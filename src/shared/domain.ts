import { z } from 'zod'

/**
 * The domain model for Parley.
 *
 * Every schema here is the single source of truth: the TypeScript types are
 * inferred from the zod schemas, and the same schemas validate the IPC
 * boundary. There is no second, hand-written copy of these shapes to drift.
 */

// ─── Identity ────────────────────────────────────────────────────────────────

export const Id = z.string().min(1).max(64)
export type Id = z.infer<typeof Id>

const Timestamp = z.number().int().nonnegative()

// ─── Agents ──────────────────────────────────────────────────────────────────

/**
 * The two CLI vendors Parley drives. Both are invoked through the user's own
 * logged-in CLI, so all usage bills against their existing subscription. Parley
 * never reads or accepts an API key.
 */
export const Vendor = z.enum(['claude', 'codex'])
export type Vendor = z.infer<typeof Vendor>

/** Claude's `--effort`. Codex maps this onto `model_reasoning_effort`. */
export const Effort = z.enum(['low', 'medium', 'high', 'xhigh', 'max'])
export type Effort = z.infer<typeof Effort>

export const AgentConfig = z.object({
  vendor: Vendor,
  /** Model alias or full name. Empty string means "the CLI's own default". */
  model: z.string().default(''),
  effort: Effort.default('medium'),
  /** Optional persona layered on top of the protocol's system prompt. */
  persona: z.string().default(''),
})
export type AgentConfig = z.infer<typeof AgentConfig>

/**
 * Capability granted to a single agent invocation.
 *
 * `read` is the default everywhere. `write` is only reachable through a
 * recorded, unconsumed human approval — see {@link Approval}. There is
 * deliberately no third, broader level: Parley never passes a `--dangerously-*`
 * or `--allow-dangerously-*` flag to either CLI.
 */
export const Capability = z.enum(['none', 'read', 'write'])
export type Capability = z.infer<typeof Capability>

// ─── Token accounting ────────────────────────────────────────────────────────

export const Usage = z.object({
  inputTokens: z.number().int().nonnegative().default(0),
  cachedInputTokens: z.number().int().nonnegative().default(0),
  outputTokens: z.number().int().nonnegative().default(0),
  reasoningTokens: z.number().int().nonnegative().default(0),
  /**
   * Cost as *reported by the CLI*, in USD. Subscription plans generally report
   * 0, so this is an observability figure and a loop-cap input — never a bill.
   */
  costUsd: z.number().nonnegative().default(0),
})
export type Usage = z.infer<typeof Usage>

export const emptyUsage = (): Usage => ({
  inputTokens: 0,
  cachedInputTokens: 0,
  outputTokens: 0,
  reasoningTokens: 0,
  costUsd: 0,
})

export const addUsage = (a: Usage, b: Usage): Usage => ({
  inputTokens: a.inputTokens + b.inputTokens,
  cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
  outputTokens: a.outputTokens + b.outputTokens,
  reasoningTokens: a.reasoningTokens + b.reasoningTokens,
  costUsd: a.costUsd + b.costUsd,
})

// ─── Approvals ───────────────────────────────────────────────────────────────

export const ApprovalScope = z.enum([
  /** Permits one write-capable milestone execution (a resume included). */
  'milestone.execute',
  /** Permits starting a loop that may write to the repository. */
  'loop.write',
  /**
   * Permits one fast-forward of the origin checkout onto a plan branch — the
   * single moment isolated work reaches the user's tree, recorded like every
   * other authorisation to touch it.
   */
  'plan.land',
])
export type ApprovalScope = z.infer<typeof ApprovalScope>

/**
 * A single-use, recorded human authorisation.
 *
 * The invariant enforced in the store and the pipeline: a write-capable run
 * requires an approval whose `subjectId` matches, whose scope matches, and
 * whose `consumedAt` is null. Starting the run consumes it. Re-running the same
 * milestone therefore requires a fresh approval — approval never accumulates.
 */
export const Approval = z.object({
  id: Id,
  scope: ApprovalScope,
  subjectId: Id,
  /** Human-readable record of exactly what was shown to the user. */
  summary: z.string(),
  grantedAt: Timestamp,
  consumedAt: Timestamp.nullable().default(null),
})
export type Approval = z.infer<typeof Approval>

// ─── Parley sessions (debate + review) ───────────────────────────────────────

export const SessionKind = z.enum([
  /** Two agents argue a product or design question to a scored verdict. */
  'debate',
  /** Two agents independently audit a repository, then reconcile findings. */
  'review',
])
export type SessionKind = z.infer<typeof SessionKind>

