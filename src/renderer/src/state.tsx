import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  type ReactNode,
} from 'react'
import type { Id, Loop, Pane, Session, Skill } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import type { CliHealth } from '@shared/ipc'
import { api, type LoopDetail, type PlanDetail, type SessionDetail } from './lib/api'
import { applyLedgerEvent } from './lib/ledgerState'

export type Surface = 'grid' | 'parley' | 'loops'
export type ThemeChoice = 'system' | 'light' | 'dark'

export interface Notice {
  id: number
  level: 'info' | 'warn' | 'error'
  message: string
}

export interface ActivityEntry {
  at: number
  phase: string
  text: string
}

export interface ActivityLog {
  /** When the subject went in-flight, for the elapsed clock. */
  startedAt: number
  entries: ActivityEntry[]
}

/**
 * Live telemetry is ephemeral and bounded.
 *
 * It exists so a long-running milestone is not an opaque spinner, not to be a
 * durable record — the milestone row is that. Keeping only the tail means a
 * chatty agent cannot grow renderer memory without limit.
 */
const MAX_ACTIVITY_ENTRIES = 60

interface State {
  surface: Surface
  theme: ThemeChoice
  /** True when the deterministic adapters are in use. Must always be visible. */
  mock: boolean
  /** The model this machine's codex is configured to use, if any. */
  codexDefaultModel: string
  health: CliHealth[]
  sessions: Session[]
  /** How many are hidden by the archive filter, so the sidebar can offer them. */
  archivedCount: number
  showArchived: boolean
  activeSessionId: Id | null
  sessionDetail: SessionDetail | null
  /** Live text for turns still streaming, keyed by turn id. */
  streaming: Record<Id, string>
  loops: Loop[]
  activeLoopId: Id | null
  loopDetail: LoopDetail | null
  planDetail: PlanDetail | null
  panes: Pane[]
  skills: Skill[]
  notices: Notice[]
  paletteOpen: boolean
  /** Keyed by milestone id, then by loop id. Never persisted. */
  activity: Record<Id, ActivityLog>
}

const initialState: State = {
  surface: 'parley',
  theme: 'system',
  mock: false,
  codexDefaultModel: '',
  health: [],
  sessions: [],
  archivedCount: 0,
  showArchived: false,
  activeSessionId: null,
  sessionDetail: null,
  streaming: {},
  loops: [],
  activeLoopId: null,
  loopDetail: null,
  planDetail: null,
  panes: [],
  skills: [],
  notices: [],
  paletteOpen: false,
  activity: {},
}

type Action =
  | { type: 'surface'; surface: Surface }
  | { type: 'theme'; theme: ThemeChoice }
  | { type: 'health'; health: CliHealth[] }
  | { type: 'mock'; mock: boolean; codexDefaultModel: string }
  | { type: 'sessions'; sessions: Session[]; archivedCount: number }
  | { type: 'showArchived'; showArchived: boolean }
  | { type: 'activeSession'; sessionId: Id | null }
  | { type: 'sessionDetail'; detail: SessionDetail | null }
  | { type: 'loops'; loops: Loop[] }
  | { type: 'activeLoop'; loopId: Id | null }
  | { type: 'loopDetail'; detail: LoopDetail | null }
  | { type: 'planDetail'; detail: PlanDetail | null }
  | { type: 'panes'; panes: Pane[] }
  | { type: 'skills'; skills: Skill[] }
  | { type: 'notice'; level: Notice['level']; message: string }
  | { type: 'dismissNotice'; id: number }
  | { type: 'palette'; open: boolean }
  | { type: 'appEvent'; event: AppEvent }

let noticeSeq = 0

function appendActivity(
  activity: Record<Id, ActivityLog>,
  subjectId: Id,
  phase: string,
  text: string,
): Record<Id, ActivityLog> {
  const existing = activity[subjectId] ?? { startedAt: Date.now(), entries: [] }
  const entries = [...existing.entries, { at: Date.now(), phase, text }].slice(-MAX_ACTIVITY_ENTRIES)
  return { ...activity, [subjectId]: { ...existing, entries } }
}

