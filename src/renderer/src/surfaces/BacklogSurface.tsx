import { useEffect, useMemo, useState, type ReactNode } from 'react'
import { BookOpen, FolderGit2, HardHat, Link2 } from 'lucide-react'
import type {
  AgentConfig,
  BacklogItem,
  BacklogItemState,
  ForemanProposal,
  Id,
  Learning,
  Session,
  WorkPlan,
} from '@shared/domain'
import { api } from '../lib/api'
import { compactNumber, relativeTime, shortPath, statusTone } from '../lib/format'
import { useStore, type RepoTab } from '../state'
import { AgentPicker } from '../components/AgentPicker'
import { NewPlanDialog } from '../components/PlanPanel'
import { Chip, Empty, Label, Spinner } from '../components/ui'

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
  const { state, dispatch, attempt, notify } = useStore()
  const [repo, setRepo] = useState<string | null>(null)
  // The per-repo tab, defaulting to Overview. Selecting a different repo
  // resets it — the tab is a place within a repo, not a global mode.
  const [activeTab, setActiveTab] = useState<RepoTab>('overview')
  const selectRepo = (path: string | null): void => {
    setRepo(path)
    setActiveTab('overview')
  }
  const [busyId, setBusyId] = useState<Id | null>(null)
  const [editingBlockers, setEditingBlockers] = useState<Id | null>(null)
  const [plans, setPlans] = useState<WorkPlan[]>([])
  const [proposals, setProposals] = useState<ForemanProposal[]>([])
  const [foremanBusy, setForemanBusy] = useState(false)
  const [acceptTarget, setAcceptTarget] = useState<{
    proposal: ForemanProposal
    session: Session
  } | null>(null)

  // The holds queue's knock: a repo-scoped hold opened this surface on a
  // specific repository — and on the exact tab that carries its control.
  // Consume and clear, same contract as focusMilestoneId.
  useEffect(() => {
    if (state.focusBacklogRepo === null) return
    setRepo(state.focusBacklogRepo)
    setActiveTab(state.focusRepoTab ?? 'overview')
    dispatch({ type: 'focusBacklogRepo', repoPath: null })
  }, [dispatch, state.focusBacklogRepo, state.focusRepoTab])

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
    // Proposals ride the same refetch rhythm: every foreman write emits
    // backlog.changed, which refreshes state.backlogItems, which re-runs this.
    void attempt(() => api.listForemanProposals()).then((all) => {
      if (all && !cancelled) setProposals(all)
    })
    return () => {
      cancelled = true
    }
  }, [attempt, state.backlogItems, state.surface])

  // Supersede racing the open dialog: if the proposal being accepted stops
  // being the pending one — a newer run replaced it, or it was decided
  // elsewhere — close the dialog with a notice rather than letting the
  // create refuse half a form later (the stale-milestone-dialog precedent).
  useEffect(() => {
    if (!acceptTarget) return
    const stillPending = proposals.some(
      (p) => p.id === acceptTarget.proposal.id && p.state === 'proposed',
    )
    if (!stillPending) {
      setAcceptTarget(null)
      notify('warn', 'That foreman proposal changed while the dialog was open — review the fresh one.')
    }
  }, [proposals, acceptTarget, notify])

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

  const askForeman = async (cfg: AgentConfig): Promise<void> => {
    if (!repo) return
    setForemanBusy(true)
    await attempt(() => api.runForeman(repo, cfg))
    setForemanBusy(false)
  }

  const acceptProposal = async (proposal: ForemanProposal): Promise<void> => {
    if (!proposal.anchorSessionId) {
      notify('error', 'This proposal has no anchor session — reject it or re-run the foreman.')
      return
    }
    const detail = await attempt(() => api.getSession(proposal.anchorSessionId as Id))
    if (!detail) {
      // attempt already surfaced the error; name the way out.
      notify('error', 'The anchor session is gone — reject this proposal or re-run the foreman.')
      return
    }
    setAcceptTarget({ proposal, session: detail.session })
  }

  const pendingFor = (path: string): ForemanProposal | null =>
    proposals.find(
      (p) => p.repoPath === path && p.state === 'proposed' && p.mock === state.mock,
    ) ?? null

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
                onClick={() => selectRepo(null)}
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
                    onClick={() => selectRepo(path)}
                    title={path}
                  >
                    <div className="list-item__top">
                      <FolderGit2 size={13} strokeWidth={2} />
                      <span className="list-item__title">{shortPath(path)}</span>
                    </div>
                    <div className="list-item__meta">
                      {pendingFor(path) ? <Chip tone="chip--accent">proposal</Chip> : null}
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
              {/* Tabs exist only within a repository — the all-repos view is
                  the cross-repo triage board it has always been. */}
              {repo ? (
                <div className="repo-tabs" role="tablist" aria-label="Repository tabs">
                  {(
                    [
                      ['overview', 'Overview'],
                      ['backlog', 'Backlog'],
                      ['learnings', 'Learnings'],
                    ] as Array<[RepoTab, string]>
                  ).map(([tab, label]) => (
                    <button
                      key={tab}
                      role="tab"
                      aria-selected={activeTab === tab}
                      className={activeTab === tab ? 'repo-tabs__tab is-active' : 'repo-tabs__tab'}
                      onClick={() => setActiveTab(tab)}
                    >
                      {label}
                      {tab === 'backlog' && pendingCount(repo) > 0 ? (
                        <span className="segmented__count tnum">{pendingCount(repo)}</span>
                      ) : null}
                    </button>
                  ))}
                </div>
              ) : null}

              {repo && activeTab === 'overview' ? (
                <ForemanPanel
                  repo={repo}
                  items={items}
                  proposals={proposals.filter((p) => p.repoPath === repo)}
                  mock={state.mock}
                  busy={foremanBusy}
                  onRun={askForeman}
                  onAccept={acceptProposal}
                  onReject={(id, note) =>
                    act(id, () => api.rejectForemanProposal(id, note))
                  }
                />
              ) : null}

              {!repo || activeTab === 'backlog' ? (
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
              </>
              ) : null}

              {!repo || activeTab === 'learnings' ? (
                <LearningsPanel learnings={learnings} busyId={busyId} act={act} />
              ) : null}
            </>
          )}
        </div>
      </main>

      {acceptTarget ? (
        <NewPlanDialog
          session={acceptTarget.session}
          foremanProposalId={acceptTarget.proposal.id}
          initialRepoPath={acceptTarget.proposal.repoPath}
          initialItems={acceptTarget.proposal.itemIds}
          initialIsolation={acceptTarget.proposal.isolation}
          initialNote={
            acceptTarget.proposal.note
              ? `From the foreman’s proposal: ${acceptTarget.proposal.note}`
              : ''
          }
          onClose={() => setAcceptTarget(null)}
          onCreated={() => {
            notify('info', 'Proposal accepted — the plan is drafting. Its items are now planned.')
          }}
        />
      ) : null}
    </div>
  )
}

