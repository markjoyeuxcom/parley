import { existsSync, mkdirSync } from 'node:fs'
import { basename, join } from 'node:path'
import type { WorkPlan, Worktree } from '@shared/domain'
import { isShellFree } from '@shared/command'
import { capture, splitCommand } from '@main/util/spawn'
import type { Repo } from '@main/store/repo'

/**
 * Isolated execution checkouts.
 *
 * A worktree plan's milestones run in a per-plan git worktree on a per-plan
 * branch, so the user's live checkout is never touched mid-run — the
 * precondition for Parley working on a repository somebody (including Parley
 * itself) is currently using. Everything here goes through `capture` with an
 * argv array: agent-adjacent strings never reach a shell.
 *
 * Two rules are load-bearing:
 *
 * - **Health fails closed.** `readTree` fails *open* on a directory that is
 *   not a git repository (an unknown tree disables the changed-tree guard and
 *   blinds the reviewer), so a worktree is verified before anything runs in
 *   it, and a sick one stops the milestone before an approval is spent.
 * - **Nothing here deletes work.** Reconciliation marks rows orphaned when
 *   their directory or origin vanishes; it never removes a directory, because
 *   a worktree can hold unlanded commits that exist nowhere else... and a
 *   branch can outlive its directory, which is why re-attachment exists.
 */

export class WorktreeError extends Error {}

const GIT_TIMEOUT_MS = 60 * 1000
const SETUP_TIMEOUT_MS = 15 * 60 * 1000

/** Deterministic names, so a crashed create can be recognised and adopted. */
export function worktreeBranch(plan: WorkPlan): string {
  return `parley/${plan.kind}-${plan.id.slice(0, 8)}`
}

export function worktreePath(worktreesRoot: string, plan: WorkPlan): string {
  // The directory name embeds the origin's basename on purpose: mock-mode
  // behavior keys on cwd substrings, and integration fixtures name their
  // tmpdirs to trip those switches — the worktree must keep tripping them.
  return join(worktreesRoot, `${basename(plan.repoPath)}--${plan.id.slice(0, 8)}`)
}

interface GitResult {
  ok: boolean
  stdout: string
  stderr: string
}

async function git(args: string[], cwd: string): Promise<GitResult> {
  const result = await capture('git', args, cwd, GIT_TIMEOUT_MS)
  return { ok: result.exitCode === 0, stdout: result.stdout.trim(), stderr: result.stderr.trim() }
}

function trimmedFailure(result: GitResult): string {
  return (result.stderr || result.stdout || 'git failed with no output').slice(0, 400)
}

/**
 * Fail-closed health: the directory exists, is a git worktree, and has the
 * recorded branch checked out. Everything downstream (baseline, diff, tests,
 * review) silently degrades on a broken tree, so this is checked before every
 * use — and before any approval is consumed.
 */
export async function verifyWorktree(worktree: Worktree): Promise<{ ok: boolean; detail: string }> {
  if (!existsSync(worktree.originPath)) {
    return { ok: false, detail: `the origin repository is missing (${worktree.originPath})` }
  }
  if (!existsSync(worktree.path)) {
    return { ok: false, detail: `the worktree directory is missing (${worktree.path})` }
  }
  const inside = await git(['rev-parse', '--git-dir'], worktree.path)
  if (!inside.ok) {
    return { ok: false, detail: `${worktree.path} is not a git worktree: ${trimmedFailure(inside)}` }
  }
  const branch = await git(['rev-parse', '--abbrev-ref', 'HEAD'], worktree.path)
  if (!branch.ok || branch.stdout !== worktree.branch) {
    return {
      ok: false,
      detail: `the worktree is on ${branch.stdout || 'an unknown branch'}, expected ${worktree.branch}`,
    }
  }
  return { ok: true, detail: '' }
}

/**
 * Returns the plan's healthy worktree, creating or re-attaching as needed.
 *
 * Creation is idempotent scaffolding: it is safe to run before an approval is
 * consumed (a setup failure must not burn a single-use approval), and a
 * half-created worktree from a crash is recognised by its deterministic names
 * and adopted rather than fought. The optional setup command runs once per
 * created directory — a fresh worktree has no node_modules, so without it the
 * plan's own test commands cannot run.
 */
