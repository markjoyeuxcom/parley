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
import { registerTerm, rememberSelection } from '../lib/termSelection'
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
      scrollback: 12_000,
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

    // WebGL is a large win on a 16-pane grid, but it fails on some GPU/driver
    // combinations and in software rendering. Falling back to the DOM renderer
    // is correct; refusing to open a terminal is not.
    try {
      const webgl = new WebglAddon()
      webgl.onContextLoss(() => webgl.dispose())
      term.loadAddon(webgl)
    } catch {
      /* DOM renderer it is. */
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
    const dataSub = term.onData((data) => {
      void api.writePane(paneId, data)
      if (data.includes('\r') || data.includes('\n')) {
        submitted?.dispose()
        submitted = term.registerMarker(0)
      }
    })

    const detach = attachPane(paneId, (data) => {
      term.write(data)
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
        const lines: string[] = []
        for (let at = from; at < buffer.length; at += 1) {
          lines.push(buffer.getLine(at)?.translateToString(true) ?? '')
        }
        return cleanRelayText(lines)
      },
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
