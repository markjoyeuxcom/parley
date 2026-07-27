import { randomUUID } from 'node:crypto'
import {
  type CorrectionDisposition,
  addUsage,
  emptyUsage,
  type AgentConfig,
  type Approval,
  type ApprovalScope,
  type Evidence,
  type Finding,
  type FindingDisposition,
  type FindingOccurrence,
  type GridLayout,
  type Id,
  type Interjection,
  type InterjectionTarget,
  type Loop,
  type LoopIteration,
  type LedgerFinding,
  MilestoneRunState,
  type Milestone,
  type MilestoneStatus,
  type Mutation,
  type MutationResult,
  type ScoreDimension,
  type Session,
  type SessionDeletionImpact,
  type SessionStatus,
  type Skill,
  type TestResult,
  type Turn,
  type Usage,
  type Verdict,
  type WorkPlan,
  type Worktree,
} from '@shared/domain'
import { findingIdentity, normaliseFindingText } from '@shared/ledger'
import type { Db, Row } from './db'

export function newId(): Id {
  return randomUUID()
}

const json = (value: unknown): string => JSON.stringify(value)

function parseJson<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string') return fallback
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}

const str = (v: unknown, d = ''): string => (typeof v === 'string' ? v : d)

/** The wire-safe view of a stored run-state blob; zod strips the heavy rest. */
function summariseRunState(raw: unknown): MilestoneRunState | null {
  const parsed = parseJson<unknown>(raw, null)
  if (!parsed) return null
  const summary = MilestoneRunState.safeParse(parsed)
  return summary.success ? summary.data : null
}

/** Reads a stored seat that may predate seats: 'a' and 'b' are 0 and 1. */
function legacySeat(value: string): number {
  if (value === 'a') return 0
  if (value === 'b') return 1
  const parsed = Number.parseInt(value, 10)
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : 0
}
const num = (v: unknown, d = 0): number => (typeof v === 'number' ? v : d)
const nullableNum = (v: unknown): number | null => (typeof v === 'number' ? v : null)
const nullableStr = (v: unknown): string | null => (typeof v === 'string' ? v : null)

const NEXT_LEDGER_SEQUENCE = `(SELECT COALESCE(MAX(seq), 0) + 1
  FROM (
    SELECT seq FROM ledger_sightings
    UNION ALL
    SELECT seq FROM ledger_dispositions
  ))`

/** Thrown when an approval cannot be spent. Surfaces to the UI verbatim. */
export class ApprovalError extends Error {}

/** How much in-flight work was left stranded by the last shutdown. */
export interface Reconciliation {
  sessions: number
  loops: number
  plans: number
  milestones: number
}

/**
 * Typed access to the local database.
 *
 * Row-to-domain mapping lives here and nowhere else, so the shape of a table is
 * only known to this file.
 */
export class Repo {
  constructor(private readonly db: Db) {}

  // ─── Crash recovery ────────────────────────────────────────────────────────

  /**
   * Resolves work that was in flight when the app last stopped.
   *
   * Runners only ever live in memory, so a quit or crash mid-turn leaves rows
   * claiming to be `running` or `executing` with nothing behind them. Without
   * this sweep those rows stay that way permanently — a milestone spinning on
   * "executing" forever, with no way to retry it because the UI correctly
   * refuses to run something it believes is already running.
   *
   * Everything is moved to a terminal state with an explicit reason, so the
   * audit trail says the run was interrupted rather than silently pretending it
   * completed. Approvals already consumed stay consumed: retrying a write
   * deliberately requires fresh authorisation.
   */
  reconcileInterrupted(): Reconciliation {
    const reason = 'Interrupted when Parley last quit.'
    const now = Date.now()

    return this.db.transaction(() => {
      const sessions = this.db.run(
        `UPDATE sessions SET status = 'failed', error = ?, ended_at = ?
         WHERE status IN ('running', 'paused', 'stopping')`,
        reason,
        now,
      ).changes

      // A turn that never finished has no end and no text worth keeping.
      this.db.run(
        `UPDATE turns SET ended_at = ?, error = ? WHERE ended_at IS NULL AND error IS NULL`,
        now,
        reason,
      )

      const loops = this.db.run(
        `UPDATE loops SET status = 'killed', stop_reason = ?, ended_at = ?
         WHERE status IN ('running', 'paused')`,
        reason,
        now,
      ).changes

      this.db.run(
        `UPDATE loop_iterations SET ended_at = ?, error = ? WHERE ended_at IS NULL AND error IS NULL`,
        now,
        reason,
      )

      const plans = this.db.run(
        `UPDATE plans
         SET status = CASE WHEN status = 'correcting' THEN 'blocked' ELSE 'failed' END,
             correction_note = CASE
               WHEN status = 'correcting' AND correction_note = '' THEN ?
               WHEN status = 'correcting' THEN correction_note || char(10) || char(10) || ?
               ELSE correction_note
             END
         WHERE status IN ('drafting', 'auditing', 'correcting', 'running')`,
        reason,
        reason,
      ).changes

      // A preserved run state makes the interruption resumable, and the note
      // says so — that sentence is the difference between "start over" and
      // "one click continues it". completed_at and review_passed are nulled
      // because an interrupted attempt can otherwise carry a stale pass from
      // the round before the crash, beside a status that says failed.
      const resumableReason = `${reason} The run state was preserved, so this milestone can be resumed with a fresh approval.`
      const milestones = this.db.run(
        `UPDATE milestones
         SET status = 'failed',
             completed_at = NULL,
             review_passed = NULL,
             review_note = CASE
               WHEN review_note = '' AND run_state IS NOT NULL THEN ?
               WHEN review_note = '' THEN ?
               WHEN run_state IS NOT NULL THEN review_note || char(10) || char(10) || ?
               ELSE review_note || char(10) || char(10) || ?
             END
         WHERE status IN ('executing', 'testing', 'reviewing')`,
        resumableReason,
        reason,
        resumableReason,
        reason,
      ).changes

      return { sessions, loops, plans, milestones }
    })
  }

  // ─── Sessions ──────────────────────────────────────────────────────────────

