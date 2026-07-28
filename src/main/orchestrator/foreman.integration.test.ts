import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Session } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { canonicalRepoPath } from '@main/util/repoPath'
import { Manager } from './manager'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

type Recorded = { systemPrompt: string; prompt: string; cwd: string }

function harness(): {
  repo: Repo
  manager: Manager
  events: AppEvent[]
  registry: AgentRegistry
} {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const manager = new Manager({
    repo,
    registry,
    emit: (event) => events.push(event),
  })
  return { repo, manager, events, registry }
}

function requestsOf(registry: AgentRegistry, vendor: 'claude' | 'codex'): Recorded[] {
  return (registry.get(vendor) as unknown as { requests: Recorded[] }).requests
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error('timed out waiting for condition')
}

/** A completed mock review whose confirmed findings become open items. */
async function reviewedRepo(
  manager: Manager,
  repo: Repo,
  repoPath: string,
): Promise<Session> {
  const session = manager.startSession({
    kind: 'review',
    matter: 'Audit the retry path for swallowed failures.',
    project: '',
    repoPath,
    participants: [claude, codex],
    maxTurns: 6,
  })
  await waitFor(() => repo.getSession(session.id)?.status === 'complete')
  return session
}

describe('the foreman run', () => {
  it('reads the backlog and files a pending proposal anchored to the record', async () => {
    const { repo, manager, events, registry } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-run-'))
    const session = await reviewedRepo(manager, repo, repoPath)
    const open = repo.listBacklogItems({ repoPath, states: ['open'] })
    expect(open.length).toBeGreaterThan(0)
    const learning = repo.fileLearning({
      repoPath,
      text: 'The retry tests only pass against a cold cache.',
      source: 'manual',
      mock: true,
    }).learning

    const proposal = await manager.runForeman(repoPath, claude)

    expect(proposal.state).toBe('proposed')
    expect(proposal.repoPath).toBe(canonicalRepoPath(repoPath))
    expect(proposal.itemIds.length).toBeGreaterThan(0)
    for (const id of proposal.itemIds) {
      expect(open.some((item) => item.id === id)).toBe(true)
    }
    // The snapshot is every open item shown, not just the chosen ones.
    expect([...proposal.openSnapshot].sort()).toEqual(open.map((i) => i.id).sort())
    expect(proposal.anchorSessionId).toBe(session.id)
    expect(proposal.usage.inputTokens).toBeGreaterThan(0)
    expect(proposal.isolation).toBe('worktree')
    expect(proposal.note).toMatch(/land the cap/i)
    expect(repo.getPendingForemanProposal(repoPath, true)?.id).toBe(proposal.id)
    expect(events.filter((e) => e.type === 'backlog.changed').length).toBeGreaterThanOrEqual(2)

    // What the foreman was actually shown: id-bearing records framed as
    // records, the confirmed learning, and the output contract.
    const request = requestsOf(registry, 'claude').at(-1)
    expect(request?.systemPrompt).toContain('You are the foreman')
    expect(request?.prompt).toContain(`(id: ${open[0]?.id})`)
    expect(request?.prompt).toContain('recorded data under review')
    expect(request?.prompt).toContain(learning.text)
    expect(request?.prompt).toContain('"itemIds"')
  })

  it('a rerun supersedes the pending; a failed rerun leaves it intact', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-super-'))
    await reviewedRepo(manager, repo, repoPath)

    const first = await manager.runForeman(repoPath, claude)
    const second = await manager.runForeman(repoPath, codex)
    expect(repo.getForemanProposal(first.id)?.state).toBe('superseded')
    expect(repo.getPendingForemanProposal(repoPath, true)?.id).toBe(second.id)

    // Two fresh manual items with no origin session become the mock's
    // selection (newest first), so the anchor rule fails — honestly, as a
    // failed row with the spend attached — and the pending survives.
    repo.fileBacklogItem({
      repoPath,
      title: 'Manually filed, no origin session A.',
      source: 'manual',
      mock: true,
      state: 'open',
    })
    repo.fileBacklogItem({
      repoPath,
      title: 'Manually filed, no origin session B.',
      source: 'manual',
      mock: true,
      state: 'open',
    })
    await expect(manager.runForeman(repoPath, claude)).rejects.toThrow(/session with a verdict/)
    const failed = repo
      .listForemanProposals({ repoPath, states: ['failed'] })
      .sort((a, b) => b.createdAt - a.createdAt)[0]
    expect(failed).toBeDefined()
    expect(failed?.usage.inputTokens).toBeGreaterThan(0)
    expect(repo.getPendingForemanProposal(repoPath, true)?.id).toBe(second.id)
  })

  it('an unparseable reply finalizes failed with the spend recorded', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-FOREMAN_UNREADABLE-'))
    await reviewedRepo(manager, repo, repoPath)

    await expect(manager.runForeman(repoPath, claude)).rejects.toThrow(/nothing parseable/)
    const failed = repo.listForemanProposals({ repoPath, states: ['failed'] })[0]
    expect(failed).toBeDefined()
    expect(failed?.usage.inputTokens).toBeGreaterThan(0)
    expect(failed?.decisionNote).toMatch(/parseable/)
  })

  it('pre-turn refusals spend nothing and file nothing', async () => {
    const { repo, manager } = harness()
    const empty = mkdtempSync(join(tmpdir(), 'parley-foreman-empty-'))
    await expect(manager.runForeman(empty, claude)).rejects.toThrow(/no open items/)
    expect(repo.listForemanProposals({ repoPath: empty })).toHaveLength(0)

    // The in-flight guard is synchronous: a second call refuses while the
    // first holds the repo, and files nothing for it.
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-guard-'))
    await reviewedRepo(manager, repo, repoPath)
    const inFlight = manager.runForeman(repoPath, claude)
    await expect(manager.runForeman(repoPath, claude)).rejects.toThrow(/already reading/)
    await inFlight
    expect(repo.listForemanProposals({ repoPath })).toHaveLength(1)
  })

  it('an item planned mid-turn is dropped from the proposal with the honest note', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-race-'))
    const session = await reviewedRepo(manager, repo, repoPath)
    // A second anchored item, so dropping the raced one still leaves a valid
    // selection (the mock review confirms exactly one finding).
    repo.fileBacklogItem({
      repoPath,
      title: 'A second item the race does not touch.',
      source: 'manual',
      originSessionId: session.id,
      mock: true,
      state: 'open',
    })
    const open = repo.listBacklogItems({ repoPath, states: ['open'] })
    expect(open.length).toBeGreaterThanOrEqual(2)
    const racedAway = open[0]
    if (!racedAway) throw new Error('expected an open item')

    const racingPlan = repo.createPlan({
      id: newId(),
      sessionId: session.id,
      kind: 'implementation',
      title: 'A plan racing the foreman',
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
      usage: emptyUsage(),
      mock: true,
      createdAt: Date.now(),
    })

    // Start the run, then flip the first-listed item to planned while the
    // mock turn is in flight. Validation happens after the reply, against
    // the world as it is then — the item drops with a note, never a false
    // proposal.
    const running = manager.runForeman(repoPath, claude)
    repo.transitionBacklogItem(racedAway.id, 'planned', {
      source: 'human',
      planId: racingPlan.id,
    })
    const proposal = await running

    expect(proposal.itemIds).not.toContain(racedAway.id)
    expect(proposal.decisionNote).toMatch(/not an open item/i)
  })

  it('interrupted attempts reconcile to failed at startup, pending untouched', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-reconcile-'))
    await reviewedRepo(manager, repo, repoPath)
    const pending = await manager.runForeman(repoPath, claude)
    const orphan = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })

    // index.ts runs this beside reconcileInterrupted at every startup.
    expect(repo.reconcileForemanAttempts()).toBe(1)
    expect(repo.getForemanProposal(orphan.id)?.state).toBe('failed')
    expect(repo.getPendingForemanProposal(repoPath, true)?.id).toBe(pending.id)
  })
})

