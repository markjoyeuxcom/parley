import { describe, expect, it } from 'vitest'
import {
  FindingDisposition,
  FindingOccurrence,
  LedgerFinding,
  type FindingDisposition as FindingDispositionType,
  type FindingOccurrence as FindingOccurrenceType,
} from './domain'
import {
  findingFingerprint,
  findingIdentity,
  findingState,
  hasOpenBlockingOccurrences,
  normaliseFindingText,
  occurrenceState,
} from './ledger'

function occurrence(
  id: string,
  findingId: string,
  createdAt: number,
  patch: Partial<FindingOccurrenceType> = {},
): FindingOccurrenceType {
  return FindingOccurrence.parse({
    id,
    findingId,
    planId: 'plan-1',
    milestoneId: 'milestone-1',
    round: 0,
    kind: 'blocking',
    source: 'review',
    seq: createdAt,
    createdAt,
    ...patch,
  })
}

function disposition(
  id: string,
  findingId: string,
  createdAt: number,
  patch: Partial<FindingDispositionType> = {},
): FindingDispositionType {
  return FindingDisposition.parse({
    id,
    findingId,
    occurrenceId: null,
    state: 'resolved',
    source: 'human',
    seq: createdAt,
    createdAt,
    ...patch,
  })
}

describe('ledger schemas', () => {
  it('records stable findings, occurrence provenance, and scoped dispositions', () => {
    expect(
      LedgerFinding.parse({
        id: 'finding-1',
        sessionId: 'session-1',
        text: 'Tests do not exercise the gate.',
        normalizedText: 'tests do not exercise the gate',
        createdAt: 1,
      }),
    ).toMatchObject({ sessionId: 'session-1' })

    expect(
      occurrence('occurrence-1', 'finding-1', 2, {
        planId: 'plan-2',
        milestoneId: null,
        round: null,
        source: 'audit',
      }),
    ).toMatchObject({ planId: 'plan-2', milestoneId: null, round: null, source: 'audit' })

    expect(
      disposition('disposition-1', 'finding-1', 3, {
        occurrenceId: 'occurrence-1',
        state: 'accepted-risk',
        note: 'Accepted by the user.',
      }),
    ).toMatchObject({ occurrenceId: 'occurrence-1', state: 'accepted-risk' })
  })
})

describe('finding identity', () => {
  it('folds only case, whitespace, and trailing punctuation drift', () => {
    const variants = [
      '  Approval routing is not tested.  ',
      'approval   ROUTING\nis not tested',
      'Approval routing is not tested?!…',
    ]

    expect(variants.map(normaliseFindingText)).toEqual([
      'approval routing is not tested',
      'approval routing is not tested',
      'approval routing is not tested',
    ])
    expect(new Set(variants.map(findingFingerprint))).toHaveLength(1)
    expect(findingFingerprint('abc')).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    )
  })

  it('gives genuine rewording a new identity and scopes identity to a session', () => {
    expect(findingFingerprint('The approval path is untested.')).not.toBe(
      findingFingerprint('Manager approval routing needs an explicit test.'),
    )
    expect(findingIdentity('session-1', 'Same finding.')).not.toBe(
      findingIdentity('session-2', 'Same finding.'),
    )
    expect(findingIdentity('session-1', 'Same finding.')).toMatch(/^[a-f0-9]{64}$/)
  })
})

