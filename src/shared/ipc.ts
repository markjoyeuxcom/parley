import { z } from 'zod'
import {
  AgentConfig,
  Capability,
  ApprovalScope,
  FindingDispositionState,
  Id,
  InterjectionTarget,
  LoopCaps,
  EnvelopeCaps,
  LoopExitCondition,
  PaneKind,
  SavedLayoutNode,
  SessionKind,
  Skill,
  WorkPlanKind,
  WorktreeIsolation,
  type Vendor,
  type FindingDisposition,
  type FindingOccurrence,
  type LedgerFinding,
} from './domain'

/** Channel names. Namespaced so nothing collides with Electron internals. */
export const CH = {
  invoke: 'parley:invoke',
  event: 'parley:event',
  ptyData: 'parley:pty:data',
} as const

// ─── Request schemas ─────────────────────────────────────────────────────────
//
// Every privileged operation the renderer can ask for is listed here with a
// schema. The main process validates against these before touching anything;
// an unrecognised command or a payload that fails to parse is rejected.

export const StartSessionReq = z.object({
  kind: SessionKind,
  matter: z.string().min(1).max(20_000),
  project: z.string().max(200).default(''),
  repoPath: z.string().nullable().default(null),
  /**
   * The seats, in order. Seats 0 and 1 hold the exchange; any further seat
   * observes it and records an independent verdict. Capped at four: the
   * exchange schedule is two-seat, so extra chairs are assessors, and a bench
   * of more than two of them is spend without conversation.
   */
  participants: z.array(AgentConfig).min(2).max(4),
  maxTurns: z.number().int().min(2).max(40).default(6),
})

export const InterjectReq = z.object({
  sessionId: Id,
  target: InterjectionTarget,
  text: z.string().min(1).max(10_000),
})

export const SessionControlReq = z.object({ sessionId: Id })

export const CreatePlanReq = z.object({
  /** Where milestones execute — see {@link WorktreeIsolation}. */
  isolation: WorktreeIsolation.default('checkout'),
  /** Shell-free command run once at worktree creation (e.g. `npm ci`). */
  setupCommand: z.string().trim().max(400).default(''),
  /** Open backlog items this plan targets. Capped by construction. */
  backlogItemIds: z.array(Id).max(12).default([]),
  /** A pending foreman proposal this creation accepts — atomically, in the
   * same transaction as the plan row and the item flips. */
  foremanProposalId: Id.nullable().default(null),
  sessionId: Id,
  kind: WorkPlanKind,
  repoPath: z.string().min(1),
  planner: AgentConfig,
  executor: AgentConfig,
  reviewer: AgentConfig,
  /** Free text from the operator. Attributed, never blended into the verdict. */
  note: z.string().max(20_000).default(''),
})

export const GrantApprovalReq = z.object({
  // The canonical enum, not a re-declaration: an inline copy silently rejects
  // any scope added to the domain, at the one boundary that must accept it.
  scope: ApprovalScope,
  subjectId: Id,
  summary: z.string().min(1),
})

export const SetTestCommandReq = z.object({
  milestoneId: Id,
  command: z.string().max(500),
})

export const AnswerPlanReq = z.object({
  planId: Id,
  answer: z.string().min(1).max(10_000),
})

export const InspectMilestoneReq = z.object({ milestoneId: Id })
/** Stops a running milestone at its next boundary. The run state is kept. */
export const StopMilestoneReq = z.object({ milestoneId: Id })
/** Resumes from preserved run state. Must reference a fresh unconsumed approval. */
export const ResumeMilestoneReq = z.object({ milestoneId: Id, approvalId: Id })

/** No approval field: adopting verifies existing work and writes nothing. */
export const AdoptMilestoneReq = z.object({ milestoneId: Id })

export const RunMilestoneReq = z.object({
  milestoneId: Id,
  /** Must reference an unconsumed approval for this milestone. */
  approvalId: Id,
})

export const CreateLoopReq = z.object({
  goal: z.string().min(1).max(20_000),
  repoPath: z.string().min(1),
  worker: AgentConfig,
  verifier: AgentConfig,
  exit: LoopExitCondition,
  caps: LoopCaps,
  capability: Capability,
})

/**
 * Starting is separate from creating so a write-capable loop can be approved
 * against its own id — which does not exist until the loop record does.
 */
export const StartLoopReq = z.object({
  loopId: Id,
  /** Required when the loop's capability is `write`. */
  approvalId: Id.nullable().default(null),
})

export const LoopControlReq = z.object({ loopId: Id })