function reducer(state: State, action: Action): State {
  switch (action.type) {
    case 'surface':
      return { ...state, surface: action.surface }
    case 'theme':
      return { ...state, theme: action.theme }
    case 'health':
      return { ...state, health: action.health }
    case 'mock':
      return { ...state, mock: action.mock, codexDefaultModel: action.codexDefaultModel }
    case 'sessions':
      return { ...state, sessions: action.sessions, archivedCount: action.archivedCount }
    case 'showArchived':
      return { ...state, showArchived: action.showArchived }
    case 'activeSession':
      return { ...state, activeSessionId: action.sessionId, sessionDetail: null, planDetail: null }
    case 'sessionDetail':
      return { ...state, sessionDetail: action.detail }
    case 'loops':
      return { ...state, loops: action.loops }
    case 'activeLoop':
      return { ...state, activeLoopId: action.loopId, loopDetail: null }
    case 'loopDetail':
      return { ...state, loopDetail: action.detail }
    case 'planDetail':
      return { ...state, planDetail: action.detail }
    case 'panes':
      return { ...state, panes: action.panes }
    case 'skills':
      return { ...state, skills: action.skills }
    case 'notice':
      noticeSeq += 1
      return {
        ...state,
        notices: [...state.notices, { id: noticeSeq, level: action.level, message: action.message }].slice(-4),
      }
    case 'dismissNotice':
      return { ...state, notices: state.notices.filter((n) => n.id !== action.id) }
    case 'palette':
      return { ...state, paletteOpen: action.open }
    case 'appEvent':
      return applyEvent(state, action.event)
    default:
      return state
  }
}

/**
 * Folds a streamed main-process event into local state.
 *
 * Everything here is an in-place patch of what is already loaded rather than a
 * refetch, so a session streaming a dozen turns does not thrash the database or
 * the scroll position.
 */
