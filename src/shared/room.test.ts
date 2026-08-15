import { describe, expect, it } from 'vitest'
import { parseAddress, seatName, uniqueSeatName, AddressError } from './room'

/**
 * Who a message is for.
 *
 * The rules are small, and every one of them exists because the alternative
 * costs real money: an unaddressed message reaching three seats spends three
 * turns, and a mistyped name silently reaching everybody spends three more.
 */

const seats = [
  { id: 's1', name: 'claude', config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' } },
  { id: 's2', name: 'reviewer', config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' } },
]

describe('addressing', () => {
  it('sends an unaddressed message to every seat', () => {
    // Saying something to a room means saying it to the room. With one seat
    // this is also what makes an unaddressed message behave as it always has.
    expect(parseAddress('what does this repo do?', seats)).toEqual({
      seatIds: ['s1', 's2'],
      body: 'what does this repo do?',
    })
  })

  it('addresses one seat and strips the mention', () => {
    expect(parseAddress('@reviewer check that claim', seats)).toEqual({
      seatIds: ['s2'],
      body: 'check that claim',
    })
  })

  it('addresses several seats at once', () => {
    expect(parseAddress('@claude @reviewer go', seats)).toEqual({
      seatIds: ['s1', 's2'],
      body: 'go',
    })
  })

  it('treats @all as the room', () => {
    expect(parseAddress('@all go', seats)).toEqual({ seatIds: ['s1', 's2'], body: 'go' })
  })

  it('matches a name whatever its casing', () => {
    expect(parseAddress('@Reviewer go', seats).seatIds).toEqual(['s2'])
  })

  it('refuses an unknown name rather than broadcasting it', () => {
    // The expensive mistake: a typo that falls back to "everyone" spends a
    // turn per seat and reads as though the address worked.
    expect(() => parseAddress('@revewer go', seats)).toThrow(AddressError)
    expect(() => parseAddress('@revewer go', seats)).toThrow(/revewer/)
  })

  it('only reads mentions at the start, so prose keeps its @ signs', () => {
    // "email me @ work" and "the @reviewer decorator" are text. Addressing
    // stops at the first token that is not a mention.
    expect(parseAddress('ask the @reviewer about it', seats)).toEqual({
      seatIds: ['s1', 's2'],
      body: 'ask the @reviewer about it',
    })
  })

  it('refuses a message that is nothing but mentions', () => {
    expect(() => parseAddress('@reviewer', seats)).toThrow(/nothing to say/)
  })
})

describe('seat naming', () => {
  it('slugs a profile name, because an address cannot contain a space', () => {
    expect(seatName({ vendor: 'claude', model: '', effort: 'high', persona: '', profile: 'Fast reviewer' })).toBe(
      'fast-reviewer',
    )
  })

  it('falls back to the vendor when there is no profile', () => {
    expect(seatName({ vendor: 'codex', model: 'gpt-5.6-sol', effort: 'high', persona: '' })).toBe('codex')
  })

  it('numbers a name that is already taken', () => {
    expect(uniqueSeatName('claude', ['claude'])).toBe('claude-2')
    expect(uniqueSeatName('claude', ['claude', 'claude-2'])).toBe('claude-3')
    expect(uniqueSeatName('claude', [])).toBe('claude')
  })
})