/**
 * The foreman's corner of the surface: at most one pending proposal per
 * repository per mode, the running state while a read is in flight, and the
 * way to ask for one. Everything renders from the record — selected and
 * deferred items resolve to their live titles, and drift since the read is
 * said out loud rather than discovered at accept.
 */
function ForemanPanel({
  repo,
  items,
  proposals,
  mock,
  busy,
  onRun,
  onAccept,
  onReject,
}: {
  repo: string
  items: BacklogItem[]
  proposals: ForemanProposal[]
  mock: boolean
  busy: boolean
  onRun: (cfg: AgentConfig) => Promise<void>
  onAccept: (proposal: ForemanProposal) => Promise<void>
  onReject: (id: Id, note: string) => Promise<void>
}): ReactNode {
  const [askOpen, setAskOpen] = useState(false)
  const [cfg, setCfg] = useState<AgentConfig>({
    vendor: 'claude',
    model: '',
    effort: 'high',
    persona: '',
  })
  const [rejecting, setRejecting] = useState(false)
  const [rejectNote, setRejectNote] = useState('')

  const pending = proposals.find((p) => p.state === 'proposed' && p.mock === mock) ?? null
  const running = proposals.find((p) => p.state === 'running' && p.mock === mock) ?? null
  const lastDecided = proposals
    .filter((p) => !['proposed', 'running'].includes(p.state) && p.mock === mock)
    .sort((a, b) => (b.decidedAt ?? b.createdAt) - (a.decidedAt ?? a.createdAt))[0]

  const itemById = new Map(items.map((item) => [item.id, item]))
  const liveOpen = items.filter((item) => item.state === 'open' && item.mock === mock)
  const surviving = pending
    ? pending.itemIds.filter((id) => itemById.get(id)?.state === 'open')
    : []
  const arrivedSince = pending
    ? liveOpen.filter((item) => !pending.openSnapshot.includes(item.id))
    : []
  const arrivedTop = [...arrivedSince]
    .map((item) => item.priority)
    .filter((p): p is NonNullable<typeof p> => p !== null)
    .sort()[0]

  const resolveTitle = (id: Id): { title: string; open: boolean } => {
    const item = itemById.get(id)
    if (!item) return { title: 'an item no longer in this repository', open: false }
    return { title: item.title, open: item.state === 'open' }
  }

  return (
    <section className="panel foreman-panel">
      <header className="panel__header">
        <HardHat size={13} strokeWidth={2} />
        <Label>Foreman</Label>
        {pending?.mock ? <Chip tone="chip--caution">mock</Chip> : null}
        <span className="spacer" />
        {busy || running ? (
          <span className="row row--tight">
            <Spinner /> <span className="field__hint">reading the backlog…</span>
          </span>
        ) : (
          <button className="btn btn--subtle btn--sm" onClick={() => setAskOpen(!askOpen)}>
            Ask the foreman
          </button>
        )}
      </header>
      <div className="panel__body">
        {askOpen && !busy && !running ? (
          <div className="foreman-ask">
            <AgentPicker label="Foreman — reads the backlog, proposes, never decides" value={cfg} onChange={setCfg} />
            <div className="row">
              <button
                className="btn btn--primary btn--sm"
                onClick={() => {
                  setAskOpen(false)
                  void onRun(cfg)
                }}
              >
                Run one read
              </button>
              <span className="field__hint">
                One read-only turn over {liveOpen.length} open item
                {liveOpen.length === 1 ? '' : 's'}. The proposal waits for you.
              </span>
            </div>
          </div>
        ) : null}

        {pending ? (
          <article className="foreman-proposal">
            <div className="backlog-card__head">
              <strong className="backlog-card__title">{pending.title}</strong>
            </div>
            <div className="backlog-card__meta">
              <Chip tone="chip--mono">{pending.isolation}</Chip>
              <Chip tone="chip--mono">{pending.vendor}</Chip>
              <span className="field__hint tnum">
                {compactNumber(pending.usage.inputTokens)} in ·{' '}
                {compactNumber(pending.usage.outputTokens)} out
              </span>
              <span className="spacer" />
              <span className="field__hint">{relativeTime(pending.createdAt)}</span>
            </div>
            {pending.rationale ? (
              <p className="backlog-card__detail foreman-proposal__rationale">{pending.rationale}</p>
            ) : null}

            <div className="foreman-proposal__items">
              <Label>Selected</Label>
              <ul>
                {pending.itemIds.map((id) => {
                  const resolved = resolveTitle(id)
                  return (
                    <li key={id} className={resolved.open ? '' : 'is-gone'}>
                      {resolved.title}
                      {!resolved.open ? (
                        <Chip tone="chip--caution">no longer open</Chip>
                      ) : null}
                    </li>
                  )
                })}
              </ul>
              {pending.deferred.length ? (
                <>
                  <Label>Deferred</Label>
                  <ul>
                    {pending.deferred.map((entry) => (
                      <li key={entry.itemId} className="foreman-proposal__deferred">
                        {resolveTitle(entry.itemId).title}
                        {entry.reason ? (
                          <span className="field__hint"> — {entry.reason}</span>
                        ) : null}
                      </li>
                    ))}
                  </ul>
                </>
              ) : null}
            </div>

            {arrivedSince.length ? (
              <p className="field__hint foreman-proposal__stale">
                {arrivedSince.length} item{arrivedSince.length === 1 ? '' : 's'} arrived after
                this proposal{arrivedTop ? `, including one ${arrivedTop}` : ''} — it was read
                against an older backlog.
              </p>
            ) : null}
            {pending.decisionNote ? (
              <p className="field__hint">{pending.decisionNote}</p>
            ) : null}

            {rejecting ? (
              <div className="row">
                <input
                  className="input"
                  placeholder="Why not — recorded on the proposal"
                  value={rejectNote}
                  onChange={(e) => setRejectNote(e.target.value)}
                />
                <button
                  className="btn btn--sm"
                  onClick={() => {
                    setRejecting(false)
                    void onReject(pending.id, rejectNote.trim())
                    setRejectNote('')
                  }}
                >
                  Reject it
                </button>
                <button className="btn btn--subtle btn--sm" onClick={() => setRejecting(false)}>
                  Keep it
                </button>
              </div>
            ) : (
              <div className="backlog-card__actions">
                <button
                  className="btn btn--sm"
                  disabled={surviving.length === 0}
                  title={
                    surviving.length === 0
                      ? 'None of the selected items is still open — reject or re-run'
                      : 'Opens the plan dialog prefilled; creating the plan is the acceptance'
                  }
                  onClick={() => void onAccept(pending)}
                >
                  Accept into a plan
                </button>
                <button className="btn btn--subtle btn--sm" onClick={() => setRejecting(true)}>
                  Reject…
                </button>
              </div>
            )}
          </article>
        ) : !running ? (
          <span className="field__hint">
            No proposal waiting. Ask the foreman for one read of {shortPath(repo)}&apos;s open
            backlog{lastDecided ? ` — last one ${lastDecided.state} ${relativeTime(lastDecided.decidedAt ?? lastDecided.createdAt)}${lastDecided.state === 'failed' && lastDecided.decisionNote ? ` (${lastDecided.decisionNote})` : ''}` : ''}.
          </span>
        ) : null}
      </div>
    </section>
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
