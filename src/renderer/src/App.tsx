import { useEffect, useMemo, type ReactNode } from 'react'
import { Titlebar } from './components/Titlebar'
import { Notices } from './components/Notices'
import { CommandPalette, type PaletteAction } from './components/CommandPalette'
import { GridSurface } from './surfaces/GridSurface'
import { useStore } from './state'

/**
 * The window.
 *
 * One surface now. The three that stood beside it — debates and reviews, the
 * capped loops, the repository board — were the governed engine's front ends,
 * and they went with it: what they were for is a room with two seats and a
 * person deciding who speaks.
 */
export function App(): ReactNode {
  const { state, dispatch } = useStore()

  // ⌘K opens the palette. Registered at the app level so it works regardless
  // of which pane has focus.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (!event.metaKey) return
      if (event.key.toLowerCase() === 'k') {
        event.preventDefault()
        dispatch({ type: 'palette', open: !state.paletteOpen })
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [dispatch, state.paletteOpen])

  const actions = useMemo<PaletteAction[]>(
    () => [
      {
        id: 'theme.auto',
        group: 'Appearance',
        label: 'Match the system theme',
        run: () => dispatch({ type: 'theme', theme: 'auto' }),
      },
      {
        id: 'theme.light',
        group: 'Appearance',
        label: 'Light',
        run: () => dispatch({ type: 'theme', theme: 'light' }),
      },
      {
        id: 'theme.dark',
        group: 'Appearance',
        label: 'Dark',
        run: () => dispatch({ type: 'theme', theme: 'dark' }),
      },
    ],
    [dispatch],
  )

  return (
    <div className="app">
      <Titlebar />
      <GridSurface />
      <Notices />
      {state.paletteOpen ? (
        <CommandPalette actions={actions} />
      ) : null}
    </div>
  )
}
