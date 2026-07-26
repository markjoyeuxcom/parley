import { useEffect, useRef, useState, type ReactNode } from 'react'
import type { Id } from '@shared/domain'
import { formatDuration } from '../lib/format'
import { useStore } from '../state'

/**
 * Live view of a run in progress.
 *
 * A milestone can occupy half an hour between approval and verdict. Without this
 * the only signal is a spinner, and the honest question a user asks — "is it
 * stuck, or is it working?" — has no answer. The feed is the agent's own tool
 * activity: the files it opens, the commands it runs, the phase Parley has
 * reached.
 *
 * Deliberately not persisted. The durable record is the milestone row; this is
 * a window onto the present.
 */
export function RunActivity({ subjectId, live }: { subjectId: Id; live: boolean }): ReactNode {
  const { state } = useStore()
  const log = state.activity[subjectId]
  const scrollRef = useRef<HTMLDivElement>(null)
  const [, forceTick] = useState(0)

  // Tick once a second so the elapsed clock advances while nothing else changes.
  // Only while live: a finished run's duration is fixed.
  useEffect(() => {
    if (!live) return
    const timer = setInterval(() => forceTick((n) => n + 1), 1000)
    return () => clearInterval(timer)
  }, [live])

  // The newest line is the interesting one, so the feed pins to the bottom.
  useEffect(() => {
    const el = scrollRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [log?.entries.length])

  if (!log) return null

  const elapsed = Date.now() - log.startedAt
  const latest = log.entries.at(-1)

  return (
    <div className="run">
      <div className="run__head">
        {live ? <span className="spinner" /> : null}
        <span className="run__phase">{live ? (latest?.phase ?? 'starting') : 'finished'}</span>
        <span className="run__elapsed tnum">{formatDuration(elapsed)}</span>
        <div className="spacer" />
        <span className="run__count tnum">
          {log.entries.length} {log.entries.length === 1 ? 'step' : 'steps'}
        </span>
      </div>

      {log.entries.length === 0 ? (
        <div className="run__empty">Waiting for the agent to report its first action…</div>
      ) : (
        <div className="run__feed" ref={scrollRef}>
          {log.entries.map((entry, index) => (
            <div className="run__line" key={`${entry.at}-${index}`}>
              <span className="run__time tnum">{clockOf(entry.at)}</span>
              <span className="run__text">{entry.text}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function clockOf(at: number): string {
  const d = new Date(at)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(
    d.getSeconds(),
  ).padStart(2, '0')}`
}
