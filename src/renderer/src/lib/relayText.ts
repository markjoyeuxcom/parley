/**
 * What a CLI drew, turned back into something worth sending another CLI.
 *
 * A terminal's buffer is a picture, not a document. Claude Code draws its
 * answers inside a box; codex and agy draw rules and gutters. Relaying that
 * verbatim puts `│ Welcome back Mark! │` into the other CLI's prompt — noise
 * pretending to be a message, and the receiving model has to guess which
 * characters were the point.
 *
 * So the frame comes off and the text stays. The bias is heavily towards
 * leaving things alone: anything that could plausibly be content is content.
 *
 * The first version was not careful enough, and Codex — reviewing this file
 * through the relay itself — found four ways it corrupted real output: ASCII
 * table pipes read as box edges, indentation eaten from any line that merely
 * contained a `─`, code fences reflowed, and a bare `>>>>>>>` conflict marker
 * deleted as a rule. Every one of those is the relay damaging exactly what it
 * exists to carry, which is worse than relaying a stray `│`.
 */

/**
 * The vertical rules a TUI uses as a left and right edge.
 *
 * Box-drawing block only. ASCII `|` is a markdown table column, a shell pipe
 * and a regex alternation — treating it as furniture turned every relayed
 * table into prose.
 *
 * BOTH ends are required, which is what tells a box from its lookalikes. A
 * leading `│` alone is far more often content: the connector in a directory
 * tree, or a glyph inside a code block. A box is closed.
 */
const EDGE_LEAD = /^[│┃┆┇┊┋║]\s?/
const EDGE_TAIL = /\s*[│┃┆┇┊┋║]$/

function unbox(line: string): string {
  const trimmed = line.replace(/\s+$/, '')
  return EDGE_LEAD.test(trimmed) && EDGE_TAIL.test(trimmed)
    ? trimmed.replace(EDGE_LEAD, '').replace(EDGE_TAIL, '').replace(/\s+$/, '')
    : trimmed
}

/** Box-drawing characters, and nothing else. `─` is U+2500; `-` is not. */
const BOX = '─━═╌╍┄┅┈┉╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬│┃┆┇┊┋║'

/**
 * A line that is only furniture.
 *
 * `<`, `>`, `v` and `^` were once in here as TUI arrows. A bare `>>>>>>>` is
 * made of nothing else, and silently deleting a conflict marker changes what a
 * diff says.
 */
const RULE = new RegExp(`^[\\s${BOX}]*$`)

/**
 * The decoration wrapped around a titled border — `╭─── Findings ───╮`.
 *
 * Both ends are required. `├` and `└` are box-drawing too, and matching a
 * leading run alone ate the branch off every `├── src/` in a directory tree —
 * one of the most ordinary things anybody relays. A border is closed; a tree
 * branch is not.
 */
const TITLE_LEAD = new RegExp(`^[${BOX}]+\\s*`)
const TITLE_TAIL = new RegExp(`\\s*[${BOX}]+$`)

const FENCE = /^\s*(?:```|~~~)/

const DEFAULT_MAX = 40_000

export function cleanRelayText(lines: readonly string[], maxChars = DEFAULT_MAX): string {
  const stripped: string[] = []
  let fenced = false
  // Whether the fence we are inside was itself drawn in a box. If it was, its
  // contents are boxed too and the edges come off; if it was not, a `│` on a
  // line inside it is a character somebody typed.
  let fenceBoxed = false

  for (const raw of lines) {
    // Edges come off BEFORE the fence is looked for. A TUI draws code blocks
    // inside its own box, so the fence arrives as `│ ```ts │` and a check
    // against the raw line never matched — the protection never applied
    // anywhere it was actually needed.
    const bare = unbox(raw)
    if (FENCE.test(bare)) {
      if (!fenced) fenceBoxed = bare !== raw.replace(/\s+$/, '')
      fenced = !fenced
      stripped.push(bare)
      continue
    }
    // Inside a fence every character is content: a blank line is structure and
    // indentation is meaning. Only the box around it, if there was one, goes.
    if (fenced) {
      stripped.push(fenceBoxed ? bare : raw.replace(/\s+$/, ''))
      continue
    }

    // Trailing spaces go first, and deliberately. They are the padding a cell
    // grid produces, and by the time text reaches a buffer an authored
    // markdown hard break is indistinguishable from a hundred columns of
    // filler — leaking the filler into another CLI's prompt is the worse of
    // the two mistakes.
    const withoutEdges = bare
    if (RULE.test(withoutEdges)) {
      // A rule is a blank line's worth of separation, not a line of content.
      stripped.push('')
      continue
    }
    // A border with a title in it is a heading wearing a frame — but only when
    // the line BEGINS with box-drawing, so `    const rule = "─"` keeps the
    // indentation that makes it code.
    // Closed at BOTH ends or it is not a border.
    const titled = TITLE_LEAD.test(withoutEdges) && TITLE_TAIL.test(withoutEdges)
      ? withoutEdges.replace(TITLE_LEAD, '').replace(TITLE_TAIL, '')
      : withoutEdges
    stripped.push(titled.replace(/\s+$/, ''))
  }

  const out: string[] = []
  let inFence = false
  for (const line of stripped) {
    if (FENCE.test(line)) inFence = !inFence
    // Three blank lines say nothing the first one did not — outside a fence,
    // where a run of them may be the shape of the code.
    if (!inFence && !line.trim() && !out.at(-1)?.trim() && out.length > 0) continue
    out.push(line)
  }
  while (out.length && !out[0]?.trim()) out.shift()
  while (out.length && !out.at(-1)?.trim()) out.pop()

  return trimToEnd(out.join('\n'), maxChars)
}

/**
 * The last `maxChars`, cut at a line boundary and never mid-character.
 *
 * Keeps the END: the answer is the last thing said, and a relay carrying the
 * first 40 KB of a long session would carry everything except it.
 */
function trimToEnd(text: string, maxChars: number): string {
  if (text.length <= maxChars) return text
  let at = text.length - maxChars

  // Never start inside a surrogate pair. Half of one is an ill-formed string
  // that renders as a replacement character wherever it lands.
  if (at > 0 && /[\uD800-\uDBFF]/.test(text[at - 1] as string)) at += 1

  const window = text.slice(at)
  // A cut landing just after a newline already begins a whole line; advancing
  // to the next one would discard a complete line for nothing.
  if (at === 0 || text[at - 1] === '\n') return window
  const nextLine = window.indexOf('\n')
  // No boundary in the window at all: it is one partial line, and relaying
  // half a line as though it were whole misrepresents what was said.
  return nextLine === -1 ? '' : window.slice(nextLine + 1)
}
