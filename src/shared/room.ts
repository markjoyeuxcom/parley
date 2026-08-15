import type { AgentConfig } from './domain'

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
