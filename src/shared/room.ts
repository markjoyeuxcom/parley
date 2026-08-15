import type { AgentConfig, Id, Room, RoomSeat } from './domain'

export class AddressError extends Error {}

/** Everyone, spelled as a name so `@all` cannot collide with a real seat. */
const EVERYONE = 'all'

/**
 * A seat's address, derived from what it is.
 *
 * A slug, because `@fast reviewer` cannot be picked out of a sentence — the
 * space ends the token, and half a name would silently address nobody.
 */
export function seatName(config: AgentConfig): string {
  const from = config.profile?.trim() || config.vendor
  const slug = from
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  return slug || config.vendor
}

/** Disambiguates a name against the room's existing ones. */
export function uniqueSeatName(base: string, taken: readonly string[]): string {
  const lower = taken.map((name) => name.toLowerCase())
  if (!lower.includes(base.toLowerCase())) return base
  for (let n = 2; ; n += 1) {
    const candidate = `${base}-${n}`
    if (!lower.includes(candidate.toLowerCase())) return candidate
  }
}

/**
 * Who a message is for, and what is left of it once the addressing is removed.
 *
 * Three rules, each of which exists because the alternative spends money:
 *
 * **Unaddressed means everyone.** Saying something to a room means saying it
 * to the room, and with a single seat it is also what keeps an ordinary
 * message behaving the way it always has.
 *
 * **Mentions are read only at the start.** Otherwise "the @reviewer
 * decorator" quietly becomes an address, and prose containing an `@` costs a
 * turn it never asked for. Reading stops at the first token that is not a
 * mention.
 *
 * **An unknown name is refused, never broadcast.** A typo that falls back to
 * everybody spends a turn per seat and looks exactly like success.
 *
 * And one rule about what they see rather than who they are:
 *
 * **Leading mentions choose who speaks; mid-sentence mentions choose what
 * they see.** Seats are independent by default — that is the whole reason to
 * have several — so a seat cannot see another's reply unless somebody says
 * so. "@auditor check the claims @sceptic just made" is the sentence a person
 * types when they want exactly that, and it now means what it looks like it
 * means. A name that matches no seat is prose here rather than an error: the
 * cost of a mid-sentence mistake is some input tokens, not a turn per seat,
 * and refusing sentences for containing an `@` would be worse than either.
 */
export function parseAddress(
  text: string,
  seats: readonly RoomSeat[],
): { seatIds: Id[]; contextSeatIds: Id[]; body: string } {
  const tokens = text.trim().split(/\s+/)
  const addressed: Id[] = []
  let everyone = false
  let at = 0

  while (at < tokens.length) {
    const token = tokens[at] as string
    if (!token.startsWith('@')) break
    const name = token.slice(1).toLowerCase()
    if (name === EVERYONE) {
      everyone = true
    } else {
      const seat = seats.find((s) => s.name.toLowerCase() === name)
      if (!seat) {
        throw new AddressError(
          `there is no seat called “${token.slice(1)}” in this room — seats are ${seats
            .map((s) => `@${s.name}`)
            .join(', ')}`,
        )
      }
      if (!addressed.includes(seat.id)) addressed.push(seat.id)
    }
    at += 1
  }

  const body = tokens.slice(at).join(' ')
  if (at > 0 && !body) throw new AddressError('that addresses a seat but leaves nothing to say')

  const seatIds = everyone || addressed.length === 0 ? seats.map((s) => s.id) : addressed
  const resolved = at > 0 ? body : text.trim()

  // Mid-sentence mentions choose what the speakers SEE. Unknown names are
  // ordinary prose here rather than an error — the asymmetry with the leading
  // position is deliberate, and stated at the top of this function's doc.
  //
  // Every mentioned seat is reported, including one that is also speaking.
  // Whether a given speaker is shown a turn depends on WHICH speaker it is —
  // a seat never needs its own words relayed back, since it is resumed and
  // already has them — and that is a per-speaker decision the caller makes.
  const contextSeatIds: Id[] = []
  for (const token of resolved.split(/\s+/)) {
    if (!token.startsWith('@')) continue
    // "@claude's point" and "@claude," are how people write; the name ends at
    // the first character that cannot be in one.
    const name = (/^@([a-z0-9-]+)/i.exec(token)?.[1] ?? '').toLowerCase()
    if (!name || name === EVERYONE) continue
    const seat = seats.find((s) => s.name.toLowerCase() === name)
    if (!seat) continue
    if (!contextSeatIds.includes(seat.id)) contextSeatIds.push(seat.id)
  }

  return { seatIds, contextSeatIds, body: resolved }
}

/**
 * The whole conversation, as a file.
 *
 * Rooms live in memory until persistence lands, so this is currently the only
 * way anything said in one survives quitting — which makes it worth more than
 * a convenience. A long room is a real artifact: hours of reading, real money,
 * and reasoning nobody wants to reproduce.
 *
 * Markdown, and the turns are pasted through untouched. Replies already ARE
 * markdown; escaping them would destroy the structure that makes the file
 * readable, and this is a transcript rather than a quoting context.
 */
export function roomTranscript(room: Room): string {
  const lines: string[] = []

  // First line, before anything else. Mock output is structurally identical
  // to real output, so a saved file that did not say so would be
  // indistinguishable from evidence — the rule exported reports already keep.
  if (room.mock) lines.push('# NOT REAL WORK — mock adapters, no model was consulted', '')

  lines.push(`# Room — ${room.cwd}`, '')
  for (const seat of room.seats) {
    const model = seat.config.model.trim()
    lines.push(`- **@${seat.name}** — ${seat.config.vendor}${model ? ` · ${model}` : ''}`)
  }
  lines.push(
    '',
    `${room.turnsSpent} of ${room.caps.turns} turns${room.usage.costUsd > 0 ? ` · $${room.usage.costUsd.toFixed(2)}` : ''}`,
    '',
    '---',
    '',
  )

  for (const turn of room.turns) {
    lines.push(`## ${turn.author === 'human' ? 'You' : `@${turn.seat}`}`, '')
    // A failed turn is kept. A silent gap would misrepresent the conversation
    // as shorter and smoother than it was.
    if (turn.error) lines.push(`> **Failed:** ${turn.error}`, '')
    if (turn.text.trim()) lines.push(turn.text.trim(), '')
  }

  return lines.join('\n')
}

