import { accessSync, constants, lstatSync, readdirSync } from 'node:fs'
import { delimiter, join, relative, resolve } from 'node:path'
import type { Id, SelfUpdate } from '@shared/domain'
import type { Repo } from '@main/store/repo'
import { capture, type CaptureResult } from '@main/util/spawn'

/**
 * The self-update gate: after a plan lands on Parley's own checkout, run the
 * repository's own `npm run verify` and then `npm run build` there, and record
 * the outcome as a self_updates row. Green means the landed bytes both pass
 * their checks and exist as a fresh build in out/ — the two facts a relaunch
 * offer stands on.
 *
 * Fail closed, in deliberate contrast to verifyLanding: that check fails OPEN
 * (an unparseable test command skips it) because it is a courtesy smoke test
 * on someone else's repository. Here the outcome gates an offer to restart
 * the app into the bytes this run produced, so every anomaly — spawn error,
 * timeout, abort, a thrown anything — is a red row, never a shrug.
 */

export interface SelfGateOptions {
  /**
   * Per-step ceiling (verify and build each get one). Injectable so the
   * timeout test exercises the real path rather than a stubbed clock.
   */
  timeoutMs?: number
  /** Aborting flips the row red — a quitting app must not leave `running`. */
  signal?: AbortSignal
  /** Build output to inspect, relative to the self repo unless absolute. */
  outputDir?: string
}

const DEFAULT_STEP_TIMEOUT_MS = 20 * 60 * 1000
const DEFAULT_OUTPUT_DIR = 'out'

type OutputSnapshot = Map<string, string>

function snapshotOutput(outputPath: string): OutputSnapshot {
  const snapshot: OutputSnapshot = new Map()
  const pending = [outputPath]

  while (pending.length > 0) {
    const directory = pending.pop()
    if (!directory) continue

    let entries
    try {
      entries = readdirSync(directory, { withFileTypes: true })
    } catch (error) {
      if (
        directory === outputPath &&
        error instanceof Error &&
        'code' in error &&
        error.code === 'ENOENT'
      ) {
        return snapshot
      }
      throw error
    }

    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isDirectory()) {
        pending.push(path)
        continue
      }
      const stat = lstatSync(path)
      snapshot.set(relative(outputPath, path), `${stat.size}:${stat.mtimeMs}`)
    }
  }

  return snapshot
}

function sameSnapshot(left: OutputSnapshot, right: OutputSnapshot): boolean {
  if (left.size !== right.size) return false
  for (const [path, fingerprint] of left) {
    if (right.get(path) !== fingerprint) return false
  }
  return true
}

/**
 * Where `npm` actually resolves on this process's PATH, for honest red
 * details: nvm/asdf PATH reordering can hand the gate a different node than
 * the one the dev server runs under, and a red that names the binary makes
 * that visible instead of mystifying.
 */
export function resolveOnPath(command: string): string | null {
  for (const dir of (process.env['PATH'] ?? '').split(delimiter)) {
    if (!dir) continue
    const candidate = join(dir, command)
    try {
      accessSync(candidate, constants.X_OK)
      return candidate
    } catch {
      // Not here; keep walking the PATH.
    }
  }
  return null
}

function tail(result: CaptureResult, lines = 30): string {
  const combined = `${result.stdout.trim()}\n${result.stderr.trim()}`.trim()
  if (!combined) return '(no output)'
  return combined.split('\n').slice(-lines).join('\n')
}

function redDetail(step: string, result: CaptureResult): string {
  const npmPath = resolveOnPath('npm') ?? 'npm (not found on PATH)'
  const cause = result.timedOut
    ? `hit its ${Math.round((result.durationMs + 500) / 1000)}s time limit`
    : result.signal
      ? `was killed by ${result.signal}`
      : `exited ${result.exitCode}`
  return (
    `\`${step}\` ${cause} in Parley's own checkout (via ${npmPath}).\n` +
    `If the landed work changed dependencies, run npm install in the checkout and land-verify again.\n\n` +
    tail(result)
  )
}

/**
 * Runs the gate to completion and returns the finalized row.
 *
 * Never throws after the attempt row exists: every failure path inside is
 * caught and finalized red, because a rejected promise here would strand a
 * `running` row that only the NEXT boot's reconcile would notice — a live
 * process must keep its own record honest. Filing itself may still throw,
 * and the caller surfaces that as a notice.
 */
export async function runSelfGate(
  repo: Repo,
  selfRepoPath: string,
  planId: Id,
  opts: SelfGateOptions = {},
): Promise<SelfUpdate> {
  const attempt = repo.fileSelfUpdateAttempt(planId)
  const timeoutMs = opts.timeoutMs ?? DEFAULT_STEP_TIMEOUT_MS
  const outputDir = opts.outputDir ?? DEFAULT_OUTPUT_DIR
  const outputPath = resolve(selfRepoPath, outputDir)
  try {
    // killTree on both: `npm run` interposes npm between us and the actual
    // script, and a timeout that only reaches npm leaves the build's own
    // grandchildren alive and writing out/ behind the guard's back.
    const verify = await capture(
      'npm',
      ['run', 'verify'],
      selfRepoPath,
      timeoutMs,
      opts.signal,
      { killTree: true },
    )
    if (opts.signal?.aborted) {
      return repo.finalizeSelfUpdate(attempt.id, 'red', 'Interrupted: Parley quit while the gate ran.')
    }
    if (verify.exitCode !== 0) {
      return repo.finalizeSelfUpdate(attempt.id, 'red', redDetail('npm run verify', verify))
    }

    const before = snapshotOutput(outputPath)
    const build = await capture(
      'npm',
      ['run', 'build'],
      selfRepoPath,
      timeoutMs,
      opts.signal,
      { killTree: true },
    )
    if (opts.signal?.aborted) {
      return repo.finalizeSelfUpdate(attempt.id, 'red', 'Interrupted: Parley quit while the gate ran.')
    }
    if (build.exitCode !== 0) {
      return repo.finalizeSelfUpdate(attempt.id, 'red', redDetail('npm run build', build))
    }

    const after = snapshotOutput(outputPath)
    if (after.size === 0) {
      return repo.finalizeSelfUpdate(
        attempt.id,
        'red',
        `\`npm run build\` exited 0, but ${outputDir}/ is missing or contains no files.`,
      )
    }
    if (sameSnapshot(before, after)) {
      return repo.finalizeSelfUpdate(
        attempt.id,
        'red',
        `\`npm run build\` exited 0, but did not change any files in ${outputDir}/.`,
      )
    }

    return repo.finalizeSelfUpdate(
      attempt.id,
      'green',
      `Checks passed in ${Math.round(verify.durationMs / 1000)}s and the build completed in ${Math.round(build.durationMs / 1000)}s. ${outputDir}/ changed and contains ${after.size} inspected files.`,
    )
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return repo.finalizeSelfUpdate(attempt.id, 'red', `The gate itself failed: ${message}`)
  }
}
