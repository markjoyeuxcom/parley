import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Square, Send } from 'lucide-react'
import type { AgentConfig, AgentProfile, Id, Room, RoomTurn } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { api } from '../lib/api'
import { Empty } from './ui'

/**
 * A room, in a grid slot.
 *
 * The counterpart to TerminalPane, and the shape of the whole pivot: a pane
 * that is a conversation rather than a process. No xterm, no PTY, no ANSI —
 * turns arrive as text over the event channel and render as text.
 *
 * The live turn is held in local state rather than pushed through the store.
 * Deltas arrive at whatever rate the CLI streams, and a reducer dispatch per
 * chunk would re-render every pane in the grid for a character landing in one
 * of them. The same reasoning that keeps PTY bytes off the validated event
 * channel, one level up.
 */

function seatLabel(seat: AgentConfig): string {
  const profile = seat.profile?.trim()
  if (profile) return profile
  return seat.model.trim() ? `${seat.vendor} · ${seat.model.trim()}` : seat.vendor
}

export function RoomPane({
  roomId,
  focused,
  onFocus,
  onOutput,
}: {
  roomId: Id
  focused: boolean
  onFocus: () => void
  onOutput: () => void
}): ReactNode {
  const [room, setRoom] = useState<Room | null>(null)
  const [streaming, setStreaming] = useState<{ turnId: Id; text: string } | null>(null)
  const [draft, setDraft] = useState('')
  const [profiles, setProfiles] = useState<AgentProfile[]>([])
  const scroller = useRef<HTMLDivElement>(null)
  const composer = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    let cancelled = false
    void api
      .getRoom(roomId)
      .then((loaded) => {
        if (!cancelled) setRoom(loaded)
      })
      .catch(() => {
        /* A room that cannot be read renders its empty state, not a crash. */
      })
    return () => {
      cancelled = true
    }
  }, [roomId])

  // The roster, so a seat can be staffed from a name rather than re-typed.
  useEffect(() => {
    let cancelled = false
    void api
      .listAgentProfiles()
      .then((rows) => {
        if (!cancelled) setProfiles(Array.isArray(rows) ? rows : [])
      })
      .catch(() => {
        /* A room with no profiles still has its default seat. */
      })
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(
    () =>
      api.onEvent((event: AppEvent) => {
        if (!('roomId' in event) || event.roomId !== roomId) return
        if (event.type === 'room.turn.started') {
          setRoom((current) =>
            current ? { ...current, status: 'thinking', turns: [...current.turns, event.turn] } : current,
          )
          setStreaming({ turnId: event.turn.id, text: '' })
        } else if (event.type === 'room.turn.delta') {
          setStreaming((current) =>
            current && current.turnId === event.turnId
              ? { ...current, text: current.text + event.text }
              : current,
          )
          onOutput()
        } else if (event.type === 'room.turn.ended') {
          setStreaming(null)
          setRoom((current) =>
            current
              ? {
                  ...current,
                  status: 'idle',
                  // The ended turn is authoritative over anything streamed: a
                  // dropped chunk corrects itself here rather than leaving a
                  // silently truncated reply on screen.
                  turns: current.turns.map((t) => (t.id === event.turn.id ? event.turn : t)),
                }
              : current,
          )
          onOutput()
        }
      }),
    [roomId, onOutput],
  )

  // Follow the tail while a seat is talking. Only when already near the bottom,
  // so scrolling back to re-read something is not yanked away mid-sentence.
  useEffect(() => {
    const el = scroller.current
    if (!el) return
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 120
    if (nearBottom) el.scrollTop = el.scrollHeight
  }, [room?.turns.length, streaming?.text])

  const send = async (): Promise<void> => {
    const text = draft.trim()
    if (!text || !room || room.status !== 'idle') return
    setDraft('')
    // Optimistic, and honest about being so: the human turn is on the record in
    // main the moment this resolves, but the person should see what they typed
    // land immediately rather than after a round trip.
    setRoom((current) =>
      current
        ? {
            ...current,
            status: 'thinking',
            turns: [
              ...current.turns,
              {
                id: `pending-${Date.now()}`,
                roomId,
                author: 'human',
                vendor: null,
                profile: '',
                text,
                usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
                startedAt: Date.now(),
                endedAt: Date.now(),
                error: null,
              },
            ],
          }
        : current,
    )
    await api.sendToRoom(roomId, text).catch(() => {
      setRoom((current) => (current ? { ...current, status: 'idle' } : current))
    })
  }

  const turns = useMemo(() => room?.turns ?? [], [room])

  if (!room) {
    return (
      <div className="room">
        <Empty title="Room not started" compact />
      </div>
    )
  }

  return (
    <div className="room" onClick={onFocus} onFocusCapture={onFocus}>
      <div className="room__seat">
        <span className="room__seat-name">{seatLabel(room.seat)}</span>
        {profiles.length > 0 ? (
          <select
            className="select"
            aria-label="Seat"
            value={room.seat.profile ?? ''}
            disabled={room.status !== 'idle'}
            onChange={(event) => {
              const chosen = profiles.find((p) => p.name === event.target.value)
              if (!chosen) return
              void api
                .setRoomSeat(roomId, {
                  vendor: chosen.vendor,
                  model: chosen.model,
                  effort: chosen.effort,
                  persona: chosen.persona,
                  profile: chosen.name,
                })
                .then((updated) => setRoom(updated))
                .catch(() => {
                  /* A refused seat leaves the one that works in place. */
                })
            }}
          >
            <option value="">{room.seat.profile ? 'Change seat…' : 'Seat from a profile…'}</option>
            {profiles.map((profile) => (
              <option key={profile.id} value={profile.name}>
                {profile.name}
              </option>
            ))}
          </select>
        ) : null}
        <span className="spacer" />
        <span className="room__readonly" title="A room seat reads this folder and writes nothing.">
          read-only
        </span>
      </div>

      <div className="room__transcript" ref={scroller}>
        {turns.length === 0 ? (
          <Empty
            title={`${seatLabel(room.seat)} is seated`}
            body="Say something. The seat reads this folder and answers; nothing here can change a file."
            compact
          />
        ) : null}
        {turns.map((turn) => (
          <RoomTurnView
            key={turn.id}
            turn={turn}
            seatName={seatLabel(room.seat)}
            live={streaming?.turnId === turn.id ? streaming.text : null}
          />
        ))}
      </div>

      <div className="room__composer">
        <textarea
          ref={composer}
          className="input room__input"
          rows={2}
          placeholder={room.status === 'thinking' ? 'Waiting on the seat…' : 'Say something…'}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          onFocus={onFocus}
          onKeyDown={(event) => {
            // ⏎ sends, ⇧⏎ makes a paragraph. The inverse of a code editor and
            // the right way round for a conversation.
            if (event.key === 'Enter' && !event.shiftKey) {
              event.preventDefault()
              void send()
            }
          }}
        />
        {room.status === 'thinking' ? (
          <button
            className="btn btn--sm"
            onClick={() => void api.stopRoom(roomId)}
            title="Abandon this turn — the room and everything said in it survive"
          >
            <Square size={12} strokeWidth={2} />
            Stop
          </button>
        ) : (
          <button
            className="btn btn--primary btn--sm"
            disabled={!draft.trim()}
            onClick={() => void send()}
            aria-label="Send"
          >
            <Send size={12} strokeWidth={2} />
          </button>
        )}
      </div>

      {focused ? null : <div className="room__unfocused" aria-hidden />}
    </div>
  )
}

function RoomTurnView({
  turn,
  seatName,
  live,
}: {
  turn: RoomTurn
  seatName: string
  live: string | null
}): ReactNode {
  // While streaming, the live text IS the turn: the row's own text is empty
  // until the turn ends.
  const body = live !== null && !turn.endedAt ? live : turn.text
  const waiting = live !== null && !turn.endedAt && !live

  return (
    <div className={`room__turn room__turn--${turn.author}`}>
      <div className="room__author">{turn.author === 'human' ? 'You' : seatName}</div>
      {turn.error ? (
        <div className="room__error" role="alert">
          {turn.error}
        </div>
      ) : waiting ? (
        <div className="room__thinking">Thinking…</div>
      ) : (
        <div className="room__body">{body}</div>
      )}
    </div>
  )
}
