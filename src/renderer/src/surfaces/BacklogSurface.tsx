import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { BookOpen, FolderGit2, Link2 } from 'lucide-react'
import type { BacklogItem, BacklogItemState, Id, Learning, WorkPlan } from '@shared/domain'
import { api } from '../lib/api'
import { relativeTime, shortPath, statusTone } from '../lib/format'
import { useStore } from '../state'
import { Chip, Empty, Label } from '../components/ui'

/**
 * The per-repository backlog: what Parley's own record says is worth doing.
 *
 * Everything here was filed by something with provenance — a confirmed review
 * finding, an accepted risk, a stow sweep, a completed plan proposing closure —
 * and every column transition is a human act on that record. The one thing
 * this surface never does is decide: proposals wait, closures wait, and the
 * backlog-review hold points here until someone answers.
 */

/** The working states, in lifecycle order. Terminal rows are counted, not shown. */
const COLUMNS: Array<{ state: BacklogItemState; title: string; hint: string }> = [
  { state: 'proposed', title: 'Proposed', hint: 'Drafted by a stow sweep — confirm or discard.' },
  { state: 'open', title: 'Open', hint: 'Confirmed work. Select these when creating a plan.' },
  { state: 'planned', title: 'Planned', hint: 'Riding a plan brief. Completion proposes closure.' },
  {
    state: 'closure-proposed',
    title: 'Closure proposed',
    hint: 'The pipeline says this landed — close it or send it back.',
  },
]

export function BacklogSurface(): ReactNode {
  const { state, dispatch, attempt } = useStore()
  const [repo, setRepo] = useState<string | null>(null)
  const [busyId, setBusyId] = useState<Id | null>(null)
  const [editingBlockers, setEditingBlockers] = useState<Id | null>(null)
  const [plans, setPlans] = useState<WorkPlan[]>([])

  // The holds queue's knock: a backlog-review hold opened this surface on a
  // specific repository. Consume and clear, same contract as focusMilestoneId.
  useEffect(() => {
    if (state.focusBacklogRepo === null) return
    setRepo(state.focusBacklogRepo)
    dispatch({ type: 'focusBacklogRepo', repoPath: null })
  }, [dispatch, state.focusBacklogRepo])

  // Linked-plan status for planned and closure-proposed items. Fetched here
  // rather than held globally: only this surface renders the linkage, and a
  // dead or externally-merged plan is exactly what the status chip exposes.
  // Keyed on the surface too: plan statuses move without any backlog write
  // (a run failing, a retry starting), so every visit re-reads them rather
  // than showing the status as of the last backlog event.
  useEffect(() => {
    if (state.surface !== 'backlog') return
    let cancelled = false
    void attempt(() => api.listPlans()).then((all) => {
      if (all && !cancelled) setPlans(all)
    })
    return () => {
      cancelled = true
    }
  }, [attempt, state.backlogItems, state.surface])

  const repos = useMemo(() => {
    const paths = new Set<string>()
    for (const item of state.backlogItems) paths.add(item.repoPath)
    for (const learning of state.learnings) paths.add(learning.repoPath)
    return [...paths].sort()
  }, [state.backlogItems, state.learnings])

  // A selected repo that lost its last row falls back to the all-repos view
  // rather than filtering forever on nothing.
  useEffect(() => {
    if (repo !== null && !repos.includes(repo)) setRepo(null)
  }, [repo, repos])

  const items = useMemo(
    () => (repo ? state.backlogItems.filter((i) => i.repoPath === repo) : state.backlogItems),
    [repo, state.backlogItems],
  )
  const learnings = useMemo(
    () => (repo ? state.learnings.filter((l) => l.repoPath === repo) : state.learnings),
    [repo, state.learnings],
  )
  const planById = useMemo(() => new Map(plans.map((p) => [p.id, p])), [plans])

  const pendingCount = (path: string): number =>
    state.backlogItems.filter(
      (i) => i.repoPath === path && (i.state === 'proposed' || i.state === 'closure-proposed'),
    ).length

  const act = async (id: Id, work: () => Promise<unknown>): Promise<void> => {
    setBusyId(id)
    await attempt(work)
    setBusyId(null)
  }

  const done = items.filter((i) => i.state === 'done').length
  const dropped = items.filter((i) => i.state === 'dropped').length

  return (
    <div className="workspace">
      <aside className="sidebar">
        <div className="sidebar__header">
          <Label>Repositories</Label>
        </div>
        <div className="scroll-y">
          {repos.length === 0 ? (
            <div style={{ padding: 'var(--s6)' }} className="field__hint">
              Nothing tracked yet. Confirmed review findings and accepted risks file here on their
              own; a session's Stow action drafts more.
            </div>
          ) : (
            <div className="list">
              <button
                className={`list-item ${repo === null ? 'is-active' : ''}`}
                onClick={() => setRepo(null)}
              >
                <div className="list-item__top">
                  <span className="list-item__title">All repositories</span>
                </div>
                <div className="list-item__meta">
                  <span className="tnum">{state.backlogItems.length} items</span>
                </div>
              </button>
              {repos.map((path) => {
                const pending = pendingCount(path)
                return (
                  <button
                    key={path}
                    className={`list-item ${repo === path ? 'is-active' : ''}`}
                    onClick={() => setRepo(path)}
                    title={path}
                  >
                    <div className="list-item__top">
                      <FolderGit2 size={13} strokeWidth={2} />
                      <span className="list-item__title">{shortPath(path)}</span>
                    </div>
                    <div className="list-item__meta">
                      {pending > 0 ? <Chip tone="chip--accent">{pending} to review</Chip> : null}
                      <span className="tnum">
                        {state.backlogItems.filter((i) => i.repoPath === path).length} items
                      </span>
                    </div>
                  </button>
                )
              })}
            </div>
          )}
        </div>
      </aside>

      <main className="main">
        <div className="scroll-y" style={{ padding: 'var(--s5)' }}>
          {items.length === 0 && learnings.length === 0 ? (
            <Empty
              title="The backlog opens from the record"
              body="Run a review and its confirmed findings file here per repository. Accept a risk and it is remembered here. Stow a finished session and the agent's proposals wait here for your confirmation."
            />
          ) : (
            <>
              <div className="backlog-board">
                {COLUMNS.map((column) => {
                  const inColumn = items.filter((item) => item.state === column.state)
                  return (
                    <section className="backlog-col" key={column.state}>
                      <header className="backlog-col__head" title={column.hint}>
                        <Label>{column.title}</Label>
                        <span className="segmented__count tnum">{inColumn.length}</span>
                      </header>
                      {inColumn.map((item) => (
                        <ItemCard
                          key={item.id}
                          item={item}
                          siblings={items}
                          plan={item.planId ? (planById.get(item.planId) ?? null) : null}
                          busy={busyId === item.id}
                          editingBlockers={editingBlockers === item.id}
                          onToggleBlockers={() =>
                            setEditingBlockers(editingBlockers === item.id ? null : item.id)
                          }
                          act={act}
                        />
                      ))}
                    </section>
                  )
                })}
              </div>

              {done + dropped > 0 ? (
                <p className="field__hint" style={{ marginTop: 'var(--s3)' }}>
                  {done} closed and {dropped} dropped item{done + dropped === 1 ? '' : 's'} stay in
                  the record with their full trails; a recurrence files fresh rather than reopening
                  them.
                </p>
              ) : null}

              <LearningsPanel learnings={learnings} busyId={busyId} act={act} />
            </>
          )}
        </div>
      </main>
    </div>
  )
}

