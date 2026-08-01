import { spawn } from 'node:child_process'
import type { RemoteFrame, RemoteRequest, RemoteTarget } from '@shared/remote'
import { decodeFrame, FrameSequencer } from './frames'
import { encodeRequest, sshArgv } from './protocol'

/**
 * One conversation with a remote helper.
 *
 * The transport and nothing else: it opens ssh, writes one request, reads
 * framed events until the far end closes, and reports how it ended. It knows
 * nothing about milestones, refs or pipelines — those are the layers above,
 * and keeping them out of here is what makes this testable against a fake
 * `ssh` that is really a small node script.
 *
 * Three failure modes are deliberately distinguished, because they call for
 * opposite responses and every one of them arrives as "the process ended":
 *
 *  - **refused**: ssh itself failed — unknown host key, no key, no such host.
 *    Nothing ran. Safe to retry after the user fixes it, nothing to reconcile.
 *  - **protocol**: ssh connected but what came back was not the protocol. Most
 *    often the helper is not installed, and the remote shell said so on stderr.
 *    Nothing ran, but the diagnosis lives in stderr, which is exactly why the
 *    helper never writes anything but framed events to stdout.
 *  - **disconnected**: the conversation started and then the wire died. This
 *    is the dangerous one: the remote may have finished the work. It must
 *    never be reported as failure, because the recovery is to go and look at
 *    the result ref, not to run it again.
 *  - **violation**: the far end spoke the protocol and then stopped making
 *    sense — an unframed line, an unreadable frame, or a gap in the sequence.
 *    Same recovery as disconnected (go and look), different cause.
 *
 * Strictness is deliberately asymmetric about the handshake. Before it, an
 * unreadable line is ordinary: ssh sessions emit banners, and shell startup
 * files print things. After it, the same line is fatal. Once the protocol has
 * proven it is alive, a stray console.log or a leaked child write means facts
 * are going missing, and a run that continues while silently dropping facts
 * produces a record with a hole in it. Better to stop and say so.
 *
 * The first frame of every conversation must be `ready`. It is what proves the
 * protocol is alive, and it re-confirms which build is actually answering —
 * the host could have been upgraded between preflight and this run.
 */

export type SshEnd =
  | { kind: 'closed'; exitCode: number }
  | { kind: 'refused'; detail: string }
  | { kind: 'protocol'; detail: string }
  | { kind: 'violation'; detail: string }
  | { kind: 'disconnected'; detail: string }
  | { kind: 'cancelled' }

export interface SshRunResult {
  end: SshEnd
  /** ssh's own stderr, tail-limited. The only channel for un-framed failure. */
  stderr: string
  /**
   * Lines on stdout that were not frames, kept for diagnosis. Only ever
   * collected BEFORE the handshake — after it, one of these ends the run.
   */
  unreadable: string[]
}

export interface SshRunOptions {
  target: Pick<RemoteTarget, 'host'>
  request: RemoteRequest
  onFrame: (frame: RemoteFrame) => void
  signal?: AbortSignal
  timeoutMs?: number
  /** Injected in tests; the real one is resolved from PATH. */
  sshBinary?: string
}

const MAX_STDERR = 64 * 1024
const MAX_UNREADABLE = 20

/**
 * ssh's own exit codes overlap with the remote command's, with one exception:
 * 255 is reserved for ssh-level failure. That single reserved value is the
 * whole reason "the host refused us" can be told apart from "the pipeline
 * exited non-zero" without guessing.
 */
const SSH_FAILURE = 255

