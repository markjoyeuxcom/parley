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

  it('never touches ASCII pipes, because those are markdown tables', () => {
    // Found by Codex, reviewing this file through the relay. The EDGE class
    // included ASCII `|` — so every markdown table relayed between two CLIs
    // lost its columns and became prose, while the commit message claimed
    // ASCII was never touched.
    expect(cleanRelayText(['| value |', '| --- |', '| `x` |']))
      .toBe('| value |\n| --- |\n| `x` |')
  })

  it('keeps indentation on a line that merely contains a box glyph', () => {
    // TITLE_FRAME had \s in its class, so any line holding a `─` anywhere had
    // its leading whitespace eaten — which is exactly the code the relay is
    // most often carrying.
    expect(cleanRelayText(['```ts', '    const rule = "─"', '```']))
      .toBe('```ts\n    const rule = "─"\n```')
  })

  it('leaves everything inside a code fence exactly as it was', () => {
    // Inside a fence a `│` is content, and a blank line is structure.
    expect(cleanRelayText(['```text', '│ literal', '', '', 'still code', '```']))
      .toBe('```text\n│ literal\n\n\nstill code\n```')
  })

  it('does not mistake a conflict marker for a rule', () => {
    // `>` and `v` were in the rule class as TUI arrows. A bare conflict marker
    // is made of nothing else, and losing it silently changes what a diff says.
    expect(cleanRelayText(['<<<<<<< HEAD', 'ours', '=======', 'theirs', '>>>>>>>']))
      .toBe('<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>>')
  })

  it('keeps a whole first line when the cut lands exactly on a boundary', () => {
    expect(cleanRelayText(['abc', 'def', 'ghi'], 7)).toBe('def\nghi')
  })

  it('never splits a surrogate pair', () => {
    const out = cleanRelayText(['A\u{1F44D}B'], 3)
    expect(out).not.toMatch(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])/)
    expect(out).not.toMatch(/(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/)
  })

  it('keeps a directory tree, which is branches not borders', () => {
    // Found by Gemini. `├` and `└` are box-drawing, so TITLE_LEAD ate the
    // branch off every `├── src/` — and a tree is one of the most ordinary
    // things anybody relays.
    expect(cleanRelayText(['├── src/', '│   └── main.ts', '└── package.json']))
      .toBe('├── src/\n│   └── main.ts\n└── package.json')
  })

  it('still unwraps a real titled border, which is closed at both ends', () => {
    expect(cleanRelayText(['╭─── Findings ───╮'])).toBe('Findings')
    expect(cleanRelayText(['├──── Findings ────┤'])).toBe('Findings')
  })

  it('finds a code fence drawn inside a box', () => {
    // The fence test ran on the raw line, so `│ ```ts │` never matched and the
    // protection never applied where TUI output actually puts code.
    expect(cleanRelayText([
      '│ ```ts       │',
      '│ ──────      │',
      '│     x = 1   │',
      '│ ```         │',
    ])).toBe('```ts\n──────\n    x = 1\n```')
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
