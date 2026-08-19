import { describe, expect, it } from 'vitest'
import { canReceiveRelay, forgetSelection, paneSelection, registerTerm, rememberSelection, relayState } from './termSelection'

describe('relay state', () => {
  it('sends the selection when there is one', () => {
    // Choosing text is somebody saying "this part". Sending the whole answer
    // instead would be overriding them.
    expect(relayState({ targets: 2, selection: 'const x = 1', lastOutput: 'the whole reply' }))
      .toBe('selection')
  })

  it('falls back to the last output, which is what they almost certainly mean', () => {
    expect(relayState({ targets: 1, selection: '', lastOutput: 'the whole reply' })).toBe('output')
  })

  it('says so when there is nowhere to send', () => {
    expect(relayState({ targets: 0, selection: 'anything', lastOutput: 'anything' })).toBe('no-targets')
  })

  it('treats whitespace as nothing, on both paths', () => {
    // A stray click leaves an empty selection, and a pane that has only drawn
    // its own furniture leaves empty output. Relaying either would paste a
    // blank line into another CLI and press Enter.
    expect(relayState({ targets: 1, selection: '   \n  ', lastOutput: '  ' })).toBe('nothing')
    expect(relayState({ targets: 1, selection: '', lastOutput: '' })).toBe('nothing')
  })
})

describe('the last selection survives losing the highlight', () => {
  const term = (selection: string) => ({
    getSelection: () => selection,
    lastOutput: () => '',
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

describe('who can receive a relay', () => {
  it('takes a live agent pane', () => {
    expect(canReceiveRelay('claude', 'live')).toBe(true)
    expect(canReceiveRelay('codex', undefined)).toBe(true)
  })

  it('refuses a pane that is still booting', () => {
    // A paste during a CLI's startup splash, before raw mode, is swallowed —
    // and the relay would report success over a message never received.
    expect(canReceiveRelay('codex', 'starting')).toBe(false)
  })

  it('refuses a dead pane, a shell and a room', () => {
    expect(canReceiveRelay('claude', 'exited')).toBe(false)
    expect(canReceiveRelay('shell', 'live')).toBe(false)
    expect(canReceiveRelay('room', 'live')).toBe(false)
  })
})
