import { describe, expect, it } from 'vitest'
import type { Hold } from '@shared/holds'
import { applyHoldsEvent, countActionable, type HoldsEvent } from './holdsState'

function hold(overrides: Partial<Hold>): Hold {
  return {
    id: 'a'.repeat(64),
    kind: 'clarification',
    sessionId: 'session-1',
    planId: 'plan-1',
    milestoneId: null,
    loopId: null,
    repoPath: null,
    title: 'Waiting on your answer',
    detail: 'Which database?',
    sinceAt: 1_000,
    actionable: true,
    mock: false,
    ...overrides,
  }
}

function event(holds: Hold[]): HoldsEvent {
  return { type: 'holds.changed', holds }
}

describe('applyHoldsEvent', () => {
  it('keeps the current array reference for an equivalent snapshot', () => {
    const current = [hold({})]
    expect(applyHoldsEvent(current, event([hold({})]))).toBe(current)
  })

  it('replaces on any change, including detail under the same identity', () => {
    const current = [hold({ kind: 'ledger-gated', detail: '2 blocking findings…' })]
    const next = [hold({ kind: 'ledger-gated', detail: '1 blocking finding…' })]
    expect(applyHoldsEvent(current, event(next))).toBe(next)
  })

  it('replaces when the set shrinks to empty', () => {
    const current = [hold({})]
    const next: Hold[] = []
    expect(applyHoldsEvent(current, event(next))).toBe(next)
  })
})

describe('countActionable', () => {
  it('counts decision holds only', () => {
    const holds = [
      hold({ id: '1'.repeat(64), actionable: true }),
      hold({ id: '2'.repeat(64), kind: 'milestone-failed', actionable: false }),
      hold({ id: '3'.repeat(64), kind: 'approval-waiting', actionable: true }),
    ]
    expect(countActionable(holds)).toBe(2)
  })
})
