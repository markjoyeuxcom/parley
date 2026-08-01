import { useEffect, useState, type ReactNode } from 'react'
import { Inbox } from 'lucide-react'
import type { Hold } from '@shared/holds'
import { api } from '../lib/api'
import { countActionable } from '../lib/holdsState'
import { relativeTime } from '../lib/format'
import { useStore } from '../state'
import { Chip, Empty } from './ui'

/** Hold kinds whose exact control is the milestone's approval dialog. */
const DIALOG_KINDS = new Set<Hold['kind']>([
  'approval-waiting',
  'ledger-gated',
  'milestone-failed',
  // The retry control is the same one, and it is the right destination even
  // though the fix is elsewhere: the reason is on the milestone, and this is
  // where you come back to once the machine is sorted out.
  'milestone-parked',
])

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
/**
 * The jump to a hold's exact control, shared by the queue popover and the
 * Repos Overview's waiting card — one routing table, two doors.
 */
export function useHoldJump(): (hold: Hold) => void {
  const { dispatch, openSession, openPlan, openLoop } = useStore()
  return (hold: Hold): void => {
    // The self-update controls live inline in the holds panel itself (m4), so
    // both doors — the popover chip and the Repos WaitingCard — route there.
    // Without this branch the interim state would fall through to the session
    // arm and dead-end: the hold carries no sessionId.
    if (hold.kind === 'self-update') {
      dispatch({ type: 'holdsPanel', open: true })
      return
    }
    // Backlog and foreman holds are repository-scoped: the control is the
    // Repos surface, opened on the repo whose proposals wait — and on the
    // exact tab that carries the control.
    if (hold.kind === 'backlog-review' || hold.kind === 'foreman-proposal') {
      dispatch({
        type: 'focusBacklogRepo',
        repoPath: hold.repoPath,
        tab: hold.kind === 'backlog-review' ? 'backlog' : 'overview',
      })
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
}

export function HoldsPopover(): ReactNode {
  const { state, dispatch, attempt } = useStore()
  const jumpToHold = useHoldJump()
  const [busyId, setBusyId] = useState<string | null>(null)
  // The self-update confirm, bound to the row id resolved at click time — the
  // hold's identity hashes the id away, so the offer is re-fetched rather
  // than remembered, and a superseded chip can never relaunch a stale build.
  const [relaunchConfirm, setRelaunchConfirm] = useState<{
    holdId: string
    updateId: string
  } | null>(null)

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
    jumpToHold(hold)
  }

  const acknowledge = async (hold: Hold): Promise<void> => {
    setBusyId(hold.id)
    const updated = await attempt(() => api.ackHold(hold.id))
    setBusyId(null)
    if (updated) dispatch({ type: 'holds', holds: updated })
  }

  const refreshHolds = async (): Promise<void> => {
    const holds = await attempt(() => api.listHolds())
    if (holds) dispatch({ type: 'holds', holds })
  }

  const beginRelaunch = async (hold: Hold): Promise<void> => {
    setBusyId(hold.id)
    const pending = await attempt(() => api.getPendingSelfUpdate())
    setBusyId(null)
    if (!pending) {
      // The offer vanished under the chip (decided elsewhere, or a newer
      // landing's gate is mid-run); show the truth instead of confirming
      // against a ghost.
      await refreshHolds()
      return
    }
    setRelaunchConfirm({ holdId: hold.id, updateId: pending.id })
  }

  const confirmRelaunch = async (updateId: string): Promise<void> => {
    setBusyId(updateId)
    // On success the app quits out from under this call; reaching the lines
    // below normally means a refusal, which attempt() surfaced already.
    await attempt(() => api.relaunchSelfUpdate(updateId))
    setBusyId(null)
    setRelaunchConfirm(null)
    await refreshHolds()
  }

  const declineUpdate = async (hold: Hold): Promise<void> => {
    setBusyId(hold.id)
    const pending = await attempt(() => api.getPendingSelfUpdate())
    if (pending) await attempt(() => api.declineSelfUpdate(pending.id))
    setBusyId(null)
    setRelaunchConfirm(null)
    await refreshHolds()
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
                  {relaunchConfirm?.holdId === hold.id ? (
                    <div className="holds-item__confirm">
                      <p className="holds-item__detail">
                        This quits Parley and starts the freshly built version.
                        Running panes close, and the terminal that ran{' '}
                        <code>npm run dev</code> ends.
                      </p>
                      <div className="holds-item__actions">
                        <button
                          className="btn btn--primary btn--sm"
                          disabled={busyId === relaunchConfirm.updateId}
                          onClick={() => void confirmRelaunch(relaunchConfirm.updateId)}
                        >
                          Quit and relaunch
                        </button>
                        <button
                          className="btn btn--subtle btn--sm"
                          onClick={() => setRelaunchConfirm(null)}
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  ) : null}
                </div>
                <div className="holds-item__actions">
                  {hold.kind === 'self-update' ? (
                    // The controls ARE this row — jumping anywhere else would
                    // land on a surface that has none.
                    <>
                      <button
                        className="btn btn--primary btn--sm"
                        disabled={busyId === hold.id || relaunchConfirm !== null}
                        onClick={() => void beginRelaunch(hold)}
                      >
                        Relaunch
                      </button>
                      <button
                        className="btn btn--subtle btn--sm"
                        disabled={busyId === hold.id}
                        onClick={() => void declineUpdate(hold)}
                      >
                        Not now
                      </button>
                    </>
                  ) : (
                    <button className="btn btn--subtle btn--sm" onClick={() => jump(hold)}>
                      Open
                    </button>
                  )}
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
