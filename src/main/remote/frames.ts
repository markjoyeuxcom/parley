import {
  REMOTE_PROTOCOL_VERSION,
  type RemoteBody,
  type RemoteCapabilities,
  type RemoteEvidenceManifest,
  type RemoteFrame,
  type RemoteVendorDetail,
} from '@shared/remote'

/**
 * Reading and writing frames.
 *
 * Pure and total, and shared by both ends: the helper builds frames with these
 * and the local side reads them with these, so there is one definition of the
 * wire rather than two that agree until they do not.
 *
 * The reader's contract is that malformed input yields null rather than an
 * exception. A helper that prints a login banner, a shell profile that echoes
 * on connect, a line truncated by a dying connection — none of these are
 * frames, and none may end a run. What they may do is accumulate: a stream
 * with plenty of unreadable output and no readable output is its own
 * diagnosis, and a better one than a stack trace.
 */

/** Numbers frames within a run. Monotonic from 1, so 0 can mean "none yet". */
export class FrameWriter {
  private sequence = 0

  constructor(private readonly runId: string) {}

  next(body: RemoteBody): RemoteFrame {
    this.sequence += 1
    return {
      protocolVersion: REMOTE_PROTOCOL_VERSION,
      runId: this.runId,
      sequence: this.sequence,
      body,
    }
  }

  /** The line to write, terminated. JSON.stringify drops undefined for us. */
  line(body: RemoteBody): string {
    return `${JSON.stringify(this.next(body))}\n`
  }

  get lastSequence(): number {
    return this.sequence
  }
}

/**
 * Accepts each frame once.
 *
 * Deduplication is on (runId, sequence) and it exists before reconnection
 * does. The moment a connection can be resumed, a frame the remote sent but
 * could not confirm will arrive twice, and a record written twice from one
 * observation is a corrupted record — a milestone's spend double-counted, a
 * narrative appended to itself. Cheap now, impossible to retrofit honestly.
 */
export class FrameDeduplicator {
  private readonly seen = new Map<string, Set<number>>()

  /** True the first time this exact frame is offered, false every time after. */
  accept(frame: RemoteFrame): boolean {
    let sequences = this.seen.get(frame.runId)
    if (!sequences) {
      sequences = new Set()
      this.seen.set(frame.runId, sequences)
    }
    if (sequences.has(frame.sequence)) return false
    sequences.add(frame.sequence)
    return true
  }

  /** Highest sequence accepted for a run — what a resume would ask to follow. */
  highWater(runId: string): number {
    const sequences = this.seen.get(runId)
    if (!sequences) return 0
    let highest = 0
    for (const sequence of sequences) if (sequence > highest) highest = sequence
    return highest
  }

  forget(runId: string): void {
    this.seen.delete(runId)
  }
}

/* ------------------------------------------------------------------ */
/* Reading                                                             */
/* ------------------------------------------------------------------ */

export function decodeFrame(line: string): RemoteFrame | null {
  const trimmed = line.trim()
  if (!trimmed.startsWith('{')) return null

  let parsed: unknown
  try {
    parsed = JSON.parse(trimmed)
  } catch {
    return null
  }
  if (typeof parsed !== 'object' || parsed === null) return null

  const raw = parsed as Record<string, unknown>
  const protocolVersion = num(raw.protocolVersion)
  const runId = str(raw.runId)
  const sequence = num(raw.sequence)
  // A frame with no identity cannot be deduplicated, and one that cannot be
  // deduplicated cannot be safely replayed. Refuse it rather than accept a
  // frame we would have to trust exactly once.
  if (protocolVersion === null || runId === null || sequence === null) return null
  if (!Number.isInteger(sequence) || sequence < 1) return null

  const body = decodeBody(raw.body)
  if (!body) return null
  return { protocolVersion, runId, sequence, body }
}

function decodeBody(value: unknown): RemoteBody | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const type = raw.type
  if (typeof type !== 'string') return null

  switch (type) {
    case 'ready': {
      const capabilities = decodeCapabilities(raw.capabilities)
      return capabilities ? { type: 'ready', capabilities } : null
    }
    case 'stdout':
    case 'stderr': {
      const processId = str(raw.processId)
      const data = str(raw.data)
      if (processId === null || data === null) return null
      return { type, processId, data }
    }
    case 'exit': {
      const processId = str(raw.processId)
      const code = num(raw.code)
      if (processId === null || code === null) return null
      return { type: 'exit', processId, code, signal: str(raw.signal) }
    }
    case 'progress': {
      const phase = str(raw.phase)
      const text = str(raw.text)
      if (phase === null || text === null) return null
      return { type: 'progress', phase, text }
    }
    case 'fact': {
      // Kept opaque here on purpose: what a fact MEANS belongs to the
      // orchestrator's vocabulary, and teaching the wire about it would put
      // the record's shape back into the protocol.
      if (!has(raw, 'fact')) return null
      return { type: 'fact', fact: raw.fact }
    }
    case 'result': {
      const outcome = raw.outcome
      if (outcome !== 'complete' && outcome !== 'failed') return null
      const manifest = decodeManifest(raw.manifest)
      if (!manifest) return null
      return { type: 'result', outcome, manifest }
    }
    case 'error': {
      const message = str(raw.message)
      if (message === null) return null
      // Fail closed: retrying a run that is not safe to retry spends real
      // money and can duplicate work on the remote.
      return { type: 'error', message, retryable: raw.retryable === true }
    }
    default:
      return null
  }
}

function decodeCapabilities(value: unknown): RemoteCapabilities | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const protocolVersion = num(raw.protocolVersion)
  const buildId = str(raw.buildId)
  const nodeVersion = str(raw.nodeVersion)
  const runsRoot = str(raw.runsRoot)
  const user = str(raw.user)
  const home = str(raw.home)
  const path = str(raw.path)
  if (protocolVersion === null || buildId === null || nodeVersion === null) return null
  if (runsRoot === null || user === null || home === null || path === null) return null

  const details: Record<string, RemoteVendorDetail> = {}
  if (typeof raw.vendorDetails === 'object' && raw.vendorDetails !== null) {
    for (const [vendor, entry] of Object.entries(raw.vendorDetails as Record<string, unknown>)) {
      if (typeof entry !== 'object' || entry === null) continue
      const detail = entry as Record<string, unknown>
      details[vendor] = {
        executable: str(detail.executable),
        version: str(detail.version),
        configured: detail.configured === true,
        permissionMode: str(detail.permissionMode),
      }
    }
  }

  return {
    protocolVersion,
    buildId,
    nodeVersion,
    nodeExecutable: str(raw.nodeExecutable) ?? '',
    capabilities: strings(raw.capabilities),
    supportedVendors: strings(raw.supportedVendors),
    availableVendors: strings(raw.availableVendors),
    vendorDetails: details,
    user,
    home,
    path,
    git: str(raw.git),
    runsRoot,
  }
}

function decodeManifest(value: unknown): RemoteEvidenceManifest | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const baseCommit = str(raw.baseCommit)
  if (baseCommit === null) return null
  return {
    resultCommit: str(raw.resultCommit),
    baseCommit,
    changedPaths: strings(raw.changedPaths),
    artifactsPath: str(raw.artifactsPath),
  }
}

/**
 * Whether a key is actually present.
 *
 * The whole omitted-versus-null distinction rests on this. `value === undefined`
 * would be wrong at the protocol boundary: an object built locally can hold an
 * explicit undefined, which JSON would then drop, so the two sides would
 * disagree about whether a field was ever sent. Presence is the question, so
 * presence is what gets asked.
 */
export function has(value: object, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, key)
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}