export const SessionStatus = z.enum([
  'idle',
  'running',
  'paused',
  'stopping',
  'complete',
  'failed',
  'cancelled',
])
export type SessionStatus = z.infer<typeof SessionStatus>

/** A participant's position in the session's seating order. */
export const Seat = z.number().int().nonnegative()
export type Seat = z.infer<typeof Seat>

export const Turn = z.object({
  id: Id,
  sessionId: Id,
  index: z.number().int().nonnegative(),
  /** Which participant spoke — an index into {@link Session.participants}. */
  seat: Seat,
  vendor: Vendor,
  model: z.string(),
  /** The protocol stage this turn was produced under. */
  stage: z.string(),
  text: z.string(),
  usage: Usage,
  startedAt: Timestamp,
  endedAt: Timestamp.nullable().default(null),
  error: z.string().nullable().default(null),
})
export type Turn = z.infer<typeof Turn>

/**
 * Who a mid-session message reaches: every seat, or exactly one.
 *
 * The stored legacy vocabulary — 'both', 'a', 'b' — reads as 'all', 0 and 1.
 */
export const InterjectionTarget = z.union([z.literal('all'), Seat])
export type InterjectionTarget = z.infer<typeof InterjectionTarget>

/**
 * A mid-session human message.
 *
 * `all` is visible to every seat. A seat number is a whisper: the other seats
 * never see it, which is what makes it useful for testing whether one agent
 * will hold a position under private pressure.
 */
export const Interjection = z.object({
  id: Id,
  sessionId: Id,
  target: InterjectionTarget,
  text: z.string().min(1),
  /** Index of the next turn at the time it was queued. */
  atTurnIndex: z.number().int().nonnegative(),
  createdAt: Timestamp,
  /** When every seat it was addressed to had taken it, or null until then. */
  deliveredAt: Timestamp.nullable().default(null),
})
export type Interjection = z.infer<typeof Interjection>

/** Five dimensions, each scored 0–10 by the agents at verdict time. */
export const ScoreDimension = z.enum([
  'correctness',
  'robustness',
  'clarity',
  'maintainability',
  'risk',
])
export type ScoreDimension = z.infer<typeof ScoreDimension>

export const Verdict = z.object({
  sessionId: Id,
  /** One-line resolution. */
  decision: z.string(),
  rationale: z.string(),
  scores: z.record(ScoreDimension, z.number().min(0).max(10)),
  /** 0–1. Deliberately separate from the scores: agreement is not confidence. */
  confidence: z.number().min(0).max(1),
  /** Positions the losing side still holds. Preserved, never summarised away. */
  dissent: z.string(),
  /** Full rendered report, persisted immutably. */
  report: z.string(),
  createdAt: Timestamp,
})
export type Verdict = z.infer<typeof Verdict>

export const FindingPriority = z.enum(['P0', 'P1', 'P2', 'P3'])
export type FindingPriority = z.infer<typeof FindingPriority>

export const FindingStatus = z.enum([
  /** Both agents agree it is real and evidenced. */
  'confirmed',
  /** Raised, investigated, and found not to hold. Kept for the audit trail. */
  'dismissed',
  /** Raised but not corroborated by file/symbol evidence. */
  'unsupported',
])
export type FindingStatus = z.infer<typeof FindingStatus>

export const Evidence = z.object({
  path: z.string(),
  line: z.number().int().positive().nullable().default(null),
  symbol: z.string().default(''),
  excerpt: z.string().default(''),
})
export type Evidence = z.infer<typeof Evidence>

export const Finding = z.object({
  id: Id,
  sessionId: Id,
  priority: FindingPriority,
  status: FindingStatus,
  title: z.string(),
  detail: z.string(),
  /** A confirmed finding must carry at least one evidence entry. */
  evidence: z.array(Evidence).default([]),
  /** The seat of the participant that raised it. */
  raisedBy: Seat,
  createdAt: Timestamp,
})
export type Finding = z.infer<typeof Finding>

