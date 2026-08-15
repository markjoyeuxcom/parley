import { randomUUID } from 'node:crypto'
import type {
  AgentConfig,
  Capability,
  Id,
  Room,
  RoomCaps,
  RoomSeat,
  RoomTurn,
  RoomVerdict,
  Usage,
} from '@shared/domain'
import { VERDICT_CONTRACT } from '@shared/protocol'
import { mergeVerdicts, parseSeatVerdict } from '@main/orchestrator/verdict'
import type { AppEvent } from '@shared/events'
import { emptyUsage } from '@shared/usage'
import { seatingRefusals } from '@shared/vendors'
import {
  contextPrompt,
  convergePrompt,
  parseAddress,
  relayPrompt,
  renderRoomVerdict,
  roomSeatSystemPrompt,
  seatName,
  uniqueSeatName,
} from '@shared/room'
import { assertCapability, type AgentRegistry } from '@main/agents'
import type { Repo } from '@main/store/repo'

/**
 * Free-flow rooms.
 *
 * The engine the scheduled exchange was hiding. `SessionRunner` owns turn
 * mechanics, resume threading and delivery — all of which a conversation
 * needs — wrapped around a fixed stage list and a structured verdict contract,
 * which is what made a debate feel like a form with two respondents. This is
 * the same mechanics with no schedule: a person decides who speaks and when.
 *
 * Four properties carry the design:
 *
 * **The seat is resumed, never replayed.** The CLI keeps its own conversation
 * and Parley relays only what is new, so token cost grows linearly with turn
 * count rather than quadratically. This is what makes a long room affordable,
 * and the one a "re-send the transcript" implementation would silently
 * destroy.
 *
 * **Seats answering the same question do not hear each other.** An
 * unaddressed message reaches every seat concurrently and independently, so
 * two answers are two reads rather than one read and an agreement. That
 * property is the whole reason to have more than one seat, and sequencing
 * them for tidiness would quietly remove it. Sharing is therefore an explicit
 * act: naming a seat mid-sentence relays its last turn, and `advance` is the
 * mode where every seat hears the one before it.
 *
 * **Read-only.** A room seat reads the folder its pane lives in and writes
 * nothing. The per-seat write opt-in is m5; until then there is no code path
 * here that can reach `write`.
 *
 * **A failed turn is a recorded turn.** The transcript is the work; wedging a
 * room because one dispatch errored would lose something the error did not.
 *
 * The record is the store; this holds the live half — which seats are mid-turn
 * and which vendor thread each one resumes on. Everything durable is written
 * through as it happens, so a crash mid-answer loses the answer and not the
 * question.
 *
 * Resume ids deliberately do NOT persist. A vendor thread belongs to a CLI
 * process's own history, and Parley cannot know whether it still exists after
 * a restart — a stale one fails at the next turn, in a way that looks like the
 * seat breaking rather than the thread being gone. A reopened room starts its
 * seats fresh against a transcript they can read.
 */

export class RoomError extends Error {}

/** How long one seat's turn may run before it is abandoned. */
const TURN_TIMEOUT_MS = 25 * 60 * 1000

export interface RoomManagerDeps {
  registry: AgentRegistry
  repo: Repo
  emit: (event: AppEvent) => void
}

interface LiveRoom {
  room: Room
  /** Vendor threads by seat id, so each seat resumes its own conversation. */
  resumeIds: Map<Id, string | null>
  /** One per in-flight turn; several run at once when a room is addressed. */
  inFlight: Map<Id, AbortController>
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
 * Refuses a seat this app cannot dispatch, with the reason the rest of the
 * app already gives. Checked wherever a seat is chosen, so an impossible seat
 * fails at the moment somebody picked it rather than at the next message.
 */
function assertSeatable(config: AgentConfig): void {
  const refusals = seatingRefusals([{ vendor: config.vendor, role: 'room-seat', toolFree: false }])
  if (refusals.length > 0) throw new RoomError(refusals.join('; '))
}

export class RoomManager {
  private readonly rooms = new Map<Id, LiveRoom>()

  constructor(private readonly deps: RoomManagerDeps) {}

