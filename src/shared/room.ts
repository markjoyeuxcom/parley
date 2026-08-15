import type { AgentConfig, Id, RoomSeat } from './domain'

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
 */
export function parseAddress(
  text: string,
  seats: readonly RoomSeat[],
): { seatIds: Id[]; body: string } {
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
  return { seatIds, body: at > 0 ? body : text.trim() }
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