export const Session = z.object({
  id: Id,
  kind: SessionKind,
  status: SessionStatus,
  /** The question, or the review brief. */
  matter: z.string().min(1),
  project: z.string().default(''),
  /** Absolute path. Required for `review`, optional for `debate`. */
  repoPath: z.string().nullable().default(null),
  /**
   * The session's participants, in seat order.
   *
   * Seats 0 and 1 are today's sides a and b: the runner still schedules a
   * two-sided exchange, and the stage and closing-sequence redesign that makes
   * more seats meaningful arrives later in this series. Stored as an array now
   * so every record is already the shape that work needs. Minimum two — a
   * parley needs a counterparty; the ceiling arrives with the surface that
   * lets anyone ask for more.
   */
  participants: z.array(AgentConfig).min(2),
  maxTurns: z.number().int().min(2).max(40).default(6),
  usage: Usage,
  /**
   * True when this record was produced by the deterministic mock adapters.
   * Persisted so a mock run can never be mistaken for real work after the fact.
   */
  mock: z.boolean().default(false),
  createdAt: Timestamp,
  endedAt: Timestamp.nullable().default(null),
  error: z.string().nullable().default(null),
  /**
   * When the user put this session out of the way, or null.
   *
   * Archiving hides; it does not delete. A finished session is the record of
   * why a decision was taken and why a repository looks the way it does, and
   * wanting a shorter list is not a reason to lose that.
   */
  archivedAt: Timestamp.nullable().default(null),
})
export type Session = z.infer<typeof Session>

// ─── Work plans (post-verdict workflows) ─────────────────────────────────────

export const WorkPlanKind = z.enum([
  'implementation',
  'validation',
  'remediation',
  'migration',
  'research',
])
export type WorkPlanKind = z.infer<typeof WorkPlanKind>

export const MilestoneStatus = z.enum([
  'planned',
  'audited',
  'approved',
  'executing',
  'testing',
  'reviewing',
  'complete',
  'rejected',
  'failed',
])
export type MilestoneStatus = z.infer<typeof MilestoneStatus>

/**
 * What deleting a session would destroy.
 *
 * Shown before the fact, because two sessions can look identical in a list and
 * be entirely different to lose: one is an abandoned conversation, the other is
 * the only record of why a repository looks the way it does. "Are you sure?"
 * cannot tell them apart; this can.
 */
export interface SessionDeletionImpact {
  turns: number
  hasVerdict: boolean
  /** Verdict findings and ledger findings destroyed with the session. */
  findings: number
  /** Immutable ledger decisions destroyed with the session. */
  dispositions: number
  plans: number
  milestones: number
  /** Milestones that ran to completion — these wrote to a repository. */
  completedMilestones: number
  /** Repositories that completed work was written to. */
  repos: string[]
  /**
   * Consumed approvals, which are deliberately **kept**.
   *
   * Each one records that a write to a named repository was authorised, and is
   * self-describing without the session. Orphaning them on purpose is better
   * than erasing the only evidence that permission was given.
   */
  retainedApprovals: number
  /**
   * Worktree branches that never landed. Their commits exist nowhere else, so
   * deleting the session quietly strands them unless this is said up front.
   */
  unlandedWorktrees: number
  /**
   * Pending foreman proposals anchored to this session. Deleting it makes
   * them unacceptable — acceptance requires the anchor's verdict — so the
   * dialog says so rather than letting a dead proposal sit in the queue.
   */
  pendingForemanProposals: number
}

/**
 * A deliberate break, and the claim that the suite would notice it.
 *
 * Passing tests say the code works on the paths someone thought to write. They
 * say nothing about whether a *wrong* implementation would have been caught, and
 * that gap produced every serious defect observed in this pipeline's first real
 * use: a harness that reported success having executed nothing, a censored view
 * that could hardcode the two fields no test varied, state that could go stale
 * behind correct events, a simulator that ignored its own seed.
 *
 * Each of those was found by hand — edit one line, re-run, see whether anything
 * fails. This makes the workbench do it. A milestone declares the wrong
 * implementations its tests are supposed to exclude; Parley applies each one and
 * requires the verification command to fail. A mutation that survives is not a
 * style opinion, it is a demonstration that the milestone's central claim rests
 * on nothing.
 */
export const Mutation = z.object({
  /** Repository-relative path of the file to break. */
  file: z.string().min(1),
  /** Exact text to replace. Must appear exactly once, or the mutation is void. */
  find: z.string().min(1),
  /** What to put in its place — the plausible wrong implementation. */
  replace: z.string(),
  /** The mistake being simulated, in the planner's own words. */
  describes: z.string().min(1),
})
export type Mutation = z.infer<typeof Mutation>

export const MutationResult = z.object({
  describes: z.string(),
  file: z.string(),
  /** True when the suite failed as it should have — the claim is pinned. */
  caught: z.boolean(),
  /**
   * Set when the mutation could not be applied at all: the text was absent, or
   * present more than once. Neither caught nor surviving — simply not a test.
   */
  skipped: z.string().default(''),
  // Why it was skipped, kept separate from the human-readable reason because the
  // two kinds need different handling: an unapplied anchor can be repaired against
  // the real file and re-run, whereas a missing verification command is a defect in
  // the plan itself and no amount of retrying will fix it.
  skipKind: z.enum(['', 'unapplied', 'no-test-command', 'crashed']).default(''),
  exitCode: z.number().int().nullable().default(null),
})
export type MutationResult = z.infer<typeof MutationResult>