function ItemCard({
  item,
  siblings,
  plan,
  busy,
  editingBlockers,
  onToggleBlockers,
  act,
}: {
  item: BacklogItem
  siblings: BacklogItem[]
  plan: WorkPlan | null
  busy: boolean
  editingBlockers: boolean
  onToggleBlockers: () => void
  act: (id: Id, work: () => Promise<unknown>) => Promise<void>
}): ReactNode {
  // Only live siblings in the same repo can block; done/dropped/unknown ids
  // are inert by the store's read rules and would be noise to offer.
  const blockables = siblings.filter(
    (other) =>
      other.id !== item.id &&
      other.repoPath === item.repoPath &&
      ['proposed', 'open', 'planned', 'closure-proposed'].includes(other.state),
  )
  const liveBlockers = item.blockedBy.filter((id) => blockables.some((b) => b.id === id))

  const setBlockers = (next: Id[]): void => {
    void act(item.id, () => api.setBacklogBlockedBy(item.id, next))
  }

  return (
    <article className={`backlog-card ${busy ? 'is-busy' : ''}`}>
      <div className="backlog-card__head">
        <strong className="backlog-card__title">{item.title}</strong>
      </div>
      {item.detail ? <p className="backlog-card__detail">{item.detail}</p> : null}
      <div className="backlog-card__meta">
        {item.mock ? <Chip tone="chip--caution">mock</Chip> : null}
        <Chip tone="chip--mono">{item.source}</Chip>
        {item.priority ? <Chip tone="chip--mono">{item.priority}</Chip> : null}
        {item.evidence.length ? (
          <span className="field__hint">
            {item.evidence.length} ref{item.evidence.length === 1 ? '' : 's'}
          </span>
        ) : null}
        <span className="spacer" />
        <span className="field__hint">{relativeTime(item.createdAt)}</span>
      </div>

      {plan ? (
        <div className="backlog-card__meta">
          <Link2 size={11} strokeWidth={2} />
          <span className="field__hint" title={plan.title}>
            {plan.title.slice(0, 40)}
          </span>
          <Chip tone={statusTone(plan.status).tone}>{statusTone(plan.status).label}</Chip>
        </div>
      ) : item.planId ? (
        // The linked plan row is gone — exactly the dead linkage worth seeing.
        <div className="backlog-card__meta">
          <Link2 size={11} strokeWidth={2} />
          <span className="field__hint">linked plan no longer exists — reopen to unstick</span>
        </div>
      ) : null}

      {liveBlockers.length > 0 && !editingBlockers ? (
        <div className="backlog-card__meta">
          <span className="field__hint">
            blocked by {liveBlockers.length} item{liveBlockers.length === 1 ? '' : 's'}
          </span>
        </div>
      ) : null}

      {editingBlockers ? (
        <div className="backlog-card__blockers">
          {blockables.length === 0 ? (
            <span className="field__hint">Nothing else live in this repository.</span>
          ) : (
            blockables.map((other) => (
              <label key={other.id} className="backlog-pick__row">
                <input
                  type="checkbox"
                  checked={item.blockedBy.includes(other.id)}
                  onChange={() =>
                    setBlockers(
                      item.blockedBy.includes(other.id)
                        ? item.blockedBy.filter((id) => id !== other.id)
                        : [...item.blockedBy, other.id],
                    )
                  }
                />
                <span className="backlog-pick__title">{other.title}</span>
              </label>
            ))
          )}
        </div>
      ) : null}

      <div className="backlog-card__actions">
        {item.state === 'proposed' ? (
          <>
            <button
              className="btn btn--sm"
              disabled={busy}
              onClick={() => void act(item.id, () => api.confirmBacklogItem(item.id))}
            >
              Confirm
            </button>
            <button
              className="btn btn--subtle btn--sm"
              disabled={busy}
              onClick={() => void act(item.id, () => api.dropBacklogItem(item.id, 'Discarded at triage.'))}
            >
              Discard
            </button>
          </>
        ) : null}
        {item.state === 'open' ? (
          <>
            <button className="btn btn--subtle btn--sm" onClick={onToggleBlockers}>
              {editingBlockers ? 'Done' : 'Blocked by…'}
            </button>
            <button
              className="btn btn--subtle btn--sm"
              disabled={busy}
              onClick={() => void act(item.id, () => api.dropBacklogItem(item.id))}
            >
              Drop
            </button>
          </>
        ) : null}
        {item.state === 'planned' ? (
          <button
            className="btn btn--subtle btn--sm"
            disabled={busy}
            title="Clears the plan linkage and returns the item to the open column"
            onClick={() => void act(item.id, () => api.reopenBacklogItem(item.id))}
          >
            Reopen
          </button>
        ) : null}
        {item.state === 'closure-proposed' ? (
          <>
            <button
              className="btn btn--sm"
              disabled={busy}
              onClick={() => void act(item.id, () => api.closeBacklogItem(item.id))}
            >
              Close
            </button>
            <button
              className="btn btn--subtle btn--sm"
              disabled={busy}
              title="The work did not actually resolve this — send it back to open"
              onClick={() => void act(item.id, () => api.reopenBacklogItem(item.id))}
            >
              Reopen
            </button>
          </>
        ) : null}
      </div>
    </article>
  )
}

