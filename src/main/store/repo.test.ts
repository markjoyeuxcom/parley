import { describe, expect, it } from 'vitest'
import { openDatabase } from './db'
import { ApprovalError, Repo, newId } from './repo'
import { emptyUsage, type Session } from '@shared/domain'

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo, overrides: Partial<Session> = {}): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'running',
    matter: 'whether to adopt the narrower option',
    project: '',
    repoPath: null,
    participants: [
      { vendor: 'claude', model: '', effort: 'medium', persona: '' },
      { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    ],
    maxTurns: 6,
    createdAt: Date.now(),
    ...overrides,
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
}

describe('approvals are single-use', () => {
  it('lets an approval be spent exactly once', () => {
    const repo = freshRepo()
    const approval = repo.grantApproval('milestone.execute', 'm1', 'write to src/net/client.ts')

    const consumed = repo.consumeApproval(approval.id, 'milestone.execute', 'm1')
    expect(consumed.consumedAt).not.toBeNull()

    // The whole point: a second attempt must be refused, not silently allowed.
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', 'm1')).toThrow(ApprovalError)
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', 'm1')).toThrow(/already been used/i)
  })

  it('refuses an approval granted for a different subject', () => {
    const repo = freshRepo()
    const approval = repo.grantApproval('milestone.execute', 'm1', 'write to a')
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', 'm2')).toThrow(
      /does not authorise/i,
    )
    // The failed attempt must not have consumed it.
    expect(repo.consumeApproval(approval.id, 'milestone.execute', 'm1').consumedAt).not.toBeNull()
  })

  it('refuses an approval granted for a different scope', () => {
    const repo = freshRepo()
    const approval = repo.grantApproval('loop.write', 'loop1', 'let the loop write')
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', 'loop1')).toThrow(
      /does not authorise/i,
    )
  })

  it('refuses an unknown approval id', () => {
    const repo = freshRepo()
    expect(() => repo.consumeApproval('nope', 'milestone.execute', 'm1')).toThrow(/no such approval/i)
  })
})

describe('interjection delivery', () => {
  it('delivers a whisper only to its target', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addInterjection({ sessionId: session.id, target: 'a', text: 'press harder on cost', atTurnIndex: 0 })

    expect(repo.takeInterjections(session.id, 'b')).toHaveLength(0)
    const forA = repo.takeInterjections(session.id, 'a')
    expect(forA).toHaveLength(1)
    expect(forA[0]?.text).toBe('press harder on cost')

    // Already taken — must not be handed out twice.
    expect(repo.takeInterjections(session.id, 'a')).toHaveLength(0)
  })

  it('delivers a both-targeted interjection once to each side', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addInterjection({ sessionId: session.id, target: 'both', text: 'assume 10x load', atTurnIndex: 0 })

    expect(repo.takeInterjections(session.id, 'a')).toHaveLength(1)
    // This is the case the naive single-flag design gets wrong.
    expect(repo.takeInterjections(session.id, 'b')).toHaveLength(1)

    expect(repo.takeInterjections(session.id, 'a')).toHaveLength(0)
    expect(repo.takeInterjections(session.id, 'b')).toHaveLength(0)
  })

  it('reports deliveredAt only once every intended recipient has read it', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addInterjection({ sessionId: session.id, target: 'both', text: 'assume 10x load', atTurnIndex: 0 })

    repo.takeInterjections(session.id, 'a')
    expect(repo.listInterjections(session.id)[0]?.deliveredAt).toBeNull()

    repo.takeInterjections(session.id, 'b')
    expect(repo.listInterjections(session.id)[0]?.deliveredAt).not.toBeNull()
  })
})