export const TestResult = z.object({
  command: z.string(),
  exitCode: z.number().int(),
  /**
   * Set when the command was killed by a signal rather than exiting.
   *
   * "The tests failed" and "the test runner crashed" are different facts that
   * demand different fixes, and both arrive as a non-zero result. Nullable with
   * a default so results recorded before this existed still parse.
   */
  signal: z.string().nullable().default(null),
  /**
   * True when Parley killed the command for exceeding its own time limit.
   *
   * Distinct from `signal` alone. A timeout kills with SIGTERM, so without this
   * a hang reports as "killed by SIGTERM" and sends the reader looking for what
   * killed the process — when the answer is that nothing did: it never
   * finished, and the deadline expired. Nullable-free with a false default so
   * results recorded before this existed read as "not a timeout", which is the
   * safe assumption for a run that produced a real exit code.
   */
  timedOut: z.boolean().default(false),
  stdout: z.string(),
  stderr: z.string(),
  durationMs: z.number().int().nonnegative(),
  ranAt: Timestamp,
})
export type TestResult = z.infer<typeof TestResult>

/**
 * The planner's verdict on one audit finding.
 *
 * Structured rather than prose because this is the most useful artifact a run
 * produces — it is where the planner either concedes a finding or overrules the
 * auditor and says why — and it was previously readable only by querying the
 * database.
 */
export const CorrectionDisposition = z.object({
  finding: z.string(),
  /** accepted, rejected, or whatever the planner actually wrote. */
  disposition: z.string(),
  note: z.string(),
})
export type CorrectionDisposition = z.infer<typeof CorrectionDisposition>

/**
 * What the renderer may know about a preserved run.
 *
 * A summary on purpose: the full run-state blob carries the tree baseline
 * (potentially megabytes of diff for a dirty checkout) and both agents'
 * vendor resume ids, none of which any surface needs. The blob stays in the
 * main process behind a dedicated repo accessor; this is the shape that rides
 * on milestone rows and events. Its presence on a failed milestone is what
 * "resumable" means.
 */
export const MilestoneRunState = z.object({
  startedAt: Timestamp,
  /** The remediation round the run was in when it stopped. */
  round: z.number().int().nonnegative(),
  /** When the run last showed real activity. Null before any was seen. */
  lastActivityAt: Timestamp.nullable().default(null),
  /** The cross-vendor stall inspection's verdict, when one ran. */
  lastInspection: z
    .object({ at: Timestamp, verdict: z.string(), note: z.string() })
    .nullable()
    .default(null),
})
export type MilestoneRunState = z.infer<typeof MilestoneRunState>

export const Milestone = z.object({
  id: Id,
  planId: Id,
  index: z.number().int().nonnegative(),
  title: z.string(),
  intent: z.string(),
  /** Files the plan expects to touch. Used to scope the diff review. */
  expectedPaths: z.array(z.string()).default([]),
  status: MilestoneStatus,
  /** The auditing agent's disposition on this milestone, recorded verbatim. */
  auditNote: z.string().default(''),
  /** Deterministic verification, run by Parley itself — not by an agent. */
  testCommand: z.string().default(''),
  testResult: TestResult.nullable().default(null),
  /** Wrong implementations this milestone's tests are meant to exclude. */
  mutations: z.array(Mutation).default([]),
  /** What happened when each was applied. Empty until verification runs. */
  mutationResults: z.array(MutationResult).default([]),
  /** Independent post-execution review by the agent that did *not* execute. */
  reviewNote: z.string().default(''),
  /**
   * The reviewer's stop-the-milestone findings, and its merely-worth-saying ones.
   *
   * Kept apart because `reviewPassed` is derived from `reviewBlocking` being empty:
   * conflating the two in the record would hide the one distinction the review
   * contract turns on. `reviewNote` remains the human-readable assembly of both.
   */
  reviewBlocking: z.array(z.string()).default([]),
  reviewNotes: z.array(z.string()).default([]),
  reviewPassed: z.boolean().nullable().default(null),
  /**
   * True when the work was already in the tree and Parley verified it rather
   * than authoring it.
   *
   * A milestone can legitimately reach `complete` this way — the deterministic
   * tests and the independent cross-vendor review still ran — but the record
   * must never imply Parley's executor wrote the code when it did not.
   */
  adopted: z.boolean().default(false),
  approvalId: Id.nullable().default(null),
  createdAt: Timestamp,
  completedAt: Timestamp.nullable().default(null),
  /** See {@link MilestoneRunState}. Optional: absent means nothing preserved. */
  runState: MilestoneRunState.nullable().optional(),
})
export type Milestone = z.infer<typeof Milestone>

