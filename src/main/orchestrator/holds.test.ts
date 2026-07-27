import { describe, expect, it } from 'vitest'
import type { Loop, Milestone, Session, WorkPlan } from '@shared/domain'
import { emptyUsage } from '@shared/domain'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { computeHolds } from './holds'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }
const none: ReadonlySet<string> = new Set()

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should holds be derived rather than stored?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
}

function makePlan(
  repo: Repo,
  sessionId: string,
  status: WorkPlan['status'],
  overrides: Partial<WorkPlan> = {},
): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Ship the widget',
    repoPath: '/tmp/example',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status,
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout' as const,
    setupCommand: '',
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
    ...overrides,
  })
}

function makeMilestone(
  repo: Repo,
  planId: string,
  index: number,
  status: Milestone['status'],
  overrides: Partial<Milestone> = {},
): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index,
    title: `Milestone ${index + 1}`,
    intent: 'Do the thing',
    expectedPaths: [],
    status,
    auditNote: '',
    testCommand: '',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
    ...overrides,
  })
}

function makeLoop(repo: Repo, status: Loop['status'], overrides: Partial<Loop> = {}): Loop {
  return repo.createLoop({
    id: newId(),
    goal: 'Keep the suite green',
    repoPath: '/tmp/example',
    worker: claude,
    verifier: codex,
    exit: { kind: 'command', command: 'true', criterion: '' },
    caps: { maxIterations: 5, maxSpendUsd: 0, maxWallClockMs: 60_000 },
    capability: 'read',
    approvalId: null,
    status,
    usage: emptyUsage(),
    iterationCount: 0,
    mock: false,
    startedAt: Date.now(),
    endedAt: null,
    stopReason: '',
    ...overrides,
  })
}

function recordBlocker(repo: Repo, sessionId: string, planId: string): void {
  const finding = repo.upsertLedgerFinding(sessionId, `Finding ${newId()}`)
  repo.recordFindingOccurrence({
    findingId: finding.id,
    planId,
    milestoneId: null,
    round: null,
    kind: 'blocking',
    source: 'audit',
  })
}

