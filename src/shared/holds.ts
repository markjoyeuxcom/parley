import type { Id } from './domain'
import { sha256 } from './ledger'

/**
 * Decision holds.
 *
 * A hold is one thing currently waiting on a human: a parked question, a
 * milestone that can be approved, a run that stopped in a state worth knowing
 * about. Holds are **derived, never stored**. The open set is recomputed from
 * the durable rows that already exist (plans, milestones, loops, the finding
 * ledger) — a materialised queue could not even be correct here, because
 * "approvable" depends on the ledger gate, and the gate moves with no plan or
 * milestone transition at all. Only two things about a hold are ever written
 * down: that a human acknowledged it, and that it was notified once.
 */

export type HoldKind =
  /** A plan is parked on a question only the user can answer. */
  | 'clarification'
  /** The next milestone can be approved and run. */
  | 'approval-waiting'
  /** The next milestone could be approved, but open blocking findings gate it. */
  | 'ledger-gated'
  /** The plan stopped before the human gate: unaudited, or audit unanswered. */
  | 'plan-blocked'
  /** A milestone failed — remediation exhausted, tests red, or interrupted. */
  | 'milestone-failed'
  /** A loop stopped without succeeding: a cap, a failure, or a kill. */
  | 'loop-exhausted'
  /** A worktree plan's branch is ready to fast-forward into the checkout. */
  | 'merge-ready'
  /** Landing was refused — the checkout diverged or has conflicting dirt. */
  | 'merge-blocked'

/**
 * Decision holds clear only by acting — answering, approving, landing. They
 * refuse acknowledgement outright, because an ack-able "waiting on your
 * answer" would clear the badge while the plan stays parked forever, which is
 * the exact silent stall this feature exists to kill. Notice holds carry no
 * pending action, so acknowledging them is the action.
 */
export type HoldClass = 'decision' | 'notice'

export const HOLD_CLASS: Record<HoldKind, HoldClass> = {
  clarification: 'decision',
  'approval-waiting': 'decision',
  'ledger-gated': 'decision',
  'plan-blocked': 'notice',
  'milestone-failed': 'notice',
  'loop-exhausted': 'notice',
  'merge-ready': 'decision',
  'merge-blocked': 'notice',
}

export interface Hold {
  /** Content-addressed identity — see {@link holdIdentity}. */
  id: Id
  kind: HoldKind
  /** Null for loop holds: loops are not session-scoped. */
  sessionId: Id | null
  planId: Id | null
  milestoneId: Id | null
  loopId: Id | null
  /** Short sentence naming what waits. */
  title: string
  /** The substance: the question text, the milestone, the stop reason. */
  detail: string
  /**
   * Best-effort onset from the underlying rows. Nothing durable records when a
   * status changed, so the notification stamp's first-seen time is the honest
   * "waiting since" once one exists; this fills the gap until then.
   */
  sinceAt: number
  /** True for decision-class holds: resolved by acting, never by ack. */
  actionable: boolean
  /** Mock provenance, carried so no surface can present fabricated waiting work as real. */
  mock: boolean
}

/**
 * Content identity for a hold.
 *
 * The same situation must hash the same across recomputes and restarts — that
 * is what lets an append-only ack survive regeneration and a notification
 * happen once. `generation` is the part that makes a *recurrence* a fresh
 * hold: a re-asked question, a milestone failing again after its ack. Callers
 * fold into it exactly the fields whose change means "this is new waiting,
 * not the same waiting re-observed".
 */
export function holdIdentity(kind: HoldKind, subjectId: Id, generation: string): Id {
  return sha256(`${kind}\0${subjectId}\0${generation}`)
}