  open(cwd: string, configs: AgentConfig[], caps: RoomCaps): Room {
    if (configs.length === 0) throw new RoomError('a room needs at least one seat')
    for (const config of configs) assertSeatable(config)

    const seats: RoomSeat[] = []
    for (const config of configs) {
      seats.push({
        id: `seat-${randomUUID()}`,
        name: uniqueSeatName(seatName(config), seats.map((s) => s.name)),
        config,
        // Every seat arrives read-only. Writing is a deliberate act with a
        // control of its own, never a property of how a room was opened.
        write: false,
      })
    }

    const room: Room = {
      id: `room-${randomUUID()}`,
      cwd,
      seats,
      caps,
      turnsSpent: 0,
      status: 'idle',
      turns: [],
      usage: emptyUsage(),
      mock: this.deps.registry.mock,
      createdAt: Date.now(),
    }
    this.deps.repo.createRoom({
      id: room.id,
      cwd: room.cwd,
      seats: room.seats,
      caps: room.caps,
      mock: room.mock,
    })
    this.rooms.set(room.id, { room, resumeIds: new Map(), inFlight: new Map() })
    return room
  }

  /**
   * Brings a room back from the record.
   *
   * Its seats are restored but nothing is running and no thread is resumed —
   * the saved-layout rule, applied to seats: no CLI session begins against a
   * subscription without somebody asking for one.
   */
  reopen(roomId: Id): Room {
    const live = this.rooms.get(roomId)
    if (live) return live.room
    const stored = this.deps.repo.getRoom(roomId)
    if (!stored) throw new RoomError('no such room')
    this.rooms.set(roomId, { room: stored, resumeIds: new Map(), inFlight: new Map() })
    return stored
  }

  /** Every room the record holds, newest first. Turns are not loaded. */
  listStored(limit?: number): Room[] {
    return this.deps.repo.listRooms(limit)
  }

  get(roomId: Id): Room | undefined {
    return this.rooms.get(roomId)?.room ?? this.deps.repo.getRoom(roomId)
  }

  list(): Room[] {
    return [...this.rooms.values()].map((live) => live.room)
  }

  /**
   * Replaces the room's only seat.
   *
   * The thread does not travel: a resume id belongs to one CLI's
   * conversation, and handing Claude's to Codex would at best fail. The new
   * seat starts fresh and the transcript above it stays — what was said was
   * said, just not by this seat.
   */
  setSeat(roomId: Id, config: AgentConfig): Room {
    assertSeatable(config)
    const live = this.requireIdle(roomId, 'change the seat')
    const [existing] = live.room.seats
    if (live.room.seats.length !== 1 || !existing) {
      throw new RoomError('this room has several seats — add or remove them instead')
    }
    live.resumeIds.delete(existing.id)
    live.room = {
      ...live.room,
      seats: [{ ...existing, name: seatName(config), config }],
    }
    this.deps.repo.setRoomSeats(roomId, live.room.seats)
    return live.room
  }

  addSeat(roomId: Id, config: AgentConfig): Room {
    assertSeatable(config)
    const live = this.requireIdle(roomId, 'add a seat')
    const seat: RoomSeat = {
      id: `seat-${randomUUID()}`,
      name: uniqueSeatName(seatName(config), live.room.seats.map((s) => s.name)),
      config,
      write: false,
    }
    live.room = { ...live.room, seats: [...live.room.seats, seat] }
    this.deps.repo.setRoomSeats(roomId, live.room.seats)
    return live.room
  }

  removeSeat(roomId: Id, seatId: Id): Room {
    const live = this.requireIdle(roomId, 'remove a seat')
    if (live.room.seats.length <= 1) throw new RoomError('a room needs at least one seat')
    live.resumeIds.delete(seatId)
    live.room = { ...live.room, seats: live.room.seats.filter((s) => s.id !== seatId) }
    this.deps.repo.setRoomSeats(roomId, live.room.seats)
    return live.room
  }

  /**
   * Turns a seat's ability to change files on or off.
   *
   * Refused mid-turn, because the dispatch a flip would change has already
   * happened — a toggle that appears to take effect and does not is worse
   * than one that refuses.
   */
  setSeatWrite(roomId: Id, seatId: Id, write: boolean): Room {
    const live = this.requireIdle(roomId, 'change what a seat may do')
    live.room = {
      ...live.room,
      seats: live.room.seats.map((seat) => (seat.id === seatId ? { ...seat, write } : seat)),
    }
    this.deps.repo.setRoomSeats(roomId, live.room.seats)
    this.deps.emit({ type: 'room.changed', roomId, room: live.room })
    return live.room
  }

