import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { delimiter, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  REMOTE_NODE_FLOOR,
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  type RemoteBody,
  type RemoteRequest,
} from '@shared/remote'
import { FrameWriter } from '@main/remote/frames'
import { probeHost, SUPPORTED_VENDORS } from './probe'
import { connectionLost, superviseRun } from './supervisor'
import { cleanupRun, runWorker } from './worker'
import { ensureMirror } from './worktree'

/**
 * How the bundle knows it is the worker rather than the supervisor.
 *
 * One artefact, two roles. A separate worker file would be a second thing to
 * install, version, and get out of step with the first.
 */
const WORKER_FLAG = '--parley-worker'

/**
 * parley-remote — the execution appliance.
 *
 * One file, no runtime npm dependencies, invoked over ssh as a bare constant
 * command with its whole request on stdin. It reports what this host is and,
 * from m3b2, runs a complete milestone in an isolated worktree here.
 *
 * Two rules govern everything it writes:
 *
 * Stdout is protocol only. Every line is a frame; a child process's output is
 * wrapped in one and never echoed raw. Once the handshake has been sent the
 * far end treats any unframed byte as fatal, which is the point — a stray
 * console.log means facts are being lost, and losing facts silently is worse
 * than stopping.
 *
 * Stderr is for failures that happen before, or instead of, the protocol.
 * A bundle that cannot start, a Node too old to run it, a request that is not
 * JSON: none of these have an in-band representation, so they go to stderr
 * where ssh will carry them back and the local side reports them as "the
 * remote did not speak Parley's protocol".
 */

/**
 * The bundle's identity: the SHA-256 of this file, computed by reading it.
 *
 * Deliberately NOT a constant baked in at build time. Embedding the hash
 * inside the file changes the file, so the embedded value can never be the
 * hash of what it sits in — a self-reference that is either wrong or requires
 * a fixed-point dance nobody should have to reason about. Reading our own
 * bytes costs a millisecond and cannot be inconsistent.
 */
function buildId(): string {
  try {
    const self = fileURLToPath(import.meta.url)
    return createHash('sha256').update(readFileSync(self)).digest('hex')
  } catch {
    // Not fatal on its own — but an unidentifiable bundle cannot be pinned or
    // upgraded, and the local side refuses one that will not say what it is.
    return ''
  }
}

function runsRootFor(): string {
  return process.env.PARLEY_RUNS_ROOT ?? join(process.env.HOME ?? homedir(), '.local', 'share', 'parley', 'runs')
}

/**
 * Reads the one request line, and leaves stdin open afterwards.
 *
 * Waiting for EOF would be simpler and wrong: the caller keeps stdin open for
 * the life of the run precisely so that its closing means the connection went
 * away. A reader that consumed until EOF would never return while the link was
 * healthy, and would return instantly once it was not.
 */
function readRequestLine(): Promise<string> {
  return new Promise((resolve) => {
    let input = ''
    process.stdin.setEncoding('utf8')
    const onData = (chunk: string): void => {
      input += chunk
      const at = input.indexOf('\n')
      if (at < 0) return
      process.stdin.off('data', onData)
      resolve(input.slice(0, at))
    }
    process.stdin.on('data', onData)
    // A caller that opens the connection and never writes should not hold the
    // host forever. ssh's keepalives cover a dead network; this covers a live
    // one with nothing on it.
    setTimeout(() => resolve(input), 60_000).unref()
  })
}

function parseRequest(input: string): RemoteRequest | null {
  const line = input.trim()
  if (!line) return null
  try {
    const parsed = JSON.parse(line) as RemoteRequest
    if (typeof parsed !== 'object' || parsed === null) return null
    if (typeof parsed.runId !== 'string' || !parsed.runId) return null
    if (typeof parsed.operation !== 'string') return null
    return parsed
  } catch {
    return null
  }
}

/** Before the protocol exists, this is the only channel there is. */
function die(message: string): never {
  process.stderr.write(`parley-remote: ${message}\n`)
  process.exit(1)
}

