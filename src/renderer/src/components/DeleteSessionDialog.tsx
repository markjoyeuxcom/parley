import { useEffect, useState, type ReactNode } from 'react'
import type { Session, SessionDeletionImpact } from '@shared/domain'
import { api } from '../lib/api'
import { firstLine, shortPath } from '../lib/format'
import { useStore } from '../state'
import { Dialog, Spinner } from './ui'

/**
 * Confirms a permanent deletion by saying what it costs.
 *
 * "Are you sure?" cannot distinguish two rows that look identical in a list: an
 * abandoned six-turn conversation, and the only surviving record of why six
 * milestones' worth of code exists in a repository you still have. This asks the
 * database and reports the difference, so the answer is informed rather than
 * brave.
 */
export function DeleteSessionDialog({
  session,
  onClose,
  onDeleted,
}: {
  session: Session
  onClose: () => void
  onDeleted: () => void
}): ReactNode {
  const { attempt, notify } = useStore()
  const [impact, setImpact] = useState<SessionDeletionImpact | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let live = true
    void (async () => {
      const result = await attempt(() => api.sessionDeletionImpact(session.id))
      if (live && result) setImpact(result)
    })()
    return () => {
      live = false
    }
  }, [attempt, session.id])

  const confirm = async (): Promise<void> => {
    setBusy(true)
    const done = await attempt(() => api.deleteSession(session.id))
    setBusy(false)
    if (!done) return
    notify('info', 'Session deleted.')
    onDeleted()
  }

  // Work that reached a repository is the line worth drawing. Everything else is
  // a conversation, and losing a conversation is recoverable by having it again.
  const wroteCode = (impact?.completedMilestones ?? 0) > 0

  return (
    <Dialog
      title="Delete this session"
      subtitle="Permanent. Archiving hides a session; this destroys it."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--danger" disabled={busy || !impact} onClick={() => void confirm()}>
            {busy ? 'Deleting…' : 'Delete permanently'}
          </button>
        </>
      }
    >
      <div className="stack">
        <div className="label">{firstLine(session.matter, 120)}</div>

        {!impact ? (
          <div className="row">
            <Spinner />
            <span className="dim" style={{ fontSize: 'var(--text-small)' }}>
              Working out what this would remove…
            </span>
          </div>
        ) : (
          <>
            <div className="field__hint">This removes, permanently:</div>
            <ul className="impact">
              <li>
                {impact.turns} {impact.turns === 1 ? 'turn' : 'turns'} of transcript
                {impact.hasVerdict ? ', and the verdict' : ''}
                {impact.findings > 0 ? `, and ${impact.findings} findings` : ''}
              </li>
              {impact.plans > 0 ? (
                <li>
                  {impact.plans} {impact.plans === 1 ? 'plan' : 'plans'} and {impact.milestones}{' '}
                  {impact.milestones === 1 ? 'milestone' : 'milestones'}
                </li>
              ) : null}
            </ul>

            {wroteCode ? (
              // The case that deserves a real pause: the code is still on disk,
              // and this is the only record of how it got there.
              <div className="audit-note audit-note--reject">
                <strong>
                  {impact.completedMilestones} completed{' '}
                  {impact.completedMilestones === 1 ? 'milestone' : 'milestones'} wrote to{' '}
                  {impact.repos.map((r) => shortPath(r)).join(', ')}.
                </strong>{' '}
                That code is still there. Deleting this leaves it with no record of what it was
                for, what was reviewed, or why it was approved.
              </div>
            ) : (
              <div className="field__hint">
                Nothing was ever written to a repository from this session, so no code loses its
                provenance.
              </div>
            )}

            {impact.retainedApprovals > 0 ? (
              <div className="field__hint">
                {impact.retainedApprovals} spent{' '}
                {impact.retainedApprovals === 1 ? 'approval is' : 'approvals are'} kept. Each records
                that a write was authorised, and stays readable without the session.
              </div>
            ) : null}
          </>
        )}
      </div>
    </Dialog>
  )
}
