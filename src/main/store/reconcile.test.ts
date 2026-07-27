import { describe, expect, it } from 'vitest'
import { migrate, openDatabase } from './db'
import { Repo, newId } from './repo'
import { emptyUsage, type Loop, type Milestone, type Session, type WorkPlan } from '@shared/domain'

/**
 * Crash recovery.
 *
 * Runners only live in memory, so anything the previous process was doing leaves
 * a row behind claiming to still be in flight. The observed symptom was a
 * milestone stuck on "executing" with a spinner forever, which the UI then
 * refused to let anyone retry.
 */

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

const claude = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'medium' as const, persona: '' }

function makeSession(repo: Repo, status: Session['status']): Session {
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status,
    matter: 'x',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 4,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error'>)
  repo.setSessionStatus(session.id, status)
  return session
}

function makePlanWithMilestone(repo: Repo, milestoneStatus: Milestone['status']): {
  plan: WorkPlan
  milestone: Milestone
} {
  const plan = repo.createPlan({
    id: newId(),
    sessionId: 'sess',
    kind: 'implementation',
    title: 'p',
    repoPath: '/tmp',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'running',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout' as const,
    setupCommand: '',
    usage: emptyUsage(),
    mock: false,
    createdAt: Date.now(),
  })
  const milestone = repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Add internal/forge core',
    intent: '',
    expectedPaths: [],
    status: milestoneStatus,
    auditNote: '',
    testCommand: '',
    testResult: null,
    reviewNote: '',
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
    mutations: [],
    mutationResults: [],
    reviewBlocking: [],
    reviewNotes: [],
  })
  return { plan, milestone }
}

function makeLoop(repo: Repo, status: Loop['status']): Loop {
  return repo.createLoop({
    id: newId(),
    goal: 'g',
    repoPath: '/tmp',
    worker: codex,
    verifier: claude,
    exit: { kind: 'command', command: 'true', criterion: '' },
    caps: { maxIterations: 3, maxSpendUsd: 0, maxWallClockMs: 60_000 },
    capability: 'read',
    approvalId: null,
    status,
    usage: emptyUsage(),
    iterationCount: 0,
    mock: false,
    startedAt: Date.now(),
    endedAt: null,
    stopReason: '',
  })
}