async function main(): Promise<void> {
  const major = Number.parseInt(process.versions.node.split('.')[0] ?? '0', 10)
  if (!Number.isFinite(major) || major < REMOTE_NODE_FLOOR) {
    die(`needs Node ${REMOTE_NODE_FLOOR} or newer, found ${process.version} at ${process.execPath}`)
  }

  const request = parseRequest(await readRequestLine())
  if (!request) die('expected one JSON request on stdin')

  if (request.version !== REMOTE_PROTOCOL_VERSION) {
    // Said on stderr rather than as a frame: if the versions disagree we
    // cannot be sure the far end would understand our frames either.
    die(
      `speaks protocol v${REMOTE_PROTOCOL_VERSION}, was sent v${request.version} — upgrade whichever side is older`,
    )
  }

  const writer = new FrameWriter(request.runId)
  const say = (body: RemoteBody): void => {
    process.stdout.write(writer.line(body))
  }

  const runsRoot = runsRootFor()
  const host = await probeHost(runsRoot)

  // Every conversation opens with `ready`. It proves the protocol is alive and
  // tells the caller which build is actually answering — the host may have
  // been upgraded since preflight.
  say({
    type: 'ready',
    capabilities: {
      protocolVersion: REMOTE_PROTOCOL_VERSION,
      buildId: buildId(),
      nodeVersion: host.nodeVersion,
      nodeExecutable: host.nodeExecutable,
      capabilities: [...REQUIRED_CAPABILITIES],
      supportedVendors: [...SUPPORTED_VENDORS],
      availableVendors: host.availableVendors,
      vendorDetails: host.vendorDetails,
      user: host.user,
      home: host.home,
      path: host.path,
      git: host.git,
      runsRoot,
    },
  })

  for (const warning of host.warnings) say({ type: 'progress', phase: 'host', text: warning })

  switch (request.operation) {
    case 'handshake':
      process.exit(0)
      break
    case 'prepare': {
      const spec = request.repository
      if (!spec) {
        say({ type: 'error', message: 'prepare needs a repository', retryable: false })
        process.exit(1)
      }
      const made = await ensureMirror(join(runsRoot, 'mirrors'), spec.remote)
      if (!made.ok || !made.path) {
        say({ type: 'error', message: made.detail, retryable: false })
        process.exit(1)
      }
      say({ type: 'prepared', mirror: made.path })
      process.exit(0)
      break
    }
    case 'run': {
      const spec = request.repository
      const run = request.run
      if (!spec || !run) {
        say({ type: 'error', message: 'a run needs a repository and a run spec', retryable: false })
        process.exit(1)
      }

      const mirror = await ensureMirror(join(runsRoot, 'mirrors'), spec.remote)
      if (!mirror.ok || !mirror.path) {
        say({ type: 'error', message: mirror.detail, retryable: false })
        process.exit(1)
      }

      const workerRequest = {
        runId: request.runId,
        mirrorDir: mirror.path,
        runsRoot,
        expectedCommit: spec.expectedCommit,
        plan: run.plan,
        milestone: run.milestone,
      }

      // The same bundle, in worker mode. A second artefact would be a second
      // thing to install, version and get out of step.
      const end = await superviseRun({
        command: process.execPath,
        args: [fileURLToPath(import.meta.url), WORKER_FLAG],
        request: workerRequest,
        hooks: {
          emit: say,
          // Cleanup runs HERE, after the worker's process group is gone. That
          // is the whole reason the work does not happen in this process.
          cleanup: () => cleanupRun(mirror.path!, runsRoot, request.runId),
        },
        cancelled: connectionLost(process.stdin),
      })

      if (end.kind === 'failed') {
        say({ type: 'error', message: end.detail, retryable: false })
        process.exit(1)
      }
      if (end.kind === 'cancelled') {
        // Said plainly rather than left to inference, and never as a result:
        // the caller may still be listening even though the link that
        // triggered this is the one that went away.
        say({ type: 'error', message: 'the run was cancelled', retryable: true })
        process.exit(1)
      }
      process.exit(0)
      break
    }
    default:
      // Honest about what this build does. A helper that pretended to accept
      // work it cannot do would fail somewhere less legible.
      say({
        type: 'error',
        message: `this build does not implement "${request.operation}" yet`,
        retryable: false,
      })
      process.exit(1)
  }
}

/**
 * The worker half: run the milestone, write bodies, say how it ended.
 *
 * It writes bodies rather than frames because sequence numbers belong to the
 * conversation, and the conversation is the supervisor's.
 */
async function worker(): Promise<void> {
  const request = JSON.parse(await readRequestLine()) as Parameters<typeof runWorker>[0]
  const controller = new AbortController()
  process.on('SIGTERM', () => controller.abort())

  const write = (body: unknown): void => {
    process.stdout.write(`${JSON.stringify(body)}\n`)
  }
  const { result, manifest } = await runWorker(request, write, controller.signal)

  if (result.status === 'completed' && manifest) {
    write({ type: 'result', outcome: 'complete', manifest })
    process.exit(0)
  }
  if (result.status === 'refused') {
    // A real ending, and not a result: the record will show why, and there is
    // no tree for anyone to import.
    write({ type: 'error', message: result.reason, retryable: false })
    process.exit(2)
  }
  if (result.status === 'cancelled') process.exit(3)
  write({
    type: 'error',
    message: result.status === 'failed' ? result.error : 'the run did not finish',
    retryable: false,
  })
  process.exit(1)
}

/**
 * Put the node that is running us within reach of everything we spawn.
 *
 * A non-interactive ssh session does not read the shell startup files where
 * nvm, asdf and mise put node, so on those hosts `node` is not on PATH — and
 * those are the hosts this whole design set out to support rather than refuse.
 * The launcher solves it for the helper itself by naming an absolute
 * interpreter. It does nothing for what the helper spawns, and the run's
 * verification command is very often `node`, `npm` or `npx`.
 *
 * Left unfixed this is not a clean failure. The command cannot start, the
 * result is an exit code, the reviewer reads failing tests and objects, and
 * the executor spends real quota rewriting code that was never wrong. That is
 * what a real host did before this line existed.
 *
 * APPENDED, never prepended: a repository that pins its own toolchain must
 * keep winning. This is a floor for hosts that have nothing, not an override.
 */
function reachableToolchain(): void {
  const bin = dirname(process.execPath)
  const path = process.env['PATH'] ?? ''
  if (path.split(delimiter).includes(bin)) return
  process.env['PATH'] = path ? `${path}${delimiter}${bin}` : bin
}

reachableToolchain()

// One artefact, two roles, chosen by a flag this file owns. Nothing about a
// run reaches the command line: the worker gets its request on stdin exactly
// as the supervisor got its own.
if (process.argv.includes(WORKER_FLAG)) {
  void worker().catch((error: unknown) => {
    die(error instanceof Error ? error.message : String(error))
  })
} else {
  void main().catch((error: unknown) => {
    die(error instanceof Error ? error.message : String(error))
  })
}
