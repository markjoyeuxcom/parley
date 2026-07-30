import { mkdtempSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { emptyUsage, type WorkPlan } from '@shared/domain'
import { canonicalRepoPath } from '@main/util/repoPath'
import { openDatabase } from './db'
import { newId, Repo } from './repo'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo): string {
  return repo.createSession({
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
  }).id
}

function makePlan(
  repo: Repo,
  sessionId: string,
  repoPath: string,
  overrides: Partial<WorkPlan> = {},
): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'A plan',
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
    ...overrides,
  })
}

describe('repo-scoped plan listing', () => {
  it('finds every plan for the repository, whatever spelling wrote it', () => {
    const repo = freshRepo()
    const sessionId = makeSession(repo)
    const real = mkdtempSync(join(tmpdir(), 'parley-repos-real-'))
    const link = join(tmpdir(), `parley-repos-link-${Date.now()}`)
    symlinkSync(real, link)

    makePlan(repo, sessionId, real)
    makePlan(repo, sessionId, link)
    makePlan(repo, sessionId, mkdtempSync(join(tmpdir(), 'parley-repos-other-')))

    // Queried by either spelling, both plans surface; the stranger stays out.
    expect(repo.listPlansForRepo(real)).toHaveLength(2)
    expect(repo.listPlansForRepo(link)).toHaveLength(2)
  })

  it('ignores the global cap — history must not fall off a limit', () => {
    const repo = freshRepo()
    const sessionId = makeSession(repo)
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-repos-many-'))
    for (let i = 0; i < 205; i += 1) makePlan(repo, sessionId, repoPath)

    expect(repo.listPlans()).toHaveLength(200)
    expect(repo.listPlansForRepo(repoPath)).toHaveLength(205)
  })
})

describe('repository summaries', () => {
  it('unions plan, backlog and learning repos — a plans-only repo appears', () => {
    const repo = freshRepo()
    const sessionId = makeSession(repo)
    const plansOnly = mkdtempSync(join(tmpdir(), 'parley-sum-plans-'))
    const backlogOnly = mkdtempSync(join(tmpdir(), 'parley-sum-items-'))
    const learningsOnly = mkdtempSync(join(tmpdir(), 'parley-sum-learn-'))

    makePlan(repo, sessionId, plansOnly)
    repo.fileBacklogItem({
      repoPath: backlogOnly,
      title: 'An open item',
      source: 'manual',
      mock: true,
      state: 'open',
    })
    repo.fileLearning({
      repoPath: learningsOnly,
      text: 'A fact.',
      source: 'manual',
      mock: true,
    })

    const paths = repo.listRepoSummaries(true).map((s) => s.repoPath)
    expect(paths).toContain(canonicalRepoPath(plansOnly))
    expect(paths).toContain(canonicalRepoPath(backlogOnly))
    expect(paths).toContain(canonicalRepoPath(learningsOnly))
  })

  it('counts attention plans, mode-scoped items, and the pending proposal', () => {
    const repo = freshRepo()
    const sessionId = makeSession(repo)
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-sum-counts-'))

    makePlan(repo, sessionId, repoPath, { status: 'complete' })
    makePlan(repo, sessionId, repoPath, { status: 'failed' })
    makePlan(repo, sessionId, repoPath, { status: 'awaiting-clarification' })
    // Complete worktree plan with an unlanded worktree row counts as attention.
    const unlanded = makePlan(repo, sessionId, repoPath, {
      status: 'complete',
      isolation: 'worktree',
    })
    repo.createWorktree({
      planId: unlanded.id,
      originPath: repoPath,
      path: join(repoPath, '.wt'),
      branch: 'parley/x',
      baseBranch: 'main',
      baseCommit: 'abc',
      createdAt: Date.now(),
      landedAt: null,
      lastError: '',
      orphaned: false,
    })

    const item = repo.fileBacklogItem({
      repoPath,
      title: 'Open, matching mode',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    repo.fileBacklogItem({
      repoPath,
      title: 'Proposed, matching mode',
      source: 'manual',
      mock: true,
      state: 'proposed',
    })
    // A real item in a mock app: registers the repo, counts nothing.
    repo.fileBacklogItem({
      repoPath,
      title: 'Real item, other mode',
      source: 'manual',
      mock: false,
      state: 'open',
    })

    const attempt = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    repo.finalizeForemanAttempt(attempt.id, {
      state: 'proposed',
      title: 'Next',
      rationale: '',
      itemIds: [item.id],
      deferred: [],
      isolation: 'worktree',
      note: '',
      anchorSessionId: sessionId,
      usage: emptyUsage(),
    })

    const summary = repo
      .listRepoSummaries(true)
      .find((s) => s.repoPath === canonicalRepoPath(repoPath))
    expect(summary).toMatchObject({
      planCount: 4,
      attentionPlans: 3,
      openItems: 1,
      pendingTriage: 1,
      hasPendingProposal: true,
    })

    // The other mode sees the same repo with its own counts.
    const realSummary = repo
      .listRepoSummaries(false)
      .find((s) => s.repoPath === canonicalRepoPath(repoPath))
    expect(realSummary).toMatchObject({ openItems: 1, pendingTriage: 0, hasPendingProposal: false })
  })
})