export const OpenPaneReq = z.object({
  kind: PaneKind,
  cwd: z.string().min(1),
  cols: z.number().int().min(2).max(2000),
  rows: z.number().int().min(2).max(1000),
  /**
   * Launch the CLI's OWN interactive session picker (`claude --resume`,
   * `codex resume`) — never Parley's governed resume ids. Ignored for shells.
   */
  resume: z.boolean().default(false),
})

export const PaneWriteReq = z.object({ paneId: Id, data: z.string() })
export const PaneResizeReq = z.object({
  paneId: Id,
  cols: z.number().int().min(2).max(2000),
  rows: z.number().int().min(2).max(1000),
})
export const PaneCloseReq = z.object({ paneId: Id })
export const PaneStopReq = z.object({ paneId: Id })
export const PaneIdentityReq = z.object({ cwd: z.string().min(1) })
/** The transcript text travels from the renderer — the buffer lives in xterm. */
export const SaveTranscriptReq = z.object({
  suggestedName: z.string().min(1).max(200),
  text: z.string().max(5_000_000),
})

export const RunSkillReq = z.object({ paneId: Id, skillId: Id })
export const SaveSkillReq = Skill.omit({ builtIn: true })

export const SaveLayoutReq = z.object({
  name: z.string().min(1).max(120),
  defaultFolder: z.string().default(''),
  tree: SavedLayoutNode,
})
export const LayoutIdReq = z.object({ layoutId: Id })

export const PickDirectoryReq = z.object({ title: z.string().default('Choose a folder') })

export const GetSessionReq = z.object({ sessionId: Id })
export const ListLedgerReq = z.object({ sessionId: Id })
/** Acknowledges a notice-class hold. Decision-class holds refuse — they clear by acting. */
export const AckHoldReq = z.object({ holdId: Id })

export const ListBacklogReq = z.object({
  repoPath: z.string().optional(),
  includeArchived: z.boolean().default(false),
})
export const DropBacklogItemReq = z.object({
  itemId: Id,
  note: z.string().trim().max(2000).default(''),
})
/** Reopens a planned or closure-proposed item; the plan edge is cleared. */
export const ReopenBacklogItemReq = z.object({ itemId: Id })
export const SetBacklogBlockedByReq = z.object({ itemId: Id, blockedBy: z.array(Id).max(50) })
/** Confirms a stow proposal into the open backlog. */
export const ConfirmBacklogItemReq = z.object({ itemId: Id })
/** Closes a closure-proposed item — the human half of the proposal. */
export const CloseBacklogItemReq = z.object({
  itemId: Id,
  note: z.string().trim().max(2000).default(''),
})
export const ListLearningsReq = z.object({
  repoPath: z.string().optional(),
  includeArchived: z.boolean().default(false),
})
/** One gated read of a repository's backlog by the chosen agent. */
export const RunForemanReq = z.object({ repoPath: z.string().min(1), cfg: AgentConfig })
export const ListForemanReq = z.object({ repoPath: z.string().optional() })
/** Rejects a pending proposal with the reason. Accepting has no endpoint —
 * it rides plan creation, atomically. */
export const RejectForemanReq = z.object({
  proposalId: Id,
  note: z.string().trim().max(2000).default(''),
})
/** Closes out a failed or blocked plan: cancelled on the record, items released. */
export const CancelPlanReq = z.object({ planId: Id })
/** Starts one unattended run within the bounds the human approved. */
export const StartEnvelopeReq = z.object({
  planId: Id,
  /** Must reference an unconsumed `plan.envelope` approval for this plan. */
  approvalId: Id,
  caps: EnvelopeCaps,
})
export const EnvelopePlanReq = z.object({ planId: Id })
/** Boots the freshly built Parley: decides the green offer, then relaunches. */
export const RelaunchSelfUpdateReq = z.object({ updateId: Id })
/** Declines the offer; the app keeps running the bytes it started with. */
export const DeclineSelfUpdateReq = z.object({ updateId: Id })
/** Confirms a proposed learning; confirmed learnings ride every new brief. */
export const ConfirmLearningReq = z.object({ learningId: Id })
/** Retires a learning so it stops riding briefs. Terminal — never deleted. */
export const RetireLearningReq = z.object({ learningId: Id })
export const DisposeLedgerFindingReq = z.object({
  sessionId: Id,
  findingId: Id,
  occurrenceId: Id.nullable(),
  state: FindingDispositionState,
  note: z.string().trim().min(1).max(4000),
})
/** Archiving hides a session from the list. It is reversible and deletes nothing. */
export const ArchiveSessionReq = z.object({ sessionId: Id, archived: z.boolean() })
export const ListSessionsReq = z.object({ includeArchived: z.boolean().default(false) })
export const ListReposReq = z.object({ includeArchived: z.boolean().default(false) })
export const ArchiveRepoReq = z.object({
  repoPath: z.string().min(1),
  archived: z.boolean(),
})
export const RepoContainerStatusReq = z.object({ repoPath: z.string().min(1) })
export const SetRepoContainerReq = z.object({
  repoPath: z.string().min(1),
  enabled: z.boolean(),
})
/** Deleting is permanent. The impact query exists so it is never a blind click. */
export const DeleteSessionReq = z.object({ sessionId: Id })
export const GetPlanReq = z.object({ planId: Id })
/**
 * Null repoPath lists globally (capped); a repoPath lists every plan for
 * that repository, uncapped — history must not fall off a global limit.
 */
