import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Gavel, Pencil, Plus, Send, Square, X } from 'lucide-react'
import type { AgentProfile, Id, Room, RoomSeat, RoomTurn, RoomVerdict } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { api } from '../lib/api'
import { parseMarkdown, type TextSpan } from '../lib/markdown'
import { Dialog, Empty, Field } from './ui'

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
  /** Live text per in-flight turn — several seats can stream at once. */
  const [streaming, setStreaming] = useState<Record<Id, string>>({})
  const [draft, setDraft] = useState('')
  const [profiles, setProfiles] = useState<AgentProfile[]>([])
  /** What each seat is doing right now. Never recorded; cleared when it stops. */
  const [activity, setActivity] = useState<Record<string, string>>({})
  const [error, setError] = useState('')
  const [adding, setAdding] = useState(false)
  const [verdicts, setVerdicts] = useState<RoomVerdict[]>([])
  const [converging, setConverging] = useState<string | null>(null)
  const scroller = useRef<HTMLDivElement>(null)

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
    void api
      .listRoomVerdicts(roomId)
      .then((rows) => {
        if (!cancelled) setVerdicts(Array.isArray(rows) ? rows : [])
      })
      .catch(() => {
        /* A room with no verdicts is the normal case. */
      })
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
            current
              ? { ...current, status: 'thinking', turns: [...current.turns, event.turn] }
              : current,
          )
          setStreaming((current) => ({ ...current, [event.turn.id]: '' }))
        } else if (event.type === 'room.activity') {
          // Per seat, and last one wins within a seat: this is a status line,
          // not a log. The scrolling history of tool calls belongs to a
          // terminal pane; here it would compete with the reply.
          setActivity((current) => ({ ...current, [event.seat]: event.text }))
        } else if (event.type === 'room.turn.delta') {
          setStreaming((current) =>
            event.turnId in current
              ? { ...current, [event.turnId]: (current[event.turnId] ?? '') + event.text }
              : current,
          )
          onOutput()
        } else if (event.type === 'room.turn.ended') {
          setStreaming((current) => {
            const next = { ...current }
            delete next[event.turn.id]
            return next
          })
          setActivity((current) => {
            const next = { ...current }
            delete next[event.turn.seat]
            return next
          })
          setRoom((current) => {
            if (!current) return current
            // Upsert, not replace. The ended turn is authoritative over
            // anything streamed — a dropped chunk corrects itself here — and
            // appending when it is unknown is what carries the human's own
            // message, and any turn that began before this pane was mounted.
            const known = current.turns.some((t) => t.id === event.turn.id)
            return {
              ...current,
              turns: known
                ? current.turns.map((t) => (t.id === event.turn.id ? event.turn : t))
                : [...current.turns, event.turn],
            }
          })
          onOutput()
        } else if (event.type === 'room.verdict') {
          setVerdicts((current) => [event.verdict, ...current])
        } else if (event.type === 'room.changed') {
          // The authoritative shape — status, seats, spend, budget. Turns are
          // kept from local state, which is ahead of it while streaming.
          setRoom((current) => (current ? { ...event.room, turns: current.turns } : event.room))
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
  }, [room?.turns.length, streaming])

  const act = async <T,>(work: Promise<T>): Promise<T | null> => {
    try {
      setError('')
      return await work
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
      return null
    }
  }

  const send = async (): Promise<void> => {
    const text = draft.trim()
    if (!text || !room || room.status !== 'idle') return
    setDraft('')
    const sent = await act(api.sendToRoom(roomId, text))
    // A refused message — a bad address, a spent budget — must put the text
    // back rather than swallowing what somebody typed.
    if (!sent) setDraft(text)
  }

  const turns = useMemo(() => room?.turns ?? [], [room])

  if (!room) {
    return (
      <div className="room">
        <Empty title="Room not started" compact />
      </div>
    )
  }

  const busy = room.status === 'thinking'
  const unseated = profiles.filter(
    (profile) => !room.seats.some((seat) => seat.config.profile === profile.name),
  )

  return (
    <div className="room" onClick={onFocus} onFocusCapture={onFocus}>
      <div className="room__seat">
        {room.seats.map((seat) => (
          <SeatChip
            key={seat.id}
            seat={seat}
            activity={activity[seat.name] ?? ''}
            removable={room.seats.length > 1 && !busy}
            editable={!busy}
            onRemove={() => void act(api.removeRoomSeat(roomId, seat.id)).then((r) => r && setRoom({ ...r, turns: room.turns }))}
            onToggleWrite={() =>
              void act(api.setRoomSeatWrite(roomId, seat.id, !seat.write)).then(
                (r) => r && setRoom({ ...r, turns: room.turns }),
              )
            }
          />
        ))}

        {!busy && unseated.length > 0 ? (
          adding ? (
            <select
              className="select"
              aria-label="Add a seat"
              autoFocus
              defaultValue=""
              onChange={(event) => {
                const chosen = unseated.find((p) => p.name === event.target.value)
                setAdding(false)
                if (!chosen) return
                void act(
                  api.addRoomSeat(roomId, {
                    vendor: chosen.vendor,
                    model: chosen.model,
                    effort: chosen.effort,
                    persona: chosen.persona,
                    profile: chosen.name,
                  }),
                ).then((r) => r && setRoom({ ...r, turns: room.turns }))
              }}
              onBlur={() => setAdding(false)}
            >
              <option value="">Seat a profile…</option>
              {unseated.map((profile) => (
                <option key={profile.id} value={profile.name}>
                  {profile.name}
                </option>
              ))}
            </select>
          ) : (
            <button
              className="btn btn--subtle btn--icon btn--sm"
              aria-label="Add a seat"
              title="Seat another profile in this room"
              onClick={() => setAdding(true)}
            >
              <Plus size={12} strokeWidth={2} />
            </button>
          )
        ) : null}

        <span className="spacer" />
        <Spend room={room} />
        <WriteState seats={room.seats} />
      </div>

      {error ? (
        <div className="room__error room__error--banner" role="alert">
          {error}
        </div>
      ) : null}

      <div className="room__transcript" ref={scroller}>
        {turns.length === 0 ? (
          <Empty
            title={`${room.seats.map((s) => `@${s.name}`).join(', ')} seated`}
            body={
              room.seats.length > 1
                ? 'Say something and every seat answers independently. Start with @name to ask one of them; name a seat mid-sentence to show them what it said.'
                : 'Say something. The seat reads this folder and answers; nothing here can change a file.'
            }
            compact
          />
        ) : null}
        {turns.map((turn) => (
          <RoomTurnView
            key={turn.id}
            turn={turn}
            live={turn.id in streaming ? (streaming[turn.id] ?? '') : null}
            activity={activity[turn.seat] ?? ''}
          />
        ))}
      </div>

      {verdicts.length > 0 ? <VerdictStrip verdicts={verdicts} /> : null}

      <div className="room__composer">
        <textarea
          className="input room__input"
          rows={2}
          placeholder={
            busy
              ? 'Waiting on the seat…'
              : room.status === 'exhausted'
                ? 'Budget spent — raise it to continue.'
                : room.seats.length > 1
                  ? 'Everyone answers. @name asks one; naming a seat mid-sentence shows them its last turn.'
                  : 'Say something…'
          }
          value={draft}
          disabled={room.status === 'exhausted'}
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
        {busy ? (
          <button
            className="btn btn--sm"
            onClick={() => void api.stopRoom(roomId)}
            title="Abandon this turn — the room and everything said in it survive"
          >
            <Square size={12} strokeWidth={2} />
            Stop
          </button>
        ) : room.status === 'exhausted' ? (
          <button
            className="btn btn--primary btn--sm"
            onClick={() =>
              void act(
                api.setRoomCaps(roomId, {
                  turns: room.caps.turns + 20,
                  costUsd: room.caps.costUsd,
                }),
              ).then((r) => r && setRoom({ ...r, turns: room.turns }))
            }
            title="Twenty more turns"
          >
            Raise budget
          </button>
        ) : (
          <>
            {room.seats.length > 1 && turns.some((t) => t.author === 'agent') ? (
              <button
                className="btn btn--sm"
                onClick={() => void act(api.advanceRoom(roomId, room.seats.length))}
                title="Let the seats answer each other — one turn per seat"
              >
                Advance
              </button>
            ) : null}
            {turns.some((t) => t.author === 'agent') ? (
              <button
                className="btn btn--sm"
                onClick={() => setConverging(draft.trim())}
                title="Ask every seat to record its own verdict, independently"
              >
                <Gavel size={12} strokeWidth={2} />
                Converge
              </button>
            ) : null}
            <button
              className="btn btn--primary btn--sm"
              disabled={!draft.trim()}
              onClick={() => void send()}
              aria-label="Send"
            >
              <Send size={12} strokeWidth={2} />
            </button>
          </>
        )}
      </div>

      {converging !== null ? (
        <ConvergeDialog
          seats={room.seats.length}
          question={converging}
          onClose={() => setConverging(null)}
          onConfirm={(question) => {
            setConverging(null)
            setDraft('')
            void act(api.convergeRoom(roomId, question))
          }}
        />
      ) : null}

      {focused ? null : <div className="room__unfocused" aria-hidden />}
    </div>
  )
}

