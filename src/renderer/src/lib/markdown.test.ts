import { describe, expect, it } from 'vitest'
import { parseMarkdown } from './markdown'

/**
 * The room transcript's reader.
 *
 * Small on purpose, and tested hard on the cases that make a hand-written
 * parser embarrassing: markers inside code, markers that never close, and a
 * fence that runs off the end of a streaming reply.
 */

describe('markdown', () => {
  it('reads headings by level, and only at the start of a line', () => {
    expect(parseMarkdown('## Where the app is')).toEqual([
      { kind: 'heading', level: 2, spans: [{ kind: 'text', text: 'Where the app is' }] },
    ])
    // A hash mid-sentence is a hash, not a heading.
    expect(parseMarkdown('issue #63 is open')[0]).toMatchObject({ kind: 'paragraph' })
  })

  it('reads bold and inline code inside a paragraph', () => {
    expect(parseMarkdown('**Prax v0.20.0** — a local-first app')).toEqual([
      {
        kind: 'paragraph',
        spans: [
          { kind: 'strong', text: 'Prax v0.20.0' },
          { kind: 'text', text: ' — a local-first app' },
        ],
      },
    ])
    expect(parseMarkdown('see `docs/ROADMAP.md` first')[0]).toMatchObject({
      spans: [
        { kind: 'text', text: 'see ' },
        { kind: 'code', text: 'docs/ROADMAP.md' },
        { kind: 'text', text: ' first' },
      ],
    })
  })

  it('never looks for emphasis inside inline code', () => {
    // The failure that makes a naive renderer eat source text: a code span
    // holding the very characters the parser is hunting for.
    expect(parseMarkdown('use `**kwargs` and `a * b`')[0]).toMatchObject({
      spans: [
        { kind: 'text', text: 'use ' },
        { kind: 'code', text: '**kwargs' },
        { kind: 'text', text: ' and ' },
        { kind: 'code', text: 'a * b' },
      ],
    })
  })

  it('leaves an unclosed marker as the literal text it is', () => {
    // Mid-stream, half a bold marker is on screen constantly. It must read as
    // asterisks rather than swallowing the rest of the reply into a <strong>.
    expect(parseMarkdown('a ** dangling')[0]).toMatchObject({
      spans: [{ kind: 'text', text: 'a ** dangling' }],
    })
    expect(parseMarkdown('a ` dangling')[0]).toMatchObject({
      spans: [{ kind: 'text', text: 'a ` dangling' }],
    })
  })

  it('does not italicise arithmetic', () => {
    // An asterisk followed by a space opens nothing, so prose that multiplies
    // stays prose. A code span is exempt — `a * b` is ordinary code.
    expect(parseMarkdown('2 * 3 and 4 * 5')[0]).toMatchObject({
      spans: [{ kind: 'text', text: '2 * 3 and 4 * 5' }],
    })
    expect(parseMarkdown('`a * b` holds')[0]).toMatchObject({
      spans: [{ kind: 'code', text: 'a * b' }, { kind: 'text', text: ' holds' }],
    })
  })

  it('reads bullet and numbered lists, with inline markup inside items', () => {
    const blocks = parseMarkdown('- **Feature waves:** calendar sync\n- A quality program')
    expect(blocks).toHaveLength(1)
    expect(blocks[0]).toMatchObject({ kind: 'list', ordered: false })
    const list = blocks[0] as { items: unknown[] }
    expect(list.items).toHaveLength(2)
    expect(list.items[0]).toMatchObject([
      { kind: 'strong', text: 'Feature waves:' },
      { kind: 'text', text: ' calendar sync' },
    ])

    expect(parseMarkdown('1. first\n2. second')[0]).toMatchObject({
      kind: 'list',
      ordered: true,
    })
  })

  it('keeps a fenced block verbatim, markers and blank lines included', () => {
    const blocks = parseMarkdown('before\n```bash\nnpm run **verify**\n\nnpm test\n```\nafter')
    expect(blocks).toHaveLength(3)
    expect(blocks[1]).toEqual({
      kind: 'code',
      lang: 'bash',
      text: 'npm run **verify**\n\nnpm test',
    })
    expect(blocks[2]).toMatchObject({ kind: 'paragraph' })
  })

  it('closes an unterminated fence at the end rather than dropping it', () => {
    // Exactly what a half-streamed reply looks like. Losing it would blank
    // the screen at the moment the most is arriving.
    expect(parseMarkdown('```\nnpm run dev')).toEqual([
      { kind: 'code', lang: '', text: 'npm run dev' },
    ])
  })

  it('splits paragraphs on blank lines and keeps soft line breaks', () => {
    const blocks = parseMarkdown('one\ntwo\n\nthree')
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toMatchObject({ spans: [{ kind: 'text', text: 'one\ntwo' }] })
    expect(blocks[1]).toMatchObject({ spans: [{ kind: 'text', text: 'three' }] })
  })

  it('returns nothing for empty or whitespace-only text', () => {
    expect(parseMarkdown('')).toEqual([])
    expect(parseMarkdown('   \n\n  ')).toEqual([])
  })
})
