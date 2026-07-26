import { z } from 'zod'
import {
  AgentConfig,
  Capability,
  Id,
  LoopCaps,
  LoopExitCondition,
  PaneKind,
  SavedLayoutNode,
  SessionKind,
  Skill,
  WorkPlanKind,
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
  agentA: AgentConfig,
  agentB: AgentConfig,
  maxTurns: z.number().int().min(2).max(40).default(6),
})

export const InterjectReq = z.object({
  sessionId: Id,
  target: z.enum(['both', 'a', 'b']),
  text: z.string().min(1).max(10_000),
})

export const SessionControlReq = z.object({ sessionId: Id })

export const CreatePlanReq = z.object({
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
  scope: z.enum(['milestone.execute', 'loop.write']),
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
})

export const PaneWriteReq = z.object({ paneId: Id, data: z.string() })
export const PaneResizeReq = z.object({
  paneId: Id,
  cols: z.number().int().min(2).max(2000),
  rows: z.number().int().min(2).max(1000),
})
export const PaneCloseReq = z.object({ paneId: Id })

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
/** Archiving hides a session from the list. It is reversible and deletes nothing. */
export const ArchiveSessionReq = z.object({ sessionId: Id, archived: z.boolean() })
export const ListSessionsReq = z.object({ includeArchived: z.boolean().default(false) })
/** Deleting is permanent. The impact query exists so it is never a blind click. */
export const DeleteSessionReq = z.object({ sessionId: Id })
export const GetPlanReq = z.object({ planId: Id })
export const GetLoopReq = z.object({ loopId: Id })

export const ExportReportReq = z.object({ sessionId: Id })

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
  'plan.create': CreatePlanReq,
  'plan.get': GetPlanReq,
  'plan.list': null,
  'plan.runMilestone': RunMilestoneReq,
  'plan.inspect': InspectMilestoneReq,
  'plan.answer': AnswerPlanReq,
  'plan.setTestCommand': SetTestCommandReq,
  'plan.adoptMilestone': AdoptMilestoneReq,
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

/** Uniform envelope so a thrown error in main never becomes an unhandled rejection. */
export type InvokeResult<T> = { ok: true; value: T } | { ok: false; error: string }

export interface AppInfo {
  /**
   * True when the deterministic mock adapters are in use.
   *
   * The UI must show this permanently and unmissably. A mock run produces
   * sessions, verdicts and reviews that look exactly like real ones while doing
   * no real work and writing no files, and a user who does not know which mode
   * they are in will read fabricated output as findings.
   */
  mock: boolean
  /**
   * The model this machine's `codex` is configured to use, if any.
   *
   * Offered as the first suggestion so the picker reflects the user's actual
   * install rather than a list baked in when the app was written.
   */
  codexDefaultModel: string
}

/** Result of probing for the two CLIs at startup. */
export interface CliHealth {
  vendor: 'claude' | 'codex'
  present: boolean
  version: string
  /** True when the CLI reports a logged-in subscription session. */
  authenticated: boolean
  detail: string
}
