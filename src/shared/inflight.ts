import type { Id } from './domain'

/**
 * What is running right now.
 *
 * The live counterpart to the holds queue, and derived by the same rule: from
 * durable state, never from a stored list. Startup reconciliation already
 * settles anything a crash left claiming to run, so a row here means the
 * record says it is live — and every row knows where its home is, because a
 * status you cannot open is only decoration.
 */
export type InFlightKind =
  | 'envelope'
  | 'milestone'
  | 'plan'
  | 'session'
  | 'loop'

export interface InFlightRow {
  id: string
  kind: InFlightKind
  /** What is running, in the user's terms. */
  title: string
  /** The phase, the repository, or whatever answers "how far along". */
  detail: string
  startedAt: number
  repoPath: string | null
  /** Where clicking it goes. Mirrors the holds queue's jump targets. */
  jump:
    | { to: 'plan'; planId: Id; milestoneId?: Id }
    | { to: 'session'; sessionId: Id }
    | { to: 'loop'; loopId: Id }
  /** Consumption bars for a capped run: 0–1 each, only where a cap exists. */
  progress?: Array<{ label: string; value: number }>
  mock: boolean
}
