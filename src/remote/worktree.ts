import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, rmSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'
import { controlledGitEnv } from '@shared/remote'

/**
 * The isolated checkout a remote run executes in.
 *
 * Three properties matter here, and each one is a way the remote could quietly
 * execute against something other than what was submitted:
 *
 * **The exact object.** A run is given a commit id, not a ref name. The ref is
 * only how the object travelled; it is resolved with `^{commit}` and compared
 * against what the request said before anything is checked out. A ref that
 * moved between push and run — a retry, a second Parley, a stale mirror — must
 * not silently become the thing that executes.
 *
 * **A controlled environment.** Every repository command runs with the host's
 * inherited GIT_ variables stripped and configuration neutralised. An ssh
 * session that arrives with GIT_DIR set would otherwise redirect all of this
 * at another repository, and everything downstream would report confidently
 * about the wrong one.
 *
 * **No repository-supplied code.** `core.hooksPath` is pointed at nothing.
 * The snapshot came from another machine, and a checkout must not be an
 * opportunity for that machine's hooks to run here.
 */

const GIT_TIMEOUT_MS = 5 * 60 * 1000

/** Run identifiers become directory names, so they get the boring grammar too. */
const BORING_RUN_ID = /^[A-Za-z0-9._-]+$/

export interface GitOutcome {
  ok: boolean
  stdout: string
  stderr: string
}

/**
 * Runs git with an environment the runner owns.
 *
 * `-c core.hooksPath=` disables hooks for this invocation without writing to
 * any repository's config, which matters because the mirror is shared between
 * runs — a config write would outlive the run that made it.
 */
export function git(
  args: string[],
  cwd: string,
  owned: Record<string, string> = {},
  signal?: AbortSignal,
): Promise<GitOutcome> {
  return new Promise((resolve_) => {
    const child = spawn('git', ['-c', 'core.hooksPath=', ...args], {
      cwd,
      env: controlledGitEnv(process.env, owned),
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    })
    let stdout = ''
    let stderr = ''
    let settled = false
    const finish = (ok: boolean): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      resolve_({ ok, stdout: stdout.trim(), stderr: stderr.trim() })
    }
    const kill = (): void => {
      try {
        process.kill(-child.pid!, 'SIGKILL')
      } catch {
        child.kill('SIGKILL')
      }
    }
    const onAbort = (): void => {
      kill()
      finish(false)
    }
    signal?.addEventListener('abort', onAbort, { once: true })
    const timer = setTimeout(() => {
      kill()
      finish(false)
    }, GIT_TIMEOUT_MS)
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      stdout += chunk
    })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => {
      stderr += chunk
    })
    child.on('error', () => finish(false))
    child.on('close', (code) => finish(code === 0))
  })
}

/**
 * The directory a run may use, or null if the request has no business naming it.
 *
 * Containment is checked by resolution rather than by inspecting the string:
 * a path that resolves outside the runs root is refused however it got there.
 */
export function runDirectory(runsRoot: string, runId: string): string | null {
  if (!BORING_RUN_ID.test(runId)) return null
  const root = resolve(runsRoot)
  const full = resolve(root, runId)
  if (full !== root && !full.startsWith(root + sep)) return null
  return full
}

export interface PrepareResult {
  ok: boolean
  /** Absolute path of the worktree, when one was created. */
  path: string | null
  detail: string
}

/**
 * Creates the run's worktree from the exact submitted object.
 *
 * The mirror is a bare repository the local side pushed into, so the commit is
 * already present — this neither fetches from the internet nor trusts a ref to
 * still mean what it meant.
 */
export async function prepareRunWorktree(input: {
  mirrorDir: string
  runsRoot: string
  runId: string
  expectedCommit: string
  inputRef: string
  signal?: AbortSignal
}): Promise<PrepareResult> {
  const path = runDirectory(input.runsRoot, input.runId)
  if (!path) return { ok: false, path: null, detail: 'the run id is not a usable directory name' }
  if (!/^[a-f0-9]{40}$/.test(input.expectedCommit)) {
    return { ok: false, path: null, detail: 'the expected commit is not a full object id' }
  }
  if (!existsSync(input.mirrorDir)) {
    return { ok: false, path: null, detail: 'this host has no mirror for that repository' }
  }

  // Resolve the REF, then check it is the object we were told to run. A ref is
  // a name; names move. This is the one comparison that makes the input
  // snapshot immutable in practice rather than only in intention.
  const resolved = await git(
    ['rev-parse', '--verify', `${input.inputRef}^{commit}`],
    input.mirrorDir,
    {},
    input.signal,
  )
  if (!resolved.ok || !resolved.stdout) {
    return { ok: false, path: null, detail: `the input ref ${input.inputRef} is not in the mirror` }
  }
  if (resolved.stdout !== input.expectedCommit) {
    return {
      ok: false,
      path: null,
      detail: `the input ref resolves to ${resolved.stdout.slice(0, 12)}, not the submitted ${input.expectedCommit.slice(0, 12)} — refusing to run against a different tree`,
    }
  }

  mkdirSync(input.runsRoot, { recursive: true })
  if (existsSync(path)) {
    // A leftover from a run that died mid-flight. Removing it is safe: a run
    // directory belongs to exactly one run id, and this one is starting now.
    await removeRunWorktree(input.mirrorDir, path, input.signal)
  }

  // --detach because the run has no branch and must never appear to be on one;
  // the commit is the whole identity of what executes.
  const added = await git(
    ['worktree', 'add', '--detach', path, input.expectedCommit],
    input.mirrorDir,
    {},
    input.signal,
  )
  if (!added.ok) {
    return { ok: false, path: null, detail: added.stderr.slice(0, 400) || 'could not create the worktree' }
  }
  return { ok: true, path, detail: '' }
}

/**
 * Removes a run's worktree, and says nothing when there is nothing to remove.
 *
 * Best effort by design: this runs on the cancellation path, where refusing to
 * finish because a directory was already gone would leave the caller unable to
 * report the cancellation it was in the middle of.
 */
export async function removeRunWorktree(
  mirrorDir: string,
  path: string,
  signal?: AbortSignal,
): Promise<void> {
  await git(['worktree', 'remove', '--force', path], mirrorDir, {}, signal)
  rmSync(path, { recursive: true, force: true })
  // Without this the mirror keeps an administrative entry for a directory that
  // no longer exists, and a later run at the same id is refused as "already
  // registered" — the failure appears one run after the one that caused it.
  await git(['worktree', 'prune'], mirrorDir, {}, signal)
}

/** Ensures a bare mirror exists for a repository, keyed by a caller-supplied id. */
export async function ensureMirror(
  mirrorsRoot: string,
  repoKey: string,
  signal?: AbortSignal,
): Promise<{ ok: boolean; path: string | null; detail: string }> {
  if (!BORING_RUN_ID.test(repoKey)) {
    return { ok: false, path: null, detail: 'the repository key is not a usable directory name' }
  }
  mkdirSync(mirrorsRoot, { recursive: true })
  const path = join(resolve(mirrorsRoot), repoKey)
  if (existsSync(join(path, 'HEAD'))) return { ok: true, path, detail: '' }

  const created = await git(['init', '--bare', '--quiet', path], resolve(mirrorsRoot), {}, signal)
  if (!created.ok) {
    return { ok: false, path: null, detail: created.stderr.slice(0, 400) || 'could not create the mirror' }
  }
  return { ok: true, path, detail: '' }
}
