import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Session } from '@shared/domain'
import { occurrenceState } from '@shared/ledger'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { canonicalRepoPath } from '@main/util/repoPath'
import { Manager } from './manager'
import { regressPlannedItems } from './backlog'

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
    worktreesRoot: mkdtempSync(join(tmpdir(), 'parley-briefroot-')),
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

/** A throwaway git repository with one seed commit, for worktree plans. */
function gitRepo(prefix: string): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath })
  }
  git('init', '-q')
  git('config', 'user.email', 't@e.invalid')
  git('config', 'user.name', 't')
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  git('commit', '-qm', 'seed')
  return repoPath
}

/**
 * A completed mock review against `repoPath`, which the deterministic
 * ingestion turns into open backlog items — the raw material every scenario
 * here starts from.
 */
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

function disposeOpenBlockingOccurrences(repo: Repo, sessionId: string): void {
  const dispositions = repo.listFindingDispositions(sessionId)
  for (const occurrence of repo.listFindingOccurrences(sessionId)) {
    if (
      occurrence.kind !== 'blocking' ||
      occurrenceState(occurrence, dispositions) !== 'open'
    ) {
      continue
    }
    repo.disposeFinding({
      findingId: occurrence.findingId,
      occurrenceId: occurrence.id,
      state: 'accepted-risk',
      note: 'The test operator explicitly accepted this audited risk.',
      source: 'human',
    })
  }
}

