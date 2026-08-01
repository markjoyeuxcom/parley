import { useEffect, useState, type ReactNode } from 'react'
import { History } from 'lucide-react'
import { entryLabel, summariseRuns, type RunLine, type RunSummary } from '@shared/runroom'
import { api } from '../lib/api'
import { relativeTime } from '../lib/format'
import { Chip, Spinner } from './ui'

/**
 * What happened, in the order it happened.
 *
 * The milestone row says where things ended up. This says how they got there —
 * which agent did what, what the verification actually reported, which
 * findings a reviewer raised and whether the second attempt fared better. That
 * story used to exist only while a run was live, scattered across activity
 * lines nobody kept.
 *
 * It shows, and does not act. Every control that changes anything stays where
 * it was on the milestone: a room that grew its own approve button would be a
 * second place to authorise work, which is exactly one more than there should
 * be.
 */

const TONE: Record<RunLine['tone'], string> = {
  plain: '',
  good: 'dot--pass',
  bad: 'dot--fail',
  warn: 'dot--caution',
}

const OUTCOME: Record<string, { label: string; tone: string }> = {
  complete: { label: 'completed', tone: 'chip--pass' },
  failed: { label: 'failed', tone: 'chip--fail' },
  // Not a failure: an attempt that could not establish anything.
  parked: { label: 'parked', tone: 'chip--caution' },
  accepted: { label: 'accepted', tone: 'chip--pass' },
  ended: { label: 'ended', tone: 'chip--caution' },
  unstarted: { label: 'never started', tone: 'chip--caution' },
  disconnected: { label: 'disconnected', tone: 'chip--caution' },
  rejected: { label: 'refused', tone: 'chip--fail' },
}

export function RunRoom({
  milestoneId,
  version,
}: {
  milestoneId: string
  /** Changes when the milestone does, which is when its story has grown. */
  version: string
}): ReactNode {
  const [runs, setRuns] = useState<RunSummary[] | null>(null)

  useEffect(() => {
    let cancelled = false
    void api
      .milestoneRuns(milestoneId)
      .then((next) => {
        if (cancelled) return
        setRuns(summariseRuns(Array.isArray(next) ? next : []))
      })
      .catch(() => {
        if (!cancelled) setRuns([])
      })
    return () => {
      cancelled = true
    }
    // `version` is bumped by whatever the milestone did, so a finished run
    // appears without anyone reloading anything.
  }, [milestoneId, version])

  if (runs === null) {
    return (
      <div className="field__hint" style={{ padding: 'var(--s4) 0' }}>
        <Spinner />
      </div>
    )
  }
  if (runs.length === 0) {
    return (
      <div className="field__hint" style={{ padding: 'var(--s3) 0' }}>
        No run yet. What happens here will be kept: which agent did what, what verification
        reported, and what a reviewer objected to.
      </div>
    )
  }

  return (
    <div className="run-room">
      {runs.map((run, index) => (
        // The most recent attempt is open; earlier ones are there without
        // being in the way.
        <RunAttempt key={run.runId} run={run} number={runs.length - index} open={index === 0} />
      ))}
    </div>
  )
}

function RunAttempt({
  run,
  number,
  open,
}: {
  run: RunSummary
  number: number
  open: boolean
}): ReactNode {
  const [expanded, setExpanded] = useState(open)
  const outcome = run.outcome ? OUTCOME[run.outcome] : null

  return (
    <section className="run-attempt">
      <button className="run-attempt__head" onClick={() => setExpanded((value) => !value)}>
        <History size={11} strokeWidth={2} />
        <span className="run-attempt__title">
          {entryLabel(run.entry)} {number}
        </span>
        {outcome ? (
          <Chip tone={outcome.tone}>{outcome.label}</Chip>
        ) : (
          // A run with no ending is still going — or stopped without saying
          // so, which is the case worth being able to see.
          <Chip tone="chip--accent">in flight</Chip>
        )}
        <span className="spacer" />
        {run.tokens > 0 ? (
          <span className="dimmer tnum" style={{ fontSize: 'var(--text-micro)' }}>
            {run.tokens.toLocaleString()} tokens
          </span>
        ) : null}
        <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
          {relativeTime(run.startedAt)}
        </span>
      </button>

      {expanded ? (
        <ol className="run-attempt__lines">
          {run.lines.map((line) => (
            <li key={line.id} className="run-line">
              <span className={`dot ${TONE[line.tone]}`} />
              <span className="run-line__who">{line.who}</span>
              <span className="run-line__text">{line.text}</span>
              {line.detail ? <span className="run-line__detail">{line.detail}</span> : null}
            </li>
          ))}
          {run.lines.length === 0 ? (
            <li className="field__hint">This attempt recorded nothing before it ended.</li>
          ) : null}
        </ol>
      ) : null}
    </section>
  )
}
