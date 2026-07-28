import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { Titlebar } from './components/Titlebar'
import { Notices } from './components/Notices'
import { HoldsPopover } from './components/HoldsPanel'
import { countActionable } from './lib/holdsState'
import { CommandPalette, type PaletteAction } from './components/CommandPalette'
import { NewSessionDialog } from './components/NewSessionDialog'
import { GridSurface } from './surfaces/GridSurface'
import { ParleySurface } from './surfaces/ParleySurface'
import { LoopsSurface } from './surfaces/LoopsSurface'
import { BacklogSurface } from './surfaces/BacklogSurface'
import { useStore, type Surface } from './state'

export function App(): ReactNode {
  const { state, dispatch, openSession, refreshSessions } = useStore()
  const [quickSession, setQuickSession] = useState<'debate' | 'review' | null>(null)

  // ⌘K opens the palette; ⌘1/2/3 jump between surfaces. Registered once at the
  // app level so shortcuts work regardless of which surface has focus.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (!event.metaKey) return
      const key = event.key.toLowerCase()
      if (key === 'k') {
        event.preventDefault()
        dispatch({ type: 'palette', open: !state.paletteOpen })
      } else if (key === '1' || key === '2' || key === '3' || key === '4') {
        event.preventDefault()
        const order: Surface[] = ['grid', 'parley', 'loops', 'backlog']
        const next = order[Number(key) - 1]
        if (next) dispatch({ type: 'surface', surface: next })
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [dispatch, state.paletteOpen])

  const actions = useMemo<PaletteAction[]>(() => {
    const list: PaletteAction[] = [
      {
        id: 'surface.grid',
        group: 'Go',
        label: 'Grid — parallel terminals',
        hint: '⌘1',
        run: () => dispatch({ type: 'surface', surface: 'grid' }),
      },
      {
        id: 'surface.parley',
        group: 'Go',
        label: 'Parley — debates and reviews',
        hint: '⌘2',
        run: () => dispatch({ type: 'surface', surface: 'parley' }),
      },
      {
        id: 'surface.loops',
        group: 'Go',
        label: 'Loops — autonomous runs',
        hint: '⌘3',
        run: () => dispatch({ type: 'surface', surface: 'loops' }),
      },
      {
        id: 'surface.backlog',
        group: 'Go',
        label: (() => {
          const pending = state.backlogItems.filter(
            (i) => i.state === 'proposed' || i.state === 'closure-proposed',
          ).length
          return pending > 0
            ? `Repos — ${pending} proposal${pending === 1 ? '' : 's'} to review`
            : 'Repos — every repository Parley works'
        })(),
        hint: '⌘4',
        run: () => dispatch({ type: 'surface', surface: 'backlog' }),
      },
      {
        id: 'new.debate',
        group: 'New',
        label: 'Debate — argue a decision to a verdict',
        run: () => setQuickSession('debate'),
      },
      {
        id: 'new.review',
        group: 'New',
        label: 'Codebase review — evidence-led audit',
        run: () => setQuickSession('review'),
      },
      {
        id: 'new.loop',
        group: 'New',
        label: 'Loop — run until a condition holds',
        run: () => dispatch({ type: 'surface', surface: 'loops' }),
      },
      {
        id: 'holds.open',
        group: 'Go',
        label:
          countActionable(state.holds) > 0
            ? `Holds — ${countActionable(state.holds)} waiting on you`
            : 'Holds — nothing waiting',
        run: () => dispatch({ type: 'holdsPanel', open: true }),
      },
      {
        id: 'theme.cycle',
        group: 'View',
        label: `Appearance — currently ${state.theme}`,
        run: () =>
          dispatch({
            type: 'theme',
            theme: state.theme === 'system' ? 'light' : state.theme === 'light' ? 'dark' : 'system',
          }),
      },
    ]

    // Recent sessions become palette entries, which is how a keyboard user gets
    // back to a session without reaching for the sidebar.
    for (const session of state.sessions.slice(0, 8)) {
      list.push({
        id: `open.${session.id}`,
        group: 'Open',
        label: session.matter.replace(/\s+/g, ' ').slice(0, 72),
        hint: session.kind === 'review' ? 'review' : 'debate',
        run: () => {
          dispatch({ type: 'surface', surface: 'parley' })
          void openSession(session.id)
        },
      })
    }

    return list
  }, [dispatch, openSession, state.backlogItems, state.holds, state.sessions, state.theme])

  return (
    <div className={state.mock ? 'app app--mock' : 'app'}>
      <Titlebar />

      {/*
        Not dismissible. In mock mode every session, verdict and review is
        fabricated — losing track of that is how invented output gets read as
        evidence. It sits below the titlebar rather than above it because the
        traffic lights are positioned at a fixed offset and would overlap.
      */}
      {state.mock ? (
        <div className="mock-banner" role="alert">
          Mock mode — no real work
          <span className="mock-banner__detail">
            Nothing is sent to Claude or Codex. Approving a milestone does write one
            placeholder file into the repository, so the pipeline can be exercised.
            Restart without PARLEY_MOCK=1 to use the real CLIs.
          </span>
        </div>
      ) : null}


      {/* Surfaces stay mounted so terminals keep their scrollback and live
          sessions keep streaming while the user works elsewhere. */}
      <div style={{ display: state.surface === 'grid' ? 'contents' : 'none' }}>
        <GridSurface />
      </div>
      <div style={{ display: state.surface === 'parley' ? 'contents' : 'none' }}>
        <ParleySurface />
      </div>
      <div style={{ display: state.surface === 'loops' ? 'contents' : 'none' }}>
        <LoopsSurface />
      </div>
      <div style={{ display: state.surface === 'backlog' ? 'contents' : 'none' }}>
        <BacklogSurface />
      </div>

      <CommandPalette actions={actions} />
      <HoldsPopover />
      <Notices />

      {quickSession ? (
        <NewSessionDialog
          initialKind={quickSession}
          onClose={() => setQuickSession(null)}
          onStarted={(session) => {
            dispatch({ type: 'surface', surface: 'parley' })
            void refreshSessions()
            void openSession(session.id)
          }}
        />
      ) : null}
    </div>
  )
}