function SeatChip({
  seat,
  activity,
  removable,
  editable,
  onRemove,
  onToggleWrite,
}: {
  seat: RoomSeat
  activity: string
  removable: boolean
  editable: boolean
  onRemove: () => void
  onToggleWrite: () => void
}): ReactNode {
  return (
    <span
      className={`room__chip ${activity ? 'is-working' : ''} ${seat.write ? 'can-write' : ''}`}
      title={seat.config.vendor}
    >
      <span className="room__chip-name">@{seat.name}</span>
      {activity ? <span className="room__activity">{activity}</span> : null}
      {editable ? (
        <button
          className="room__chip-x"
          aria-label={seat.write ? `Make @${seat.name} read-only` : `Let @${seat.name} write`}
          title={
            seat.write
              ? 'This seat can change files here. Click to make it read-only.'
              : 'Let this seat change files in this folder.'
          }
          onClick={onToggleWrite}
        >
          <Pencil size={10} strokeWidth={2.5} />
        </button>
      ) : null}
      {removable ? (
        <button
          className="room__chip-x"
          aria-label={`Remove @${seat.name}`}
          onClick={onRemove}
        >
          <X size={10} strokeWidth={2.5} />
        </button>
      ) : null}
    </span>
  )
}

/**
 * What the seats may do, stated without being asked.
 *
 * The room header carries this permanently because a per-seat write flag is
 * STANDING authorisation — it lasts until somebody turns it off — and a
 * capability that persists silently is one nobody remembers granting.
 */
