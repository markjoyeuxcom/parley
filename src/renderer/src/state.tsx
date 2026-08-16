import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  type ReactNode,
} from 'react'
import type { Pane, Skill } from '@shared/domain'
import type { CliHealth } from '@shared/ipc'
import { api } from './lib/api'

/**
 * What the window knows.
 *
 * Small, and deliberately so: a room holds its own transcript, and a terminal
 * pane holds its own scrollback. What lives here is the handful of facts every
 * surface needs — which CLIs exist, whether the adapters are mocked, the pane
 * registry, the skills rail — plus the notice queue.
 *
 * Streaming text is NOT here. A delta arriving in one room would re-render
 * every pane in the grid, which is the same reason terminal bytes never
 * reached this store either.
 */

export interface Notice {
  id: number
  level: 'info' | 'warn' | 'error'
  message: string
}

export type ThemeChoice = 'auto' | 'light' | 'dark'

export interface State {
  theme: ThemeChoice
  /**
   * True when the deterministic adapters are in use.
   *
   * Shown permanently and unmissably: a mock room produces turns and verdicts
   * that look exactly like real ones while consulting no model.
   */
  mock: boolean
  codexDefaultModel: string
  agyModels: string[]
  health: CliHealth[]
  panes: Pane[]
  skills: Skill[]
  notices: Notice[]
  paletteOpen: boolean
  /**
   * A room the Grid should open, asked for from somewhere else.
   *
   * The cross-surface knock, kept from the governed era because search still
   * needs one: a hit names a room, and the only place a room can be read is a
   * pane. The Grid consumes the request and clears it.
   */
  focusRoomId: string | null
}

export type Action =
  | { type: 'theme'; theme: ThemeChoice }
  | { type: 'info'; mock: boolean; codexDefaultModel: string; agyModels: string[] }
  | { type: 'health'; health: CliHealth[] }
  | { type: 'panes'; panes: Pane[] }
  | { type: 'pane'; pane: Pane }
  | { type: 'paneStatus'; paneId: string; status: Pane['status']; exitCode: number | null }
  | { type: 'paneClosed'; paneId: string }
  | { type: 'skills'; skills: Skill[] }
  | { type: 'notice'; notice: Notice }
  | { type: 'dismissNotice'; id: number }
  | { type: 'palette'; open: boolean }
  | { type: 'focusRoom'; roomId: string | null }

export const INITIAL: State = {
  theme: 'auto',
  mock: false,
  codexDefaultModel: '',
  agyModels: [],
  health: [],
  panes: [],
  skills: [],
  notices: [],
  paletteOpen: false,
  focusRoomId: null,
}

/** Exported for its own test: the pane fold is a property worth pinning. */
export function reduce(state: State, action: Action): State {
  switch (action.type) {
    case 'theme':
      return { ...state, theme: action.theme }
    case 'info':
      return {
        ...state,
        mock: action.mock,
        codexDefaultModel: action.codexDefaultModel,
        agyModels: action.agyModels,
      }
    case 'health':
      return { ...state, health: action.health }
    case 'panes':
      return { ...state, panes: action.panes }
    case 'pane':
      return {
        ...state,
        panes: state.panes.some((pane) => pane.id === action.pane.id)
          ? state.panes.map((pane) => (pane.id === action.pane.id ? action.pane : pane))
          : [...state.panes, action.pane],
      }
    case 'paneStatus':
      return {
        ...state,
        panes: state.panes.map((pane) =>
          pane.id === action.paneId
            ? { ...pane, status: action.status, exitCode: action.exitCode }
            : pane,
        ),
      }
    case 'paneClosed':
      return { ...state, panes: state.panes.filter((pane) => pane.id !== action.paneId) }
    case 'skills':
      return { ...state, skills: action.skills }
    case 'notice':
      return { ...state, notices: [...state.notices, action.notice] }
    case 'dismissNotice':
      return { ...state, notices: state.notices.filter((n) => n.id !== action.id) }
    case 'palette':
      return { ...state, paletteOpen: action.open }
    case 'focusRoom':
      return { ...state, focusRoomId: action.roomId }
    default:
      return state
  }
}

interface Store {
  state: State
  dispatch: (action: Action) => void
  notify: (level: Notice['level'], message: string) => void
  /**
   * Runs a bridge call and turns a refusal into a notice.
   *
   * Returns null when it failed, so callers branch on the value rather than
   * wrapping every invoke in a try — a refused command is an ordinary outcome
   * here, not an exception.
   */
  attempt: <T>(work: () => Promise<T>) => Promise<T | null>
}

const StoreContext = createContext<Store | null>(null)

export function StoreProvider({ children }: { children: ReactNode }): ReactNode {
  const [state, dispatch] = useReducer(reduce, INITIAL)
  const nextNotice = useRef(1)

  const store = useMemo<Store>(() => {
    const notify = (level: Notice['level'], message: string): void => {
      dispatch({ type: 'notice', notice: { id: (nextNotice.current += 1), level, message } })
    }
    return {
      state,
      dispatch,
      notify,
      attempt: async <T,>(work: () => Promise<T>): Promise<T | null> => {
        try {
          return await work()
        } catch (err) {
          notify('error', err instanceof Error ? err.message : String(err))
          return null
        }
      },
    }
  }, [state])

  useEffect(() => {
    void api
      .info()
      .then((info) =>
        dispatch({
          type: 'info',
          mock: info.mock,
          codexDefaultModel: info.codexDefaultModel,
          agyModels: info.agyModels,
        }),
      )
      .catch(() => {
        /* The banner stays off; every other surface still works. */
      })
    void api
      .health()
      .then((health) => dispatch({ type: 'health', health }))
      .catch(() => {
        /* An unknown CLI status is shown as unknown, not as an error. */
      })
    void api
      .listSkills()
      .then((skills) => dispatch({ type: 'skills', skills }))
      .catch(() => {
        /* An empty rail is still a rail. */
      })
  }, [])

  useEffect(
    () =>
      api.onEvent((event) => {
        switch (event.type) {
          case 'pane.created':
            dispatch({ type: 'pane', pane: event.pane })
            break
          case 'pane.status':
            dispatch({
              type: 'paneStatus',
              paneId: event.paneId,
              status: event.status,
              exitCode: event.exitCode ?? null,
            })
            break
          case 'pane.closed':
            dispatch({ type: 'paneClosed', paneId: event.paneId })
            break
          case 'notice':
            dispatch({
              type: 'notice',
              notice: { id: (nextNotice.current += 1), level: event.level, message: event.message },
            })
            break
          default:
            // Room events are handled by the pane that owns the room: a delta
            // arriving here would re-render every pane in the grid.
            break
        }
      }),
    [],
  )

  return <StoreContext.Provider value={store}>{children}</StoreContext.Provider>
}

export function useStore(): Store {
  const store = useContext(StoreContext)
  if (!store) throw new Error('useStore outside StoreProvider')
  return store
}
