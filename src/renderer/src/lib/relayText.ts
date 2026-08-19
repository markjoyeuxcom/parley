/**
 * What a CLI drew, turned back into something worth sending another CLI.
 *
 * A terminal's buffer is a picture, not a document. Claude Code draws its
 * answers inside a box; codex and agy draw rules and gutters. Relaying that
 * verbatim puts `│ Welcome back Mark! │` into the other CLI's prompt — noise
 * pretending to be a message, and the receiving model has to guess which
 * characters were the point.
 *
 * So the frame comes off and the text stays. Deliberately conservative: only
 * characters that can ONLY be furniture are removed, and indentation inside
 * the frame survives untouched, because relaying code is most of the point and
 * two leading spaces are load-bearing there.
 */

/** Vertical rules a TUI uses as a left or right edge. */
const EDGE = /^[│┃┆┇┊┋║|]\s?|\s?[│┃┆┇┊┋║|]$/g

/**
 * The decoration around a titled border — `╭─── Findings ───╮`.
 *
 * Only the box-drawing block, never ASCII. `─` is U+2500 and nothing but a
 * terminal draws it; `-` is what every diff header, fence and command flag is
 * made of, and eating those would corrupt the most valuable thing the relay
 * carries.
 */
const TITLE_FRAME = /^[\s╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬─━═╌╍┄┅┈┉]+|[\s╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬─━═╌╍┄┅┈┉]+$/g

/** A line that is only a horizontal rule, corner or junction. */
const RULE = /^[\s─━═╌╍┄┅┈┉╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬<>v^]*$/

const DEFAULT_MAX = 40_000

export function cleanRelayText(lines: readonly string[], maxChars = DEFAULT_MAX): string {
  const stripped: string[] = []
  for (const raw of lines) {
    // Right edge first: trailing padding inside the box is not indentation.
    const withoutEdges = raw.replace(/\s+$/, '').replace(EDGE, '')
    if (RULE.test(withoutEdges)) {
      // A rule is a blank line's worth of separation, not a line of content.
      stripped.push('')
      continue
    }
    // A border with a title in it is a heading wearing a frame. Only unwrapped
    // when the line actually carries box-drawing characters, so indentation on
    // an ordinary line is never mistaken for decoration.
    const titled = /[╭╮╰╯┌┐└┘├┤┬┴┼╔╗╚╝╠╣╦╩╬─━═╌╍┄┅┈┉]/.test(withoutEdges)
      ? withoutEdges.replace(TITLE_FRAME, '')
      : withoutEdges
    stripped.push(titled.replace(/\s+$/, ''))
  }

  const out: string[] = []
  for (const line of stripped) {
    // Three blank lines say nothing the first one did not.
    if (!line.trim() && !out.at(-1)?.trim() && out.length > 0) continue
    out.push(line)
  }
  while (out.length && !out[0]?.trim()) out.shift()
  while (out.length && !out.at(-1)?.trim()) out.pop()

  const text = out.join('\n')
  if (text.length <= maxChars) return text
  // Keep the END. The answer is the last thing said, and a relay that carried
  // the first 40 KB of a long session would carry everything except it.
  return text.slice(text.length - maxChars).replace(/^[^\n]*\n/, '')
}
