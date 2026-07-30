import { describe, expect, it } from 'vitest'
import { eligibleVendors, isToolless, pickCounterpart, seatingRefusals } from './vendors'

describe('vendor governance', () => {
  it('marks only Agy as tool-less', () => {
    expect(isToolless('claude')).toBe(false)
    expect(isToolless('codex')).toBe(false)
    expect(isToolless('agy')).toBe(true)
  })

  it('never picks a tool-less counterpart', () => {
    expect(pickCounterpart('claude')).toBe('codex')
    expect(pickCounterpart('codex')).toBe('claude')
    expect(pickCounterpart('agy')).toBe('claude')
    expect(pickCounterpart('claude', (vendor) => vendor !== 'claude')).toBe('claude')
    expect(() => pickCounterpart('agy', () => true)).toThrow(/no tool-capable vendor/)
  })

  it('admits Agy only to a tool-free debate seat', () => {
    expect(
      seatingRefusals([{ vendor: 'agy', role: 'debate-seat', toolFree: true }]),
    ).toEqual([])
    expect(
      seatingRefusals([{ vendor: 'agy', role: 'debate-seat', toolFree: false }]),
    ).toEqual([expect.stringContaining('tool-free debate seat')])

    for (const role of [
      'review-seat',
      'planner',
      'executor',
      'reviewer',
      'loop-worker',
      'loop-verifier',
      'foreman',
    ] as const) {
      expect(seatingRefusals([{ vendor: 'agy', role, toolFree: true }])).toEqual([
        expect.stringContaining(role.replaceAll('-', ' ')),
      ])
    }
  })

  it('offers exactly the vendors the role-aware refusal policy admits', () => {
    expect(eligibleVendors('debate-seat', true)).toEqual(['claude', 'codex', 'agy'])
    expect(eligibleVendors('debate-seat', false)).toEqual(['claude', 'codex'])
    expect(eligibleVendors('review-seat', true)).toEqual(['claude', 'codex'])
    expect(eligibleVendors('loop-worker', true)).toEqual(['claude', 'codex'])
  })

  it('does not refuse tool-capable vendors in any role', () => {
    expect(
      seatingRefusals([
        { vendor: 'claude', role: 'executor', toolFree: false },
        { vendor: 'codex', role: 'foreman', toolFree: false },
      ]),
    ).toEqual([])
  })
})
