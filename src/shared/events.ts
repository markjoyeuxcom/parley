import type { Id, Pane, Room, RoomTurn, RoomVerdict } from './domain'

/**
 * Events pushed from the main process to the renderer.
 *
 * One discriminated union over a single channel, so the renderer registers one
 * listener and switches on `type`. High-volume terminal output deliberately does
 * *not* travel here — see {@link PtyChunk}.
 */
export type AppEvent =
  // Rooms
  | { type: 'room.turn.started'; roomId: Id; turn: RoomTurn }
  | { type: 'room.turn.delta'; roomId: Id; turnId: Id; text: string }
  /**
   * What the seat is doing right now — "Read src/index.ts", "Bash npm test".
   *
   * Ephemeral and never persisted. It exists because a terminal pane shows
   * tool calls scrolling past and a room showed nothing at all between
   * "Thinking…" and prose, which is most of what made a headless seat feel
   * dead next to the CLI's own TUI. The durable account of a turn is the turn.
   */
  | { type: 'room.activity'; roomId: Id; seat: string; text: string }
  /**
   * The finished turn, carrying the complete text.
   *
   * Not redundant with the deltas: a client that mounted mid-turn, or dropped
   * a chunk, is corrected here rather than left holding a partial reply.
   */
  | { type: 'room.turn.ended'; roomId: Id; turn: RoomTurn }
  /**
   * The room's own shape changed — status, seats, spend, budget.
   *
   * A snapshot rather than deltas: a room is small, several seats mutate it
   * concurrently, and shipping the whole thing makes the pane's fold
   * trivially correct instead of a merge that has to be right under
   * interleaving. Carries `roomId` beside the room redundantly, so every room
   * event can be filtered by one predicate.
   */
  | { type: 'room.changed'; roomId: Id; room: Room }
  /** The seats concluded something. Kept, never replaced — see RoomVerdict. */
  | { type: 'room.verdict'; roomId: Id; verdict: RoomVerdict }
  // Grid
  | { type: 'pane.created'; pane: Pane }
  | { type: 'pane.status'; paneId: Id; status: Pane['status']; exitCode?: number | null }
  | { type: 'pane.closed'; paneId: Id }
  // Cross-cutting
  | { type: 'notice'; level: 'info' | 'warn' | 'error'; message: string }

export type AppEventType = AppEvent['type']

/**
 * Terminal output. Kept off {@link AppEvent} and unvalidated on the hot path:
 * a busy pane emits thousands of chunks and schema-parsing each one would
 * dominate the frame budget.
 */
export interface PtyChunk {
  paneId: Id
  data: string
}
