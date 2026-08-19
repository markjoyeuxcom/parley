import { describe, expect, it } from 'vitest'
import { forgetSelection, paneSelection, registerTerm, rememberSelection, relayState } from './termSelection'

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

describe('the last selection survives losing the highlight', () => {
  const term = (selection: string) => ({
    getSelection: () => selection,
    serialize: () => '',
    findNext: () => false,
    findPrevious: () => false,
    clearSearch: () => {},
  })

  it('keeps what was selected after the highlight goes', () => {
    // Selecting in a mouse-capturing CLI needs ⌥ held, and letting go of ⌥
    // drops the highlight — the text is gone from getSelection() before the
    // menu is even open. What somebody selected is not unselected by their
    // hand leaving the keyboard.
    registerTerm('p1', term(''))
    rememberSelection('p1', 'function add(a, b) {\n  return a + b\n}')
    expect(paneSelection('p1')).toBe('function add(a, b) {\n  return a + b\n}')
  })

  it('prefers a live selection over the remembered one', () => {
    registerTerm('p2', term('what is selected now'))
    rememberSelection('p2', 'what was selected before')
    expect(paneSelection('p2')).toBe('what is selected now')
  })

  it('never remembers whitespace, which a stray click produces', () => {
    registerTerm('p3', term(''))
    rememberSelection('p3', '   \n ')
    expect(paneSelection('p3')).toBe('')
  })

  it('forgets when the pane goes', () => {
    registerTerm('p4', term(''))
    rememberSelection('p4', 'something')
    forgetSelection('p4')
    expect(paneSelection('p4')).toBe('')
  })
})