describe('occurrence-scoped state', () => {
  it('keeps each occurrence open until a disposition covers that occurrence', () => {
    const first = occurrence('occurrence-1', 'finding-1', 10)
    const second = occurrence('occurrence-2', 'finding-1', 20, { milestoneId: 'milestone-2' })
    const scoped = disposition('disposition-1', 'finding-1', 30, {
      occurrenceId: first.id,
      state: 'dismissed',
    })

    expect(occurrenceState(first, [scoped])).toBe('dismissed')
    expect(occurrenceState(second, [scoped])).toBe('open')
    expect(findingState('finding-1', [first, second], [scoped])).toBe('open')
  })

  it('lets an unscoped disposition cover all prior occurrences but not a recurrence', () => {
    const first = occurrence('occurrence-1', 'finding-1', 10)
    const second = occurrence('occurrence-2', 'finding-1', 20, { milestoneId: 'milestone-2' })
    const settled = disposition('disposition-1', 'finding-1', 30, { state: 'accepted-risk' })
    const recurrence = occurrence('occurrence-3', 'finding-1', 40, {
      planId: 'plan-2',
      milestoneId: 'milestone-3',
    })

    expect(occurrenceState(first, [settled])).toBe('accepted-risk')
    expect(occurrenceState(second, [settled])).toBe('accepted-risk')
    expect(occurrenceState(recurrence, [settled])).toBe('open')
    expect(findingState('finding-1', [first, second, recurrence], [settled])).toBe('open')
  })

  it('keeps a same-millisecond recurrence open when it follows a finding-wide disposition', () => {
    const first = occurrence('occurrence-1', 'finding-1', 10, { seq: 1 })
    const settled = disposition('disposition-1', 'finding-1', 10, {
      seq: 2,
      state: 'accepted-risk',
    })
    const recurrence = occurrence('occurrence-2', 'finding-1', 10, { seq: 3 })

    expect(occurrenceState(first, [settled])).toBe('accepted-risk')
    expect(occurrenceState(recurrence, [settled])).toBe('open')
    expect(hasOpenBlockingOccurrences([first, recurrence], [settled])).toBe(true)
  })

  it('resolves same-createdAt dispositions in sequence order', () => {
    const sighting = occurrence('occurrence-1', 'finding-1', 10, { seq: 1 })
    const first = disposition('disposition-1', 'finding-1', 20, {
      occurrenceId: sighting.id,
      seq: 2,
      state: 'dismissed',
    })
    const second = disposition('disposition-2', 'finding-1', 20, {
      occurrenceId: sighting.id,
      seq: 3,
      state: 'resolved',
    })

    expect(occurrenceState(sighting, [second, first])).toBe('resolved')
  })

  it('takes the state of the later closed occurrence by sequence', () => {
    const first = occurrence('occurrence-1', 'finding-1', 10, { seq: 1 })
    const second = occurrence('occurrence-2', 'finding-1', 10, {
      milestoneId: 'milestone-2',
      seq: 3,
    })
    const firstClosed = disposition('disposition-1', 'finding-1', 10, {
      occurrenceId: first.id,
      seq: 2,
      state: 'dismissed',
    })
    const secondClosed = disposition('disposition-2', 'finding-1', 10, {
      occurrenceId: second.id,
      seq: 4,
      state: 'accepted-risk',
    })

    expect(findingState('finding-1', [second, first], [secondClosed, firstClosed])).toBe(
      'accepted-risk',
    )
  })

  it('uses the latest covering disposition without crossing finding boundaries', () => {
    const sighting = occurrence('occurrence-1', 'finding-1', 10)
    const history = [
      disposition('wrong-finding', 'finding-2', 40, { state: 'dismissed' }),
      disposition('first', 'finding-1', 20, { state: 'dismissed' }),
      disposition('latest', 'finding-1', 30, { state: 'resolved' }),
    ]

    expect(occurrenceState(sighting, history)).toBe('resolved')
    expect(findingState('finding-1', [sighting], history)).toBe('resolved')
  })

  it('does not let identical text on another milestone clear that occurrence', () => {
    const firstMilestone = occurrence('occurrence-1', 'finding-1', 10)
    const secondMilestone = occurrence('occurrence-2', 'finding-1', 11, {
      milestoneId: 'milestone-2',
    })
    const firstPassed = disposition('pipeline-1', 'finding-1', 20, {
      occurrenceId: firstMilestone.id,
      source: 'pipeline',
    })

    expect(findingState('finding-1', [firstMilestone, secondMilestone], [firstPassed])).toBe('open')
  })
})

describe('approval gating', () => {
  it('gates only on open blocking occurrences', () => {
    const blocker = occurrence('blocking', 'finding-1', 10)
    const note = occurrence('note', 'finding-2', 11, { kind: 'note' })

    expect(hasOpenBlockingOccurrences([note], [])).toBe(false)
    expect(hasOpenBlockingOccurrences([blocker, note], [])).toBe(true)
    expect(
      hasOpenBlockingOccurrences(
        [blocker, note],
        [disposition('resolved', blocker.findingId, 20, { occurrenceId: blocker.id })],
      ),
    ).toBe(false)
  })
})
