import { spawn, type ChildProcess } from 'node:child_process'
import type { RemoteBody } from '@shared/remote'

/**
 * The process that owns a run's lifetime — and, crucially, outlives it.
 *
 * The pipeline does NOT execute in this process. It executes in a worker that
 * is its own process-group leader, and that separation is the entire point:
 * cancelling a run means signalling the whole group so no agent or test
 * command survives, and if the pipeline ran here then killing that group would
 * kill the very code responsible for tearing down the worktree afterwards.
 * The supervisor would take its own cleanup down with it, every time, and the
 * only evidence would be run directories quietly accumulating on the host.
 *
 * So: supervisor reads stdin and writes frames; worker does the work in a
 * separate group; supervisor kills the group, cleans up, and reports.
 *
 * The worker speaks JSON bodies on its stdout, not frames. Sequence numbers
 * belong to the conversation, and the conversation is the supervisor's — one
 * writer owning the sequence is what keeps it monotonic across the
 * supervisor's own frames and everything the worker produced.
 */

export interface SupervisorHooks {
  /** Emits a body as a numbered frame on the real protocol stream. */
  emit: (body: RemoteBody) => void
  /** Tears down the run's worktree. Runs after the group is dead, never before. */
  cleanup: () => Promise<void>
}

export type SupervisorEnd =
  | { kind: 'finished'; exitCode: number }
  /** stdin closed or a cancel arrived: the group was killed deliberately. */
  | { kind: 'cancelled' }
  /** The worker could not be started, or stopped making sense. */
  | { kind: 'failed'; detail: string }

/** How long a worker gets to wind down before the group is killed outright. */
export const GRACE_MS = 5_000

export interface SuperviseOptions {
  /** argv for the worker: the same bundle, in its internal worker mode. */
  command: string
  args: string[]
  /** The request the worker needs, delivered on its stdin. */
  request: unknown
  hooks: SupervisorHooks
  /** Resolves when the connection is gone — ssh EOF, or an explicit cancel. */
  cancelled: Promise<void>
  graceMs?: number
  /** Injected in tests. */
  spawnFn?: typeof spawn
}

export async function superviseRun(opts: SuperviseOptions): Promise<SupervisorEnd> {
  const graceMs = opts.graceMs ?? GRACE_MS
  const spawnFn = opts.spawnFn ?? spawn

  let child: ChildProcess
  try {
    child = spawnFn(opts.command, opts.args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      // The worker leads its own process group, so every agent and test
      // command it spawns is a descendant we can signal as one.
      detached: true,
    })
  } catch (error) {
    return { kind: 'failed', detail: `could not start the worker: ${String(error)}` }
  }

  let pending = ''
  let stderr = ''
  let cancelling = false

  child.stdout?.setEncoding('utf8')
  child.stdout?.on('data', (chunk: string) => {
    pending += chunk
    let newline = pending.indexOf('\n')
    while (newline >= 0) {
      const line = pending.slice(0, newline).trim()
      pending = pending.slice(newline + 1)
      if (line.startsWith('{')) {
        try {
          opts.hooks.emit(JSON.parse(line) as RemoteBody)
        } catch {
          // The worker is ours; unreadable output from it is a bug, not noise
          // to tolerate. Surfacing it as a framed error keeps the stream
          // honest rather than dropping work silently.
          opts.hooks.emit({
            type: 'error',
            message: `the worker emitted something unreadable: ${line.slice(0, 200)}`,
            retryable: false,
          })
        }
      }
      newline = pending.indexOf('\n')
    }
  })

  child.stderr?.setEncoding('utf8')
  child.stderr?.on('data', (chunk: string) => {
    if (stderr.length < 32 * 1024) stderr += chunk
  })

  const killGroup = (signal: NodeJS.Signals): void => {
    try {
      process.kill(-child.pid!, signal)
    } catch {
      try {
        child.kill(signal)
      } catch {
        // Already gone. Nothing to do, and nothing worth reporting.
      }
    }
  }

  const exited = new Promise<number>((resolve) => {
    child.on('error', () => resolve(-1))
    child.on('exit', (code, signal) => resolve(signal ? -1 : (code ?? -1)))
  })

  void opts.cancelled.then(async () => {
    if (cancelling) return
    cancelling = true
    // SIGTERM first so a worker that wants to tidy up can, then SIGKILL the
    // group so nothing survives the grace period. Both go to the GROUP: the
    // worker's own children are the agents and test commands, and they are
    // what would otherwise keep running and keep spending.
    killGroup('SIGTERM')
    const timer = setTimeout(() => killGroup('SIGKILL'), graceMs)
    await exited
    clearTimeout(timer)
  })

  try {
    child.stdin?.end(`${JSON.stringify(opts.request)}\n`)
  } catch {
    // A worker that died before reading closes the pipe under us; the exit
    // handler owns the diagnosis.
  }

  const code = await exited

  // Cleanup runs HERE, in the supervisor, after the worker's group is gone.
  // This is the reason the split exists at all.
  await opts.hooks.cleanup()

  if (cancelling) return { kind: 'cancelled' }
  if (code === 0) return { kind: 'finished', exitCode: 0 }
  return {
    kind: 'failed',
    detail: stderr.trim().slice(0, 400) || `the worker exited with ${code}`,
  }
}

/**
 * Resolves when the connection goes away.
 *
 * stdin ending is how a remote process learns ssh is gone. Waiting on it, and
 * treating it as a cancel, is what stops a dropped laptop lid from leaving an
 * agent running on a build host until somebody notices the bill.
 */
export function connectionLost(stream: NodeJS.ReadableStream): Promise<void> {
  return new Promise((resolve) => {
    stream.on('end', () => resolve())
    stream.on('close', () => resolve())
    stream.on('error', () => resolve())
  })
}
