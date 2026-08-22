import { useEffect, useRef, type ReactNode } from 'react'
import { Terminal } from '@xterm/xterm'
import type { IMarker } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { SearchAddon } from '@xterm/addon-search'
import { SerializeAddon } from '@xterm/addon-serialize'
import { WebglAddon } from '@xterm/addon-webgl'
import type { Id } from '@shared/domain'
import { api } from '../lib/api'
import { attachPane } from '../lib/ptyBuffer'
import { forgetSelection, registerTerm, rememberSelection } from '../lib/termSelection'
import { cleanRelayText } from '../lib/relayText'

/**
 * Reads the xterm palette out of the app's own CSS custom properties.
 *
 * Keeping one source of truth means the terminal follows the light/dark toggle
 * without a second colour table to maintain.
 */
function themeFromTokens(): Record<string, string> {
  const style = getComputedStyle(document.documentElement)
  const token = (name: string, fallback: string): string => style.getPropertyValue(name).trim() || fallback

  const background = token('--bg-terminal', '#151516')
  const foreground = token('--text-primary', '#ededee')

  return {
    background,
    foreground,
    cursor: token('--accent', '#7a94ff'),
    cursorAccent: background,
    selectionBackground: token('--accent-soft', 'rgba(122,148,255,0.3)'),
    black: '#2a2a2d',
    red: '#f06b62',
    green: '#4cc38a',
    yellow: '#e2a336',
    blue: '#7ba3f5',
    magenta: '#c78ae0',
    cyan: '#5cc9d6',
    white: '#d4d4d8',
    brightBlack: '#6a6a73',
    brightRed: '#ff8e86',
    brightGreen: '#6fd7a4',
    brightYellow: '#f0bd5e',
    brightBlue: '#9dbaff',
    brightMagenta: '#dba7ef',
    brightCyan: '#7fdde8',
    brightWhite: '#f4f4f6',
  }
}