describe('backlog items in plan briefs and their lifecycle', () => {
  it('selected items ride the brief with the learnings, flip planned, and completion proposes closure', async () => {
    const { repo, manager, events, registry } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-brief-checkout-'))
    const session = await reviewedRepo(manager, repo, repoPath)

    const open = repo.listBacklogItems({ repoPath })
    expect(open.length).toBeGreaterThan(0)
    const selected = open[0]
    if (!selected) throw new Error('expected an open item')
    const learning = repo.fileLearning({
      repoPath,
      text: 'The retry tests only pass when run against a cold cache.',
      source: 'manual',
      mock: true,
    }).learning
    expect(learning.state).toBe('confirmed')

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
      backlogItemIds: [selected.id],
    })

    // The flip happened in the same synchronous stretch as row creation —
    // by the time createPlan resolves, the selection is already bound.
    const planned = repo.getBacklogItem(selected.id)
    expect(planned).toMatchObject({ state: 'planned', planId: plan.id })
    // Unselected items are untouched.
    for (const other of open.slice(1)) {
      expect(repo.getBacklogItem(other.id)?.state).toBe('open')
    }

    await manager.whenPlanSettled(plan.id)
    expect(repo.getPlan(plan.id)?.status).toBe('ready')

    // The planner was actually told: the brief carries the items block with
    // the selected title, and the repo's confirmed learnings, attributed.
    const briefed = requestsOf(registry, 'claude').filter((request) =>
      request.prompt.includes('THE BACKLOG ITEMS TO ADDRESS'),
    )
    expect(briefed.length).toBeGreaterThan(0)
    for (const request of briefed) {
      expect(request.prompt).toContain(selected.title)
      expect(request.prompt).toContain('WHAT THIS REPOSITORY HAS TAUGHT US')
      expect(request.prompt).toContain(learning.text)
    }

    // Run the plan's single milestone to completion in the live checkout.
    const first = repo.listMilestones(plan.id)[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      testCommand: 'true',
      expectedPaths: ['parley-mock-work.txt'],
    })
    disposeOpenBlockingOccurrences(repo, session.id)
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    const changedBefore = events.filter((e) => e.type === 'backlog.changed').length
    const done = await manager.runMilestone(first.id, approval.id)
    expect(done.status).toBe('complete')
    expect(repo.getPlan(plan.id)?.status).toBe('complete')

    // Checkout plans propose closure at completion — the work is already in
    // the tree. Proposed, never closed: the item waits for a human.
    const after = repo.getBacklogItem(selected.id)
    expect(after?.state).toBe('closure-proposed')
    const trail = repo.listBacklogEvents(selected.id)
    const closure = trail.find((event) => event.kind === 'closure-proposed')
    expect(closure?.source).toBe('pipeline')
    expect(events.filter((e) => e.type === 'backlog.changed').length).toBeGreaterThan(
      changedBefore,
    )
  })

  it('a bad selection refuses before any plan row exists', async () => {
    const { repo, manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-brief-refuse-'))
    const session = await reviewedRepo(manager, repo, repoPath)
    const plansBefore = repo.listPlans().length

    const base = {
      sessionId: session.id,
      kind: 'implementation' as const,
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    }

    // A different repository's item.
    const elsewhere = repo.fileBacklogItem({
      repoPath: mkdtempSync(join(tmpdir(), 'parley-brief-other-')),
      title: 'An item that lives in another repository entirely.',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    await expect(
      manager.createPlan({ ...base, backlogItemIds: [elsewhere.id] }),
    ).rejects.toThrow(/different repository/i)

    // An item that is no longer open.
    const dropped = repo.fileBacklogItem({
      repoPath,
      title: 'An item the operator already dropped.',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    repo.transitionBacklogItem(dropped.id, 'dropped', { source: 'human' })
    await expect(
      manager.createPlan({ ...base, backlogItemIds: [dropped.id] }),
    ).rejects.toThrow(/dropped, not open/i)

    // A real item offered to a mock app.
    const real = repo.fileBacklogItem({
      repoPath,
      title: 'An item filed from a real, unmocked review.',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    const db = repo as unknown as { db: { run: (sql: string, ...p: unknown[]) => unknown } }
    db.db.run(`UPDATE backlog_items SET mock = 0 WHERE id = ?`, real.id)
    await expect(
      manager.createPlan({ ...base, backlogItemIds: [real.id] }),
    ).rejects.toThrow(/real work/i)

    // A selection that never existed.
    await expect(
      manager.createPlan({ ...base, backlogItemIds: [newId()] }),
    ).rejects.toThrow(/no such backlog item/i)

    // Every refusal happened before the plan row was created, and no
    // surviving item moved.
    expect(repo.listPlans().length).toBe(plansBefore)
    expect(repo.getBacklogItem(elsewhere.id)?.state).toBe('open')
    expect(repo.getBacklogItem(real.id)?.state).toBe('open')
  })

  it('planning death regresses planned items to open with the failure on the trail', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-brief-regress-'))
    const session = repo.createSession({
      id: newId(),
      kind: 'debate',
      status: 'complete',
      matter: 'x',
      project: '',
      repoPath: null,
      participants: [claude, codex],
      maxTurns: 2,
      mock: true,
      createdAt: Date.now(),
    })
    const plan = repo.createPlan({
      id: newId(),
      sessionId: session.id,
      kind: 'implementation',
      title: 'A plan whose planner died',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
      status: 'failed',
      question: '',
      correctionNote: '',
      correctionDispositions: [],
      isolation: 'checkout',
      setupCommand: '',
      usage: emptyUsage(),
      mock: true,
      createdAt: Date.now(),
    })
    const item = repo.fileBacklogItem({
      repoPath,
      title: 'An item bound to a plan that never got off the ground.',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    repo.transitionBacklogItem(item.id, 'planned', { source: 'pipeline', planId: plan.id })

    const events: AppEvent[] = []
    const regressed = regressPlannedItems(
      repo,
      plan.id,
      'Planning failed: the planner died mid-draft.',
      (event) => events.push(event),
    )
    expect(regressed).toBe(1)
    const after = repo.getBacklogItem(item.id)
    expect(after?.state).toBe('open')
    expect(after?.planId).toBeNull()
    const trail = repo.listBacklogEvents(item.id)
    expect(trail.at(-1)?.note).toMatch(/planning failed/i)
    expect(events.some((e) => e.type === 'backlog.changed')).toBe(true)

    // Idempotent: a second sweep finds nothing still planned.
    expect(regressPlannedItems(repo, plan.id, 'again', () => {})).toBe(0)
  })

  it('a worktree plan holds its closure proposal until the work actually lands', async () => {
    const { repo, manager, events } = harness()
    const origin = gitRepo('parley-brief-worktree-')
    const session = await reviewedRepo(manager, repo, origin)

    const selected = repo.listBacklogItems({ repoPath: origin })[0]
    if (!selected) throw new Error('expected an open item')
    expect(selected.repoPath).toBe(canonicalRepoPath(origin))

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath: origin,
      planner: claude,
      executor: codex,
      reviewer: claude,
      isolation: 'worktree',
      backlogItemIds: [selected.id],
    })
    await manager.whenPlanSettled(plan.id)

    const first = repo.listMilestones(plan.id)[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      testCommand: 'true',
      expectedPaths: ['parley-mock-work.txt'],
    })
    disposeOpenBlockingOccurrences(repo, session.id)
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    const done = await manager.runMilestone(first.id, approval.id)
    expect(done.status).toBe('complete')
    expect(repo.getPlan(plan.id)?.status).toBe('complete')

    // Complete but unlanded: the checkout has not changed, so completion
    // proposes nothing yet. The item stays bound to its plan.
    expect(repo.getBacklogItem(selected.id)).toMatchObject({
      state: 'planned',
      planId: plan.id,
    })

    // Landing rules key on the plan record; make it real for the landing leg
    // (the item's own mock flag is provenance and deliberately unchanged).
    const db = repo as unknown as { db: { run: (sql: string, ...p: unknown[]) => unknown } }
    db.db.run(`UPDATE plans SET mock = 0 WHERE id = ?`, plan.id)
    const landApproval = manager.grantLandApproval(plan.id, 'land it')
    const changedBefore = events.filter((e) => e.type === 'backlog.changed').length
    const landed = await manager.landPlan(plan.id, landApproval.id)
    expect(landed.landed).toBe(true)

    // Only now — the moment the work reached the checkout — does closure
    // get proposed, with the landing on the trail.
    const after = repo.getBacklogItem(selected.id)
    expect(after?.state).toBe('closure-proposed')
    const closure = repo
      .listBacklogEvents(selected.id)
      .find((event) => event.kind === 'closure-proposed')
    expect(closure?.source).toBe('pipeline')
    expect(closure?.note).toMatch(/landed/i)
    expect(events.filter((e) => e.type === 'backlog.changed').length).toBeGreaterThan(
      changedBefore,
    )
  })
})