export const ListPlansReq = z.object({
  repoPath: z.string().min(1).nullable().default(null),
})
/**
 * Lands a complete worktree plan's branch on the origin, fast-forward only.
 * Must reference an unconsumed `plan.land` approval — landing is the single
 * moment isolated work reaches the checkout, and it is recorded like every
 * other authorisation to touch it.
 */
export const LandPlanReq = z.object({ planId: Id, approvalId: Id })
export const GetLoopReq = z.object({ loopId: Id })

export const ExportReportReq = z.object({ sessionId: Id })
/** One read-only sweep filing proposed backlog items and learnings. */
export const StowSessionReq = z.object({ sessionId: Id })

/**
 * The full command table. Keys are the wire command names; values are the
 * request schemas. `null` means the command takes no payload.
 */
export const COMMANDS = {
  'app.info': null,
  'health.probe': null,
  'session.start': StartSessionReq,
  'session.list': ListSessionsReq,
  'session.archive': ArchiveSessionReq,
  'session.deletionImpact': DeleteSessionReq,
  'session.delete': DeleteSessionReq,
  'session.get': GetSessionReq,
  'session.interject': InterjectReq,
  'session.pause': SessionControlReq,
  'session.resume': SessionControlReq,
  'session.stop': SessionControlReq,
  'session.export': ExportReportReq,
  'session.stow': StowSessionReq,
  'ledger.list': ListLedgerReq,
  'ledger.dispose': DisposeLedgerFindingReq,
  'holds.list': null,
  'holds.ack': AckHoldReq,
  'backlog.list': ListBacklogReq,
  'backlog.drop': DropBacklogItemReq,
  'backlog.reopen': ReopenBacklogItemReq,
  'backlog.setBlockedBy': SetBacklogBlockedByReq,
  'backlog.confirm': ConfirmBacklogItemReq,
  'backlog.close': CloseBacklogItemReq,
  'learnings.list': ListLearningsReq,
  'learnings.confirm': ConfirmLearningReq,
  'learnings.retire': RetireLearningReq,
  'foreman.run': RunForemanReq,
  'foreman.list': ListForemanReq,
  'foreman.reject': RejectForemanReq,
  'selfupdate.pending': null,
  'selfupdate.relaunch': RelaunchSelfUpdateReq,
  'selfupdate.decline': DeclineSelfUpdateReq,
  'plan.create': CreatePlanReq,
  'plan.get': GetPlanReq,
  'plan.list': ListPlansReq,
  'plan.cancel': CancelPlanReq,
  'envelope.start': StartEnvelopeReq,
  'envelope.stop': EnvelopePlanReq,
  'envelope.list': EnvelopePlanReq,
  'repos.list': ListReposReq,
  'repos.archive': ArchiveRepoReq,
  'repo.containerStatus': RepoContainerStatusReq,
  'repo.setContainer': SetRepoContainerReq,
  'plan.runMilestone': RunMilestoneReq,
  'plan.inspect': InspectMilestoneReq,
  'plan.answer': AnswerPlanReq,
  'plan.setTestCommand': SetTestCommandReq,
  'plan.adoptMilestone': AdoptMilestoneReq,
  'plan.stopMilestone': StopMilestoneReq,
  'plan.resumeMilestone': ResumeMilestoneReq,
  'plan.land': LandPlanReq,
  'approval.grant': GrantApprovalReq,
  'approval.list': null,
  'loop.create': CreateLoopReq,
  'loop.start': StartLoopReq,
  'loop.list': null,
  'loop.get': GetLoopReq,
  'loop.pause': LoopControlReq,
  'loop.resume': LoopControlReq,
  'loop.kill': LoopControlReq,
  'pane.open': OpenPaneReq,
  'pane.write': PaneWriteReq,
  'pane.resize': PaneResizeReq,
  'pane.close': PaneCloseReq,
  'pane.stop': PaneStopReq,
  'pane.identity': PaneIdentityReq,
  'pane.saveTranscript': SaveTranscriptReq,
  'pane.list': null,
  'layout.save': SaveLayoutReq,
  'layout.list': null,
  'layout.delete': LayoutIdReq,
  'skill.list': null,
  'skill.save': SaveSkillReq,
  'skill.run': RunSkillReq,
  'dialog.pickDirectory': PickDirectoryReq,
} as const

