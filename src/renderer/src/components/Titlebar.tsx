import { type ReactNode } from 'react'
import { Command } from 'lucide-react'
import { isToolless } from '@shared/vendors'
import { useStore, type ThemeChoice } from '../state'
import { Dot } from './ui'

const THEME_ORDER: ThemeChoice[] = ['auto', 'light', 'dark']

export function Titlebar(): ReactNode {
  const { state, dispatch } = useStore()

  return (
    <header className="titlebar">
      <div className="titlebar__left">
        <div className="wordmark">
          Parley
        </div>
        {state.mock ? (
          // Unmissable, permanently. A mock room produces turns that look
          // exactly like real ones while consulting no model.
          <span className="chip chip--caution no-drag" title="Deterministic adapters — no model is consulted">
            mock
          </span>
        ) : null}
      </div>

      <div className="titlebar__right">
        <CliStatus />
        <button
          className="btn btn--subtle btn--sm"
          onClick={() => dispatch({ type: 'palette', open: true })}
          title="Command palette — ⌘K"
        >
          <Command size={12} strokeWidth={2} />
          <span className="kbd">K</span>
        </button>
        <button
          className="btn btn--subtle btn--sm"
          onClick={() => {
            const next = THEME_ORDER[(THEME_ORDER.indexOf(state.theme) + 1) % THEME_ORDER.length]
            dispatch({ type: 'theme', theme: next ?? 'auto' })
          }}
          title={`Appearance: ${state.theme}`}
        >
          {state.theme === 'auto' ? 'Auto' : state.theme === 'light' ? 'Light' : 'Dark'}
        </button>
      </div>
    </header>
  )
}

/**
 * Subscription status for the CLIs.
 *
 * Shown permanently rather than only on failure: the whole app depends on these
 * being signed in, and a silent "not authenticated" is the single most likely
 * reason a session produces nothing. A missing tool-less vendor is the one
 * exception — agy is tool-less in Parley's dispatch and can only hold a pane,
 * so its absence is a configuration rather than a failure, and gets the
 * neutral dot instead of red.
 */
function CliStatus(): ReactNode {
  const { state } = useStore()
  if (!state.health.length) return null

  return (
    <div className="row row--tight" style={{ marginRight: 'var(--s2)' }}>
      {state.health.map((cli) => {
        const absentButOptional = !cli.present && isToolless(cli.vendor)
        const tone = !cli.present
          ? absentButOptional
            ? ''
            : 'dot--fail'
          : cli.authenticated
            ? 'dot--pass'
            : 'dot--caution'
        const detail = absentButOptional
          ? `${cli.vendor} is optional — it only adds a third debate voice. ${cli.detail}`
          : cli.detail
        return (
          <span
            key={cli.vendor}
            className="row row--tight"
            title={`${cli.vendor} ${cli.version} — ${detail}`}
            style={{ gap: 4 }}
          >
            <Dot tone={tone} />
            <span style={{ fontSize: 'var(--text-tiny)', color: 'var(--text-tertiary)' }}>
              {cli.vendor}
            </span>
          </span>
        )
      })}
    </div>
  )
}
