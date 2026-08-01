import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import type { Hold } from '@shared/holds'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Manager } from './manager'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(repo = new Repo(openDatabase(':memory:'))): {
  repo: Repo
  manager: Manager
  events: AppEvent[]
  notifications: string[]
} {
  const events: AppEvent[] = []
  const notifications: string[] = []
  const manager = new Manager({
    repo,
    registry: new AgentRegistry(true),
    emit: (event) => events.push(event),
    notifyUser: (title) => notifications.push(title),
  })
  return { repo, manager, events, notifications }
}

/** Lets every scheduled microtask recompute (and any timer) run. */
async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0))
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) throw new Error('timed out waiting for condition')
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
}

function makeSession(repo: Repo, withVerdict = false): Session {
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should holds notify exactly once?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  if (withVerdict) {
    repo.saveVerdict({
      sessionId: session.id,
      decision: 'Proceed.',
      rationale: '',
      scores: { clarity: 7, correctness: 7, maintainability: 7, risk: 3, robustness: 7 },
      confidence: 0.8,
      dissent: '',
      report: '',
      createdAt: Date.now(),
    })
  }
  return session
}

function makeParkedPlan(repo: Repo, sessionId: string, question: string): WorkPlan {
  const plan = repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'implementation plan',
    repoPath: '/tmp/example',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'drafting',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout' as const,
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
  repo.askPlanQuestion(plan.id, question, { stage: 'planning' })
  return plan
}

function makeFailedMilestone(repo: Repo, sessionId: string): { plan: WorkPlan; milestone: Milestone } {
  const plan = repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'failing plan',
    repoPath: '/tmp/example',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout' as const,
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
  const milestone = repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Fix the retry path',
    intent: 'Make retries observable.',
    expectedPaths: [],
    status: 'failed',
    auditNote: '',
    testCommand: '',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: 'Round 1 — the reviewer objected.',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
  })
  return { plan, milestone }
}

function holdsEvents(events: AppEvent[]): Array<Extract<AppEvent, { type: 'holds.changed' }>> {
  return events.filter((e): e is Extract<AppEvent, { type: 'holds.changed' }> => e.type === 'holds.changed')
}

