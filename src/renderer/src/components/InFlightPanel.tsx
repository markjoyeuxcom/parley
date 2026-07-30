import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { Activity } from 'lucide-react'
import type { InFlightRow } from '@shared/inflight'
import { api } from '../lib/api'
import { formatDuration, shortPath } from '../lib/format'
import { useStore } from '../state'
import { Chip, Empty, Spinner } from './ui'

/**
 * "In flight" — the live half of the attention model.
 *
 * Sibling of the holds queue, and deliberately its opposite: holds are what
 * waits on YOU, this is what is working for you. Both are derived from the
 * record rather than stored, both sort oldest-first (longest-running is
 * likeliest stuck), and both make every row openable — a status you cannot
 * act on is decoration.
 *
 * Not a fifth surface, on purpose. A dashboard would compete with the four
 * surfaces that actually hold work; a popover is glanceable and gone.
 */

/** Poll only while open. Nothing here is a durable transition worth an event. */
const REFRESH_MS = 2000

export function InFlightButton({
  open,
  onToggle,
  count,
}: {
  open: boolean
  onToggle: () => void
  count: number
}): ReactNode {
  return (
    <button
      className="btn btn--subtle btn--sm"
      onClick={onToggle}
      title="In flight — what is running now"
      aria-haspopup="dialog"
      aria-expanded={open}
    >
      <Activity size={12} strokeWidth={2} />
      {count > 0 ? <span className="segmented__count tnum">{count}</span> : null}
    </button>
  )
}

export function useInFlight(active: boolean): InFlightRow[] {
  const [rows, setRows] = useState<InFlightRow[]>([])

  const refresh = useCallback(() => {
    void api
      .listInFlight()
      .then((next) => setRows(Array.isArray(next) ? next : []))
      .catch(() => setRows([]))
  }, [])

  useEffect(() => {
    refresh()
    if (!active) return
    const timer = setInterval(refresh, REFRESH_MS)
    return () => clearInterval(timer)
  }, [active, refresh])

  return rows
}

const KIND_LABEL: Record<InFlightRow['kind'], string> = {
  envelope: 'unattended',
  milestone: 'milestone',
  plan: 'planning',
  session: 'session',
  loop: 'loop',
}

export function InFlightPopover({
  rows,
  onClose,
}: {
  rows: InFlightRow[]
  onClose: () => void
}): ReactNode {
  const { dispatch, openPlan, openSession, openLoop } = useStore()
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const jump = (row: InFlightRow): void => {
    onClose()
    if (row.jump.to === 'session') {
      dispatch({ type: 'surface', surface: 'parley' })
      void openSession(row.jump.sessionId)
      return
    }
    if (row.jump.to === 'loop') {
      dispatch({ type: 'surface', surface: 'loops' })
      void openLoop(row.jump.loopId)
      return
    }
    // A plan's home is the Repos surface's Plans tab, where it opens in place.
    if (row.repoPath) {
      dispatch({ type: 'focusBacklogRepo', repoPath: row.repoPath, tab: 'plans' })
    }
    dispatch({ type: 'surface', surface: 'backlog' })
    void openPlan(row.jump.planId)
    if (row.jump.milestoneId) {
      dispatch({ type: 'focusMilestone', milestoneId: row.jump.milestoneId })
    }
  }

  return (
    <>
      <div className="holds-scrim" onClick={onClose} />
      <section className="holds-popover" role="dialog" aria-label="In flight">
        <header className="holds-popover__head">
          <strong>In flight</strong>
          <span className="spacer" />
          <span style={{ fontSize: 'var(--text-tiny)', color: 'var(--text-tertiary)' }}>
            {rows.length ? `${rows.length} running` : ''}
          </span>
        </header>

        {rows.length === 0 ? (
          <Empty title="Nothing is running" body="Started work appears here while it runs." />
        ) : (
          <div className="plan-list" style={{ maxHeight: '60vh' }}>
            {rows.map((row) => (
              <button key={row.id} className="list-item" onClick={() => jump(row)}>
                <div className="row row--tight">
                  <Spinner />
                  <span className="list-item__title">{row.title}</span>
                  <span className="spacer" />
                  {row.mock ? <Chip tone="chip--caution">mock</Chip> : null}
                  <Chip tone="chip--mono">{KIND_LABEL[row.kind]}</Chip>
                </div>
                <div className="list-item__meta">
                  {row.detail} · {formatDuration(Math.max(0, now - row.startedAt))}
                  {row.repoPath ? ` · ${shortPath(row.repoPath)}` : ''}
                </div>
                {row.progress?.length ? (
                  <div className="row row--tight" style={{ gap: 'var(--s3)', marginTop: 'var(--s2)' }}>
                    {row.progress.map((bar) => (
                      <span
                        key={bar.label}
                        title={`${bar.label}: ${Math.round(Math.min(1, bar.value) * 100)}% of its cap`}
                        style={{ flex: 1, height: 3, background: 'var(--line)', borderRadius: 999 }}
                      >
                        <span
                          style={{
                            display: 'block',
                            height: '100%',
                            width: `${Math.min(100, Math.max(0, bar.value * 100))}%`,
                            background: bar.value >= 0.9 ? 'var(--caution)' : 'var(--accent)',
                            borderRadius: 999,
                          }}
                        />
                      </span>
                    ))}
                  </div>
                ) : null}
              </button>
            ))}
          </div>
        )}
      </section>
    </>
  )
}