/**
 * Where a plan's milestones execute.
 *
 * `checkout` is the original behavior: the executor writes into the live
 * checkout at repoPath, and completed work is left uncommitted for the user.
 * `worktree` isolates execution in a per-plan git worktree on its own branch;
 * Parley commits each passing milestone there, and nothing reaches the user's
 * checkout until they land the branch — fast-forward only, as a decision hold.
 */
export const WorktreeIsolation = z.enum(['checkout', 'worktree'])
export type WorktreeIsolation = z.infer<typeof WorktreeIsolation>

export const WorkPlan = z.object({
  id: Id,
  /** The verdict this plan descends from. */
  sessionId: Id,
  kind: WorkPlanKind,
  title: z.string(),
  repoPath: z.string(),
  /** Who plans, who audits/executes, who independently reviews. */
  planner: AgentConfig,
  executor: AgentConfig,
  reviewer: AgentConfig,
  status: z.enum([
    'drafting',
    'auditing',
    /** The planner is answering the audit before the human sees the plan. */
    'correcting',
    /** Stopped on a question only the user can answer. */
    'awaiting-clarification',
    'ready',
    'running',
    'complete',
    'failed',
    'blocked',
    'cancelled',
  ]),
  /** The blocking question, when `status` is `awaiting-clarification`. */
  question: z.string().default(''),
  /** The planner's dispositions on the audit, recorded verbatim. */
  correctionNote: z.string().default(''),
  /** The same dispositions, structured, so they can be shown as a table. */
  correctionDispositions: z.array(CorrectionDisposition).default([]),
  usage: Usage,
  isolation: WorktreeIsolation.default('checkout'),
  /**
   * Shell-free command run once when the plan's worktree is created — the
   * `npm ci` class of step, without which a fresh worktree cannot even run
   * its own test commands. Meaningless (and unused) for checkout isolation.
   */
  setupCommand: z.string().default(''),
  /** See {@link Session.mock}. */
  mock: z.boolean().default(false),
  createdAt: Timestamp,
})
export type WorkPlan = z.infer<typeof WorkPlan>

/**
 * The registry row for a plan's isolated checkout.
 *
 * The row is registry, not truth: the truth is the directory and the branch,
 * and startup reconciliation re-derives honesty (the orphaned flag) from what
 * actually survives on disk. Rows are never deleted by reconciliation — a
 * branch can outlive its directory and still carry unlanded commits.
 */
export const Worktree = z.object({
  planId: Id,
  /** The repository the worktree was created from, and lands back into. */
  originPath: z.string(),
  path: z.string(),
  branch: z.string(),
  /** What the origin had checked out at creation — landing guidance, not law. */
  baseBranch: z.string().default(''),
  baseCommit: z.string(),
  createdAt: Timestamp,
  landedAt: Timestamp.nullable().default(null),
  lastError: z.string().default(''),
  /** The directory or origin vanished. The branch may still hold the work. */
  orphaned: z.boolean().default(false),
})
export type Worktree = z.infer<typeof Worktree>

// ─── Backlog and learnings ───────────────────────────────────────────────────

/**
 * An item's place in its lifecycle. `proposed` is agent output awaiting a
 * human (stow files here); deterministic ingestion files straight to `open`
 * because its sources are already structured record. `planned` carries the
 * plan that targeted it; `closure-proposed` is the pipeline saying "this
 * looks done — confirm it", never closing on its own.
 */
export const BacklogItemState = z.enum([
  'proposed',
  'open',
  'planned',
  'closure-proposed',
  'done',
  'dropped',
])
export type BacklogItemState = z.infer<typeof BacklogItemState>

export const BacklogItemSource = z.enum(['review-finding', 'accepted-risk', 'stow', 'manual'])
export type BacklogItemSource = z.infer<typeof BacklogItemSource>

/**
 * One unit of repo-scoped work worth remembering.
 *
 * The id is random; `contentHash` is only a dedupe key against *live* items —
 * a done or dropped item must never block a genuine recurrence from filing
 * fresh. Evidence is copied, never referenced: review Finding rows are
 * wholesale-replaced per session closing, so their ids are unstable by
 * design. `mock` is invariant-level — fabricated findings must never read as
 * real work in a real repository's backlog.
 */
