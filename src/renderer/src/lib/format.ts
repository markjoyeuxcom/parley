import type { Usage } from '@shared/domain'

/** Compact token counts: 1_240 → "1.2k", 1_240_000 → "1.2M". */
export function compactNumber(value: number): string {
  if (!Number.isFinite(value)) return '—'
  if (Math.abs(value) < 1000) return String(Math.round(value))
  if (Math.abs(value) < 1_000_000) return `${(value / 1000).toFixed(value < 10_000 ? 1 : 0)}k`
  return `${(value / 1_000_000).toFixed(1)}M`
}

export function formatTokens(usage: Usage): string {
  return `${compactNumber(usage.inputTokens + usage.cachedInputTokens)} in · ${compactNumber(usage.outputTokens)} out`
}

/** Short relative time. Falls back to a date past a week. */
export function relativeTime(timestamp: number): string {
  const delta = Date.now() - timestamp
  const minute = 60_000
  const hour = 60 * minute
  const day = 24 * hour

  if (delta < 45_000) return 'just now'
  if (delta < hour) return `${Math.round(delta / minute)}m ago`
  if (delta < day) return `${Math.round(delta / hour)}h ago`
  if (delta < 7 * day) return `${Math.round(delta / day)}d ago`
  return new Date(timestamp).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

export function formatDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '—'
  const seconds = Math.round(ms / 1000)
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

export function formatMinutes(ms: number): string {
  const minutes = Math.round(ms / 60_000)
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return rest ? `${hours}h ${rest}m` : `${hours}h`
}

/** `~/Developer/thing/src` → `thing/src`. */
export function shortPath(path: string): string {
  const parts = path.split('/').filter(Boolean)
  if (parts.length <= 2) return path
  return parts.slice(-2).join('/')
}

/** First sentence or `max` characters, whichever is shorter. Used for list rows. */
export function firstLine(text: string, max = 90): string {
  const trimmed = text.trim().replace(/\s+/g, ' ')
  if (!trimmed) return ''
  const stop = trimmed.search(/[.!?](\s|$)/)
  const candidate = stop > 20 && stop < max ? trimmed.slice(0, stop + 1) : trimmed
  return candidate.length > max ? `${candidate.slice(0, max - 1).trimEnd()}…` : candidate
}

/**
 * The side skin a seat wears.
 *
 * Seats 0 and 1 are the classic a/b colour pair; later seats reuse it by
 * parity until the surface learns to seat more than two, later in the
 * Participants series.
 */
export function seatSide(seat: number): 'a' | 'b' {
  return seat % 2 === 0 ? 'a' : 'b'
}

/** The short speaker label for a seat: A, B, then numbers. */
export function seatLabel(seat: number): string {
  return seat === 0 ? 'A' : seat === 1 ? 'B' : `S${seat + 1}`
}

export const VENDOR_LABEL: Record<string, string> = {
  claude: 'Claude',
  codex: 'Codex',
}

/** Status → chip class + label, shared by sessions and loops. */
export function statusTone(status: string): { tone: string; label: string } {
  switch (status) {
    case 'running':
    case 'executing':
    case 'testing':
    case 'reviewing':
    case 'drafting':
    case 'auditing':
      return { tone: 'chip--accent', label: status }
    case 'complete':
    case 'succeeded':
    case 'audited':
    case 'ready':
      return { tone: 'chip--pass', label: status }
    case 'paused':
    case 'stopping':
    case 'exhausted':
    case 'planned':
    case 'blocked':
    // Amber rather than red on purpose: nothing went wrong with the work, and
    // colouring it as a failure would be the same lie the status exists to
    // stop the record telling.
    case 'parked':
      return { tone: 'chip--caution', label: status }
    case 'failed':
    case 'killed':
    case 'cancelled':
    case 'rejected':
      return { tone: 'chip--fail', label: status }
    default:
      return { tone: '', label: status }
  }
}

/**
 * The four things a verification run can mean.
 *
 * Kept out of the component and tested, because the ordering here is load-bearing
 * and not obvious: a timeout is delivered as a SIGTERM, so `timedOut` must be
 * checked before `signal` or every timeout reads as a crash. The distinction
 * matters because the four states call for different responses — a crash says the
 * command itself is suspect and nothing was verified, a failure says the suite ran
 * and disagreed — and they were previously one line of prose.
 */
export function verificationState(result: {
  exitCode: number
  signal: string | null
  timedOut: boolean
}): { label: string; tone: string; detail: string; verified: boolean } {
  if (result.timedOut) {
    return {
      label: 'timed out',
      tone: 'chip--caution',
      detail: 'nothing was verified — it never finished',
      verified: false,
    }
  }
  if (result.signal) {
    return {
      label: `crashed (${result.signal})`,
      tone: 'chip--caution',
      detail: 'nothing was verified — the command died',
      verified: false,
    }
  }
  if (result.exitCode === 0) {
    return { label: 'passed', tone: 'chip--pass', detail: '', verified: true }
  }
  return {
    label: `failed (exit ${result.exitCode})`,
    tone: 'chip--fail',
    detail: 'the suite ran and disagreed',
    verified: true,
  }
}