describe('reconcileInterrupted', () => {
  it('frees a milestone stuck mid-execution so it can be retried', () => {
    const repo = freshRepo()
    const { milestone } = makePlanWithMilestone(repo, 'executing')

    const counts = repo.reconcileInterrupted()

    expect(counts.milestones).toBe(1)
    const recovered = repo.getMilestone(milestone.id)
    expect(recovered?.status).toBe('failed')
    expect(recovered?.reviewNote).toMatch(/interrupted/i)
  })

  it('covers every mid-flight milestone status', () => {
    for (const status of ['executing', 'testing', 'reviewing'] as const) {
      const repo = freshRepo()
      const { milestone } = makePlanWithMilestone(repo, status)
      repo.reconcileInterrupted()
      expect(repo.getMilestone(milestone.id)?.status, status).toBe('failed')
    }
  })

  it('blocks a plan interrupted while correcting instead of exposing its audited draft', () => {
    const repo = freshRepo()
    const { plan, milestone } = makePlanWithMilestone(repo, 'audited')
    repo.setPlanStatus(plan.id, 'correcting')

    const counts = repo.reconcileInterrupted()

    expect(counts.plans).toBe(1)
    expect(repo.getPlan(plan.id)?.status).toBe('blocked')
    expect(repo.getPlan(plan.id)?.correctionNote).toMatch(/interrupted/i)
    expect(repo.getMilestone(milestone.id)?.status).toBe('audited')
  })

  it('fails plans interrupted outside the correction stage', () => {
    for (const status of ['drafting', 'auditing', 'running'] as const) {
      const repo = freshRepo()
      const { plan } = makePlanWithMilestone(repo, 'planned')
      repo.setPlanStatus(plan.id, status)

      const counts = repo.reconcileInterrupted()

      expect(counts.plans, status).toBe(1)
      expect(repo.getPlan(plan.id)?.status, status).toBe('failed')
    }
  })

  it('leaves settled milestones alone', () => {
    for (const status of ['planned', 'audited', 'complete', 'rejected', 'failed'] as const) {
      const repo = freshRepo()
      const { milestone } = makePlanWithMilestone(repo, status)
      const counts = repo.reconcileInterrupted()
      expect(counts.milestones, status).toBe(0)
      expect(repo.getMilestone(milestone.id)?.status, status).toBe(status)
    }
  })

  it('resolves interrupted sessions and stamps an end time', () => {
    const repo = freshRepo()
    const running = makeSession(repo, 'running')
    const paused = makeSession(repo, 'paused')
    const done = makeSession(repo, 'complete')

    const counts = repo.reconcileInterrupted()

    expect(counts.sessions).toBe(2)
    expect(repo.getSession(running.id)?.status).toBe('failed')
    expect(repo.getSession(running.id)?.error).toMatch(/interrupted/i)
    expect(repo.getSession(running.id)?.endedAt).not.toBeNull()
    expect(repo.getSession(paused.id)?.status).toBe('failed')
    expect(repo.getSession(done.id)?.status).toBe('complete')
  })

  it('kills interrupted loops but leaves an unstarted one startable', () => {
    const repo = freshRepo()
    const running = makeLoop(repo, 'running')
    const idle = makeLoop(repo, 'idle')

    const counts = repo.reconcileInterrupted()

    expect(counts.loops).toBe(1)
    expect(repo.getLoop(running.id)?.status).toBe('killed')
    // An idle loop was never running, so it must stay startable.
    expect(repo.getLoop(idle.id)?.status).toBe('idle')
  })

  it('closes turns that never ended', () => {
    const repo = freshRepo()
    const session = makeSession(repo, 'running')
    repo.createTurn({
      id: newId(),
      sessionId: session.id,
      index: 0,
      seat: 0,
      vendor: 'claude',
      model: '',
      stage: 'Position',
      text: '',
      usage: emptyUsage(),
      startedAt: Date.now(),
      endedAt: null,
      error: null,
    })

    repo.reconcileInterrupted()

    const turn = repo.listTurns(session.id)[0]
    expect(turn?.endedAt).not.toBeNull()
    expect(turn?.error).toMatch(/interrupted/i)
  })

  it('is idempotent — a second pass finds nothing', () => {
    const repo = freshRepo()
    makeSession(repo, 'running')
    makePlanWithMilestone(repo, 'executing')
    makeLoop(repo, 'running')

    const first = repo.reconcileInterrupted()
    expect(first.sessions + first.loops + first.milestones).toBeGreaterThan(0)

    const second = repo.reconcileInterrupted()
    expect(second).toEqual({ sessions: 0, loops: 0, plans: 0, milestones: 0 })
  })

  it('reports nothing on a clean database', () => {
    expect(freshRepo().reconcileInterrupted()).toEqual({
      sessions: 0,
      loops: 0,
      plans: 0,
      milestones: 0,
    })
  })

  it('does not release a consumed approval', () => {
    // Retrying a write must require fresh authorisation, even after a crash.
    const repo = freshRepo()
    const { milestone } = makePlanWithMilestone(repo, 'executing')
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'write')
    repo.consumeApproval(approval.id, 'milestone.execute', milestone.id)

    repo.reconcileInterrupted()

    expect(repo.listApprovals()[0]?.consumedAt).not.toBeNull()
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', milestone.id)).toThrow()
  })
})

describe('saved grid layouts', () => {
  const tree = {
    type: 'split' as const,
    direction: 'row' as const,
    ratio: 0.5,
    a: { type: 'leaf' as const, kind: 'shell' as const, cwd: '/repo/a' },
    b: { type: 'leaf' as const, kind: 'claude' as const, cwd: '/repo/b' },
  }

  it('round-trips through the database', () => {
    const repo = freshRepo()
    const saved = repo.saveLayout({ id: newId(), name: 'janus', defaultFolder: '/repo/a', tree })

    const loaded = repo.getLayout(saved.id)
    expect(loaded?.name).toBe('janus')
    expect(loaded?.defaultFolder).toBe('/repo/a')
    // Each pane keeps its own folder — a layout is not a single-folder workspace.
    expect(JSON.stringify(loaded?.tree)).toContain('/repo/b')
  })

  it('replaces by name rather than accumulating duplicates', () => {
    const repo = freshRepo()
    const first = repo.saveLayout({ id: newId(), name: 'janus', defaultFolder: '/a', tree })
    const second = repo.saveLayout({ id: newId(), name: 'janus', defaultFolder: '/b', tree })

    expect(repo.listLayouts()).toHaveLength(1)
    // Re-saving keeps the original row, so the id a caller already holds stays valid.
    expect(second.id).toBe(first.id)
    expect(repo.getLayout(first.id)?.defaultFolder).toBe('/b')
  })

  it('keeps distinct names apart and lists newest first', async () => {
    const repo = freshRepo()
    repo.saveLayout({ id: newId(), name: 'zebra', defaultFolder: '', tree })
    // The clock has millisecond resolution, so without a gap both rows share a
    // timestamp and this would be testing the tie-break, not recency. The name
    // is chosen so alphabetical order would give the opposite answer.
    await new Promise((r) => setTimeout(r, 5))
    repo.saveLayout({ id: newId(), name: 'alpha', defaultFolder: '', tree })

    expect(repo.listLayouts().map((l) => l.name)).toEqual(['alpha', 'zebra'])
  })

  it('deletes cleanly', () => {
    const repo = freshRepo()
    const saved = repo.saveLayout({ id: newId(), name: 'gone', defaultFolder: '', tree })
    repo.deleteLayout(saved.id)
    expect(repo.getLayout(saved.id)).toBeNull()
    expect(repo.listLayouts()).toEqual([])
  })

  it('reports nothing for an unknown id', () => {
    expect(freshRepo().getLayout('nope')).toBeNull()
  })
})