export const BacklogItem = z.object({
  id: Id,
  /** Canonicalised — symlink spellings must not fork a repo's backlog. */
  repoPath: z.string(),
  contentHash: z.string(),
  title: z.string().min(1),
  detail: z.string().default(''),
  priority: FindingPriority.nullable().default(null),
  state: BacklogItemState,
  source: BacklogItemSource,
  originSessionId: Id.nullable().default(null),
  /** The plan that targeted it, while `planned` or `closure-proposed`. */
  planId: Id.nullable().default(null),
  evidence: z.array(Evidence).default([]),
  /** Item ids that should land first. Inert once a blocker is done/dropped. */
  blockedBy: z.array(Id).default([]),
  mock: z.boolean().default(false),
  createdAt: Timestamp,
  updatedAt: Timestamp,
})
export type BacklogItem = z.infer<typeof BacklogItem>

/**
 * The append-only trail: every state the item entered (creation appends its
 * initial state, so replaying the trail always reproduces the column — a
 * pinned test), plus `resighted` for a live-item collision.
 */
export const BacklogEventKind = z.enum([
  'resighted',
  'proposed',
  'open',
  'planned',
  'closure-proposed',
  'done',
  'dropped',
])
export type BacklogEventKind = z.infer<typeof BacklogEventKind>

export const BacklogEventSource = z.enum(['human', 'pipeline', 'stow'])
export type BacklogEventSource = z.infer<typeof BacklogEventSource>

export const BacklogEvent = z.object({
  id: Id,
  itemId: Id,
  kind: BacklogEventKind,
  note: z.string().default(''),
  source: BacklogEventSource,
  /** Monotonic order — same-millisecond events must not scramble the trail. */
  seq: z.number().int().positive(),
  createdAt: Timestamp,
})
export type BacklogEvent = z.infer<typeof BacklogEvent>

/**
 * A durable, curated lesson about one repository. Confirmed learnings ride
 * every new plan brief for the repo (capped at render time, attributed);
 * retiring is the curation lever. Stow files `proposed`; a human confirms.
 */
export const Learning = z.object({
  id: Id,
  repoPath: z.string(),
  text: z.string().min(1),
  state: z.enum(['proposed', 'confirmed', 'retired']),
  source: z.enum(['stow', 'manual']),
  originSessionId: Id.nullable().default(null),
  mock: z.boolean().default(false),
  createdAt: Timestamp,
})
export type Learning = z.infer<typeof Learning>

// ─── Foreman proposals ──────────────────────────────────────────────────────

/**
 * `running` is the attempt row filed before the agent turn dispatches, so an
 * interrupted run is a recorded fact rather than a vanished spend; startup
 * reconciliation flips leftovers to `failed`. `superseded` is what a pending
 * proposal becomes when a newer run finalizes — the record of every read the
 * foreman ever took, not just the surviving one.
 */
export const ForemanProposalState = z.enum([
  'running',
  'proposed',
  'accepted',
  'rejected',
  'superseded',
  'failed',
])
export type ForemanProposalState = z.infer<typeof ForemanProposalState>

/** An open item the foreman chose not to take, with its argument. */
export const ForemanDeferral = z.object({
  itemId: Id,
  reason: z.string().default(''),
})
export type ForemanDeferral = z.infer<typeof ForemanDeferral>

/**
 * One read of a repository's backlog and the plan it argues for.
 *
 * Proposal power only: nothing here executes. Accepting routes through the
 * normal plan-creation path in the same transaction that stamps `planId`;
 * rejecting records the note. The foreman never transitions backlog state.
 */
export const ForemanProposal = z.object({
  id: Id,
  /** Canonicalised, like the backlog it reads. */
  repoPath: z.string(),
  state: ForemanProposalState,
  title: z.string().default(''),
  rationale: z.string().default(''),
  /** The open items the proposal selects, validated at filing. */
  itemIds: z.array(Id).default([]),
  deferred: z.array(ForemanDeferral).default([]),
  /** Every open item id the foreman was shown — the staleness baseline. */
  openSnapshot: z.array(Id).default([]),
  isolation: WorktreeIsolation,
  /** Draft operator note, seeded into the accept dialog attributed to the foreman. */
  note: z.string().default(''),
  /** The session whose verdict anchors the plan this proposal argues for. */
  anchorSessionId: Id.nullable().default(null),
  /** Set when accepted — the plan the acceptance created. */
  planId: Id.nullable().default(null),
  vendor: Vendor,
  usage: Usage,
  mock: z.boolean().default(false),
  createdAt: Timestamp,
  decidedAt: Timestamp.nullable().default(null),
  /** Rejection reason, failure error, or honest validation drops at filing. */
  decisionNote: z.string().default(''),
})
export type ForemanProposal = z.infer<typeof ForemanProposal>

// ─── Finding ledger ─────────────────────────────────────────────────────────

