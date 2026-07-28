import { describe, expect, it } from 'vitest'
import { emptyUsage, type Usage, type WorkPlan } from '@shared/domain'
import { openDatabase } from './db'
import { newId, Repo } from './repo'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

const spent: Usage = {
  inputTokens: 1200,
  cachedInputTokens: 0,
  outputTokens: 340,
  reasoningTokens: 0,
  costUsd: 0,
}

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function openItem(repo: Repo, repoPath: string, title: string, mock = true) {
  return repo.fileBacklogItem({ repoPath, title, source: 'manual', mock, state: 'open' }).item
}

function makeSession(repo: Repo): string {
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'What next?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  return session.id
}

function makePlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return {
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'The proposed batch',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'drafting',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  }
}

function proposedOutcome(itemIds: string[], anchorSessionId: string) {
  return {
    state: 'proposed' as const,
    title: 'Bound the retry path',
    rationale: 'The two P1s gate everything else.',
    itemIds,
    deferred: [],
    isolation: 'worktree' as const,
    note: 'Land the cap before the test that asserts it.',
    anchorSessionId,
    usage: spent,
  }
}

describe('foreman proposal store', () => {
  it('an attempt files running with its snapshot and supersedes nothing', () => {
    const repo = freshRepo()
    const item = openItem(repo, '/tmp/foreman-a', 'First item')
    const anchor = makeSession(repo)
    const first = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-a',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(first.id, proposedOutcome([item.id], anchor))

    // A second attempt, merely running, must not clobber the valid pending.
    const attempt = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-a',
      vendor: 'codex',
      mock: true,
      openSnapshot: [item.id],
    })
    expect(attempt.state).toBe('running')
    expect(attempt.openSnapshot).toEqual([item.id])
    expect(repo.getPendingForemanProposal('/tmp/foreman-a', true)?.id).toBe(first.id)
  })

  it('finalize to proposed supersedes prior same-mock pendings, and only those', () => {
    const repo = freshRepo()
    const item = openItem(repo, '/tmp/foreman-b', 'An item')
    const realItem = openItem(repo, '/tmp/foreman-b', 'A real item', false)
    const anchor = makeSession(repo)

    const mockFirst = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-b',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(mockFirst.id, proposedOutcome([item.id], anchor))
    const realPending = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-b',
      vendor: 'claude',
      mock: false,
      openSnapshot: [realItem.id],
    })
    repo.finalizeForemanAttempt(realPending.id, proposedOutcome([realItem.id], anchor))

    const mockSecond = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-b',
      vendor: 'codex',
      mock: true,
      openSnapshot: [item.id],
    })
    const finalized = repo.finalizeForemanAttempt(mockSecond.id, proposedOutcome([item.id], anchor))
    expect(finalized.state).toBe('proposed')
    expect(finalized.usage).toEqual(spent)

    // The older mock pending was superseded; the real one was not touched.
    expect(repo.getForemanProposal(mockFirst.id)?.state).toBe('superseded')
    expect(repo.getForemanProposal(mockFirst.id)?.decidedAt).not.toBeNull()
    expect(repo.getPendingForemanProposal('/tmp/foreman-b', true)?.id).toBe(mockSecond.id)
    expect(repo.getPendingForemanProposal('/tmp/foreman-b', false)?.id).toBe(realPending.id)
  })

  it('finalize to failed records the spend and leaves the pending intact', () => {
    const repo = freshRepo()
    const item = openItem(repo, '/tmp/foreman-c', 'An item')
    const anchor = makeSession(repo)
    const pending = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-c',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(pending.id, proposedOutcome([item.id], anchor))

    const attempt = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-c',
      vendor: 'codex',
      mock: true,
      openSnapshot: [item.id],
    })
    const failed = repo.finalizeForemanAttempt(attempt.id, {
      state: 'failed',
      error: 'the reply carried no parseable block',
      usage: spent,
    })
    expect(failed.state).toBe('failed')
    expect(failed.usage).toEqual(spent)
    expect(failed.decisionNote).toMatch(/parseable/)
    expect(repo.getPendingForemanProposal('/tmp/foreman-c', true)?.id).toBe(pending.id)

    // Terminal rows cannot be finalized again.
    expect(() =>
      repo.finalizeForemanAttempt(attempt.id, proposedOutcome([item.id], anchor)),
    ).toThrow(/cannot be finalized/)
  })

  it('decide moves proposed to accepted or rejected, and nowhere else', () => {
    const repo = freshRepo()
    const item = openItem(repo, '/tmp/foreman-d', 'An item')
    const anchor = makeSession(repo)
    const attempt = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-d',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(attempt.id, proposedOutcome([item.id], anchor))

    // Accepting requires the plan the acceptance created.
    expect(() => repo.decideForemanProposal(attempt.id, 'accepted')).toThrow(/requires the plan/)

    const rejected = repo.decideForemanProposal(attempt.id, 'rejected', {
      note: 'Wrong batch — the P1 must go first.',
    })
    expect(rejected.state).toBe('rejected')
    expect(rejected.decidedAt).not.toBeNull()
    expect(rejected.decisionNote).toMatch(/wrong batch/i)

    // Decided rows are terminal for decide.
    expect(() => repo.decideForemanProposal(attempt.id, 'accepted', { planId: newId() })).toThrow(
      /cannot become/,
    )
    // Running rows are not decidable.
    const running = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-d',
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })
    expect(() => repo.decideForemanProposal(running.id, 'rejected')).toThrow(/cannot become/)
  })

  it('reconcile flips interrupted running rows to failed and nothing else', () => {
    const repo = freshRepo()
    const item = openItem(repo, '/tmp/foreman-e', 'An item')
    const anchor = makeSession(repo)
    const pending = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-e',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(pending.id, proposedOutcome([item.id], anchor))
    const interrupted = repo.fileForemanAttempt({
      repoPath: '/tmp/foreman-e',
      vendor: 'codex',
      mock: true,
      openSnapshot: [item.id],
    })

    expect(repo.reconcileForemanAttempts()).toBe(1)
    expect(repo.getForemanProposal(interrupted.id)).toMatchObject({
      state: 'failed',
      decisionNote: 'Interrupted when Parley last quit.',
    })
    expect(repo.getPendingForemanProposal('/tmp/foreman-e', true)?.id).toBe(pending.id)
    expect(repo.reconcileForemanAttempts()).toBe(0)
  })

  it('bindPlanCreation lands the plan, the flips, and the acceptance as one act', () => {
    const repo = freshRepo()
    const repoPath = '/tmp/foreman-f'
    const a = openItem(repo, repoPath, 'First selected')
    const b = openItem(repo, repoPath, 'Second selected')
    const anchor = makeSession(repo)
    const attempt = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [a.id, b.id],
    })
    repo.finalizeForemanAttempt(attempt.id, proposedOutcome([a.id, b.id], anchor))

    const plan = makePlan(repo, anchor, repoPath)
    repo.bindPlanCreation(plan, [a.id, b.id], attempt.id)

    expect(repo.getPlan(plan.id)).not.toBeNull()
    expect(repo.getBacklogItem(a.id)).toMatchObject({ state: 'planned', planId: plan.id })
    expect(repo.getBacklogItem(b.id)).toMatchObject({ state: 'planned', planId: plan.id })
    expect(repo.getForemanProposal(attempt.id)).toMatchObject({
      state: 'accepted',
      planId: plan.id,
    })
  })

  it('a mid-transaction failure leaves no partial state behind', () => {
    const repo = freshRepo()
    const repoPath = '/tmp/foreman-g'
    const good = openItem(repo, repoPath, 'Still open')
    const dropped = openItem(repo, repoPath, 'Already dropped')
    repo.transitionBacklogItem(dropped.id, 'dropped', { source: 'human' })
    const anchor = makeSession(repo)
    const attempt = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [good.id, dropped.id],
    })
    repo.finalizeForemanAttempt(attempt.id, proposedOutcome([good.id, dropped.id], anchor))

    // The dropped item's illegal flip throws mid-transaction: the plan row,
    // the first item's flip, and the acceptance must all roll back together.
    const plan = makePlan(repo, anchor, repoPath)
    expect(() => repo.bindPlanCreation(plan, [good.id, dropped.id], attempt.id)).toThrow(
      /cannot become planned/,
    )
    expect(repo.getPlan(plan.id)).toBeNull()
    expect(repo.getBacklogItem(good.id)?.state).toBe('open')
    expect(repo.getForemanProposal(attempt.id)?.state).toBe('proposed')
  })

  it('the manual path gets the same atomicity with no proposal at all', () => {
    const repo = freshRepo()
    const repoPath = '/tmp/foreman-h'
    const item = openItem(repo, repoPath, 'Manually selected')
    const anchor = makeSession(repo)
    const plan = makePlan(repo, anchor, repoPath)
    repo.bindPlanCreation(plan, [item.id], null)
    expect(repo.getPlan(plan.id)).not.toBeNull()
    expect(repo.getBacklogItem(item.id)).toMatchObject({ state: 'planned', planId: plan.id })
  })
})