  // archivedAt is excluded rather than defaulted: a session is never created
  // archived, so asking every caller to say so would be noise.
  createSession(input: Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>): Session {
    const session: Session = {
      ...input,
      usage: emptyUsage(),
      endedAt: null,
      error: null,
      archivedAt: null,
    }
    this.db.run(
      `INSERT INTO sessions (id, kind, status, matter, project, repo_path, participants, max_turns, usage, mock, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      session.id,
      session.kind,
      session.status,
      session.matter,
      session.project,
      session.repoPath,
      json(session.participants),
      session.maxTurns,
      json(session.usage),
      session.mock ? 1 : 0,
      session.createdAt,
    )
    return session
  }

  private toSession(row: Row): Session {
    return {
      id: str(row['id']),
      kind: str(row['kind']) as Session['kind'],
      status: str(row['status']) as SessionStatus,
      matter: str(row['matter']),
      project: str(row['project']),
      repoPath: nullableStr(row['repo_path']),
      // Every row has been seated since the v11 backfill; the default pair
      // only guards a corrupt cell, the same way the other parses do.
      participants: parseJson<AgentConfig[] | null>(row['participants'], null) ?? [
        { vendor: 'claude', model: '', effort: 'medium', persona: '' },
        { vendor: 'codex', model: '', effort: 'medium', persona: '' },
      ],
      maxTurns: num(row['max_turns'], 6),
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
      endedAt: nullableNum(row['ended_at']),
      error: nullableStr(row['error']),
      archivedAt: nullableNum(row['archived_at']),
    }
  }

  getSession(id: Id): Session | null {
    const row = this.db.get(`SELECT * FROM sessions WHERE id = ?`, id)
    return row ? this.toSession(row) : null
  }

  /**
   * @param includeArchived Archived sessions are excluded by default, which is
   *   the whole point of archiving. Pass true for the "show archived" view.
   */
  listSessions(limit = 200, includeArchived = false): Session[] {
    return this.db
      .all(
        `SELECT * FROM sessions
         ${includeArchived ? '' : 'WHERE archived_at IS NULL'}
         ORDER BY created_at DESC LIMIT ?`,
        limit,
      )
      .map((r) => this.toSession(r))
  }

  /** How many are hidden right now, so the UI can offer to show them. */
  countArchivedSessions(): number {
    const row = this.db.get(`SELECT COUNT(*) AS n FROM sessions WHERE archived_at IS NOT NULL`)
    return num(row?.['n'])
  }

  /**
   * Archives or restores a session. Reversible by construction — the only
   * change is a timestamp, and nothing that references the session is touched.
   */
  setSessionArchived(id: Id, archived: boolean): Session {
    this.db.run(
      `UPDATE sessions SET archived_at = ? WHERE id = ?`,
      archived ? Date.now() : null,
      id,
    )
    const session = this.getSession(id)
    if (!session) throw new Error('no such session')
    return session
  }

  /** Everything that would go with this session, for the confirmation dialog. */
  describeSessionDeletion(id: Id): SessionDeletionImpact {
    const plans = this.db.all(`SELECT id, repo_path FROM plans WHERE session_id = ?`, id)
    const planIds = plans.map((p) => str(p['id']))

    let milestones = 0
    let completedMilestones = 0
    let retainedApprovals = 0
    let unlandedWorktrees = 0
    const repos = new Set<string>()

    for (const plan of plans) {
      // An unlanded worktree row names a branch whose commits exist nowhere
      // else; deleting the session orphans it silently unless said up front.
      const unlanded = this.db.get(
        `SELECT COUNT(*) AS n FROM worktrees WHERE plan_id = ? AND landed_at IS NULL`,
        str(plan['id']),
      )
      unlandedWorktrees += num(unlanded?.['n'])
      const rows = this.db.all(`SELECT id, status FROM milestones WHERE plan_id = ?`, str(plan['id']))
      milestones += rows.length
      for (const row of rows) {
        if (str(row['status']) === 'complete') {
          completedMilestones += 1
          repos.add(str(plan['repo_path']))
        }
        // Approvals are polymorphic (scope + subject_id) with no foreign key, so
        // this has to be counted per milestone rather than joined.
        const spent = this.db.get(
          `SELECT COUNT(*) AS n FROM approvals WHERE subject_id = ? AND consumed_at IS NOT NULL`,
          str(row['id']),
        )
        retainedApprovals += num(spent?.['n'])
      }
    }

    const count = (sql: string): number => num(this.db.get(sql, id)?.['n'])
    const legacyFindings = count(`SELECT COUNT(*) AS n FROM findings WHERE session_id = ?`)
    const ledgerFindings = count(`SELECT COUNT(*) AS n FROM ledger_findings WHERE session_id = ?`)
    return {
      turns: count(`SELECT COUNT(*) AS n FROM turns WHERE session_id = ?`),
      hasVerdict: count(`SELECT COUNT(*) AS n FROM verdicts WHERE session_id = ?`) > 0,
      findings: legacyFindings + ledgerFindings,
      dispositions: count(
        `SELECT COUNT(*) AS n
         FROM ledger_dispositions d
         JOIN ledger_findings f ON f.id = d.finding_id
         WHERE f.session_id = ?`,
      ),
      plans: planIds.length,
      milestones,
      completedMilestones,
      repos: [...repos],
      retainedApprovals,
      unlandedWorktrees,
    }
  }

  /**
   * Permanently removes a session and the work hanging off it.
   *
   * The cascade is written out rather than left to foreign keys. Only four
   * tables actually declare `ON DELETE CASCADE` against sessions — `plans` and
   * `agent_threads` carry a `session_id` with no constraint at all — so relying
   * on the schema would silently strand a plan and its milestones. Being
   * explicit also puts the policy somewhere a reader can check it, including
   * the one deliberate omission below.
   */
  deleteSession(id: Id): void {
    this.db.transaction(() => {
      for (const plan of this.db.all(`SELECT id FROM plans WHERE session_id = ?`, id)) {
        const planId = str(plan['id'])
        this.db.run(`DELETE FROM milestones WHERE plan_id = ?`, planId)
        this.db.run(`DELETE FROM plans WHERE id = ?`, planId)
      }

      // Deliberately not deleted: consumed approvals. Each records that a write
      // to a named repository was authorised, carries its own summary, and
      // remains legible with the session gone. Erasing the evidence that
      // permission was given is worse than leaving a row nothing points at.

      this.db.run(
        `DELETE FROM ledger_dispositions
         WHERE finding_id IN (SELECT id FROM ledger_findings WHERE session_id = ?)`,
        id,
      )
      this.db.run(
        `DELETE FROM ledger_sightings
         WHERE finding_id IN (SELECT id FROM ledger_findings WHERE session_id = ?)`,
        id,
      )
      this.db.run(`DELETE FROM ledger_findings WHERE session_id = ?`, id)
      this.db.run(`DELETE FROM agent_threads WHERE session_id = ?`, id)
      // turns, interjections, verdicts and findings go with this by cascade.
      this.db.run(`DELETE FROM sessions WHERE id = ?`, id)
    })
  }

  setSessionStatus(id: Id, status: SessionStatus, error?: string | null): void {
    const terminal = status === 'complete' || status === 'failed' || status === 'cancelled'
    this.db.run(
      `UPDATE sessions SET status = ?, error = ?, ended_at = ? WHERE id = ?`,
      status,
      error ?? null,
      terminal ? Date.now() : null,
      id,
    )
  }

  addSessionUsage(id: Id, delta: Usage): Usage {
    const row = this.db.get(`SELECT usage FROM sessions WHERE id = ?`, id)
    const total = addUsage(parseJson<Usage>(row?.['usage'], emptyUsage()), delta)
    this.db.run(`UPDATE sessions SET usage = ? WHERE id = ?`, json(total), id)
    return total
  }

  // ─── Turns ─────────────────────────────────────────────────────────────────

  createTurn(turn: Turn): Turn {
    this.db.run(
      `INSERT INTO turns (id, session_id, idx, seat, vendor, model, stage, text, usage, started_at, ended_at, error)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      turn.id,
      turn.sessionId,
      turn.index,
      turn.seat,
      turn.vendor,
      turn.model,
      turn.stage,
      turn.text,
      json(turn.usage),
      turn.startedAt,
      turn.endedAt,
      turn.error,
    )
    return turn
  }

