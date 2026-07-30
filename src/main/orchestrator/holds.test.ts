import { describe, expect, it } from 'vitest'
import type { Loop, Milestone, Session, WorkPlan } from '@shared/domain'
import { emptyUsage } from '@shared/domain'
import { holdIdentity } from '@shared/holds'
import { openDatabase } from '@main/store/db'
import { canonicalRepoPath } from '@main/util/repoPath'
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
    container: false,
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
    container: false,
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

describe('the backlog-review hold', () => {
  const file = (
    repo: Repo,
    repoPath: string,
    title: string,
    state: 'proposed' | 'open',
    mock = true,
  ) =>
    repo.fileBacklogItem({ repoPath, title, source: 'manual', mock, state }).item

  it('derives one decision hold per repository with pending proposals', () => {
    const repo = freshRepo()
    file(repo, '/tmp/repo-a', 'A stow proposal', 'proposed')
    file(repo, '/tmp/repo-a', 'Another stow proposal', 'proposed')
    file(repo, '/tmp/repo-a', 'Already triaged into the backlog', 'open')
    file(repo, '/tmp/repo-b', 'Quiet repo, nothing pending', 'open')

    const holds = computeHolds(repo, none)
    const review = holds.filter((h) => h.kind === 'backlog-review')
    expect(review).toHaveLength(1)
    expect(review[0]).toMatchObject({
      actionable: true,
      repoPath: '/tmp/repo-a',
      mock: true,
    })
    expect(review[0]?.detail).toContain('2 proposed items')
  })

  it('closure proposals count as pending triage too', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'complete')
    const item = file(repo, '/tmp/repo-c', 'Planned and completed', 'open')
    repo.transitionBacklogItem(item.id, 'planned', { source: 'pipeline', planId: plan.id })
    repo.transitionBacklogItem(item.id, 'closure-proposed', {
      source: 'pipeline',
      planId: plan.id,
    })

    const review = computeHolds(repo, none).filter((h) => h.kind === 'backlog-review')
    expect(review).toHaveLength(1)
    expect(review[0]?.detail).toContain('1 closure proposal')

    // Closing it is the triage; the hold clears with nothing to ack.
    repo.transitionBacklogItem(item.id, 'done', { source: 'human' })
    expect(computeHolds(repo, none).some((h) => h.kind === 'backlog-review')).toBe(false)
  })

  it('a new batch mints a fresh identity; triage only falls back to stamped ones', () => {
    const repo = freshRepo()
    const first = file(repo, '/tmp/repo-d', 'The first proposal', 'proposed')
    const soloId = computeHolds(repo, none).find((h) => h.kind === 'backlog-review')?.id

    // A later arrival is new waiting: fresh identity, one fresh notification.
    const db = repo as unknown as { db: { run: (sql: string, ...p: unknown[]) => unknown } }
    const second = file(repo, '/tmp/repo-d', 'A later proposal', 'proposed')
    db.db.run(
      `UPDATE backlog_items SET created_at = ? WHERE id = ?`,
      first.createdAt + 60_000,
      second.id,
    )
    const batchId = computeHolds(repo, none).find((h) => h.kind === 'backlog-review')?.id
    expect(batchId).toBeDefined()
    expect(batchId).not.toBe(soloId)

    // Discarding the newest falls back to the first item's identity — already
    // stamped, so partial triage never renotifies.
    repo.transitionBacklogItem(second.id, 'dropped', { source: 'human' })
    const fallback = computeHolds(repo, none).find((h) => h.kind === 'backlog-review')?.id
    expect(fallback).toBe(soloId)
  })

  it('a single real pending item makes the hold real', () => {
    const repo = freshRepo()
    file(repo, '/tmp/repo-e', 'Mock proposal', 'proposed')
    file(repo, '/tmp/repo-e', 'Real proposal', 'proposed', false)
    const review = computeHolds(repo, none).find((h) => h.kind === 'backlog-review')
    expect(review?.mock).toBe(false)
  })
})