describe('session bookkeeping', () => {
  it('accumulates usage across turns', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addSessionUsage(session.id, { ...emptyUsage(), inputTokens: 100, outputTokens: 20, costUsd: 0.5 })
    const total = repo.addSessionUsage(session.id, { ...emptyUsage(), inputTokens: 50, outputTokens: 5, costUsd: 0.25 })
    expect(total.inputTokens).toBe(150)
    expect(total.outputTokens).toBe(25)
    expect(total.costUsd).toBeCloseTo(0.75)
  })

  it('stamps endedAt only on terminal statuses', () => {
    const repo = freshRepo()
    const session = makeSession(repo)

    repo.setSessionStatus(session.id, 'paused')
    expect(repo.getSession(session.id)?.endedAt).toBeNull()

    repo.setSessionStatus(session.id, 'complete')
    expect(repo.getSession(session.id)?.endedAt).not.toBeNull()
  })

  it('round-trips a session through the database unchanged', () => {
    const repo = freshRepo()
    const session = makeSession(repo, { project: 'Ledger', repoPath: '/tmp/x' })
    const loaded = repo.getSession(session.id)
    expect(loaded?.project).toBe('Ledger')
    expect(loaded?.repoPath).toBe('/tmp/x')
    expect(loaded?.participants.map((seat) => seat.vendor)).toEqual(['claude', 'codex'])
  })
})

describe('resume ids', () => {
  it('stores one vendor thread id per seat and overwrites on update', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.saveResumeId(session.id, 0, 'claude-1')
    repo.saveResumeId(session.id, 1, 'codex-1')
    expect(repo.getResumeId(session.id, 0)).toBe('claude-1')
    expect(repo.getResumeId(session.id, 1)).toBe('codex-1')

    repo.saveResumeId(session.id, 0, 'claude-2')
    expect(repo.getResumeId(session.id, 0)).toBe('claude-2')
    expect(repo.getResumeId(session.id, 1)).toBe('codex-1')
  })
})

describe('archiving hides without destroying', () => {
  // The point of archiving rather than deleting: a finished session is the
  // record of why a decision was taken and why a repository looks the way it
  // does. Wanting a shorter list is not a reason to lose that.
  it('excludes archived sessions from the default list', () => {
    const repo = freshRepo()
    const keep = makeSession(repo, { matter: 'still relevant' })
    const hide = makeSession(repo, { matter: 'dead experiment' })

    repo.setSessionArchived(hide.id, true)

    expect(repo.listSessions().map((s) => s.id)).toEqual([keep.id])
  })

  it('includes them on request', () => {
    const repo = freshRepo()
    const keep = makeSession(repo)
    const hide = makeSession(repo)
    repo.setSessionArchived(hide.id, true)

    const all = repo.listSessions(200, true).map((s) => s.id)
    expect(all).toHaveLength(2)
    expect(all).toContain(keep.id)
    expect(all).toContain(hide.id)
  })

  it('keeps the session and everything hanging off it', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addInterjection({ sessionId: session.id, target: 'both', text: 'consider cost', atTurnIndex: 0 })

    repo.setSessionArchived(session.id, true)

    // Reachable by id, and its children are untouched — this is the difference
    // between archiving and deleting.
    expect(repo.getSession(session.id)).not.toBeNull()
    expect(repo.listInterjections(session.id)).toHaveLength(1)
  })

  it('restores cleanly, clearing the timestamp', () => {
    const repo = freshRepo()
    const session = makeSession(repo)

    repo.setSessionArchived(session.id, true)
    expect(repo.getSession(session.id)?.archivedAt).not.toBeNull()

    const restored = repo.setSessionArchived(session.id, false)
    expect(restored.archivedAt).toBeNull()
    expect(repo.listSessions().map((s) => s.id)).toContain(session.id)
  })

  it('counts what is hidden, so the UI can offer to show it', () => {
    const repo = freshRepo()
    makeSession(repo)
    const a = makeSession(repo)
    const b = makeSession(repo)

    expect(repo.countArchivedSessions()).toBe(0)
    repo.setSessionArchived(a.id, true)
    repo.setSessionArchived(b.id, true)
    expect(repo.countArchivedSessions()).toBe(2)
    expect(repo.listSessions()).toHaveLength(1)
  })

  it('is idempotent, so a double click does not misbehave', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.setSessionArchived(session.id, true)
    const first = repo.getSession(session.id)?.archivedAt
    repo.setSessionArchived(session.id, true)
    expect(repo.getSession(session.id)?.archivedAt).not.toBeNull()
    expect(typeof first).toBe('number')
    expect(repo.countArchivedSessions()).toBe(1)
  })

  it('leaves new sessions visible', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    expect(session.archivedAt).toBeNull()
    expect(repo.listSessions().map((s) => s.id)).toContain(session.id)
  })
})