/**
 * Whether an occurrence can stop a milestone from being approved.
 *
 * The source is deliberately separate: an audit concern, an execution-review
 * concern and an adoption-review concern all gate in the same way, while
 * their provenance remains intact. There is deliberately no `correction`
 * member — the planner's answer to the audit is recorded on the plan, never
 * in the ledger, because an agent answering its own audit must not be able to
 * touch the record the human gate reads.
 */
export const FindingOccurrenceKind = z.enum(['blocking', 'note'])
export type FindingOccurrenceKind = z.infer<typeof FindingOccurrenceKind>

export const FindingOccurrenceSource = z.enum(['audit', 'review', 'adoption'])
export type FindingOccurrenceSource = z.infer<typeof FindingOccurrenceSource>

/**
 * The stable, content-addressed part of a ledger entry.
 *
 * Scope belongs to occurrences, not findings. The same objection can be raised
 * against several milestones without one milestone's disposition clearing the
 * others.
 */
export const LedgerFinding = z.object({
  id: Id,
  sessionId: Id,
  text: z.string().min(1),
  normalizedText: z.string().min(1),
  createdAt: Timestamp,
})
export type LedgerFinding = z.infer<typeof LedgerFinding>

/**
 * One time a finding was raised, with enough provenance to distinguish repeat
 * findings and separate remediation rounds.
 */
export const FindingOccurrence = z.object({
  id: Id,
  findingId: Id,
  planId: Id,
  milestoneId: Id.nullable().default(null),
  round: z.number().int().nonnegative().nullable().default(null),
  kind: FindingOccurrenceKind,
  source: FindingOccurrenceSource,
  seq: z.number().int().positive(),
  createdAt: Timestamp,
})
export type FindingOccurrence = z.infer<typeof FindingOccurrence>

export const FindingDispositionState = z.enum(['resolved', 'dismissed', 'accepted-risk'])
export type FindingDispositionState = z.infer<typeof FindingDispositionState>

export const FindingDispositionSource = z.enum(['human', 'pipeline'])
export type FindingDispositionSource = z.infer<typeof FindingDispositionSource>

/**
 * An immutable decision added to the ledger.
 *
 * `occurrenceId` names exactly one occurrence. A null scope is an explicit
 * finding-wide decision and covers only occurrences which existed at the time;
 * a later recurrence therefore surfaces as open again.
 */
export const FindingDisposition = z.object({
  id: Id,
  findingId: Id,
  occurrenceId: Id.nullable(),
  state: FindingDispositionState,
  note: z.string().default(''),
  source: FindingDispositionSource,
  seq: z.number().int().positive(),
  createdAt: Timestamp,
})
export type FindingDisposition = z.infer<typeof FindingDisposition>

export const FindingLedgerState = z.union([z.literal('open'), FindingDispositionState])
export type FindingLedgerState = z.infer<typeof FindingLedgerState>

// ─── Loops (autonomous run-until-condition) ──────────────────────────────────

/**
 * Hard bounds on an autonomous loop. All three are enforced by Parley, not by
 * the agent, and are checked *before* each iteration is dispatched. A loop with
 * no cap cannot be created: the schema requires positive values.
 */
export const LoopCaps = z.object({
  maxIterations: z.number().int().min(1).max(100),
  maxSpendUsd: z.number().min(0),
  maxWallClockMs: z.number().int().min(1000),
})
export type LoopCaps = z.infer<typeof LoopCaps>

export const LoopExitKind = z.enum([
  /** A deterministic command exiting 0 — run by Parley, not self-reported. */
  'command',
  /** The reviewing agent judges the goal met. Requires a second opinion. */
  'review',
])
export type LoopExitKind = z.infer<typeof LoopExitKind>

export const LoopExitCondition = z.object({
  kind: LoopExitKind,
  /** Shell-free command line for `kind: 'command'`, split on spawn. */
  command: z.string().default(''),
  /** Natural-language completion test for `kind: 'review'`. */
  criterion: z.string().default(''),
})
export type LoopExitCondition = z.infer<typeof LoopExitCondition>

export const LoopStatus = z.enum([
  'idle',
  'running',
  'paused',
  'succeeded',
  /** A cap was hit before the exit condition held. Not a success. */
  'exhausted',
  'killed',
  'failed',
])
export type LoopStatus = z.infer<typeof LoopStatus>

export const LoopIteration = z.object({
  id: Id,
  loopId: Id,
  index: z.number().int().nonnegative(),
  vendor: Vendor,
  summary: z.string(),
  usage: Usage,
  /** Whether the exit condition held after this iteration. */
  exitMet: z.boolean(),
  exitDetail: z.string().default(''),
  startedAt: Timestamp,
  endedAt: Timestamp.nullable().default(null),
  error: z.string().nullable().default(null),
})
export type LoopIteration = z.infer<typeof LoopIteration>

