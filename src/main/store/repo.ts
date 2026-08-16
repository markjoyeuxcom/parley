import { newId } from '@main/util/ids'
import { searchRecord, type SearchHit, type SearchOptions } from './search'
import {
  addUsage,
  emptyUsage,
  type AgentProfile,
  type GridLayout,
  type Id,
  type Room,
  type RoomCaps,
  type RoomSeat,
  type RoomTurn,
  type RoomVerdict,
  type Skill,
  type Usage,
} from '@shared/domain'
import { canonicalRepoPath } from '@main/util/repoPath'
import type { Db, Row } from './db'

/**
 * Local persistence, for what the Grid keeps.
 *
 * Rooms and their turns, the seat roster, saved layouts and skills — and the
 * search index over the first of those. Everything the governed engine wrote
 * went with it; what remains is small enough that the whole class fits in one
 * reading.
 */

function parseJson<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string') return fallback
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}

const json = (value: unknown): string => JSON.stringify(value)
const str = (v: unknown, d = ''): string => (typeof v === 'string' ? v : d)
const nullableStr = (v: unknown): string | null => (typeof v === 'string' ? v : null)
const num = (v: unknown, d = 0): number => (typeof v === 'number' ? v : d)

export { newId }

export class Repo {
  constructor(private readonly db: Db) {}

  // ─── Repository activity and archives ─────────────────────────────────────

  /**
   * Appends one repository activity watermark. Deliberately a bare statement:
   * callers own the transaction that pairs it with the write being recorded.
   */

  search(query: string, options: SearchOptions = {}): SearchHit[] {
    return searchRecord(this.db, query, options)
  }

  /* ── Rooms ───────────────────────────────────────────────────────────── */

  createRoom(input: {
    id: Id
    cwd: string
    seats: RoomSeat[]
    caps: RoomCaps
    mock: boolean
  }): void {
    this.db.run(
      `INSERT INTO rooms (id, cwd, seats, caps, mock, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
      input.id,
      input.cwd,
      JSON.stringify(input.seats),
      JSON.stringify(input.caps),
      input.mock ? 1 : 0,
      Date.now(),
    )
  }

  setRoomSeats(roomId: Id, seats: RoomSeat[]): void {
    this.db.run(`UPDATE rooms SET seats = ? WHERE id = ?`, JSON.stringify(seats), roomId)
  }

  setRoomCaps(roomId: Id, caps: RoomCaps): void {
    this.db.run(`UPDATE rooms SET caps = ? WHERE id = ?`, JSON.stringify(caps), roomId)
  }

  /** Stamps the close. The row and its turns stay — see the schema comment. */

  closeRoom(roomId: Id): void {
    this.db.run(`UPDATE rooms SET closed_at = ? WHERE id = ? AND closed_at IS NULL`, Date.now(), roomId)
  }

  appendRoomTurn(roomId: Id, turn: RoomTurn): void {
    const next = num(
      this.db.get<{ n: number }>(`SELECT COUNT(*) AS n FROM room_turns WHERE room_id = ?`, roomId)?.n,
    )
    this.db.run(
      `INSERT INTO room_turns
         (id, room_id, idx, author, seat, vendor, profile, text, usage, started_at, ended_at, error)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      turn.id,
      roomId,
      next,
      turn.author,
      turn.seat,
      turn.vendor,
      turn.profile,
      turn.text,
      JSON.stringify(turn.usage),
      turn.startedAt,
      turn.endedAt,
      turn.error,
    )
  }

  /** Fills in a turn that was written when it started. */

  finishRoomTurn(turn: RoomTurn): void {
    this.db.run(
      `UPDATE room_turns SET text = ?, usage = ?, ended_at = ?, error = ? WHERE id = ?`,
      turn.text,
      JSON.stringify(turn.usage),
      turn.endedAt,
      turn.error,
      turn.id,
    )
  }

  getRoom(roomId: Id): Room | undefined {
    const row = this.db.get(`SELECT * FROM rooms WHERE id = ?`, roomId)
    if (!row) return undefined
    const turns = this.db
      .all(`SELECT * FROM room_turns WHERE room_id = ? ORDER BY idx ASC`, roomId)
      .map((t) => this.toRoomTurn(t))
    return this.toRoom(row, turns)
  }

  /** Newest first. Closed rooms are included: the record is the point. */

  listRooms(limit = 100): Room[] {
    return this.db
      .all(`SELECT * FROM rooms ORDER BY created_at DESC LIMIT ?`, limit)
      .map((row) => this.toRoom(row, []))
  }

  /**
   * Drops closed rooms that never held a turn, and returns how many went.
   *
   * An accidentally-opened pane should not accumulate as a record; a room
   * somebody actually spoke in always survives. Guarded on `closed_at` so a
   * room the app is currently holding is never swept out from under it —
   * this runs at startup, but the guard is what makes that incidental rather
   * than load-bearing.
   */

