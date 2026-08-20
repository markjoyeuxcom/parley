import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * Structural checks on the stylesheets themselves.
 *
 * These exist because a CSS mistake is invisible to everything else here. The
 * typechecker does not read CSS, no unit test renders with real styles, and a
 * class declared twice does not warn — the browser simply merges both rules
 * onto every element carrying the name.
 *
 * That is not hypothetical. `.room__body` named two unrelated elements: the
 * scroll wrapper around a transcript, and the rendered markdown of one turn.
 * The wrapper's `display: flex` therefore applied to the markdown too, so
 * every paragraph, heading and list became a flex item in a row, and an
 * agent's reply rendered as forty narrow vertical strips. Nothing failed. It
 * shipped, and was found by looking at it.
 */

const STYLES = join(__dirname)

function sheets(): Array<{ name: string; text: string }> {
  return readdirSync(STYLES)
    .filter((file) => file.endsWith('.css'))
    .map((name) => ({ name, text: readFileSync(join(STYLES, name), 'utf8') }))
}

/** Top-level `.thing {` rules, with comments removed so examples do not count. */
function bareClassSelectors(css: string): string[] {
  const withoutComments = css.replace(/\/\*[\s\S]*?\*\//g, '')
  return [...withoutComments.matchAll(/^(\.[A-Za-z0-9_-]+)\s*\{/gm)].map((m) => m[1] as string)
}

describe('no class is declared twice', () => {
  for (const { name, text } of sheets()) {
    it(`${name} declares each bare class selector once`, () => {
      const seen = new Map<string, number>()
      for (const selector of bareClassSelectors(text)) {
        seen.set(selector, (seen.get(selector) ?? 0) + 1)
      }
      const duplicated = [...seen.entries()]
        .filter(([, count]) => count > 1)
        .map(([selector, count]) => `${selector} (${count}×)`)

      // If a duplicate is deliberate, merge the two rules instead of adding an
      // exception: two rules for one selector is the same thing written twice,
      // and two elements sharing a selector is the bug above.
      expect(duplicated).toEqual([])
    })
  }
})

describe('the stylesheets parse as balanced', () => {
  for (const { name, text } of sheets()) {
    it(`${name} has matching braces`, () => {
      const withoutComments = text.replace(/\/\*[\s\S]*?\*\//g, '')
      const open = (withoutComments.match(/\{/g) ?? []).length
      const close = (withoutComments.match(/\}/g) ?? []).length
      // An unclosed rule swallows everything after it, which reads as "the
      // last half of the stylesheet stopped working".
      expect({ file: name, open, close }).toEqual({ file: name, open, close: open })
    })
  }
})
