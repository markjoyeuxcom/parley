import { randomUUID } from 'node:crypto'
import type { AgentConfig, Id, Room, RoomTurn, Usage } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { emptyUsage } from '@shared/usage'
import { seatingRefusals } from '@shared/vendors'
import { roomSeatSystemPrompt } from '@shared/room'
import type { AgentRegistry } from '@main/agents'

/**
 * Free-flow rooms.
 *
 * The engine the scheduled exchange was hiding. `SessionRunner` owns turn
 * mechanics, resume threading and delivery — all of which a conversation
 * needs — wrapped around a fixed stage list and a structured verdict contract,
 * which is what made a debate feel like a form with two respondents. This is
 * the same mechanics with no schedule: the person typing decides who speaks
 * and when, and a turn's prompt is the message, not a stage's declared input.
 *
 * Three properties carry over deliberately:
 *
 * **The seat is resumed, never replayed.** The CLI keeps its own conversation
 * and Parley relays only the new message, so token cost grows linearly with
 * turn count rather than quadratically. This is the property that makes a long
 * room affordable at all, and the one a "just re-send the transcript"
 * implementation would silently destroy.
 *
 * **Read-only.** A room seat reads the folder its pane lives in and writes
 * nothing. The per-seat write opt-in is m5; until it exists there is no code
 * path here that can reach `write`.
 *
 * **A failed turn is a recorded turn.** The transcript is the work; wedging a
 * room because one dispatch errored would lose something the error itself did
 * not.
 *
 * In memory only. Persistence is m4 — rooms become `sessions` rows and their
 * turns become `turns` rows, which is also when a restart stops costing you
 * the conversation.
 */

export class RoomError extends Error {}

/** How long one seat's turn may run before it is abandoned. */
const TURN_TIMEOUT_MS = 25 * 60 * 1000

export interface RoomManagerDeps {
  registry: AgentRegistry
  emit: (event: AppEvent) => void
}

interface LiveRoom {
  room: Room
  /** The seat's vendor thread, so the next turn resumes rather than restarts. */
  resumeId: string | null
  /** Present only while a turn is in flight. */
  inFlight: AbortController | null
}

function addUsage(total: Usage, next: Usage): Usage {
  return {
    inputTokens: total.inputTokens + next.inputTokens,
    cachedInputTokens: total.cachedInputTokens + next.cachedInputTokens,
    outputTokens: total.outputTokens + next.outputTokens,
    reasoningTokens: total.reasoningTokens + next.reasoningTokens,
    costUsd: total.costUsd + next.costUsd,
  }
}

/**
 * Refuses a seat this app cannot dispatch, with the reason the rest of the app
 * already gives. Checked at open AND at reseat: a room that could be edited
 * into an impossible seat would fail at the next message instead of at the
 * moment somebody chose it.
 */
function assertSeatable(seat: AgentConfig): void {
  const refusals = seatingRefusals([{ vendor: seat.vendor, role: 'room-seat', toolFree: false }])
  if (refusals.length > 0) throw new RoomError(refusals.join('; '))
}

export class RoomManager {
  private readonly rooms = new Map<Id, LiveRoom>()

  constructor(private readonly deps: RoomManagerDeps) {}

  open(cwd: string, seat: AgentConfig): Room {
    assertSeatable(seat)
    const room: Room = {
      id: `room-${randomUUID()}`,
      cwd,
      seat,
      status: 'idle',
      turns: [],
      usage: emptyUsage(),
      mock: this.deps.registry.mock,
      createdAt: Date.now(),
    }
    this.rooms.set(room.id, { room, resumeId: null, inFlight: null })
    return room
  }

  get(roomId: Id): Room | undefined {
    return this.rooms.get(roomId)?.room
  }

  list(): Room[] {
    return [...this.rooms.values()].map((live) => live.room)
  }

  /**
   * Reseats the room.
   *
   * The thread does not travel: a resume id belongs to one CLI's conversation,
   * and handing Claude's thread to Codex would at best fail and at worst
   * resume something unrelated. So the new seat starts fresh, and the
   * transcript above it stays — which is the honest reading, since what was
   * said was said, just not by this seat.
   */
  setSeat(roomId: Id, seat: AgentConfig): Room {
    assertSeatable(seat)
    const live = this.require(roomId)
    if (live.room.status !== 'idle') {
      throw new RoomError('that room is mid-turn; stop it before changing the seat')
    }
    live.room = { ...live.room, seat }
    live.resumeId = null
    return live.room
  }