function WriteState({ seats }: { seats: readonly RoomSeat[] }): ReactNode {
  const writers = seats.filter((seat) => seat.write)
  if (writers.length === 0) {
    return (
      <span className="room__readonly" title="Every seat reads this folder and changes nothing.">
        read-only
      </span>
    )
  }
  return (
    <span
      className="room__readonly is-writing"
      title="These seats can change files in this folder until you turn it off."
    >
      {writers.map((seat) => `@${seat.name}`).join(' ')} can write
    </span>
  )
}

/**
 * What this room has spent, against what it may.
 *
 * Turns lead because they are the cap doing the real work: Codex reports no
 * cost at all and Claude reports a notional figure, so a dollar total alone
 * would be the least trustworthy number on screen presented as the headline.
 */
function Spend({ room }: { room: Room }): ReactNode {
  const cost = room.usage.costUsd
  return (
    <span
      className={`room__spend ${room.status === 'exhausted' ? 'is-spent' : ''}`}
      title={`${room.turnsSpent} of ${room.caps.turns} turns spent${room.caps.costUsd > 0 ? `, ceiling $${room.caps.costUsd.toFixed(2)}` : ''}`}
    >
      {room.turnsSpent}/{room.caps.turns} turns
      {cost > 0 ? ` · $${cost.toFixed(2)}` : ''}
    </span>
  )
}

function RoomTurnView({
  turn,
  live,
  activity,
}: {
  turn: RoomTurn
  live: string | null
  activity: string
}): ReactNode {
  // While streaming, the live text IS the turn: the row's own text is empty
  // until the turn ends.
  const body = live !== null && !turn.endedAt ? live : turn.text
  const waiting = live !== null && !turn.endedAt && !live

  return (
    <div className={`room__turn room__turn--${turn.author}`}>
      <div className="room__author">{turn.author === 'human' ? 'You' : `@${turn.seat}`}</div>
      {turn.error ? (
        <div className="room__error" role="alert">
          {turn.error}
        </div>
      ) : waiting ? (
        // Before the first delta there is nothing to read, so this is the one
        // place the tool call is the whole message rather than a status line.
        <div className="room__thinking">{activity || 'Thinking…'}</div>
      ) : (
        <Markdown text={body} />
      )}
    </div>
  )
}

/**
 * A reply, read rather than scanned.
 *
 * Rendering to React elements — never an HTML string — is what makes this safe
 * to point at model output: there is no parse step that could produce markup,
 * so the whole injection class is closed by construction rather than by
 * sanitising.
 *
 * The human's own turns go through the same renderer. Somebody pasting a path
 * in backticks should see it set as code in their own message too, and having
 * one path means the transcript cannot develop two typographies.
 */
