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
 * What to do with a frame that just arrived.
 *
 * A gap is not a frame to hold on to. ssh gives an ordered byte stream, so a
 * missing sequence cannot be "in flight" — it means corruption, a parser bug
 * or an emitter bug, and the only honest response is to stop. Buffering 14
 * while hoping 13 turns up would produce a run whose record has a hole in it
 * and whose resume point is a fiction.
 */
export type FrameAdmission =
  | { kind: 'accept' }
  /** Already applied. Safe to ignore — this is exactly what resume will resend. */
  | { kind: 'duplicate' }
  | { kind: 'gap'; expected: number }

/**
 * Admits frames in order, once each.
 *
 * The high-water mark is the highest CONTIGUOUS sequence accepted, which is
 * the only number a resume can honestly be based on: "everything up to here
 * has been applied". The largest sequence merely *observed* would be a lie the
 * moment anything was missed.
 *
 * That definition also collapses the bookkeeping to one integer per run. An
 * ever-growing set of seen sequences would be both heavier and weaker — it
 * would happily accept 14 before 13 and never notice the hole.
 */
export class FrameSequencer {
  private readonly contiguous = new Map<string, number>()

  admit(frame: RemoteFrame): FrameAdmission {
    const high = this.contiguous.get(frame.runId) ?? 0
    if (frame.sequence <= high) return { kind: 'duplicate' }
    if (frame.sequence > high + 1) return { kind: 'gap', expected: high + 1 }
    this.contiguous.set(frame.runId, frame.sequence)
    return { kind: 'accept' }
  }

  /** Everything up to and including this has been applied. Zero means none. */
  highWater(runId: string): number {
    return this.contiguous.get(runId) ?? 0
  }

  forget(runId: string): void {
    this.contiguous.delete(runId)
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