describe('migrating an older database', () => {
  /**
   * Simulates a database written before archiving existed by removing the
   * column and winding the recorded version back, then runs the real migration
   * over it. The risk being guarded against is a migration that throws on an
   * existing database, which would leave the app unable to open the user's
   * history at all.
   */
  function asVersion5(db: ReturnType<typeof openDatabase>): void {
    db.exec(`ALTER TABLE sessions DROP COLUMN archived_at`)
    db.run(`UPDATE meta SET value = '5' WHERE key = 'schema_version'`)
  }

  it('adds the column and leaves every existing session visible', async () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const a = makeSession(repo, { matter: 'older work' })
    const b = makeSession(repo, { matter: 'more older work' })

    asVersion5(db)
    const { migrate } = await import('./db')
    expect(() => migrate(db)).not.toThrow()

    // Not archived by accident: NULL is the default, so history stays visible.
    const after = new Repo(db).listSessions()
    expect(after.map((s) => s.id).sort()).toEqual([a.id, b.id].sort())
    expect(after.every((s) => s.archivedAt === null)).toBe(true)
  })

  /**
   * The v8 case: a database written before blocking findings and dispositions were
   * stored structurally. Existing rows must keep their prose note and simply read
   * back empty lists, rather than the app failing to open the user's history.
   */
  function asVersion7(db: ReturnType<typeof openDatabase>): void {
    db.exec(`ALTER TABLE milestones DROP COLUMN review_blocking`)
    db.exec(`ALTER TABLE milestones DROP COLUMN review_notes`)
    db.exec(`ALTER TABLE plans DROP COLUMN correction_dispositions`)
    db.run(`UPDATE meta SET value = '7' WHERE key = 'schema_version'`)
  }

  it('adds the structured review columns without losing the prose already there', async () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const session = makeSession(repo, { matter: 'older work' })
    const agent = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }
    const planId = newId()
    repo.createPlan({
      id: planId,
      sessionId: session.id,
      kind: 'implementation',
      title: 'a plan',
      repoPath: '/tmp/repo',
      planner: agent,
      executor: { ...agent, vendor: 'codex' },
      reviewer: agent,
      status: 'ready',
      question: '',
      correctionNote: 'ACCEPTED — the cap belongs there.',
      correctionDispositions: [],
      isolation: 'checkout' as const,
      setupCommand: '',
      usage: emptyUsage(),
      mock: false,
      createdAt: Date.now(),
    })
    const milestone = repo.createMilestone({
      id: newId(),
      planId,
      index: 0,
      title: 'do the thing',
      intent: '',
      expectedPaths: [],
      status: 'failed',
      auditNote: '',
      testCommand: '',
      testResult: null,
      reviewNote: 'Round 1 — Blocking: the cap is not surfaced',
      reviewPassed: false,
      adopted: false,
      approvalId: null,
      createdAt: Date.now(),
      completedAt: null,
      mutations: [],
      mutationResults: [],
      reviewBlocking: ['the cap is not surfaced'],
      reviewNotes: [],
    })

    asVersion7(db)
    const { migrate } = await import('./db')
    expect(() => migrate(db)).not.toThrow()

    const after = new Repo(db).getMilestone(milestone.id)
    // The old note survives; the new lists default to empty rather than undefined,
    // so the surface renders the prose and no phantom blocking chips.
    expect(after?.reviewNote).toMatch(/the cap is not surfaced/)
    expect(after?.reviewBlocking).toEqual([])
    expect(after?.reviewNotes).toEqual([])
    const migratedPlan = new Repo(db).getPlan(planId)
    expect(migratedPlan?.correctionNote).toMatch(/the cap belongs there/)
    expect(migratedPlan?.correctionDispositions).toEqual([])
  })

  /**
   * The v10 case: a database written before participants were an array. Every
   * two-sided session must come back as seats 0 and 1, minted from the pair it
   * was recorded with.
   */
  function asVersion10(db: ReturnType<typeof openDatabase>): void {
    db.exec(`ALTER TABLE sessions DROP COLUMN participants`)
    db.run(`UPDATE meta SET value = '10' WHERE key = 'schema_version'`)
  }

  it('backfills participants from the recorded a/b pair', async () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const session = makeSession(repo, { matter: 'seated before seats existed' })

    asVersion10(db)
    const { migrate } = await import('./db')
    expect(() => migrate(db)).not.toThrow()

    const after = new Repo(db).getSession(session.id)
    expect(after?.participants.map((seat) => seat.vendor)).toEqual(['claude', 'codex'])
    // Backfilled as data, not merely derived on read: the column itself holds
    // the array, so consumers that query it directly see seated rows.
    const row = db.get(`SELECT participants FROM sessions WHERE id = ?`, session.id)
    expect(typeof row?.['participants']).toBe('string')
  })

  /**
   * The v11 case: a database from before turns and threads spoke seats. Turns
   * carried only a side name, and agent_threads was keyed (session_id, side).
   */
  function asVersion11(db: ReturnType<typeof openDatabase>): void {
    db.exec(`ALTER TABLE turns DROP COLUMN seat`)
    db.exec(`
      CREATE TABLE agent_threads_sided (
        session_id TEXT NOT NULL,
        side       TEXT NOT NULL,
        resume_id  TEXT NOT NULL,
        PRIMARY KEY (session_id, side)
      );
    `)
    db.exec(`
      INSERT INTO agent_threads_sided (session_id, side, resume_id)
      SELECT session_id, CASE seat WHEN 0 THEN 'a' ELSE 'b' END, resume_id FROM agent_threads
    `)
    db.exec(`DROP TABLE agent_threads`)
    db.exec(`ALTER TABLE agent_threads_sided RENAME TO agent_threads`)
    db.run(`UPDATE meta SET value = '11' WHERE key = 'schema_version'`)
  }

  it('seats turns and threads recorded before seats existed', async () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const session = makeSession(repo, { matter: 'spoken in sides' })
    repo.createTurn({
      id: newId(),
      sessionId: session.id,
      index: 0,
      seat: 1,
      vendor: 'codex',
      model: '',
      stage: 'Challenge',
      text: 'x',
      usage: emptyUsage(),
      startedAt: 1,
      endedAt: 2,
      error: null,
    })
    repo.saveResumeId(session.id, 0, 'claude-thread')
    repo.saveResumeId(session.id, 1, 'codex-thread')

    asVersion11(db)
    const { migrate } = await import('./db')
    expect(() => migrate(db)).not.toThrow()

    const seated = new Repo(db)
    expect(seated.listTurns(session.id)[0]?.seat).toBe(1)
    // Backfilled as data on the row, not merely derived on read.
    const row = db.get(`SELECT seat FROM turns WHERE session_id = ?`, session.id)
    expect(row?.['seat']).toBe(1)
    // The rebuilt thread table carries the resume ids across, per seat.
    expect(seated.getResumeId(session.id, 0)).toBe('claude-thread')
    expect(seated.getResumeId(session.id, 1)).toBe('codex-thread')
  })

  it('falls back to the legacy pair when a row has no participants', () => {
    // A database an older build wrote into after this one created it: the
    // participants column exists but the row is NULL. The legacy mirror
    // columns are the truth then, and reading must not fail.
    const repo = freshRepo()
    const session = makeSession(repo)
    const db = (repo as unknown as { db: ReturnType<typeof openDatabase> }).db
    db.run(`UPDATE sessions SET participants = NULL WHERE id = ?`, session.id)

    const loaded = repo.getSession(session.id)
    expect(loaded?.participants.map((seat) => seat.vendor)).toEqual(['claude', 'codex'])
  })

  it('is safe to run twice', async () => {
    const db = openDatabase(':memory:')
    const { migrate } = await import('./db')
    expect(() => migrate(db)).not.toThrow()
    expect(() => migrate(db)).not.toThrow()
  })

  it('records the new version, so it does not re-run every launch', async () => {
    // Asserted against SCHEMA_VERSION rather than a literal: this test is about
    // the version being *written*, not about which version is current, and
    // hardcoding the number made it fail on every future migration.
    const db = openDatabase(':memory:')
    asVersion5(db)
    const { migrate, SCHEMA_VERSION } = await import('./db')
    migrate(db)
    const row = db.get<{ value: string }>(`SELECT value FROM meta WHERE key = 'schema_version'`)
    expect(row?.value).toBe(String(SCHEMA_VERSION))
  })
})

