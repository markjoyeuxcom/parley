import type {
  FindingDisposition,
  FindingLedgerState,
  FindingOccurrence,
  Id,
  LedgerFinding,
} from './domain'

const TRAILING_MARKS = /[\s\p{P}\p{S}]+$/u

/**
 * Removes presentation drift without treating a rewritten objection as the
 * same finding.
 */
export function normaliseFindingText(text: string): string {
  const collapsed = text.trim().toLowerCase().replace(/\s+/gu, ' ')
  return collapsed.replace(TRAILING_MARKS, '') || collapsed
}

/**
 * A synchronous SHA-256 implementation keeps finding identity deterministic in
 * both Electron processes without importing Node into this shared module.
 * Exported because hold identity (shared/holds.ts) is built on the same
 * property and must never diverge from the ledger's notion of "same content".
 */
export function sha256(text: string): string {
  const bytes = new TextEncoder().encode(text)
  const bitLength = bytes.length * 8
  const paddedLength = Math.ceil((bytes.length + 9) / 64) * 64
  const padded = new Uint8Array(paddedLength)
  padded.set(bytes)
  padded[bytes.length] = 0x80

  const view = new DataView(padded.buffer)
  const high = Math.floor(bitLength / 0x1_0000_0000)
  const low = bitLength >>> 0
  view.setUint32(paddedLength - 8, high)
  view.setUint32(paddedLength - 4, low)

  const constants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]
  const hash = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]
  const words = new Uint32Array(64)

  for (let offset = 0; offset < paddedLength; offset += 64) {
    for (let i = 0; i < 16; i += 1) words[i] = view.getUint32(offset + i * 4)
    for (let i = 16; i < 64; i += 1) {
      const x = words[i - 15] ?? 0
      const y = words[i - 2] ?? 0
      const s0 = rightRotate(x, 7) ^ rightRotate(x, 18) ^ (x >>> 3)
      const s1 = rightRotate(y, 17) ^ rightRotate(y, 19) ^ (y >>> 10)
      words[i] = ((words[i - 16] ?? 0) + s0 + (words[i - 7] ?? 0) + s1) >>> 0
    }

    let [a, b, c, d, e, f, g, h] = hash
    for (let i = 0; i < 64; i += 1) {
      const sum1 = rightRotate(e ?? 0, 6) ^ rightRotate(e ?? 0, 11) ^ rightRotate(e ?? 0, 25)
      const choose = ((e ?? 0) & (f ?? 0)) ^ (~(e ?? 0) & (g ?? 0))
      const temp1 = ((h ?? 0) + sum1 + choose + (constants[i] ?? 0) + (words[i] ?? 0)) >>> 0
      const sum0 = rightRotate(a ?? 0, 2) ^ rightRotate(a ?? 0, 13) ^ rightRotate(a ?? 0, 22)
      const majority = ((a ?? 0) & (b ?? 0)) ^ ((a ?? 0) & (c ?? 0)) ^ ((b ?? 0) & (c ?? 0))
      const temp2 = (sum0 + majority) >>> 0
      h = g
      g = f
      f = e
      e = ((d ?? 0) + temp1) >>> 0
      d = c
      c = b
      b = a
      a = (temp1 + temp2) >>> 0
    }

    hash[0] = ((hash[0] ?? 0) + (a ?? 0)) >>> 0
    hash[1] = ((hash[1] ?? 0) + (b ?? 0)) >>> 0
    hash[2] = ((hash[2] ?? 0) + (c ?? 0)) >>> 0
    hash[3] = ((hash[3] ?? 0) + (d ?? 0)) >>> 0
    hash[4] = ((hash[4] ?? 0) + (e ?? 0)) >>> 0
    hash[5] = ((hash[5] ?? 0) + (f ?? 0)) >>> 0
    hash[6] = ((hash[6] ?? 0) + (g ?? 0)) >>> 0
    hash[7] = ((hash[7] ?? 0) + (h ?? 0)) >>> 0
  }

  return hash.map((word) => word.toString(16).padStart(8, '0')).join('')
}

function rightRotate(value: number, distance: number): number {
  return (value >>> distance) | (value << (32 - distance))
}

/** Content identity within a session. */
export function findingIdentity(sessionId: Id, text: string): Id {
  return sha256(`${sessionId}\0${normaliseFindingText(text)}`)
}

/** Content identity independent of ledger scope, useful for matching ingestion. */
export function findingFingerprint(text: string): string {
  return sha256(normaliseFindingText(text))
}

function coversOccurrence(
  disposition: FindingDisposition,
  occurrence: FindingOccurrence,
): boolean {
  if (disposition.findingId !== occurrence.findingId) return false
  if (disposition.occurrenceId !== null) return disposition.occurrenceId === occurrence.id
  return occurrence.seq <= disposition.seq
}

/** Resolves one occurrence from an append-ordered disposition history. */
export function occurrenceState(
  occurrence: FindingOccurrence,
  dispositions: readonly FindingDisposition[],
): FindingLedgerState {
  let state: FindingLedgerState = 'open'
  let settledSeq = -1
  for (const disposition of dispositions) {
    if (!coversOccurrence(disposition, occurrence) || disposition.seq < settledSeq) continue
    state = disposition.state
    settledSeq = disposition.seq
  }
  return state
}

function findingIdOf(finding: Id | Pick<LedgerFinding, 'id'>): Id {
  return typeof finding === 'string' ? finding : finding.id
}

/**
 * A repeated finding remains open until every one of its occurrences is
 * covered. Once closed, the latest occurrence's disposition is its display
 * state.
 */
export function findingState(
  finding: Id | Pick<LedgerFinding, 'id'>,
  occurrences: readonly FindingOccurrence[],
  dispositions: readonly FindingDisposition[],
): FindingLedgerState {
  const matching = occurrences.filter((occurrence) => occurrence.findingId === findingIdOf(finding))
  if (!matching.length) return 'open'

  let latest = matching[0]!
  let latestState = occurrenceState(latest, dispositions)
  for (const occurrence of matching) {
    const state = occurrenceState(occurrence, dispositions)
    if (state === 'open') return 'open'
    if (occurrence.seq >= latest.seq) {
      latest = occurrence
      latestState = state
    }
  }
  return latestState
}

export function isBlockingOccurrence(occurrence: FindingOccurrence): boolean {
  return occurrence.kind === 'blocking'
}

/** Only an open blocking occurrence participates in the approval gate. */
export function hasOpenBlockingOccurrences(
  occurrences: readonly FindingOccurrence[],
  dispositions: readonly FindingDisposition[],
): boolean {
  return occurrences.some(
    (occurrence) => isBlockingOccurrence(occurrence) && occurrenceState(occurrence, dispositions) === 'open',
  )
}
