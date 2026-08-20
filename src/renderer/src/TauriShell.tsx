import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { listen } from '@tauri-apps/api/event'
import type { Id, Pane, PaneKind } from '@shared/domain'
import { api } from './lib/api'
import { TerminalPane } from './components/TerminalPane'

/**
 * The smallest thing that answers the question.
 *
 * A real CLI, in a real PTY spawned from Rust, drawn by xterm inside
 * WKWebView. Not the Grid — most of the Grid's commands have no Rust
 * implementation yet, and a surface full of loud failures would tell us
 * nothing. This tells us whether the migration's premise holds.
 *
 * It reuses `TerminalPane` unchanged, which is the point of the whole
 * approach: the renderer never knew which runtime was answering, so it did not
 * have to change when the answer became Rust.
 *
 * The arrangement here is deliberately not the Grid's. The Grid splits a tree
 * of slots, remembers layouts, and restores them with their processes; all of
 * that is worth having and none of it is worth rebuilding twice. This is a
 * column count. It exists so five terminals can be looked at while the rest of
 * the migration happens, and it should be deleted whole when GridSurface runs
 * on Rust.
 */

/** Kept small on purpose — past four columns a terminal is too narrow to read. */
const COLUMN_CHOICES = [1, 2, 3, 4] as const

/**
 * Squarish. Five panes in three columns is two rows of readable terminals;
 * five in a row is five slivers, which is what this started as.
 */
function autoColumns(count: number): number {
  if (count <= 1) return 1
  return Math.min(4, Math.ceil(Math.sqrt(count)))
}

export function TauriShell(): ReactNode {
  const [panes, setPanes] = useState<Pane[]>([])
  const [focused, setFocused] = useState<Id | null>(null)
  const [error, setError] = useState('')
  /** null means follow the pane count; a number is the user overriding that. */
  const [columns, setColumns] = useState<number | null>(null)
  /**
   * Bytes seen arriving, straight from the event channel.
   *
   * Added to find out why Rust was emitting into a blank terminal, and kept
   * because it is the cheapest possible answer to the question this build
   * exists to ask. Electron's renderer died at eight to fourteen minutes with
   * three busy panes; if this one goes the same way, the byte count at the
   * moment it stops is the difference between drowning in output and something
   * else entirely.
   */
  const [received, setReceived] = useState(0)
  useEffect(() => {
    const stop = listen<{ paneId: string; data: string }>('pty:data', (e) => {
      setReceived((n) => n + (e.payload?.data?.length ?? 0))
    })
    return () => void stop.then((off) => off())
  }, [])

  /**
   * Adopt whatever Rust already has.
   *
   * The panes outlive this window, deliberately — that is the same promise the
   * Electron build makes, and it is why closing the window does not throw away
   * an agent mid-task. Without this a reload showed an empty grid over a
   * handful of CLIs still running, still burning tokens, with no way left to
   * reach them.
   */
  useEffect(() => {
    api
      .listPanes()
      .then((existing) => {
        if (existing.length === 0) return
        setPanes(existing)
        setFocused((current) => current ?? existing[0]?.id ?? null)
      })
      .catch((err) => setError(err instanceof Error ? err.message : String(err)))
  }, [])

  const cols = columns ?? autoColumns(panes.length)

  const open = useCallback(async (kind: PaneKind) => {
    setError('')
    try {
      // The folder is the checkout for now; choosing one is a command that has
      // not been migrated, and inventing a second way to pick it would be a
      // thing to delete later.
      const pane = await api.openPane(kind, '/Users/markjoyeux/Developer/Personal/parley', 120, 34)
      setPanes((current) => [...current, pane])
      setFocused(pane.id)
    } catch (err) {
      // Loudly. A migration's worst failure is the quiet one.
      setError(err instanceof Error ? err.message : String(err))
    }
  }, [])

  const close = useCallback(async (paneId: Id) => {
    // Dropped from the layout first. The process is going either way, and a
    // pane that lingers while Rust tears it down is a pane taking keystrokes
    // nothing will read.
    setPanes((current) => current.filter((p) => p.id !== paneId))
    setFocused((current) => (current === paneId ? null : current))
    try {
      await api.closePane(paneId)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }, [])

  const summary = useMemo(
    () => `${panes.length} pane${panes.length === 1 ? '' : 's'} · ${received} bytes in`,
    [panes.length, received],
  )

  return (
    <div className="grid-surface">
      {/* data-tauri-drag-region, not -webkit-app-region: WKWebView does not
          honour the CSS property, and Tauri only drags for an event whose own
          target carries the attribute — so the buttons below stay clickable
          without opting out. */}
      <div className="bar bar--overlay" data-tauri-drag-region>
        <span className="label" style={{ flexShrink: 0 }}>PARLEY ON TAURI</span>
        {(['shell', 'claude', 'codex', 'agy'] as PaneKind[]).map((kind) => (
          <button key={kind} className="btn btn--sm" onClick={() => void open(kind)}>
            + {kind}
          </button>
        ))}

        <span className="spacer" />

        <span className="dim" style={{ flexShrink: 0 }}>columns</span>
        <button
          className={`btn btn--sm${columns === null ? ' btn--primary' : ''}`}
          onClick={() => setColumns(null)}
          title="Follow the pane count"
        >
          auto
        </button>
        {COLUMN_CHOICES.map((n) => (
          <button
            key={n}
            className={`btn btn--sm${columns === n ? ' btn--primary' : ''}`}
            onClick={() => setColumns(n)}
          >
            {n}
          </button>
        ))}

        <span className="dim" style={{ flexShrink: 0, marginLeft: 'var(--s4)' }}>{summary}</span>
      </div>

      {error ? (
        <div className="room__error room__error--banner" role="alert">{error}</div>
      ) : null}

      {panes.length === 0 ? (
        <div className="empty" style={{ margin: 'auto' }}>
          <div className="empty__title">No panes open</div>
          <div className="empty__body">
            Open one and watch it. The question this build exists to answer is
            whether a webview holds three busy terminals for longer than ten
            minutes.
          </div>
        </div>
      ) : (
        <div className="tauri-grid" style={{ ['--cols' as string]: cols }}>
          {panes.map((pane) => (
            <div
              key={pane.id}
              className={`tauri-pane${focused === pane.id ? ' tauri-pane--focused' : ''}`}
            >
              <div className="tauri-pane__head">
                {/* The title already carries the vendor for an agent pane —
                    same shape as the Electron build, because this string is
                    also the attribution the relay quotes it by. */}
                <span className="tauri-pane__title">{pane.title}</span>
                <span className="spacer" />
                <button
                  className="btn btn--icon btn--sm"
                  onClick={() => void close(pane.id)}
                  title={`Close this ${pane.kind} pane`}
                >
                  ✕
                </button>
              </div>
              {/* Directly in the flex column. `.pane__term` is `flex: 1`, which
                  is inert inside a block wrapper — that is what made every pane
                  stop at thirty-four rows regardless of the window. */}
              <TerminalPane
                paneId={pane.id}
                focused={focused === pane.id}
                onFocus={() => setFocused(pane.id)}
              />
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