  /**
   * One exchange: the person's message, then the seat's reply.
   *
   * Resolves when the seat is done. The human turn is on the record before the
   * dispatch, so what was asked survives a crash mid-answer.
   */
  async send(roomId: Id, text: string): Promise<RoomTurn> {
    const live = this.require(roomId)
    if (live.room.status !== 'idle') {
      throw new RoomError('that room is already waiting on a reply')
    }

    this.append(live, {
      id: `turn-${randomUUID()}`,
      roomId,
      author: 'human',
      vendor: null,
      profile: '',
      text,
      usage: emptyUsage(),
      startedAt: Date.now(),
      endedAt: Date.now(),
      error: null,
    })

    const seat = live.room.seat
    const turn: RoomTurn = {
      id: `turn-${randomUUID()}`,
      roomId,
      author: 'agent',
      vendor: seat.vendor,
      profile: seat.profile ?? '',
      text: '',
      usage: emptyUsage(),
      startedAt: Date.now(),
      endedAt: null,
      error: null,
    }

    live.room = { ...live.room, status: 'thinking' }
    live.inFlight = new AbortController()
    this.append(live, turn)
    this.deps.emit({ type: 'room.turn.started', roomId, turn })

    let result
    try {
      result = await this.deps.registry.get(seat.vendor).run({
        systemPrompt: roomSeatSystemPrompt(seat),
        // The message alone. The seat is resumed, so the conversation it is
        // replying to is already in the CLI's own history — sending the
        // transcript too would pay for it twice and grow every turn.
        prompt: text,
        cfg: seat,
        capability: 'read',
        cwd: live.room.cwd,
        resumeId: live.resumeId,
        signal: live.inFlight.signal,
        timeoutMs: TURN_TIMEOUT_MS,
        onDelta: (delta) =>
          this.deps.emit({ type: 'room.turn.delta', roomId, turnId: turn.id, text: delta }),
        // Relayed, never recorded. A tool call is what is happening now; the
        // turn is what happened.
        onActivity: (text) => this.deps.emit({ type: 'room.activity', roomId, text }),
      })
    } catch (err) {
      // An adapter that throws rather than returning an error result. Same
      // treatment: the turn records what happened and the room stays usable.
      result = {
        text: '',
        usage: emptyUsage(),
        resumeId: null,
        exitCode: -1,
        error: err instanceof Error ? err.message : String(err),
      }
    }

    const finished: RoomTurn = {
      ...turn,
      text: result.text,
      usage: result.usage,
      endedAt: Date.now(),
      error: result.error,
    }

    // The room may have been closed while the seat was thinking; nothing to
    // update, and no event worth sending about a room nobody can see.
    if (!this.rooms.has(roomId)) return finished

    live.resumeId = result.resumeId ?? live.resumeId
    live.inFlight = null
    live.room = {
      ...live.room,
      status: 'idle',
      usage: addUsage(live.room.usage, result.usage),
      turns: live.room.turns.map((t) => (t.id === turn.id ? finished : t)),
    }
    this.deps.emit({ type: 'room.turn.ended', roomId, turn: finished })
    return finished
  }

  /**
   * Abandons the in-flight turn. The room survives, and so does everything
   * said in it — this is a stop, not a close.
   */
  stop(roomId: Id): void {
    const live = this.rooms.get(roomId)
    live?.inFlight?.abort()
  }

  close(roomId: Id): void {
    const live = this.rooms.get(roomId)
    if (!live) return
    live.inFlight?.abort()
    this.rooms.delete(roomId)
  }

  /** Every room, abandoned. Called when the app is quitting. */
  disposeAll(): void {
    for (const id of [...this.rooms.keys()]) this.close(id)
  }

  private require(roomId: Id): LiveRoom {
    const live = this.rooms.get(roomId)
    if (!live) throw new RoomError('no such room')
    return live
  }

  private append(live: LiveRoom, turn: RoomTurn): void {
    live.room = { ...live.room, turns: [...live.room.turns, turn] }
  }
}
