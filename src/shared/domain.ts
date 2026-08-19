import { z } from 'zod'
import type { Usage as UsageShape } from './usage'

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
 * The CLI vendors Parley drives. All are invoked through the user's own
 * logged-in CLI, so all usage bills against their existing subscription. Parley
 * never reads or accepts an API key.
 */
export const Vendor = z.enum(['claude', 'codex', 'agy'])
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
  /**
   * The profile this seat was picked from, by NAME, stamped at pick time.
   *
   * The name and not the id, deliberately. It travels wherever the config
   * goes — into a plan row, over the wire to a remote worker — and both ends
   * can attribute work to it without a lookup against a record only one of
   * them has. It is also honest the way the journal is honest: renaming a
   * profile later does not rewrite what a seat was called when it ran.
   * Cleared the moment any field is edited, because a config that has
   * drifted from its profile is no longer that profile.
   *
   * Optional rather than defaulted: a default would make every literal in
   * the codebase name it, and absence — a seat configured by hand — is the
   * normal case, not a gap to be filled.
   */
  profile: z.string().optional(),
})
export type AgentConfig = z.infer<typeof AgentConfig>

/**
 * A named way of configuring a seat.
 *
 * The Buzz idea, taken without its luggage: an agent identity worth reusing
 * is a vendor, a model, an effort and a persona under a name — "Fast
 * reviewer", "Opus architect". Never credentials. The CLIs hold their own
 * authentication, and a profile that carried keys would turn a convenience
 * into a vault.
 */
export const AgentProfile = z.object({
  id: Id,
  /** Unique. Two profiles with one name would make attribution ambiguous. */
  name: z.string().min(1),
  vendor: Vendor,
  model: z.string().default(''),
  effort: Effort.default('medium'),
  persona: z.string().default(''),
  createdAt: Timestamp,
})
export type AgentProfile = z.infer<typeof AgentProfile>

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

/**
 * The type and the values live in a leaf module with no dependencies, so the
 * remote execution bundle can import them without inheriting this file's
 * schema library. Re-exported here so every existing caller is unaffected —
 * there is one definition of each, not a remote copy.
 */
export type Usage = UsageShape
export { addUsage, emptyUsage } from './usage'

/**
 * Compile-time proof that the schema and the hand-written type still describe
 * the same thing. Without it the two could drift silently — a field added to
 * the schema and not to the leaf would validate into a shape nothing else
 * knows about — and the drift would only surface as a confusing runtime bug.
 */
type Exact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : never) : never
const _usageShapesAgree: Exact<z.infer<typeof Usage>, UsageShape> = true
void _usageShapesAgree

// ─── Grid (parallel terminal panes) ──────────────────────────────────────────

export const PaneKind = z.enum(['shell', 'claude', 'codex', 'agy'])
export type PaneKind = z.infer<typeof PaneKind>

/**
 * Pane kinds whose CLI offers its own interactive session picker.
 *
 * "Resume a session…" opens that picker inside the pane — `claude --resume`,
 * `codex resume` — and Parley's governed resume ids never reach it. Agy is
 * absent deliberately: it resumes by id (`--conversation <id>`), which is a
 * different thing entirely. A pane offering it would either need an id the
 * Grid has no business holding, or an invented flag; both are worse than the
 * menu item simply not being there.
 *
 * Shared rather than duplicated per process, because the main side spawns the
 * command and the renderer decides whether to offer it — and the two silently
 * disagreeing would show a menu item that does nothing.
 */
export const RESUME_PICKER_KINDS: readonly PaneKind[] = ['claude', 'codex']

/**
 * What a grid slot holds.
 *
 * A superset of {@link PaneKind}, and deliberately a separate type rather than
 * a fifth member of it. `PaneKind` means "what process the PtyManager spawns",
 * and a room spawns nothing — it is seats and a transcript. Folding rooms into
 * PaneKind would put a member into `commandFor` whose only correct answer is
 * "never call me", and the first caller to forget that would silently open a
 * login shell. Here the type refuses instead.
 */
export const SlotKind = z.union([PaneKind, z.literal('room')])
export type SlotKind = z.infer<typeof SlotKind>

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
 * What kind of row a search hit came from.
 *
 * Here rather than beside the FTS query because both the store that produces
 * hits and the IPC contract that ships them need it, and the two drifted the
 * moment a new kind was added — the duplicate silently type-errored at the
 * boundary instead of at either definition.
 */
export const SearchKind = z.enum([
  'session',
  'turn',
  'plan',
  'milestone',
  'finding',
  'backlog',
  'learning',
  /** One thing said in a room — the only place a long argument lives. */
  'room-turn',
])
export type SearchKind = z.infer<typeof SearchKind>

// ─── Rooms (free-flow agent conversation) ────────────────────────────────────

/**
 * Who spoke.
 *
 * The human is a seat, not a side-channel. A scheduled exchange needed one —
 * hence interjections, their per-seat delivery tracking, and the rule that an
 * `all` interjection reaches each seat exactly once. A room has no schedule to
 * interrupt, so a person's message is simply a turn, and the whole delivery
 * apparatus has nothing left to do.
 */
export const RoomTurnAuthor = z.enum(['human', 'agent'])
export type RoomTurnAuthor = z.infer<typeof RoomTurnAuthor>

