import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import type { RecordSearchHit } from '@shared/ipc'
import { api } from '../lib/api'
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
/**
 * The palette also asks the record.
 *
 * One box, one keystroke, two kinds of answer: things to DO (the actions
 * above) and things that were SAID (the search index below). A second overlay
 * on a second shortcut would make someone decide which kind of question they
 * have before typing, which is exactly the decision a palette exists to
 * absorb.
 */
export function CommandPalette({ actions }: { actions: PaletteAction[] }): ReactNode {
  const { state, dispatch } = useStore()
  const [query, setQuery] = useState('')
  const [cursor, setCursor] = useState(0)
  const [hits, setHits] = useState<RecordSearchHit[]>([])
  const listRef = useRef<HTMLDivElement>(null)

  const results = useMemo(() => filterActions(actions, query), [actions, query])

  // Debounced, and generation-guarded: a slow answer for "ret" must not land
  // on top of the results for "retry ceiling".
  useEffect(() => {
    if (!state.paletteOpen || !query.trim()) {
      setHits([])
      return
    }
    let stale = false
    const timer = setTimeout(() => {
      void api
        .searchRecord(query, 12)
        .then((found) => {
          if (!stale) setHits(found)
        })
        .catch(() => {
          // A search that fails mid-keystroke is noise, not news; the actions
          // above keep working and the next keystroke retries.
          if (!stale) setHits([])
        })
    }, 150)
    return () => {
      stale = true
      clearTimeout(timer)
    }
  }, [query, state.paletteOpen])

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

  /** Actions first, then the record: one list as far as the keyboard knows. */
  const total = results.length + hits.length

  const openHit = (hit: RecordSearchHit): void => {
    // A hit lives in a room, and the only place a room can be read is a pane.
    // The Grid consumes this and clears it.
    if (hit.roomId) dispatch({ type: 'focusRoom', roomId: hit.roomId })
  }

  const commit = (index: number): void => {
    const action = results[index]
    if (action) {
      close()
      action.run()
      return
    }
    const hit = hits[index - results.length]
    if (!hit) return
    close()
    openHit(hit)
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
              setCursor((c) => Math.min(total - 1, c + 1))
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
          {total === 0 ? (
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
          {hits.length > 0 ? (
            <>
              <div className="palette__section">In the record</div>
              {hits.map((hit, at) => {
                const index = results.length + at
                return (
                  <button
                    key={`${hit.kind}:${hit.refId}`}
                    className={`palette__item ${index === cursor ? 'is-active' : ''}`}
                    onMouseEnter={() => setCursor(index)}
                    onClick={() => commit(index)}
                  >
                    <span style={{ color: 'var(--text-tertiary)', fontSize: 'var(--text-tiny)', minWidth: 52 }}>
                      {hit.kind}
                    </span>
                    <span className="palette__snippet">{markedSnippet(hit.snippet)}</span>
                  </button>
                )
              })}
            </>
          ) : null}
        </div>
      </div>
    </div>
  )
}

/**
 * The snippet with the index's «marks» rendered as marks.
 *
 * The characters are the search layer's own highlighting protocol — chosen
 * there because they cannot appear in a git path or survive tokenising — and
 * this is the one place they become visual instead of textual.
 */
export function markedSnippet(snippet: string): ReactNode {
  const parts = snippet.split(/[«»]/)
  return parts.map((part, at) =>
    at % 2 === 1 ? <mark key={at}>{part}</mark> : <span key={at}>{part}</span>,
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
