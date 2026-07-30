import type {
  AgentConfig,
  Approval,
  BacklogItem,
  Finding,
  FindingDisposition,
  FindingOccurrence,
  ForemanProposal,
  GridLayout,
  Id,
  Interjection,
  InterjectionTarget,
  Learning,
  Loop,
  LoopIteration,
  Milestone,
  Pane,
  SelfUpdate,
  Session,
  SessionDeletionImpact,
  Skill,
  Turn,
  Verdict,
  WorkPlan,
  Worktree,
} from '@shared/domain'
import type { AppEvent, PtyChunk } from '@shared/events'
import type { Hold } from '@shared/holds'
import type {
  AppInfo,
  CliHealth,
  CommandName,
  LedgerEntry,
  PaneIdentity,
  RepoContainerStatus,
  RepoSummary,
} from '@shared/ipc'

/** The preload bridge. The only channel out of the renderer. */
interface Bridge {
  invoke<T = unknown>(command: CommandName, payload?: unknown): Promise<T>
  onEvent(handler: (event: AppEvent) => void): () => void
  onPtyData(handler: (chunk: PtyChunk) => void): () => void
  platform: string
}

declare global {
  interface Window {
    parley: Bridge
  }
}

const bridge = (): Bridge => window.parley

export interface SessionDetail {
  session: Session
  turns: Turn[]
  interjections: Interjection[]
  verdict: Verdict | null
  findings: Finding[]
  ledger: LedgerEntry[]
  plans: WorkPlan[]
}

export interface PlanDetail {
  plan: WorkPlan
  milestones: Milestone[]
  /** The plan's isolated checkout, when isolation is 'worktree'. */
  worktree?: Worktree | null
}

export interface LoopDetail {
  loop: Loop
  iterations: LoopIteration[]
}

/**
 * Typed wrapper over the invoke bridge.
 *
 * Thin on purpose — the schemas in `shared/ipc.ts` are the contract, and this
 * only gives call sites names and return types.
 */
