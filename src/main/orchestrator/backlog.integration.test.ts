import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { canonicalRepoPath } from '@main/util/repoPath'
import { disposeLedgerFinding } from '@main/ipc/ledger'
import { Manager } from './manager'
import { backfillBacklog, backfillBacklogFromSession } from './backlog'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(repo = new Repo(openDatabase(':memory:'))): {
  repo: Repo
  manager: Manager
  events: AppEvent[]
} {
  const events: AppEvent[] = []
  const manager = new Manager({
    repo,
    registry: new AgentRegistry(true),
    emit: (event) => events.push(event),
  })
  return { repo, manager, events }
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) throw new Error('timed out waiting for condition')
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
}

async function completedReview(
  manager: Manager,
  repo: Repo,
): Promise<{ session: Session; repoPath: string }> {
  const repoPath = mkdtempSync(join(tmpdir(), 'parley-backlog-review-'))
  const session = manager.startSession({
    kind: 'review',
    matter: 'Audit the retry path for swallowed failures.',
    project: '',
    repoPath,
    participants: [claude, codex],
    maxTurns: 6,
  })
  await waitFor(() => repo.getSession(session.id)?.status === 'complete')
  return { session, repoPath }
}

function makeDebateSession(repo: Repo): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Accepted risks must not be forgotten.',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
}

function makePlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Plan in one repo',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
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

describe('deterministic backlog ingestion', () => {
  it('a completed review files its confirmed findings as open items, and replays are free', async () => {
    const { repo, manager, events } = harness()
    const { session, repoPath } = await completedReview(manager, repo)

    const confirmed = repo.listFindings(session.id).filter((f) => f.status === 'confirmed')
    expect(confirmed.length).toBeGreaterThan(0)

    const items = repo.listBacklogItems({ repoPath })
    expect(items).toHaveLength(confirmed.length)
    for (const item of items) {
      expect(item).toMatchObject({ state: 'open', source: 'review-finding', mock: true })
      expect(item.originSessionId).toBe(session.id)
      expect(item.repoPath).toBe(canonicalRepoPath(repoPath))
    }
    // Evidence and priority are copied, never referenced — Finding ids are
    // wholesale-replaced per closing and must not be leaned on.
    const withEvidence = items.filter((item) => item.evidence.length > 0)
    expect(withEvidence.length).toBeGreaterThan(0)
    expect(items.some((item) => item.priority !== null)).toBe(true)
    expect(events.some((e) => e.type === 'backlog.changed')).toBe(true)

    // Replay: everything dedupes to resights, nothing files twice.
    const replay = backfillBacklogFromSession(repo, session.id)
    expect(replay.filed).toBe(0)
    expect(replay.resighted).toBe(confirmed.length)
    expect(repo.listBacklogItems({ repoPath })).toHaveLength(confirmed.length)
  })

  it('the startup sweep back-ingests past reviews without duplicating', async () => {
    const { repo, manager } = harness()
    const { repoPath } = await completedReview(manager, repo)
    const before = repo.listBacklogItems({ repoPath }).length

    const sweep = backfillBacklog(repo)
    expect(sweep.filed).toBe(0)
    expect(sweep.resighted).toBeGreaterThan(0)
    expect(repo.listBacklogItems({ repoPath })).toHaveLength(before)
  })

  it('accepted risks carry into the backlogs of the repos they were accepted against', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeDebateSession(repo)
    const repoA = mkdtempSync(join(tmpdir(), 'parley-backlog-repoA-'))
    const repoB = mkdtempSync(join(tmpdir(), 'parley-backlog-repoB-'))
    const planA = makePlan(repo, session.id, repoA)
    const planB = makePlan(repo, session.id, repoB)

    const finding = repo.upsertLedgerFinding(
      session.id,
      'The cache key omits the tenant, so two tenants can share entries.',
    )
    const occurrenceA = repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: planA.id,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })
    repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: planB.id,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })

    const events: AppEvent[] = []
    // Occurrence-scoped acceptance files only where that occurrence lives.
    disposeLedgerFinding(
      repo,
      {
        sessionId: session.id,
        findingId: finding.id,
        occurrenceId: occurrenceA.id,
        state: 'accepted-risk',
        note: 'Single-tenant deployment for now.',
      },
      (event) => events.push(event),
    )
    expect(repo.listBacklogItems({ repoPath: repoA })).toHaveLength(1)
    expect(repo.listBacklogItems({ repoPath: repoB })).toHaveLength(0)
    const item = repo.listBacklogItems({ repoPath: repoA })[0]
    expect(item).toMatchObject({ source: 'accepted-risk', state: 'open', mock: true })
    expect(item?.detail).toContain('tenant')

    // Finding-wide acceptance covers every occurrence: repo B files, repo A
    // resights rather than duplicating.
    disposeLedgerFinding(
      repo,
      {
        sessionId: session.id,
        findingId: finding.id,
        occurrenceId: null,
        state: 'accepted-risk',
        note: 'Accepted everywhere.',
      },
      (event) => events.push(event),
    )
    expect(repo.listBacklogItems({ repoPath: repoA })).toHaveLength(1)
    expect(repo.listBacklogItems({ repoPath: repoB })).toHaveLength(1)
    const changed = events.filter((e) => e.type === 'backlog.changed')
    expect(changed.length).toBeGreaterThanOrEqual(2)
  })

  it('resolved and dismissed dispositions file nothing', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const session = makeDebateSession(repo)
    const repoA = mkdtempSync(join(tmpdir(), 'parley-backlog-quiet-'))
    const plan = makePlan(repo, session.id, repoA)
    const finding = repo.upsertLedgerFinding(session.id, 'A finding that gets resolved.')
    repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: plan.id,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })

    disposeLedgerFinding(
      repo,
      {
        sessionId: session.id,
        findingId: finding.id,
        occurrenceId: null,
        state: 'resolved',
        note: 'Fixed in the same sitting.',
      },
      () => {},
    )
    expect(repo.listBacklogItems({ repoPath: repoA })).toHaveLength(0)
  })
})