describe('atomic acceptance through plan creation', () => {
  it('one act: plan created, items planned, proposal accepted, hold cleared', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-accept-'))
    await reviewedRepo(manager, repo, repoPath)
    const proposal = await manager.runForeman(repoPath, claude)
    expect(proposal.anchorSessionId).toBeTruthy()

    const { plan } = await manager.createPlan({
      sessionId: proposal.anchorSessionId as string,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
      backlogItemIds: proposal.itemIds,
      foremanProposalId: proposal.id,
    })

    for (const itemId of proposal.itemIds) {
      expect(repo.getBacklogItem(itemId)).toMatchObject({ state: 'planned', planId: plan.id })
    }
    expect(repo.getForemanProposal(proposal.id)).toMatchObject({
      state: 'accepted',
      planId: plan.id,
    })
    expect(repo.getPendingForemanProposal(repoPath, true)).toBeNull()
    await manager.whenPlanSettled(plan.id)
  })

  it('a superseded proposal refuses before anything is created', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-stale-'))
    await reviewedRepo(manager, repo, repoPath)
    const first = await manager.runForeman(repoPath, claude)
    const second = await manager.runForeman(repoPath, codex)
    const plansBefore = repo.listPlans().length

    await expect(
      manager.createPlan({
        sessionId: first.anchorSessionId as string,
        kind: 'implementation',
        repoPath,
        planner: claude,
        executor: codex,
        reviewer: claude,
        backlogItemIds: first.itemIds,
        foremanProposalId: first.id,
      }),
    ).rejects.toThrow(/superseded by a newer run/)

    expect(repo.listPlans().length).toBe(plansBefore)
    for (const itemId of first.itemIds) {
      expect(repo.getBacklogItem(itemId)?.state).toBe('open')
    }
    expect(repo.getPendingForemanProposal(repoPath, true)?.id).toBe(second.id)
  })

  it('acceptance is refused from any session but the anchor', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-foreman-anchor-'))
    await reviewedRepo(manager, repo, repoPath)
    const proposal = await manager.runForeman(repoPath, claude)

    // A different completed session, verdict and all.
    const other = manager.startSession({
      kind: 'debate',
      matter: 'An unrelated decision.',
      project: '',
      repoPath: null,
      participants: [claude, codex],
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(other.id)?.status === 'complete')

    await expect(
      manager.createPlan({
        sessionId: other.id,
        kind: 'implementation',
        repoPath,
        planner: claude,
        executor: codex,
        reviewer: claude,
        backlogItemIds: proposal.itemIds,
        foremanProposalId: proposal.id,
      }),
    ).rejects.toThrow(/anchor session/)
    expect(repo.getForemanProposal(proposal.id)?.state).toBe('proposed')
  })
})