export function TerminalPane({
  paneId,
  focused,
  onFocus,
  onOutput,
}: {
  paneId: Id
  focused: boolean
  onFocus: () => void
  /** Fires per output chunk — the deterministic unread signal's source. */
  onOutput?: () => void
}): ReactNode {
  const hostRef = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  // A ref so a changing callback never tears the terminal down — the mount
  // effect must depend on paneId alone or scrollback dies with each render.
  const onOutputRef = useRef(onOutput)
  onOutputRef.current = onOutput

  useEffect(() => {
    const host = hostRef.current
    if (!host) return

    const term = new Terminal({
      fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--font-mono').trim() ||
        'ui-monospace, monospace',
      fontSize: 12,
      lineHeight: 1.35,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: 'bar',
      cursorWidth: 2,
      // Twelve thousand before. Scrollback is not just retained memory per
      // pane — xterm reflows the whole of it on every resize, and this app
      // resizes on window changes and on the grid's own column control. Three
      // thousand lines is still three times xterm's default and far more than
      // the relay's "send last answer" ever reaches back for.
      scrollback: 3_000,
      allowProposedApi: true,
      // macOS convention: ⌥+arrow moves by word in the shell.
      macOptionIsMeta: true,
      // ⌥+drag takes the selection back from a CLI that has claimed the mouse.
      // Claude Code draws clickable UI, so it turns mouse tracking on and
      // every drag goes to the application — it highlights the text itself,
      // which looks like a selection while xterm has none. Without this there
      // is no way to select in that pane at all, and the relay is dead there.
      macOptionClickForcesSelection: true,
      theme: themeFromTokens(),
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(host)

    // WebGL on, which is the opposite of what this said before.
    //
    // The old reasoning: the renderer died every ten minutes or so, batching
    // PTY output changed nothing (8-14 minutes before, 11.1 after), so
    // something must accumulate per rendered glyph — and WebGL was left off as
    // the suspect.
    //
    // It was pointing the wrong way. xterm.js is main-thread bound end to end,
    // and its maintainers put numbers on the split: parsing and VT emulation
    // 60-90% of the load, rendering 10-40% — where DOM is the ~40% end and
    // WebGL the ~10% one. Two terminals already halve the frame rate, four
    // quarter it (xtermjs/xterm.js#3368). An agent TUI full-redraws at
    // 46-384KB a frame against 1-5KB for incremental output, so three of them
    // saturate one thread and the backlog is what runs out of memory.
    //
    // Batching did nothing because the cost was never the messages; it was
    // parse plus render. This cannot fix the parse half — nothing here can,
    // short of leaving xterm — but the DOM renderer was the most expensive
    // option available and it was the one in use.
    //
    // VITE_PARLEY_WEBGL=0 goes back to the DOM renderer, which is how the two
    // get compared rather than argued about.
    if (import.meta.env.VITE_PARLEY_WEBGL !== '0') {
      try {
        const webgl = new WebglAddon()
        // A lost context leaves a blank pane otherwise. Disposing drops us
        // back to the DOM renderer, which is slow but visible.
        webgl.onContextLoss(() => webgl.dispose())
        term.loadAddon(webgl)
      } catch {
        /* DOM renderer it is. */
      }
    }

    termRef.current = term
    fitRef.current = fit

    const syncSize = (): void => {
      try {
        fit.fit()
        void api.resizePane(paneId, term.cols, term.rows)
      } catch {
        /* The pane may have gone; the exit handler covers it. */
      }
    }

    // Two frames: one for layout, one for fonts to have settled enough that the
    // measured cell size is right. Fitting too early yields an 80x24 default
    // that then has to be corrected visibly.
    requestAnimationFrame(() => requestAnimationFrame(syncSize))

    // Where the person's last question ended and the answer began.
    //
    // Marked on Enter rather than on every keystroke: typing a prompt would
    // otherwise walk the boundary forward character by character, and "the
    // last output" would end up meaning whatever arrived after the final
    // letter they typed. The marker tracks its line as the buffer scrolls and
    // reports -1 once it falls out of scrollback.
    let submitted: IMarker | undefined
    const markSubmitted = (): void => {
      submitted?.dispose()
      submitted = term.registerMarker(0)
      // A new question ends the old selection. Keeping it meant one stray
      // word chosen an hour ago outranked every answer since.
      forgetSelection(paneId)
    }
    const dataSub = term.onData((data) => {
      void api.writePane(paneId, data)
      if (data.includes('\r') || data.includes('\n')) markSubmitted()
    })

    // `done` is the whole point: xterm calls it once the chunk has actually
    // been parsed, which is the only signal that says whether this terminal is
    // keeping up. Without it the buffer could only guess, and it guessed by
    // writing everything immediately and growing until Chromium intervened.
    const detach = attachPane(paneId, (data, done) => {
      term.write(data, done)
      onOutputRef.current?.()
    })
    const search = new SearchAddon()
    term.loadAddon(search)
    const serialize = new SerializeAddon()
    term.loadAddon(serialize)
    // Recorded as it happens, not read when the menu opens. Releasing ⌥ drops
    // the highlight, and a live TUI redrawing over it does the same — by then
    // xterm reports nothing selected and the relay would have nothing to send.
    const selectionWatch = term.onSelectionChange(() => rememberSelection(paneId, term.getSelection()))

    const unregisterSelection = registerTerm(paneId, {
      getSelection: () => term.getSelection(),
      lastOutput: () => {
        const buffer = term.buffer.active
        // Without a boundary — nothing submitted yet this session, or it has
        // scrolled away — fall back to a bounded tail rather than the whole
        // scrollback, which can be twelve thousand lines.
        const from = submitted && submitted.line >= 0
          ? submitted.line + 1
          : Math.max(0, buffer.length - 300)
        // Stop at the cursor. Below it is the CLI's input line, and anything
        // half-typed there is a question being drafted — relaying somebody's
        // unfinished thought back out as part of the answer is not what they
        // asked for.
        const until = Math.min(buffer.length, buffer.baseY + buffer.cursorY)
        const lines: string[] = []
        for (let at = from; at < until; at += 1) {
          const line = buffer.getLine(at)
          if (!line) continue
          // A row that xterm marked wrapped is the SAME line continuing: the
          // break is the pane's width, not the text's. Joining them back means
          // a relayed command or sentence is not chopped at column 80.
          if (line.isWrapped && lines.length > 0) {
            lines[lines.length - 1] += line.translateToString(true)
            continue
          }
          lines.push(line.translateToString(true))
        }
        return cleanRelayText(lines)
      },
      // `pane.paste` enters through main rather than through xterm's keyboard
      // callback. The Ask/Return loop calls this after that prompt is accepted
      // so the next `lastOutput` is the counterpart's new answer only.
      markSubmitted,
      serialize: () => serialize.serialize(),
      findNext: (query) => search.findNext(query),
      findPrevious: (query) => search.findPrevious(query),
      clearSearch: () => search.clearDecorations(),
    })

    const observer = new ResizeObserver(() => syncSize())
    observer.observe(host)

    return () => {
      observer.disconnect()
      detach()
      unregisterSelection()
      submitted?.dispose()
      selectionWatch.dispose()
      dataSub.dispose()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
  }, [paneId])

  // Re-theme in place when the appearance changes, rather than rebuilding the
  // terminal and losing its scrollback.
  useEffect(() => {
    const root = document.documentElement
    const apply = (): void => {
      if (termRef.current) termRef.current.options.theme = themeFromTokens()
    }
    const observer = new MutationObserver(apply)
    observer.observe(root, { attributes: true, attributeFilter: ['data-theme'] })
    const media = window.matchMedia('(prefers-color-scheme: dark)')
    media.addEventListener('change', apply)
    return () => {
      observer.disconnect()
      media.removeEventListener('change', apply)
    }
  }, [])

  useEffect(() => {
    if (focused) termRef.current?.focus()
  }, [focused])

  return <div className="pane__term" ref={hostRef} onMouseDown={onFocus} />
}