export type CommandName = keyof typeof COMMANDS

export type CommandPayload<K extends CommandName> = (typeof COMMANDS)[K] extends z.ZodType
  ? z.infer<(typeof COMMANDS)[K] & z.ZodType>
  : undefined

/** One stable finding and its append-only occurrence and decision history. */
export interface LedgerEntry extends LedgerFinding {
  occurrences: FindingOccurrence[]
  dispositions: FindingDisposition[]
}

/** Uniform envelope so a thrown error in main never becomes an unhandled rejection. */
export type InvokeResult<T> = { ok: true; value: T } | { ok: false; error: string }

export async function toInvokeResult<T>(invoke: () => T | Promise<T>): Promise<InvokeResult<T>> {
  try {
    return { ok: true, value: await invoke() }
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : String(err) }
  }
}

export function unwrapInvokeResult<T>(result: InvokeResult<T>): T {
  if (!result.ok) throw new Error(result.error)
  return result.value
}

export interface AppInfo {
  /**
   * True when the deterministic mock adapters are in use.
   *
   * The UI must show this permanently and unmissably. A mock run produces
   * sessions, verdicts and reviews that look exactly like real ones while doing
   * no real work, and a user who does not know which mode they are in will read
   * fabricated output as findings.
   *
   * It is not read-only: executing a milestone under the mocks writes one
   * placeholder file into the repository, because the pipeline's changed-tree gate
   * cannot otherwise be exercised. Anything claiming mock mode writes nothing is
   * wrong, and was wrong here.
   */
  mock: boolean
  /**
   * The model this machine's `codex` is configured to use, if any.
   *
   * Offered as the first suggestion so the picker reflects the user's actual
   * install rather than a list baked in when the app was written.
   */
  codexDefaultModel: string
  /** Gemini model ids reported by this machine's `agy models` command. */
  agyModels: string[]
  /**
   * Canonical path of Parley's own checkout when running from source, null
   * when packaged. The renderer uses it only to explain the worktree-only
   * rule up front (greying the checkout option); the main process re-enforces
   * it at plan creation and again at execution, so a stale or absent value
   * here can never widen what is allowed.
   */
  selfRepoPath: string | null
}

/**
 * One repository as the Repos surface's sidebar sees it. Canonically keyed;
 * item and proposal counts are scoped to the running mode (they drive action
 * chips), plan counts are total.
 */
export interface RepoSummary {
  repoPath: string
  archived: boolean
  planCount: number
  /** Plans needing a human: failed, parked, blocked, or complete-unlanded. */
  attentionPlans: number
  openItems: number
  pendingTriage: number
  hasPendingProposal: boolean
}

/**
 * A pane header's identity line in one read. `git` is null outside a
 * repository; `worktree` is set only when the folder IS a registered plan
 * worktree — it says landed or not, and never "safe to remove".
 */
export interface PaneIdentity {
  git: {
    root: string
    branch: string
    dirty: boolean
    ahead: number
    behind: number
    hasUpstream: boolean
  } | null
  worktree: {
    planId: string
    originPath: string
    branch: string
    landed: boolean
    orphaned: boolean
  } | null
}

/**
 * The Repos Overview's dev-container section in one read: the standing
 * choice, whether the repository declares a configuration, and whether the
 * devcontainer CLI is installed. The cli probe is fresh on every read — a
 * stale "missing" after an install would be worse than the probe's cost.
 */
export interface RepoContainerStatus {
  enabled: boolean
  configPresent: boolean
  cli: { present: boolean; version: string; detail: string }
}

/** Result of probing for a governed CLI at startup. */
export interface CliHealth {
  vendor: Vendor
  present: boolean
  version: string
  /** True when the CLI reports a logged-in subscription session. */
  authenticated: boolean
  detail: string
}