describe('upgrading a database made by an older build', () => {
  /** A v1-era plans/milestones schema: none of the columns added since. */
  function legacyDatabase(): ReturnType<typeof openDatabase> {
    const db = openDatabase(':memory:')
    db.exec('DROP TABLE IF EXISTS plans')
    db.exec('DROP TABLE IF EXISTS milestones')
    db.exec(`CREATE TABLE plans (
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
      repo_path TEXT NOT NULL, planner TEXT NOT NULL, executor TEXT NOT NULL, reviewer TEXT NOT NULL,
      status TEXT NOT NULL, usage TEXT NOT NULL, created_at INTEGER NOT NULL)`)
    db.exec(`CREATE TABLE milestones (
      id TEXT PRIMARY KEY, plan_id TEXT NOT NULL, idx INTEGER NOT NULL, title TEXT NOT NULL,
      intent TEXT NOT NULL DEFAULT '', expected_paths TEXT NOT NULL DEFAULT '[]', status TEXT NOT NULL,
      audit_note TEXT NOT NULL DEFAULT '', test_command TEXT NOT NULL DEFAULT '', test_result TEXT,
      review_note TEXT NOT NULL DEFAULT '', review_passed INTEGER, approval_id TEXT,
      created_at INTEGER NOT NULL, completed_at INTEGER)`)
    db.run(`INSERT INTO plans VALUES (?,?,?,?,?,?,?,?,?,?,?)`,
      'p1', 's1', 'implementation', 'Legacy plan', '/repo', '{}', '{}', '{}', 'ready', '{}', 1)
    db.run(`INSERT INTO milestones (id, plan_id, idx, title, status, created_at) VALUES (?,?,?,?,?,?)`,
      'm1', 'p1', 0, 'Legacy milestone', 'audited', 1)
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version','1')
            ON CONFLICT(key) DO UPDATE SET value = '1'`)
    return db
  }

  it('adds every column added since, without touching the rows', () => {
    // Real user data goes through this path on the first launch after an
    // upgrade. Losing it would be unrecoverable, so it is worth a test.
    const db = legacyDatabase()
    migrate(db)
    const repo = new Repo(db)

    const plan = repo.getPlan('p1')
    expect(plan?.title).toBe('Legacy plan')
    // Columns that did not exist when the row was written.
    expect(plan?.mock).toBe(false)
    expect(plan?.question).toBe('')
    expect(plan?.correctionNote).toBe('')

    const milestone = repo.getMilestone('m1')
    expect(milestone?.title).toBe('Legacy milestone')
    expect(milestone?.adopted).toBe(false)
  })

  it('is idempotent, so a second launch is harmless', () => {
    const db = legacyDatabase()
    migrate(db)
    expect(() => migrate(db)).not.toThrow()
    expect(new Repo(db).getPlan('p1')?.title).toBe('Legacy plan')
  })

  it('refuses to open a database written by a newer build', () => {
    // Silently downgrading would drop columns the newer build depends on.
    const db = openDatabase(':memory:')
    db.run(`INSERT INTO meta (key, value) VALUES ('schema_version','999')
            ON CONFLICT(key) DO UPDATE SET value = '999'`)
    expect(() => migrate(db)).toThrow(/refusing to downgrade/i)
  })
})
