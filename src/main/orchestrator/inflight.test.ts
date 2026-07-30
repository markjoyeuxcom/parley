import { describe, expect, it } from 'vitest'
import { emptyUsage } from '@shared/domain'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { newEnvelope } from './envelope'
import { computeInFlight } from './inflight'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo, status: 'running' | 'complete') {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status,
    matter: 'Should this run unattended?',
    project: '',
    repoPath: '/tmp/inflight',
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now() - 5_000,
  })
}

function makePlan(repo: Repo, sessionId: string, status: 'ready' | 'running' | 'drafting') {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Bound the retry path',
    repoPath: '/tmp/inflight',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status,
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now() - 4_000,
  })
}

function makeMilestone(repo: Repo, planId: string, status: 'audited' | 'executing') {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Add a ceiling',
    intent: 'Cap it.',
    expectedPaths: [],
    status,
    auditNote: '',
    testCommand: 'true',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now() - 3_000,
    completedAt: null,
  })
}

describe('in-flight derivation', () => {
  it('is empty when nothing runs, however much history exists', () => {
    const repo = freshRepo()
    const session = makeSession(repo, 'complete')
    const plan = makePlan(repo, session.id, 'ready')
    makeMilestone(repo, plan.id, 'audited')
    expect(computeInFlight(repo)).toEqual([])
  })

  it('reports a running envelope with a bar per cap it was given', () => {
    const repo = freshRepo()
    const session = makeSession(repo, 'complete')
    const plan = makePlan(repo, session.id, 'ready')
    const envelope = repo.createEnvelope(
      newEnvelope(plan.id, { maxMilestones: 4, maxWallClockMs: 3_600_000, maxSpendUsd: 0 }, 0),
      plan.repoPath,
    )
    repo.bumpEnvelopeMilestones(envelope.id)

    const rows = computeInFlight(repo)
    expect(rows).toHaveLength(1)
    expect(rows[0]?.kind).toBe('envelope')
    expect(rows[0]?.title).toContain('Bound the retry path')
    expect(rows[0]?.detail).toBe('1 of 4 milestones authorised')
    expect(rows[0]?.jump).toEqual({ to: 'plan', planId: plan.id })
    // Two bars, not three: a zero spend cap is disabled, so showing a spend
    // bar would imply a bound that does not exist.
    expect(rows[0]?.progress?.map((bar) => bar.label)).toEqual(['milestones', 'time'])
    expect(rows[0]?.progress?.[0]?.value).toBeCloseTo(0.25)
  })

  it('reports executing milestones, running sessions and loops, oldest first', () => {
    const repo = freshRepo()
    const running = makeSession(repo, 'running')
    const plan = makePlan(repo, running.id, 'running')
    makeMilestone(repo, plan.id, 'executing')
    repo.createLoop({
      id: newId(),
      goal: 'keep the build green',
      repoPath: '/tmp/inflight',
      worker: claude,
      verifier: codex,
      exit: { kind: 'command', command: 'true', criterion: '' },
      caps: { maxIterations: 5, maxSpendUsd: 0, maxWallClockMs: 600_000 },
      capability: 'read',
      container: false,
      approvalId: null,
      status: 'running',
      usage: emptyUsage(),
      iterationCount: 2,
      mock: true,
      startedAt: Date.now() - 1_000,
      endedAt: null,
      stopReason: '',
      lastActivityAt: null,
    })

    const rows = computeInFlight(repo)
    expect(rows.map((row) => row.kind)).toEqual(['session', 'milestone', 'loop'])
    // Oldest first: whatever has been running longest is likeliest stuck.
    expect(rows[0]!.startedAt).toBeLessThanOrEqual(rows[1]!.startedAt)
    expect(rows[1]!.startedAt).toBeLessThanOrEqual(rows[2]!.startedAt)

    const milestone = rows[1]
    expect(milestone?.detail).toContain('executing')
    expect(milestone?.jump).toMatchObject({ to: 'plan', planId: plan.id })
    expect(rows[2]?.detail).toBe('iteration 2 of 5')
  })

  it('reports a plan still being drafted or audited, before any milestone exists', () => {
    const repo = freshRepo()
    const session = makeSession(repo, 'complete')
    makePlan(repo, session.id, 'drafting')
    const rows = computeInFlight(repo)
    expect(rows).toHaveLength(1)
    expect(rows[0]?.kind).toBe('plan')
    expect(rows[0]?.detail).toBe('drafting')
  })

  it('marks mock work as mock, so fabricated activity never reads as real', () => {
    const repo = freshRepo()
    const session = makeSession(repo, 'running')
    expect(computeInFlight(repo)[0]?.mock).toBe(true)
    expect(session.mock).toBe(true)
  })
})
