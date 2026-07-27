import type { AppEvent } from '@shared/events'
import type { LedgerEntry } from '@shared/ipc'
import type { SessionDetail } from './api'

type LedgerEvent = Extract<AppEvent, { type: 'session.ledger' }>

export function mergeLedgerEntry(detail: SessionDetail, entry: LedgerEntry): SessionDetail {
  if (detail.session.id !== entry.sessionId) return detail
  const existing = detail.ledger.filter((item) => item.id !== entry.id)
  return { ...detail, ledger: [...existing, entry] }
}

export function applyLedgerEvent(
  detail: SessionDetail | null,
  event: LedgerEvent,
): SessionDetail | null {
  return detail ? mergeLedgerEntry(detail, event.entry) : detail
}
