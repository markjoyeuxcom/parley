import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useStore } from '../state'

export interface PaletteAction {
  id: string
  label: string
  hint?: string
  group: string
  run: () => void
}

/**
 * Command palette.
 *
 * Filtering is a simple subsequence match on label and group, which is what a
 * keyboard-driven user actually wants — typing "nd" should find "New debate".
 */
export function CommandPalette({ actions }: { actions: PaletteAction[] }): ReactNode {
  const { state, dispatch } = useStore()
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const listRef = useRef<HTMLDivElement>(null)

  const results = useMemo(() => filterActions(actions, query), [actions, query])

  useEffect(() => {
    setCursor(0)
  }, [query])

  // Reset the query each time it opens: a palette that remembers the last search
  // makes the next invocation slower, not faster.
  useEffect(() => {
    if (state.paletteOpen) {
      setQuery('')
      setCursor(0)
    }
  }, [state.paletteOpen])

  useEffect(() => {
    listRef.current?.querySelector('.is-active')?.scrollIntoView({ block: 'nearest' })
  }, [cursor])

  if (!state.paletteOpen) return null

  const close = (): void => dispatch({ type: 'palette', open: false })

  const commit = (index: number): void => {
    const action = results[index]
    if (!action) return
    close()
    action.run()
  }

  return (
    <div
      className="palette-scrim"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) close()
      }}
    >
      <div className="palette" role="dialog" aria-modal="true" aria-label="Command palette">
        <input
          className="palette__input"
          placeholder="Run a command…"
          value={query}
          autoFocus
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.preventDefault()
              close()
            } else if (event.key === 'ArrowDown') {
              event.preventDefault()
              setCursor((c) => Math.min(results.length - 1, c + 1))
            } else if (event.key === 'ArrowUp') {
              event.preventDefault()
              setCursor((c) => Math.max(0, c - 1))
            } else if (event.key === 'Enter') {
              event.preventDefault()
              commit(cursor)
            }
          }}
        />
        <div className="palette__list" ref={listRef}>
          {results.length === 0 ? (
            <div style={{ padding: 'var(--s6)', color: 'var(--text-tertiary)', fontSize: 'var(--text-small)' }}>
              Nothing matches “{query}”.
            </div>
          ) : (
            results.map((action, index) => (
              <button
                key={action.id}
                className={`palette__item ${index === cursor ? 'is-active' : ''}`}
                onMouseEnter={() => setCursor(index)}
                onClick={() => commit(index)}
              >
                <span style={{ color: 'var(--text-tertiary)', fontSize: 'var(--text-tiny)', minWidth: 52 }}>
                  {action.group}
                </span>
                <span>{action.label}</span>
                {action.hint ? <span className="palette__hint">{action.hint}</span> : null}
              </button>
            ))
          )}
        </div>
      </div>
    </div>
  )
}

/** Case-insensitive subsequence match, ranked by how early the match starts. */
export function filterActions(actions: PaletteAction[], query: string): PaletteAction[] {
  const needle = query.trim().toLowerCase()
  if (!needle) return actions

  const scored: Array<{ action: PaletteAction; score: number }> = []
  for (const action of actions) {
    const haystack = `${action.group} ${action.label}`.toLowerCase()
    const score = subsequenceScore(haystack, needle)
    if (score !== null) scored.push({ action, score })
  }
  return scored.sort((a, b) => a.score - b.score).map((s) => s.action)
}

function subsequenceScore(haystack: string, needle: string): number | null {
  let index = 0
  let first = -1
  let gaps = 0
  let last = -1

  for (const char of needle) {
    const found = haystack.indexOf(char, index)
    if (found === -1) return null
    if (first === -1) first = found
    if (last !== -1) gaps += found - last - 1
    last = found
    index = found + 1
  }
  return first * 2 + gaps
}
