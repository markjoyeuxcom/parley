import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
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

function readRequest(): Promise<string> {
  return new Promise((resolve) => {
    let input = ''
    process.stdin.setEncoding('utf8')
    process.stdin.on('data', (chunk: string) => {
      input += chunk
    })
    process.stdin.on('end', () => resolve(input))
    // A caller that opens the connection and never writes should not hold the
    // host forever. ssh's own keepalives cover a dead network; this covers a
    // live one with nothing on it.
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

  const request = parseRequest(await readRequest())
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

void main().catch((error: unknown) => {
  die(error instanceof Error ? error.message : String(error))
})
