import type { AppEvent } from '@shared/events'
import type { Hold } from '@shared/holds'

export type HoldsEvent = Extract<AppEvent, { type: 'holds.changed' }>

/**
 * Folds an authoritative holds snapshot into what the renderer holds.
 *
 * Returns the current array untouched when the payload is equivalent, so a
 * replayed snapshot — hydration racing the first event, a reconnect — never
 * causes a re-render. Identity alone is not equivalence: a hold's detail can
 * move while its id stays fixed (a gated approval's blocker count is worded
 * into the detail precisely so the count changing does not renotify).
 */
export function applyHoldsEvent(current: Hold[], event: HoldsEvent): Hold[] {
  return sameHolds(current, event.holds) ? current : event.holds
}

function sameHolds(a: Hold[], b: Hold[]): boolean {
  if (a.length !== b.length) return false
  return a.every((hold, index) => JSON.stringify(hold) === JSON.stringify(b[index]))
}

/** Decision-class holds only — the number the titlebar wears. */
export function countActionable(holds: Hold[]): number {
  return holds.filter((hold) => hold.actionable).length
}