export const RoomTurn = z.object({
  id: Id,
  roomId: Id,
  author: RoomTurnAuthor,
  /** Which seat spoke, by name as of this turn. Empty on a human turn. */
  seat: z.string().default(''),
  /** Null on a human turn. */
  vendor: Vendor.nullable().default(null),
  /** The profile the seat was picked from, stamped as of this turn. */
  profile: z.string().default(''),
  text: z.string().default(''),
  usage: Usage,
  startedAt: Timestamp,
  endedAt: Timestamp.nullable().default(null),
  error: z.string().nullable().default(null),
})
export type RoomTurn = z.infer<typeof RoomTurn>

/**
 * `thinking` means at least one seat is mid-turn; a room refuses a second send
 * until idle. `exhausted` means a cap was reached — terminal until a human
 * raises the budget, and never reported as success.
 */
export const RoomStatus = z.enum(['idle', 'thinking', 'exhausted'])
export type RoomStatus = z.infer<typeof RoomStatus>

/**
 * A named chair in a room.
 *
 * The name is how the seat is addressed (`@reviewer`) and how its turns are
 * attributed, so it is a slug rather than free text — an address with a space
 * in it cannot be parsed out of a sentence.
 */
export const RoomSeat = z.object({
  id: Id,
  name: z.string().min(1).max(40),
  config: AgentConfig,
  /**
   * Whether this seat may change files in the room's folder.
   *
   * Off by default and off for every seat a room opens with. Turning it on is
   * STANDING authorisation, not single-use — it lasts until somebody turns it
   * off — which is a materially weaker guarantee than the recorded, spent-on-
   * start approval the audited pipeline required, and the reason the room
   * header states which seats hold it without being asked.
   */
  write: z.boolean().default(false),
})
export type RoomSeat = z.infer<typeof RoomSeat>

/**
 * What a room may spend before it stops.
 *
 * The useful half of the retired caps invariant. A terminal pane burns quota
 * only while a person types; seats on auto-advance are a furnace with no TUI
 * to watch and no natural pause, so the bound is checked by Parley before
 * every dispatch and is never visible to a seat — an agent that can see its
 * budget can argue about it.
 *
 * `costUsd: 0` means no cost ceiling, which is the honest default: Codex
 * reports no cost at all and Claude reports a notional figure, so turns are
 * the cap actually doing the work.
 */
export const RoomCaps = z.object({
  turns: z.number().int().positive().max(500),
  costUsd: z.number().nonnegative(),
})
export type RoomCaps = z.infer<typeof RoomCaps>

/**
 * One room: a folder, its seats, and everything said in it.
 *
 * In memory only. Persistence is m4, which is also when a room becomes a
 * `sessions` row and its turns become `turns` rows.
 */
export const Room = z.object({
  id: Id,
  cwd: z.string(),
  seats: z.array(RoomSeat),
  caps: RoomCaps,
  /** Agent turns spent. Human turns are free and are not counted. */
  turnsSpent: z.number().int().nonnegative().default(0),
  status: RoomStatus,
  turns: z.array(RoomTurn),
  usage: Usage,
  mock: z.boolean().default(false),
  createdAt: Timestamp,
})
export type Room = z.infer<typeof Room>

/** Five dimensions, each scored 0–10 by the agents at verdict time. */
export const ScoreDimension = z.enum([
  'correctness',
  'robustness',
  'clarity',
  'maintainability',
  'risk',
])
export type ScoreDimension = z.infer<typeof ScoreDimension>

/**
 * What a room's seats concluded, when somebody asked them to.
 *
 * Its own row with its own id rather than one per room: a room is a
 * conversation that can reach several conclusions over its life, and
 * overwriting the first the moment a second is asked for would destroy the
 * more interesting half of the record — what they thought before, and what
 * changed their minds.
 */
export const RoomVerdict = z.object({
  id: Id,
  roomId: Id,
  /** What the seats were asked to settle. */
  question: z.string(),
  decision: z.string(),
  rationale: z.string(),
  scores: z.record(ScoreDimension, z.number().min(0).max(10)),
  /** 0–1, and lowered by disagreement. Agreement is not confidence. */
  confidence: z.number().min(0).max(1),
  /** 0–1: how closely the seats' scores aligned. Stored rather than folded
   * away, so a surface can say "they disagreed" instead of only showing the
   * reduced number that resulted. */
  agreement: z.number().min(0).max(1),
  /** True when only one seat produced anything usable. */
  singleSource: z.boolean(),
  /** Positions a seat still holds. Preserved verbatim, never summarised. */
  dissent: z.string(),
  report: z.string(),
  createdAt: Timestamp,
})
export type RoomVerdict = z.infer<typeof RoomVerdict>

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
  | { type: 'leaf'; kind: SlotKind; cwd: string; title?: string }
  | {
      type: 'split'
      direction: 'row' | 'column'
      ratio: number
      a: SavedLayoutNode
      b: SavedLayoutNode
    }

export const SavedLayoutNode: z.ZodType<SavedLayoutNode> = z.lazy(() =>
  z.union([
    z.object({
      type: z.literal('leaf'),
      kind: SlotKind,
      cwd: z.string().min(1),
      /** A human-given pane name. Optional so pre-title layouts stay valid. */
      title: z.string().optional(),
    }),
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
