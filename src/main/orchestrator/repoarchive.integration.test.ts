import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { Loop, Milestone, Session, WorkPlan } from '@shared/domain'
import { emptyUsage } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { canonicalRepoPath } from '@main/util/repoPath'
import { Manager } from './manager'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(): { repo: Repo; manager: Manager } {
  const repo = new Repo(openDatabase(':memory:'))
  const manager = new Manager({
    repo,
    registry: new AgentRegistry(true),
    emit: () => {},
  })
  return { repo, manager }
}

function makeSession(
  repo: Repo,
  repoPath: string,
  status: Session['status'],
  createdAt = Date.now(),
): Session {
  return repo.createSession({
    id: newId(),
    kind: 'review',
    status,
    matter: 'Review repository archive safety.',
    project: '',
    repoPath,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt,
  })
}

function makePlan(
  repo: Repo,
  sessionId: string,
  repoPath: string,
  status: WorkPlan['status'],
  title = `Plan in ${status}`,
): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title,
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status,
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
}

function makeLoop(
  repo: Repo,
  repoPath: string,
  status: Loop['status'],
  startedAt = Date.now(),
): Loop {
  return repo.createLoop({
    id: newId(),
    goal: 'Keep repository archive safety intact.',
    repoPath,
    worker: claude,
    verifier: codex,
    exit: { kind: 'command', command: 'true', criterion: '' },
    caps: { maxIterations: 2, maxSpendUsd: 0, maxWallClockMs: 60_000 },
    capability: 'read',
    container: false,
    approvalId: null,
    status,
    usage: emptyUsage(),
    iterationCount: 0,
    mock: true,
    startedAt,
    endedAt: null,
    stopReason: '',
    lastActivityAt: null,
  })
}

function makeMilestone(repo: Repo, planId: string): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Archive safely',
    intent: 'Refuse while this milestone runs.',
    expectedPaths: [],
    status: 'complete',
    auditNote: '',
    testCommand: '',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: true,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: Date.now(),
  })
}

describe('repository archive attention', () => {
  it('uses uncapped durable reads and names every durable reason', () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-repo-archive-durable-'))
    const activeSession = makeSession(repo, repoPath, 'running', 1)
    makeSession(repo, repoPath, 'stopping', 2)
    for (let index = 0; index < 200; index += 1) {
      makeSession(repo, repoPath, 'complete', 100 + index)
    }
    expect(repo.listSessions(200, true)).not.toContainEqual(activeSession)

    const activeLoop = makeLoop(repo, repoPath, 'running', 1)
    makeLoop(repo, repoPath, 'paused', 2)
    for (let index = 0; index < 200; index += 1) {
      makeLoop(repo, repoPath, 'succeeded', 100 + index)
    }
    expect(repo.listLoops(200)).not.toContainEqual(activeLoop)

    const anchor = makeSession(repo, repoPath, 'complete')
    for (const status of ['drafting', 'auditing', 'correcting', 'running'] as const) {
      makePlan(repo, anchor.id, repoPath, status)
    }

    const pending = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })
    repo.finalizeForemanAttempt(pending.id, {
      state: 'proposed',
      title: 'Pending archive work',
      rationale: 'The repository still needs work.',
      itemIds: [],
      deferred: [],
      isolation: 'worktree',
      note: '',
      anchorSessionId: anchor.id,
      usage: emptyUsage(),
    })
    repo.fileForemanAttempt({
      repoPath,
      vendor: 'codex',
      mock: true,
      openSnapshot: [],
    })

    const runningUpdatePlan = makePlan(repo, anchor.id, repoPath, 'complete', 'Running update')
    repo.fileSelfUpdateAttempt(runningUpdatePlan.id)
    const greenUpdatePlan = makePlan(repo, anchor.id, repoPath, 'complete', 'Green update')
    const green = repo.fileSelfUpdateAttempt(greenUpdatePlan.id)
    repo.finalizeSelfUpdate(green.id, 'green', 'Ready to relaunch.')

    let message = ''
    try {
      manager.setRepoArchived(repoPath, true)
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
    }
    expect(message).toContain('a session is running')
    expect(message).toContain('a session is stopping')
    expect(message).toContain('a loop is running')
    expect(message).toContain('a loop is paused')
    for (const status of ['drafting', 'auditing', 'correcting', 'running']) {
      expect(message).toContain(`a plan is ${status}`)
    }
    expect(message).toContain('a foreman attempt is running')
    expect(message).toContain('a foreman proposal is pending')
    expect(message).toContain('a self-update is running')
    expect(message).toContain('a self-update is awaiting a decision')
    expect(repo.archivedRepoPaths()).toEqual([])
  })

  it('refuses every in-process run associated with the repository', () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-repo-archive-memory-'))
    const canonical = canonicalRepoPath(repoPath)
    const session = makeSession(repo, repoPath, 'complete')
    const plan = makePlan(repo, session.id, repoPath, 'complete')
    const milestone = makeMilestone(repo, plan.id)
    const internals = manager as unknown as {
      stowRuns: Set<string>
      foremanRuns: Set<string>
      milestoneRuns: Map<string, unknown>
      selfGateRuns: Map<string, AbortController>
      selfGateQueue: Map<string, unknown>
    }
    internals.stowRuns.add(session.id)
    internals.foremanRuns.add(canonical)
    internals.milestoneRuns.set(milestone.id, {})
    internals.selfGateRuns.set(canonical, new AbortController())
    internals.selfGateQueue.set(canonical, {})

    expect(() => manager.setRepoArchived(repoPath, true)).toThrow(
      /a stow sweep is running.*the foreman is reading this repository.*a milestone is running.*a self-update gate is running.*a self-update gate is queued/,
    )

    internals.stowRuns.clear()
    internals.foremanRuns.clear()
    internals.milestoneRuns.clear()
    internals.selfGateRuns.clear()
    internals.selfGateQueue.clear()
    manager.setRepoArchived(repoPath, true)
    expect(repo.archivedRepoPaths()).toEqual([canonical])
  })

  it('does not archive or hide a derived hold', () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-repo-archive-hold-'))
    const item = repo.fileBacklogItem({
      repoPath,
      title: 'Review this proposal',
      source: 'manual',
      mock: true,
      state: 'proposed',
    }).item
    const before = manager.listHolds().filter((hold) => hold.repoPath === canonicalRepoPath(repoPath))
    expect(before).toHaveLength(1)

    expect(() => manager.setRepoArchived(repoPath, true)).toThrow(/a hold needs attention/)
    expect(repo.archivedRepoPaths()).toEqual([])
    expect(manager.listHolds().filter((hold) => hold.repoPath === canonicalRepoPath(repoPath))).toEqual(
      before,
    )

    repo.transitionBacklogItem(item.id, 'dropped', { source: 'human', note: 'Not needed.' })
    manager.setRepoArchived(repoPath, true)
    expect(repo.archivedRepoPaths()).toEqual([canonicalRepoPath(repoPath)])
  })

  it('records restoration as new repository activity', () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-repo-archive-restore-'))
    manager.setRepoArchived(repoPath, true)
    const archivedAt = repo.repoActivitySeq(repoPath)

    manager.setRepoArchived(repoPath, false)

    expect(repo.repoActivitySeq(repoPath)).toBe(archivedAt + 1)
    expect(repo.archivedRepoPaths()).toEqual([])
  })
})
