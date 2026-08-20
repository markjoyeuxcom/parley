import { z } from 'zod'
import {
  AgentConfig,
  Effort,
  Id,
  PaneKind,
  RoomCaps,
  SavedLayoutNode,
  Skill,
  Vendor,
  type SearchKind,
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

export const OpenPaneReq = z.object({
  kind: PaneKind,
  cwd: z.string().min(1),
  cols: z.number().int().min(2).max(2000),
  rows: z.number().int().min(2).max(1000),
  /**
   * Launch the CLI's OWN interactive session picker (`claude --resume`,
   * `codex resume`). Ignored for shells, and for agy, which resumes by id
   * rather than through a picker — see RESUME_PICKER_KINDS.
   */
  resume: z.boolean().default(false),
})

export const PaneWriteReq = z.object({ paneId: Id, data: z.string() })
/**
 * Relayed content. Bounded, because this is one CLI's output going into
 * another's prompt and an unbounded paste is somebody's whole scrollback.
 */
export const PanePasteReq = z.object({ paneId: Id, text: z.string().min(1).max(200_000) })
export const PaneResizeReq = z.object({
  paneId: Id,
  cols: z.number().int().min(2).max(2000),
  rows: z.number().int().min(2).max(1000),
})
/**
 * Flow control, from the renderer that cannot keep up.
 *
 * xterm parses on the main thread and `write` queues whatever it cannot get
 * through. Nothing bounded that queue, so three panes redrawing faster than one
 * thread could parse grew the backlog until Chromium killed the renderer —
 * measured at 11.3GB and eight minutes. Pausing the pty is what a real terminal
 * does when its reader falls behind: the child blocks on write, which costs it
 * nothing and bounds us.
 */
export const PaneFlowReq = z.object({ paneId: Id, paused: z.boolean() })
export const PaneCloseReq = z.object({ paneId: Id })
export const PaneStopReq = z.object({ paneId: Id })
export const PaneIdentityReq = z.object({ cwd: z.string().min(1) })
/** Uncommitted work in a folder, for handing to a counterpart to review. */
export const WorkingDiffReq = z.object({ cwd: z.string().min(1) })

/** The text travels from the renderer: a pane's buffer lives in xterm. */
export const SaveTranscriptReq = z.object({
  suggestedName: z.string().min(1).max(200),
  text: z.string().max(5_000_000),
})

/**
 * Where a skill lands.
 *
 * A discriminated target rather than an optional paneId: a skill reaches a
 * pane as keystrokes into a live TUI and a room as a message to its seat, and
 * those are different deliveries with different failure modes. Making the
 * caller name which one keeps a room from ever being handed to `pty.submit`.
 */
export const SkillTarget = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('pane'), paneId: Id }),
  z.object({ kind: z.literal('room'), roomId: Id }),
])
export type SkillTarget = z.infer<typeof SkillTarget>

export const RunSkillReq = z.object({ target: SkillTarget, skillId: Id })
export const SaveSkillReq = Skill.omit({ builtIn: true })

export const SaveLayoutReq = z.object({
  name: z.string().min(1).max(120),
  defaultFolder: z.string().default(''),
  tree: SavedLayoutNode,
})
export const FolderReq = z.object({ path: z.string().min(1) })
export const LayoutIdReq = z.object({ layoutId: Id })
export const PickDirectoryReq = z.object({ title: z.string().default('Choose a folder') })

const ProfileFields = {
  name: z.string().min(1),
  vendor: Vendor,
  model: z.string().default(''),
  effort: Effort.default('medium'),
  persona: z.string().default(''),
}

/**
 * The whole privileged surface.
 *
 * One channel with a validated command table rather than one channel per
 * operation: the renderer is sandboxed and untrusted, and a single audited
 * chokepoint is far easier to reason about than thirty separate handlers.
 * Adding capability means adding a command *and* a schema.
 */
