import { describe, expect, it } from 'vitest'
import { cleanRelayText } from './relayText'

describe('cleaning what a TUI drew before relaying it', () => {
  it('takes the frame off a boxed reply', () => {
    // Claude Code draws its output inside a box. Dragging a selection across
    // it — or reading the buffer back — picks up the borders, and relaying
    // "│ Welcome back Mark! │" into another CLI is noise pretending to be a
    // message.
    expect(cleanRelayText([
      '╭──────────────────────────────╮',
      '│ Tips for getting started     │',
      '│ Run /init to create a file   │',
      '╰──────────────────────────────╯',
    ])).toBe('Tips for getting started\nRun /init to create a file')
  })

  it('keeps indentation inside the frame, because code depends on it', () => {
    expect(cleanRelayText([
      '│ function add(a, b) {   │',
      '│   return a + b         │',
      '│ }                      │',
    ])).toBe('function add(a, b) {\n  return a + b\n}')
  })

  it('drops blank space at both ends and collapses the gaps', () => {
    expect(cleanRelayText(['', '  ', 'first', '', '', '', 'second', '   ', ''])).toBe('first\n\nsecond')
  })

  it('unwraps a titled border, which is a heading wearing a frame', () => {
    expect(cleanRelayText(['╭─── Claude Code v2.1.236 ─────╮'])).toBe('Claude Code v2.1.236')
    expect(cleanRelayText(['├──── Findings ────┤'])).toBe('Findings')
  })

  it('never touches ASCII dashes, because those are diffs and prose', () => {
    // `─` is U+2500 and only a terminal draws it. `-` is what every diff
    // header, front-matter fence and command flag is made of, and eating those
    // would corrupt the most valuable thing the relay carries.
    expect(cleanRelayText(['--- a/src/main.ts', '+++ b/src/main.ts', '--verbose']))
      .toBe('--- a/src/main.ts\n+++ b/src/main.ts\n--verbose')
    expect(cleanRelayText(['---'])).toBe('---')
  })

  it('leaves ordinary output completely alone', () => {
    expect(cleanRelayText(['npm test', '  3 passing', '  1 failing'])).toBe('npm test\n  3 passing\n  1 failing')
  })

  it('keeps the END when there is too much, because the answer is the last thing', () => {
    const many = Array.from({ length: 5_000 }, (_, i) => `line ${i}`)
    const out = cleanRelayText(many, 200)
    expect(out.length).toBeLessThanOrEqual(200)
    expect(out).toContain('line 4999')
    expect(out).not.toContain('line 0\n')
  })

  it('is empty when the pane drew nothing but its own furniture', () => {
    expect(cleanRelayText(['╭────╮', '│    │', '╰────╯'])).toBe('')
    expect(cleanRelayText([])).toBe('')
  })
})
