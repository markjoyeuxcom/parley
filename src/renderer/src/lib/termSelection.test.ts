import { describe, expect, it } from 'vitest'
import { relayState } from './termSelection'

describe('relay state', () => {
  it('is ready once there is a selection and somewhere to send it', () => {
    expect(relayState({ targets: 2, selection: 'const x = 1' })).toBe('ready')
  })

  it('says so when there is nowhere to send', () => {
    expect(relayState({ targets: 0, selection: 'anything' })).toBe('no-targets')
  })

  it('treats whitespace as nothing selected', () => {
    // A stray click leaves an empty selection, and offering to relay it would
    // paste a blank line into another CLI and press Enter.
    expect(relayState({ targets: 1, selection: '   \n  ' })).toBe('needs-selection')
    expect(relayState({ targets: 1, selection: '' })).toBe('needs-selection')
  })
})
