import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { emptyUsage, type WorkPlan } from '@shared/domain'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import {
  commitMilestone,
  ensureWorktree,
  reconcileWorktrees,
  verifyLanding,
  verifyWorktree,
  worktreeBranch,
  worktreePath,
  WorktreeError,
} from './worktrees'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function gitRepo(prefix: string, withIdentity = true): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
  }
  git('init', '-q')
  if (withIdentity) {
    git('config', 'user.email', 'test@example.invalid')
    git('config', 'user.name', 'Parley Test')
  }
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  if (withIdentity) git('commit', '-qm', 'seed')
  else {
    execFileSync(
      'git',
      ['-c', 'user.name=Seed', '-c', 'user.email=seed@example.invalid', 'commit', '-qm', 'seed'],
      { cwd: repoPath, stdio: 'ignore' },
    )
  }
  return repoPath
}

function gitOut(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
}

function makePlan(repo: Repo, repoPath: string, overrides: Partial<WorkPlan> = {}): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId: newId(),
    kind: 'implementation',
    title: 'Isolated plan',
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

function worktreesRoot(): string {
  return mkdtempSync(join(tmpdir(), 'parley-wtroot-'))
}

describe('ensureWorktree', () => {
  it('creates a branch from HEAD, records the registry row, and is idempotent', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-origin-')
    const plan = makePlan(repo, origin)
    const root = worktreesRoot()

    const created = await ensureWorktree(repo, root, plan)
    expect(created.branch).toBe(worktreeBranch(plan))
    expect(created.baseCommit).toBe(gitOut(origin, 'rev-parse', 'HEAD'))
    expect(created.baseBranch).toBe(gitOut(origin, 'rev-parse', '--abbrev-ref', 'HEAD'))
    expect(existsSync(join(created.path, 'seed.txt'))).toBe(true)
    expect(gitOut(created.path, 'rev-parse', '--abbrev-ref', 'HEAD')).toBe(created.branch)
    // The directory name embeds the origin basename — mock-mode cwd switches
    // and integration fixtures depend on it.
    expect(created.path).toContain('parley-wt-origin-')

    const again = await ensureWorktree(repo, root, plan)
    expect(again.path).toBe(created.path)
    expect(repo.listWorktrees()).toHaveLength(1)
  })

  it('runs the setup command once, in the worktree', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-setup-')
    const plan = makePlan(repo, origin, { setupCommand: 'mkdir setup-ran' })
    const root = worktreesRoot()

    const created = await ensureWorktree(repo, root, plan)
    expect(existsSync(join(created.path, 'setup-ran'))).toBe(true)
    expect(existsSync(join(origin, 'setup-ran'))).toBe(false)

    // A second ensure must not re-run it: mkdir would fail on the existing
    // directory, so a passing re-ensure is the proof.
    await expect(ensureWorktree(repo, root, plan)).resolves.toBeTruthy()
  })

  it('a failing setup command fails the ensure and leaves nothing half-made', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-setupfail-')
    const plan = makePlan(repo, origin, { setupCommand: 'false' })
    const root = worktreesRoot()

    await expect(ensureWorktree(repo, root, plan)).rejects.toThrow(WorktreeError)
    expect(repo.getWorktreeForPlan(plan.id)).toBeNull()
    // The branch is gone too, so a corrected retry starts clean.
    expect(() => gitOut(origin, 'rev-parse', '--verify', `refs/heads/${worktreeBranch(plan)}`)).toThrow()
  })

  it('does not adopt an unrelated repository at the deterministic path and branch', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-adopt-origin-')
    const plan = makePlan(repo, origin)
    const root = worktreesRoot()
    const unrelated = gitRepo('parley-wt-adopt-unrelated-')
    execFileSync('git', ['checkout', '-q', '-b', worktreeBranch(plan)], {
      cwd: unrelated,
      stdio: 'ignore',
    })
    renameSync(unrelated, worktreePath(root, plan))

    await expect(ensureWorktree(repo, root, plan)).rejects.toThrow(/not this plan’s worktree/)
    expect(repo.getWorktreeForPlan(plan.id)).toBeNull()
  })

  it('re-attaches to a surviving branch when the directory vanished, keeping its commits', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-reattach-')
    const plan = makePlan(repo, origin)
    const root = worktreesRoot()

    const created = await ensureWorktree(repo, root, plan)
    writeFileSync(join(created.path, 'work.txt'), 'the milestone wrote this\n')
    const commit = await commitMilestone(created, 'milestone 1')
    expect(commit.committed).toBe(true)

    rmSync(created.path, { recursive: true, force: true })
    expect((await verifyWorktree(created)).ok).toBe(false)

    const reattached = await ensureWorktree(repo, root, plan)
    expect(reattached.path).toBe(created.path)
    expect(existsSync(join(reattached.path, 'work.txt'))).toBe(true)
    expect((await verifyWorktree(reattached)).ok).toBe(true)
  })

  it('refuses to execute for a plan whose branch already landed', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-landed-')
    const plan = makePlan(repo, origin)
    const root = worktreesRoot()

    await ensureWorktree(repo, root, plan)
    repo.markWorktreeLanded(plan.id)

    await expect(ensureWorktree(repo, root, plan)).rejects.toThrow(/already landed/)
  })
})