function Markdown({ text }: { text: string }): ReactNode {
  const blocks = useMemo(() => parseMarkdown(text), [text])

  return (
    <div className="room__body">
      {blocks.map((block, index) => {
        const key = `${block.kind}-${index}`
        if (block.kind === 'code') {
          return (
            <pre className="room__code" key={key}>
              <code>{block.text}</code>
            </pre>
          )
        }
        if (block.kind === 'heading') {
          // Capped and styled by level rather than by tag size: a room is not
          // a document, and an h1 inside a pane would outweigh the app's own
          // chrome.
          const Tag = `h${Math.min(block.level + 2, 6)}` as 'h3'
          return (
            <Tag className={`room__heading room__heading--${block.level}`} key={key}>
              <Spans spans={block.spans} />
            </Tag>
          )
        }
        if (block.kind === 'list') {
          const Tag = block.ordered ? 'ol' : 'ul'
          return (
            <Tag className="room__list" key={key}>
              {block.items.map((item, itemIndex) => (
                <li key={itemIndex}>
                  <Spans spans={item} />
                </li>
              ))}
            </Tag>
          )
        }
        return (
          <p className="room__para" key={key}>
            <Spans spans={block.spans} />
          </p>
        )
      })}
    </div>
  )
}

function Spans({ spans }: { spans: TextSpan[] }): ReactNode {
  return (
    <>
      {spans.map((span, index) => {
        if (span.kind === 'strong') return <strong key={index}>{span.text}</strong>
        if (span.kind === 'em') return <em key={index}>{span.text}</em>
        if (span.kind === 'code')
          return (
            <code className="room__inline-code" key={index}>
              {span.text}
            </code>
          )
        return <span key={index}>{span.text}</span>
      })}
    </>
  )
}

/**
 * The confirmation before a converge.
 *
 * Converging costs one turn per seat and produces the one artifact in a room
 * that reads as a conclusion, so it is worth a beat — and the beat is where
 * the question gets stated, which is the difference between a verdict on
 * something and a verdict on nothing in particular.
 */
function ConvergeDialog({
  seats,
  question,
  onClose,
  onConfirm,
}: {
  seats: number
  question: string
  onClose: () => void
  onConfirm: (question: string) => void
}): ReactNode {
  const [text, setText] = useState(question)
  return (
    <Dialog
      title="Converge"
      subtitle={`Every seat records its own verdict, independently. ${seats} turn${seats === 1 ? '' : 's'}.`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--primary" onClick={() => onConfirm(text)}>
            Ask the seats
          </button>
        </>
      }
    >
      <Field
        label="Question"
        hint="Leave empty to converge on whatever the room has been discussing."
      >
        <input
          className="input"
          autoFocus
          placeholder="Should we decompose renderApp, or measure first?"
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') onConfirm(text)
          }}
        />
      </Field>
    </Dialog>
  )
}

/**
 * What the room has concluded, newest first.
 *
 * Confidence and agreement are shown side by side because they answer
 * different questions — how sure the seats were, and how much they actually
 * agreed — and collapsing them into one number is exactly what makes a
 * confident-sounding verdict misleading. Dissent gets its own line whenever
 * there is any, because it is the first thing a summary would drop.
 */
function VerdictStrip({ verdicts }: { verdicts: readonly RoomVerdict[] }): ReactNode {
  const [open, setOpen] = useState(false)
  const latest = verdicts[0]
  if (!latest) return null

  return (
    <div className="room__verdict">
      <button className="room__verdict-head" onClick={() => setOpen((v) => !v)}>
        <span className="room__verdict-decision">{latest.decision}</span>
        <span className="spacer" />
        <span className="room__verdict-meta">
          confidence {latest.confidence.toFixed(2)}
          {latest.singleSource
            ? ' · one seat only'
            : ` · agreement ${latest.agreement.toFixed(2)}`}
          {verdicts.length > 1 ? ` · ${verdicts.length} verdicts` : ''}
        </span>
      </button>
      {open ? (
        <div className="room__verdict-body">
          <Markdown text={latest.report} />
        </div>
      ) : latest.dissent.trim() ? (
        <div className="room__verdict-dissent" title={latest.dissent}>
          Dissent: {latest.dissent.split('\n')[0]}
        </div>
      ) : null}
    </div>
  )
}