  /**
   * Asks every seat what it concluded, independently, and merges the answers.
   *
   * The one thing genuinely lost to free flow, kept as an action rather than
   * a schedule. In an unscheduled room the seats converge on whoever spoke
   * last; here each is asked from its own resumed reading and none is shown
   * another's verdict — which is what makes disagreement mean something, and
   * why disagreement LOWERS the recorded confidence rather than being
   * averaged away.
   *
   * Returns null when nothing usable came back. A converge that produced
   * prose instead of a contract has established nothing, and a row claiming
   * otherwise would be the worst kind of record.
   */
  async converge(roomId: Id, question: string): Promise<RoomVerdict | null> {
    const live = this.require(roomId)
    if (live.room.status === 'thinking') throw new RoomError('that room is already waiting on a reply')
    if (!live.room.turns.some((turn) => turn.author === 'agent')) {
      throw new RoomError('nothing has been said yet for the seats to conclude on')
    }
    const refusal = this.exceeded(live.room, live.room.seats.length)
    if (refusal) {
      live.room = { ...live.room, status: 'exhausted' }
      throw new RoomError(refusal)
    }

    const prompt = convergePrompt(question, VERDICT_CONTRACT)
    const spoken = await this.speak(
      live,
      live.room.seats.map((seat) => ({ seat, prompt })),
    )

    const merged = mergeVerdicts(spoken.map((turn) => parseSeatVerdict(turn.text)))
    if (!merged) return null

    const verdict: RoomVerdict = {
      id: `verdict-${randomUUID()}`,
      roomId,
      question: question.trim(),
      decision: merged.decision,
      rationale: merged.rationale,
      scores: merged.scores,
      confidence: merged.confidence,
      agreement: merged.agreement,
      singleSource: merged.singleSource,
      dissent: merged.dissent,
      report: renderRoomVerdict(live.room, question, merged),
      createdAt: Date.now(),
    }
    this.deps.repo.saveRoomVerdict(verdict)
    this.deps.emit({ type: 'room.verdict', roomId, verdict })
    return verdict
  }

  listVerdicts(roomId: Id): RoomVerdict[] {
    return this.deps.repo.listRoomVerdicts(roomId)
  }

  /**
   * Raises or lowers the bound, and revives a room that stopped at one.
   *
   * Reviving is the whole point of keeping `exhausted` as a state rather than
   * an error: reaching a cap is a decision point, and continuing past it
   * should be a deliberate act with a number attached.
   */
  setCaps(roomId: Id, caps: RoomCaps): Room {
    const live = this.require(roomId)
    live.room = { ...live.room, caps }
    this.deps.repo.setRoomCaps(roomId, caps)
    if (live.room.status === 'exhausted' && this.exceeded(live.room, 1) === null) {
      live.room = { ...live.room, status: 'idle' }
    }
    return live.room
  }

  /**
   * The reason a room may not spend `count` more turns, or null.
   *
   * Checked before dispatch and never shown to a seat: an agent that can see
   * its budget can argue about it, and one that can argue about it will.
   */
  private exceeded(room: Room, count: number): string | null {
    if (room.turnsSpent + count > room.caps.turns) {
      return `this room's turn budget is spent (${room.turnsSpent} of ${room.caps.turns}); raise it to continue`
    }
    if (room.caps.costUsd > 0 && room.usage.costUsd >= room.caps.costUsd) {
      return `this room has reached its cost ceiling ($${room.usage.costUsd.toFixed(2)} of $${room.caps.costUsd.toFixed(2)}); raise it to continue`
    }
    return null
  }