export async function ensureWorktree(
  repo: Repo,
  worktreesRoot: string,
  plan: WorkPlan,
  onActivity?: (text: string) => void,
): Promise<Worktree> {
  const existing = repo.getWorktreeForPlan(plan.id)
  if (existing) {
    if (existing.landedAt !== null) {
      throw new WorktreeError('this plan’s branch has already landed; nothing further can execute in it')
    }
    const health = await verifyWorktree(existing)
    if (health.ok) {
      if (existing.orphaned || existing.lastError) repo.flagWorktree(plan.id, false, '')
      return { ...existing, orphaned: false, lastError: '' }
    }
    // The one recoverable sickness: the directory vanished while the branch
    // survives. Re-attach to the branch — its commits are the plan's work.
    if (!existsSync(existing.path) && existsSync(existing.originPath)) {
      await git(['worktree', 'prune'], existing.originPath)
      const branchExists = await git(
        ['rev-parse', '--verify', '--quiet', `refs/heads/${existing.branch}`],
        existing.originPath,
      )
      if (branchExists.ok) {
        mkdirSync(worktreesRoot, { recursive: true })
        const attach = await git(
          ['worktree', 'add', existing.path, existing.branch],
          existing.originPath,
        )
        if (!attach.ok) {
          throw new WorktreeError(`could not re-attach the worktree: ${trimmedFailure(attach)}`)
        }
        await runSetup(plan, existing.path, onActivity)
        repo.flagWorktree(plan.id, false, '')
        return { ...existing, orphaned: false, lastError: '' }
      }
    }
    throw new WorktreeError(`the worktree for this plan is unhealthy: ${health.detail}`)
  }

  const origin = plan.repoPath
  const head = await git(['rev-parse', 'HEAD'], origin)
  if (!head.ok) {
    throw new WorktreeError(
      `cannot create a worktree: ${origin} has no commits to branch from (${trimmedFailure(head)})`,
    )
  }
  const baseBranch = await git(['rev-parse', '--abbrev-ref', 'HEAD'], origin)
  const branch = worktreeBranch(plan)
  const path = worktreePath(worktreesRoot, plan)
  mkdirSync(worktreesRoot, { recursive: true })

  if (existsSync(path)) {
    // A directory with no registry row: a crash between `worktree add` and the
    // insert. Adopt it if it is exactly what we would have created.
    const onBranch = await git(['rev-parse', '--abbrev-ref', 'HEAD'], path)
    if (!onBranch.ok || onBranch.stdout !== branch) {
      throw new WorktreeError(
        `a directory already exists at ${path} and is not this plan’s worktree; move it aside`,
      )
    }
  } else {
    const leftoverBranch = await git(
      ['rev-parse', '--verify', '--quiet', `refs/heads/${branch}`],
      origin,
    )
    const add = leftoverBranch.ok
      ? // Never -B: resetting a surviving branch would discard unlanded commits.
        await git(['worktree', 'add', path, branch], origin)
      : await git(['worktree', 'add', '-b', branch, path, head.stdout], origin)
    if (!add.ok) {
      throw new WorktreeError(`could not create the worktree: ${trimmedFailure(add)}`)
    }
  }

  try {
    await runSetup(plan, path, onActivity)
  } catch (err) {
    // Leave nothing half-made: a failed setup removes the worktree and its
    // fresh branch so the retry starts clean. The branch is deleted only on
    // the create path — it cannot hold work yet.
    await git(['worktree', 'remove', '--force', path], origin)
    await git(['branch', '-D', branch], origin)
    throw err
  }

  return repo.createWorktree({
    planId: plan.id,
    originPath: origin,
    path,
    branch,
    baseBranch: baseBranch.ok && baseBranch.stdout !== 'HEAD' ? baseBranch.stdout : '',
    baseCommit: head.stdout,
    createdAt: Date.now(),
    landedAt: null,
    lastError: '',
    orphaned: false,
  })
}