export const Loop = z.object({
  id: Id,
  goal: z.string().min(1),
  repoPath: z.string(),
  worker: AgentConfig,
  /** Independent verifier. Must differ in vendor from `worker` where possible. */
  verifier: AgentConfig,
  exit: LoopExitCondition,
  caps: LoopCaps,
  capability: Capability,
  approvalId: Id.nullable().default(null),
  status: LoopStatus,
  usage: Usage,
  iterationCount: z.number().int().nonnegative().default(0),
  /** See {@link Session.mock}. */
  mock: z.boolean().default(false),
  startedAt: Timestamp,
  endedAt: Timestamp.nullable().default(null),
  stopReason: z.string().default(''),
  /**
   * When the loop last showed real activity, for stall detection. Written by
   * the liveness watchdog on activity only (throttled), never on a tick.
   * Optional: absent means the watchdog never saw this loop run.
   */
  lastActivityAt: Timestamp.nullable().optional(),
})
export type Loop = z.infer<typeof Loop>

// ─── Grid (parallel terminal panes) ──────────────────────────────────────────

export const PaneKind = z.enum(['shell', 'claude', 'codex'])
export type PaneKind = z.infer<typeof PaneKind>

export const PaneStatus = z.enum(['starting', 'live', 'exited'])
export type PaneStatus = z.infer<typeof PaneStatus>

export const Pane = z.object({
  id: Id,
  kind: PaneKind,
  title: z.string(),
  cwd: z.string(),
  status: PaneStatus,
  exitCode: z.number().int().nullable().default(null),
  createdAt: Timestamp,
})
export type Pane = z.infer<typeof Pane>

/**
 * Binary split tree for the live grid.
 *
 * Leaves hold a *slot* id, not a pane id. A slot outlives the process in it: a
 * restored layout has slots whose agent panes have not been started yet, and
 * closing a pane without removing its slot would otherwise be unrepresentable.
 */
export type LayoutNode =
  | { type: 'leaf'; slotId: Id }
  | { type: 'split'; direction: 'row' | 'column'; ratio: number; a: LayoutNode; b: LayoutNode }

export const LayoutNode: z.ZodType<LayoutNode> = z.lazy(() =>
  z.union([
    z.object({ type: z.literal('leaf'), slotId: Id }),
    z.object({
      type: z.literal('split'),
      direction: z.enum(['row', 'column']),
      ratio: z.number().min(0.15).max(0.85),
      a: LayoutNode,
      b: LayoutNode,
    }),
  ]),
)

/**
 * The persisted form of a grid arrangement.
 *
 * Carries no ids at all: a saved layout describes what each pane *is* — its kind
 * and its folder — so restoring it mints fresh slots rather than resurrecting
 * dead process ids.
 */
export type SavedLayoutNode =
  | { type: 'leaf'; kind: PaneKind; cwd: string }
  | {
      type: 'split'
      direction: 'row' | 'column'
      ratio: number
      a: SavedLayoutNode
      b: SavedLayoutNode
    }

export const SavedLayoutNode: z.ZodType<SavedLayoutNode> = z.lazy(() =>
  z.union([
    z.object({ type: z.literal('leaf'), kind: PaneKind, cwd: z.string().min(1) }),
    z.object({
      type: z.literal('split'),
      direction: z.enum(['row', 'column']),
      ratio: z.number().min(0.15).max(0.85),
      a: SavedLayoutNode,
      b: SavedLayoutNode,
    }),
  ]),
)

export const GridLayout = z.object({
  id: Id,
  name: z.string().min(1).max(120),
  /**
   * Pre-fills the toolbar target when the layout is opened. A default, never a
   * constraint — panes in a saved layout may sit in different folders, and
   * working across two repositories at once is a normal thing to want.
   */
  defaultFolder: z.string().default(''),
  tree: SavedLayoutNode,
  createdAt: Timestamp,
  updatedAt: Timestamp,
})
export type GridLayout = z.infer<typeof GridLayout>

export const MAX_PANES = 16

/** A reusable prompt pack that can be dropped onto a pane. */
export const Skill = z.object({
  id: Id,
  name: z.string().min(1),
  description: z.string().default(''),
  prompt: z.string().min(1),
  /** Preferred vendor, or null for either. */
  vendorHint: Vendor.nullable().default(null),
  builtIn: z.boolean().default(false),
})
export type Skill = z.infer<typeof Skill>