function applyEvent(state: State, event: AppEvent): State {
  switch (event.type) {
    case 'session.created':
      return { ...state, sessions: [event.session, ...state.sessions] }

    case 'session.status': {
      const sessions = state.sessions.map((s) =>
        s.id === event.sessionId ? { ...s, status: event.status, error: event.error ?? s.error } : s,
      )
      const detail =
        state.sessionDetail?.session.id === event.sessionId
          ? {
              ...state.sessionDetail,
              session: {
                ...state.sessionDetail.session,
                status: event.status,
                error: event.error ?? state.sessionDetail.session.error,
              },
            }
          : state.sessionDetail
      if (event.status === 'failed' && event.error) {
        noticeSeq += 1
        const failure: Notice = { id: noticeSeq, level: 'error', message: event.error }
        return {
          ...state,
          sessions,
          sessionDetail: detail,
          notices: [...state.notices, failure].slice(-4),
        }
      }
      return { ...state, sessions, sessionDetail: detail }
    }

    case 'session.turn.started':
      if (state.sessionDetail?.session.id !== event.turn.sessionId) return state
      return {
        ...state,
        sessionDetail: { ...state.sessionDetail, turns: [...state.sessionDetail.turns, event.turn] },
        streaming: { ...state.streaming, [event.turn.id]: '' },
      }

    case 'session.turn.delta': {
      if (state.sessionDetail?.session.id !== event.sessionId) return state
      const current = state.streaming[event.turnId] ?? ''
      return { ...state, streaming: { ...state.streaming, [event.turnId]: current + event.text } }
    }

    case 'session.turn.ended': {
      if (state.sessionDetail?.session.id !== event.turn.sessionId) return state
      const turns = state.sessionDetail.turns.map((t) => (t.id === event.turn.id ? event.turn : t))
      const streaming = { ...state.streaming }
      delete streaming[event.turn.id]
      return { ...state, sessionDetail: { ...state.sessionDetail, turns }, streaming }
    }

    case 'session.usage': {
      const sessions = state.sessions.map((s) => (s.id === event.sessionId ? { ...s, usage: event.usage } : s))
      const detail =
        state.sessionDetail?.session.id === event.sessionId
          ? { ...state.sessionDetail, session: { ...state.sessionDetail.session, usage: event.usage } }
          : state.sessionDetail
      return { ...state, sessions, sessionDetail: detail }
    }

    case 'session.finding': {
      if (state.sessionDetail?.session.id !== event.finding.sessionId) return state
      const existing = state.sessionDetail.findings.filter((f) => f.id !== event.finding.id)
      return { ...state, sessionDetail: { ...state.sessionDetail, findings: [...existing, event.finding] } }
    }

    case 'session.verdict':
      if (state.sessionDetail?.session.id !== event.verdict.sessionId) return state
      return { ...state, sessionDetail: { ...state.sessionDetail, verdict: event.verdict } }

    case 'session.ledger': {
      const sessionDetail = applyLedgerEvent(state.sessionDetail, event)
      return sessionDetail === state.sessionDetail ? state : { ...state, sessionDetail }
    }

    case 'plan.created':
      return state.sessionDetail?.session.id === event.plan.sessionId
        ? { ...state, sessionDetail: { ...state.sessionDetail, plans: [event.plan, ...state.sessionDetail.plans] } }
        : state

    case 'plan.status': {
      // Restart the clock on every stage change, so the elapsed time shown is
      // "how long has it been auditing" rather than "how long since I clicked".
      // The latter is the number you already know.
      const running = ['drafting', 'auditing', 'correcting'].includes(event.status)
      const activity = running
        ? { ...state.activity, [event.planId]: { startedAt: Date.now(), entries: [] } }
        : state.activity

      // The session's plan list carries a status too, and the plan switcher shows
      // it. Patching only planDetail left the switcher reading whatever the status
      // was when the list was fetched — permanently "drafting" on a ready plan.
      const sessionDetail = state.sessionDetail
        ? {
            ...state.sessionDetail,
            plans: state.sessionDetail.plans.map((p) =>
              p.id === event.planId ? { ...p, status: event.status } : p,
            ),
          }
        : state.sessionDetail

      if (state.planDetail?.plan.id !== event.planId) return { ...state, activity, sessionDetail }
      return {
        ...state,
        activity,
        sessionDetail,
        planDetail: { ...state.planDetail, plan: { ...state.planDetail.plan, status: event.status } },
      }
    }

    case 'plan.milestones': {
      if (state.planDetail?.plan.id !== event.planId) return state
      // Replaced, not merged: rows absent from this list have been deleted.
      return {
        ...state,
        planDetail: { ...state.planDetail, milestones: [...event.milestones].sort((x, y) => x.index - y.index) },
      }
    }

    case 'plan.milestone': {
      // Start the clock the first time a milestone reports itself in flight, so
      // the elapsed time shown is the run's, not the window's.
      const inFlight = ['executing', 'testing', 'reviewing'].includes(event.milestone.status)
      const activity =
        inFlight && !state.activity[event.milestone.id]
          ? { ...state.activity, [event.milestone.id]: { startedAt: Date.now(), entries: [] } }
          : state.activity

      if (state.planDetail?.plan.id !== event.milestone.planId) return { ...state, activity }
      const others = state.planDetail.milestones.filter((m) => m.id !== event.milestone.id)
      const milestones = [...others, event.milestone].sort((x, y) => x.index - y.index)
      return { ...state, activity, planDetail: { ...state.planDetail, milestones } }
    }

    case 'plan.activity':
      return {
        ...state,
        activity: appendActivity(state.activity, event.milestoneId, event.phase, event.text),
      }

    // Keyed by plan rather than milestone: these are the stages that run before
    // any milestone exists.
    case 'plan.stage':
      return {
        ...state,
        activity: appendActivity(state.activity, event.planId, event.stage, event.text),
      }

    case 'loop.activity':
      return {
        ...state,
        activity: appendActivity(state.activity, event.loopId, 'working', event.text),
      }

    case 'loop.created':
      return { ...state, loops: [event.loop, ...state.loops] }

    case 'loop.status': {
      const loops = state.loops.map((l) =>
        l.id === event.loopId
          ? { ...l, status: event.status, stopReason: event.stopReason ?? l.stopReason }
          : l,
      )
      const detail =
        state.loopDetail?.loop.id === event.loopId
          ? {
              ...state.loopDetail,
              loop: {
                ...state.loopDetail.loop,
                status: event.status,
                stopReason: event.stopReason ?? state.loopDetail.loop.stopReason,
              },
            }
          : state.loopDetail
      return { ...state, loops, loopDetail: detail }
    }

    case 'loop.iteration.started':
      if (state.loopDetail?.loop.id !== event.iteration.loopId) return state
      return {
        ...state,
        loopDetail: {
          ...state.loopDetail,
          iterations: [...state.loopDetail.iterations, event.iteration],
          loop: { ...state.loopDetail.loop, iterationCount: event.iteration.index + 1 },
        },
      }

    case 'loop.iteration.ended': {
      if (state.loopDetail?.loop.id !== event.iteration.loopId) return state
      const iterations = state.loopDetail.iterations.map((i) =>
        i.id === event.iteration.id ? event.iteration : i,
      )
      return { ...state, loopDetail: { ...state.loopDetail, iterations } }
    }

    case 'pane.created':
      return { ...state, panes: [...state.panes, event.pane] }

    case 'pane.status':
      return {
        ...state,
        panes: state.panes.map((p) =>
          p.id === event.paneId
            ? { ...p, status: event.status, exitCode: event.exitCode ?? p.exitCode }
            : p,
        ),
      }

    case 'pane.closed':
      return state

    case 'notice':
      noticeSeq += 1
      return {
        ...state,
        notices: [...state.notices, { id: noticeSeq, level: event.level, message: event.message }].slice(-4),
      }

    default:
      return state
  }
}