/**
 * A message with another seat's words attached.
 *
 * The relayed turn comes first and is fenced by an attribution line, so the
 * seat can tell what it is being shown from what it is being asked. Without
 * the separation a long quoted turn reads as the instruction, and the actual
 * question arrives as an afterthought at the bottom.
 */
export function contextPrompt(
  relays: ReadonlyArray<{ speaker: string; text: string }>,
  body: string,
): string {
  if (relays.length === 0) return body
  const quoted = relays
    .map(({ speaker, text }) => `@${speaker} said:\n\n${text}`)
    .join('\n\n───\n\n')
  return `${quoted}\n\n───\n\n${body}`
}

/**
 * The verdict as a document.
 *
 * Dissent gets its own section and is never folded into the rationale — it is
 * the most perishable output of an adversarial room, and the one a summary
 * would smooth away first. Agreement is printed beside confidence rather than
 * only inside it, so a reader can see that two seats disagreed rather than
 * only that the number came out low.
 */
export function renderRoomVerdict(
  room: { cwd: string; seats: readonly RoomSeat[] },
  question: string,
  merged: {
    decision: string
    rationale: string
    confidence: number
    agreement: number
    singleSource: boolean
    scores: Record<string, number>
    dissent: string
  },
): string {
  const lines = [
    `# ${merged.decision}`,
    '',
    question.trim() ? `**Question:** ${question.trim()}` : '**Question:** the matter under discussion',
    `**Room:** ${room.cwd}`,
    `**Seats:** ${room.seats.map((seat) => `@${seat.name}`).join(', ')}`,
    '',
    `**Confidence:** ${merged.confidence.toFixed(2)}`,
    merged.singleSource
      ? '**Corroboration:** none — one seat produced a usable verdict, so this confidence is capped and is not a cross-checked result.'
      : `**Agreement:** ${merged.agreement.toFixed(2)} across the seats' scores.`,
    '',
    '## Rationale',
    '',
    merged.rationale || '_none given_',
    '',
    '## Scores',
    '',
    ...Object.entries(merged.scores).map(([dim, value]) => `- ${dim}: ${value}`),
    '',
  ]
  // Only when there is one. An empty "Dissent: none" reads as an assurance
  // that the seats agreed, which is a different claim entirely.
  if (merged.dissent.trim()) lines.push('## Dissent', '', merged.dissent.trim(), '')
  return lines.join('\n')
}

/**
 * Asks one seat, independently, to record what it concluded.
 *
 * No transcript travels with it: the seat is resumed and holds the whole
 * conversation already, so "the matter you have been discussing" is a
 * complete reference. That is also what keeps the seats independent at the
 * one moment independence matters most — each is answering from its own
 * reading, not from a summary somebody else wrote.
 */
export function convergePrompt(question: string, contract: string): string {
  const matter = question.trim()
  return [
    'Independently record your own verdict now.',
    matter
      ? `THE QUESTION:\n${matter}`
      : 'The question is the matter you have been discussing in this room.',
    'This is your own reading. Do not soften it toward anything another seat said, and do not inflate your confidence to signal agreement.',
    contract,
  ].join('\n\n')
}

/**
 * What a room seat is told it is.
 *
 * Deliberately thin next to the session protocols it replaces. A debate seat
 * is handed a stance to argue and a contract to answer in; a room seat is
 * handed a room. Everything that made the exchange rigid lived in those extra
 * instructions, and the whole point of a room is that the person typing sets
 * the agenda turn by turn rather than a schedule setting it up front.
 *
 * The persona rides on top, unchanged, because that is the one piece of
 * standing instruction the human actually chose.
 */
/**
 * What a seat is shown when another seat has just spoken.
 *
 * The `counterpartyLatest` mechanic from the session protocols, which is the
 * one piece of that machinery worth keeping: the seat is resumed, so it holds
 * its own side of the conversation already, and the only thing it needs
 * relayed is what somebody else said. Naming the speaker matters — a room is
 * not a two-sided exchange, and "somebody disagreed with you" is not
 * something a third seat can answer.
 */
export function relayPrompt(speaker: string, text: string): string {
  return `@${speaker} said:\n\n${text}\n\nRespond in your own voice. Disagree if you disagree — do not restate what was just said.`
}

export function roomSeatSystemPrompt(seat: AgentConfig): string {
  const base = [
    'You are one participant in an ongoing conversation with a person, in a working folder they have open.',
    'Talk normally. Answer what was asked, at whatever length it deserves, and stop.',
    'You may read files in this folder to ground what you say. You cannot change anything here — say what you would change and why, rather than pretending to have done it.',
    // The same anti-preamble rule the session prompts carry. It is not a
    // stylistic preference: an opener restating the question is pure cost in a
    // conversation whose whole value is turn latency.
    'Do not open with praise, a restatement of the question, or commentary about the exercise. Start with substance. Never describe your own output as thorough or careful — let it be judged on content.',
    'If you need something from the person to answer well, ask for it instead of guessing.',
  ].join(' ')

  const persona = seat.persona.trim()
  return persona ? `${base}\n\n${persona}` : base
}