describe('verifyWorktree', () => {
  it('accepts a healthy worktree belonging to its recorded origin', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-healthy-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    await expect(verifyWorktree(created)).resolves.toEqual({ ok: true, detail: '' })
  })

  it('fails closed when an unrelated repository replaces the worktree on the expected branch', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-identity-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)
    const unrelated = gitRepo('parley-wt-unrelated-')
    execFileSync('git', ['checkout', '-q', '-b', created.branch], {
      cwd: unrelated,
      stdio: 'ignore',
    })
    rmSync(created.path, { recursive: true, force: true })
    renameSync(unrelated, created.path)

    const sick = await verifyWorktree(created)
    expect(sick.ok).toBe(false)
    expect(sick.detail).toMatch(/different repository/)
  })

  it('accepts a symlinked spelling of the recorded origin', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-symlink-origin-')
    const linkRoot = mkdtempSync(join(tmpdir(), 'parley-wt-origin-link-'))
    const originLink = join(linkRoot, 'origin')
    symlinkSync(origin, originLink)
    const plan = makePlan(repo, originLink)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    await expect(verifyWorktree(created)).resolves.toEqual({ ok: true, detail: '' })
  })

  it('fails closed when the recorded origin is no longer a repository', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-origin-valid-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)
    const formerOrigin = gitRepo('parley-wt-origin-former-')
    rmSync(join(formerOrigin, '.git'), { recursive: true, force: true })

    const sick = await verifyWorktree({ ...created, originPath: formerOrigin })
    expect(sick.ok).toBe(false)
    expect(sick.detail).toMatch(/could not establish/)
  })

  it('fails closed when the directory is deleted', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-health-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    expect((await verifyWorktree(created)).ok).toBe(true)
    rmSync(created.path, { recursive: true, force: true })
    const sick = await verifyWorktree(created)
    expect(sick.ok).toBe(false)
    expect(sick.detail).toMatch(/directory is missing/)
  })

  it('fails closed when the wrong branch is checked out', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-branch-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    execFileSync('git', ['checkout', '-q', '-b', 'somewhere-else'], { cwd: created.path, stdio: 'ignore' })
    const sick = await verifyWorktree(created)
    expect(sick.ok).toBe(false)
    expect(sick.detail).toMatch(/somewhere-else/)
  })
})

describe('verifyLanding', () => {
  it('runs a red command in the origin and reports its command, exit code, and output', async () => {
    const origin = gitRepo('parley-land-verify-red-')
    writeFileSync(
      join(origin, 'verify-red.cjs'),
      [
        "require('node:fs').writeFileSync('verify-ran.txt', 'ran in origin\\n')",
        "console.log('verification stdout')",
        "console.error('verification stderr')",
        'process.exit(3)',
        '',
      ].join('\n'),
    )

    const result = await verifyLanding(origin, 'node verify-red.cjs')

    expect(result.ok).toBe(false)
    expect(result.detail).toContain('`node verify-red.cjs`')
    expect(result.detail).toContain('exited 3')
    expect(result.detail).toContain('verification stdout')
    expect(result.detail).toContain('verification stderr')
    expect(existsSync(join(origin, 'verify-ran.txt'))).toBe(true)
  })

  it('returns green when the command passes', async () => {
    const origin = gitRepo('parley-land-verify-green-')
    writeFileSync(
      join(origin, 'verify-green.cjs'),
      "require('node:fs').writeFileSync('verify-green.txt', 'passed\\n')\n",
    )

    const result = await verifyLanding(origin, 'node verify-green.cjs')

    expect(result).toEqual({ ok: true, detail: '' })
    expect(existsSync(join(origin, 'verify-green.txt'))).toBe(true)
  })

  it('fails open without spawning commands that need shell syntax or cannot be parsed', async () => {
    const origin = gitRepo('parley-land-verify-refused-')
    writeFileSync(
      join(origin, 'shell-syntax.cjs'),
      "require('node:fs').writeFileSync('shell-syntax-ran.txt', 'spawned\\n')\n",
    )
    writeFileSync(
      join(origin, 'unparsable.cjs'),
      "require('node:fs').writeFileSync('unparsable-ran.txt', 'spawned\\n')\n",
    )

    await expect(verifyLanding(origin, 'node shell-syntax.cjs && true')).resolves.toEqual({
      ok: true,
      detail: '',
    })
    await expect(verifyLanding(origin, 'node "unparsable.cjs')).resolves.toEqual({
      ok: true,
      detail: '',
    })
    expect(existsSync(join(origin, 'shell-syntax-ran.txt'))).toBe(false)
    expect(existsSync(join(origin, 'unparsable-ran.txt'))).toBe(false)
  })
})