interface Store {
  state: State
  dispatch: React.Dispatch<Action>
  notify: (level: Notice['level'], message: string) => void
  /** Runs an async action and surfaces any failure as a notice. */
  attempt: <T>(work: () => Promise<T>) => Promise<T | null>
  /**
   * @param includeArchived Overrides the stored filter. Needed because a caller
   *   that has just dispatched a toggle cannot read the new value back — the
   *   dispatch is batched, so the ref still holds the old one.
   */
  refreshSessions: (includeArchived?: boolean) => Promise<void>
  refreshLoops: () => Promise<void>
  openSession: (sessionId: Id) => Promise<void>
  openLoop: (loopId: Id) => Promise<void>
  openPlan: (planId: Id) => Promise<void>
}

const StoreContext = createContext<Store | null>(null)

export function StoreProvider({ children }: { children: ReactNode }): ReactNode {
  const [state, dispatch] = useReducer(reducer, initialState)
  const stateRef = useRef(state)
  stateRef.current = state

  const notify = useCallback((level: Notice['level'], message: string) => {
    dispatch({ type: 'notice', level, message })
  }, [])

  const attempt = useCallback(
    async <T,>(work: () => Promise<T>): Promise<T | null> => {
      try {
        return await work()
      } catch (err) {
        notify('error', err instanceof Error ? err.message : String(err))
        return null
      }
    },
    [notify],
  )

  const refreshSessions = useCallback(async (includeArchived?: boolean) => {
    // Falls back to the stored flag, so the many callers that just want a
    // refresh do not have to know about it.
    const include = includeArchived ?? stateRef.current.showArchived
    const result = await attempt(() => api.listSessions(include))
    if (result) {
      dispatch({ type: 'sessions', sessions: result.sessions, archivedCount: result.archivedCount })
    }
  }, [attempt])

  const refreshLoops = useCallback(async () => {
    const loops = await attempt(() => api.listLoops())
    if (loops) dispatch({ type: 'loops', loops })
  }, [attempt])

  const openSession = useCallback(
    async (sessionId: Id) => {
      dispatch({ type: 'activeSession', sessionId })
      const detail = await attempt(() => api.getSession(sessionId))
      if (detail) dispatch({ type: 'sessionDetail', detail })
    },
    [attempt],
  )

  const openLoop = useCallback(
    async (loopId: Id) => {
      dispatch({ type: 'activeLoop', loopId })
      const detail = await attempt(() => api.getLoop(loopId))
      if (detail) dispatch({ type: 'loopDetail', detail })
    },
    [attempt],
  )

  const openPlan = useCallback(
    async (planId: Id) => {
      const detail = await attempt(() => api.getPlan(planId))
      if (detail) dispatch({ type: 'planDetail', detail })
    },
    [attempt],
  )

  // Subscribe once, for the lifetime of the app.
  useEffect(() => {
    const off = api.onEvent((event) => dispatch({ type: 'appEvent', event }))
    return off
  }, [])

  // Initial load.
  useEffect(() => {
    void refreshSessions()
    void refreshLoops()
    void attempt(() => api.listSkills()).then((skills) => {
      if (skills) dispatch({ type: 'skills', skills })
    })
    void attempt(() => api.health()).then((health) => {
      if (health) dispatch({ type: 'health', health })
    })
    void attempt(() => api.info()).then((info) => {
      if (info) {
        dispatch({ type: 'mock', mock: info.mock, codexDefaultModel: info.codexDefaultModel })
      }
    })
  }, [attempt, refreshSessions, refreshLoops])

  // Apply the theme choice to the document root, which the token layer reads.
  useEffect(() => {
    const root = document.documentElement
    if (state.theme === 'system') root.removeAttribute('data-theme')
    else root.setAttribute('data-theme', state.theme)
  }, [state.theme])

  // Notices auto-dismiss; errors stay until dismissed, because an error the user
  // did not read is an error they will hit again.
  useEffect(() => {
    const transient = state.notices.filter((n) => n.level !== 'error')
    if (!transient.length) return
    const timers = transient.map((n) =>
      setTimeout(() => dispatch({ type: 'dismissNotice', id: n.id }), 7000),
    )
    return () => timers.forEach(clearTimeout)
  }, [state.notices])

  const value = useMemo<Store>(
    () => ({
      state,
      dispatch,
      notify,
      attempt,
      refreshSessions,
      refreshLoops,
      openSession,
      openLoop,
      openPlan,
    }),
    [state, notify, attempt, refreshSessions, refreshLoops, openSession, openLoop, openPlan],
  )

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
}

export function useStore(): Store {
  const store = useContext(StoreContext)
  if (!store) throw new Error('useStore must be used inside StoreProvider')
  return store
}