describe('computeHolds', () => {
  it('derives a clarification hold carrying the parked question, deterministically', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'drafting')
    repo.askPlanQuestion(plan.id, 'Which database should the cache use?', { stage: 'planning' })

    const holds = computeHolds(repo, none)
    expect(holds).toHaveLength(1)
    expect(holds[0]).toMatchObject({
      kind: 'clarification',
      sessionId: session.id,
      planId: plan.id,
      detail: 'Which database should the cache use?',
      actionable: true,
      mock: true,
    })
    // The same state must hash to the same identity on every recompute.
    expect(computeHolds(repo, none)).toEqual(holds)
  })

  it('derives one approval hold per plan, for the lowest actionable milestone', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'ready')
    const first = makeMilestone(repo, plan.id, 0, 'audited')
    makeMilestone(repo, plan.id, 1, 'audited')

    const holds = computeHolds(repo, none)
    expect(holds).toHaveLength(1)
    expect(holds[0]).toMatchObject({
      kind: 'approval-waiting',
      planId: plan.id,
      milestoneId: first.id,
      actionable: true,
    })
  })

  it('gates the approval hold while blockers are open and frees it after a disposition', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'ready')
    makeMilestone(repo, plan.id, 0, 'audited')
    recordBlocker(repo, session.id, plan.id)

    const gated = computeHolds(repo, none)
    expect(gated).toHaveLength(1)
    expect(gated[0]?.kind).toBe('ledger-gated')
    expect(gated[0]?.detail).toMatch(/1 blocking finding/)
    expect(gated[0]?.actionable).toBe(true)

    const finding = repo.listLedgerFindings(session.id)[0]
    if (!finding) throw new Error('expected the recorded finding')
    repo.disposeFinding({
      findingId: finding.id,
      occurrenceId: null,
      state: 'dismissed',
      note: 'Not applicable to this plan.',
      source: 'human',
    })

    const freed = computeHolds(repo, none)
    expect(freed).toHaveLength(1)
    expect(freed[0]?.kind).toBe('approval-waiting')
    // A different kind is a different identity — "now approvable" notifies once.
    expect(freed[0]?.id).not.toBe(gated[0]?.id)
  })

  it('a failed milestone is one hold, never also an approval hold', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'ready')
    const failed = makeMilestone(repo, plan.id, 0, 'failed')

    const alone = computeHolds(repo, none)
    expect(alone).toHaveLength(1)
    expect(alone[0]).toMatchObject({
      kind: 'milestone-failed',
      milestoneId: failed.id,
      actionable: false,
    })

    // A later audited milestone is separate waiting and surfaces alongside it.
    const audited = makeMilestone(repo, plan.id, 1, 'audited')
    const both = computeHolds(repo, none)
    expect(both).toHaveLength(2)
    expect(both.map((h) => h.kind).sort()).toEqual(['approval-waiting', 'milestone-failed'])
    expect(both.find((h) => h.kind === 'approval-waiting')?.milestoneId).toBe(audited.id)
  })

  it('a failed milestone in a cancelled plan derives nothing', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'cancelled')
    makeMilestone(repo, plan.id, 0, 'failed')

    expect(computeHolds(repo, none)).toEqual([])
  })

  it('a blocked plan surfaces the park reason as a notice hold', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'blocked', {
      correctionNote:
        'The audit reply was unreadable.\n\nExecution is blocked until the plan can be audited.',
    })

    const holds = computeHolds(repo, none)
    expect(holds).toHaveLength(1)
    expect(holds[0]).toMatchObject({ kind: 'plan-blocked', planId: plan.id, actionable: false })
    expect(holds[0]?.detail).toContain('Execution is blocked until the plan can be audited.')
  })

  it('terminal loops that did not succeed surface; succeeded and live ones do not', () => {
    const repo = freshRepo()
    makeLoop(repo, 'exhausted', { stopReason: 'iteration cap reached', endedAt: Date.now() })
    makeLoop(repo, 'failed', { stopReason: 'worker error', endedAt: Date.now() })
    makeLoop(repo, 'killed', { stopReason: 'Interrupted when Parley last quit.', endedAt: Date.now() })
    makeLoop(repo, 'succeeded', { endedAt: Date.now() })
    makeLoop(repo, 'running')
    makeLoop(repo, 'idle')

    const holds = computeHolds(repo, none)
    expect(holds).toHaveLength(3)
    expect(new Set(holds.map((h) => h.kind))).toEqual(new Set(['loop-exhausted']))
    expect(holds.every((h) => !h.actionable)).toBe(true)
    expect(holds.every((h) => h.sessionId === null && h.loopId !== null)).toBe(true)
  })

  it('an acknowledgement clears a notice hold but never a decision hold', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const parked = makePlan(repo, session.id, 'drafting')
    repo.askPlanQuestion(parked.id, 'Proceed with the rewrite?', {})
    const failing = makePlan(repo, session.id, 'ready')
    makeMilestone(repo, failing.id, 0, 'failed')

    const open = computeHolds(repo, none)
    expect(open).toHaveLength(2)
    const acked = new Set(open.map((h) => h.id))

    // Acking everything removes only the notice; a stray ack row for the
    // clarification must not hide genuinely parked work.
    const after = computeHolds(repo, acked)
    expect(after).toHaveLength(1)
    expect(after[0]?.kind).toBe('clarification')
  })

  it('a re-failure after an acknowledgement is a fresh hold', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'ready')
    const milestone = makeMilestone(repo, plan.id, 0, 'failed', {
      reviewNote: 'Round 1 — the reviewer objected.',
    })

    const first = computeHolds(repo, none)
    expect(first).toHaveLength(1)
    const acked = new Set([first[0]?.id ?? ''])
    expect(computeHolds(repo, acked)).toEqual([])

    repo.updateMilestone(milestone.id, {
      reviewNote: 'Round 1 — the reviewer objected.\nRound 2 — still failing.',
    })
    const again = computeHolds(repo, acked)
    expect(again).toHaveLength(1)
    expect(again[0]?.id).not.toBe(first[0]?.id)
  })

  it('archived sessions derive nothing', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'drafting')
    repo.askPlanQuestion(plan.id, 'Still relevant?', {})
    repo.setSessionArchived(session.id, true)

    expect(computeHolds(repo, none)).toEqual([])
  })

  it('decisions sort before notices, oldest first within a class', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const older = makePlan(repo, session.id, 'drafting', { createdAt: 1_000 })
    repo.askPlanQuestion(older.id, 'First question?', {})
    const ready = makePlan(repo, session.id, 'ready')
    makeMilestone(repo, ready.id, 0, 'audited', { createdAt: 2_000 })
    const failing = makePlan(repo, session.id, 'ready')
    makeMilestone(repo, failing.id, 0, 'failed', { createdAt: 3_000 })

    const holds = computeHolds(repo, none)
    expect(holds.map((h) => h.kind)).toEqual([
      'clarification',
      'approval-waiting',
      'milestone-failed',
    ])
  })

  it('a silent in-flight milestone surfaces as a stalled notice, stable per episode', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'running')
    const milestone = makeMilestone(repo, plan.id, 0, 'executing')
    repo.setMilestoneRunState(milestone.id, {
      startedAt: 1_000,
      round: 0,
      previousConcerns: [],
      reviewerNote: '',
      executionReport: '',
      executorResumeId: null,
      reviewerResumeId: null,
      before: { paths: [], signature: 'x', unknown: false },
      baselineHead: 'a'.repeat(40),
      lastActivityAt: 10_000,
      lastInspection: null,
    })

    // Fresh stamp: no hold. Aged past the threshold: one notice hold whose
    // identity is the frozen stamp, so re-observing the same stall re-derives
    // the same hold rather than re-notifying.
    expect(computeHolds(repo, none, 10_000 + 1_000)).toEqual([])
    const stalled = computeHolds(repo, none, 10_000 + 6 * 60 * 1000)
    expect(stalled).toHaveLength(1)
    expect(stalled[0]).toMatchObject({
      kind: 'run-stalled',
      milestoneId: milestone.id,
      actionable: false,
      sinceAt: 10_000,
    })
    const later = computeHolds(repo, none, 10_000 + 30 * 60 * 1000)
    expect(later[0]?.id).toBe(stalled[0]?.id)

    // The inspection verdict joins the detail under the same identity — an
    // update to read, never a second notification.
    repo.setMilestoneRunState(milestone.id, {
      startedAt: 1_000,
      round: 0,
      previousConcerns: [],
      reviewerNote: '',
      executionReport: '',
      executorResumeId: null,
      reviewerResumeId: null,
      before: { paths: [], signature: 'x', unknown: false },
      baselineHead: 'a'.repeat(40),
      lastActivityAt: 10_000,
      lastInspection: { at: 20_000, verdict: 'stuck', note: 'wedged on a lock file' },
    })
    const inspected = computeHolds(repo, none, 10_000 + 30 * 60 * 1000)
    expect(inspected[0]?.id).toBe(stalled[0]?.id)
    expect(inspected[0]?.detail).toContain('stuck')
    expect(inspected[0]?.detail).toContain('wedged on a lock file')
  })

  it('a silent running loop stalls through its own stamp', () => {
    const repo = freshRepo()
    const loop = makeLoop(repo, 'running')
    repo.setLoopActivity(loop.id, 5_000)

    expect(computeHolds(repo, none, 5_000 + 1_000)).toEqual([])
    const stalled = computeHolds(repo, none, 5_000 + 6 * 60 * 1000)
    expect(stalled).toHaveLength(1)
    expect(stalled[0]).toMatchObject({ kind: 'run-stalled', loopId: loop.id, sinceAt: 5_000 })
  })

  it('mock provenance is carried from the underlying record', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'drafting', { mock: true })
    repo.askPlanQuestion(plan.id, 'Mock question?', {})
    makeLoop(repo, 'failed', { mock: false, stopReason: 'worker error', endedAt: Date.now() })

    const holds = computeHolds(repo, none)
    expect(holds.find((h) => h.kind === 'clarification')?.mock).toBe(true)
    expect(holds.find((h) => h.kind === 'loop-exhausted')?.mock).toBe(false)
  })
})
