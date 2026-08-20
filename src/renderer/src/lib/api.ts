import type {
  AgentConfig,
  AgentProfile,
  GridLayout,
  Id,
  Pane,
  PaneKind,
  Room,
  RoomCaps,
  RoomVerdict,
  Skill,
} from '@shared/domain'
import type { AppEvent, PtyChunk } from '@shared/events'
import type {
  AppInfo,
  CliHealth,
  CommandName,
  PaneIdentity,
  WorkingDiff,
  RecordSearchHit,
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
  listAgentProfiles: (): Promise<AgentProfile[]> => bridge().invoke('profile.list'),
  addAgentProfile: (profile: Omit<AgentProfile, 'id' | 'createdAt'>): Promise<AgentProfile> =>
    bridge().invoke('profile.add', profile),
  openRoom: (cwd: string, seats: AgentConfig[], caps: RoomCaps): Promise<Room> =>
    bridge().invoke('room.open', { cwd, seats, caps }),
  addRoomSeat: (roomId: Id, seat: AgentConfig): Promise<Room> =>
    bridge().invoke('room.addSeat', { roomId, seat }),
  removeRoomSeat: (roomId: Id, seatId: Id): Promise<Room> =>
    bridge().invoke('room.removeSeat', { roomId, seatId }),
  setRoomCaps: (roomId: Id, caps: RoomCaps): Promise<Room> =>
    bridge().invoke('room.setCaps', { roomId, caps }),
  /** Standing authorisation, not single-use — see the room header. */
  setRoomSeatWrite: (roomId: Id, seatId: Id, write: boolean): Promise<Room> =>
    bridge().invoke('room.setSeatWrite', { roomId, seatId, write }),
  /** Fire-and-forget; the verdict arrives as a room.verdict event. */
  convergeRoom: (roomId: Id, question: string): Promise<{ ok: boolean }> =>
    bridge().invoke('room.converge', { roomId, question }),
  listRoomVerdicts: (roomId: Id): Promise<RoomVerdict[]> =>
    bridge().invoke('room.verdicts', { roomId }),
  /** Turns, not rounds. Fire-and-forget; the pane follows the events. */
  advanceRoom: (roomId: Id, turns: number): Promise<{ ok: boolean }> =>
    bridge().invoke('room.advance', { roomId, turns }),
  getRoom: (roomId: Id): Promise<Room | null> => bridge().invoke('room.get', { roomId }),
  /** Rooms in the record, newest first. Turns are not included. */
  listRooms: (): Promise<Room[]> => bridge().invoke('room.list'),
  /** Brings a recorded room back, with its transcript and no seat running. */
  reopenRoom: (roomId: Id): Promise<Room> => bridge().invoke('room.reopen', { roomId }),
  /**
   * Fire-and-forget by design: the seat's turn can run for minutes and the
   * pane learns what happened from the room.turn.* events, so awaiting the
   * dispatch would buy a promise nobody reads and a timeout nobody survives.
   */
  sendToRoom: (roomId: Id, text: string): Promise<{ ok: boolean }> =>
    bridge().invoke('room.send', { roomId, text }),
  setRoomSeat: (roomId: Id, seat: AgentConfig): Promise<Room> =>
    bridge().invoke('room.setSeat', { roomId, seat }),
  stopRoom: (roomId: Id): Promise<null> => bridge().invoke('room.stop', { roomId }),
  closeRoom: (roomId: Id): Promise<null> => bridge().invoke('room.close', { roomId }),
  updateAgentProfile: (
    profileId: Id,
    profile: Omit<AgentProfile, 'id' | 'createdAt'>,
  ): Promise<AgentProfile> => bridge().invoke('profile.update', { profileId, ...profile }),
  forgetAgentProfile: (profileId: Id): Promise<null> =>
    bridge().invoke('profile.forget', { profileId }),
  searchRecord: (query: string, limit?: number): Promise<RecordSearchHit[]> =>
    bridge().invoke('search.query', { query, ...(limit ? { limit } : {}) }),
  openPane: (
    kind: Pane['kind'],
    cwd: string,
    cols: number,
    rows: number,
    resume = false,
  ): Promise<Pane> => bridge().invoke('pane.open', { kind, cwd, cols, rows, resume }),
  writePane: (paneId: Id, data: string): Promise<unknown> => bridge().invoke('pane.write', { paneId, data }),
  /** Relays content into another pane as a paste, keeping its newlines. */
  /** Uncommitted work in a folder, or null when it is not a repository. */
  workingDiff: (cwd: string): Promise<WorkingDiff | null> =>
    bridge().invoke('git.workingDiff', { cwd }),
  pastePane: (paneId: Id, text: string): Promise<unknown> => bridge().invoke('pane.paste', { paneId, text }),
  resizePane: (paneId: Id, cols: number, rows: number): Promise<unknown> =>
    bridge().invoke('pane.resize', { paneId, cols, rows }),
  /** Backpressure: stop the child writing while xterm catches up. */
  setPaneFlow: (paneId: Id, paused: boolean): Promise<unknown> =>
    bridge().invoke('pane.flow', { paneId, paused }),
  closePane: (paneId: Id): Promise<unknown> => bridge().invoke('pane.close', { paneId }),
  stopPane: (paneId: Id): Promise<unknown> => bridge().invoke('pane.stop', { paneId }),
  paneIdentity: (cwd: string): Promise<PaneIdentity> => bridge().invoke('pane.identity', { cwd }),
  savePaneTranscript: (
    suggestedName: string,
    text: string,
  ): Promise<{ saved: boolean; path: string | null }> =>
    bridge().invoke('pane.saveTranscript', { suggestedName, text }),
  listPanes: (): Promise<Pane[]> => bridge().invoke('pane.list'),

  // Saved layouts
  saveLayout: (input: {
    name: string
    defaultFolder: string
    tree: GridLayout['tree']
  }): Promise<GridLayout> => bridge().invoke('layout.save', input),
  listFolders: (): Promise<string[]> => bridge().invoke('folder.list'),
  rememberFolder: (path: string): Promise<string[]> => bridge().invoke('folder.remember', { path }),
  forgetFolder: (path: string): Promise<string[]> => bridge().invoke('folder.forget', { path }),
  listLayouts: (): Promise<GridLayout[]> => bridge().invoke('layout.list'),
  deleteLayout: (layoutId: Id): Promise<unknown> => bridge().invoke('layout.delete', { layoutId }),

  // Skills
  listSkills: (): Promise<Skill[]> => bridge().invoke('skill.list'),
  saveSkill: (skill: Omit<Skill, 'builtIn'>): Promise<Skill> => bridge().invoke('skill.save', skill),
  runSkillInRoom: (roomId: Id, skillId: Id): Promise<{ ok: boolean }> =>
    bridge().invoke('skill.run', { target: { kind: 'room', roomId }, skillId }),
  runSkill: (paneId: Id, skillId: Id): Promise<unknown> =>
    bridge().invoke('skill.run', { target: { kind: 'pane', paneId }, skillId }),

  // Dialogs
  pickDirectory: (title = 'Choose a folder'): Promise<{ path: string | null }> =>
    bridge().invoke('dialog.pickDirectory', { title }),
  onEvent: (handler: (event: AppEvent) => void): (() => void) => bridge().onEvent(handler),
  onPtyData: (handler: (chunk: PtyChunk) => void): (() => void) => bridge().onPtyData(handler),
}
