import { useEffect, useState, type ReactNode } from 'react'
import { Inbox } from 'lucide-react'
import type { Hold } from '@shared/holds'
import { api } from '../lib/api'
import { countActionable } from '../lib/holdsState'
import { relativeTime } from '../lib/format'
import { useStore } from '../state'
import { Chip, Empty } from './ui'

/** Hold kinds whose exact control is the milestone's approval dialog. */
const DIALOG_KINDS = new Set<Hold['kind']>(['approval-waiting', 'ledger-gated', 'milestone-failed'])

/**
 * The titlebar affordance for the attention queue.
 *
 * The count is decision holds only — things that block work until the user
 * acts. Notices are inside the panel but do not wear on the badge; a number
 * that mixed the two would go stale-looking the moment someone triaged their
 * notices, and unreliable numbers get ignored.
 */
export function HoldsButton(): ReactNode {
  const { state, dispatch } = useStore()
  const actionable = countActionable(state.holds)

  return (
    <button
      className="btn btn--subtle btn--sm"
      onClick={() => dispatch({ type: 'holdsPanel', open: !state.holdsOpen })}
      title="Holds — what is waiting on you"
      aria-haspopup="dialog"
      aria-expanded={state.holdsOpen}
    >
      <Inbox size={12} strokeWidth={2} />
      {actionable > 0 ? <span className="segmented__count tnum">{actionable}</span> : null}
    </button>
  )
}

/**
 * The queue itself: every hold, cross-surface, each with a way to act.
 *
 * Decision holds only offer Open — they clear by acting where the work is
 * (answer, approve, land), and the main process refuses their acks anyway.
 * Notice holds offer Acknowledge, and the returned snapshot replaces local
 * state so the badge and a second window always agree.
 */
export function HoldsPopover(): ReactNode {
  const { state, dispatch, attempt, openSession, openPlan, openLoop } = useStore()
  const [busyId, setBusyId] = useState<string | null>(null)

  useEffect(() => {
    if (!state.holdsOpen) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') dispatch({ type: 'holdsPanel', open: false })
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [dispatch, state.holdsOpen])

  if (!state.holdsOpen) return null

  const close = (): void => dispatch({ type: 'holdsPanel', open: false })

  const jump = (hold: Hold): void => {
    close()
    // Backlog and foreman holds are repository-scoped: the control is the
    // surface itself, opened on the repo whose proposals wait.
    if (hold.kind === 'backlog-review' || hold.kind === 'foreman-proposal') {
      dispatch({ type: 'focusBacklogRepo', repoPath: hold.repoPath })
      dispatch({ type: 'surface', surface: 'backlog' })
      return
    }
    if (hold.loopId) {
      dispatch({ type: 'surface', surface: 'loops' })
      void openLoop(hold.loopId)
      return
    }
    if (hold.sessionId) {
      dispatch({ type: 'surface', surface: 'parley' })
      void openSession(hold.sessionId).then(async () => {
        if (hold.planId) await openPlan(hold.planId)
        // For holds whose control is the approval dialog — approve, resume,
        // disposition — land the user in the dialog itself, not merely near
        // it. The PlanPanel that owns the milestone consumes the knock.
        if (hold.milestoneId && DIALOG_KINDS.has(hold.kind)) {
          dispatch({ type: 'focusMilestone', milestoneId: hold.milestoneId })
        }
      })
    }
  }

  const acknowledge = async (hold: Hold): Promise<void> => {
    setBusyId(hold.id)
    const updated = await attempt(() => api.ackHold(hold.id))
    setBusyId(null)
    if (updated) dispatch({ type: 'holds', holds: updated })
  }

  const decisions = countActionable(state.holds)

  return (
    <>
      <div className="holds-scrim" onClick={close} />
      <section className="holds-popover" role="dialog" aria-label="Waiting on you">
        <header className="holds-popover__head">
          <strong>Waiting on you</strong>
          <span className="spacer" />
          {decisions > 0 ? (
            <Chip tone="chip--accent">
              {decisions} decision{decisions === 1 ? '' : 's'}
            </Chip>
          ) : (
            <Chip tone="chip--pass">clear</Chip>
          )}
        </header>

        {state.holds.length === 0 ? (
          <Empty
            title="Nothing is waiting on you"
            body="Questions, approvals and stopped runs will queue here — and notify you once, when they appear."
          />
        ) : (
          <ul className="holds-list">
            {state.holds.map((hold) => (
              <li key={hold.id} className="holds-item">
                <div className="holds-item__body">
                  <div className="holds-item__head">
                    <strong>{hold.title}</strong>
                    {hold.mock ? <Chip tone="chip--caution">mock</Chip> : null}
                    <time className="holds-item__time" dateTime={new Date(hold.sinceAt).toISOString()}>
                      {relativeTime(hold.sinceAt)}
                    </time>
                  </div>
                  <p className="holds-item__detail">{hold.detail}</p>
                </div>
                <div className="holds-item__actions">
                  <button className="btn btn--subtle btn--sm" onClick={() => jump(hold)}>
                    Open
                  </button>
                  {!hold.actionable ? (
                    <button
                      className="btn btn--subtle btn--sm"
                      disabled={busyId === hold.id}
                      onClick={() => void acknowledge(hold)}
                    >
                      Acknowledge
                    </button>
                  ) : null}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  )
}
