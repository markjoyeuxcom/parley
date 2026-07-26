/**
 * Pulling structured data back out of a prose reply.
 *
 * Both CLIs stream prose, so the protocol asks each agent to end its message
 * with one fenced JSON block. Models are not reliable about that, so extraction
 * is defensive and never throws: on failure the caller keeps the prose and
 * treats the structured part as absent. Losing a verdict's scores is
 * recoverable; losing the whole turn is not.
 */

export interface Extracted<T> {
  /** The message with the trailing JSON block removed, trimmed. */
  prose: string
  /** Parsed payload, or null when no valid JSON block was found. */
  data: T | null
  /** Set when a block was found but could not be used. */
  problem: string | null
}

/** Matches ```json ... ``` and bare ``` ... ``` fences. */
const FENCE = /```(?:json|jsonc)?\s*\n([\s\S]*?)```/gi

/**
 * Scans forward for the first balanced `{...}` run, respecting string literals
 * and escapes. Used when the model emitted JSON with no fence at all.
 */
function findBalancedObject(text: string, from: number): { start: number; end: number } | null {
  const start = text.indexOf('{', from)
  if (start === -1) return null

  let depth = 0
  let inString = false
  let escaped = false

  for (let i = start; i < text.length; i += 1) {
    const ch = text[i]
    if (escaped) {
      escaped = false
      continue
    }
    if (ch === '\\') {
      if (inString) escaped = true
      continue
    }
    if (ch === '"') {
      inString = !inString
      continue
    }
    if (inString) continue
    if (ch === '{') depth += 1
    else if (ch === '}') {
      depth -= 1
      if (depth === 0) return { start, end: i + 1 }
    }
  }
  return null
}

/**
 * Every structured contract in the protocol is a JSON *object* with named
 * fields. A top-level array is rejected rather than accepted, because arrays are
 * `typeof 'object'` and would otherwise flow downstream to fail later as a
 * confusing "missing field" instead of an honest "no usable JSON".
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function tryParse(raw: string): unknown | null {
  const trimmed = raw.trim()
  if (!trimmed) return null
  try {
    return JSON.parse(trimmed)
  } catch {
    // Trailing commas are the single most common malformation. Nothing more
    // aggressive than that — silently repairing arbitrary JSON risks changing
    // what the model actually meant.
    try {
      return JSON.parse(trimmed.replace(/,(\s*[}\]])/g, '$1'))
    } catch {
      return null
    }
  }
}

/**
 * Extracts the *last* JSON object in the message. Last rather than first
 * because the protocol puts the block at the end, and prose above it may itself
 * contain illustrative JSON in a fence.
 */
export function extractJson<T = unknown>(message: string): Extracted<T> {
  if (!message) return { prose: '', data: null, problem: null }

  const fences = [...message.matchAll(FENCE)]
  for (let i = fences.length - 1; i >= 0; i -= 1) {
    const match = fences[i]
    if (!match) continue
    const body = match[1] ?? ''
    const parsed = tryParse(body)
    if (isPlainObject(parsed)) {
      const prose = (message.slice(0, match.index) + message.slice(match.index + match[0].length)).trim()
      return { prose, data: parsed as T, problem: null }
    }
  }

  // No usable fence. Fall back to a bare balanced object, scanning from the last
  // plausible opening brace backwards so we prefer the trailing block.
  const lastBrace = message.lastIndexOf('{')
  if (lastBrace !== -1) {
    let searchFrom = 0
    let best: { start: number; end: number } | null = null
    while (searchFrom <= lastBrace) {
      const found = findBalancedObject(message, searchFrom)
      if (!found) break
      best = found
      // Past the whole object, not one character into it. Advancing by a single
      // character descends into the first nested object and, because the last match
      // wins, returns that instead of the block it is nested in — so a bare
      // {"milestones":[{…}]} reply parsed as the first milestone and the plan came
      // back empty. Stepping over the match keeps the trailing-block preference this
      // loop is for while only ever comparing top-level candidates.
      searchFrom = found.end
    }
    if (best) {
      const parsed = tryParse(message.slice(best.start, best.end))
      if (isPlainObject(parsed)) {
        const prose = (message.slice(0, best.start) + message.slice(best.end)).trim()
        return { prose, data: parsed as T, problem: null }
      }
    }
  }

  const sawFence = fences.length > 0
  return {
    prose: message.trim(),
    data: null,
    problem: sawFence ? 'a fenced block was present but did not parse as JSON' : 'no JSON block found',
  }
}

/** Clamps a possibly-absent numeric field into range, with a fallback. */
export function clampNumber(value: unknown, min: number, max: number, fallback: number): number {
  const n = typeof value === 'string' ? Number(value) : value
  if (typeof n !== 'number' || !Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

/** Coerces to a trimmed string, with a length ceiling to bound stored rows. */
export function safeString(value: unknown, max = 20_000): string {
  if (typeof value === 'string') return value.trim().slice(0, max)
  if (value === null || value === undefined) return ''
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return ''
}

/** Accepts a value only if it is one of `allowed`, else returns `fallback`. */
export function oneOf<T extends string>(value: unknown, allowed: readonly T[], fallback: T): T {
  return typeof value === 'string' && (allowed as readonly string[]).includes(value) ? (value as T) : fallback
}
