import { describe, expect, it } from 'vitest'
import { isToolless, pickCounterpart, seatingRefusals } from './vendors'

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

  it('does not refuse tool-capable vendors in any role', () => {
    expect(
      seatingRefusals([
        { vendor: 'claude', role: 'executor', toolFree: false },
        { vendor: 'codex', role: 'foreman', toolFree: false },
      ]),
    ).toEqual([])
  })
})