async function runSetup(
  plan: WorkPlan,
  path: string,
  onActivity?: (text: string) => void,
): Promise<void> {
  const command = plan.setupCommand.trim()
  if (!command) return
  if (!isShellFree(command)) {
    throw new WorktreeError('the setup command needs shell syntax, which Parley spawns without')
  }
  const argv = splitCommand(command)
  if (!argv || argv.length === 0) {
    throw new WorktreeError('the setup command could not be parsed')
  }
  onActivity?.(`setup: ${command}`)
  const result = await capture(argv[0] ?? '', argv.slice(1), path, SETUP_TIMEOUT_MS)
  if (result.exitCode !== 0) {
    const output = `${result.stderr}\n${result.stdout}`.trim().slice(0, 600)
    throw new WorktreeError(
      `the setup command failed (exit ${result.exitCode}${result.timedOut ? ', timed out' : ''}): ${output}`,
    )
  }
  onActivity?.('setup finished')
}

/**
 * Commits everything in the worktree as one milestone commit.
 *
 * Parley is the committer, with an explicit identity so a machine with no git
 * user configuration still commits. The agent never commits — this runs after
 * verification and review have passed, so the branch only ever accumulates
 * work that earned its place.
 */
export async function commitMilestone(
  worktree: Worktree,
  message: string,
): Promise<{ committed: boolean; sha: string; detail: string }> {
  const add = await git(['add', '-A'], worktree.path)
  if (!add.ok) return { committed: false, sha: '', detail: trimmedFailure(add) }

  const status = await git(['status', '--porcelain'], worktree.path)
  if (!status.ok) return { committed: false, sha: '', detail: trimmedFailure(status) }
  if (!status.stdout) {
    return { committed: false, sha: '', detail: 'nothing to commit — the worktree is unchanged' }
  }

  const commit = await git(
    ['-c', 'user.name=Parley', '-c', 'user.email=parley@local', 'commit', '-m', message],
    worktree.path,
  )
  if (!commit.ok) return { committed: false, sha: '', detail: trimmedFailure(commit) }

  const sha = await git(['rev-parse', 'HEAD'], worktree.path)
  return { committed: true, sha: sha.ok ? sha.stdout : '', detail: '' }
}

/**
 * Everything about a landing that can be refused without spending anything.
 *
 * landWorktree refuses routinely — a diverged origin, uncommitted dirt, a
 * vanished branch — and each refusal is retryable after the human fixes the
 * world. Consuming an approval before those checks would burn one per git
 * refusal and train people to click through grants, so the preflight runs
 * them first and the spend happens only when git can actually fast-forward.
 * A genuine origin-moved-in-the-gap race still costs one approval; git still
 * refuses safely.
 */
export async function preflightLand(
  worktree: Worktree,
): Promise<{ ok: boolean; detail: string }> {
  if (worktree.landedAt !== null) return { ok: false, detail: 'this branch has already landed' }
  if (!existsSync(worktree.originPath)) {
    return { ok: false, detail: `the origin repository is missing (${worktree.originPath})` }
  }
  const branchExists = await git(
    ['rev-parse', '--verify', '--quiet', `refs/heads/${worktree.branch}`],
    worktree.originPath,
  )
  if (!branchExists.ok) {
    return { ok: false, detail: `the branch ${worktree.branch} no longer exists in the origin` }
  }
  if (existsSync(worktree.path)) {
    const status = await git(['status', '--porcelain'], worktree.path)
    if (status.ok && status.stdout) {
      return {
        ok: false,
        detail:
          'the worktree has uncommitted changes — adopt the milestone that left them, or discard them by hand, before landing',
      }
    }
  }
  const ancestor = await git(
    ['merge-base', '--is-ancestor', 'HEAD', worktree.branch],
    worktree.originPath,
  )
  if (!ancestor.ok) {
    return {
      ok: false,
      detail: `the checkout has moved since the branch was cut — a fast-forward is no longer possible. The work is safe on ${worktree.branch}; merge it by hand.`,
    }
  }
  return { ok: true, detail: '' }
}

/**
 * Re-runs a verification command in the origin after a landing.
 *
 * Honest about what it is: a smoke check. The commands are the milestones'
 * own, possibly path-scoped, and green here proves the fast-forward landed
 * what was reviewed — not that the whole repository is healthy. Bounded well
 * under the pipeline's test timeout because it runs post-return.
 */
