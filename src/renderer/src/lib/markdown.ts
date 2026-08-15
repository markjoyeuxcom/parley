/**
 * Just enough Markdown to read a room transcript.
 *
 * Hand-written rather than a dependency, for two reasons that are not
 * "avoid dependencies". First, the output is a tree of plain data that the
 * pane turns into React elements — there is no HTML string anywhere, so the
 * whole injection class this normally opens is closed by construction, and
 * model output is untrusted text by definition. Second, a full CommonMark
 * implementation brings tables, footnotes, reference links and HTML
 * passthrough, none of which a conversation needs and all of which would need
 * styling in a hand-written design system.
 *
 * What it reads: ATX headings, fenced code, bullet and numbered lists, and
 * inline bold, italic and code. Everything else is text, deliberately.
 *
 * The rule that shapes the whole parser: **an unfinished marker is literal
 * text.** A reply is parsed on every delta, so half of every emphasis marker
 * and most fences are unterminated for a moment on their way in. A parser
 * that speculated would make the transcript flicker between readings; this one
 * shows exactly what has arrived.
 */

export interface TextSpan {
  kind: 'text' | 'strong' | 'em' | 'code'
  text: string
}

export type MarkdownBlock =
  | { kind: 'heading'; level: number; spans: TextSpan[] }
  | { kind: 'paragraph'; spans: TextSpan[] }
  | { kind: 'list'; ordered: boolean; items: TextSpan[][] }
  | { kind: 'code'; lang: string; text: string }

const HEADING = /^(#{1,6})\s+(.*)$/
const BULLET = /^[-*]\s+(.*)$/
const NUMBERED = /^\d+[.)]\s+(.*)$/
const FENCE = /^```(.*)$/

/**
 * Inline markers, longest first.
 *
 * Code is matched before emphasis and its content is never re-scanned, so a
 * span holding the parser's own markers (`**kwargs`) survives intact — the
 * single most likely way a hand-written renderer eats somebody's source.
 */
const INLINE: ReadonlyArray<{ open: string; kind: TextSpan['kind'] }> = [
  { open: '`', kind: 'code' },
  { open: '**', kind: 'strong' },
  { open: '*', kind: 'em' },
]

function pushText(spans: TextSpan[], text: string): void {
  if (!text) return
  const last = spans[spans.length - 1]
  // Merge, so literal-marker fallbacks do not leave the caller a shredded
  // list of one-character spans to render.
  if (last?.kind === 'text') last.text += text
  else spans.push({ kind: 'text', text })
}

export function parseInline(text: string): TextSpan[] {
  const spans: TextSpan[] = []
  let at = 0

  while (at < text.length) {
    const marker = INLINE.find((m) => text.startsWith(m.open, at))
    if (!marker) {
      pushText(spans, text[at] as string)
      at += 1
      continue
    }

    const from = at + marker.open.length
    const close = text.indexOf(marker.open, from)
    // An emphasis marker followed by a space opens nothing — CommonMark's
    // left-flanking rule, reduced to the case that actually shows up: prose
    // doing arithmetic ("2 * 3 and 4 * 5") must not turn into italics.
    // Code spans are exempt: `a * b` is a perfectly ordinary code span.
    const opensEmphasis = marker.kind === 'code' || !/\s/.test(text[from] ?? '')
    // Unterminated, or empty (`**`): the marker is text. This is the branch a
    // streaming reply takes constantly.
    if (close === -1 || close === from || !opensEmphasis) {
      pushText(spans, marker.open)
      at += marker.open.length
      continue
    }

    spans.push({ kind: marker.kind, text: text.slice(from, close) })
    at = close + marker.open.length
  }

  return spans
}

export function parseMarkdown(source: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = []
  const lines = source.split('\n')

  let paragraph: string[] = []
  let list: { ordered: boolean; items: string[] } | null = null

  const flushParagraph = (): void => {
    const text = paragraph.join('\n').trim()
    paragraph = []
    if (text) blocks.push({ kind: 'paragraph', spans: parseInline(text) })
  }
  const flushList = (): void => {
    if (!list) return
    blocks.push({
      kind: 'list',
      ordered: list.ordered,
      items: list.items.map((item) => parseInline(item)),
    })
    list = null
  }
  const flush = (): void => {
    flushParagraph()
    flushList()
  }

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i] as string

    const fence = FENCE.exec(line)
    if (fence) {
      flush()
      const lang = (fence[1] ?? '').trim()
      const body: string[] = []
      i += 1
      while (i < lines.length && !FENCE.test(lines[i] as string)) {
        body.push(lines[i] as string)
        i += 1
      }
      // Falling off the end closes the block anyway: mid-stream this is the
      // normal case, and dropping it would blank the screen exactly when the
      // most text is arriving.
      blocks.push({ kind: 'code', lang, text: body.join('\n') })
      continue
    }

    const heading = HEADING.exec(line)
    if (heading) {
      flush()
      blocks.push({
        kind: 'heading',
        level: (heading[1] as string).length,
        spans: parseInline((heading[2] as string).trim()),
      })
      continue
    }

    const bullet = BULLET.exec(line)
    const numbered = NUMBERED.exec(line)
    if (bullet || numbered) {
      flushParagraph()
      const ordered = !bullet
      const item = (bullet?.[1] ?? numbered?.[1] ?? '').trim()
      if (list && list.ordered !== ordered) flushList()
      if (!list) list = { ordered, items: [] }
      list.items.push(item)
      continue
    }

    if (!line.trim()) {
      flush()
      continue
    }

    flushList()
    paragraph.push(line)
  }

  flush()
  return blocks
}
