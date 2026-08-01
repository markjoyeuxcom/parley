import { newId } from '@main/util/ids'
import type { RemoteTarget } from '@shared/remote'
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
  type BacklogEvent,
  type BacklogEventKind,
  type BacklogEventSource,
  type BacklogItem,
  type BacklogItemSource,
  type BacklogItemState,
  type FindingPriority,
  type ForemanDeferral,
  type ForemanProposal,
  type ForemanProposalState,
  type Interjection,
  type InterjectionTarget,
  type Learning,
  type Loop,
  type LoopIteration,
  type LedgerFinding,
  MilestoneRunState,
  type Milestone,
  type MilestoneStatus,
  type Mutation,
  type MutationResult,
  type ScoreDimension,
  type SelfUpdate,
  type SelfUpdateState,
  type Session,
  type SessionDeletionImpact,
  type SessionStatus,
  type Skill,
  type TestResult,
  type Turn,
  type Usage,
  type Vendor,
  type Verdict,
  type Acceptance,
  type AppJourney,
  type Envelope,
  type Workspace,
  type WorkPlan,
  type Worktree,
} from '@shared/domain'
import { findingIdentity, normaliseFindingText, sha256 } from '@shared/ledger'
import type { RepoSummary } from '@shared/ipc'
import { canonicalRepoPath } from '@main/util/repoPath'
import type { Db, Row } from './db'

/**
 * Re-exported from a dependency leaf so the execution core can mint an id
 * without importing the persistence layer — and through it, the schemas and
 * their validator. One definition, two doors.
 */
export { newId }

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

/**
 * Backlog dedupe identity: the ledger's own normalisation over title and
 * detail — never a new normalisation, and never title-only, because two
 * distinct findings sharing a generic title must not collapse into one item.
 */
function backlogContentHash(title: string, detail: string): string {
  return sha256(`${normaliseFindingText(title)}\0${normaliseFindingText(detail)}`)
}

/** Who the trail says acted, derived from where the item came from. */
function backlogEventSource(source: BacklogItemSource): BacklogEventSource {
  if (source === 'stow') return 'stow'
  // A note written while accepting is the human's own words, not the
  // pipeline's observation — the event log has to say which it was.
  if (source === 'manual' || source === 'acceptance') return 'human'
  return 'pipeline'
}

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

export interface DurableRepoAttention {
  sessions: Session[]
  loops: Loop[]
  plans: WorkPlan[]
  foreman: ForemanProposal[]
  selfUpdates: Array<{ update: SelfUpdate; plan: WorkPlan }>
}

/**
 * Typed access to the local database.
 *
 * Row-to-domain mapping lives here and nowhere else, so the shape of a table is
 * only known to this file.
 */
export class Repo {
  constructor(private readonly db: Db) {}

  // ─── Repository activity and archives ─────────────────────────────────────

  /**
   * Appends one repository activity watermark. Deliberately a bare statement:
   * callers own the transaction that pairs it with the write being recorded.
   */
  noteRepoActivity(path: string, _source?: 'backlog' | 'milestone'): void {
    this.db.run(
      `INSERT INTO repo_activity (seq, repo_path)
       VALUES ((SELECT COALESCE(MAX(seq), 0) + 1 FROM repo_activity), ?)`,
      canonicalRepoPath(path),
    )
  }

  repoActivitySeq(path: string): number {
    const row = this.db.get(
      `SELECT COALESCE(MAX(seq), 0) AS seq FROM repo_activity WHERE repo_path = ?`,
      canonicalRepoPath(path),
    )
    return num(row?.['seq'])
  }

  archiveRepo(path: string): void {
    const repoPath = canonicalRepoPath(path)
    this.db.transaction(() => {
      const seq = this.repoActivitySeq(path)
      this.db.run(
        `INSERT INTO repo_archives (repo_path, archived_seq) VALUES (?, ?)
         ON CONFLICT(repo_path) DO UPDATE SET archived_seq = excluded.archived_seq`,
        repoPath,
        seq,
      )
    })
  }

  restoreRepo(path: string): void {
    this.noteRepoActivity(path)
  }

  /**
   * Records the repository's standing dev-container choice. Plans and loops
   * snapshot this at creation — the row governs future work only, never work
   * an approval already covered.
   */
  setRepoContainer(path: string, enabled: boolean): void {
    this.db.transaction(() => {
      this.db.run(
        `INSERT INTO repo_containers (repo_path, enabled, decided_at) VALUES (?, ?, ?)
         ON CONFLICT(repo_path) DO UPDATE SET enabled = excluded.enabled, decided_at = excluded.decided_at`,
        canonicalRepoPath(path),
        enabled ? 1 : 0,
        Date.now(),
      )
      this.noteRepoActivity(path)
    })
  }

  getRepoContainer(path: string): boolean {
    const row = this.db.get(
      `SELECT enabled FROM repo_containers WHERE repo_path = ?`,
      canonicalRepoPath(path),
    )
    return num(row?.['enabled']) === 1
  }

  archivedRepoPaths(): string[] {
    return this.db
      .all<{ repoPath: string; archivedSeq: number }>(
        `SELECT repo_path AS repoPath, archived_seq AS archivedSeq
         FROM repo_archives ORDER BY repo_path ASC`,
      )
      .filter((archive) => archive.archivedSeq >= this.repoActivitySeq(archive.repoPath))
      .map((archive) => archive.repoPath)
  }

  /**
   * Every durable row that says work is live for one repository. These reads
   * are intentionally uncapped: archive safety cannot inherit the 200-row
   * presentation limits used by the session, plan, and loop lists.
   */
  liveAttentionForRepo(path: string): DurableRepoAttention {
    const canonical = canonicalRepoPath(path)
    const belongsToRepo = (repoPath: string): boolean =>
      canonicalRepoPath(repoPath) === canonical

    const sessions = this.db
      .all(`SELECT * FROM sessions WHERE status IN ('running', 'paused', 'stopping')`)
      .map((row) => this.toSession(row))
      .filter((session) => session.repoPath !== null && belongsToRepo(session.repoPath))
    const loops = this.db
      .all(`SELECT * FROM loops WHERE status IN ('running', 'paused')`)
      .map((row) => this.toLoop(row))
      .filter((loop) => belongsToRepo(loop.repoPath))
    const plans = this.db
      .all(`SELECT * FROM plans WHERE status IN ('drafting', 'auditing', 'correcting', 'running')`)
      .map((row) => this.toPlan(row))
      .filter((plan) => belongsToRepo(plan.repoPath))
    const foreman = this.db
      .all(`SELECT * FROM foreman_proposals WHERE state IN ('running', 'proposed')`)
      .map((row) => this.toForemanProposal(row))
      .filter((proposal) => belongsToRepo(proposal.repoPath))
    const selfUpdates = this.db
      .all<{ updateId: string; planId: string }>(
        `SELECT self_updates.id AS updateId, self_updates.plan_id AS planId
         FROM self_updates
         JOIN plans ON plans.id = self_updates.plan_id
         WHERE self_updates.state IN ('running', 'green')`,
      )
      .flatMap((row) => {
        const update = this.getSelfUpdate(row.updateId)
        const plan = this.getPlan(row.planId)
        return update && plan && belongsToRepo(plan.repoPath) ? [{ update, plan }] : []
      })

    return { sessions, loops, plans, foreman, selfUpdates }
  }

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
      const sessionRepos = this.db
        .all(`SELECT repo_path FROM sessions WHERE status IN ('running', 'paused', 'stopping')`)
        .map((row) => nullableStr(row['repo_path']))
        .filter((path): path is string => path !== null)
      const loopRepos = this.db
        .all(`SELECT repo_path FROM loops WHERE status IN ('running', 'paused')`)
        .map((row) => str(row['repo_path']))
      const planRepos = this.db
        .all(
          `SELECT repo_path FROM plans
           WHERE status IN ('drafting', 'auditing', 'correcting', 'running')`,
        )
        .map((row) => str(row['repo_path']))
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

