import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Session, type Turn } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Manager } from './manager'

/**
 * Search hits arrive with their doors resolved.
 *
 * `Repo.search` says what matched; the Manager says how to get there. The
 * joins live in one place — a milestone hit's scope is a plan id, and only
 * the record knows which session and repository that plan belongs to.
 */

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function seeded(): { manager: Manager; sessionId: string; planId: string; milestoneId: string } {
  const repo = new Repo(openDatabase(':memory:'))
  const events: AppEvent[] = []
  const manager = new Manager({ repo, registry: new AgentRegistry(true), emit: (e) => events.push(e) })

  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should the retry ceiling be configurable?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  repo.createTurn({
    id: newId(),
    sessionId: session.id,
    index: 0,
    seat: 0,
    vendor: 'claude',
    model: '',
    stage: 'opening',
    text: 'Retries should surface exhaustion.',
    usage: emptyUsage(),
    startedAt: Date.now(),
    endedAt: Date.now(),
    error: null,
  } as unknown as Turn)
  const plan = repo.createPlan({
    id: newId(),
    sessionId: session.id,
    kind: 'implementation',
    title: 'Cap the retries',
    repoPath: '/repos/atlas',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree' as const,
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: false,
    createdAt: Date.now(),
  })
  const milestone = repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Surface retry exhaustion',
    intent: 'Make it observable.',
    expectedPaths: [],
    status: 'audited',
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
  })
  repo.fileBacklogItem({
    repoPath: '/repos/atlas',
    title: 'Document the retry policy',
    detail: 'Nobody can tell what the ceiling is.',
    source: 'review-finding',
    originSessionId: session.id,
    mock: false,
  })
  return { manager, sessionId: session.id, planId: plan.id, milestoneId: milestone.id }
}

describe('doors on the hits', () => {
  it('resolves a milestone through its plan to the session and repository', () => {
    const { manager, sessionId, planId, milestoneId } = seeded()
    const hit = manager.search('exhaustion').find((entry) => entry.kind === 'milestone')
    // The renderer never sees a plan-id scope it cannot open: the join
    // happened here, where the record is.
    expect(hit).toMatchObject({
      milestoneId,
      planId,
      sessionId,
      repoPath: '/repos/atlas',
    })
  })

  it('sends record kinds through their own doors', () => {
    const { manager, sessionId } = seeded()
    const hits = manager.search('retry')
    const by = (kind: string) => hits.find((entry) => entry.kind === kind)

    expect(by('turn')?.sessionId).toBe(sessionId)
    expect(by('session')?.sessionId).toBe(sessionId)
    // A backlog item lives on its repository; it has no session door even
    // though a session originated it — the item outlives the session.
    expect(by('backlog')).toMatchObject({ repoPath: '/repos/atlas', sessionId: null })
  })

  it('leaves the doors null rather than inventing them when the plan is gone', () => {
    const { manager, sessionId, planId } = seeded()
    const repoOf = (m: Manager): Repo => m.repo
    repoOf(manager).deleteSession(sessionId)
    // The milestone rows cascaded away with the plan, so only kinds that
    // survive remain; nothing throws, and no door points at a deleted row.
    const hits = manager.search('retry')
    expect(hits.every((hit) => hit.planId !== planId || hit.sessionId === null)).toBe(true)
  })
})
