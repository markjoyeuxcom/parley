import { useCallback, useEffect, useState, type ReactNode } from 'react'
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
 */
export function TauriShell(): ReactNode {
  const [panes, setPanes] = useState<Pane[]>([])
  const [focused, setFocused] = useState<Id | null>(null)
  const [error, setError] = useState('')
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

  return (
    <div className="grid-surface">
      <div className="bar">
        <span className="label" style={{ flexShrink: 0 }}>PARLEY ON TAURI</span>
        {(['shell', 'claude', 'codex', 'agy'] as PaneKind[]).map((kind) => (
          <button key={kind} className="btn btn--sm" onClick={() => void open(kind)}>
            + {kind}
          </button>
        ))}
        <span className="spacer" />
        <span className="dim">
          {panes.length} pane{panes.length === 1 ? '' : 's'} · {received} bytes in
        </span>
      </div>

      {error ? (
        <div className="room__error room__error--banner" role="alert">{error}</div>
      ) : null}

      <div style={{ flex: 1, minHeight: 0, display: 'flex', gap: 1 }}>
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
          panes.map((pane) => (
            <div
              key={pane.id}
              style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column' }}
            >
              <div className="pane__head">
                <span className="pane__title">{pane.kind} — {pane.title}</span>
              </div>
              <div style={{ flex: 1, minHeight: 0 }}>
                <TerminalPane
                  paneId={pane.id}
                  focused={focused === pane.id}
                  onFocus={() => setFocused(pane.id)}
                />
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  )
}