export function runSsh(opts: SshRunOptions): Promise<SshRunResult> {
  const binary = opts.sshBinary ?? 'ssh'
  const timeoutMs = opts.timeoutMs ?? 6 * 60 * 60 * 1000

  return new Promise((resolve) => {
    // Detached so the whole ssh process group can be signalled: a cancel that
    // leaves ssh alive leaves the remote pipeline running and spending.
    const child = spawn(binary, sshArgv(opts.target), {
      env: process.env,
      detached: true,
    })

    let stderr = ''
    let pending = ''
    /** Set by the `ready` frame. Before it we tolerate noise; after it we do not. */
    let alive = false
    let settled = false
    const unreadable: string[] = []
    const sequencer = new FrameSequencer()

    const finish = (end: SshEnd): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      opts.signal?.removeEventListener('abort', onAbort)
      resolve({ end, stderr, unreadable })
    }

    const kill = (): void => {
      try {
        // Negative pid signals the group; ssh may have spawned helpers.
        process.kill(-child.pid!, 'SIGTERM')
      } catch {
        child.kill('SIGTERM')
      }
    }

    const violate = (detail: string): void => {
      kill()
      finish({ kind: 'violation', detail })
    }

    const onAbort = (): void => {
      // Close stdin first: the remote sees EOF, stops its own work and tears
      // down its worktree. Killing ssh alone would leave it running there with
      // nobody reading its output.
      try {
        child.stdin.end()
      } catch {
        // Already gone; the kill below is the fallback.
      }
      kill()
      finish({ kind: 'cancelled' })
    }
    opts.signal?.addEventListener('abort', onAbort, { once: true })

    const timer = setTimeout(() => {
      kill()
      finish({ kind: 'disconnected', detail: 'the remote run exceeded its time limit' })
    }, timeoutMs)

    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      pending += chunk
      let newline = pending.indexOf('\n')
      while (newline >= 0) {
        const line = pending.slice(0, newline)
        pending = pending.slice(newline + 1)
        const frame = decodeFrame(line)
        if (!frame) {
          if (line.trim().length === 0) {
            newline = pending.indexOf('\n')
            continue
          }
          if (alive) {
            violate(`unreadable output after the handshake: ${line.slice(0, 200)}`)
            return
          }
          if (unreadable.length < MAX_UNREADABLE) unreadable.push(line.slice(0, 500))
          newline = pending.indexOf('\n')
          continue
        }

        if (!alive) {
          if (frame.body.type !== 'ready') {
            violate('the remote sent a frame before announcing itself')
            return
          }
          alive = true
        }

        const admission = sequencer.admit(frame)
        if (admission.kind === 'gap') {
          // ssh delivers an ordered byte stream, so a missing sequence cannot
          // still be in flight. Holding this frame and hoping the gap fills
          // would leave the record with a hole and the resume point a fiction.
          violate(
            `the remote skipped frame ${admission.expected} — expected ${admission.expected}, got ${frame.sequence}`,
          )
          return
        }
        // A duplicate is exactly what a resume resends; applying it twice is
        // the corruption, ignoring it is the whole point of the sequence.
        if (admission.kind === 'accept') opts.onFrame(frame)
        newline = pending.indexOf('\n')
      }
    })

    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => {
      if (stderr.length < MAX_STDERR) stderr += chunk
    })

    child.on('error', (error: Error) => {
      finish({ kind: 'refused', detail: `could not start ssh: ${error.message}` })
    })

    // 'close' rather than 'exit': stdout must be fully drained before the end
    // is interpreted, or a result event sitting in the pipe when the process
    // exits would be read as a run that produced no result.
    child.on('close', (code: number | null, signal: string | null) => {
      if (settled) return
      if (signal !== null) {
        finish({ kind: 'disconnected', detail: `ssh was killed by ${signal}` })
        return
      }
      if (code === SSH_FAILURE) {
        finish({ kind: 'refused', detail: sshRefusal(stderr) })
        return
      }
      if (!alive) {
        finish({ kind: 'protocol', detail: helperMissing(stderr, unreadable) })
        return
      }
      finish({ kind: 'closed', exitCode: code ?? 0 })
    })

    child.stdin.on('error', () => {
      // A helper that exits before reading stdin closes the pipe under us.
      // The close handler owns the diagnosis; this only stops the EPIPE throw.
    })
    // Written, but NOT closed. Stdin staying open is how the far end knows the
    // connection is still there — closing it after the request would make EOF
    // arrive instantly and be indistinguishable from a dropped link, so the
    // remote would cancel itself the moment it started. Keeping it open turns
    // the same signal into something useful: closing stdin IS the cancel.
    child.stdin.write(encodeRequest(opts.request))
  })
}

/** ssh's failures are legible; pass its own words through rather than ours. */
function sshRefusal(stderr: string): string {
  const line = stderr
    .split('\n')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0 && !entry.startsWith('Warning: Permanently added'))
    .pop()
  return line ? `ssh refused the connection: ${line}` : 'ssh could not connect to the host'
}

function helperMissing(stderr: string, unreadable: string[]): string {
  const detail = stderr.trim() || unreadable.join(' ').trim()
  return detail
    ? `the remote did not speak Parley's protocol: ${detail.slice(0, 400)}`
    : 'the remote produced no protocol output — is parley-remote installed on that host?'
}
