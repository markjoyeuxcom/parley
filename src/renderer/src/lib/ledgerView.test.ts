import { describe, expect, it } from 'vitest'
import type { FindingDisposition, FindingOccurrence } from '@shared/domain'
import type { LedgerEntry } from '@shared/ipc'
import {
  approvalPermission,
  buildLedgerView,
  findingTimeline,
  groupLedgerEntries,
} from './ledgerView'

function occurrence(
  id: string,
  findingId: string,
  seq: number,
  patch: Partial<FindingOccurrence> = {},
): FindingOccurrence {
  return {
    id,
    findingId,
    planId: 'plan-1',
    milestoneId: 'milestone-1',
    round: 0,
    kind: 'blocking',
    source: 'review',
    seq,
    createdAt: seq,
    ...patch,
  }
}

function disposition(
  id: string,
  findingId: string,
  seq: number,
  patch: Partial<FindingDisposition> = {},
): FindingDisposition {
  return {
    id,
    findingId,
    occurrenceId: null,
    state: 'resolved',
    note: 'Settled.',
    source: 'human',
    seq,
    createdAt: seq,
    ...patch,
  }
}

function entry(
  id: string,
  occurrences: FindingOccurrence[],
  dispositions: FindingDisposition[] = [],
): LedgerEntry {
  return {
    id,
    sessionId: 'session-1',
    text: `Finding ${id}`,
    normalizedText: `finding ${id}`,
    occurrences,
    dispositions,
    createdAt: 1,
  }
}

describe('ledger grouping and timeline', () => {
  it('groups repeated payloads without losing occurrence or disposition history', () => {
    const first = occurrence('occurrence-1', 'finding-1', 1)
    const second = occurrence('occurrence-2', 'finding-1', 3, {
      milestoneId: 'milestone-2',
      round: 1,
    })
    const settled = disposition('disposition-1', 'finding-1', 2, {
      occurrenceId: first.id,
    })

    const grouped = groupLedgerEntries([
      entry('finding-1', [first]),
      entry('finding-1', [first, second], [settled]),
    ])

    expect(grouped).toHaveLength(1)
    expect(grouped[0]?.occurrences).toEqual([first, second])
    expect(grouped[0]?.dispositions).toEqual([settled])
  })

  it('interleaves every occurrence and disposition by sequence, not timestamp', () => {
    const first = occurrence('occurrence-1', 'finding-1', 1, { createdAt: 30 })
    const settled = disposition('disposition-1', 'finding-1', 2, {
      occurrenceId: first.id,
      createdAt: 10,
    })
    const recurrence = occurrence('occurrence-2', 'finding-1', 3, {
      milestoneId: null,
      round: null,
      source: 'audit',
      createdAt: 20,
    })

    expect(
      findingTimeline(entry('finding-1', [recurrence, first], [settled])).map((item) => [
        item.type,
        item.type === 'occurrence' ? item.occurrence.id : item.disposition.id,
      ]),
    ).toEqual([
      ['occurrence', first.id],
      ['disposition', settled.id],
      ['occurrence', recurrence.id],
    ])
  })
})

describe('ledger approval permission', () => {
  it('allows approval only after every blocking occurrence has a covering disposition', () => {
    const first = occurrence('occurrence-1', 'finding-1', 1)
    const repeated = occurrence('occurrence-2', 'finding-1', 3, {
      milestoneId: 'milestone-2',
      round: 1,
    })
    const note = occurrence('note-1', 'finding-2', 4, { kind: 'note' })
    const firstResolved = disposition('disposition-1', 'finding-1', 2, {
      occurrenceId: first.id,
    })

    const blocked = approvalPermission([
      entry('finding-1', [first, repeated], [firstResolved]),
      entry('finding-2', [note]),
    ])
    expect(blocked.allowed).toBe(false)
    expect(blocked.unresolved.map(({ occurrence: item }) => item.id)).toEqual([repeated.id])

    const allResolved = disposition('disposition-2', 'finding-1', 5, {
      state: 'accepted-risk',
    })
    expect(
      approvalPermission([
        entry('finding-1', [first, repeated], [firstResolved, allResolved]),
        entry('finding-2', [note]),
      ]),
    ).toMatchObject({ allowed: true, unresolved: [] })
  })

  it('keeps an occurrence raised after a finding-wide disposition unresolved', () => {
    const first = occurrence('occurrence-1', 'finding-1', 1)
    const allPrior = disposition('disposition-1', 'finding-1', 2)
    const recurrence = occurrence('occurrence-2', 'finding-1', 3)

    const view = buildLedgerView([
      entry('finding-1', [first, recurrence], [allPrior]),
    ])[0]

    expect(view?.state).toBe('open')
    expect(view?.openBlockingOccurrences).toEqual([recurrence])
  })

  it('does not let a disposition for identical text on another finding clear a blocker', () => {
    const first = occurrence('occurrence-1', 'finding-1', 1)
    const other = occurrence('occurrence-2', 'finding-2', 2)
    const wrongDisposition = disposition('disposition-1', 'finding-2', 3, {
      occurrenceId: other.id,
    })

    const permission = approvalPermission([
      entry('finding-1', [first]),
      entry('finding-2', [other], [wrongDisposition]),
    ])

    expect(permission.allowed).toBe(false)
    expect(permission.unresolved.map(({ entry: item }) => item.id)).toEqual(['finding-1'])
  })
})
