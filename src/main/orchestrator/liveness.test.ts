import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Loop, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { LivenessWatchdog } from './liveness'
import { Pipeline, type RunState } from './pipeline'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Is silence a signal?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: 0,
  })
}

function makePlan(repo: Repo, sessionId: string, status: WorkPlan['status'] = 'running'): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Watched plan',
    repoPath: '/tmp/example',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status,
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout',
    setupCommand: '',
    usage: emptyUsage(),
    mock: true,
    createdAt: 0,
  })
}

function makeMilestone(repo: Repo, planId: string, status: Milestone['status']): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Watched milestone',
    intent: 'Emit activity, or not.',
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
    createdAt: 0,
    completedAt: null,
  })
}

function makeLoop(repo: Repo, status: Loop['status']): Loop {
  return repo.createLoop({
    id: newId(),
    goal: 'Stay busy',
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
    mock: true,
    startedAt: 0,
    endedAt: null,
    stopReason: '',
  })
}

function seedRunState(repo: Repo, milestoneId: string): void {
  repo.setMilestoneRunState(milestoneId, {
    startedAt: 0,
    round: 0,
    previousConcerns: [],
    reviewerNote: '',
    executionReport: 'partway through',
    executorResumeId: null,
    reviewerResumeId: null,
    before: { paths: [], signature: 'x', unknown: false },
    baselineHead: 'a'.repeat(40),
    lastActivityAt: null,
    lastInspection: null,
  })
}

function harness(stallAfterMs = 1_000): {
  repo: Repo
  watchdog: LivenessWatchdog
  clock: { t: number }
  holdsCalls: number[]
  inspections: string[]
  milestone: Milestone
  activityEvent: AppEvent
  inFlightEvent: AppEvent
} {
  const repo = freshRepo()
  const session = makeSession(repo)
  const plan = makePlan(repo, session.id)
  const milestone = makeMilestone(repo, plan.id, 'executing')
  seedRunState(repo, milestone.id)

  const clock = { t: 100_000 }
  const holdsCalls: number[] = []
  const inspections: string[] = []
  const watchdog = new LivenessWatchdog({
    repo,
    holdsChanged: () => holdsCalls.push(clock.t),
    inspectMilestone: (id) => inspections.push(id),
    now: () => clock.t,
    stallAfterMs,
  })
  const inFlightEvent: AppEvent = { type: 'plan.milestone', milestone }
  const activityEvent: AppEvent = {
    type: 'plan.activity',
    milestoneId: milestone.id,
    phase: 'executing',
    text: 'editing a file',
  }
  return { repo, watchdog, clock, holdsCalls, inspections, milestone, activityEvent, inFlightEvent }
}

function stamped(repo: Repo, milestoneId: string): number | null {
  return repo.getMilestoneRunState<RunState>(milestoneId)?.lastActivityAt ?? null
}

describe('LivenessWatchdog', () => {
  it('seeds tracking from the in-flight transition, so a spawn hang is still caught', () => {
    const { repo, watchdog, clock, inspections, milestone, inFlightEvent } = harness()
    watchdog.observe(inFlightEvent)
    expect(stamped(repo, milestone.id)).toBe(clock.t)

    // No activity ever arrives — the seed alone must trip the stall.
    clock.t += 5_000
    watchdog.tick()
    expect(inspections).toEqual([milestone.id])
  })

  it('inspects once per episode, however many ticks pass', () => {
    const { watchdog, clock, inspections, milestone, inFlightEvent } = harness()
    watchdog.observe(inFlightEvent)
    clock.t += 5_000
    watchdog.tick()
    watchdog.tick()
    clock.t += 5_000
    watchdog.tick()
    expect(inspections).toEqual([milestone.id])
  })

  it('resumed activity ends the episode, persists immediately, and re-arms the inspection', () => {
    const { repo, watchdog, clock, holdsCalls, inspections, milestone, inFlightEvent, activityEvent } =
      harness()
    watchdog.observe(inFlightEvent)
    clock.t += 5_000
    watchdog.tick()
    expect(inspections).toHaveLength(1)

    const before = holdsCalls.length
    watchdog.observe(activityEvent)
    // The stall just ended: the stamp updates now (not on the throttle), and
    // the recompute is asked for so the hold clears.
    expect(stamped(repo, milestone.id)).toBe(clock.t)
    expect(holdsCalls.length).toBeGreaterThan(before)

    clock.t += 5_000
    watchdog.tick()
    expect(inspections).toHaveLength(2)
  })

  it('throttles healthy-activity persistence but never falls behind the threshold', () => {
    const { repo, watchdog, clock, milestone, inFlightEvent, activityEvent } = harness(120_000)
    watchdog.observe(inFlightEvent)
    const first = stamped(repo, milestone.id)

    clock.t += 10_000
    watchdog.observe(activityEvent)
    // Within the throttle: memory moved, the stamp did not.
    expect(stamped(repo, milestone.id)).toBe(first)

    clock.t += 55_000
    watchdog.observe(activityEvent)
    expect(stamped(repo, milestone.id)).toBe(clock.t)
  })

  it('terminal transitions forget the run', () => {
    const { repo, watchdog, clock, inspections, milestone, inFlightEvent } = harness()
    watchdog.observe(inFlightEvent)
    const settled = { ...repo.getMilestone(milestone.id)!, status: 'complete' as const }
    watchdog.observe({ type: 'plan.milestone', milestone: settled })
    clock.t += 5_000
    watchdog.tick()
    expect(inspections).toEqual([])
  })

  it('tracks loops through their own column', () => {
    const repo = freshRepo()
    const loop = makeLoop(repo, 'running')
    const clock = { t: 50_000 }
    const watchdog = new LivenessWatchdog({
      repo,
      holdsChanged: () => {},
      inspectMilestone: () => {},
      now: () => clock.t,
      stallAfterMs: 1_000,
    })
    watchdog.observe({ type: 'loop.status', loopId: loop.id, status: 'running' })
    expect(repo.getLoop(loop.id)?.lastActivityAt).toBe(clock.t)
  })
})

describe('the stall inspection', () => {
  it('lands a verdict in the run state without touching anything', async () => {
    const repo = freshRepo()
    const registry = new AgentRegistry(true)
    const pipeline = new Pipeline({ repo, registry, emit: () => {} })
    const session = makeSession(repo)
    const plan = makePlan(repo, session.id)
    const milestone = makeMilestone(repo, plan.id, 'executing')
    seedRunState(repo, milestone.id)

    await pipeline.inspectStalledMilestone(milestone.id)

    const state = repo.getMilestoneRunState<RunState>(milestone.id)
    expect(state?.lastInspection).not.toBeNull()
    expect(['progressing', 'stuck', 'unclear']).toContain(state?.lastInspection?.verdict ?? '')
    expect((state?.lastInspection?.note ?? '').length).toBeGreaterThan(0)
    // The wire summary carries it too, for the stall hold's detail.
    expect(repo.getMilestone(milestone.id)?.runState?.lastInspection).not.toBeNull()
  })
})
