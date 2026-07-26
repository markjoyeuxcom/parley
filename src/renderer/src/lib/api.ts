import type {
  Approval,
  Finding,
  GridLayout,
  Id,
  Interjection,
  Loop,
  LoopIteration,
  Milestone,
  Pane,
  Session,
  SessionDeletionImpact,
  Skill,
  Turn,
  Verdict,
  WorkPlan,
} from '@shared/domain'
import type { AppEvent, PtyChunk } from '@shared/events'
import type { AppInfo, CliHealth, CommandName } from '@shared/ipc'

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
  plans: WorkPlan[]
}

export interface PlanDetail {
  plan: WorkPlan
  milestones: Milestone[]
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
    agentA: Session['agentA']
    agentB: Session['agentB']
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
  interject: (sessionId: Id, target: 'both' | 'a' | 'b', text: string): Promise<unknown> =>
    bridge().invoke('session.interject', { sessionId, target, text }),
  pauseSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.pause', { sessionId }),
  resumeSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.resume', { sessionId }),
  stopSession: (sessionId: Id): Promise<unknown> => bridge().invoke('session.stop', { sessionId }),
  exportReport: (sessionId: Id): Promise<{ saved: boolean; path: string | null }> =>
    bridge().invoke('session.export', { sessionId }),

  // Plans
  createPlan: (payload: {
    sessionId: Id
    kind: WorkPlan['kind']
    repoPath: string
    planner: WorkPlan['planner']
    executor: WorkPlan['executor']
    reviewer: WorkPlan['reviewer']
    note?: string
  }): Promise<PlanDetail> => bridge().invoke('plan.create', payload),
  listPlans: (): Promise<WorkPlan[]> => bridge().invoke('plan.list'),
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
  openPane: (kind: Pane['kind'], cwd: string, cols: number, rows: number): Promise<Pane> =>
    bridge().invoke('pane.open', { kind, cwd, cols, rows }),
  writePane: (paneId: Id, data: string): Promise<unknown> => bridge().invoke('pane.write', { paneId, data }),
  resizePane: (paneId: Id, cols: number, rows: number): Promise<unknown> =>
    bridge().invoke('pane.resize', { paneId, cols, rows }),
  closePane: (paneId: Id): Promise<unknown> => bridge().invoke('pane.close', { paneId }),
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