export async function verifyLanding(
  originPath: string,
  testCommand: string,
): Promise<{ ok: boolean; detail: string }> {
  const argv = splitCommand(testCommand.trim())
  if (!argv || argv.length === 0 || !isShellFree(testCommand)) {
    return { ok: true, detail: '' }
  }
  const result = await capture(argv[0] ?? '', argv.slice(1), originPath, LAND_VERIFY_TIMEOUT_MS)
  if (result.exitCode === 0) return { ok: true, detail: '' }
  const output = `${result.stderr}\n${result.stdout}`.trim().slice(0, 400)
  return {
    ok: false,
    detail: `post-land verification failed: \`${testCommand.trim()}\` exited ${result.exitCode}${result.timedOut ? ' (timed out)' : ''} in the origin. ${output}`,
  }
}

const LAND_VERIFY_TIMEOUT_MS = 5 * 60 * 1000

/**
 * Lands the plan branch on the origin's checked-out branch, fast-forward only.
 *
 * ff-only is the whole safety argument: git itself proves the checkout has not
 * moved since the branch was cut, refuses to overwrite uncommitted changes,
 * and never invents a merge commit on the user's behalf. Anything git refuses
 * parks as the row's lastError — surfaced as a merge-blocked hold naming the
 * branch, whose commits are preserved for landing by hand.
 *
 * Teardown happens only after a successful merge: the worktree directory is
 * removed and the branch deleted with `-d`, which git only permits because it
 * is fully merged. A dirty worktree refuses before the merge — uncommitted
 * leftovers mean an interrupted attempt someone should adopt or discard first.
 */
export async function landWorktree(
  repo: Repo,
  worktree: Worktree,
): Promise<{ landed: boolean; detail: string }> {
  if (worktree.landedAt !== null) {
    return { landed: false, detail: 'this branch has already landed' }
  }
  if (!existsSync(worktree.originPath)) {
    return { landed: false, detail: `the origin repository is missing (${worktree.originPath})` }
  }
  const branchExists = await git(
    ['rev-parse', '--verify', '--quiet', `refs/heads/${worktree.branch}`],
    worktree.originPath,
  )
  if (!branchExists.ok) {
    return { landed: false, detail: `the branch ${worktree.branch} no longer exists in the origin` }
  }

  if (existsSync(worktree.path)) {
    const status = await git(['status', '--porcelain'], worktree.path)
    if (status.ok && status.stdout) {
      const detail =
        'the worktree has uncommitted changes — adopt the milestone that left them, or discard them by hand, before landing'
      repo.flagWorktree(worktree.planId, worktree.orphaned, detail)
      return { landed: false, detail }
    }
  } else {
    // The directory is gone but the branch survives; clear git's stale
    // administrative entry so the merge and the branch delete can proceed.
    await git(['worktree', 'prune'], worktree.originPath)
  }

  const merge = await git(['merge', '--ff-only', worktree.branch], worktree.originPath)
  if (!merge.ok) {
    const detail = trimmedFailure(merge)
    repo.flagWorktree(worktree.planId, worktree.orphaned, detail)
    return { landed: false, detail }
  }

  if (existsSync(worktree.path)) {
    await git(['worktree', 'remove', worktree.path], worktree.originPath)
  }
  await git(['branch', '-d', worktree.branch], worktree.originPath)
  repo.markWorktreeLanded(worktree.planId)

  const head = await git(['rev-parse', 'HEAD'], worktree.originPath)
  return { landed: true, detail: head.ok ? head.stdout : '' }
}

/**
 * Startup honesty for the registry: flags rows whose directory or origin
 * vanished, and lets git prune its own stale administrative entries. Never
 * deletes a row or a directory — an orphaned row still names a branch that
 * may hold unlanded work, and the flag is what surfaces that instead of
 * letting a broken path fail open later.
 */
export async function reconcileWorktrees(repo: Repo): Promise<{ orphaned: number }> {
  let orphaned = 0
  const origins = new Set<string>()

  for (const worktree of repo.listWorktrees()) {
    if (worktree.landedAt !== null) continue
    if (!existsSync(worktree.originPath)) {
      if (!worktree.orphaned) {
        repo.flagWorktree(worktree.planId, true, 'the origin repository is missing')
        orphaned += 1
      }
      continue
    }
    origins.add(worktree.originPath)
    if (!existsSync(worktree.path) && !worktree.orphaned) {
      repo.flagWorktree(worktree.planId, true, 'the worktree directory is missing')
      orphaned += 1
    }
  }

  for (const origin of origins) {
    await git(['worktree', 'prune'], origin)
  }

  return { orphaned }
}