describe('commitMilestone', () => {
  it('commits with an explicit identity even when the repository has none configured', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-noident-', false)
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    writeFileSync(join(created.path, 'work.txt'), 'authored by the pipeline\n')
    const result = await commitMilestone(created, 'implementation m1: write the file')
    expect(result.committed).toBe(true)
    expect(result.sha).toMatch(/^[0-9a-f]{40}$/)
    expect(gitOut(created.path, 'log', '-1', '--format=%an')).toBe('Parley')
    expect(gitOut(created.path, 'log', '-1', '--format=%s')).toBe('implementation m1: write the file')
  })

  it('reports an unchanged tree rather than inventing an empty commit', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-clean-')
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, worktreesRoot(), plan)

    const result = await commitMilestone(created, 'nothing happened')
    expect(result.committed).toBe(false)
    expect(result.detail).toMatch(/nothing to commit/)
  })
})

describe('reconcileWorktrees', () => {
  it('flags vanished directories and origins, idempotently, deleting nothing', async () => {
    const repo = freshRepo()
    const originA = gitRepo('parley-wt-recon-a-')
    const originB = gitRepo('parley-wt-recon-b-')
    const root = worktreesRoot()
    const planA = makePlan(repo, originA)
    const planB = makePlan(repo, originB)
    const wtA = await ensureWorktree(repo, root, planA)
    const wtB = await ensureWorktree(repo, root, planB)

    rmSync(wtA.path, { recursive: true, force: true })
    rmSync(originB, { recursive: true, force: true })

    const first = await reconcileWorktrees(repo)
    expect(first.orphaned).toBe(2)
    const rows = repo.listWorktrees()
    expect(rows).toHaveLength(2)
    expect(rows.every((w) => w.orphaned)).toBe(true)
    expect(repo.getWorktreeForPlan(planA.id)?.lastError).toMatch(/directory is missing/)
    expect(repo.getWorktreeForPlan(planB.id)?.lastError).toMatch(/origin repository is missing/)

    // Idempotent: a second pass finds nothing new and still deletes nothing.
    const second = await reconcileWorktrees(repo)
    expect(second.orphaned).toBe(0)
    expect(repo.listWorktrees()).toHaveLength(2)
    // The healthy worktree of plan B — the branch and dir under our root —
    // was not touched even though its origin vanished.
    expect(existsSync(wtB.path)).toBe(true)
  })

  it('a healthy registry reconciles to zero and an ensure clears a stale flag', async () => {
    const repo = freshRepo()
    const origin = gitRepo('parley-wt-recover-')
    const root = worktreesRoot()
    const plan = makePlan(repo, origin)
    const created = await ensureWorktree(repo, root, plan)

    expect((await reconcileWorktrees(repo)).orphaned).toBe(0)

    // A stale flag (say, from a transiently unmounted volume) self-heals the
    // next time the worktree is actually used and passes health.
    repo.flagWorktree(plan.id, true, 'the worktree directory is missing')
    const healed = await ensureWorktree(repo, root, plan)
    expect(healed.orphaned).toBe(false)
    expect(repo.getWorktreeForPlan(plan.id)?.orphaned).toBe(false)
    expect(created.path).toBe(healed.path)
  })
})