describe('the foreman-proposal hold', () => {
  const spent = {
    inputTokens: 100,
    cachedInputTokens: 0,
    outputTokens: 40,
    reasoningTokens: 0,
    costUsd: 0,
  }

  function pendingProposal(repo: Repo, repoPath: string, mock = true) {
    const item = repo.fileBacklogItem({
      repoPath,
      title: 'An open item',
      source: 'manual',
      mock,
      state: 'open',
    }).item
    const session = makeSession(repo)
    const attempt = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock,
      openSnapshot: [item.id],
    })
    return repo.finalizeForemanAttempt(attempt.id, {
      state: 'proposed',
      title: 'Bound the retry path',
      rationale: 'The retry items gate the rest.',
      itemIds: [item.id],
      deferred: [],
      isolation: 'worktree',
      note: '',
      anchorSessionId: session.id,
      usage: spent,
    })
  }

  it('a pending proposal is one decision hold; deciding clears it', () => {
    const repo = freshRepo()
    const proposal = pendingProposal(repo, '/tmp/foreman-hold-a')

    const derived = computeHolds(repo, none).filter((h) => h.kind === 'foreman-proposal')
    expect(derived).toHaveLength(1)
    expect(derived[0]).toMatchObject({
      actionable: true,
      repoPath: '/tmp/foreman-hold-a',
      mock: true,
    })
    expect(derived[0]?.detail).toContain('Bound the retry path')

    // A running attempt holds nothing — there is nothing to decide yet.
    repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-hold-a',
      vendor: 'codex',
      mock: true,
      openSnapshot: [],
    })
    expect(computeHolds(repo, none).filter((h) => h.kind === 'foreman-proposal')).toHaveLength(1)

    repo.decideForemanProposal(proposal.id, 'rejected', { note: 'Not this batch.' })
    expect(computeHolds(repo, none).some((h) => h.kind === 'foreman-proposal')).toBe(false)
  })

  it('a superseding run mints a fresh identity — one fresh notification', () => {
    const repo = freshRepo()
    const first = pendingProposal(repo, '/tmp/foreman-hold-b')
    const firstHold = computeHolds(repo, none).find((h) => h.kind === 'foreman-proposal')

    const second = pendingProposal(repo, '/tmp/foreman-hold-b')
    expect(repo.getForemanProposal(first.id)?.state).toBe('superseded')
    const secondHold = computeHolds(repo, none).find((h) => h.kind === 'foreman-proposal')
    expect(secondHold?.id).toBeDefined()
    expect(secondHold?.id).not.toBe(firstHold?.id)
    expect(repo.getPendingForemanProposal('/tmp/foreman-hold-b', true)?.id).toBe(second.id)
  })

  it('coexists with the backlog-review hold on the same repository', () => {
    const repo = freshRepo()
    pendingProposal(repo, '/tmp/foreman-hold-c')
    repo.fileBacklogItem({
      repoPath: '/tmp/foreman-hold-c',
      title: 'A stow proposal awaiting triage',
      source: 'stow',
      mock: true,
      state: 'proposed',
    })

    const holds = computeHolds(repo, none)
    const kinds = holds.filter((h) => h.repoPath === '/tmp/foreman-hold-c').map((h) => h.kind)
    expect(kinds).toContain('foreman-proposal')
    expect(kinds).toContain('backlog-review')
  })

  it('a real pending proposal wears no mock flag', () => {
    const repo = freshRepo()
    pendingProposal(repo, '/tmp/foreman-hold-d', false)
    const derived = computeHolds(repo, none).find((h) => h.kind === 'foreman-proposal')
    expect(derived?.mock).toBe(false)
  })
})

describe('holds carry their repository', () => {
  it('every plan- and loop-derived hold wears a canonical repoPath, outside its identity', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    // A raw, uncanonical spelling: trailing slash survives in the plan row.
    const plan = makePlan(repo, session.id, 'awaiting-clarification', {
      repoPath: '/tmp/holds-repo/',
      question: 'Which database?',
    })

    const derived = computeHolds(repo, none).find((h) => h.kind === 'clarification')
    expect(derived?.repoPath).toBe('/tmp/holds-repo')
    // The identity folds kind, subject and generation only — repoPath must
    // never join it, or backfilling it would re-mint every notify-once stamp.
    expect(derived?.id).toBe(holdIdentity('clarification', plan.id, plan.question))

    for (const hold of computeHolds(repo, none)) {
      if (hold.planId || hold.loopId) expect(hold.repoPath).not.toBeNull()
    }
  })
})

describe('the self-update hold', () => {
  it('derives one decision hold from the green offer, repo-stamped via the plan', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id, 'complete', { mock: false })
    const attempt = repo.fileSelfUpdateAttempt(plan.id)

    // Running is a gate in progress, not an offer.
    expect(computeHolds(repo, none).some((h) => h.kind === 'self-update')).toBe(false)

    repo.finalizeSelfUpdate(attempt.id, 'green', 'built')
    const hold = computeHolds(repo, none).find((h) => h.kind === 'self-update')
    expect(hold).toBeDefined()
    expect(hold?.actionable).toBe(true)
    expect(hold?.title).toBe('A new Parley build is verified')
    expect(hold?.planId).toBe(plan.id)
    expect(hold?.repoPath).toBe(canonicalRepoPath(plan.repoPath))
    expect(hold?.detail).toContain('npm run dev')

    // Clears only by deciding — the decision arms are the m3 commands.
    repo.decideSelfUpdate(attempt.id, 'declined')
    expect(computeHolds(repo, none).some((h) => h.kind === 'self-update')).toBe(false)
  })

  it('survives its plan being deleted, degraded to null plan fields', () => {
    const repo = freshRepo()
    const attempt = repo.fileSelfUpdateAttempt('plan-that-never-existed')
    repo.finalizeSelfUpdate(attempt.id, 'green', 'built')

    const hold = computeHolds(repo, none).find((h) => h.kind === 'self-update')
    expect(hold).toBeDefined()
    expect(hold?.planId).toBeNull()
    expect(hold?.repoPath).toBeNull()
    // The verified build is real regardless; the gate never runs for mock.
    expect(hold?.mock).toBe(false)
  })

  it('a superseding attempt mints a fresh identity for its own green', () => {
    const repo = freshRepo()
    const first = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(first.id, 'green', 'built')
    const firstId = computeHolds(repo, none).find((h) => h.kind === 'self-update')?.id

    const second = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(second.id, 'green', 'built again')
    const holds = computeHolds(repo, none).filter((h) => h.kind === 'self-update')
    // One offer at a time, and its identity is new — notify-once fires again.
    expect(holds).toHaveLength(1)
    expect(holds[0]?.id).not.toBe(firstId)
  })
})