export const api = {
  info: (): Promise<AppInfo> => bridge().invoke('app.info'),
  health: (): Promise<CliHealth[]> => bridge().invoke('health.probe'),

  // Sessions
  startSession: (payload: {
    kind: Session['kind']
    matter: string
    project: string
    repoPath: string | null
    /** Seats in order: 0 and 1 hold the exchange, further seats assess. */
    participants: AgentConfig[]
    maxTurns: number
  }): Promise<Session> => bridge().invoke('session.start', payload),
  listSessions: (includeArchived = false): Promise<{ sessions: Session[]; archivedCount: number }> =>
    bridge().invoke('session.list', { includeArchived }),
  archiveSession: (sessionId: Id, archived: boolean): Promise<Session> =>
    bridge().invoke('session.archive', { sessionId, archived }),
  sessionDeletionImpact: (sessionId: Id): Promise<SessionDeletionImpact> =>
    bridge().invoke('session.deletionImpact', { sessionId }),
  deleteSession: (sessionId: Id): Promise<{ deleted: boolean }> =>
    bridge().invoke('session.delete', { sessionId }),
  getSession: (sessionId: Id): Promise<SessionDetail> => bridge().invoke('session.get', { sessionId }),
  interject: (sessionId: Id, target: InterjectionTarget, text: string): Promise<unknown> =>
    bridge().invoke('session.interject', { sessionId, target, text }),
  pauseSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.pause', { sessionId }),
  resumeSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.resume', { sessionId }),
  stopSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.stop', { sessionId }),
  exportReport: (sessionId: Id): Promise<{ saved: boolean; path: string | null }> =>
    bridge().invoke('session.export', { sessionId }),
  /** One read-only sweep; everything it drafts files as proposals. */
  stowSession: (
    sessionId: Id,
  ): Promise<{ filedItems: number; filedLearnings: number; duplicates: number }> =>
    bridge().invoke('session.stow', { sessionId }),

  // Finding ledger
  listLedger: (sessionId: Id): Promise<LedgerEntry[]> =>
    bridge().invoke('ledger.list', { sessionId }),
  disposeLedgerFinding: (
    sessionId: Id,
    findingId: Id,
    occurrenceId: FindingOccurrence['id'] | null,
    state: FindingDisposition['state'],
    note: string,
  ): Promise<LedgerEntry> =>
    bridge().invoke('ledger.dispose', { sessionId, findingId, occurrenceId, state, note }),

  // Decision holds
  listHolds: (): Promise<Hold[]> => bridge().invoke('holds.list'),
  /** Returns the updated queue. Refused for decision-class holds. */
  ackHold: (holdId: Id): Promise<Hold[]> => bridge().invoke('holds.ack', { holdId }),

  // Backlog
  listBacklogItems: (repoPath?: string, includeArchived = false): Promise<BacklogItem[]> =>
    bridge().invoke('backlog.list', repoPath ? { repoPath, includeArchived } : { includeArchived }),
  dropBacklogItem: (itemId: Id, note = ''): Promise<BacklogItem> =>
    bridge().invoke('backlog.drop', { itemId, note }),
  /** Reopens a planned or closure-proposed item; the plan edge is cleared. */
  reopenBacklogItem: (itemId: Id): Promise<BacklogItem> =>
    bridge().invoke('backlog.reopen', { itemId }),
  setBacklogBlockedBy: (itemId: Id, blockedBy: Id[]): Promise<BacklogItem> =>
    bridge().invoke('backlog.setBlockedBy', { itemId, blockedBy }),
  /** Confirms a stow proposal into the open backlog. */
  confirmBacklogItem: (itemId: Id): Promise<BacklogItem> =>
    bridge().invoke('backlog.confirm', { itemId }),
  /** Closes a closure-proposed item — the human half of the proposal. */
  closeBacklogItem: (itemId: Id, note = ''): Promise<BacklogItem> =>
    bridge().invoke('backlog.close', { itemId, note }),
  listLearnings: (repoPath?: string, includeArchived = false): Promise<Learning[]> =>
    bridge().invoke('learnings.list', repoPath ? { repoPath, includeArchived } : { includeArchived }),
  /** Confirms a proposed learning; confirmed learnings ride every new brief. */
  confirmLearning: (learningId: Id): Promise<Learning> =>
    bridge().invoke('learnings.confirm', { learningId }),
  /** Retires a learning so it stops riding briefs. Terminal — never deleted. */
  retireLearning: (learningId: Id): Promise<Learning> =>
    bridge().invoke('learnings.retire', { learningId }),

  // Foreman
  /** One gated read of the repo's backlog; files a proposal a human decides. */
  runForeman: (repoPath: string, cfg: AgentConfig): Promise<ForemanProposal> =>
    bridge().invoke('foreman.run', { repoPath, cfg }),
  listForemanProposals: (repoPath?: string): Promise<ForemanProposal[]> =>
    bridge().invoke('foreman.list', repoPath ? { repoPath } : {}),
  /** Rejecting is its own act; accepting rides plan creation atomically. */
  rejectForemanProposal: (proposalId: Id, note = ''): Promise<ForemanProposal> =>
    bridge().invoke('foreman.reject', { proposalId, note }),

  /** Closes out a failed or blocked plan — cancelled on the record. */
  closeOutPlan: (planId: Id): Promise<WorkPlan> =>
    bridge().invoke('plan.cancel', { planId }),

  // Self-update (dev mode)
  /** The one live offer, resolved at action time — holds don't carry row ids. */
  getPendingSelfUpdate: (): Promise<SelfUpdate | null> =>
    bridge().invoke('selfupdate.pending', {}),
  /** Decides the green offer, then quits into the freshly built out/. */
  relaunchSelfUpdate: (updateId: Id): Promise<SelfUpdate> =>
    bridge().invoke('selfupdate.relaunch', { updateId }),
  declineSelfUpdate: (updateId: Id): Promise<SelfUpdate> =>
    bridge().invoke('selfupdate.decline', { updateId }),

  // Plans
  createPlan: (payload: {
    sessionId: Id
    kind: WorkPlan['kind']
    repoPath: string
    planner: WorkPlan['planner']
    executor: WorkPlan['executor']
    reviewer: WorkPlan['reviewer']
    note?: string
    /** Where milestones execute. Defaults to the live checkout. */
    isolation?: WorkPlan['isolation']
    /** Shell-free command run once at worktree creation (e.g. `npm ci`). */
    setupCommand?: string
    /** Open backlog items this plan targets; they flip to planned. */
    backlogItemIds?: Id[]
    /** A pending foreman proposal this creation accepts, atomically. */
    foremanProposalId?: Id | null
  }): Promise<PlanDetail> => bridge().invoke('plan.create', payload),
  /** Null-ish repoPath lists globally (capped); a repoPath lists that repo's
   * plans, uncapped. The empty-object payload is load-bearing: the schema is
   * an object now, and undefined would fail it. */
  listPlans: (repoPath?: string): Promise<WorkPlan[]> =>
    bridge().invoke('plan.list', repoPath ? { repoPath } : {}),
  listRepoSummaries: (
    includeArchived = false,
  ): Promise<{ repos: RepoSummary[]; archivedCount: number }> =>
    bridge().invoke('repos.list', { includeArchived }),
  archiveRepo: (repoPath: string, archived: boolean): Promise<{ ok: true }> =>
    bridge().invoke('repos.archive', { repoPath, archived }),
  repoContainerStatus: (repoPath: string): Promise<RepoContainerStatus> =>
    bridge().invoke('repo.containerStatus', { repoPath }),
  setRepoContainer: (repoPath: string, enabled: boolean): Promise<RepoContainerStatus> =>
    bridge().invoke('repo.setContainer', { repoPath, enabled }),
  getPlan: (planId: Id): Promise<PlanDetail> => bridge().invoke('plan.get', { planId }),
  setTestCommand: (milestoneId: Id, command: string): Promise<Milestone> =>
    bridge().invoke('plan.setTestCommand', { milestoneId, command }),
  answerPlan: (planId: Id, answer: string): Promise<PlanDetail> =>
    bridge().invoke('plan.answer', { planId, answer }),
  inspectMilestone: (
    milestoneId: Id,
  ): Promise<{ existing: string[]; missing: string[]; dirtyPaths: string[] }> =>
    bridge().invoke('plan.inspect', { milestoneId }),
  runMilestone: (milestoneId: Id, approvalId: Id): Promise<Milestone> =>
    bridge().invoke('plan.runMilestone', { milestoneId, approvalId }),
  adoptMilestone: (milestoneId: Id): Promise<Milestone> =>
    bridge().invoke('plan.adoptMilestone', { milestoneId }),
  /** Stops at the next boundary; the run state is kept, so resume stays open. */
  stopMilestone: (milestoneId: Id): Promise<unknown> =>
    bridge().invoke('plan.stopMilestone', { milestoneId }),
  /** Continues an interrupted run from its preserved state. Fresh approval. */
  resumeMilestone: (milestoneId: Id, approvalId: Id): Promise<Milestone> =>
    bridge().invoke('plan.resumeMilestone', { milestoneId, approvalId }),
  /** Fast-forwards the origin onto the plan branch, spending the approval. */
  landPlan: (planId: Id, approvalId: Id): Promise<{ landed: boolean; detail: string }> =>
    bridge().invoke('plan.land', { planId, approvalId }),

  // Approvals
  grantApproval: (
    scope: Approval['scope'],
    subjectId: Id,
    summary: string,
  ): Promise<Approval> => bridge().invoke('approval.grant', { scope, subjectId, summary }),
  listApprovals: (): Promise<Approval[]> => bridge().invoke('approval.list'),

  // Loops
  createLoop: (payload: {
    goal: string
    repoPath: string
    worker: Loop['worker']
    verifier: Loop['verifier']
    exit: Loop['exit']
    caps: Loop['caps']
    capability: Loop['capability']
  }): Promise<Loop> => bridge().invoke('loop.create', payload),
  startLoop: (loopId: Id, approvalId: Id | null): Promise<Loop> =>
    bridge().invoke('loop.start', { loopId, approvalId }),
  listLoops: (): Promise<Loop[]> => bridge().invoke('loop.list'),
  getLoop: (loopId: Id): Promise<LoopDetail> => bridge().invoke('loop.get', { loopId }),
  pauseLoop: (loopId: Id): Promise<unknown> => bridge().invoke('loop.pause', { loopId }),
  resumeLoop: (loopId: Id): Promise<unknown> => bridge().invoke('loop.resume', { loopId }),
  killLoop: (loopId: Id): Promise<unknown> => bridge().invoke('loop.kill', { loopId }),

  // Grid
  openPane: (
    kind: Pane['kind'],
    cwd: string,
    cols: number,
    rows: number,
    resume = false,
  ): Promise<Pane> => bridge().invoke('pane.open', { kind, cwd, cols, rows, resume }),
  writePane: (paneId: Id, data: string): Promise<unknown> => bridge().invoke('pane.write', { paneId, data }),
  resizePane: (paneId: Id, cols: number, rows: number): Promise<unknown> =>
    bridge().invoke('pane.resize', { paneId, cols, rows }),
  closePane: (paneId: Id): Promise<unknown> => bridge().invoke('pane.close', { paneId }),
  stopPane: (paneId: Id): Promise<unknown> => bridge().invoke('pane.stop', { paneId }),
  paneIdentity: (cwd: string): Promise<PaneIdentity> => bridge().invoke('pane.identity', { cwd }),
  listPanes: (): Promise<Pane[]> => bridge().invoke('pane.list'),

  // Saved layouts
  saveLayout: (input: {
    name: string
    defaultFolder: string
    tree: GridLayout['tree']
  }): Promise<GridLayout> => bridge().invoke('layout.save', input),
  listLayouts: (): Promise<GridLayout[]> => bridge().invoke('layout.list'),
  deleteLayout: (layoutId: Id): Promise<unknown> => bridge().invoke('layout.delete', { layoutId }),

  // Skills
  listSkills: (): Promise<Skill[]> => bridge().invoke('skill.list'),
  saveSkill: (skill: Omit<Skill, 'builtIn'>): Promise<Skill> => bridge().invoke('skill.save', skill),
  runSkill: (paneId: Id, skillId: Id): Promise<unknown> => bridge().invoke('skill.run', { paneId, skillId }),

  // Dialogs
  pickDirectory: (title = 'Choose a folder'): Promise<{ path: string | null }> =>
    bridge().invoke('dialog.pickDirectory', { title }),

  onEvent: (handler: (event: AppEvent) => void): (() => void) => bridge().onEvent(handler),
  onPtyData: (handler: (chunk: PtyChunk) => void): (() => void) => bridge().onPtyData(handler),
}
