import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { computeHolds } from './holds'
import { Manager } from './manager'
import { Pipeline } from './pipeline'
import { landWorktree } from './worktrees'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }
const none: ReadonlySet<string> = new Set()

function harness(): {
  pipeline: Pipeline
  repo: Repo
  events: AppEvent[]
  session: Session
  worktreesRoot: string
} {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const worktreesRoot = mkdtempSync(join(tmpdir(), 'parley-landroot-'))
  const pipeline = new Pipeline({ repo, registry, emit: (event) => events.push(event), worktreesRoot })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Does landing preserve the guarantees?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  return { pipeline, repo, events, session, worktreesRoot }
}

function gitRepo(prefix: string): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
  }
  git('init', '-q')
  git('config', 'user.email', 'test@example.invalid')
  git('config', 'user.name', 'Parley Test')
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  git('commit', '-qm', 'seed')
  return repoPath
}

function gitOut(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
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
    title: 'Land the widget',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
    ...overrides,
  })
}

function makeMilestone(repo: Repo, planId: string): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Write the mock work file',
    intent: 'Produce something committable.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'audited',
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
    createdAt: Date.now(),
    completedAt: null,
  })
}

/** Runs the single milestone to completion, leaving the plan complete. */
async function completedWorktreePlan(prefix: string): Promise<{
  repo: Repo
  session: Session
  plan: WorkPlan
  origin: string
  baseHead: string
}> {
  const { pipeline, repo, session } = harness()
  const origin = gitRepo(prefix)
  const baseHead = gitOut(origin, 'rev-parse', 'HEAD')
  const plan = makePlan(repo, session.id, origin)
  const milestone = makeMilestone(repo, plan.id)
  const approval = repo.grantApproval('milestone.execute', milestone.id, 'test approval')
  const run = await pipeline.runMilestone(milestone.id, approval.id)
  if (run.status !== 'complete') throw new Error(`fixture milestone ended ${run.status}`)
  if (repo.getPlan(plan.id)?.status !== 'complete') throw new Error('fixture plan not complete')
  return { repo, session, plan, origin, baseHead }
}

describe('fast-forward landing', () => {
  it('lands onto the origin, tears down, and the merge-ready hold clears', async () => {
    const { repo, session, plan, origin, baseHead } = await completedWorktreePlan('parley-land-ok-')
    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')

    // A complete unlanded worktree plan is exactly one decision hold.
    const ready = computeHolds(repo, none).filter((h) => h.planId === plan.id)
    expect(ready).toHaveLength(1)
    expect(ready[0]).toMatchObject({ kind: 'merge-ready', actionable: true, sessionId: session.id })
    expect(ready[0]?.detail).toContain(worktree.branch)

    const tip = gitOut(worktree.path, 'rev-parse', 'HEAD')
    const result = await landWorktree(repo, worktree)
    expect(result.landed).toBe(true)

    // The origin fast-forwarded to the milestone commit; the branch and the
    // worktree directory are gone; the registry remembers the landing.
    expect(gitOut(origin, 'rev-parse', 'HEAD')).toBe(tip)
    expect(gitOut(origin, 'rev-parse', 'HEAD')).not.toBe(baseHead)
    expect(existsSync(join(origin, 'parley-mock-work.txt'))).toBe(true)
    expect(existsSync(worktree.path)).toBe(false)
    expect(
      execFileSync('git', ['branch', '--list', worktree.branch], { cwd: origin, encoding: 'utf8' }).trim(),
    ).toBe('')
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).not.toBeNull()
    expect(computeHolds(repo, none).filter((h) => h.planId === plan.id)).toEqual([])
  })

  it('a diverged origin parks as merge-blocked with the branch name, moving nothing', async () => {
    const { repo, plan, origin } = await completedWorktreePlan('parley-land-diverge-')
    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')

    writeFileSync(join(origin, 'seed.txt'), 'the user moved on\n')
    execFileSync('git', ['commit', '-aqm', 'user work'], { cwd: origin })
    const divergedHead = gitOut(origin, 'rev-parse', 'HEAD')

    const result = await landWorktree(repo, worktree)
    expect(result.landed).toBe(false)
    expect(result.detail.toLowerCase()).toContain('fast-forward')

    // Nothing moved, nothing was torn down, and the queue now says blocked —
    // with the branch named, because the commits are the only copy of the work.
    expect(gitOut(origin, 'rev-parse', 'HEAD')).toBe(divergedHead)
    expect(existsSync(worktree.path)).toBe(true)
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).toBeNull()
    const holds = computeHolds(repo, none).filter((h) => h.planId === plan.id)
    expect(holds).toHaveLength(1)
    expect(holds[0]?.kind).toBe('merge-blocked')
    expect(holds[0]?.actionable).toBe(false)
    expect(holds[0]?.detail).toContain(worktree.branch)
  })

  it('a dirty worktree refuses before merging, naming the adoption way out', async () => {
    const { repo, plan } = await completedWorktreePlan('parley-land-dirtywt-')
    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')

    writeFileSync(join(worktree.path, 'leftover.txt'), 'an interrupted attempt wrote this\n')

    const result = await landWorktree(repo, worktree)
    expect(result.landed).toBe(false)
    expect(result.detail).toMatch(/uncommitted changes/)
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).toBeNull()
  })

  it('mock plans never land, refused at the manager with the reason', async () => {
    const { repo, plan } = await completedWorktreePlan('parley-land-mock-')
    const manager = new Manager({
      repo,
      registry: new AgentRegistry(true),
      emit: () => {},
      worktreesRoot: mkdtempSync(join(tmpdir(), 'parley-landroot-')),
    })

    await expect(manager.landPlan(plan.id)).rejects.toThrow(/mock work never lands/i)
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).toBeNull()
  })

  it('landing an orphaned row still works from the surviving branch', async () => {
    const { repo, plan, origin } = await completedWorktreePlan('parley-land-orphan-')
    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')
    const tip = gitOut(worktree.path, 'rev-parse', 'HEAD')

    // The user deleted the worktree directory; the branch survives, and
    // landing needs only the origin and the branch.
    execFileSync('rm', ['-rf', worktree.path])
    repo.flagWorktree(plan.id, true, 'the worktree directory is missing')

    const blocked = computeHolds(repo, none).filter((h) => h.planId === plan.id)
    expect(blocked[0]?.kind).toBe('merge-blocked')

    const result = await landWorktree(repo, worktree)
    expect(result.landed).toBe(true)
    expect(gitOut(origin, 'rev-parse', 'HEAD')).toBe(tip)
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).not.toBeNull()
    expect(computeHolds(repo, none).filter((h) => h.planId === plan.id)).toEqual([])
  })
})