/**
 * The prose record: what sessions taught, curated by hand. Confirmed learnings
 * ride every new plan brief for their repository (newest first, capped at
 * render), so retiring one here is what stops it from being repeated forever.
 */
function LearningsPanel({
  learnings,
  busyId,
  act,
}: {
  learnings: Learning[]
  busyId: Id | null
  act: (id: Id, work: () => Promise<unknown>) => Promise<void>
}): ReactNode {
  const live = learnings.filter((l) => l.state !== 'retired')
  const retired = learnings.length - live.length
  if (!learnings.length) return null

  return (
    <section className="panel" style={{ marginTop: 'var(--s5)' }}>
      <header className="panel__header">
        <BookOpen size={13} strokeWidth={2} />
        <Label>Learnings</Label>
        <span className="spacer" />
        {retired > 0 ? <span className="field__hint">{retired} retired</span> : null}
      </header>
      <div className="panel__body">
        {live.length === 0 ? (
          <span className="field__hint">
            Nothing live. Stow a finished session to draft learnings from it.
          </span>
        ) : (
          <ul className="backlog-learnings">
            {live.map((learning) => (
              <li key={learning.id} className="backlog-learnings__row">
                <span className="backlog-learnings__text">{learning.text}</span>
                {learning.mock ? <Chip tone="chip--caution">mock</Chip> : null}
                {learning.state === 'proposed' ? (
                  <Chip tone="chip--accent">proposed</Chip>
                ) : (
                  <Chip tone="chip--pass">riding briefs</Chip>
                )}
                <span className="field__hint">{relativeTime(learning.createdAt)}</span>
                {learning.state === 'proposed' ? (
                  <button
                    className="btn btn--sm"
                    disabled={busyId === learning.id}
                    onClick={() => void act(learning.id, () => api.confirmLearning(learning.id))}
                  >
                    Confirm
                  </button>
                ) : null}
                <button
                  className="btn btn--subtle btn--sm"
                  disabled={busyId === learning.id}
                  onClick={() => void act(learning.id, () => api.retireLearning(learning.id))}
                >
                  Retire
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
