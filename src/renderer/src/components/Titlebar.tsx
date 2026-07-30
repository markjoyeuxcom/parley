import { type ReactNode } from 'react'
import { Command, FolderGit2, Repeat, Scale, Terminal } from 'lucide-react'
import { isToolless } from '@shared/vendors'
import { useStore, type Surface, type ThemeChoice } from '../state'
import { HoldsButton } from './HoldsPanel'
import { Dot } from './ui'

const SURFACES: Array<{ id: Surface; label: string; icon: ReactNode }> = [
  { id: 'grid', label: 'Grid', icon: <Terminal size={13} strokeWidth={2} /> },
  { id: 'parley', label: 'Parley', icon: <Scale size={13} strokeWidth={2} /> },
  { id: 'loops', label: 'Loops', icon: <Repeat size={13} strokeWidth={2} /> },
  // The id stays 'backlog' (⌘4, every literal, zero churn); only the face
  // changed when the surface grew from a board into the repository home.
  { id: 'backlog', label: 'Repos', icon: <FolderGit2 size={13} strokeWidth={2} /> },
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
    // Pending triage, matching the backlog-review hold: proposals in, human
    // answer not yet given.
    backlog: state.backlogItems.filter(
      (i) => i.state === 'proposed' || i.state === 'closure-proposed',
    ).length,
  }

  return (
    <header className="titlebar">
      <div className="titlebar__left">
        <div className="wordmark">
          Parley
        </div>
        {state.selfRepoPath !== null ? (
          // The instance marker: this build runs from the checkout, against
          // the parley-dev record — a packaged install never shows it. One
          // glance answers "which Parley is this window".
          <span
            className="chip chip--caution no-drag"
            title={`Development build — running from ${state.selfRepoPath}; data in parley-dev`}
          >
            dev
          </span>
        ) : null}
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
 * Subscription status for the CLIs.
 *
 * Shown permanently rather than only on failure: the whole app depends on these
 * being signed in, and a silent "not authenticated" is the single most likely
 * reason a session produces nothing. A missing tool-less vendor is the one
 * exception — agy only ever fills optional debate seats, so its absence is a
 * configuration, not a failure, and gets the neutral dot instead of red.
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