describe('holds engine', () => {
  it('a plan parked mid-run becomes a clarification hold, and the answer path no longer blocks', async () => {
    const { repo, manager, events, notifications } = harness()
    const session = makeSession(repo, true)

    // The mock planner parks on a question when the repo path carries ASK_ME.
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-holds-ASK_ME-'))
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })

    await waitFor(() => repo.getPlan(plan.id)?.status === 'awaiting-clarification')
    await settle()

    const published = holdsEvents(events).at(-1)?.holds ?? []
    const clarification = published.find((h) => h.kind === 'clarification')
    if (!clarification) throw new Error('expected a clarification hold to be published')
    // Bug fix #1 pinned: the live payload carries the question text, which the
    // plan.status event never did.
    expect(clarification.detail).toBe(repo.getPlan(plan.id)?.question)
    expect(clarification.detail.length).toBeGreaterThan(0)
    expect(notifications.some((title) => title.includes('Waiting on your answer'))).toBe(true)

    // Bug fix #2 pinned: answerPlan returns before the resumed pipeline
    // settles, and whenPlanSettled covers the resumed run.
    const answered = manager.answerPlan(plan.id, 'Use the simplest option.')
    expect(answered.plan.id).toBe(plan.id)
    // The resumed run is still in flight when the call returns — the status is
    // whatever the resumed stage wrote synchronously, never a settled one.
    expect(['ready', 'failed', 'blocked', 'complete']).not.toContain(
      repo.getPlan(plan.id)?.status ?? '',
    )

    await manager.whenPlanSettled(plan.id)
    expect(repo.getPlan(plan.id)?.status).toBe('ready')

    await settle()
    const finalHolds = manager.listHolds()
    expect(finalHolds.some((h) => h.kind === 'clarification')).toBe(false)
    // The plan is now approvable, so the queue moved rather than emptied.
    // Whether the approval is free or gated depends on what the mock audit
    // left in the ledger; either way it is one actionable hold on this plan.
    const decision = finalHolds.find((h) => h.planId === plan.id && h.actionable)
    expect(decision).toBeTruthy()
    expect(['approval-waiting', 'ledger-gated']).toContain(decision?.kind ?? '')
  })

  it('notifies each hold once, ever — including across engine lifetimes on one database', async () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    makeParkedPlan(repo, session.id, 'Which region should the bucket live in?')

    const first = harness(repo)
    await settle()
    expect(first.notifications).toHaveLength(1)
    expect(holdsEvents(first.events)).toHaveLength(1)

    // A fresh engine over the same database — a restart — must not renotify.
    const second = harness(repo)
    await settle()
    expect(second.notifications).toHaveLength(0)
    // It still publishes the standing snapshot for the fresh window.
    expect(holdsEvents(second.events)).toHaveLength(1)
  })

  it('prefixes mock hold notifications so fabricated waiting work reads as such', async () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    makeParkedPlan(repo, session.id, 'Mock question?')

    const { notifications } = harness(repo)
    await settle()
    expect(notifications).toEqual(['Mock — Waiting on your answer'])
  })

  it('refuses to acknowledge a decision hold, in the main process rather than the UI', async () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    makeParkedPlan(repo, session.id, 'May I proceed?')
    const { manager } = harness(repo)
    await settle()

    const clarification = manager.listHolds().find((h) => h.kind === 'clarification')
    if (!clarification) throw new Error('expected a clarification hold')
    expect(() => manager.ackHold(clarification.id)).toThrow(/clears by acting/)
    expect(manager.listHolds().some((h) => h.id === clarification.id)).toBe(true)
  })

  it('tells a parked milestone apart from a failed one, and names what could not start', async () => {
    // The two look identical in a queue and send someone to opposite places:
    // a failure to the diff, a park to the machine. Rendering both as "a
    // milestone failed" is what made a missing interpreter look like broken
    // code for two paid remediation rounds.
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    const { milestone } = makeFailedMilestone(repo, session.id)
    repo.updateMilestone(milestone.id, {
      status: 'parked',
      testCommand: 'npm test',
      testResult: {
        command: 'npm test',
        exitCode: -1,
        signal: null,
        timedOut: false,
        startError: 'spawn npm ENOENT',
        stdout: '',
        stderr: '\nspawn error: spawn npm ENOENT',
        durationMs: 0,
        ranAt: Date.now(),
      },
    })
    const { manager } = harness(repo)
    await settle()

    const holds = manager.listHolds()
    expect(holds.some((h) => h.kind === 'milestone-failed')).toBe(false)
    const parked = holds.find((h) => h.kind === 'milestone-parked')
    if (!parked) throw new Error('expected a milestone-parked hold')

    // Both the command and the reason, because neither alone is actionable.
    expect(parked.title).toContain('could not run')
    expect(parked.detail).toContain('npm test')
    expect(parked.detail).toContain('spawn npm ENOENT')

    // A notice: it is real waiting, but nothing in Parley can clear it, so it
    // must not sit in the badge count as though a click would resolve it.
    expect(parked.actionable).toBe(false)

    // Fixing one missing thing and hitting a different one is a new
    // situation, and acknowledging the first must not hide the second.
    const acked = manager.ackHold(parked.id)
    expect(acked.some((h) => h.id === parked.id)).toBe(false)
    repo.updateMilestone(milestone.id, {
      testResult: {
        command: 'npm test',
        exitCode: -1,
        signal: null,
        timedOut: false,
        startError: 'spawn npm EACCES',
        stdout: '',
        stderr: '',
        durationMs: 0,
        ranAt: Date.now(),
      },
    })
    const again = manager.listHolds().find((h) => h.kind === 'milestone-parked')
    expect(again).toBeTruthy()
    expect(again?.id).not.toBe(parked.id)
  })

  it('acknowledges a failed milestone, and a fresh failure reopens as a new hold', async () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    const { milestone } = makeFailedMilestone(repo, session.id)
    const { manager, events } = harness(repo)
    await settle()

    const failed = manager.listHolds().find((h) => h.kind === 'milestone-failed')
    if (!failed) throw new Error('expected a milestone-failed hold')

    const after = manager.ackHold(failed.id)
    expect(after.some((h) => h.id === failed.id)).toBe(false)
    // The ack publishes immediately — the queue a second window would hydrate
    // and the one this window holds must agree.
    const lastPublished = holdsEvents(events).at(-1)?.holds ?? []
    expect(lastPublished.some((h: Hold) => h.id === failed.id)).toBe(false)

    // The same milestone failing again is new waiting, not the acked hold.
    repo.updateMilestone(milestone.id, {
      reviewNote: 'Round 1 — the reviewer objected.\nRound 2 — still failing.',
    })
    const reopened = manager.listHolds().find((h) => h.kind === 'milestone-failed')
    expect(reopened).toBeTruthy()
    expect(reopened?.id).not.toBe(failed.id)
  })

  it('does not republish an unchanged snapshot however many events arrive', async () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeSession(repo)
    makeParkedPlan(repo, session.id, 'Still here?')
    const { manager, events } = harness(repo)
    await settle()
    const before = holdsEvents(events).length

    // Status events that change nothing about the derived set.
    manager['deps'].emit({ type: 'session.status', sessionId: session.id, status: 'complete' })
    manager['deps'].emit({ type: 'session.status', sessionId: session.id, status: 'complete' })
    await settle()

    expect(holdsEvents(events)).toHaveLength(before)
  })
})