      for (const repoPath of [...sessionRepos, ...loopRepos, ...planRepos]) {
        this.noteRepoActivity(repoPath)
      }
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
    return this.db.transaction(() => {
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
      if (session.repoPath) this.noteRepoActivity(session.repoPath)
      return session
    })
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
    return this.db.transaction(() => {
      const session = this.getSession(id)
      if (!session) throw new Error('no such session')
      const archivedAt = archived ? Date.now() : null
      this.db.run(
        `UPDATE sessions SET archived_at = ? WHERE id = ?`,
        archivedAt,
        id,
      )
      if (session.repoPath) this.noteRepoActivity(session.repoPath)
      return { ...session, archivedAt }
    })
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
      pendingForemanProposals: count(
        `SELECT COUNT(*) AS n FROM foreman_proposals WHERE anchor_session_id = ? AND state = 'proposed'`,
      ),
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
      const sessionRepoPath = nullableStr(
        this.db.get(`SELECT repo_path FROM sessions WHERE id = ?`, id)?.['repo_path'],
      )
      for (const plan of this.db.all(`SELECT id, repo_path FROM plans WHERE session_id = ?`, id)) {
        const planId = str(plan['id'])
        this.db.run(`DELETE FROM milestones WHERE plan_id = ?`, planId)
        this.db.run(`DELETE FROM plans WHERE id = ?`, planId)
        this.noteRepoActivity(str(plan['repo_path']))
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
      if (sessionRepoPath) this.noteRepoActivity(sessionRepoPath)
    })
  }

  setSessionStatus(id: Id, status: SessionStatus, error?: string | null): void {
    this.db.transaction(() => {
      const row = this.db.get(`SELECT repo_path FROM sessions WHERE id = ?`, id)
      const terminal = status === 'complete' || status === 'failed' || status === 'cancelled'
      const changes = this.db.run(
        `UPDATE sessions SET status = ?, error = ?, ended_at = ? WHERE id = ?`,
        status,
        error ?? null,
        terminal ? Date.now() : null,
        id,
      ).changes
      const repoPath = nullableStr(row?.['repo_path'])
      if (changes === 1 && repoPath) this.noteRepoActivity(repoPath)
    })
  }

  addSessionUsage(id: Id, delta: Usage): Usage {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT usage, repo_path FROM sessions WHERE id = ?`, id)
      const total = addUsage(parseJson<Usage>(row?.['usage'], emptyUsage()), delta)
      const changes = this.db.run(`UPDATE sessions SET usage = ? WHERE id = ?`, json(total), id).changes
      const repoPath = nullableStr(row?.['repo_path'])
      if (changes === 1 && repoPath) this.noteRepoActivity(repoPath)
      return total
    })
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

  // ─── Backlog and learnings ─────────────────────────────────────────────────
  // The per-repository record of work worth remembering. Repo paths are
  // canonicalised at this boundary only; the transition method is the single
  // choke point that keeps the state column and the append-only trail in
  // agreement.

  /**
   * Files an item, deduplicating by content against *live* items only — a
   * collision with a live item appends a `resighted` event rather than doing
   * nothing, because silence there is the failure mode. A terminal item never
   * blocks a genuine recurrence from filing fresh, with one carve-out: the
   * SAME origin session replaying the same content is not a recurrence, it is
   * an ingestion replay (the startup back-sweep, a repeated stow), and it is
   * silently idempotent. Without the carve-out every relaunch resurrected
   * every closed finding — done items re-filed as open, forever.
   */
  fileBacklogItem(input: {
    repoPath: string
    title: string
    detail?: string
    priority?: FindingPriority | null
    source: BacklogItemSource
    originSessionId?: Id | null
    /** The acceptance whose note filed this. Provenance, not a foreign key. */
    originAcceptanceId?: Id | null
    evidence?: Evidence[]
    mock: boolean
    /** Stow files `proposed`; deterministic sources file `open`. */
    state?: 'proposed' | 'open'
    note?: string
  }): { item: BacklogItem; resighted: boolean } {
    return this.db.transaction(() => this.fileBacklogItemCore(input))
  }

  /**
   * The filing itself, without opening a transaction.
   *
   * Exists so a caller that is ALREADY in one — recording an acceptance and
   * its notes together — can file without nesting, which SQLite refuses. The
   * createPlanCore precedent.
   */
  private fileBacklogItemCore(input: {
    repoPath: string
    title: string
    detail?: string
    priority?: FindingPriority | null
    source: BacklogItemSource
    originSessionId?: Id | null
    originAcceptanceId?: Id | null
    evidence?: Evidence[]
    mock: boolean
    state?: 'proposed' | 'open'
    note?: string
  }): { item: BacklogItem; resighted: boolean } {
    const repoPath = canonicalRepoPath(input.repoPath)
    const contentHash = backlogContentHash(input.title, input.detail ?? '')
    const eventSource = backlogEventSource(input.source)

    return (() => {
      const live = this.db.get(
        `SELECT * FROM backlog_items
         WHERE repo_path = ? AND content_hash = ?
           AND state IN ('proposed', 'open', 'planned', 'closure-proposed')
         LIMIT 1`,
        repoPath,
        contentHash,
      )
      if (live) {
        const item = this.toBacklogItem(live)
        this.appendBacklogEvent(
          item.id,
          'resighted',
          input.note ?? `Raised again (${input.source}).`,
          eventSource,
        )
        return { item, resighted: true }
      }

      // Only terminal rows can match here — a live one was caught above. No
      // resight event is appended: nothing new was observed, and stamping a
      // settled trail on every replay is its own kind of spam.
      if (input.originSessionId) {
        const sameOrigin = this.db.get(
          `SELECT * FROM backlog_items
           WHERE repo_path = ? AND content_hash = ? AND origin_session_id = ?
           LIMIT 1`,
          repoPath,
          contentHash,
          input.originSessionId,
        )
        if (sameOrigin) {
          return { item: this.toBacklogItem(sameOrigin), resighted: true }
        }
      }

      const now = Date.now()
      const state = input.state ?? 'open'
      const item: BacklogItem = {
        id: newId(),
        repoPath,
        contentHash,
        title: input.title,
        detail: input.detail ?? '',
        priority: input.priority ?? null,
        state,
        source: input.source,
        originSessionId: input.originSessionId ?? null,
        originAcceptanceId: input.originAcceptanceId ?? null,
        planId: null,
        evidence: input.evidence ?? [],
        blockedBy: [],
        mock: input.mock,
        createdAt: now,
        updatedAt: now,
      }
      this.db.run(
        `INSERT INTO backlog_items (id, repo_path, content_hash, title, detail, priority, state, source, origin_session_id, origin_acceptance_id, plan_id, evidence, blocked_by, mock, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        item.id,
        item.repoPath,
        item.contentHash,
        item.title,
        item.detail,
        item.priority,
        item.state,
        item.source,
        item.originSessionId,
        item.originAcceptanceId,
        item.planId,
        json(item.evidence),
        json(item.blockedBy),
        item.mock ? 1 : 0,
        item.createdAt,
        item.updatedAt,
      )
      this.appendBacklogEvent(item.id, state, input.note ?? `Filed (${input.source}).`, eventSource)
      return { item, resighted: false }
    })()
  }

  /**
   * The single legal-transition choke point: validates the move, updates the
   * column, appends the event — one transaction, so the trail always folds to
   * the column (a pinned test). `planned` requires the targeting plan;
   * reopening clears it, or a dead plan completing later would
   * closure-propose an item since re-targeted elsewhere.
   */
  transitionBacklogItem(
    id: Id,
    to: Exclude<BacklogItemState, 'proposed'>,
    opts: { source: BacklogEventSource; note?: string; planId?: Id },
  ): BacklogItem {
    return this.db.transaction(() => this.transitionBacklogItemCore(id, to, opts))
  }

  /**
   * The transition body without its transaction, so composite writes —
   * {@link bindPlanCreation} — can run it inside their own. The wrapper above
   * is the public face; transactions here do not nest.
   */
  private transitionBacklogItemCore(
    id: Id,
    to: Exclude<BacklogItemState, 'proposed'>,
    opts: { source: BacklogEventSource; note?: string; planId?: Id },
  ): BacklogItem {
    const LEGAL: Record<BacklogItemState, ReadonlyArray<BacklogItemState>> = {
      proposed: ['open', 'dropped'],
      // open → done directly: work verified as already delivered — by a
      // foreman read, or done outside Parley — must be closable as done.
      // Forcing it through `dropped` records "won't do" against work that
      // was in fact done, and the trail would lie about the outcome.
      open: ['planned', 'done', 'dropped'],
      planned: ['closure-proposed', 'open'],
      'closure-proposed': ['done', 'open'],
      done: [],
      dropped: [],
    }
    const row = this.db.get(`SELECT * FROM backlog_items WHERE id = ?`, id)
    if (!row) throw new Error('no such backlog item')
    const item = this.toBacklogItem(row)
    if (!LEGAL[item.state].includes(to)) {
      throw new Error(`a ${item.state} backlog item cannot become ${to}`)
    }
    let planId = item.planId
    if (to === 'planned') {
      if (!opts.planId) throw new Error('planning a backlog item requires the plan id')
      planId = opts.planId
    } else if (to === 'open') {
      planId = null
    }
    const now = Date.now()
    this.db.run(
      `UPDATE backlog_items SET state = ?, plan_id = ?, updated_at = ? WHERE id = ?`,
      to,
      planId,
      now,
      id,
    )
    this.appendBacklogEvent(id, to, opts.note ?? '', opts.source)
    const updated = this.db.get(`SELECT * FROM backlog_items WHERE id = ?`, id)
    if (!updated) throw new Error('backlog item disappeared mid-transition')
    return this.toBacklogItem(updated)
  }

  /**
   * Blockers must exist, share the item's repository, and stay acyclic.
   * Terminal blockers are left in place — reads treat them as inert, so a
   * resolved blocker stops blocking without anyone editing this list.
   */
  setBacklogBlockedBy(id: Id, blockedBy: Id[]): BacklogItem {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM backlog_items WHERE id = ?`, id)
      if (!row) throw new Error('no such backlog item')
      const item = this.toBacklogItem(row)

      const unique = [...new Set(blockedBy)]
      for (const blockerId of unique) {
        if (blockerId === id) throw new Error('an item cannot block itself')
        const blocker = this.getBacklogItem(blockerId)
        if (!blocker) throw new Error(`no such blocking item: ${blockerId}`)
        if (blocker.repoPath !== item.repoPath) {
          throw new Error('blockers must belong to the same repository')
        }
      }
      // Cycle check: from each proposed blocker, can we walk back to `id`?
      const visit = (fromId: Id, seen: Set<Id>): boolean => {
        if (fromId === id) return true
        if (seen.has(fromId)) return false
        seen.add(fromId)
        const from = this.getBacklogItem(fromId)
        return (from?.blockedBy ?? []).some((next) => visit(next, seen))
      }
      if (unique.some((blockerId) => visit(blockerId, new Set()))) {
        throw new Error('that dependency would create a cycle')
      }

      this.db.run(
        `UPDATE backlog_items SET blocked_by = ?, updated_at = ? WHERE id = ?`,
        json(unique),
        Date.now(),
        id,
      )
      this.noteRepoActivity(item.repoPath)
      const updated = this.db.get(`SELECT * FROM backlog_items WHERE id = ?`, id)
      if (!updated) throw new Error('backlog item disappeared')
      return this.toBacklogItem(updated)
    })
  }

  getBacklogItem(id: Id): BacklogItem | null {
    const row = this.db.get(`SELECT * FROM backlog_items WHERE id = ?`, id)
    return row ? this.toBacklogItem(row) : null
  }

  listBacklogItems(filter: { repoPath?: string; states?: BacklogItemState[] } = {}): BacklogItem[] {
    const where: string[] = []
    const params: unknown[] = []
    if (filter.repoPath) {
      where.push('repo_path = ?')
      params.push(canonicalRepoPath(filter.repoPath))
    }
    if (filter.states?.length) {
      where.push(`state IN (${filter.states.map(() => '?').join(', ')})`)
      params.push(...filter.states)
    }
    const clause = where.length ? ` WHERE ${where.join(' AND ')}` : ''
    return this.db
      .all(`SELECT * FROM backlog_items${clause} ORDER BY created_at DESC, id ASC`, ...params)
      .map((r) => this.toBacklogItem(r))
  }

  distinctBacklogRepos(): string[] {
    return this.db
      .all(`SELECT DISTINCT repo_path FROM backlog_items ORDER BY repo_path ASC`)
      .map((row) => str(row['repo_path']))
  }

  listBacklogEvents(itemId: Id): BacklogEvent[] {
    return this.db
      .all(`SELECT * FROM backlog_events WHERE item_id = ? ORDER BY seq ASC`, itemId)
      .map((r) => this.toBacklogEvent(r))
  }

  private appendBacklogEvent(
    itemId: Id,
    kind: BacklogEventKind,
    note: string,
    source: BacklogEventSource,
  ): void {
    this.db.run(
      `INSERT INTO backlog_events (id, item_id, kind, note, source, seq, created_at)
       VALUES (?, ?, ?, ?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM backlog_events), ?)`,
      newId(),
      itemId,
      kind,
      note,
      source,
      Date.now(),
    )
    this.noteRepoActivity(this.repoPathForItem(itemId), 'backlog')
  }

  private repoPathForItem(itemId: Id): string {
    const row = this.db.get(`SELECT repo_path FROM backlog_items WHERE id = ?`, itemId)
    if (!row) throw new Error('no such backlog item')
    return str(row['repo_path'])
  }

  /** Live-duplicate check is exact text; learnings are short and curated. */
  fileLearning(input: {
    repoPath: string
    text: string
    source: Learning['source']
    originSessionId?: Id | null
    mock: boolean
    /** Stow files `proposed`; manual entries are already human-confirmed. */
    state?: 'proposed' | 'confirmed'
  }): { learning: Learning; duplicate: boolean } {
    const repoPath = canonicalRepoPath(input.repoPath)
    return this.db.transaction(() => {
      const live = this.db.get(
        `SELECT * FROM learnings WHERE repo_path = ? AND text = ? AND state != 'retired' LIMIT 1`,
        repoPath,
        input.text,
      )
      if (live) return { learning: this.toLearning(live), duplicate: true }

      const learning: Learning = {
        id: newId(),
        repoPath,
        text: input.text,
        state: input.state ?? (input.source === 'manual' ? 'confirmed' : 'proposed'),
        source: input.source,
        originSessionId: input.originSessionId ?? null,
        mock: input.mock,
        createdAt: Date.now(),
      }
      this.db.run(
        `INSERT INTO learnings (id, repo_path, text, state, source, origin_session_id, mock, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        learning.id,
        learning.repoPath,
        learning.text,
        learning.state,
        learning.source,
        learning.originSessionId,
        learning.mock ? 1 : 0,
        learning.createdAt,
      )
      this.noteRepoActivity(learning.repoPath)
      return { learning, duplicate: false }
    })
  }

  transitionLearning(id: Id, to: 'confirmed' | 'retired'): Learning {
    return this.db.transaction(() => {
      const LEGAL: Record<Learning['state'], ReadonlyArray<Learning['state']>> = {
        proposed: ['confirmed', 'retired'],
        confirmed: ['retired'],
        retired: [],
      }
      const row = this.db.get(`SELECT * FROM learnings WHERE id = ?`, id)
      if (!row) throw new Error('no such learning')
      const learning = this.toLearning(row)
      if (!LEGAL[learning.state].includes(to)) {
        throw new Error(`a ${learning.state} learning cannot become ${to}`)
      }
      this.db.run(`UPDATE learnings SET state = ? WHERE id = ?`, to, id)
      this.noteRepoActivity(learning.repoPath)
      return { ...learning, state: to }
    })
  }

  listLearnings(filter: { repoPath?: string; states?: Array<Learning['state']> } = {}): Learning[] {
    const where: string[] = []
    const params: unknown[] = []
    if (filter.repoPath) {
      where.push('repo_path = ?')
      params.push(canonicalRepoPath(filter.repoPath))
    }
    if (filter.states?.length) {
      where.push(`state IN (${filter.states.map(() => '?').join(', ')})`)
      params.push(...filter.states)
    }
    const clause = where.length ? ` WHERE ${where.join(' AND ')}` : ''
    return this.db
      .all(`SELECT * FROM learnings${clause} ORDER BY created_at DESC, id ASC`, ...params)
      .map((r) => this.toLearning(r))
  }

  private toBacklogItem(row: Row): BacklogItem {
    return {
      id: str(row['id']),
      repoPath: str(row['repo_path']),
      contentHash: str(row['content_hash']),
      title: str(row['title']),
      detail: str(row['detail']),
      priority: nullableStr(row['priority']) as BacklogItem['priority'],
      state: str(row['state']) as BacklogItemState,
      source: str(row['source']) as BacklogItemSource,
      originSessionId: nullableStr(row['origin_session_id']),
      originAcceptanceId: nullableStr(row['origin_acceptance_id']),
      planId: nullableStr(row['plan_id']),
      evidence: parseJson<BacklogItem['evidence']>(row['evidence'], []),
      blockedBy: parseJson<Id[]>(row['blocked_by'], []),
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
      updatedAt: num(row['updated_at']),
    }
  }

  private toBacklogEvent(row: Row): BacklogEvent {
    return {
      id: str(row['id']),
      itemId: str(row['item_id']),
      kind: str(row['kind']) as BacklogEventKind,
      note: str(row['note']),
      source: str(row['source']) as BacklogEventSource,
      seq: num(row['seq']),
      createdAt: num(row['created_at']),
    }
  }

  private toLearning(row: Row): Learning {
    return {
      id: str(row['id']),
      repoPath: str(row['repo_path']),
      text: str(row['text']),
      state: str(row['state']) as Learning['state'],
      source: str(row['source']) as Learning['source'],
      originSessionId: nullableStr(row['origin_session_id']),
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
    }
  }

  // ─── Foreman proposals ─────────────────────────────────────────────────────

  /**
   * Files a `running` attempt before the agent turn dispatches, so an
   * interrupted run is a recorded fact rather than a vanished spend. Never
   * supersedes anything — only a successful finalize may, because a mere
   * attempt must not clobber a valid pending proposal.
   */
  fileForemanAttempt(input: {
    repoPath: string
    vendor: Vendor
    mock: boolean
    openSnapshot: Id[]
  }): ForemanProposal {
    const attempt: ForemanProposal = {
      id: newId(),
      repoPath: canonicalRepoPath(input.repoPath),
      state: 'running',
      title: '',
      rationale: '',
      itemIds: [],
      deferred: [],
      openSnapshot: [...input.openSnapshot],
      isolation: 'worktree',
      note: '',
      anchorSessionId: null,
      planId: null,
      vendor: input.vendor,
      usage: emptyUsage(),
      mock: input.mock,
      createdAt: Date.now(),
      decidedAt: null,
      decisionNote: '',
    }
    return this.db.transaction(() => {
      this.db.run(
        `INSERT INTO foreman_proposals (id, repo_path, state, title, rationale, item_ids, deferred, open_snapshot, isolation, note, anchor_session_id, plan_id, vendor, usage, mock, created_at, decided_at, decision_note)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        attempt.id,
        attempt.repoPath,
        attempt.state,
        attempt.title,
        attempt.rationale,
        json(attempt.itemIds),
        json(attempt.deferred),
        json(attempt.openSnapshot),
        attempt.isolation,
        attempt.note,
        attempt.anchorSessionId,
        attempt.planId,
        attempt.vendor,
        json(attempt.usage),
        attempt.mock ? 1 : 0,
        attempt.createdAt,
        attempt.decidedAt,
        attempt.decisionNote,
      )
      this.noteRepoActivity(attempt.repoPath)
      return attempt
    })
  }

  /**
   * Ends an attempt. The `proposed` arm supersedes prior same-mock pendings
   * for the repository here, in this transaction — the one moment a new read
   * replaces an old one. The `failed` arm records the error and the spend and
   * touches nothing else.
   */
  finalizeForemanAttempt(
    id: Id,
    outcome:
      | {
          state: 'proposed'
          title: string
          rationale: string
          itemIds: Id[]
          deferred: ForemanDeferral[]
          isolation: WorkPlan['isolation']
          note: string
          anchorSessionId: Id
          usage: Usage
          /** Honest validation drops ("2 named items were unknown"), if any. */
          decisionNote?: string
        }
      | {
          state: 'failed'
          error: string
          usage: Usage
          /**
           * What the read produced before it failed to select. An honest
           * "nothing to plan — these are done" still burns a read, and its
           * per-item reasoning is the substance a human acts on; discarding
           * it made a second (equally failing) ask the only way to see it.
           */
          rationale?: string
          deferred?: ForemanDeferral[]
        },
  ): ForemanProposal {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM foreman_proposals WHERE id = ?`, id)
      if (!row) throw new Error('no such foreman attempt')
      const attempt = this.toForemanProposal(row)
      if (attempt.state !== 'running') {
        throw new Error(`a ${attempt.state} foreman attempt cannot be finalized`)
      }
      const now = Date.now()
      if (outcome.state === 'failed') {
        this.db.run(
          `UPDATE foreman_proposals SET state = 'failed', usage = ?, decided_at = ?, decision_note = ?, rationale = ?, deferred = ? WHERE id = ?`,
          json(outcome.usage),
          now,
          outcome.error,
          outcome.rationale ?? '',
          json(outcome.deferred ?? []),
          id,
        )
      } else {
        this.db.run(
          `UPDATE foreman_proposals SET state = 'superseded', decided_at = ?, decision_note = 'Superseded by a newer run.'
           WHERE repo_path = ? AND state = 'proposed' AND mock = ? AND id != ?`,
          now,
          attempt.repoPath,
          attempt.mock ? 1 : 0,
          id,
        )
        this.db.run(
          `UPDATE foreman_proposals SET state = 'proposed', title = ?, rationale = ?, item_ids = ?, deferred = ?, isolation = ?, note = ?, anchor_session_id = ?, usage = ?, decision_note = ? WHERE id = ?`,
          outcome.title,
          outcome.rationale,
          json(outcome.itemIds),
          json(outcome.deferred),
          outcome.isolation,
          outcome.note,
          outcome.anchorSessionId,
          json(outcome.usage),
          outcome.decisionNote ?? '',
          id,
        )
      }
      this.noteRepoActivity(attempt.repoPath)
      const updated = this.db.get(`SELECT * FROM foreman_proposals WHERE id = ?`, id)
      if (!updated) throw new Error('foreman attempt disappeared mid-finalize')
      return this.toForemanProposal(updated)
    })
  }

  /** The one live proposal for a repository in the given mode, if any. */
  getPendingForemanProposal(repoPath: string, mock: boolean): ForemanProposal | null {
    const row = this.db.get(
      `SELECT * FROM foreman_proposals WHERE repo_path = ? AND state = 'proposed' AND mock = ?
       ORDER BY created_at DESC, id ASC LIMIT 1`,
      canonicalRepoPath(repoPath),
      mock ? 1 : 0,
    )
    return row ? this.toForemanProposal(row) : null
  }

  getForemanProposal(id: Id): ForemanProposal | null {
    const row = this.db.get(`SELECT * FROM foreman_proposals WHERE id = ?`, id)
    return row ? this.toForemanProposal(row) : null
  }

  listForemanProposals(
    filter: { repoPath?: string; states?: ForemanProposalState[] } = {},
  ): ForemanProposal[] {
    const where: string[] = []
    const params: unknown[] = []
    if (filter.repoPath) {
      where.push('repo_path = ?')
      params.push(canonicalRepoPath(filter.repoPath))
    }
    if (filter.states?.length) {
      where.push(`state IN (${filter.states.map(() => '?').join(', ')})`)
      params.push(...filter.states)
    }
    const clause = where.length ? ` WHERE ${where.join(' AND ')}` : ''
    return this.db
      .all(`SELECT * FROM foreman_proposals${clause} ORDER BY created_at DESC, id ASC`, ...params)
      .map((r) => this.toForemanProposal(r))
  }

  decideForemanProposal(
    id: Id,
    to: 'accepted' | 'rejected',
    opts: { planId?: Id; note?: string } = {},
  ): ForemanProposal {
    return this.db.transaction(() => this.decideForemanProposalCore(id, to, opts))
  }

  /** The decide body without its transaction — see {@link bindPlanCreation}. */
  private decideForemanProposalCore(
    id: Id,
    to: 'accepted' | 'rejected',
    opts: { planId?: Id; note?: string } = {},
  ): ForemanProposal {
    const row = this.db.get(`SELECT * FROM foreman_proposals WHERE id = ?`, id)
    if (!row) throw new Error('no such foreman proposal')
    const proposal = this.toForemanProposal(row)
    if (proposal.state !== 'proposed') {
      throw new Error(`a ${proposal.state} foreman proposal cannot become ${to}`)
    }
    if (to === 'accepted' && !opts.planId) {
      throw new Error('accepting a foreman proposal requires the plan it created')
    }
    this.db.run(
      `UPDATE foreman_proposals SET state = ?, plan_id = ?, decided_at = ?, decision_note = ? WHERE id = ?`,
      to,
      to === 'accepted' ? (opts.planId ?? null) : proposal.planId,
      Date.now(),
      opts.note ?? '',
      id,
    )
    this.noteRepoActivity(proposal.repoPath)
    const updated = this.db.get(`SELECT * FROM foreman_proposals WHERE id = ?`, id)
    if (!updated) throw new Error('foreman proposal disappeared mid-decide')
    return this.toForemanProposal(updated)
  }

  /**
   * Startup honesty for attempts the process did not live to finalize:
   * `running` rows become `failed`, and the pending proposal they never got
   * to supersede stays exactly as it was.
   */
  reconcileForemanAttempts(): number {
    return this.db.transaction(() => {
      const repoPaths = this.db
        .all(`SELECT repo_path FROM foreman_proposals WHERE state = 'running'`)
        .map((row) => str(row['repo_path']))
      const changes = this.db.run(
        `UPDATE foreman_proposals SET state = 'failed', decided_at = ?, decision_note = 'Interrupted when Parley last quit.'
         WHERE state = 'running'`,
        Date.now(),
      ).changes
      for (const repoPath of repoPaths) this.noteRepoActivity(repoPath)
      return changes
    })
  }

  /**
   * Plan creation as one durable act: the plan row, the selected items'
   * flips to `planned`, and — when the plan accepts a foreman proposal — the
   * acceptance stamp, in a single transaction. A crash cannot leave a plan
   * running while its proposal still reads pending, or items planned toward
   * a plan that was never written. The manual path passes `proposalId` null
   * and gets the same atomicity for its flips.
   */
  bindPlanCreation(plan: WorkPlan, itemIds: Id[], proposalId: Id | null): WorkPlan {
    return this.db.transaction(() => {
      this.createPlanCore(plan)
      for (const itemId of itemIds) {
        this.transitionBacklogItemCore(itemId, 'planned', {
          source: 'human',
          planId: plan.id,
          note: 'Selected for this plan at creation.',
        })
      }
      if (proposalId) {
        this.decideForemanProposalCore(proposalId, 'accepted', { planId: plan.id })
      }
      return plan
    })
  }

  // ─── App journeys ──────────────────────────────────────────────────────────

  createJourney(journey: AppJourney): AppJourney {
    this.db.run(
      `INSERT INTO app_journeys (id, name, brief, session_id, workspace_id, plan_id, harden_session_id, created_at, updated_at, mock)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      journey.id,
      journey.name,
      journey.brief,
      journey.sessionId,
      journey.workspaceId,
      journey.planId,
      journey.hardenSessionId,
      journey.createdAt,
      journey.updatedAt,
      journey.mock ? 1 : 0,
    )
    return journey
  }

  /**
   * Attaches what a stage produced. Only ever adds links and the brief —
   * there is no stage column to move, because the stage is derived.
   */
  updateJourney(
    id: Id,
    patch: Partial<Pick<AppJourney, 'name' | 'brief' | 'sessionId' | 'workspaceId' | 'planId' | 'hardenSessionId'>>,
  ): AppJourney {
    const fields: Record<string, string> = {
      name: 'name',
      brief: 'brief',
      sessionId: 'session_id',
      workspaceId: 'workspace_id',
      planId: 'plan_id',
      hardenSessionId: 'harden_session_id',
    }
    for (const [key, column] of Object.entries(fields)) {
      const value = (patch as Record<string, unknown>)[key]
      if (value === undefined) continue
      this.db.run(`UPDATE app_journeys SET ${column} = ? WHERE id = ?`, value as string | null, id)
    }
    this.db.run(`UPDATE app_journeys SET updated_at = ? WHERE id = ?`, Date.now(), id)
    const updated = this.getJourney(id)
    if (!updated) throw new Error(`journey ${id} disappeared`)
    return updated
  }

  getJourney(id: Id): AppJourney | null {
    const row = this.db.get(`SELECT * FROM app_journeys WHERE id = ?`, id)
    return row ? this.toJourney(row) : null
  }

  listJourneys(mock: boolean): AppJourney[] {
    return this.db
      .all(`SELECT * FROM app_journeys WHERE mock = ? ORDER BY created_at DESC`, mock ? 1 : 0)
      .map((row) => this.toJourney(row))
  }

  deleteJourney(id: Id): void {
    // The guide is scaffolding, not a record of work: everything it links to
    // — the debate, the project, the plan — is durable on its own and stays.
    this.db.run(`DELETE FROM app_journeys WHERE id = ?`, id)
  }

  private toJourney(row: Row): AppJourney {
    return {
      id: str(row['id']),
      name: str(row['name']),
      brief: str(row['brief']),
      sessionId: nullableStr(row['session_id']),
      workspaceId: nullableStr(row['workspace_id']),
      planId: nullableStr(row['plan_id']),
      hardenSessionId: nullableStr(row['harden_session_id']),
      createdAt: num(row['created_at']),
      updatedAt: num(row['updated_at']),
      mock: num(row['mock']) === 1,
    }
  }

  // ─── Acceptance ────────────────────────────────────────────────────────────

  /**
   * Records a human's judgement on completed work, and files whatever they
   * said needs changing — in ONE transaction.
   *
   * Atomic on purpose: an acceptance whose notes did not file would be a
   * record of feedback nobody can act on, and items filed without their
   * acceptance would be exactly the free-floating typing the backlog's
   * provenance rule exists to prevent. Either both happened or neither did.
   */
  recordAcceptance(input: {
    milestoneId: Id
    planId: Id
    repoPath: string
    state: Acceptance['state']
    note?: string
    /** One line each. Empty lines are the user's formatting, not items. */
    changes?: string[]
    mock: boolean
  }): { acceptance: Acceptance; items: BacklogItem[] } {
    return this.db.transaction(() => {
      const acceptance: Acceptance = {
        id: newId(),
        milestoneId: input.milestoneId,
        planId: input.planId,
        repoPath: canonicalRepoPath(input.repoPath),
        state: input.state,
        note: input.note ?? '',
        createdAt: Date.now(),
        mock: input.mock,
      }
      this.db.run(
        `INSERT INTO acceptances (id, milestone_id, plan_id, repo_path, state, note, created_at, mock)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        acceptance.id,
        acceptance.milestoneId,
        acceptance.planId,
        acceptance.repoPath,
        acceptance.state,
        acceptance.note,
        acceptance.createdAt,
        acceptance.mock ? 1 : 0,
      )

      const items: BacklogItem[] = []
      for (const line of input.changes ?? []) {
        const title = line.trim()
        if (!title) continue
        const { item } = this.fileBacklogItemCore({
          repoPath: acceptance.repoPath,
          title,
          source: 'acceptance',
          originAcceptanceId: acceptance.id,
          mock: input.mock,
          // A human's own words go straight to open: proposals exist because
          // an AGENT drafted them and a human had not yet agreed.
          state: 'open',
          note: 'Filed from your acceptance notes.',
        })
        items.push(item)
      }
      this.noteRepoActivity(acceptance.repoPath)
      return { acceptance, items }
    })
  }

  listAcceptancesForMilestone(milestoneId: Id): Acceptance[] {
    return this.db
      .all(
        `SELECT * FROM acceptances WHERE milestone_id = ? ORDER BY created_at DESC`,
        milestoneId,
      )
      .map((row) => this.toAcceptance(row))
  }

  listAcceptancesForPlan(planId: Id): Acceptance[] {
    return this.db
      .all(`SELECT * FROM acceptances WHERE plan_id = ? ORDER BY created_at DESC`, planId)
      .map((row) => this.toAcceptance(row))
  }

  private toAcceptance(row: Row): Acceptance {
    return {
      id: str(row['id']),
      milestoneId: str(row['milestone_id']),
      planId: str(row['plan_id']),
      repoPath: str(row['repo_path']),
      state: str(row['state']) as Acceptance['state'],
      note: str(row['note']),
      createdAt: num(row['created_at']),
      mock: num(row['mock']) === 1,
    }
  }

  // ─── Workspaces ────────────────────────────────────────────────────────────

  /* ── Remote execution targets ──────────────────────────────────────── */

  /**
   * Hosts Parley may execute on.
   *
   * Application-global rather than per-repository: a build host is somewhere
   * work MAY run, not a fact about any repository having been worked on. The
   * completeness guard classifies it out of scope for exactly that reason.
   */
  createRemoteTarget(target: RemoteTarget & { nodeCommand: string }): RemoteTarget {
    this.db.run(
      `INSERT INTO remote_targets (id, label, host, node_command, runs_root, created_at)
       VALUES (?, ?, ?, ?, ?, ?)`,
      target.id,
      target.label,
      target.host,
      target.nodeCommand,
      target.runsRoot,
      target.createdAt,
    )
    return target
  }

  listRemoteTargets(): Array<RemoteTarget & { nodeCommand: string }> {
    return this.db.all(`SELECT * FROM remote_targets ORDER BY created_at ASC`).map((row) => ({
      id: String(row.id),
      label: String(row.label),
      host: String(row.host),
      nodeCommand: String(row.node_command),
      runsRoot: String(row.runs_root),
      createdAt: Number(row.created_at),
    }))
  }

  getRemoteTarget(id: Id): (RemoteTarget & { nodeCommand: string }) | null {
    return this.listRemoteTargets().find((target) => target.id === id) ?? null
  }

  deleteRemoteTarget(id: Id): void {
    this.db.run(`DELETE FROM remote_targets WHERE id = ?`, id)
  }

  createWorkspace(workspace: Workspace): Workspace {
    return this.db.transaction(() => {
      this.db.run(
        `INSERT INTO workspaces (id, repo_path, name, template_id, state, detail, created_at, ready_at, mock)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        workspace.id,
        canonicalRepoPath(workspace.repoPath),
        workspace.name,
        workspace.templateId,
        workspace.state,
        workspace.detail,
        workspace.createdAt,
        workspace.readyAt,
        workspace.mock ? 1 : 0,
      )
      this.noteRepoActivity(workspace.repoPath)
      return workspace
    })
  }

  getWorkspace(id: Id): Workspace | null {
    const row = this.db.get(`SELECT * FROM workspaces WHERE id = ?`, id)
    return row ? this.toWorkspace(row) : null
  }

  getWorkspaceByPath(repoPath: string): Workspace | null {
    const row = this.db.get(
      `SELECT * FROM workspaces WHERE repo_path = ?`,
      canonicalRepoPath(repoPath),
    )
    return row ? this.toWorkspace(row) : null
  }

  listWorkspaces(): Workspace[] {
    return this.db
      .all(`SELECT * FROM workspaces ORDER BY created_at DESC`)
      .map((row) => this.toWorkspace(row))
  }

  /**
   * Settles a building workspace. Conditional on `building` for the same
   * reason envelopes are conditional on `running`: a startup reconcile and a
   * live builder must never both write an outcome.
   */
  settleWorkspace(id: Id, state: 'ready' | 'failed', detail: string): boolean {
    const result = this.db.run(
      `UPDATE workspaces SET state = ?, detail = ?, ready_at = ? WHERE id = ? AND state = 'building'`,
      state,
      detail,
      state === 'ready' ? Date.now() : null,
      id,
    )
    return result.changes === 1
  }

  /** A live process never startup-reconciles: `building` at boot was interrupted. */
  reconcileWorkspaces(): number {
    const result = this.db.run(
      `UPDATE workspaces SET state = 'failed', detail = ? WHERE state = 'building'`,
      'interrupted — the app stopped while this project was being created',
    )
    return result.changes
  }

  private toWorkspace(row: Row): Workspace {
    return {
      id: str(row['id']),
      repoPath: str(row['repo_path']),
      name: str(row['name']),
      templateId: str(row['template_id']),
      state: str(row['state']) as Workspace['state'],
      detail: str(row['detail']),
      createdAt: num(row['created_at']),
      readyAt: nullableNum(row['ready_at']),
      mock: num(row['mock']) === 1,
    }
  }

  // ─── Envelopes ─────────────────────────────────────────────────────────────

  createEnvelope(envelope: Envelope, repoPath: string): Envelope {
    return this.db.transaction(() => {
      this.db.run(
        `INSERT INTO envelopes (id, plan_id, state, caps, milestones_run, start_cost_usd, detail, started_at, ended_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        envelope.id,
        envelope.planId,
        envelope.state,
        json(envelope.caps),
        envelope.milestonesRun,
        envelope.startCostUsd,
        envelope.detail,
        envelope.startedAt,
        envelope.endedAt,
      )
      this.noteRepoActivity(repoPath)
      return envelope
    })
  }

  getEnvelope(id: Id): Envelope | null {
    const row = this.db.get(`SELECT * FROM envelopes WHERE id = ?`, id)
    return row ? this.toEnvelope(row) : null
  }

  getActiveEnvelopeForPlan(planId: Id): Envelope | null {
    const row = this.db.get(
      `SELECT * FROM envelopes WHERE plan_id = ? AND state = 'running' ORDER BY started_at DESC LIMIT 1`,
      planId,
    )
    return row ? this.toEnvelope(row) : null
  }

  listEnvelopesForPlan(planId: Id): Envelope[] {
    return this.db
      .all(`SELECT * FROM envelopes WHERE plan_id = ? ORDER BY started_at DESC`, planId)
      .map((row) => this.toEnvelope(row))
  }

  /** Every running envelope, for the in-flight view and the startup sweep. */
  listActiveEnvelopes(): Envelope[] {
    return this.db
      .all(`SELECT * FROM envelopes WHERE state = 'running' ORDER BY started_at ASC`)
      .map((row) => this.toEnvelope(row))
  }

  /**
   * Ends a running envelope. The conditional update is the discipline: only
   * `running` can settle, so a crash-reconcile and a live driver can never
   * both write an ending — the same shape as approval consumption.
   */
  settleEnvelope(
    id: Id,
    state: 'parked' | 'exhausted' | 'finished' | 'cancelled',
    detail: string,
  ): boolean {
    const result = this.db.run(
      `UPDATE envelopes SET state = ?, detail = ?, ended_at = ? WHERE id = ? AND state = 'running'`,
      state,
      detail,
      Date.now(),
      id,
    )
    return result.changes === 1
  }

  /** Records one more minted milestone execution on the running envelope. */
  bumpEnvelopeMilestones(id: Id): void {
    this.db.run(
      `UPDATE envelopes SET milestones_run = milestones_run + 1 WHERE id = ? AND state = 'running'`,
      id,
    )
  }

  /**
   * A live process never startup-reconciles: any envelope still `running` at
   * boot was interrupted, and the honest record is a park — the milestone
   * beneath it has its own preserved run state and recovery controls.
   */
  reconcileEnvelopes(): number {
    const result = this.db.run(
      `UPDATE envelopes SET state = 'parked', detail = ?, ended_at = ?
       WHERE state = 'running'`,
      'interrupted — the app stopped while this envelope was running',
      Date.now(),
    )
    return result.changes
  }

  private toEnvelope(row: Row): Envelope {
    return {
      id: str(row['id']),
      planId: str(row['plan_id']),
      state: str(row['state']) as Envelope['state'],
      caps: parseJson<Envelope['caps']>(row['caps'], {
        maxMilestones: 1,
        maxWallClockMs: 60_000,
        maxSpendUsd: 0,
      }),
      milestonesRun: num(row['milestones_run']),
      startCostUsd: num(row['start_cost_usd']),
      detail: str(row['detail']),
      startedAt: num(row['started_at']),
      endedAt: nullableNum(row['ended_at']),
    }
  }

  // ─── Self-updates ──────────────────────────────────────────────────────────

  /**
   * Opens a gate attempt for a landed plan. Older green rows are superseded
   * here, in the same transaction — the moment a new gate can touch out/, no
   * stale "verified" offer may survive it: a later failed build would
   * otherwise leave a green hold pointing at half-written bytes.
   */
  fileSelfUpdateAttempt(planId: Id): SelfUpdate {
    return this.db.transaction(() => {
      const now = Date.now()
      this.db.run(
        `UPDATE self_updates SET state = 'superseded', decided_at = ?,
           detail = 'Superseded: a newer landing started its own gate.'
         WHERE state = 'green'`,
        now,
      )
      const attempt: SelfUpdate = {
        id: newId(),
        planId,
        state: 'running',
        detail: '',
        createdAt: now,
        decidedAt: null,
      }
      this.db.run(
        `INSERT INTO self_updates (id, plan_id, state, detail, created_at, decided_at)
         VALUES (?, ?, ?, ?, ?, ?)`,
        attempt.id,
        attempt.planId,
        attempt.state,
        attempt.detail,
        attempt.createdAt,
        attempt.decidedAt,
      )
      return attempt
    })
  }

  /**
   * Retires one green offer when its gate finished after another landing had
   * already queued a follow-up. Targeting the observed row matters: the
   * follow-up has not filed yet, and must not be able to supersede anything
   * else if filing later fails.
   */
  supersedeSelfUpdate(id: Id): SelfUpdate {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!row) throw new Error('no such self-update')
      const attempt = this.toSelfUpdate(row)
      if (attempt.state !== 'green') {
        throw new Error(`a ${attempt.state} self-update cannot be superseded`)
      }
      this.db.run(
        `UPDATE self_updates SET state = 'superseded', decided_at = ?,
           detail = 'Superseded: a landing queued while this gate was running.'
         WHERE id = ?`,
        Date.now(),
        id,
      )
      const updated = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!updated) throw new Error('self-update disappeared mid-supersede')
      return this.toSelfUpdate(updated)
    })
  }

  /**
   * Ends a gate run. Green stays undecided (decided_at null) — that absence
   * is what "awaiting the human" means, and the hold derives from it. Red is
   * terminal, so it takes its decision stamp here.
   */
  finalizeSelfUpdate(id: Id, state: 'green' | 'red', detail: string): SelfUpdate {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!row) throw new Error('no such self-update attempt')
      const attempt = this.toSelfUpdate(row)
      if (attempt.state !== 'running') {
        throw new Error(`a ${attempt.state} self-update attempt cannot be finalized`)
      }
      this.db.run(
        `UPDATE self_updates SET state = ?, detail = ?, decided_at = ? WHERE id = ?`,
        state,
        detail,
        state === 'red' ? Date.now() : null,
        id,
      )
      const updated = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!updated) throw new Error('self-update attempt disappeared mid-finalize')
      return this.toSelfUpdate(updated)
    })
  }

  /** The human's call on a green row: boot the new build, or not. */
  decideSelfUpdate(id: Id, to: 'relaunched' | 'declined'): SelfUpdate {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!row) throw new Error('no such self-update')
      const attempt = this.toSelfUpdate(row)
      if (attempt.state !== 'green') {
        throw new Error(`a ${attempt.state} self-update cannot become ${to}`)
      }
      this.db.run(
        `UPDATE self_updates SET state = ?, decided_at = ? WHERE id = ?`,
        to,
        Date.now(),
        id,
      )
      const updated = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
      if (!updated) throw new Error('self-update disappeared mid-decide')
      return this.toSelfUpdate(updated)
    })
  }

  /**
   * The one live offer, if any. Supersede-at-attempt keeps green unique, but
   * the ordering stays defensive rather than load-bearing.
   */
  getPendingSelfUpdate(): SelfUpdate | null {
    const row = this.db.get(
      `SELECT * FROM self_updates WHERE state = 'green'
       ORDER BY created_at DESC, id ASC LIMIT 1`,
    )
    return row ? this.toSelfUpdate(row) : null
  }

  getSelfUpdate(id: Id): SelfUpdate | null {
    const row = this.db.get(`SELECT * FROM self_updates WHERE id = ?`, id)
    return row ? this.toSelfUpdate(row) : null
  }

  listSelfUpdates(limit = 50): SelfUpdate[] {
    return this.db
      .all(`SELECT * FROM self_updates ORDER BY created_at DESC, id ASC LIMIT ?`, limit)
      .map((r) => this.toSelfUpdate(r))
  }

  /**
   * Startup honesty for rows a dead process left `running`: this only ever
   * runs before any new gate exists, so a surviving `running` row can only
   * mean the app quit or crashed mid-gate. A LIVE process never calls this —
   * its own catch finalizes red instead.
   */
  reconcileSelfUpdates(): number {
    return this.db.run(
      `UPDATE self_updates SET state = 'red', decided_at = ?,
         detail = 'Interrupted when Parley last quit.'
       WHERE state = 'running'`,
      Date.now(),
    ).changes
  }

  private toSelfUpdate(row: Row): SelfUpdate {
    return {
      id: str(row['id']),
      planId: str(row['plan_id']),
      state: str(row['state']) as SelfUpdateState,
      detail: str(row['detail']),
      createdAt: num(row['created_at']),
      decidedAt: row['decided_at'] == null ? null : num(row['decided_at']),
    }
  }

  private toForemanProposal(row: Row): ForemanProposal {
    return {
      id: str(row['id']),
      repoPath: str(row['repo_path']),
      state: str(row['state']) as ForemanProposalState,
      title: str(row['title']),
      rationale: str(row['rationale']),
      itemIds: parseJson<Id[]>(row['item_ids'], []),
      deferred: parseJson<ForemanDeferral[]>(row['deferred'], []),
      openSnapshot: parseJson<Id[]>(row['open_snapshot'], []),
      isolation: str(row['isolation']) as ForemanProposal['isolation'],
      note: str(row['note']),
      anchorSessionId: nullableStr(row['anchor_session_id']),
      planId: nullableStr(row['plan_id']),
      vendor: str(row['vendor']) as Vendor,
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
      decidedAt: row['decided_at'] == null ? null : num(row['decided_at']),
      decisionNote: str(row['decision_note']),
    }
  }

  // ─── Plans and milestones ──────────────────────────────────────────────────

  createPlan(plan: WorkPlan): WorkPlan {
    return this.db.transaction(() => this.createPlanCore(plan))
  }

  private createPlanCore(plan: WorkPlan): WorkPlan {
    this.db.run(
      `INSERT INTO plans (id, session_id, kind, title, repo_path, planner, executor, reviewer, status, usage, mock, question, correction_note, correction_dispositions, isolation, setup_command, container, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
      plan.container ? 1 : 0,
      plan.createdAt,
    )
    this.noteRepoActivity(plan.repoPath)
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
      container: num(row['container']) === 1,
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

  /**
   * Every plan that ever targeted the repository, newest first. Unlimited on
   * purpose — "every plan for this repo" behind the global 200-cap would
   * silently drop history. plans.repo_path is raw by design (validateRepoPath
   * and existing rows are untouchable), so the filter canonicalises in
   * memory, the same way the foreman's recent-plans block does.
   */
  listPlansForRepo(repoPath: string): WorkPlan[] {
    const canonical = canonicalRepoPath(repoPath)
    return this.db
      .all(`SELECT * FROM plans ORDER BY created_at DESC`)
      .map((r) => this.toPlan(r))
      .filter((plan) => canonicalRepoPath(plan.repoPath) === canonical)
  }

  /**
   * One row per repository Parley has ever worked — the union of plan,
   * backlog and learning repos, canonically keyed. Item and proposal counts
   * are scoped to the running mode (they drive action chips the surface can
   * actually act on); plan counts are total, with mode visible per-row in
   * the table itself.
   */
  listRepoSummaries(mock: boolean): RepoSummary[] {
    const summaries = new Map<string, RepoSummary>()
    const archived = new Set(this.archivedRepoPaths())
    const summaryFor = (repoPath: string): RepoSummary => {
      const existing = summaries.get(repoPath)
      if (existing) return existing
      const created: RepoSummary = {
        repoPath,
        archived: archived.has(repoPath),
        planCount: 0,
        attentionPlans: 0,
        openItems: 0,
        pendingTriage: 0,
        hasPendingProposal: false,
      }
      summaries.set(repoPath, created)
      return created
    }

    const unlanded = new Set(
      this.db
        .all(`SELECT plan_id FROM worktrees WHERE landed_at IS NULL`)
        .map((row) => str(row['plan_id'])),
    )
    for (const row of this.db.all(`SELECT * FROM plans`)) {
      const plan = this.toPlan(row)
      const summary = summaryFor(canonicalRepoPath(plan.repoPath))
      summary.planCount += 1
      const attention =
        plan.status === 'failed' ||
        plan.status === 'awaiting-clarification' ||
        plan.status === 'blocked' ||
        (plan.status === 'complete' && plan.isolation === 'worktree' && unlanded.has(plan.id))
      if (attention) summary.attentionPlans += 1
    }
    for (const item of this.listBacklogItems()) {
      const summary = summaryFor(item.repoPath)
      if (item.mock !== mock) continue
      if (item.state === 'open') summary.openItems += 1
      if (item.state === 'proposed' || item.state === 'closure-proposed') {
        summary.pendingTriage += 1
      }
    }
    for (const learning of this.listLearnings()) summaryFor(learning.repoPath)
    // The fourth source. A project Parley just created has no plan, no
    // backlog item and no learning, so without this it would be invisible on
    // the only surface that lists repositories.
    for (const workspace of this.listWorkspaces()) {
      if (workspace.mock !== mock) continue
      summaryFor(canonicalRepoPath(workspace.repoPath))
    }
    for (const summary of summaries.values()) {
      summary.hasPendingProposal =
        this.getPendingForemanProposal(summary.repoPath, mock) !== null
    }
    return [...summaries.values()].sort((a, b) => a.repoPath.localeCompare(b.repoPath))
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

  /**
   * Closes out a plan that stopped without finishing. Only failed and blocked
   * plans qualify: running work has a stop button, complete work lands or
   * stands, and cancelling either would falsify the record. Backlog items
   * still planned toward it are released to open in the same transaction —
   * a dead plan must not keep its claim on the worklist.
   */
  cancelPlan(id: Id): { plan: WorkPlan; releasedItemIds: Id[] } {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT * FROM plans WHERE id = ?`, id)
      if (!row) throw new Error('no such plan')
      const plan = this.toPlan(row)
      if (plan.status !== 'failed' && plan.status !== 'blocked') {
        throw new Error(`a ${plan.status} plan cannot be closed out — only failed or blocked`)
      }
      this.db.run(`UPDATE plans SET status = 'cancelled' WHERE id = ?`, id)
      this.noteRepoActivity(plan.repoPath)
      const releasedItemIds: Id[] = []
      for (const itemRow of this.db.all(
        `SELECT id FROM backlog_items WHERE plan_id = ? AND state = 'planned'`,
        id,
      )) {
        const itemId = str(itemRow['id'])
        this.transitionBacklogItemCore(itemId, 'open', {
          source: 'human',
          note: 'Released: its plan was closed out.',
        })
        releasedItemIds.push(itemId)
      }
      return { plan: { ...plan, status: 'cancelled' as const }, releasedItemIds }
    })
  }

  setPlanStatus(id: Id, status: WorkPlan['status']): void {
    this.db.transaction(() => {
      const plan = this.getPlan(id)
      const changes = this.db.run(`UPDATE plans SET status = ? WHERE id = ?`, status, id).changes
      if (changes === 1 && plan) this.noteRepoActivity(plan.repoPath)
    })
  }

  /** Parks a plan on a question, storing what the resumed stage will need. */
  askPlanQuestion(id: Id, question: string, pending: unknown): void {
    this.db.transaction(() => {
      const plan = this.getPlan(id)
      const changes = this.db.run(
        `UPDATE plans SET status = 'awaiting-clarification', question = ?, pending = ? WHERE id = ?`,
        question,
        json(pending),
        id,
      ).changes
      if (changes === 1 && plan) this.noteRepoActivity(plan.repoPath)
    })
  }

  /** Reads and clears the parked state. Returns null when nothing is parked. */
  takePlanPending<T>(id: Id): T | null {
    return this.db.transaction(() => {
      const row = this.db.get(`SELECT pending, repo_path FROM plans WHERE id = ?`, id)
      const raw = row?.['pending']
      if (typeof raw !== 'string' || !raw) return null
      this.db.run(`UPDATE plans SET pending = NULL, question = '' WHERE id = ?`, id)
      this.noteRepoActivity(str(row['repo_path']))
      try {
        return JSON.parse(raw) as T
      } catch {
        return null
      }
    })
  }

  setPlanCorrectionNote(id: Id, note: string): void {
    this.db.transaction(() => {
      const plan = this.getPlan(id)
      const changes = this.db.run(`UPDATE plans SET correction_note = ? WHERE id = ?`, note, id).changes
      if (changes === 1 && plan) this.noteRepoActivity(plan.repoPath)
    })
  }

  /** The same dispositions, structured, for the surface to table. */
  setPlanCorrectionDispositions(id: Id, dispositions: CorrectionDisposition[]): void {
    this.db.transaction(() => {
      const plan = this.getPlan(id)
      const changes = this.db.run(
        `UPDATE plans SET correction_dispositions = ? WHERE id = ?`,
        json(dispositions),
        id,
      ).changes
      if (changes === 1 && plan) this.noteRepoActivity(plan.repoPath)
    })
  }

  /** Milestones are replaced wholesale when a corrected plan supersedes them. */
  clearMilestones(planId: Id): void {
    this.db.run(`DELETE FROM milestones WHERE plan_id = ?`, planId)
  }

  setPlanTitle(id: Id, title: string): void {
    this.db.transaction(() => {
      const plan = this.getPlan(id)
      const changes = this.db.run(`UPDATE plans SET title = ? WHERE id = ?`, title, id).changes
      if (changes === 1 && plan) this.noteRepoActivity(plan.repoPath)
    })
  }

  addPlanUsage(id: Id, delta: Usage): void {
    this.db.transaction(() => {
      const row = this.db.get(`SELECT usage, repo_path FROM plans WHERE id = ?`, id)
      const total = addUsage(parseJson<Usage>(row?.['usage'], emptyUsage()), delta)
      const changes = this.db.run(`UPDATE plans SET usage = ? WHERE id = ?`, json(total), id).changes
      if (changes === 1 && row) this.noteRepoActivity(str(row['repo_path']))
    })
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
    return this.db.transaction(() => {
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
        const changes = this.db.run(
          `UPDATE milestones SET ${sets.join(', ')} WHERE id = ?`,
          ...values,
          id,
        ).changes
        if (changes === 1) {
          this.noteRepoActivity(this.repoPathForMilestone(id), 'milestone')
        }
      }
      const updated = this.getMilestone(id)
      if (!updated) throw new Error(`milestone ${id} disappeared`)
      return updated
    })
  }

  private repoPathForMilestone(id: Id): string {
    const row = this.db.get(
      `SELECT p.repo_path
       FROM milestones m
       JOIN plans p ON p.id = m.plan_id
       WHERE m.id = ?`,
      id,
    )
    if (!row) throw new Error(`milestone ${id} disappeared`)
    return str(row['repo_path'])
  }

  // ─── Loops ─────────────────────────────────────────────────────────────────

  createLoop(loop: Loop): Loop {
    return this.db.transaction(() => {
      this.db.run(
        `INSERT INTO loops (id, goal, repo_path, worker, verifier, exit_condition, caps, capability,
                            container, approval_id, status, usage, iteration_count, mock, started_at, ended_at, stop_reason)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        loop.id,
        loop.goal,
        loop.repoPath,
        json(loop.worker),
        json(loop.verifier),
        json(loop.exit),
        json(loop.caps),
        loop.capability,
        loop.container ? 1 : 0,
        loop.approvalId,
        loop.status,
        json(loop.usage),
        loop.iterationCount,
        loop.mock ? 1 : 0,
        loop.startedAt,
        loop.endedAt,
        loop.stopReason,
      )
      this.noteRepoActivity(loop.repoPath)
      return loop
    })
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
      container: num(row['container']) === 1,
      approvalId: nullableStr(row['approval_id']),
      status: str(row['status']) as Loop['status'],
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      iterationCount: num(row['iteration_count']),
      mock: num(row['mock']) === 1,
      startedAt: num(row['started_at']),
      endedAt: nullableNum(row['ended_at']),
      stopReason: str(row['stop_reason']),
      lastActivityAt: nullableNum(row['last_activity_at']),
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
    return this.db.transaction(() => {
      const before = this.getLoop(id)
      const startedAt = Date.now()
      const result = this.db.run(
        `UPDATE loops SET status = 'running', approval_id = ?, started_at = ?
         WHERE id = ? AND status = 'idle'`,
        approvalId,
        startedAt,
        id,
      )
      if (result.changes !== 1) throw new Error(`loop ${id} is not idle`)
      if (!before) throw new Error(`loop ${id} disappeared`)
      this.noteRepoActivity(before.repoPath)
      const loop = this.getLoop(id)
      if (!loop) throw new Error(`loop ${id} disappeared`)
      return loop
    })
  }

  /** The liveness stamp. Written on real activity only (throttled), silently. */
  setLoopActivity(id: Id, at: number): void {
    this.db.transaction(() => {
      const loop = this.getLoop(id)
      const changes = this.db.run(`UPDATE loops SET last_activity_at = ? WHERE id = ?`, at, id).changes
      if (changes === 1 && loop) this.noteRepoActivity(loop.repoPath)
    })
  }

  setLoopStatus(id: Id, status: Loop['status'], stopReason = ''): void {
    this.db.transaction(() => {
      const loop = this.getLoop(id)
      const terminal = status === 'succeeded' || status === 'exhausted' || status === 'killed' || status === 'failed'
      const changes = this.db.run(
        `UPDATE loops SET status = ?, stop_reason = ?, ended_at = ? WHERE id = ?`,
        status,
        stopReason,
        terminal ? Date.now() : null,
        id,
      ).changes
      if (changes === 1 && loop) this.noteRepoActivity(loop.repoPath)
    })
  }

  bumpLoop(id: Id, delta: Usage): Loop {
    return this.db.transaction(() => {
      const loop = this.getLoop(id)
      if (!loop) throw new Error(`loop ${id} not found`)
      const usage = addUsage(loop.usage, delta)
      const count = loop.iterationCount + 1
      this.db.run(`UPDATE loops SET usage = ?, iteration_count = ? WHERE id = ?`, json(usage), count, id)
      this.noteRepoActivity(loop.repoPath)
      return { ...loop, usage, iterationCount: count }
    })
  }

  addLoopUsage(id: Id, delta: Usage): Loop {
    return this.db.transaction(() => {
      const loop = this.getLoop(id)
      if (!loop) throw new Error(`loop ${id} not found`)
      const usage = addUsage(loop.usage, delta)
      this.db.run(`UPDATE loops SET usage = ? WHERE id = ?`, json(usage), id)
      this.noteRepoActivity(loop.repoPath)
      return { ...loop, usage }
    })
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
