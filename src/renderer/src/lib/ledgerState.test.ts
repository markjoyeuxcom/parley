import { describe, expect, it } from 'vitest'
import type { FindingDisposition, FindingOccurrence, Session } from '@shared/domain'
import type { LedgerEntry } from '@shared/ipc'
import type { SessionDetail } from './api'
import { applyLedgerEvent, applyPlanLedgerEvent } from './ledgerState'

function session(id: string): Session {
  return {
    id,
    kind: 'debate',
    status: 'complete',
    matter: 'Should this change ship?',
    project: '',
    repoPath: null,
    participants: [
      { vendor: 'claude', model: '', effort: 'medium', persona: '' },
      { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    ],
    maxTurns: 6,
    usage: {
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      costUsd: 0,
    },
    mock: false,
    createdAt: 1,
    endedAt: 2,
    error: null,
    archivedAt: null,
  }
}

function detail(sessionId: string, ledger: LedgerEntry[] = []): SessionDetail {
  return {
    session: session(sessionId),
    turns: [],
    interjections: [],
    verdict: null,
    findings: [],
    ledger,
    plans: [],
  }
}

function entry(
  sessionId: string,
  dispositions: FindingDisposition[] = [],
): LedgerEntry {
  const occurrence: FindingOccurrence = {
    id: 'occurrence-1',
    findingId: 'finding-1',
    planId: 'plan-1',
    milestoneId: 'milestone-1',
    round: 0,
    kind: 'blocking',
    source: 'review',
    seq: 1,
    createdAt: 2,
  }
  return {
    id: 'finding-1',
    sessionId,
    text: 'The approval path is not tested.',
    normalizedText: 'the approval path is not tested',
    occurrences: [occurrence],
    dispositions,
    createdAt: 1,
  }
}

describe('ledger event state', () => {
  it('adds an emitted ledger entry to the active session', () => {
    const current = detail('session-1')
    const updated = applyLedgerEvent(current, {
      type: 'session.ledger',
      entry: entry('session-1'),
    })

    expect(updated?.ledger).toHaveLength(1)
    expect(updated?.ledger[0]?.occurrences[0]?.id).toBe('occurrence-1')
  })

  it('replaces the entry when a recorded disposition is emitted', () => {
    const current = detail('session-1', [entry('session-1')])
    const disposition: FindingDisposition = {
      id: 'disposition-1',
      findingId: 'finding-1',
      occurrenceId: 'occurrence-1',
      state: 'dismissed',
      note: 'The report used an obsolete call path.',
      source: 'human',
      seq: 2,
      createdAt: 3,
    }
    const updated = applyLedgerEvent(current, {
      type: 'session.ledger',
      entry: entry('session-1', [disposition]),
    })

    expect(updated?.ledger).toHaveLength(1)
    expect(updated?.ledger[0]?.dispositions).toEqual([disposition])
  })

  it('does not merge an entry belonging to another session', () => {
    const current = detail('session-1')
    expect(
      applyLedgerEvent(current, {
        type: 'session.ledger',
        entry: entry('session-2'),
      }),
    ).toBe(current)
  })
})

describe('the plan-side ledger fold', () => {
  it('null means unknown and stays unknown — never fabricated into empty', () => {
    expect(
      applyPlanLedgerEvent(null, 'session-1', {
        type: 'session.ledger',
        entry: entry('session-1'),
      }),
    ).toBeNull()
  })

  it('merges only when the open plan belongs to the entry session', () => {
    const existing = [entry('session-1')]
    const updated = applyPlanLedgerEvent(existing, 'session-1', {
      type: 'session.ledger',
      entry: { ...entry('session-1'), id: 'finding-2' },
    })
    expect(updated).toHaveLength(2)

    // A different open plan's session, or no open plan: untouched.
    expect(
      applyPlanLedgerEvent(existing, 'session-2', {
        type: 'session.ledger',
        entry: entry('session-1'),
      }),
    ).toBe(existing)
    expect(
      applyPlanLedgerEvent(existing, undefined, {
        type: 'session.ledger',
        entry: entry('session-1'),
      }),
    ).toBe(existing)
  })

  it('the Repos-host echo lands with no session view at all', () => {
    // The exact scenario the reducer rewrite exists for: a disposition
    // recorded from the Repos-hosted gate dialog while sessionDetail is
    // null. The session-side fold drops it; the plan-side fold must not.
    expect(applyLedgerEvent(null, { type: 'session.ledger', entry: entry('session-1') })).toBeNull()
    const updated = applyPlanLedgerEvent([entry('session-1')], 'session-1', {
      type: 'session.ledger',
      entry: { ...entry('session-1'), dispositions: [] },
    })
    expect(updated).toHaveLength(1)
  })
})
