import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { capture, type CaptureResult } from '@main/util/spawn'
import { findExecutable } from '@main/util/environment'

/**
 * The one seam through which Parley's own deterministic project commands —
 * milestone test commands, worktree setup, landing verification, loop exit
 * checks — can execute inside a repository's dev container instead of on the
 * host. The repo and git stay local; agents keep writing files on the host;
 * only these observed executions cross into the container, because they are
 * the ones that need the repo's toolchain to be true.
 *
 * Grounded against @devcontainers/cli 0.87.0 (probed live 2026-07-30):
 * `exec --workspace-folder <ws> -- <argv>` passes the inner argv through
 * verbatim (the CLI parses unknown options as args and consumes `--`), the
 * inner exit code flows back unchanged, the command runs in the container's
 * mapped workspace folder, and the default workspace mount is a bind mount —
 * a file edited on the host is immediately visible inside, which mutation
 * testing depends on.
 *
 * Deliberate limits, stated rather than papered over:
 *  - `up` may build an image; it gets its own generous timeout and is only
 *    ever called from approved write flows.
 *  - A timeout or abort kills the HOST-side CLI client. The in-container
 *    process is not in that process group and may keep finishing; result
 *    detail must say so rather than pretend `killTree` reaches inside docker.
 *  - Containers are never torn down here. Lifecycle belongs to the user's
 *    docker tooling.
 *  - Git inside the container does not work for Parley's worktrees (the CLI
 *    mounts the worktree common dir only for worktrees created with
 *    `--relative-paths`, which ours are not). Container-routed commands must
 *    not need git.
 */

/** `up` may pull and build an image on first run; test timeouts do not fit. */
export const DEFAULT_UP_TIMEOUT_MS = 20 * 60 * 1000

export const PROBE_TIMEOUT_MS = 20_000

/** The two config locations the CLI itself documents for --config's default. */
export function hasDevcontainerConfig(workspace: string): boolean {
  return (
    existsSync(join(workspace, '.devcontainer', 'devcontainer.json')) ||
    existsSync(join(workspace, '.devcontainer.json'))
  )
}

/**
 * Argv for running one project command inside the workspace's container.
 * The `--` is load-bearing: it guarantees inner flags can never be read as
 * the CLI's own options, whatever future parser the CLI ships.
 */
export function containerExecArgv(argv: readonly string[], workspace: string): string[] {
  return ['exec', '--workspace-folder', workspace, '--', ...argv]
}

export function containerUpArgv(workspace: string): string[] {
  return ['up', '--workspace-folder', workspace]
}

export function locateDevcontainer(binary = 'devcontainer'): string | null {
  return findExecutable(binary)
}

function missingCli(binary: string): CaptureResult {
  return {
    exitCode: -1,
    signal: null,
    // Nothing ran, so this must never be read as a verdict on the code.
    startError: `${binary} was not found on PATH`,
    stdout: '',
    stderr:
      `The devcontainer CLI (${binary}) was not found on PATH. ` +
      'Install it with `npm install -g @devcontainers/cli`. If it works in ' +
      'Terminal but not here, launch Parley from Terminal once so it can ' +
      'read your shell PATH.',
    durationMs: 0,
    timedOut: false,
  }
}

export interface ProjectCommandOptions {
  /** True routes through `devcontainer exec`; false runs directly on the host. */
  container: boolean
  timeoutMs?: number
  signal?: AbortSignal
  /**
   * Host-side process-group kill, exactly as `capture` defines it. In
   * container mode this bounds the CLI client only — the in-container
   * process survives the cut and may keep running.
   */
  killTree?: boolean
  /** Devcontainer executable name or path; resolution failure fails the run. */
  binary?: string
}

/**
 * Runs one project command, on the host or in the workspace's dev container.
 *
 * This wrapper exists so every project-command call site makes the same
 * choice the same way. It never grows a shell: argv in, argv out.
 */
export async function runProjectCommand(
  argv: readonly string[],
  cwd: string,
  opts: ProjectCommandOptions,
): Promise<CaptureResult> {
  const [command, ...args] = argv
  if (!command) {
    return {
      exitCode: -1,
      signal: null,
      startError: 'there was no command to run',
      stdout: '',
      stderr: 'no command to run',
      durationMs: 0,
      timedOut: false,
    }
  }

  if (!opts.container) {
    return capture(command, args, cwd, opts.timeoutMs, opts.signal, {
      killTree: opts.killTree,
    })
  }

  const binary = opts.binary ?? 'devcontainer'
  const resolved = locateDevcontainer(binary)
  if (!resolved) return missingCli(binary)

  return capture(resolved, containerExecArgv(argv, cwd), cwd, opts.timeoutMs, opts.signal, {
    killTree: opts.killTree,
  })
}

/**
 * Starts (or reuses) the workspace's container. Write flows call this once
 * before their first exec; read-only flows must never reach it. A non-zero
 * exit is the caller's honest failure detail — no retries here.
 */
export async function ensureUp(
  workspace: string,
  opts: { binary?: string; timeoutMs?: number; signal?: AbortSignal } = {},
): Promise<CaptureResult> {
  const binary = opts.binary ?? 'devcontainer'
  const resolved = locateDevcontainer(binary)
  if (!resolved) return missingCli(binary)

  return capture(
    resolved,
    containerUpArgv(workspace),
    workspace,
    opts.timeoutMs ?? DEFAULT_UP_TIMEOUT_MS,
    opts.signal,
  )
}

export interface ToolHealth {
  present: boolean
  version: string
  detail: string
}

/** Presence and version of the devcontainer CLI. Daemon health is not probed
 *  here — `up`'s own failure at run time is the honest witness for docker. */
export async function devcontainerProbe(binary = 'devcontainer'): Promise<ToolHealth> {
  const resolved = locateDevcontainer(binary)
  if (!resolved) {
    return {
      present: false,
      version: '',
      detail:
        'The devcontainer CLI was not found on PATH. Install it with ' +
        '`npm install -g @devcontainers/cli`. If it works in Terminal but ' +
        'not here, launch Parley from Terminal once so it can read your ' +
        'shell PATH.',
    }
  }

  const version = await capture(resolved, ['--version'], process.cwd(), PROBE_TIMEOUT_MS)
  if (version.exitCode !== 0) {
    return {
      present: true,
      version: '',
      detail: version.stderr.trim().slice(0, 300) || `${resolved} could not be run.`,
    }
  }

  return {
    present: true,
    version: version.stdout.trim().split('\n')[0] ?? '',
    detail: resolved,
  }
}
