import { type ReactNode } from 'react'
import { Command, Repeat, Scale, Terminal } from 'lucide-react'
import { useStore, type Surface, type ThemeChoice } from '../state'
import { HoldsButton } from './HoldsPanel'
import { Dot } from './ui'

const SURFACES: Array<{ id: Surface; label: string; icon: ReactNode }> = [
  { id: 'grid', label: 'Grid', icon: <Terminal size={13} strokeWidth={2} /> },
  { id: 'parley', label: 'Parley', icon: <Scale size={13} strokeWidth={2} /> },
  { id: 'loops', label: 'Loops', icon: <Repeat size={13} strokeWidth={2} /> },
]

const THEME_ORDER: ThemeChoice[] = ['system', 'light', 'dark']

export function Titlebar(): ReactNode {
  const { state, dispatch } = useStore()

  const activeSessions = state.sessions.filter((s) => s.status === 'running' || s.status === 'paused').length
  const activeLoops = state.loops.filter((l) => l.status === 'running' || l.status === 'paused').length
  const counts: Record<Surface, number> = {
    grid: state.panes.filter((p) => p.status !== 'exited').length,
    parley: activeSessions,
    loops: activeLoops,
  }

  return (
    <header className="titlebar">
      <div className="titlebar__left">
        <div className="wordmark">
          Parley
        </div>
      </div>

      <nav className="segmented no-drag" role="tablist" aria-label="Surface">
        {SURFACES.map((surface) => (
          <button
            key={surface.id}
            role="tab"
            aria-selected={state.surface === surface.id}
            className={`segmented__item ${state.surface === surface.id ? 'is-active' : ''}`}
            onClick={() => dispatch({ type: 'surface', surface: surface.id })}
          >
            {surface.icon}
            {surface.label}
            {counts[surface.id] > 0 ? (
              <span className="segmented__count tnum">{counts[surface.id]}</span>
            ) : null}
          </button>
        ))}
      </nav>

      <div className="titlebar__right">
        <CliStatus />
        <HoldsButton />
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
            dispatch({ type: 'theme', theme: next ?? 'system' })
          }}
          title={`Appearance: ${state.theme}`}
        >
          {state.theme === 'system' ? 'Auto' : state.theme === 'light' ? 'Light' : 'Dark'}
        </button>
      </div>
    </header>
  )
}

/**
 * Subscription status for the two CLIs.
 *
 * Shown permanently rather than only on failure: the whole app depends on these
 * being signed in, and a silent "not authenticated" is the single most likely
 * reason a session produces nothing.
 */
function CliStatus(): ReactNode {
  const { state } = useStore()
  if (!state.health.length) return null

  return (
    <div className="row row--tight" style={{ marginRight: 'var(--s2)' }}>
      {state.health.map((cli) => {
        const tone = !cli.present ? 'dot--fail' : cli.authenticated ? 'dot--pass' : 'dot--caution'
        return (
          <span
            key={cli.vendor}
            className="row row--tight"
            title={`${cli.vendor} ${cli.version} — ${cli.detail}`}
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