describe('deleting a session', () => {
  const agent = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }

  /** A session with a plan, a milestone, and a spent approval against it. */
  function sessionWithWork(repo: Repo): {
    session: Session
    planId: string
    milestoneId: string
    approvalId: string
  } {
    const session = makeSession(repo)
    const planId = newId()
    repo.createPlan({
      id: planId,
      sessionId: session.id,
      kind: 'implementation',
      title: 'a plan',
      repoPath: '/tmp/repo',
      planner: agent,
      executor: { ...agent, vendor: 'codex' },
      reviewer: agent,
      status: 'ready',
      question: '',
      correctionNote: '',
      correctionDispositions: [],
      isolation: 'checkout' as const,
      setupCommand: '',
      usage: emptyUsage(),
      mock: false,
      createdAt: Date.now(),
    })
    const milestoneId = newId()
    repo.createMilestone({
      id: milestoneId,
      planId,
      index: 0,
      title: 'do the thing',
      intent: 'change some files',
      expectedPaths: ['a.ts'],
      status: 'complete',
      auditNote: '',
      testCommand: 'true',
      testResult: null,
      reviewNote: '',
      reviewPassed: true,
      adopted: false,
      approvalId: null,
      createdAt: Date.now(),
      completedAt: Date.now(),
      mutations: [],
      mutationResults: [],
      reviewBlocking: [],
      reviewNotes: [],
    })
    const approval = repo.grantApproval('milestone.execute', milestoneId, 'write to /tmp/repo')
    repo.consumeApproval(approval.id, 'milestone.execute', milestoneId)
    return { session, planId, milestoneId, approvalId: approval.id }
  }

  it('removes the plan and its milestones, which no foreign key would have caught', () => {
    // plans carries a session_id with no constraint, so a delete that trusted
    // the schema would leave the plan and every milestone behind, invisible.
    const repo = freshRepo()
    const { session, planId, milestoneId } = sessionWithWork(repo)

    repo.deleteSession(session.id)

    expect(repo.getSession(session.id)).toBeNull()
    expect(repo.getPlan(planId)).toBeNull()
    expect(repo.getMilestone(milestoneId)).toBeNull()
  })

  it('keeps the spent approval, because it is the record that a write was authorised', () => {
    const repo = freshRepo()
    const { session, approvalId } = sessionWithWork(repo)

    repo.deleteSession(session.id)

    const kept = repo.listApprovals().find((a) => a.id === approvalId)
    expect(kept).toBeTruthy()
    expect(kept?.summary).toContain('/tmp/repo')
    expect(kept?.consumedAt).not.toBeNull()
  })

  it('takes the transcript and the resume ids with it', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    repo.addInterjection({ sessionId: session.id, target: 'both', text: 'note', atTurnIndex: 0 })
    repo.saveResumeId(session.id, 0, 'vendor-thread-1')

    repo.deleteSession(session.id)

    expect(repo.listInterjections(session.id)).toHaveLength(0)
    expect(repo.getResumeId(session.id, 0)).toBeNull()
  })

  it('leaves other sessions and their work untouched', () => {
    const repo = freshRepo()
    const doomed = sessionWithWork(repo)
    const keeper = sessionWithWork(repo)

    repo.deleteSession(doomed.session.id)

    expect(repo.getSession(keeper.session.id)).not.toBeNull()
    expect(repo.getPlan(keeper.planId)).not.toBeNull()
    expect(repo.getMilestone(keeper.milestoneId)).not.toBeNull()
  })

  it('reports what would be lost before anything is', () => {
    const repo = freshRepo()
    const { session } = sessionWithWork(repo)

    const impact = repo.describeSessionDeletion(session.id)

    expect(impact.plans).toBe(1)
    expect(impact.milestones).toBe(1)
    expect(impact.completedMilestones).toBe(1)
    expect(impact.repos).toEqual(['/tmp/repo'])
    expect(impact.retainedApprovals).toBe(1)
    // Describing must not delete.
    expect(repo.getSession(session.id)).not.toBeNull()
  })

  it('distinguishes a session that never wrote anything', () => {
    // The whole point of the summary: these two look identical in a list.
    const repo = freshRepo()
    const talkOnly = makeSession(repo)

    const impact = repo.describeSessionDeletion(talkOnly.id)

    expect(impact.plans).toBe(0)
    expect(impact.completedMilestones).toBe(0)
    expect(impact.repos).toEqual([])
    expect(impact.retainedApprovals).toBe(0)
  })
})