  reconcileRooms(): number {
    return this.db.run(
      `DELETE FROM rooms
        WHERE closed_at IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM room_turns WHERE room_turns.room_id = rooms.id)`,
    ).changes
  }

  saveRoomVerdict(verdict: RoomVerdict): RoomVerdict {
    this.db.run(
      `INSERT INTO room_verdicts
         (id, room_id, question, decision, rationale, scores, confidence,
          agreement, single_source, dissent, report, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      verdict.id,
      verdict.roomId,
      verdict.question,
      verdict.decision,
      verdict.rationale,
      JSON.stringify(verdict.scores),
      verdict.confidence,
      verdict.agreement,
      verdict.singleSource ? 1 : 0,
      verdict.dissent,
      verdict.report,
      verdict.createdAt,
    )
    return verdict
  }

  /** Newest first: a room's later conclusions supersede without erasing. */

  listRoomVerdicts(roomId: Id): RoomVerdict[] {
    return this.db
      // rowid breaks the tie: two verdicts asked for in the same millisecond
      // would otherwise come back in an arbitrary order, and which one a room
      // reached LAST is the whole point of keeping both.
      .all(`SELECT * FROM room_verdicts WHERE room_id = ? ORDER BY created_at DESC, rowid DESC`, roomId)
      .map((row) => ({
        id: str(row['id']),
        roomId: str(row['room_id']),
        question: str(row['question']),
        decision: str(row['decision']),
        rationale: str(row['rationale']),
        scores: JSON.parse(str(row['scores'], '{}')) as RoomVerdict['scores'],
        confidence: num(row['confidence']),
        agreement: num(row['agreement']),
        singleSource: num(row['single_source']) === 1,
        dissent: str(row['dissent']),
        report: str(row['report']),
        createdAt: num(row['created_at']),
      }))
  }

  private toRoomTurn(row: Row): RoomTurn {
    return {
      id: str(row['id']),
      roomId: str(row['room_id']),
      author: str(row['author']) as RoomTurn['author'],
      seat: str(row['seat']),
      vendor: (row['vendor'] as RoomTurn['vendor']) ?? null,
      profile: str(row['profile']),
      text: str(row['text']),
      usage: parseJson<Usage>(row['usage'], emptyUsage()),
      startedAt: num(row['started_at']),
      endedAt: row['ended_at'] === null ? null : num(row['ended_at']),
      error: row['error'] === null ? null : str(row['error']),
    }
  }

  /**
   * Rebuilds a room from its row and its turns.
   *
   * Everything summarising the turns is recomputed here rather than read: the
   * spend is their sum, the turn count is how many an agent took, and the
   * status is idle unless the caps are spent — after a restart nothing is
   * mid-turn, so `thinking` is not a state the record can be in.
   */

  private toRoom(row: Row, turns: RoomTurn[]): Room {
    const caps = JSON.parse(str(row['caps'], '{}')) as RoomCaps
    const usage = turns.reduce<Usage>((total, turn) => addUsage(total, turn.usage), emptyUsage())
    const turnsSpent = turns.filter((turn) => turn.author === 'agent').length
    const spent =
      turnsSpent >= caps.turns || (caps.costUsd > 0 && usage.costUsd >= caps.costUsd)
    return {
      id: str(row['id']),
      cwd: str(row['cwd']),
      seats: JSON.parse(str(row['seats'], '[]')) as RoomSeat[],
      caps,
      turnsSpent,
      status: spent ? 'exhausted' : 'idle',
      turns,
      usage,
      mock: num(row['mock']) === 1,
      createdAt: num(row['created_at']),
    }
  }

  createAgentProfile(input: Omit<AgentProfile, 'id' | 'createdAt'>): AgentProfile {
    const name = input.name.trim()
    if (!name) throw new Error('a profile needs a name')
    const row: AgentProfile = {
      id: newId(),
      name,
      vendor: input.vendor,
      model: input.model,
      effort: input.effort,
      persona: input.persona,
      createdAt: Date.now(),
    }
    this.db.run(
      `INSERT INTO agent_profiles (id, name, vendor, model, effort, persona, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      row.id,
      row.name,
      row.vendor,
      row.model,
      row.effort,
      row.persona,
      row.createdAt,
    )
    return row
  }

  listAgentProfiles(): AgentProfile[] {
    return this.db
      .all(`SELECT * FROM agent_profiles ORDER BY name COLLATE NOCASE ASC`)
      .map((row) => ({
        id: str(row['id']),
        name: str(row['name']),
        vendor: str(row['vendor']) as AgentProfile['vendor'],
        model: str(row['model'] ?? ''),
        effort: str(row['effort']) as AgentProfile['effort'],
        persona: str(row['persona'] ?? ''),
        createdAt: num(row['created_at']),
      }))
  }

  /**
   * Rewrites a profile in place.
   *
   * In place and not delete-plus-recreate, for two reasons that only show up
   * later: the id is what a roster row is keyed by, and `createdAt` is the
   * only ordering fact a profile carries — both would be silently replaced by
   * a recreate, and the roster would reshuffle under the hand that edited it.
   *
   * Renaming onto another profile is refused by the NOCASE unique index, which
   * is exactly the create path's rule applied to the same question. Renaming a
   * profile to its own name in a different casing is NOT a collision: the
   * index is checked against other rows, and this one is the row being edited.
   *
   * An edit does not chase the stamps it left behind. A plan or journal entry
   * naming "Fast reviewer" records what the seat was called when it ran, and a
   * later rename cannot reach back and make that untrue.
   */

  updateAgentProfile(id: Id, input: Omit<AgentProfile, 'id' | 'createdAt'>): AgentProfile {
    const name = input.name.trim()
    if (!name) throw new Error('a profile needs a name')
    const existing = this.db.get(`SELECT created_at FROM agent_profiles WHERE id = ?`, id)
    if (!existing) throw new Error('no such profile')
    this.db.run(
      `UPDATE agent_profiles SET name = ?, vendor = ?, model = ?, effort = ?, persona = ?
       WHERE id = ?`,
      name,
      input.vendor,
      input.model,
      input.effort,
      input.persona,
      id,
    )
    return {
      id,
      name,
      vendor: input.vendor,
      model: input.model,
      effort: input.effort,
      persona: input.persona,
      createdAt: num(existing['created_at']),
    }
  }

  /**
   * Deletes the profile and nothing else.
   *
   * Configs that were stamped from it keep their stamp: the journal and every
   * plan row carry the NAME as of when the seat was picked, and what a seat
   * was called when it ran is a fact a deletion cannot reach.
   */

  forgetAgentProfile(id: Id): void {
    this.db.run(`DELETE FROM agent_profiles WHERE id = ?`, id)
  }

  /* ── Runs that left this machine ─────────────────────────────────────── */

  saveLayout(input: Omit<GridLayout, 'createdAt' | 'updatedAt'>): GridLayout {
    const now = Date.now()
    const existing = this.db.get(`SELECT id, created_at FROM grid_layouts WHERE name = ?`, input.name)
    const id = existing ? str(existing['id']) : input.id
    const createdAt = existing ? num(existing['created_at']) : now

    this.db.run(
      `INSERT INTO grid_layouts (id, name, default_folder, tree, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         default_folder = excluded.default_folder,
         tree = excluded.tree,
         updated_at = excluded.updated_at`,
      id,
      input.name,
      input.defaultFolder,
      json(input.tree),
      createdAt,
      now,
    )
    return { ...input, id, createdAt, updatedAt: now }
  }

  private toLayout(row: Row): GridLayout {
    return {
      id: str(row['id']),
      name: str(row['name']),
      defaultFolder: str(row['default_folder']),
      tree: parseJson<GridLayout['tree']>(row['tree'], { type: 'leaf', kind: 'shell', cwd: '' }),
      createdAt: num(row['created_at']),
      updatedAt: num(row['updated_at']),
    }
  }

  listLayouts(): GridLayout[] {
    // Name breaks the tie so two layouts saved in the same millisecond do not
    // swap places between calls.
    return this.db
      .all(`SELECT * FROM grid_layouts ORDER BY updated_at DESC, name ASC`)
      .map((r) => this.toLayout(r))
  }

  deleteLayout(id: Id): void {
    this.db.run(`DELETE FROM grid_layouts WHERE id = ?`, id)
  }

  // ─── Skills ────────────────────────────────────────────────────────────────

  upsertSkill(skill: Skill): Skill {
    this.db.run(
      `INSERT INTO skills (id, name, description, prompt, vendor_hint, built_in)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         name = excluded.name,
         description = excluded.description,
         prompt = excluded.prompt,
         vendor_hint = excluded.vendor_hint`,
      skill.id,
      skill.name,
      skill.description,
      skill.prompt,
      skill.vendorHint,
      skill.builtIn ? 1 : 0,
    )
    return skill
  }

  listSkills(): Skill[] {
    return this.db.all(`SELECT * FROM skills ORDER BY built_in DESC, name ASC`).map((row): Skill => ({
      id: str(row['id']),
      name: str(row['name']),
      description: str(row['description']),
      prompt: str(row['prompt']),
      vendorHint: nullableStr(row['vendor_hint']) as Skill['vendorHint'],
      builtIn: num(row['built_in']) === 1,
    }))
  }

  getSkill(id: Id): Skill | null {
    const row = this.db.get(`SELECT * FROM skills WHERE id = ?`, id)
    if (!row) return null
    return {
      id: str(row['id']),
      name: str(row['name']),
      description: str(row['description']),
      prompt: str(row['prompt']),
      vendorHint: nullableStr(row['vendor_hint']) as Skill['vendorHint'],
      builtIn: num(row['built_in']) === 1,
    }
  }
}
