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

/**
 * How long a run may be silent before it counts as stalled. Shared because
 * the derivation (main) and any surface explaining the threshold must agree.
 */
export const STALL_AFTER_MS = 5 * 60 * 1000

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
  /** An in-flight run has been silent past the stall threshold. */
  | 'run-stalled'
  /** A worktree plan's branch is ready to fast-forward into the checkout. */
  | 'merge-ready'
  /** Landing was refused — the checkout diverged or has conflicting dirt. */
  | 'merge-blocked'
  /** A repository's backlog holds proposals waiting on human triage. */
  | 'backlog-review'
  /** The foreman filed a plan proposal a human must accept or reject. */
  | 'foreman-proposal'
  /** A verified fresh build of Parley itself awaits relaunch or decline. */
  | 'self-update'

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
  'run-stalled': 'notice',
  'merge-ready': 'decision',
  'merge-blocked': 'notice',
  // Proposals wait on a real yes/no: confirm into the backlog or discard,
  // close or reopen. An ack would hide them while they stay proposed forever.
  'backlog-review': 'decision',
  // Same logic one level up: the foreman's proposal clears by accepting it
  // into a plan or rejecting it with a reason, never by dismissal.
  'foreman-proposal': 'decision',
  // The offer clears by relaunching or declining — an ack-able "new build
  // waiting" would leave the app running stale bytes with the badge dark,
  // which is the exact hazard this series exists to kill.
  'self-update': 'decision',
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
  /**
   * The repository the waiting belongs to, canonically keyed — set on every
   * hold that has one (plan, milestone, loop, backlog, foreman); null only
   * for holds with no repository at all. Deliberately OUTSIDE holdIdentity:
   * adding it must never re-mint an identity, or every notify-once stamp
   * would fire again.
   */
  repoPath: string | null
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