export const COMMANDS = {
  'app.info': null,
  'health.probe': null,

  // Rooms
  'room.open': z.object({
    cwd: z.string().min(1),
    seats: z.array(AgentConfig).min(1).max(6),
    caps: RoomCaps,
  }),
  'room.get': z.object({ roomId: Id }),
  'room.list': null,
  'room.reopen': z.object({ roomId: Id }),
  'room.send': z.object({ roomId: Id, text: z.string().min(1).max(100_000) }),
  'room.setSeat': z.object({ roomId: Id, seat: AgentConfig }),
  'room.addSeat': z.object({ roomId: Id, seat: AgentConfig }),
  'room.removeSeat': z.object({ roomId: Id, seatId: Id }),
  'room.setSeatWrite': z.object({ roomId: Id, seatId: Id, write: z.boolean() }),
  'room.setCaps': z.object({ roomId: Id, caps: RoomCaps }),
  /** Turns, not rounds — the unit the budget counts in. */
  'room.advance': z.object({ roomId: Id, turns: z.number().int().positive().max(100) }),
  'room.converge': z.object({ roomId: Id, question: z.string().max(2000).default('') }),
  'room.verdicts': z.object({ roomId: Id }),
  'room.stop': z.object({ roomId: Id }),
  'room.close': z.object({ roomId: Id }),

  // The roster
  'profile.list': null,
  'profile.add': z.object(ProfileFields),
  'profile.update': z.object({ profileId: Id, ...ProfileFields }),
  'profile.forget': z.object({ profileId: Id }),

  // Terminal panes
  'pane.open': OpenPaneReq,
  'pane.write': PaneWriteReq,
  'pane.paste': PanePasteReq,
  'pane.resize': PaneResizeReq,
  'pane.flow': PaneFlowReq,
  'pane.close': PaneCloseReq,
  'pane.stop': PaneStopReq,
  'pane.identity': PaneIdentityReq,
  'git.workingDiff': WorkingDiffReq,
  'pane.saveTranscript': SaveTranscriptReq,
  'pane.list': null,

  'layout.save': SaveLayoutReq,
  'folder.list': null,
  'folder.remember': FolderReq,
  'folder.forget': FolderReq,
  'layout.list': null,
  'layout.delete': LayoutIdReq,

  'skill.list': null,
  'skill.save': SaveSkillReq,
  'skill.run': RunSkillReq,

  'search.query': z.object({
    query: z.string(),
    limit: z.number().int().positive().max(100).optional(),
  }),
  'dialog.pickDirectory': PickDirectoryReq,
} as const

export type CommandName = keyof typeof COMMANDS

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
   * The UI must show this permanently and unmissably. A mock room produces
   * turns and verdicts that look exactly like real ones while consulting no
   * model, and somebody who does not know which mode they are in will read
   * fabricated output as findings.
   */
  mock: boolean
  /** The model this machine's `codex` is configured to use, if any. */
  codexDefaultModel: string
  /** Gemini models the installed `agy` actually lists. */
  agyModels: string[]
}

/** Result of probing for a CLI at startup. */
export interface CliHealth {
  vendor: Vendor
  present: boolean
  version: string
  /** True when the CLI reports a logged-in subscription session. */
  authenticated: boolean
  /** Something a person can act on: what is missing, or how to sign in. */
  detail: string
}

/** What a pane's folder is, for the header. Refreshed on focus, never on a timer. */
export interface PaneIdentity {
  branch: string
  dirty: boolean
  ahead: number
  behind: number
}

/**
 * Uncommitted work in a folder, for handing to a counterpart to review.
 *
 * Untracked files are named rather than included: a new file is often the most
 * interesting thing an agent did, and inlining every one is how a review
 * payload becomes a scrollback.
 */
export interface WorkingDiff {
  branch: string
  /** Unified diff against HEAD. Empty when nothing tracked has changed. */
  diff: string
  untracked: string[]
  /** True when the diff was cut at the sending limit. */
  truncated: boolean
}

export interface RecordSearchHit {
  kind: SearchKind
  refId: Id
  title: string
  /** The matching text, with the query's words marked by «…». */
  snippet: string
  /** The room a hit lives in — the only door a search result now has. */
  roomId: Id | null
}