  finishTurn(turn: Turn): void {
    this.db.run(
      `UPDATE turns SET text = ?, usage = ?, ended_at = ?, error = ? WHERE id = ?`,
      turn.text,
      json(turn.usage),
      turn.endedAt,
      turn.error,
      turn.id,
    )
  }

  private toTurn(row: Row): Turn {
    return {
      id: str(row['id']),
      sessionId: str(row['session_id']),
      index: num(row['idx']),
      // Seated by the v12 backfill; the zero default only guards a corrupt
      // cell, the same way the other parses do.
      seat: num(row['seat'], 0),
      vendor: str(row['vendor']) as Turn['vendor'],
      model: str(row['model']),
      stage: str(row['stage']),
      text: str(row['text']),
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      startedAt: num(row['started_at']),
      endedAt: nullableNum(row['ended_at']),
      error: nullableStr(row['error']),
    }
  }

  listTurns(sessionId: Id): Turn[] {
    return this.db
      .all(`SELECT * FROM turns WHERE session_id = ? ORDER BY idx ASC`, sessionId)
      .map((r) => this.toTurn(r))
  }

  // ─── Vendor thread ids ─────────────────────────────────────────────────────

  saveResumeId(sessionId: Id, seat: number, resumeId: string): void {
    this.db.run(
      `INSERT INTO agent_threads (session_id, seat, resume_id) VALUES (?, ?, ?)
       ON CONFLICT(session_id, seat) DO UPDATE SET resume_id = excluded.resume_id`,
      sessionId,
      seat,
      resumeId,
    )
  }

  getResumeId(sessionId: Id, seat: number): string | null {
    const row = this.db.get(
      `SELECT resume_id FROM agent_threads WHERE session_id = ? AND seat = ?`,
      sessionId,
      seat,
    )
    return nullableStr(row?.['resume_id'])
  }

  // ─── Interjections ─────────────────────────────────────────────────────────