  /**
   * One exchange: the person's message, then a reply from every seat it
   * addresses.
   *
   * Addressed seats run concurrently and see only the human's message — never
   * each other's answers. Resolves when they are all done.
   */
  async send(roomId: Id, text: string): Promise<RoomTurn[]> {
    const live = this.require(roomId)
    if (live.room.status === 'thinking') {
      throw new RoomError('that room is already waiting on a reply')
    }

    // Addressing is resolved BEFORE anything is recorded or spent, so a typo
    // costs nothing and leaves no turn behind.
    const { seatIds, contextSeatIds, body } = parseAddress(text, live.room.seats)

    // A named seat that has never spoken is refused rather than quietly
    // dropped. Silently sending the message without the context it asked for
    // reproduces the exact failure this rule exists to fix — a seat replying
    // "I cannot see what you are referring to" — except now it also looks
    // like the feature worked.
    for (const seatId of contextSeatIds) {
      const seat = live.room.seats.find((s) => s.id === seatId)
      if (!seat) continue
      if (!this.lastTurnOf(live.room, seat.name)) {
        throw new RoomError(`@${seat.name} has not said anything yet, so there is nothing to show`)
      }
    }
    const refusal = this.exceeded(live.room, seatIds.length)
    if (refusal) {
      live.room = { ...live.room, status: 'exhausted' }
      throw new RoomError(refusal)
    }

    // Announced, not just recorded. The person's own message has to appear the
    // moment they send it, and an optimistic copy in the pane would be a
    // second source of truth that drifts the first time a send is refused.
    const said: RoomTurn = {
      id: `turn-${randomUUID()}`,
      roomId,
      author: 'human',
      seat: '',
      vendor: null,
      profile: '',
      text,
      usage: emptyUsage(),
      startedAt: Date.now(),
      endedAt: Date.now(),
      error: null,
    }
    this.append(live, said)
    this.deps.repo.appendRoomTurn(roomId, said)
    this.deps.emit({ type: 'room.turn.ended', roomId, turn: said })

    const seats = live.room.seats.filter((seat) => seatIds.includes(seat.id))
    return this.speak(
      live,
      seats.map((seat) => ({
        seat,
        // Per speaker, because "self" differs by speaker: a seat is resumed
        // and already holds its own words, while the others in the same
        // message genuinely need them. Filtering this in the parser would
        // have starved every other seat whenever one of them was mentioned.
        prompt: contextPrompt(
          contextSeatIds
            .filter((id) => id !== seat.id)
            .flatMap((id) => {
              const from = live.room.seats.find((s) => s.id === id)
              const last = from ? this.lastTurnOf(live.room, from.name) : null
              return from && last ? [{ speaker: from.name, text: last.text }] : []
            }),
          body,
        ),
      })),
    )
  }

  /**
   * Round-robin: each seat in turn, hearing the one before it.
   *
   * The other half of routing, and the opposite trade to `send`. Here the
   * seats are talking to each other, so each is relayed the previous reply —
   * which means later speakers are anchored by earlier ones. That is what a
   * conversation is; it is also why it is not the default.
   *
   * Bounded twice: by the turns asked for, and by the budget, which wins.
   *
   * The unit is TURNS, not rounds. A round over three seats is three turns
   * and three dispatches, and a control labelled "2 rounds" would quietly
   * mean six — the same unit the budget counts in is the only one that can be
   * reasoned about.
   */
  async advance(roomId: Id, turns: number): Promise<void> {
    const live = this.require(roomId)
    if (live.room.status === 'thinking') throw new RoomError('that room is already waiting on a reply')
    if (live.room.seats.length < 2) throw new RoomError('advancing needs at least two seats')

    for (let i = 0; i < turns; i += 1) {
      const refusal = this.exceeded(live.room, 1)
      if (refusal) {
        live.room = { ...live.room, status: 'exhausted' }
        this.deps.emit({ type: 'room.changed', roomId: live.room.id, room: live.room })
        return
      }
      const last = [...live.room.turns].reverse().find((turn) => turn.author === 'agent')
      if (!last) throw new RoomError('nothing has been said yet for a seat to answer')

      // Whoever spoke last hands over to the next seat in order.
      const spokeAt = live.room.seats.findIndex((seat) => seat.name === last.seat)
      const next = live.room.seats[(spokeAt + 1) % live.room.seats.length]
      if (!next) return

      const [turn] = await this.speak(live, [
        { seat: next, prompt: relayPrompt(last.seat, last.text) },
      ])
      // A seat that failed ends the round rather than handing an error on as
      // though it were an argument.
      if (!turn || turn.error) return
    }
  }

  /** Runs one or more seats concurrently, recording each as its own turn. */
  private async speak(
    live: LiveRoom,
    work: Array<{ seat: RoomSeat; prompt: string }>,
  ): Promise<RoomTurn[]> {
    const roomId = live.room.id
    live.room = {
      ...live.room,
      status: 'thinking',
      turnsSpent: live.room.turnsSpent + work.length,
    }

    const started = work.map(({ seat, prompt }) => {
      const turn: RoomTurn = {
        id: `turn-${randomUUID()}`,
        roomId,
        author: 'agent',
        seat: seat.name,
        vendor: seat.config.vendor,
        profile: seat.config.profile ?? '',
        text: '',
        usage: emptyUsage(),
        startedAt: Date.now(),
        endedAt: null,
        error: null,
      }
      this.append(live, turn)
      // Written when it STARTS, with no text. A crash mid-answer then loses
      // the answer and not the question — and the question is the expensive
      // half to reconstruct.
      this.deps.repo.appendRoomTurn(roomId, turn)
      this.deps.emit({ type: 'room.turn.started', roomId, turn })
      return { seat, prompt, turn }
    })

    const finished = await Promise.all(
      started.map(({ seat, prompt, turn }) => this.dispatch(live, seat, prompt, turn)),
    )

    // The room may have been closed while its seats were thinking.
    if (!this.rooms.has(roomId)) return finished

    live.room = {
      ...live.room,
      status: this.exceeded(live.room, 1) ? 'exhausted' : 'idle',
    }
    this.deps.emit({ type: 'room.changed', roomId: live.room.id, room: live.room })
    return finished
  }

