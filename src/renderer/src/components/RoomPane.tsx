import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { ArrowDown, Gavel, List, Pencil, Plus, Send, Square, X } from 'lucide-react'
import type { AgentProfile, Id, Room, RoomSeat, RoomTurn, RoomVerdict } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { api } from '../lib/api'
import { formatDuration } from '../lib/format'
import {
  matchSeats,
  mentionAt,
  previewAudience,
  turnOutline,
  type AudiencePreview,
} from '@shared/room'
import { parseMarkdown, type TextSpan } from '../lib/markdown'
import { Dialog, Empty, Field, Menu, MenuItem, MenuSection } from './ui'

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
  onReopen,
}: {
  roomId: Id
  focused: boolean
  onFocus: () => void
  onOutput: () => void
  /** Offered from the empty state — see the Empty below for why it is here. */
  onReopen: () => void
}): ReactNode {
  const [room, setRoom] = useState<Room | null>(null)
  /** Live text per in-flight turn — several seats can stream at once. */
  const [streaming, setStreaming] = useState<Record<Id, string>>({})
  const [draft, setDraft] = useState('')
  /**
   * Where the caret is, and which completion is highlighted.
   *
   * The caret is state rather than something read on demand because the
   * completion list depends on it: `@rev` offers seats, and the same text with
   * the caret past the space does not.
   */
  const [caret, setCaret] = useState(0)
  const [pick, setPick] = useState(0)
  /** Escape closes the list without closing the mention. Typing reopens it. */
  const [dismissed, setDismissed] = useState(false)
  /**
   * Turns folded down to their one-line summary.
   *
   * Held here rather than inside each turn so the index can fold the whole
   * room at once — folding twenty turns one at a time is not navigation. A
   * view state and nothing else: what was said is untouched, and a reload
   * comes back fully expanded, because a transcript that remembered what it
   * had been hiding would be a transcript that edits itself.
   */
  const [folded, setFolded] = useState<ReadonlySet<Id>>(new Set())
  /** False once the reader has scrolled away from the tail. */
  const [atBottom, setAtBottom] = useState(true)
  const [profiles, setProfiles] = useState<AgentProfile[]>([])
  /**
   * What each seat did on its way to an answer, per turn and in order.
   *
   * Ephemeral, like the events themselves: a reopened room shows its turns
   * without the actions behind them, because what a seat read is not part of
   * what it said. Kept as a LIST rather than a latest-wins line so a finished
   * turn can show its working — the thing a terminal pane has always had and
   * a room did not.
   */
  const [activity, setActivity] = useState<Record<Id, string[]>>({})
  /** Ticks while a seat is working, so an in-flight turn can show its age. */
  const [now, setNow] = useState(() => Date.now())
  const [error, setError] = useState('')
  const [adding, setAdding] = useState(false)
  const [verdicts, setVerdicts] = useState<RoomVerdict[]>([])
  const [converging, setConverging] = useState<string | null>(null)
  const scroller = useRef<HTMLDivElement>(null)
  const input = useRef<HTMLTextAreaElement>(null)
  /** Every turn's element, so the index can scroll to one. */
  const anchors = useRef(new Map<Id, HTMLDivElement>())
  /** Where to put the caret once a completion has re-rendered the box. */
  const pendingCaret = useRef<number | null>(null)

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
    void api
      .listRoomVerdicts(roomId)
      .then((rows) => {
        if (!cancelled) setVerdicts(Array.isArray(rows) ? rows : [])
      })
      .catch(() => {
        /* A room with no verdicts is the normal case. */
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
            current
              ? {
                  ...current,
                  status: 'thinking',
                  turns: [...current.turns, event.turn],
                }
              : current,
          )
          setStreaming((current) => ({ ...current, [event.turn.id]: '' }))
        } else if (event.type === 'room.activity') {
          setActivity((current) => ({
            ...current,
            [event.turnId]: [...(current[event.turnId] ?? []), event.text],
          }))
        } else if (event.type === 'room.turn.delta') {
          setStreaming((current) =>
            event.turnId in current
              ? {
                  ...current,
                  [event.turnId]: (current[event.turnId] ?? '') + event.text,
                }
              : current,
          )
          onOutput()
        } else if (event.type === 'room.turn.ended') {
          setStreaming((current) => {
            const next = { ...current }
            delete next[event.turn.id]
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

  // One ticker while anything is in flight, so a turn can say how long it has
  // been going. Stopped the moment the room is idle: a timer running all day
  // for a number nobody is watching is the thing this is meant to avoid.
  useEffect(() => {
    if (room?.status !== 'thinking') return
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [room?.status])

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

  // A completion rewrites the box, and a controlled textarea puts the caret at
  // the end of whatever it is given — which would strand it after a mention
  // completed mid-sentence. Restored after the render that changed the value.
  useLayoutEffect(() => {
    const at = pendingCaret.current
    if (at === null) return
    pendingCaret.current = null
    input.current?.focus()
    input.current?.setSelectionRange(at, at)
  }, [draft])

  const turns = useMemo(() => room?.turns ?? [], [room])

  if (!room) {
    return (
      <div className="room">
        <Empty title="Room not started" compact />
      </div>
    )
  }

  const mention = mentionAt(draft, caret)
  const completing: RoomSeat[] =
    dismissed || !mention || room.status === 'exhausted'
      ? []
      : matchSeats(mention.query, room.seats)

  /** Replace the half-typed mention with a real seat name, then keep typing. */
  const complete = (name: string): void => {
    if (!mention) return
    const at = mention.from + name.length + 2
    setDraft(`${draft.slice(0, mention.from)}@${name} ${draft.slice(caret)}`)
    setCaret(at)
    pendingCaret.current = at
  }

  const jumpTo = (id: Id): void => {
    anchors.current.get(id)?.scrollIntoView?.({ block: 'start', behavior: 'smooth' })
  }
  const jumpToLatest = (): void => {
    const el = scroller.current
    if (el) el.scrollTop = el.scrollHeight
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
            activity={latestFor(turns, activity, seat.name)}
            removable={room.seats.length > 1 && !busy}
            editable={!busy}
            onRemove={() =>
              void act(api.removeRoomSeat(roomId, seat.id)).then(
                (r) => r && setRoom({ ...r, turns: room.turns }),
              )
            }
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
        {turns.length > 2 ? (
          <Menu
            label={
              <>
                <List size={12} strokeWidth={2} />
                {turns.length}
              </>
            }
            title="Jump to a turn"
          >
            {(close) => (
              <>
                <MenuSection>
                  <MenuItem
                    onClick={() => {
                      setFolded(
                        folded.size === turns.length ? new Set() : new Set(turns.map((t) => t.id)),
                      )
                      close()
                    }}
                  >
                    {folded.size === turns.length ? 'Expand every turn' : 'Collapse every turn'}
                  </MenuItem>
                </MenuSection>
                <MenuSection>
                  {turns.map((turn) => (
                    <MenuItem
                      key={turn.id}
                      onClick={() => {
                        jumpTo(turn.id)
                        close()
                      }}
                    >
                      <span className="room__index-who">
                        {turn.author === 'human' ? 'You' : `@${turn.seat}`}
                      </span>
                      <span className="room__index-gist">{gist(turn)}</span>
                    </MenuItem>
                  ))}
                </MenuSection>
              </>
            )}
          </Menu>
        ) : null}
        <Spend room={room} />
        <WriteState seats={room.seats} />
      </div>

      {error ? (
        <div className="room__error room__error--banner" role="alert">
          {error}
        </div>
      ) : null}

      <div className="room__viewport">
        <div
          className="room__transcript"
          ref={scroller}
          onScroll={(event) => {
            const el = event.currentTarget
            setAtBottom(el.scrollHeight - el.scrollTop - el.clientHeight < 120)
          }}
        >
          {turns.length === 0 ? (
            <Empty
              title={`${room.seats.map((s) => `@${s.name}`).join(', ')} seated`}
              body={
                room.seats.length > 1
                  ? 'Say something and every seat answers independently. Start with @name to ask one of them; name a seat mid-sentence to show them what it said.'
                  : 'Say something. The seat reads this folder and answers; nothing here can change a file.'
              }
              action={
                // An empty room is exactly where somebody looking for an earlier
                // conversation ends up: the toolbar mints a fresh one, so this
                // is the moment to offer the record instead of only burying it
                // in the pane menu.
                <button className="btn btn--sm" onClick={onReopen}>
                  Reopen an earlier room…
                </button>
              }
              compact
            />
          ) : null}
          {turns.map((turn) => (
            <RoomTurnView
              key={turn.id}
              turn={turn}
              live={turn.id in streaming ? (streaming[turn.id] ?? '') : null}
              actions={activity[turn.id] ?? []}
              now={now}
              folded={folded.has(turn.id)}
              onFold={() =>
                setFolded((was) => {
                  const next = new Set(was)
                  if (!next.delete(turn.id)) next.add(turn.id)
                  return next
                })
              }
              anchor={(el) => {
                if (el) anchors.current.set(turn.id, el)
                else anchors.current.delete(turn.id)
              }}
            />
          ))}
        </div>

        {!atBottom && turns.length > 0 ? (
          <button className="room__jump" onClick={jumpToLatest}>
            <ArrowDown size={12} strokeWidth={2} />
            Latest
          </button>
        ) : null}
      </div>

      {verdicts.length > 0 ? <VerdictStrip verdicts={verdicts} /> : null}

      <AudienceLine
        preview={previewAudience(draft, room.seats) ?? everyone(room)}
        remaining={room.caps.turns - room.turnsSpent}
      />

      <div className="room__composer">
        {completing.length > 0 ? (
          <div className="room__complete" role="listbox" aria-label="Seats">
            {completing.map((seat, index) => (
              <button
                key={seat.id}
                role="option"
                aria-selected={index === pick}
                className={`room__complete-item ${index === pick ? 'is-picked' : ''}`}
                // Mouse-down, not click: the textarea must not lose focus, or
                // the caret we are about to set has nowhere to go.
                onMouseDown={(event) => {
                  event.preventDefault()
                  complete(seat.name)
                }}
                onMouseEnter={() => setPick(index)}
              >
                <span className="room__complete-name">@{seat.name}</span>
                <span className="dim">{seat.config.profile || seat.config.vendor}</span>
              </button>
            ))}
          </div>
        ) : null}
        <textarea
          ref={input}
          onSelect={(event) => setCaret(event.currentTarget.selectionStart)}
          className="input room__input"
          rows={2}
          placeholder={
            busy
              ? 'Waiting on the seat…'
              : room.status === 'exhausted'
                ? 'Budget spent — raise it to continue.'
                : room.seats.length > 1
                  ? '@name asks one seat; naming a seat mid-sentence shows them its last turn.'
                  : 'Say something…'
          }
          value={draft}
          disabled={room.status === 'exhausted'}
          onChange={(event) => {
            setDraft(event.target.value)
            setCaret(event.target.selectionStart)
            setPick(0)
            setDismissed(false)
          }}
          onFocus={onFocus}
          onKeyDown={(event) => {
            // While the seat list is open it owns the keys a list owns —
            // otherwise ⏎ would send a message ending in a half-typed name,
            // which is the exact mistake the list exists to prevent.
            if (completing.length > 0) {
              if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault()
                const step = event.key === 'ArrowDown' ? 1 : completing.length - 1
                setPick((at) => (at + step) % completing.length)
                return
              }
              if (event.key === 'Enter' || event.key === 'Tab') {
                event.preventDefault()
                complete((completing[pick] as RoomSeat).name)
                return
              }
              if (event.key === 'Escape') {
                event.preventDefault()
                setDismissed(true)
                return
              }
            }
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

/**
 * A turn's index entry, cut to one line.
 *
 * An index is for scanning, and an entry that wraps to three lines is a
 * paragraph. The cut is here rather than in CSS because a clamped box and an
 * inline label do not compose, and a fixed length is easier to trust.
 */
function gist(turn: RoomTurn): string {
  const line = turnOutline(turn)
  return line.length > 80 ? `${line.slice(0, 79).trimEnd()}…` : line
}

/** What an unaddressed message does — the resting reading, before anything is typed. */
function everyone(room: Room): AudiencePreview {
  return {
    speakers: room.seats.map((seat) => seat.name),
    relaying: [],
    turns: room.seats.length,
    error: null,
  }
}

/**
 * Who will hear this, and what it will cost — before ⏎, not after.
 *
 * Addressing is the one part of a room with semantics nothing else has: a
 * leading mention changes who answers, a mid-sentence one changes what they
 * see, and an unaddressed line spends a turn per seat. All of that used to be
 * legible only in the placeholder and provable only by sending, which put the
 * explanation on the wrong side of the spend.
 *
 * Always rendered, including with an empty box, for two reasons. The line
 * appearing on the first keystroke moved the composer under the cursor. And
 * the resting state is worth stating on its own: a room whose seats you have
 * not looked at in an hour still answers as a room, and this says so.
 */
function AudienceLine({
  preview,
  remaining,
}: {
  preview: AudiencePreview
  remaining: number
}): ReactNode {
  if (preview.error) {
    return (
      <div className="room__audience room__audience--bad" role="status">
        {preview.error}
      </div>
    )
  }

  // Mid-address: the name may yet be finished, so this says nothing about cost.
  if (preview.speakers.length === 0) {
    return (
      <div className="room__audience" role="status">
        Choosing who answers…
      </div>
    )
  }

  const who =
    preview.turns > 1 && preview.speakers.length > 1
      ? `Everyone · ${preview.speakers.length} independent seats`
      : preview.speakers.map((name) => `@${name}`).join(' ')
  const over = preview.turns > remaining

  return (
    <div className="room__audience" role="status">
      <span>{who}</span>
      <span className={over ? 'room__audience--bad' : 'dim'}>
        {over
          ? `needs ${preview.turns} turn${preview.turns === 1 ? '' : 's'}, ${remaining} left`
          : `spends ${preview.turns} turn${preview.turns === 1 ? '' : 's'}`}
      </span>
      {preview.relaying.length > 0 ? (
        <span className="dim">
          sees {preview.relaying.map((name) => `@${name}`).join(', ')}
          {preview.relaying.length === 1 ? "'s last turn" : "'s last turns"}
        </span>
      ) : null}
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
        <button className="room__chip-x" aria-label={`Remove @${seat.name}`} onClick={onRemove}>
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

/** The last thing the seat's in-flight turn reported doing, for its chip. */
function latestFor(
  turns: readonly RoomTurn[],
  activity: Record<Id, string[]>,
  seat: string,
): string {
  for (let i = turns.length - 1; i >= 0; i -= 1) {
    const turn = turns[i]
    if (turn && turn.seat === seat && !turn.endedAt) {
      return activity[turn.id]?.at(-1) ?? ''
    }
  }
  return ''
}

function RoomTurnView({
  turn,
  live,
  actions,
  now,
  folded,
  onFold,
  anchor,
}: {
  turn: RoomTurn
  live: string | null
  actions: readonly string[]
  /** Ticks only while something is in flight; unused once a turn has ended. */
  now: number
  folded: boolean
  onFold: () => void
  anchor: (el: HTMLDivElement | null) => void
}): ReactNode {
  const [openActions, setOpenActions] = useState(false)
  // While streaming, the live text IS the turn: the row's own text is empty
  // until the turn ends.
  const body = live !== null && !turn.endedAt ? live : turn.text
  const waiting = live !== null && !turn.endedAt && !live
  const running = turn.author === 'agent' && !turn.endedAt
  // Live while it runs, from the record once it has finished — so a duration
  // survives a reload even though the actions behind it do not.
  const elapsed = running ? now - turn.startedAt : (turn.endedAt ?? 0) - turn.startedAt
  // Nothing in flight is ever folded: a turn still arriving is the one thing
  // in the room worth watching.
  const foldable = !running && body.length > 800

  return (
    <div className={`room__turn room__turn--${turn.author}`} ref={anchor}>
      <div className="room__author">
        {turn.author === 'human' ? 'You' : `@${turn.seat}`}
        {turn.author === 'agent' && elapsed > 0 ? (
          <span className="room__elapsed">{formatDuration(elapsed)}</span>
        ) : null}
        {foldable ? (
          <button className="room__fold-toggle" onClick={onFold} aria-expanded={!folded}>
            {folded ? 'Expand' : 'Collapse'}
          </button>
        ) : null}
      </div>

      {actions.length > 0 ? (
        <div className="room__actions">
          <button className="room__actions-head" onClick={() => setOpenActions((v) => !v)}>
            {openActions ? '▾' : '▸'} {actions.length} action
            {actions.length === 1 ? '' : 's'}
            {openActions ? '' : ` · ${actions[actions.length - 1] ?? ''}`}
          </button>
          {openActions ? (
            <ol className="room__actions-list">
              {actions.map((action, index) => (
                <li key={index}>{action}</li>
              ))}
            </ol>
          ) : null}
        </div>
      ) : null}

      {foldable && folded ? (
        <button className="room__gist" onClick={onFold} title="Expand">
          {turnOutline(turn)}
        </button>
      ) : turn.error ? (
        <div className="room__error" role="alert">
          {turn.error}
        </div>
      ) : waiting && actions.length === 0 ? (
        // Nothing read and nothing said yet: the only honest thing to show.
        <div className="room__thinking">Thinking…</div>
      ) : waiting ? null : (
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
          return <CodeBlock key={key} lang={block.lang} text={block.text} />
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

/**
 * A fenced block, folded when it is long.
 *
 * A converge answers in a contract, so every closing turn ends with a JSON
 * object whose strings run to hundreds of characters — and the parsed version
 * of exactly that is already on screen in the verdict strip. Left open it
 * buries the prose the seat wrote above it, which is the part worth reading.
 *
 * The rule is about length rather than about verdicts, because a seat pasting
 * sixty lines of source has the same problem and deserves the same answer.
 * Nothing is hidden that a click does not reveal, and the header says how much
 * there is.
 */
const FOLD_OVER_LINES = 12

function CodeBlock({ lang, text }: { lang: string; text: string }): ReactNode {
  const lines = useMemo(() => text.split('\n'), [text])
  const foldable = lines.length > FOLD_OVER_LINES
  const [open, setOpen] = useState(false)

  if (!foldable) {
    return (
      <pre className="room__code">
        <code>{text}</code>
      </pre>
    )
  }

  return (
    <div className="room__fold">
      <button className="room__fold-head" onClick={() => setOpen((v) => !v)}>
        {open ? '▾' : '▸'} {lang || 'text'} · {lines.length} lines
      </button>
      {/* Height-capped rather than line-capped while folded: lines wrap now,
          so three source lines can still be a screenful. */}
      <pre className={`room__code ${open ? '' : 'room__code--folded'}`}>
        <code>{open ? text : lines.slice(0, 3).join('\n')}</code>
      </pre>
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
          {latest.singleSource ? ' · one seat only' : ` · agreement ${latest.agreement.toFixed(2)}`}
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
