import type {
  Finding,
  Id,
  Loop,
  LoopIteration,
  Milestone,
  Pane,
  Session,
  Turn,
  Usage,
  Verdict,
  WorkPlan,
} from './domain'

/**
 * Events pushed from the main process to the renderer.
 *
 * One discriminated union over a single channel, so the renderer registers one
 * listener and switches on `type`. High-volume terminal output deliberately does
 * *not* travel here — see {@link PtyChunk}.
 */
export type AppEvent =
  // Parley sessions
  | { type: 'session.created'; session: Session }
  | { type: 'session.status'; sessionId: Id; status: Session['status']; error?: string }
  | { type: 'session.turn.started'; turn: Turn }
  | { type: 'session.turn.delta'; sessionId: Id; turnId: Id; text: string }
  | { type: 'session.turn.ended'; turn: Turn }
  | { type: 'session.usage'; sessionId: Id; usage: Usage }
  | { type: 'session.finding'; finding: Finding }
  | { type: 'session.verdict'; verdict: Verdict }
  // Work plans
  | { type: 'plan.created'; plan: WorkPlan }
  | { type: 'plan.status'; planId: Id; status: WorkPlan['status'] }
  | { type: 'plan.milestone'; milestone: Milestone }
  /**
   * The authoritative milestone set for a plan, replacing whatever the client
   * holds.
   *
   * Needed because `plan.milestone` can only ever add or update one row, and a
   * correction *replaces* the set: it clears the drafts and writes new rows with
   * new ids. With no way to say "these are gone", a client that merged by id kept
   * showing the superseded drafts — complete with live approve buttons for rows
   * the database had already deleted.
   */
  | { type: 'plan.milestones'; planId: Id; milestones: Milestone[] }
  /**
   * Live telemetry from a running milestone: the file the executor is editing,
   * the command it is running, the phase Parley has reached.
   *
   * Ephemeral and never persisted — it exists so a milestone that takes half an
   * hour is not an opaque spinner. The durable record is the milestone row.
   */
  | { type: 'plan.activity'; milestoneId: Id; phase: MilestonePhase; text: string }
  /**
   * The same, for the stages that run before any milestone exists.
   *
   * Drafting, auditing and correcting cannot use `plan.activity` because it is
   * keyed to a milestone, and milestones are what those stages produce. Without
   * this the longest stages in the pipeline are the only silent ones.
   */
  | { type: 'plan.stage'; planId: Id; stage: WorkPlan['status']; text: string }
  // Loops
  | { type: 'loop.created'; loop: Loop }
  | { type: 'loop.status'; loopId: Id; status: Loop['status']; stopReason?: string }
  | { type: 'loop.iteration.started'; iteration: LoopIteration }
  | { type: 'loop.iteration.ended'; iteration: LoopIteration }
  /** Live telemetry from the running iteration. See `plan.activity`. */
  | { type: 'loop.activity'; loopId: Id; text: string }
  // Grid
  | { type: 'pane.created'; pane: Pane }
  | { type: 'pane.status'; paneId: Id; status: Pane['status']; exitCode?: number | null }
  | { type: 'pane.closed'; paneId: Id }
  // Cross-cutting
  | { type: 'notice'; level: 'info' | 'warn' | 'error'; message: string }

/** Which stage of the audited pipeline a live activity line belongs to. */
export type MilestonePhase = 'executing' | 'testing' | 'reviewing'

export type AppEventType = AppEvent['type']

/**
 * Terminal output. Kept off {@link AppEvent} and unvalidated on the hot path:
 * a busy pane emits thousands of chunks and schema-parsing each one would
 * dominate the frame budget.
 */
export interface PtyChunk {
  paneId: Id
  data: string
}