  private async dispatch(
    live: LiveRoom,
    seat: RoomSeat,
    prompt: string,
    turn: RoomTurn,
  ): Promise<RoomTurn> {
    const roomId = live.room.id
    const control = new AbortController()
    live.inFlight.set(turn.id, control)

    const capability: Capability = seat.write ? 'write' : 'read'
    // The last place a write could slip through. It cannot fire while the
    // capability is derived from the same flag it checks — which is the
    // point: any future path that sets one without the other is refused.
    assertCapability(capability, seat.write)

    let result
    try {
      result = await this.deps.registry.get(seat.config.vendor).run({
        systemPrompt: roomSeatSystemPrompt(seat.config),
        prompt,
        cfg: seat.config,
        // Derived from the seat rather than passed alongside it, so the two
        // cannot disagree. assertCapability below is the belt to this brace.
        capability,
        cwd: live.room.cwd,
        resumeId: live.resumeIds.get(seat.id) ?? null,
        signal: control.signal,
        timeoutMs: TURN_TIMEOUT_MS,
        onDelta: (delta) =>
          this.deps.emit({ type: 'room.turn.delta', roomId, turnId: turn.id, text: delta }),
        // Relayed, never recorded. A tool call is what is happening now; the
        // turn is what happened.
        onActivity: (text) =>
          this.deps.emit({ type: 'room.activity', roomId, seat: seat.name, text }),
      })
    } catch (err) {
      // An adapter that throws rather than returning an error result. Same
      // treatment: the turn records what happened, the room stays usable.
      result = {
        text: '',
        usage: emptyUsage(),
        resumeId: null,
        exitCode: -1,
        error: err instanceof Error ? err.message : String(err),
      }
    }

    live.inFlight.delete(turn.id)
    const done: RoomTurn = {
      ...turn,
      text: result.text,
      usage: result.usage,
      endedAt: Date.now(),
      error: result.error,
    }
    this.deps.repo.finishRoomTurn(done)
    if (!this.rooms.has(roomId)) return done

    if (result.resumeId) live.resumeIds.set(seat.id, result.resumeId)
    live.room = {
      ...live.room,
      usage: addUsage(live.room.usage, result.usage),
      turns: live.room.turns.map((t) => (t.id === turn.id ? done : t)),
    }
    this.deps.emit({ type: 'room.turn.ended', roomId, turn: done })
    return done
  }

  /**
   * Abandons every in-flight turn. The room survives, and so does everything
   * said in it — this is a stop, not a close.
   */
  stop(roomId: Id): void {
    const live = this.rooms.get(roomId)
    if (!live) return
    for (const control of live.inFlight.values()) control.abort()
  }

  /**
   * Lets go of the live room. The record keeps everything said in it — a pane
   * being closed is not a decision to destroy hours of reading.
   */
  close(roomId: Id): void {
    const live = this.rooms.get(roomId)
    if (!live) return
    for (const control of live.inFlight.values()) control.abort()
    this.rooms.delete(roomId)
    this.deps.repo.closeRoom(roomId)
  }

  /** Every room, abandoned. Called when the app is quitting. */
  disposeAll(): void {
    for (const id of [...this.rooms.keys()]) this.close(id)
  }

  /** The most recent thing a seat actually said, or null. */
  private lastTurnOf(room: Room, seatName: string): RoomTurn | null {
    for (let i = room.turns.length - 1; i >= 0; i -= 1) {
      const turn = room.turns[i]
      if (turn && turn.author === 'agent' && turn.seat === seatName && turn.text.trim()) return turn
    }
    return null
  }

  private require(roomId: Id): LiveRoom {
    const live = this.rooms.get(roomId)
    if (!live) throw new RoomError('no such room')
    return live
  }

  private requireIdle(roomId: Id, action: string): LiveRoom {
    const live = this.require(roomId)
    if (live.room.status === 'thinking') {
      throw new RoomError(`that room is mid-turn; stop it before you ${action}`)
    }
    return live
  }

  private append(live: LiveRoom, turn: RoomTurn): void {
    live.room = { ...live.room, turns: [...live.room.turns, turn] }
  }
}
