import {
  REMOTE_HELPER_COMMAND,
  REMOTE_PROTOCOL_VERSION,
  type RemoteCapabilities,
  type RemoteEvent,
  type RemoteEvidenceManifest,
  type RemoteRequest,
  type RemoteTarget,
} from '@shared/remote'

/**
 * The wire, as pure functions.
 *
 * Everything here is total and synchronous so the rules can be proven without
 * a network, a host, or a helper: how the ssh command line is built, what a
 * request looks like, and — the part that earns its tests — what happens when
 * the far end sends something unexpected. A protocol reader that throws on
 * malformed input turns a noisy remote into a crashed run; a reader that
 * silently accepts anything turns it into a wrong one. This one does neither.
 */

/**
 * Argv for reaching a target's helper.
 *
 * Read the shape carefully, because it is the security property: every element
 * is a constant or a value from the user's own target record, and the remote
 * command is the bare constant `parley-remote`. Nothing about the run appears
 * here. ssh will hand `parley-remote run` to the remote login shell — that is
 * unavoidable and harmless, because there is nothing in it to interpret.
 *
 * The options are not decoration:
 *  - `BatchMode=yes` makes a missing key an immediate error instead of an
 *    interactive password prompt against a process with no terminal, which
 *    would otherwise look exactly like a hang.
 *  - `StrictHostKeyChecking=yes` refuses an unknown or changed host key rather
 *    than trusting it on first sight. Parley executes code on the other end of
 *    this connection; accepting whatever answers is not a default we get to
 *    have. The user adds the host to known_hosts themselves, deliberately.
 *  - `ExitOnForwardFailure` and the keepalives make a dead connection fail in
 *    seconds rather than hanging until a run's own timeout.
 */
export function sshArgv(target: Pick<RemoteTarget, 'host'>): string[] {
  return [
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=4',
    target.host,
    REMOTE_HELPER_COMMAND,
  ]
}

/** The request body written to the helper's stdin, newline-terminated. */
export function encodeRequest(request: RemoteRequest): string {
  return `${JSON.stringify(request)}\n`
}

export function handshakeRequest(runId: string): RemoteRequest {
  return { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId }
}

/* ------------------------------------------------------------------ */
/* Reading the far end                                                 */
/* ------------------------------------------------------------------ */

/**
 * One line of the helper's stdout.
 *
 * Returns null for anything that is not a well-formed event rather than
 * throwing or guessing. A helper that prints a stray banner, a shell profile
 * that echoes a message on login, a truncated final line — none of these are
 * protocol events, and none of them should be able to end a run. The caller
 * counts them; enough unreadable output with no readable output is its own
 * diagnosis, and a better one than a parse exception.
 */
export function decodeEvent(line: string): RemoteEvent | null {
  const trimmed = line.trim()
  if (!trimmed.startsWith('{')) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null

  const event = parsed as Record<string, unknown>
  const type = event.type
  if (typeof type !== 'string') return null

  switch (type) {
    case 'ready': {
      const capabilities = decodeCapabilities(event.capabilities)
      return capabilities ? { type: 'ready', capabilities } : null
    }
    case 'stdout':
    case 'stderr': {
      const processId = str(event.processId)
      const data = str(event.data)
      if (processId === null || data === null) return null
      return { type, processId, data }
    }
    case 'exit': {
      const processId = str(event.processId)
      const code = num(event.code)
      if (processId === null || code === null) return null
      return { type: 'exit', processId, code, signal: str(event.signal) }
    }
    case 'progress': {
      const phase = str(event.phase)
      const text = str(event.text)
      if (phase === null || text === null) return null
      return { type: 'progress', phase, text }
    }
    case 'report': {
      if (!('report' in event)) return null
      return { type: 'report', report: event.report }
    }
    case 'result': {
      const outcome = event.outcome
      if (outcome !== 'complete' && outcome !== 'failed') return null
      const manifest = decodeManifest(event.manifest)
      if (!manifest) return null
      return { type: 'result', outcome, manifest }
    }
    case 'error': {
      const message = str(event.message)
      if (message === null) return null
      return { type: 'error', message, retryable: event.retryable === true }
    }
    default:
      return null
  }
}

function decodeCapabilities(value: unknown): RemoteCapabilities | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const version = num(raw.version)
  const helperVersion = str(raw.helperVersion)
  const runsRoot = str(raw.runsRoot)
  const git = str(raw.git)
  if (version === null || helperVersion === null || runsRoot === null || git === null) return null

  const vendors: RemoteCapabilities['vendors'] = []
  if (Array.isArray(raw.vendors)) {
    for (const entry of raw.vendors) {
      if (typeof entry !== 'object' || entry === null) continue
      const vendor = str((entry as Record<string, unknown>).vendor)
      const vendorVersion = str((entry as Record<string, unknown>).version)
      if (vendor === null || vendorVersion === null) continue
      vendors.push({ vendor, version: vendorVersion })
    }
  }
  return { version, helperVersion, vendors, runsRoot, git }
}

function decodeManifest(value: unknown): RemoteEvidenceManifest | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const baseCommit = str(raw.baseCommit)
  if (baseCommit === null) return null
  const changedPaths = Array.isArray(raw.changedPaths)
    ? raw.changedPaths.filter((entry): entry is string => typeof entry === 'string')
    : []
  return {
    resultCommit: str(raw.resultCommit),
    baseCommit,
    changedPaths,
    artifactsPath: str(raw.artifactsPath),
  }
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

/* ------------------------------------------------------------------ */
/* The handshake's verdict                                             */
/* ------------------------------------------------------------------ */

/**
 * Why a target cannot run this plan, or null if it can.
 *
 * Checked BEFORE a snapshot is pushed and before an approval is spent, because
 * every one of these failures is knowable in advance and none of them is worth
 * discovering from a half-finished run. The vendor check is the one that pays
 * for itself: a target without the plan's executor CLI signed in produces a
 * confident-looking failure thirty seconds in.
 */
export function targetRefusal(
  capabilities: RemoteCapabilities,
  needs: readonly string[],
): string | null {
  if (capabilities.version !== REMOTE_PROTOCOL_VERSION) {
    return `the remote helper speaks protocol v${capabilities.version}, this Parley speaks v${REMOTE_PROTOCOL_VERSION} — update whichever is older`
  }
  const have = new Set(capabilities.vendors.map((entry) => entry.vendor))
  const missing = [...new Set(needs)].filter((vendor) => !have.has(vendor))
  if (missing.length > 0) {
    return `the remote host has no working ${missing.join(' or ')} CLI — install it there and sign in, then try again`
  }
  return null
}
