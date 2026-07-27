import { describe, expect, it } from 'vitest'
import { statusTone, verificationState } from './format'

describe('statusTone', () => {
  it('renders a blocked plan as caution rather than failure', () => {
    expect(statusTone('blocked')).toEqual({ tone: 'chip--caution', label: 'blocked' })
  })
})

describe('verificationState', () => {
  const base = { exitCode: 0, signal: null as string | null, timedOut: false }

  it('reads a clean run as passed', () => {
    expect(verificationState(base)).toMatchObject({ label: 'passed', verified: true })
  })

  it('reads a non-zero exit as a real disagreement, not a crash', () => {
    const state = verificationState({ ...base, exitCode: 1 })
    expect(state.label).toBe('failed (exit 1)')
    expect(state.verified).toBe(true)
    expect(state.detail).toMatch(/ran and disagreed/)
  })

  it('reads a signal as a crash that verified nothing', () => {
    const state = verificationState({ ...base, exitCode: -1, signal: 'SIGSEGV' })
    expect(state.label).toBe('crashed (SIGSEGV)')
    expect(state.verified).toBe(false)
  })

  // The ordering trap: a timeout arrives as a SIGTERM, so checking `signal` first
  // would report every timeout as a crash and send the reader after the wrong bug.
  it('reads a timeout as a timeout even though it arrives as SIGTERM', () => {
    const state = verificationState({ exitCode: -1, signal: 'SIGTERM', timedOut: true })
    expect(state.label).toBe('timed out')
    expect(state.verified).toBe(false)
  })

  it('never marks a crash or timeout as verified, which would imply the suite ran', () => {
    for (const r of [
      { ...base, exitCode: -1, signal: 'SIGKILL' },
      { exitCode: -1, signal: 'SIGTERM', timedOut: true },
    ]) {
      expect(verificationState(r).verified).toBe(false)
    }
  })

  it('gives the four states four distinct tones or labels', () => {
    const labels = [
      verificationState(base).label,
      verificationState({ ...base, exitCode: 2 }).label,
      verificationState({ ...base, exitCode: -1, signal: 'SIGSEGV' }).label,
      verificationState({ exitCode: -1, signal: 'SIGTERM', timedOut: true }).label,
    ]
    expect(new Set(labels).size).toBe(4)
  })
})
