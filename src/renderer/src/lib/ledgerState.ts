import type { AppEvent } from '@shared/events'
import type { LedgerEntry } from '@shared/ipc'
import type { SessionDetail } from './api'

type LedgerEvent = Extract<AppEvent, { type: 'session.ledger' }>

/** The array-level merge both ledger holders share: replace-by-id, append. */
export function mergeLedgerEntries(
  entries: readonly LedgerEntry[],
  entry: LedgerEntry,
): LedgerEntry[] {
  return [...entries.filter((item) => item.id !== entry.id), entry]
}

export function mergeLedgerEntry(detail: SessionDetail, entry: LedgerEntry): SessionDetail {
  if (detail.session.id !== entry.sessionId) return detail
  return { ...detail, ledger: mergeLedgerEntries(detail.ledger, entry) }
}

export function applyLedgerEvent(
  detail: SessionDetail | null,
  event: LedgerEvent,
): SessionDetail | null {
  return detail ? mergeLedgerEntry(detail, event.entry) : detail
}

/**
 * The plan-side ledger's fold. Null means unknown — never fabricate an empty
 * ledger from an unknown one, because an empty ledger un-gates approvals.
 * The match key is the open plan's session: a Repos-hosted gate dialog's
 * disposition echo must land here even when no session view is mounted.
 */
export function applyPlanLedgerEvent(
  planLedger: readonly LedgerEntry[] | null,
  planSessionId: string | undefined,
  event: LedgerEvent,
): readonly LedgerEntry[] | null {
  if (planLedger === null) return planLedger
  if (!planSessionId || planSessionId !== event.entry.sessionId) return planLedger
  return mergeLedgerEntries(planLedger, event.entry)
}