describe('gathering findings for a remediation plan', () => {
  const agent = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }

  function planWithReviewedMilestone(
    repo: Repo,
    sessionId: string,
    opts: { status: 'complete' | 'failed' | 'audited'; reviewNote: string; title: string },
  ): string {
    const planId = newId()
    repo.createPlan({
      id: planId,
      sessionId,
      kind: 'implementation',
      title: 'plan',
      repoPath: '/tmp/repo',
      planner: agent,
      executor: { ...agent, vendor: 'codex' },
      reviewer: agent,
      status: 'ready',
      question: '',
      correctionNote: '',
      correctionDispositions: [],
      isolation: 'checkout' as const,
      setupCommand: '',
      usage: emptyUsage(),
      mock: false,
      createdAt: Date.now(),
    })
    repo.createMilestone({
      id: newId(),
      planId,
      index: 0,
      title: opts.title,
      intent: 'i',
      expectedPaths: [],
      status: opts.status,
      auditNote: '',
      testCommand: 'true',
      testResult: null,
      reviewNote: opts.reviewNote,
      reviewPassed: true,
      adopted: false,
      approvalId: null,
      createdAt: Date.now(),
      completedAt: null,
      mutations: [],
      mutationResults: [],
      reviewBlocking: [],
      reviewNotes: [],
    })
    return planId
  }

  it('collects the recorded reviews of work that actually ran', () => {
    // Without this, "fix the confirmed findings" reaches a planner with no
    // findings: reviews live in this database, and the planner reads the repo.
    const repo = freshRepo()
    const session = makeSession(repo)
    planWithReviewedMilestone(repo, session.id, {
      status: 'complete',
      title: 'add the AI',
      reviewNote: 'a hardcoded snapshot would pass this suite',
    })

    const findings = repo.reviewFindingsForSession(session.id)
    expect(findings).toHaveLength(1)
    expect(findings[0]).toContain('hardcoded snapshot')
    // Named, so the planner can tell which milestone it belongs to.
    expect(findings[0]).toContain('add the AI')
  })

  it('ignores milestones that never ran', () => {
    // A review against unexecuted work is not a finding about the codebase.
    const repo = freshRepo()
    const session = makeSession(repo)
    planWithReviewedMilestone(repo, session.id, {
      status: 'audited',
      title: 'not yet run',
      reviewNote: 'this should not appear',
    })

    expect(repo.reviewFindingsForSession(session.id)).toEqual([])
  })

  it('excludes the plan being drafted, which has no history yet', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const older = planWithReviewedMilestone(repo, session.id, {
      status: 'complete',
      title: 'earlier work',
      reviewNote: 'earlier finding',
    })
    const current = planWithReviewedMilestone(repo, session.id, {
      status: 'complete',
      title: 'the remediation plan itself',
      reviewNote: 'should be excluded',
    })

    const findings = repo.reviewFindingsForSession(session.id, current)
    expect(findings).toHaveLength(1)
    expect(findings[0]).toContain('earlier finding')
    expect(older).toBeTruthy()
  })

  it('does not reach into another session', () => {
    const repo = freshRepo()
    const mine = makeSession(repo)
    const theirs = makeSession(repo)
    planWithReviewedMilestone(repo, theirs.id, {
      status: 'complete',
      title: 'unrelated',
      reviewNote: 'someone else findings',
    })

    expect(repo.reviewFindingsForSession(mine.id)).toEqual([])
  })

  it('skips milestones with an empty review', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    planWithReviewedMilestone(repo, session.id, {
      status: 'complete',
      title: 'clean',
      reviewNote: '   ',
    })

    expect(repo.reviewFindingsForSession(session.id)).toEqual([])
  })
})
