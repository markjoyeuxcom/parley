import type {
  FindingDisposition,
  FindingLedgerState,
  FindingOccurrence,
} from '@shared/domain'
import type { LedgerEntry } from '@shared/ipc'
import { findingState, occurrenceState } from '@shared/ledger'

export type LedgerTimelineItem =
  | {
      type: 'occurrence'
      seq: number
      createdAt: number
      occurrence: FindingOccurrence
      state: FindingLedgerState
    }
  | {
      type: 'disposition'
      seq: number
      createdAt: number
      disposition: FindingDisposition
    }

export interface FindingLedgerView {
  entry: LedgerEntry
  state: FindingLedgerState
  timeline: LedgerTimelineItem[]
  openBlockingOccurrences: FindingOccurrence[]
}

export interface BlockingOccurrenceView {
  entry: LedgerEntry
  occurrence: FindingOccurrence
}

export interface LedgerApprovalPermission {
  allowed: boolean
  unresolved: BlockingOccurrenceView[]
}

function uniqueById<T extends { id: string }>(items: readonly T[]): T[] {
  return [...new Map(items.map((item) => [item.id, item])).values()]
}

/**
 * Coalesces repeated payloads for a finding without collapsing its occurrences.
 *
 * Renderer events replace an entry in normal use, but grouping here keeps the
 * view correct if a caller combines a loaded snapshot with streamed updates.
 */
export function groupLedgerEntries(entries: readonly LedgerEntry[]): LedgerEntry[] {
  const grouped = new Map<string, LedgerEntry>()

  for (const entry of entries) {
    const existing = grouped.get(entry.id)
    if (!existing) {
      grouped.set(entry.id, {
        ...entry,
        occurrences: uniqueById(entry.occurrences),
        dispositions: uniqueById(entry.dispositions),
      })
      continue
    }

    grouped.set(entry.id, {
      ...existing,
      ...entry,
      occurrences: uniqueById([...existing.occurrences, ...entry.occurrences]),
      dispositions: uniqueById([...existing.dispositions, ...entry.dispositions]),
      createdAt: Math.min(existing.createdAt, entry.createdAt),
    })
  }

  return [...grouped.values()].sort(
    (left, right) => left.createdAt - right.createdAt || left.id.localeCompare(right.id),
  )
}

/** Interleaves every occurrence and disposition using the durable ledger order. */
export function findingTimeline(entry: LedgerEntry): LedgerTimelineItem[] {
  const occurrences: LedgerTimelineItem[] = entry.occurrences.map((occurrence) => ({
    type: 'occurrence',
    seq: occurrence.seq,
    createdAt: occurrence.createdAt,
    occurrence,
    state: occurrenceState(occurrence, entry.dispositions),
  }))
  const dispositions: LedgerTimelineItem[] = entry.dispositions.map((disposition) => ({
    type: 'disposition',
    seq: disposition.seq,
    createdAt: disposition.createdAt,
    disposition,
  }))

  return [...occurrences, ...dispositions].sort(
    (left, right) =>
      left.seq - right.seq ||
      left.createdAt - right.createdAt ||
      timelineId(left).localeCompare(timelineId(right)),
  )
}

function timelineId(item: LedgerTimelineItem): string {
  return item.type === 'occurrence' ? item.occurrence.id : item.disposition.id
}

export function buildLedgerView(entries: readonly LedgerEntry[]): FindingLedgerView[] {
  return groupLedgerEntries(entries).map((entry) => {
    const openBlockingOccurrences = entry.occurrences
      .filter(
        (occurrence) =>
          occurrence.kind === 'blocking' &&
          occurrenceState(occurrence, entry.dispositions) === 'open',
      )
      .sort((left, right) => left.seq - right.seq || left.id.localeCompare(right.id))

    return {
      entry,
      state: findingState(entry, entry.occurrences, entry.dispositions),
      timeline: findingTimeline(entry),
      openBlockingOccurrences,
    }
  })
}

/**
 * The renderer-side approval rule.
 *
 * It intentionally considers every session occurrence. A blocker is cleared
 * only by a disposition that covers that exact occurrence (or a finding-wide
 * disposition recorded after it).
 */
export function approvalPermission(entries: readonly LedgerEntry[]): LedgerApprovalPermission {
  const unresolved = buildLedgerView(entries)
    .flatMap((view) =>
      view.openBlockingOccurrences.map((occurrence) => ({ entry: view.entry, occurrence })),
    )
    .sort(
      (left, right) =>
        left.occurrence.seq - right.occurrence.seq ||
        left.occurrence.id.localeCompare(right.occurrence.id),
    )
  return { allowed: unresolved.length === 0, unresolved }
}
