import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { Archive, ArchiveRestore, ChevronDown, ChevronRight, Hammer, Layers, Pause, Play, Plus, Send, Square, Trash2 } from 'lucide-react'
import type { AgentConfig, Id, InterjectionTarget, Session, Turn } from '@shared/domain'
import { api } from '../lib/api'
import { firstLine, formatTokens, relativeTime, seatLabel, seatSide, shortPath, statusTone, VENDOR_LABEL } from '../lib/format'
import { groupSessions, recentProjects, type SessionGrouping } from '../lib/sessionGroups'
import { useStore } from '../state'
import { DeleteSessionDialog } from '../components/DeleteSessionDialog'
import { FindingsLedgerPanel } from '../components/FindingsLedgerPanel'
import { NewSessionDialog } from '../components/NewSessionDialog'
import { NewPlanDialog, PlanPanel } from '../components/PlanPanel'
import { FindingsPanel, VerdictPanel } from '../components/VerdictPanel'
import { Chip, Dot, Empty, Label, Menu, MenuItem, MenuSection, Spinner } from '../components/ui'

export function ParleySurface(): ReactNode {
  const { state, dispatch, openSession, refreshSessions, attempt, notify } = useStore()
  const [showNew, setShowNew] = useState(false)
  // Grouping and folds are a view preference, not a record: they live with
  // the surface and reset with the window, like every other view state here.
  const [grouping, setGrouping] = useState<SessionGrouping>('none')
  const [collapsed, setCollapsed] = useState<ReadonlySet<string>>(new Set())
  const [pendingDelete, setPendingDelete] = useState<Session | null>(null)

  const archive = async (session: Session): Promise<void> => {
    const next = session.archivedAt === null
    const done = await attempt(() => api.archiveSession(session.id, next))
    if (!done) return
    // Archiving what is currently open would leave a detail pane for a session
    // no longer in the list beside it.
    if (next && state.activeSessionId === session.id) {
      dispatch({ type: 'activeSession', sessionId: null })
    }
    await refreshSessions()
    notify('info', next ? 'Archived. Nothing was deleted — restore it any time.' : 'Restored.')
  }

  const toggleArchived = async (): Promise<void> => {
    const next = !state.showArchived
    dispatch({ type: 'showArchived', showArchived: next })
    await refreshSessions(next)
  }

  return (
    <div className="workspace">
      <aside className="sidebar">
        <div className="sidebar__header">
          <Label>Sessions</Label>
          <span className="spacer" />
          <Menu
            title="Group sessions"
            label={
              <>
                <Layers size={12} strokeWidth={2} />
                {grouping === 'none' ? 'Flat' : grouping === 'project' ? 'Project' : 'Repo'}
              </>
            }
          >
            {(close) => (
              <MenuSection>
                {(
                  [
                    ['none', 'No grouping — newest first'],
                    ['project', 'By project'],
                    ['repository', 'By repository'],
                  ] as Array<[SessionGrouping, string]>
                ).map(([value, label]) => (
                  <MenuItem
                    key={value}
                    selected={grouping === value}
                    onClick={() => {
                      close()
                      setGrouping(value)
                    }}
                  >
                    {label}
                  </MenuItem>
                ))}
              </MenuSection>
            )}
          </Menu>
          <button className="btn btn--subtle btn--icon btn--sm" onClick={() => setShowNew(true)} title="New session">
            <Plus size={13} strokeWidth={2} />
          </button>
        </div>

        <div className="scroll-y">
          {state.sessions.length === 0 ? (
            <div style={{ padding: 'var(--s6)' }} className="field__hint">
              No sessions yet. Put a decision to two CLIs and keep the record.
            </div>
          ) : (
            <div className="list">
              {groupSessions(state.sessions, grouping).map((group) => {
                const folded = collapsed.has(group.key)
                return (
                  <div key={group.key}>
                    {group.title ? (
                      <button
                        className="list-group__header"
                        onClick={() =>
                          setCollapsed((current) => {
                            const next = new Set(current)
                            if (next.has(group.key)) next.delete(group.key)
                            else next.add(group.key)
                            return next
                          })
                        }
                      >
                        {folded ? (
                          <ChevronRight size={11} strokeWidth={2} />
                        ) : (
                          <ChevronDown size={11} strokeWidth={2} />
                        )}
                        <span className="list-group__title">{group.title}</span>
                        <span className="dimmer tnum">{group.sessions.length}</span>
                      </button>
                    ) : null}
                    {folded
                      ? null
                      : group.sessions.map((session) => (
                          <SessionRow
                            key={session.id}
                            session={session}
                            active={session.id === state.activeSessionId}
                            onOpen={() => void openSession(session.id)}
                            onArchive={() => void archive(session)}
                            onDelete={() => setPendingDelete(session)}
                          />
                        ))}
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* Only offered once something is actually hidden — an control that
            reveals nothing is just noise in the corner. */}
        {state.archivedCount > 0 ? (
          <button className="sidebar__footer-btn" onClick={() => void toggleArchived()}>
            {state.showArchived
              ? 'Hide archived'
              : `Show ${state.archivedCount} archived`}
          </button>
        ) : null}
      </aside>

      <div className="pane-column">
        {state.activeSessionId ? (
          <SessionView key={state.activeSessionId} />
        ) : (
          <Empty
            title="Nothing selected"
            body="Open a past session, or start a new one. Two CLIs from different model families argue to a scored verdict, and you keep the transcript, the dissent and the report."
            action={
              <button className="btn btn--primary" onClick={() => setShowNew(true)}>
                <Plus size={12} strokeWidth={2} />
                New session
              </button>
            }
          />
        )}
      </div>

      {showNew ? (
        <NewSessionDialog
          onClose={() => setShowNew(false)}
          onStarted={(session) => {
            dispatch({ type: 'surface', surface: 'parley' })
            void refreshSessions()
            void openSession(session.id)
          }}
        />
      ) : null}

      {pendingDelete ? (
        <DeleteSessionDialog
          session={pendingDelete}
          onClose={() => setPendingDelete(null)}
          onDeleted={() => {
            const gone = pendingDelete.id
            setPendingDelete(null)
            if (state.activeSessionId === gone) dispatch({ type: 'activeSession', sessionId: null })
            void refreshSessions()
          }}
        />
      ) : null}
    </div>
  )
}

function SessionRow({
  session,
  active,
  onOpen,
  onArchive,
  onDelete,
}: {
  session: Session
  active: boolean
  onOpen: () => void
  onArchive: () => void
  onDelete: () => void
}): ReactNode {
  const tone = statusTone(session.status)
  const live = session.status === 'running'
  const archived = session.archivedAt !== null

  return (
    // A wrapper, because the row itself is a button and a button cannot contain
    // one. The control is overlaid and revealed on hover or keyboard focus.
    <div className="list-row">
      <button className={`list-item ${active ? 'is-active' : ''}`} onClick={onOpen}>
        <div className="list-item__top">
          {live ? <Dot tone="dot--live" /> : <Dot tone={tone.tone.replace('chip--', 'dot--')} />}
          <span className="list-item__title">{firstLine(session.matter, 64)}</span>
        </div>
        <div className="list-item__meta">
          {session.mock ? <Chip tone="chip--caution">mock</Chip> : null}
          {archived ? <Chip>archived</Chip> : null}
          <span>{session.kind === 'review' ? 'Review' : 'Debate'}</span>
          <span>·</span>
          <span>{relativeTime(session.createdAt)}</span>
          {session.project ? (
            <>
              <span>·</span>
              <span className="truncate">{session.project}</span>
            </>
          ) : null}
        </div>
      </button>

      {live ? null : (
        <div className="list-row__actions">
          {/* Delete is offered only once archived. Two deliberate steps, so
              nothing is destroyed by one stray click while scrolling. */}
          {archived ? (
            <button
              className="list-row__action list-row__action--danger"
              onClick={onDelete}
              title="Delete permanently"
              aria-label="Delete session permanently"
            >
              <Trash2 size={12} strokeWidth={2} />
            </button>
          ) : null}
          <button
            className="list-row__action"
            onClick={onArchive}
            title={archived ? 'Restore to the list' : 'Archive — hides it, keeps the record'}
            aria-label={archived ? 'Restore session' : 'Archive session'}
          >
            {archived ? <ArchiveRestore size={12} strokeWidth={2} /> : <Archive size={12} strokeWidth={2} />}
          </button>
        </div>
      )}
    </div>
  )
}

function SessionView(): ReactNode {
  const { state, attempt, notify, openPlan, dispatch } = useStore()
  const detail = state.sessionDetail
  const [showPlan, setShowPlan] = useState(false)
  // The exchange region's fold. Null = automatic: open while the session is
  // live (the stream is the main event), folded once it settles with an
  // outcome (the record and the work are what gets acted on). A click makes
  // the choice explicit; switching sessions returns to automatic. Hooks live
  // ABOVE the !detail return — a hook below a conditional return crashes the
  // renderer the moment the branch flips, which is exactly what it did.
  const [exchangeOpen, setExchangeOpen] = useState<boolean | null>(null)
  useEffect(() => setExchangeOpen(null), [state.activeSessionId])

  if (!detail) {
    return (
      <div className="empty">
        <Spinner />
      </div>
    )
  }

  const { session, turns, verdict, findings, ledger, plans } = detail
  const tone = statusTone(session.status)
  const running = session.status === 'running'
  const paused = session.status === 'paused'
  const active = running || paused || session.status === 'stopping'

  // The open plan, but only when it belongs to THIS session. Both surfaces
  // share the planDetail slot, and without the ownership check a plan opened
  // from Repos would render into whatever session is on screen — gated by
  // that session's ledger, which is the wrong gate entirely.
  const ownPlanDetail =
    state.planDetail && state.planDetail.plan.sessionId === session.id ? state.planDetail : null

  /** Whether there is anything to put in the inspector column yet. */
  const hasOutcome = Boolean(
    verdict || findings.length || ledger.length || plans.length || ownPlanDetail,
  )
  const exchangeVisible = exchangeOpen ?? (active || !hasOutcome)
  const exchangeFolded = !exchangeVisible

  const exportReport = async (): Promise<void> => {
    const result = await attempt(() => api.exportReport(session.id))
    if (result?.saved && result.path) notify('info', `Saved to ${result.path}`)
  }

  const stow = async (): Promise<void> => {
    const result = await attempt(() => api.stowSession(session.id))
    if (!result) return
    const parts: string[] = []
    if (result.filedItems) {
      parts.push(`${result.filedItems} item${result.filedItems === 1 ? '' : 's'} proposed`)
    }
    if (result.filedLearnings) {
      parts.push(`${result.filedLearnings} learning${result.filedLearnings === 1 ? '' : 's'} proposed`)
    }
    if (result.duplicates) parts.push(`${result.duplicates} already tracked`)
    notify(
      'info',
      parts.length
        ? `Stowed: ${parts.join(', ')}. Nothing counts until you confirm it.`
        : 'Nothing new to stow — everything worth keeping is already recorded.',
    )
  }

  return (
    <>
      <div className="bar">
        <Chip tone={tone.tone}>{tone.label}</Chip>
        {session.mock ? (
          <Chip tone="chip--caution" title="Produced by the mock adapters — not real work">
            mock
          </Chip>
        ) : null}
        <span className="truncate" style={{ fontSize: 'var(--text-small)', fontWeight: 530, minWidth: 0 }}>
          {firstLine(session.matter, 110)}
        </span>
        <div className="spacer" />

        {session.repoPath ? (
          // The chip is also the door back: the repository view holds
          // everything else this session is connected to.
          <button
            className="chip chip--mono"
            title={`${session.repoPath} — open in Repositories`}
            onClick={() => {
              dispatch({ type: 'surface', surface: 'backlog' })
              dispatch({ type: 'focusBacklogRepo', repoPath: session.repoPath, tab: 'sessions' })
            }}
          >
            {shortPath(session.repoPath)}
          </button>
        ) : (
          <Chip title="No repository attached — both sides run tool-free">no repo</Chip>
        )}
        <span className="dimmer tnum" style={{ fontSize: 'var(--text-tiny)' }}>
          {formatTokens(session.usage)}
        </span>

        {active ? (
          <>
            {running ? (
              <button
                className="btn btn--sm"
                onClick={() => void attempt(() => api.pauseSession(session.id))}
                title="Pause at the next turn boundary"
              >
                <Pause size={12} strokeWidth={2} />
                Pause
              </button>
            ) : paused ? (
              <button className="btn btn--sm" onClick={() => void attempt(() => api.resumeSession(session.id))}>
                <Play size={12} strokeWidth={2} />
                Resume
              </button>
            ) : null}
            <button
              className="btn btn--sm btn--danger"
              onClick={() => void attempt(() => api.stopSession(session.id))}
              title="Kill the in-flight turn now"
            >
              <Square size={11} strokeWidth={2.5} />
              Stop
            </button>
          </>
        ) : null}

        {/* Available even once a plan exists: a plan can go stale, and the
            verdict is the durable artifact worth replanning from. */}
        {verdict ? (
          <button
            className="btn btn--sm"
            onClick={() => setShowPlan(true)}
            title={plans.length ? 'Draft another plan from this verdict' : 'Turn this verdict into audited work'}
          >
            <Hammer size={12} strokeWidth={2} />
            {plans.length ? 'New plan' : 'Plan work'}
          </button>
        ) : null}
      </div>

      <div
        className={`session__body ${hasOutcome ? 'session__body--split' : ''} ${
          hasOutcome && plans.length ? 'session__body--work' : ''
        } ${exchangeFolded ? 'session__body--folded' : ''}`}
      >
        <div className="session__main">
          {!active && hasOutcome ? (
            <button
              className="exchange-bar"
              onClick={() => setExchangeOpen(exchangeFolded)}
              aria-expanded={exchangeVisible}
            >
              {exchangeVisible ? (
                <ChevronDown size={13} strokeWidth={2} />
              ) : (
                <ChevronRight size={13} strokeWidth={2} />
              )}
              <span className="exchange-bar__title">Exchange</span>
              <span className="dimmer">
                {turns.length} turn{turns.length === 1 ? '' : 's'} · settled record
              </span>
              <span className="spacer" />
              <span className="dimmer">{exchangeVisible ? 'Hide' : 'Show'}</span>
            </button>
          ) : null}
          {exchangeVisible ? (
            <>
              <Transcript sessionId={session.id} turns={turns} streaming={state.streaming} />
              {active ? (
                <Composer sessionId={session.id} participants={session.participants} />
              ) : null}
            </>
          ) : null}
        </div>

        {hasOutcome ? (
          <aside className="session__inspector">
            <div className="session__inspector-inner">
              <div className="session__inspector-head">
                <Label>Outcome</Label>
                <div className="spacer" />
                {verdict ? (
                  <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
                    Immutable record
                  </span>
                ) : null}
              </div>

              {/* One pane, not a stack of floating cards: every block of the
                  outcome shares a single border and separates by rule lines. */}
              <div className="outcome-pane">
                {verdict ? (
                  <VerdictPanel
                    verdict={verdict}
                    onExport={() => void exportReport()}
                    onStow={session.repoPath ? () => void stow() : null}
                    sessionId={session.id}
                  />
                ) : null}
                <FindingsPanel findings={findings} />
                <FindingsLedgerPanel
                  entries={ledger}
                  plans={plans}
                  milestones={ownPlanDetail?.milestones}
                />
              </div>
            </div>
          </aside>
        ) : null}

        {/* The record and the work have different rhythms — the outcome is
            read once, the plan is worked in — so on wide viewports the plan
            area is its own column rather than a mile of scroll below the
            verdict. Narrower windows stack it after the record. */}
        {hasOutcome && plans.length ? (
          <aside className="session__work">
            <div className="session__inspector-inner">
              <div className="session__inspector-head">
                <Label>Work</Label>
              </div>

              <div className="outcome-pane">
                {/* A vertical list, because a horizontal strip stops working at
                    the third plan and real sessions accumulate more — failed
                    attempts, remediations, the one that landed. Numbered by
                    creation (stable for cross-reference), shown newest first:
                    the latest plan is almost always the one being worked.
                    Stays visible while a plan is open, so opening one never
                    hides the way to the others. */}
                <div className="plan-list" role="tablist" aria-label="Plans in this session">
                  {[...plans]
                    .sort((a, b) => a.createdAt - b.createdAt)
                    .map((plan, index) => ({ plan, index }))
                    .reverse()
                    .map(({ plan, index }) => {
                      const isOpen = ownPlanDetail?.plan.id === plan.id
                      const tone = statusTone(plan.status)
                      return (
                        <button
                          key={plan.id}
                          role="tab"
                          aria-selected={isOpen}
                          className={isOpen ? 'list-item is-active' : 'list-item'}
                          onClick={() => void openPlan(plan.id)}
                          title={`${plan.title} — ${plan.kind}, ${plan.status}`}
                        >
                          <div className="list-item__top">
                            <span className="tnum dimmer">{index + 1}</span>
                            <span className="list-item__title">{plan.title}</span>
                            <Chip tone={tone.tone}>{tone.label}</Chip>
                          </div>
                          <div className="list-item__meta">
                            <span>{plan.kind}</span>
                            <span>·</span>
                            <span>{plan.isolation}</span>
                            <span>·</span>
                            <span>{relativeTime(plan.createdAt)}</span>
                          </div>
                        </button>
                      )
                    })}
                </div>

                {ownPlanDetail ? (
                  <PlanPanel
                    detail={ownPlanDetail}
                    // The session's own ledger, live-merged by session.ledger
                    // events — strictly fresher here than planLedger, and
                    // never null while this view renders.
                    ledger={ledger}
                    onRefresh={() => void openPlan(ownPlanDetail.plan.id)}
                    host="parley"
                  />
                ) : null}
              </div>
            </div>
          </aside>
        ) : null}
      </div>

      {showPlan ? (
        <NewPlanDialog
          session={session}
          onClose={() => setShowPlan(false)}
          onCreated={(planDetail) => dispatch({ type: 'planDetail', detail: planDetail })}
        />
      ) : null}
    </>
  )
}

/** A finished turn longer than this clamps behind an expander. */
const CLAMP_CHARS = 1200

function Transcript({
  sessionId,
  turns,
  streaming,
}: {
  sessionId: Id
  turns: Turn[]
  streaming: Record<Id, string>
}): ReactNode {
  const scrollRef = useRef<HTMLDivElement>(null)
  const pinnedToBottom = useRef(true)
  const [expanded, setExpanded] = useState<ReadonlySet<Id>>(new Set())

  // Follow the stream only while the reader is already at the bottom. Yanking
  // the viewport while someone is reading an earlier turn is the fastest way to
  // make a live transcript unusable.
  useLayoutEffect(() => {
    const element = scrollRef.current
    if (!element || !pinnedToBottom.current) return
    element.scrollTop = element.scrollHeight
  }, [turns, streaming])

  useEffect(() => {
    pinnedToBottom.current = true
  }, [sessionId])

  return (
    <div
      className="transcript"
      ref={scrollRef}
      onScroll={(event) => {
        const el = event.currentTarget
        pinnedToBottom.current = el.scrollHeight - el.scrollTop - el.clientHeight < 60
      }}
    >
      <div className="transcript__inner">
        {turns.length === 0 ? (
          <div className="row" style={{ justifyContent: 'center', padding: 'var(--s9)' }}>
            <Spinner />
            <span className="dim" style={{ fontSize: 'var(--text-small)' }}>
              Opening…
            </span>
          </div>
        ) : (
          turns.map((turn) => {
            const live = streaming[turn.id]
            const text = turn.text || live || ''
            const pending = !turn.endedAt && !turn.text
            // Long finished turns — architecture maps, embedded JSON — are
            // reference material, not reading material: clamp them behind an
            // expander. A turn still streaming is never clamped; its tail is
            // the signal that the session is alive.
            const collapsible = !!turn.endedAt && !turn.error && text.length > CLAMP_CHARS
            const isExpanded = expanded.has(turn.id)
            const clamped = collapsible && !isExpanded

            return (
              <div className={`turn turn--${seatSide(turn.seat)}`} key={turn.id}>
                <div className="turn__rail" />
                <div className="turn__content">
                  <div className="turn__header">
                    <span className="turn__stage">{turn.stage}</span>
                    <Chip tone={seatSide(turn.seat) === 'a' ? 'chip--a' : 'chip--b'}>
                      {seatLabel(turn.seat)} · {VENDOR_LABEL[turn.vendor] ?? turn.vendor}
                    </Chip>
                    {turn.model ? <Chip tone="chip--mono">{turn.model}</Chip> : null}
                    {!turn.endedAt ? <Spinner /> : null}
                    {turn.error ? <Chip tone="chip--fail">failed</Chip> : null}
                  </div>

                  {turn.error ? (
                    <div className="turn__body" style={{ color: 'var(--fail)' }}>
                      {turn.error}
                    </div>
                  ) : (
                    <div
                      className={`turn__body ${pending ? 'turn__body--pending' : ''} ${clamped ? 'turn__body--clamped' : ''}`}
                    >
                      {text || 'Thinking…'}
                    </div>
                  )}
                  {collapsible ? (
                    <button
                      className="turn__expand"
                      onClick={() =>
                        setExpanded((current) => {
                          const next = new Set(current)
                          if (next.has(turn.id)) next.delete(turn.id)
                          else next.add(turn.id)
                          return next
                        })
                      }
                    >
                      {isExpanded
                        ? 'Collapse'
                        : `Show all — ${text.split('\n').length} lines`}
                    </button>
                  ) : null}
                </div>
              </div>
            )
          })
        )}
      </div>
    </div>
  )
}

/**
 * The interjection composer.
 *
 * `All` is visible to every seat. A whisper reaches one seat only and the
 * others never learn it happened — which is what makes it useful for testing
 * whether an agent will hold a position under private pressure.
 */
function Composer({
  sessionId,
  participants,
}: {
  sessionId: Id
  participants: readonly AgentConfig[]
}): ReactNode {
  const { attempt, notify } = useStore()
  const [text, setText] = useState('')
  const [target, setTarget] = useState<InterjectionTarget>('all')

  // One whisper per seat, labelled by chair and vendor: a jury of three
  // claudes still reads unambiguously.
  const options: Array<{ value: InterjectionTarget; label: string; title: string }> = [
    { value: 'all', label: 'All', title: 'Every advisor sees this' },
    ...participants.map((participant, seat) => ({
      value: seat as InterjectionTarget,
      label: `Whisper ${seatLabel(seat)}`,
      title: `Only ${seatLabel(seat)} (${VENDOR_LABEL[participant.vendor] ?? participant.vendor}) sees this`,
    })),
  ]

  const submit = async (): Promise<void> => {
    const body = text.trim()
    if (!body) return
    const done = await attempt(() => api.interject(sessionId, target, body))
    if (done) {
      setText('')
      notify(
        'info',
        target === 'all'
          ? 'Queued for every advisor on their next turn.'
          : `Whispered to ${seatLabel(target)} — the other advisors will not see it.`,
      )
    }
  }

  return (
    <div className="composer">
      <div className="composer__inner">
        <div className="composer__row">
          <div className="segmented" role="group" aria-label="Interjection target">
            {options.map((option) => (
              <button
                key={String(option.value)}
                className={`segmented__item ${target === option.value ? 'is-active' : ''}`}
                onClick={() => setTarget(option.value)}
                title={option.title}
              >
                {option.label}
              </button>
            ))}
          </div>
          <div className="spacer" />
          <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
            Delivered on the next turn
          </span>
        </div>

        <div className="composer__row">
          <textarea
            className="composer__input"
            rows={1}
            placeholder={
              target === 'all'
                ? 'Direct every advisor — assume 10× load, or ignore cost entirely…'
                : `Press ${seatLabel(target)} privately…`
            }
            value={text}
            onChange={(event) => setText(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault()
                void submit()
              }
            }}
          />
          <button className="btn btn--primary" disabled={!text.trim()} onClick={() => void submit()}>
            <Send size={12} strokeWidth={2} />
            Send
          </button>
        </div>
      </div>
    </div>
  )
}