  addInterjection(input: Omit<Interjection, 'id' | 'createdAt' | 'deliveredAt'>): Interjection {
    const record: Interjection = { ...input, id: newId(), createdAt: Date.now(), deliveredAt: null }
    this.db.run(
      `INSERT INTO interjections (id, session_id, target, text, at_turn_index, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      record.id,
      record.sessionId,
      String(record.target),
      record.text,
      record.atTurnIndex,
      record.createdAt,
    )
    return record
  }

  /** Reads a stored target that may predate seats: 'both' is 'all', sides map. */
  private toInterjectionTarget(value: string): InterjectionTarget {
    if (value === 'all' || value === 'both') return 'all'
    return legacySeat(value)
  }

  /**
   * Returns the interjections a given seat has not yet seen, marking them
   * delivered *for that seat only* in the same transaction so a retry cannot
   * double-deliver.
   *
   * A whisper to one seat is never returned for another: that asymmetry is the
   * feature — it is what lets the director press one agent privately and see
   * whether it holds its position without the others knowing it was pushed.
   */
  takeInterjections(sessionId: Id, seat: number): Interjection[] {
    // Stored targets may predate seats, so a seat matches its own number,
    // 'all', and the legacy spellings of both.
    const spellings = ['all', 'both', String(seat)]
    if (seat === 0) spellings.push('a')
    if (seat === 1) spellings.push('b')

    return this.db.transaction(() => {
      const rows = this.db.all(
        `SELECT * FROM interjections
         WHERE session_id = ?
           AND target IN (${spellings.map(() => '?').join(', ')})
           AND NOT EXISTS (
             SELECT 1 FROM interjection_deliveries d
             WHERE d.interjection_id = interjections.id AND d.seat = ?
           )
         ORDER BY created_at ASC`,
        sessionId,
        ...spellings,
        seat,
      )
      const now = Date.now()
      for (const row of rows) {
        this.db.run(
          `INSERT INTO interjection_deliveries (interjection_id, seat, delivered_at) VALUES (?, ?, ?)`,
          str(row['id']),
          seat,
          now,
        )
      }
      const seatCount = this.sessionSeatCount(sessionId)
      return rows.map((row) => this.toInterjection(row, this.deliveriesFor(str(row['id'])), seatCount))
    })
  }

  private sessionSeatCount(sessionId: Id): number {
    return this.getSession(sessionId)?.participants.length ?? 2
  }

  private deliveriesFor(interjectionId: Id): Array<{ seat: number; at: number }> {
    return this.db
      .all(
        `SELECT seat, delivered_at FROM interjection_deliveries WHERE interjection_id = ?`,
        interjectionId,
      )
      .map((row) => ({ seat: num(row['seat']), at: num(row['delivered_at']) }))
  }

  /**
   * `deliveredAt` is "delivered to everyone it was addressed to" — for an
   * 'all' interjection that means every seat in the session has taken it, and
   * the stamp is the last seat's; a whisper is delivered when its one seat is.
   */
  private toInterjection(
    row: Row,
    deliveries: Array<{ seat: number; at: number }>,
    seatCount: number,
  ): Interjection {
    const target = this.toInterjectionTarget(str(row['target']))
    let deliveredAt: number | null = null
    if (target === 'all') {
      if (deliveries.length >= seatCount) {
        deliveredAt = deliveries.reduce((latest, entry) => Math.max(latest, entry.at), 0)
      }
    } else {
      deliveredAt = deliveries.find((entry) => entry.seat === target)?.at ?? null
    }
    return {
      id: str(row['id']),
      sessionId: str(row['session_id']),
      target,
      text: str(row['text']),
      atTurnIndex: num(row['at_turn_index']),
      createdAt: num(row['created_at']),
      deliveredAt,
    }
  }

  listInterjections(sessionId: Id): Interjection[] {
    const seatCount = this.sessionSeatCount(sessionId)
    const deliveries = this.db.all(
      `SELECT d.interjection_id, d.seat, d.delivered_at
       FROM interjection_deliveries d
       JOIN interjections i ON i.id = d.interjection_id
       WHERE i.session_id = ?`,
      sessionId,
    )
    const byInterjection = new Map<string, Array<{ seat: number; at: number }>>()
    for (const row of deliveries) {
      const id = str(row['interjection_id'])
      const list = byInterjection.get(id) ?? []
      list.push({ seat: num(row['seat']), at: num(row['delivered_at']) })
      byInterjection.set(id, list)
    }
    return this.db
      .all(`SELECT * FROM interjections WHERE session_id = ? ORDER BY created_at ASC`, sessionId)
      .map((row) => this.toInterjection(row, byInterjection.get(str(row['id'])) ?? [], seatCount))
  }

  // ─── Verdicts and findings ─────────────────────────────────────────────────

  saveVerdict(verdict: Verdict): void {
    this.db.run(
      `INSERT INTO verdicts (session_id, decision, rationale, scores, confidence, dissent, report, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(session_id) DO NOTHING`,
      verdict.sessionId,
      verdict.decision,
      verdict.rationale,
      json(verdict.scores),
      verdict.confidence,
      verdict.dissent,
      verdict.report,
      verdict.createdAt,
    )
  }

  getVerdict(sessionId: Id): Verdict | null {
    const row = this.db.get(`SELECT * FROM verdicts WHERE session_id = ?`, sessionId)
    if (!row) return null
    return {
      sessionId: str(row['session_id']),
      decision: str(row['decision']),
      rationale: str(row['rationale']),
      scores: parseJson<Record<ScoreDimension, number>>(row['scores'], {} as Record<ScoreDimension, number>),
      confidence: num(row['confidence']),
      dissent: str(row['dissent']),
      report: str(row['report']),
      createdAt: num(row['created_at']),
    }
  }

  replaceFindings(sessionId: Id, findings: Finding[]): void {
    this.db.transaction(() => {
      this.db.run(`DELETE FROM findings WHERE session_id = ?`, sessionId)
      for (const f of findings) {
        this.db.run(
          `INSERT INTO findings (id, session_id, priority, status, title, detail, evidence, raised_by, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          f.id,
          f.sessionId,
          f.priority,
          f.status,
          f.title,
          f.detail,
          json(f.evidence),
          // The column is TEXT and once held 'a'/'b'; seats write their number
          // and the read maps the legacy names onto seats 0 and 1.
          String(f.raisedBy),
          f.createdAt,
        )
      }
    })
  }

  listFindings(sessionId: Id): Finding[] {
    return this.db
      .all(`SELECT * FROM findings WHERE session_id = ? ORDER BY priority ASC, created_at ASC`, sessionId)
      .map((row): Finding => ({
        id: str(row['id']),
        sessionId: str(row['session_id']),
        priority: str(row['priority']) as Finding['priority'],
        status: str(row['status']) as Finding['status'],
        title: str(row['title']),
        detail: str(row['detail']),
        evidence: parseJson<Evidence[]>(row['evidence'], []),
        raisedBy: legacySeat(str(row['raised_by'])),
        createdAt: num(row['created_at']),
      }))
  }

  // ─── Finding ledger ────────────────────────────────────────────────────────

  upsertLedgerFinding(sessionId: Id, text: string, createdAt = Date.now()): LedgerFinding {
    const finding: LedgerFinding = {
      id: findingIdentity(sessionId, text),
      sessionId,
      text: text.trim(),
      normalizedText: normaliseFindingText(text),
      createdAt,
    }
    if (!finding.normalizedText) throw new Error('a finding cannot be empty')

    this.db.run(
      `INSERT INTO ledger_findings (id, session_id, text, normalized_text, created_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(id) DO NOTHING`,
      finding.id,
      finding.sessionId,
      finding.text,
      finding.normalizedText,
      finding.createdAt,
    )

    const row = this.db.get(`SELECT * FROM ledger_findings WHERE id = ?`, finding.id)
    if (!row) throw new Error('failed to record finding')
    return this.toLedgerFinding(row)
  }

  private toLedgerFinding(row: Row): LedgerFinding {
    return {
      id: str(row['id']),
      sessionId: str(row['session_id']),
      text: str(row['text']),
      normalizedText: str(row['normalized_text']),
      createdAt: num(row['created_at']),
    }
  }

  listLedgerFindings(sessionId: Id): LedgerFinding[] {
    return this.db
      .all(
        `SELECT * FROM ledger_findings
         WHERE session_id = ?
         ORDER BY created_at ASC, id ASC`,
        sessionId,
      )
      .map((row) => this.toLedgerFinding(row))
  }

  recordFindingOccurrence(
    input: Omit<FindingOccurrence, 'id' | 'seq' | 'createdAt'> &
      Partial<Pick<FindingOccurrence, 'id' | 'createdAt'>>,
  ): FindingOccurrence {
    const id = input.id ?? newId()
    const createdAt = input.createdAt ?? Date.now()
    this.db.run(
      `INSERT INTO ledger_sightings
       (id, finding_id, plan_id, milestone_id, round, kind, source, seq, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ${NEXT_LEDGER_SEQUENCE}, ?)`,
      id,
      input.findingId,
      input.planId,
      input.milestoneId,
      input.round,
      input.kind,
      input.source,
      createdAt,
    )
    const row = this.db.get(`SELECT * FROM ledger_sightings WHERE id = ?`, id)
    if (!row) throw new Error('failed to record finding occurrence')
    return this.toFindingOccurrence(row)
  }

  private toFindingOccurrence(row: Row): FindingOccurrence {
    return {
      id: str(row['id']),
      findingId: str(row['finding_id']),
      planId: str(row['plan_id']),
      milestoneId: nullableStr(row['milestone_id']),
      round: nullableNum(row['round']),
      kind: str(row['kind']) as FindingOccurrence['kind'],
      source: str(row['source']) as FindingOccurrence['source'],
      seq: num(row['seq']),
      createdAt: num(row['created_at']),
    }
  }

  listFindingOccurrences(sessionId: Id): FindingOccurrence[] {
    return this.db
      .all(
        `SELECT s.*
         FROM ledger_sightings s
         JOIN ledger_findings f ON f.id = s.finding_id
         WHERE f.session_id = ?
         ORDER BY s.seq ASC`,
        sessionId,
      )
      .map((row) => this.toFindingOccurrence(row))
  }

  disposeFinding(
    input: Omit<FindingDisposition, 'id' | 'seq' | 'createdAt'> &
      Partial<Pick<FindingDisposition, 'id' | 'createdAt'>>,
  ): FindingDisposition {
    const id = input.id ?? newId()
    const createdAt = input.createdAt ?? Date.now()

    if (input.occurrenceId !== null) {
      const occurrence = this.db.get(
        `SELECT finding_id FROM ledger_sightings WHERE id = ?`,
        input.occurrenceId,
      )
      if (!occurrence) throw new Error('no such finding occurrence')
      if (str(occurrence['finding_id']) !== input.findingId) {
        throw new Error('that occurrence belongs to a different finding')
      }
    }

    this.db.run(
      `INSERT INTO ledger_dispositions
       (id, finding_id, occurrence_id, state, note, source, seq, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ${NEXT_LEDGER_SEQUENCE}, ?)`,
      id,
      input.findingId,
      input.occurrenceId,
      input.state,
      input.note,
      input.source,
      createdAt,
    )
    const row = this.db.get(`SELECT * FROM ledger_dispositions WHERE id = ?`, id)
    if (!row) throw new Error('failed to record finding disposition')
    return this.toFindingDisposition(row)
  }

  private toFindingDisposition(row: Row): FindingDisposition {
    return {
      id: str(row['id']),
      findingId: str(row['finding_id']),
      occurrenceId: nullableStr(row['occurrence_id']),
      state: str(row['state']) as FindingDisposition['state'],
      note: str(row['note']),
      source: str(row['source']) as FindingDisposition['source'],
      seq: num(row['seq']),
      createdAt: num(row['created_at']),
    }
  }

  listFindingDispositions(sessionId: Id): FindingDisposition[] {
    return this.db
      .all(
        `SELECT d.*
         FROM ledger_dispositions d
         JOIN ledger_findings f ON f.id = d.finding_id
         WHERE f.session_id = ?
         ORDER BY d.seq ASC`,
        sessionId,
      )
      .map((row) => this.toFindingDisposition(row))
  }

  // Single-finding reads, for assembling one ledger entry without loading the
  // session's whole ledger. Both tables are indexed on (finding_id, seq), so
  // these are point lookups rather than scans.

  getLedgerFinding(findingId: Id): LedgerFinding | null {
    const row = this.db.get(`SELECT * FROM ledger_findings WHERE id = ?`, findingId)
    return row ? this.toLedgerFinding(row) : null
  }

  listOccurrencesForFinding(findingId: Id): FindingOccurrence[] {
    return this.db
      .all(`SELECT * FROM ledger_sightings WHERE finding_id = ? ORDER BY seq ASC`, findingId)
      .map((row) => this.toFindingOccurrence(row))
  }

  listDispositionsForFinding(findingId: Id): FindingDisposition[] {
    return this.db
      .all(`SELECT * FROM ledger_dispositions WHERE finding_id = ? ORDER BY seq ASC`, findingId)
      .map((row) => this.toFindingDisposition(row))
  }

  // ─── Approvals ─────────────────────────────────────────────────────────────

  grantApproval(scope: ApprovalScope, subjectId: Id, summary: string): Approval {
    const approval: Approval = {
      id: newId(),
      scope,
      subjectId,
      summary,
      grantedAt: Date.now(),
      consumedAt: null,
    }
    this.db.run(
      `INSERT INTO approvals (id, scope, subject_id, summary, granted_at, consumed_at)
       VALUES (?, ?, ?, ?, ?, NULL)`,
      approval.id,
      approval.scope,
      approval.subjectId,
      approval.summary,
      approval.grantedAt,
    )
    return approval
  }

  /**
   * Spends an approval, or throws.
   *
   * The guard is the `consumed_at IS NULL` predicate in the UPDATE: SQLite
   * applies it atomically, so two concurrent attempts to start the same
   * milestone cannot both see an unconsumed approval. `changes === 0` means it
   * was already spent, does not exist, or does not match this subject and scope
   * — all of which are refusals.
   */
  consumeApproval(approvalId: Id, scope: ApprovalScope, subjectId: Id): Approval {
    const result = this.db.run(
      `UPDATE approvals SET consumed_at = ?
       WHERE id = ? AND scope = ? AND subject_id = ? AND consumed_at IS NULL`,
      Date.now(),
      approvalId,
      scope,
      subjectId,
    )
    if (result.changes !== 1) {
      const existing = this.db.get(`SELECT * FROM approvals WHERE id = ?`, approvalId)
      if (!existing) throw new ApprovalError('no such approval')
      if (existing['consumed_at'] !== null) {
        throw new ApprovalError(
          'that approval has already been used; approval is single-use, so grant a new one to run again',
        )
      }
      throw new ApprovalError('that approval does not authorise this action')
    }
    const row = this.db.get(`SELECT * FROM approvals WHERE id = ?`, approvalId)
    return this.toApproval(row as Row)
  }

  private toApproval(row: Row): Approval {
    return {
      id: str(row['id']),
      scope: str(row['scope']) as ApprovalScope,
      subjectId: str(row['subject_id']),
      summary: str(row['summary']),
      grantedAt: num(row['granted_at']),
      consumedAt: nullableNum(row['consumed_at']),
    }
  }

  listApprovals(limit = 200): Approval[] {
    return this.db
      .all(`SELECT * FROM approvals ORDER BY granted_at DESC LIMIT ?`, limit)
      .map((r) => this.toApproval(r))
  }

  // ─── Decision holds ────────────────────────────────────────────────────────
  // The open set is derived, never stored (orchestrator/holds.ts). These
  // persist only the human's acknowledgements and the notify-once stamps,
  // keyed by content-addressed hold identity so both survive recomputation.

  ackHold(identity: string, at = Date.now()): void {
    this.db.run(
      `INSERT INTO hold_acks (identity, acked_at) VALUES (?, ?)
       ON CONFLICT(identity) DO NOTHING`,
      identity,
      at,
    )
  }

  listHoldAcks(): Set<string> {
    return new Set(this.db.all(`SELECT identity FROM hold_acks`).map((row) => str(row['identity'])))
  }

  /**
   * Records that a hold was notified. True exactly once per identity — the
   * insert either lands or hits the primary key, which is what makes
   * "notify once, ever" atomic rather than a check-then-act race.
   */
  stampNotified(identity: string, at = Date.now()): boolean {
    return (
      this.db.run(
        `INSERT INTO hold_notifications (identity, notified_at) VALUES (?, ?)
         ON CONFLICT(identity) DO NOTHING`,
        identity,
        at,
      ).changes === 1
    )
  }

  // ─── Worktrees ─────────────────────────────────────────────────────────────

  createWorktree(worktree: Worktree): Worktree {
    this.db.run(
      `INSERT INTO worktrees (plan_id, origin_path, path, branch, base_branch, base_commit, created_at, landed_at, last_error, orphaned)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      worktree.planId,
      worktree.originPath,
      worktree.path,
      worktree.branch,
      worktree.baseBranch,
      worktree.baseCommit,
      worktree.createdAt,
      worktree.landedAt,
      worktree.lastError,
      worktree.orphaned ? 1 : 0,
    )
    return worktree
  }

  getWorktreeForPlan(planId: Id): Worktree | null {
    const row = this.db.get(`SELECT * FROM worktrees WHERE plan_id = ?`, planId)
    return row ? this.toWorktree(row) : null
  }

  listWorktrees(): Worktree[] {
    return this.db
      .all(`SELECT * FROM worktrees ORDER BY created_at ASC`)
      .map((r) => this.toWorktree(r))
  }

  /** Marks disk honesty: the directory or origin vanished, or came back. */
  flagWorktree(planId: Id, orphaned: boolean, lastError: string): void {
    this.db.run(
      `UPDATE worktrees SET orphaned = ?, last_error = ? WHERE plan_id = ?`,
      orphaned ? 1 : 0,
      lastError,
      planId,
    )
  }

  markWorktreeLanded(planId: Id, at = Date.now()): void {
    this.db.run(`UPDATE worktrees SET landed_at = ?, last_error = '' WHERE plan_id = ?`, at, planId)
  }

  private toWorktree(row: Row): Worktree {
    return {
      planId: str(row['plan_id']),
      originPath: str(row['origin_path']),
      path: str(row['path']),
      branch: str(row['branch']),
      baseBranch: str(row['base_branch']),
      baseCommit: str(row['base_commit']),
      createdAt: num(row['created_at']),
      landedAt: nullableNum(row['landed_at']),
      lastError: str(row['last_error']),
      orphaned: num(row['orphaned']) === 1,
    }
  }

  // ─── Plans and milestones ──────────────────────────────────────────────────

  createPlan(plan: WorkPlan): WorkPlan {
    this.db.run(
      `INSERT INTO plans (id, session_id, kind, title, repo_path, planner, executor, reviewer, status, usage, mock, question, correction_note, correction_dispositions, isolation, setup_command, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      plan.id,
      plan.sessionId,
      plan.kind,
      plan.title,
      plan.repoPath,
      json(plan.planner),
      json(plan.executor),
      json(plan.reviewer),
      plan.status,
      json(plan.usage),
      plan.mock ? 1 : 0,
      plan.question,
      plan.correctionNote,
      json(plan.correctionDispositions),
      plan.isolation,
      plan.setupCommand,
      plan.createdAt,
    )
    return plan
  }

  private toPlan(row: Row): WorkPlan {
    const fallback: AgentConfig = { vendor: 'claude', model: '', effort: 'medium', persona: '' }
    return {
      id: str(row['id']),
      sessionId: str(row['session_id']),
      kind: str(row['kind']) as WorkPlan['kind'],
      title: str(row['title']),
      repoPath: str(row['repo_path']),
      planner: parseJson<AgentConfig>(row['planner'], fallback),
      executor: parseJson<AgentConfig>(row['executor'], fallback),
      reviewer: parseJson<AgentConfig>(row['reviewer'], fallback),
      status: str(row['status']) as WorkPlan['status'],
      question: str(row['question']),
      correctionNote: str(row['correction_note']),
      correctionDispositions: parseJson<CorrectionDisposition[]>(row['correction_dispositions'], []),
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      isolation: str(row['isolation'], 'checkout') === 'worktree' ? 'worktree' : 'checkout',
      setupCommand: str(row['setup_command']),
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
    }
  }

  getPlan(id: Id): WorkPlan | null {
    const row = this.db.get(`SELECT * FROM plans WHERE id = ?`, id)
    return row ? this.toPlan(row) : null
  }

  listPlans(limit = 200): WorkPlan[] {
    return this.db.all(`SELECT * FROM plans ORDER BY created_at DESC LIMIT ?`, limit).map((r) => this.toPlan(r))
  }

  listPlansForSession(sessionId: Id): WorkPlan[] {
    return this.db
      .all(`SELECT * FROM plans WHERE session_id = ? ORDER BY created_at ASC`, sessionId)
      .map((r) => this.toPlan(r))
  }

  /**
   * What earlier reviews in this session objected to, milestone by milestone.
   *
   * Exists because "fix the confirmed findings" had no way to learn what the
   * findings were. Reviews are recorded against milestones in this database; a
   * planner reads the repository. The two never met, so a remediation plan was
   * a mislabelled implementation plan that invented its own worklist.
   *
   * Only milestones that ran are included — a review of work never executed is
   * not a finding — and the plan being drafted is excluded, since it has no
   * history of its own yet.
   */
  reviewFindingsForSession(sessionId: Id, excludePlanId: Id | null = null): string[] {
    const findings: string[] = []
    for (const plan of this.listPlansForSession(sessionId)) {
      if (plan.id === excludePlanId) continue
      for (const m of this.listMilestones(plan.id)) {
        if (!m.reviewNote.trim()) continue
        if (m.status !== 'complete' && m.status !== 'failed') continue
        findings.push(`Milestone ${m.index + 1} — ${m.title}\n${m.reviewNote.trim()}`)
      }
    }
    return findings
  }

  setPlanStatus(id: Id, status: WorkPlan['status']): void {
    this.db.run(`UPDATE plans SET status = ? WHERE id = ?`, status, id)
  }

  /** Parks a plan on a question, storing what the resumed stage will need. */
  askPlanQuestion(id: Id, question: string, pending: unknown): void {
    this.db.run(
      `UPDATE plans SET status = 'awaiting-clarification', question = ?, pending = ? WHERE id = ?`,
      question,
      json(pending),
      id,
    )
  }

  /** Reads and clears the parked state. Returns null when nothing is parked. */
  takePlanPending<T>(id: Id): T | null {
    const row = this.db.get(`SELECT pending FROM plans WHERE id = ?`, id)
    const raw = row?.['pending']
    if (typeof raw !== 'string' || !raw) return null
    this.db.run(`UPDATE plans SET pending = NULL, question = '' WHERE id = ?`, id)
    try {
      return JSON.parse(raw) as T
    } catch {
      return null
    }
  }

  setPlanCorrectionNote(id: Id, note: string): void {
    this.db.run(`UPDATE plans SET correction_note = ? WHERE id = ?`, note, id)
  }

  /** The same dispositions, structured, for the surface to table. */
  setPlanCorrectionDispositions(id: Id, dispositions: CorrectionDisposition[]): void {
    this.db.run(
      `UPDATE plans SET correction_dispositions = ? WHERE id = ?`,
      json(dispositions),
      id,
    )
  }

  /** Milestones are replaced wholesale when a corrected plan supersedes them. */
  clearMilestones(planId: Id): void {
    this.db.run(`DELETE FROM milestones WHERE plan_id = ?`, planId)
  }

  setPlanTitle(id: Id, title: string): void {
    this.db.run(`UPDATE plans SET title = ? WHERE id = ?`, title, id)
  }

  addPlanUsage(id: Id, delta: Usage): void {
    const row = this.db.get(`SELECT usage FROM plans WHERE id = ?`, id)
    const total = addUsage(parseJson<Usage>(row?.['usage'], emptyUsage()), delta)
    this.db.run(`UPDATE plans SET usage = ? WHERE id = ?`, json(total), id)
  }

  createMilestone(m: Milestone): Milestone {
    this.db.run(
      `INSERT INTO milestones (id, plan_id, idx, title, intent, expected_paths, status, audit_note,
                               test_command, test_result, review_note, review_passed, adopted, approval_id, created_at, completed_at,
                               mutations, mutation_results, review_blocking, review_notes)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      m.id,
      m.planId,
      m.index,
      m.title,
      m.intent,
      json(m.expectedPaths),
      m.status,
      m.auditNote,
      m.testCommand,
      m.testResult ? json(m.testResult) : null,
      m.reviewNote,
      m.reviewPassed === null ? null : m.reviewPassed ? 1 : 0,
      m.adopted ? 1 : 0,
      m.approvalId,
      m.createdAt,
      m.completedAt,
      json(m.mutations),
      json(m.mutationResults),
      json(m.reviewBlocking),
      json(m.reviewNotes),
    )
    return m
  }

  private toMilestone(row: Row): Milestone {
    const passed = row['review_passed']
    return {
      id: str(row['id']),
      planId: str(row['plan_id']),
      index: num(row['idx']),
      title: str(row['title']),
      intent: str(row['intent']),
      expectedPaths: parseJson<string[]>(row['expected_paths'], []),
      status: str(row['status']) as MilestoneStatus,
      auditNote: str(row['audit_note']),
      testCommand: str(row['test_command']),
      testResult: row['test_result'] ? parseJson<TestResult | null>(row['test_result'], null) : null,
      mutations: parseJson<Mutation[]>(row['mutations'], []),
      mutationResults: parseJson<MutationResult[]>(row['mutation_results'], []),
      reviewNote: str(row['review_note']),
      reviewBlocking: parseJson<string[]>(row['review_blocking'], []),
      reviewNotes: parseJson<string[]>(row['review_notes'], []),
      reviewPassed: typeof passed === 'number' ? passed === 1 : null,
      adopted: num(row['adopted']) === 1,
      approvalId: nullableStr(row['approval_id']),
      createdAt: num(row['created_at']),
      completedAt: nullableNum(row['completed_at']),
      runState: summariseRunState(row['run_state']),
    }
  }

  /**
   * The full run-state blob, main-side only. Everything a resumed run needs —
   * baseline tree, both resume ids, the critique — none of which belongs on
   * the wire. Writes go through {@link setMilestoneRunState}; the domain rows
   * carry only the summary.
   */
  getMilestoneRunState<T>(id: Id): T | null {
    const row = this.db.get(`SELECT run_state FROM milestones WHERE id = ?`, id)
    const raw = row?.['run_state']
    if (typeof raw !== 'string' || !raw) return null
    try {
      return JSON.parse(raw) as T
    } catch {
      return null
    }
  }

  setMilestoneRunState(id: Id, state: unknown | null): void {
    this.db.run(
      `UPDATE milestones SET run_state = ? WHERE id = ?`,
      state === null ? null : json(state),
      id,
    )
  }

  getMilestone(id: Id): Milestone | null {
    const row = this.db.get(`SELECT * FROM milestones WHERE id = ?`, id)
    return row ? this.toMilestone(row) : null
  }

  listMilestones(planId: Id): Milestone[] {
    return this.db
      .all(`SELECT * FROM milestones WHERE plan_id = ? ORDER BY idx ASC`, planId)
      .map((r) => this.toMilestone(r))
  }

  updateMilestone(id: Id, patch: Partial<Milestone>): Milestone {
    const columns: Record<keyof Milestone & string, string> = {
      id: 'id',
      planId: 'plan_id',
      index: 'idx',
      title: 'title',
      intent: 'intent',
      expectedPaths: 'expected_paths',
      status: 'status',
      auditNote: 'audit_note',
      testCommand: 'test_command',
      testResult: 'test_result',
      reviewNote: 'review_note',
      reviewBlocking: 'review_blocking',
      reviewNotes: 'review_notes',
      reviewPassed: 'review_passed',
      adopted: 'adopted',
      approvalId: 'approval_id',
      createdAt: 'created_at',
      completedAt: 'completed_at',
      mutations: 'mutations',
      mutationResults: 'mutation_results',
      // Deliberately unwritable through a patch: the domain field is a derived
      // summary, and the full blob has its own accessor (setMilestoneRunState).
      runState: '',
    }
    const sets: string[] = []
    const values: unknown[] = []
    for (const [key, value] of Object.entries(patch)) {
      const column = columns[key as keyof Milestone & string]
      if (!column || column === 'id') continue
      sets.push(`${column} = ?`)
      if (
        key === 'expectedPaths' ||
        key === 'testResult' ||
        key === 'mutations' ||
        key === 'mutationResults' ||
        key === 'reviewBlocking' ||
        key === 'reviewNotes'
      ) {
        values.push(value === null ? null : json(value))
      }
      else if (key === 'reviewPassed') values.push(value === null ? null : value ? 1 : 0)
      else if (key === 'adopted') values.push(value ? 1 : 0)
      else values.push(value as unknown)
    }
    if (sets.length) {
      this.db.run(`UPDATE milestones SET ${sets.join(', ')} WHERE id = ?`, ...values, id)
    }
    const updated = this.getMilestone(id)
    if (!updated) throw new Error(`milestone ${id} disappeared`)
    return updated
  }

  // ─── Loops ─────────────────────────────────────────────────────────────────

  createLoop(loop: Loop): Loop {
    this.db.run(
      `INSERT INTO loops (id, goal, repo_path, worker, verifier, exit_condition, caps, capability,
                          approval_id, status, usage, iteration_count, mock, started_at, ended_at, stop_reason)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      loop.id,
      loop.goal,
      loop.repoPath,
      json(loop.worker),
      json(loop.verifier),
      json(loop.exit),
      json(loop.caps),
      loop.capability,
      loop.approvalId,
      loop.status,
      json(loop.usage),
      loop.iterationCount,
      loop.mock ? 1 : 0,
      loop.startedAt,
      loop.endedAt,
      loop.stopReason,
    )
    return loop
  }

  private toLoop(row: Row): Loop {
    const fallback: AgentConfig = { vendor: 'claude', model: '', effort: 'medium', persona: '' }
    return {
      id: str(row['id']),
      goal: str(row['goal']),
      repoPath: str(row['repo_path']),
      worker: parseJson<AgentConfig>(row['worker'], fallback),
      verifier: parseJson<AgentConfig>(row['verifier'], fallback),
      exit: parseJson<Loop['exit']>(row['exit_condition'], { kind: 'command', command: '', criterion: '' }),
      caps: parseJson<Loop['caps']>(row['caps'], { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 }),
      capability: str(row['capability']) as Loop['capability'],
      approvalId: nullableStr(row['approval_id']),
      status: str(row['status']) as Loop['status'],
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      iterationCount: num(row['iteration_count']),
      mock: num(row['mock']) === 1,
      startedAt: num(row['started_at']),
      endedAt: nullableNum(row['ended_at']),
      stopReason: str(row['stop_reason']),
    }
  }

  getLoop(id: Id): Loop | null {
    const row = this.db.get(`SELECT * FROM loops WHERE id = ?`, id)
    return row ? this.toLoop(row) : null
  }

  listLoops(limit = 200): Loop[] {
    return this.db.all(`SELECT * FROM loops ORDER BY started_at DESC LIMIT ?`, limit).map((r) => this.toLoop(r))
  }

  startLoop(id: Id, approvalId: Id | null): Loop {
    const startedAt = Date.now()
    const result = this.db.run(
      `UPDATE loops SET status = 'running', approval_id = ?, started_at = ?
       WHERE id = ? AND status = 'idle'`,
      approvalId,
      startedAt,
      id,
    )
    if (result.changes !== 1) throw new Error(`loop ${id} is not idle`)
    const loop = this.getLoop(id)
    if (!loop) throw new Error(`loop ${id} disappeared`)
    return loop
  }

  setLoopStatus(id: Id, status: Loop['status'], stopReason = ''): void {
    const terminal = status === 'succeeded' || status === 'exhausted' || status === 'killed' || status === 'failed'
    this.db.run(
      `UPDATE loops SET status = ?, stop_reason = ?, ended_at = ? WHERE id = ?`,
      status,
      stopReason,
      terminal ? Date.now() : null,
      id,
    )
  }

  bumpLoop(id: Id, delta: Usage): Loop {
    const loop = this.getLoop(id)
    if (!loop) throw new Error(`loop ${id} not found`)
    const usage = addUsage(loop.usage, delta)
    const count = loop.iterationCount + 1
    this.db.run(`UPDATE loops SET usage = ?, iteration_count = ? WHERE id = ?`, json(usage), count, id)
    return { ...loop, usage, iterationCount: count }
  }

  addLoopUsage(id: Id, delta: Usage): Loop {
    const loop = this.getLoop(id)
    if (!loop) throw new Error(`loop ${id} not found`)
    const usage = addUsage(loop.usage, delta)
    this.db.run(`UPDATE loops SET usage = ? WHERE id = ?`, json(usage), id)
    return { ...loop, usage }
  }

  createIteration(it: LoopIteration): LoopIteration {
    this.db.run(
      `INSERT INTO loop_iterations (id, loop_id, idx, vendor, summary, usage, exit_met, exit_detail, started_at, ended_at, error)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      it.id,
      it.loopId,
      it.index,
      it.vendor,
      it.summary,
      json(it.usage),
      it.exitMet ? 1 : 0,
      it.exitDetail,
      it.startedAt,
      it.endedAt,
      it.error,
    )
    return it
  }

  finishIteration(it: LoopIteration): void {
    this.db.run(
      `UPDATE loop_iterations SET summary = ?, usage = ?, exit_met = ?, exit_detail = ?, ended_at = ?, error = ?
       WHERE id = ?`,
      it.summary,
      json(it.usage),
      it.exitMet ? 1 : 0,
      it.exitDetail,
      it.endedAt,
      it.error,
      it.id,
    )
  }

  listIterations(loopId: Id): LoopIteration[] {
    return this.db
      .all(`SELECT * FROM loop_iterations WHERE loop_id = ? ORDER BY idx ASC`, loopId)
      .map((row): LoopIteration => ({
        id: str(row['id']),
        loopId: str(row['loop_id']),
        index: num(row['idx']),
        vendor: str(row['vendor']) as LoopIteration['vendor'],
        summary: str(row['summary']),
        usage: parseJson<Usage>(row['usage'], emptyUsage()),
        exitMet: num(row['exit_met']) === 1,
        exitDetail: str(row['exit_detail']),
        startedAt: num(row['started_at']),
        endedAt: nullableNum(row['ended_at']),
        error: nullableStr(row['error']),
      }))
  }

  // ─── Saved grid layouts ────────────────────────────────────────────────────

  /** Saves under a name, replacing any layout already using it. */
  saveLayout(input: Omit<GridLayout, 'createdAt' | 'updatedAt'>): GridLayout {
    const now = Date.now()
    const existing = this.db.get(`SELECT id, created_at FROM grid_layouts WHERE name = ?`, input.name)
    const id = existing ? str(existing['id']) : input.id
    const createdAt = existing ? num(existing['created_at']) : now

    this.db.run(
      `INSERT INTO grid_layouts (id, name, default_folder, tree, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         default_folder = excluded.default_folder,
         tree = excluded.tree,
         updated_at = excluded.updated_at`,
      id,
      input.name,
      input.defaultFolder,
      json(input.tree),
      createdAt,
      now,
    )
    return { ...input, id, createdAt, updatedAt: now }
  }

  private toLayout(row: Row): GridLayout {
    return {
      id: str(row['id']),
      name: str(row['name']),
      defaultFolder: str(row['default_folder']),
      tree: parseJson<GridLayout['tree']>(row['tree'], { type: 'leaf', kind: 'shell', cwd: '' }),
      createdAt: num(row['created_at']),
      updatedAt: num(row['updated_at']),
    }
  }

  listLayouts(): GridLayout[] {
    // Name breaks the tie so two layouts saved in the same millisecond do not
    // swap places between calls.
    return this.db
      .all(`SELECT * FROM grid_layouts ORDER BY updated_at DESC, name ASC`)
      .map((r) => this.toLayout(r))
  }

  getLayout(id: Id): GridLayout | null {
    const row = this.db.get(`SELECT * FROM grid_layouts WHERE id = ?`, id)
    return row ? this.toLayout(row) : null
  }

  deleteLayout(id: Id): void {
    this.db.run(`DELETE FROM grid_layouts WHERE id = ?`, id)
  }

  // ─── Skills ────────────────────────────────────────────────────────────────

  upsertSkill(skill: Skill): Skill {
    this.db.run(
      `INSERT INTO skills (id, name, description, prompt, vendor_hint, built_in)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         description = excluded.description,
         prompt = excluded.prompt,
         vendor_hint = excluded.vendor_hint`,
      skill.id,
      skill.name,
      skill.description,
      skill.prompt,
      skill.vendorHint,
      skill.builtIn ? 1 : 0,
    )
    return skill
  }

  listSkills(): Skill[] {
    return this.db.all(`SELECT * FROM skills ORDER BY built_in DESC, name ASC`).map((row): Skill => ({
      id: str(row['id']),
      name: str(row['name']),
      description: str(row['description']),
      prompt: str(row['prompt']),
      vendorHint: nullableStr(row['vendor_hint']) as Skill['vendorHint'],
      builtIn: num(row['built_in']) === 1,
    }))
  }

  getSkill(id: Id): Skill | null {
    const row = this.db.get(`SELECT * FROM skills WHERE id = ?`, id)
    if (!row) return null
    return {
      id: str(row['id']),
      name: str(row['name']),
      description: str(row['description']),
      prompt: str(row['prompt']),
      vendorHint: nullableStr(row['vendor_hint']) as Skill['vendorHint'],
      builtIn: num(row['built_in']) === 1,
    }
  }
}
