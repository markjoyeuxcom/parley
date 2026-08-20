import { describe, expect, it } from 'vitest'
import { emptyUsage } from './usage'
import {
  matchSeats,
  mentionAt,
  parseAddress,
  previewAudience,
  roomSeatSystemPrompt,
  roomTranscript,
  turnOutline,
  seatName,
  uniqueSeatName,
  AddressError,
} from './room'

/**
 * Who a message is for.
 *
 * The rules are small, and every one of them exists because the alternative
 * costs real money: an unaddressed message reaching three seats spends three
 * turns, and a mistyped name silently reaching everybody spends three more.
 */

const seat = (id: string, name: string, over = {}) => ({
  id,
  name,
  config: {
    vendor: 'claude' as const,
    model: '',
    effort: 'high' as const,
    persona: '',
  },
  write: false,
  ...over,
})
const seats = [seat('s1', 'claude'), seat('s2', 'reviewer')]

describe('addressing', () => {
  it('sends an unaddressed message to every seat', () => {
    // Saying something to a room means saying it to the room. With one seat
    // this is also what makes an unaddressed message behave as it always has.
    expect(parseAddress('what does this repo do?', seats)).toEqual({
      seatIds: ['s1', 's2'],
      contextSeatIds: [],
      body: 'what does this repo do?',
    })
  })

  it('addresses one seat and strips the mention', () => {
    expect(parseAddress('@reviewer check that claim', seats)).toEqual({
      seatIds: ['s2'],
      contextSeatIds: [],
      body: 'check that claim',
    })
  })

  it('addresses several seats at once', () => {
    expect(parseAddress('@claude @reviewer go', seats)).toEqual({
      seatIds: ['s1', 's2'],
      contextSeatIds: [],
      body: 'go',
    })
  })

  it('treats @all as the room', () => {
    expect(parseAddress('@all go', seats)).toEqual({
      seatIds: ['s1', 's2'],
      contextSeatIds: [],
      body: 'go',
    })
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
    // Addressing stops at the first token that is not a mention: a mention
    // further in never changes WHO answers.
    expect(parseAddress('ask the @reviewer about it', seats)).toEqual({
      seatIds: ['s1', 's2'],
      contextSeatIds: ['s2'],
      body: 'ask the @reviewer about it',
    })
  })

  it('reads a mention mid-sentence as whose turn to include', () => {
    // Leading mentions choose who speaks; mid-sentence mentions choose what
    // they see. The sentence somebody naturally types — "@reviewer check the
    // claims @claude just made" — then means what it looks like it means.
    expect(parseAddress('@reviewer check the claims @claude just made', seats)).toEqual({
      seatIds: ['s2'],
      contextSeatIds: ['s1'],
      body: 'check the claims @claude just made',
    })
  })

  it('ignores an unknown name mid-sentence rather than refusing', () => {
    // The asymmetry is deliberate. A bad name at the START changes who
    // answers and costs a turn per seat, so it is refused. Mid-sentence it is
    // ordinary prose — an email address, a decorator, a handle — and refusing
    // would make the room reject sentences for containing an @.
    expect(parseAddress('mail me @ work about the @revewer thing', seats)).toEqual({
      seatIds: ['s1', 's2'],
      contextSeatIds: [],
      body: 'mail me @ work about the @revewer thing',
    })
  })

  it('reports a mentioned seat even when it is the one speaking', () => {
    // Parsing says what was mentioned; who is shown what is decided per
    // speaker, because a seat never needs its own words relayed back and the
    // other seats in the same message do. Collapsing that here would mean
    // "@all what about @sceptic's point" silently starved everybody else.
    expect(parseAddress('@reviewer expand on what @reviewer said', seats).contextSeatIds).toEqual([
      's2',
    ])
  })

  it('strips punctuation from a mid-sentence mention', () => {
    // "@claude's point" and "@claude," are how people actually write.
    expect(parseAddress('@reviewer is @claude, right?', seats).contextSeatIds).toEqual(['s1'])
    expect(parseAddress("@reviewer take @claude's point", seats).contextSeatIds).toEqual(['s1'])
  })

  it('refuses a message that is nothing but mentions', () => {
    expect(() => parseAddress('@reviewer', seats)).toThrow(/nothing to say/)
  })
})

describe('audience preview', () => {
  it('says who answers and what it spends', () => {
    expect(previewAudience('what does this do?', seats)).toEqual({
      speakers: ['claude', 'reviewer'],
      relaying: [],
      turns: 2,
      error: null,
    })
    expect(previewAudience('@reviewer check that', seats)).toMatchObject({
      speakers: ['reviewer'],
      turns: 1,
    })
  })

  it('names the seat whose turn will be attached', () => {
    expect(previewAudience('@reviewer check what @claude said', seats)).toMatchObject({
      speakers: ['reviewer'],
      relaying: ['claude'],
      turns: 1,
    })
  })

  it('stays quiet while the message is still only an address', () => {
    // Typing "@rev" is not a mistake yet, and an app that objects after every
    // keystroke is worse than one that waits.
    expect(previewAudience('@rev', seats)).toEqual({
      speakers: [],
      relaying: [],
      turns: 0,
      error: null,
    })
    expect(previewAudience('@reviewer', seats)?.error).toBeNull()
    expect(previewAudience('   ', seats)).toBeNull()
  })

  it('surfaces the refusal once there is something to send', () => {
    expect(previewAudience('@revewer go', seats)?.error).toMatch(/no seat called/)
    expect(previewAudience('@revewer go', seats)?.turns).toBe(0)
  })
})

describe('mention completion', () => {
  it('finds the mention the caret is inside', () => {
    expect(mentionAt('@rev', 4)).toEqual({ query: 'rev', from: 0 })
    expect(mentionAt('@', 1)).toEqual({ query: '', from: 0 })
  })

  it('completes a mention mid-sentence, since those relay a turn', () => {
    expect(mentionAt('@reviewer check what @cla said', 25)).toEqual({
      query: 'cla',
      from: 21,
    })
  })

  it('stops offering once the caret leaves the token', () => {
    // Having typed past a finished mention is not a request to complete it.
    expect(mentionAt('@reviewer go', 12)).toBeNull()
    expect(mentionAt('@reviewer ', 10)).toBeNull()
  })

  it('ignores an @ that is not starting a token', () => {
    // Otherwise "mark@example.com" opens a list of seats.
    expect(mentionAt('mail me at mark@example', 23)).toBeNull()
  })

  it('offers prefix matches before substring ones', () => {
    const pool = [seat('s1', 'code-reviewer'), seat('s2', 'reviewer')]
    expect(matchSeats('rev', pool).map((s) => s.name)).toEqual(['reviewer', 'code-reviewer'])
    expect(matchSeats('', pool)).toHaveLength(2)
    expect(matchSeats('zzz', pool)).toHaveLength(0)
  })
})

describe('transcript', () => {
  const room = {
    id: 'room-1',
    cwd: '/Users/me/Personal/prax',
    seats: [
      seat('s1', 'auditor', {
        config: {
          vendor: 'claude' as const,
          model: 'opus',
          effort: 'high' as const,
          persona: '',
          profile: 'Auditor',
        },
      }),
      seat('s2', 'sceptic'),
    ],
    caps: { turns: 40, costUsd: 0 },
    turnsSpent: 2,
    status: 'idle' as const,
    usage: {
      inputTokens: 10,
      cachedInputTokens: 0,
      outputTokens: 5,
      reasoningTokens: 0,
      costUsd: 10.47,
    },
    mock: false,
    createdAt: 1_700_000_000_000,
    turns: [
      {
        id: 't1',
        roomId: 'room-1',
        author: 'human' as const,
        seat: '',
        vendor: null,
        profile: '',
        text: 'Is the decomposition right?',
        usage: emptyUsage(),
        startedAt: 1,
        endedAt: 1,
        error: null,
      },
      {
        id: 't2',
        roomId: 'room-1',
        author: 'agent' as const,
        seat: 'auditor',
        vendor: 'claude' as const,
        profile: 'Auditor',
        text: '## Verdict\nMeasurement-first.',
        usage: emptyUsage(),
        startedAt: 2,
        endedAt: 3,
        error: null,
      },
      {
        id: 't3',
        roomId: 'room-1',
        author: 'agent' as const,
        seat: 'sceptic',
        vendor: 'claude' as const,
        profile: '',
        text: '',
        usage: emptyUsage(),
        startedAt: 4,
        endedAt: 5,
        error: 'the CLI exited 1',
      },
    ],
  }

  it('writes every turn under who said it, keeping the markdown intact', () => {
    const out = roomTranscript(room)
    expect(out).toContain('## You')
    expect(out).toContain('Is the decomposition right?')
    expect(out).toContain('## @auditor')
    // The reply is already markdown; a transcript that re-escaped it would
    // destroy the thing being saved.
    expect(out).toContain('## Verdict\nMeasurement-first.')
  })

  it('keeps a failed turn instead of dropping it', () => {
    // A silent gap would misrepresent the conversation as shorter and
    // smoother than it was.
    expect(roomTranscript(room)).toContain('the CLI exited 1')
  })

  it('records the seats and what the room spent', () => {
    const out = roomTranscript(room)
    expect(out).toContain('@auditor')
    expect(out).toContain('claude · opus')
    expect(out).toContain('2 of 40 turns')
    expect(out).toContain('$10.47')
  })

  it('marks a mock room as not real work, first thing', () => {
    // The same rule the exported reports carry: mock output is structurally
    // identical to real output, so a saved file that did not say so would be
    // indistinguishable from evidence.
    const out = roomTranscript({ ...room, mock: true })
    expect(out.split('\n')[0]).toContain('NOT REAL WORK')
  })
})

describe('turn outline', () => {
  const turn = (over: Record<string, unknown>) => ({
    id: 't',
    roomId: 'r',
    author: 'agent' as const,
    seat: 'claude',
    vendor: 'claude' as const,
    profile: '',
    text: '',
    usage: emptyUsage(),
    startedAt: 1,
    endedAt: 2,
    error: null,
    ...over,
  })

  it('takes the first line of prose, not the markup around it', () => {
    expect(turnOutline(turn({ text: '## Verdict\n\nMeasurement first.' }))).toBe('Verdict')
    expect(turnOutline(turn({ text: '- **the gate** is unsound' }))).toBe('the gate is unsound')
  })

  it('looks past a code fence, since "```ts" identifies nothing', () => {
    expect(turnOutline(turn({ text: '```ts\nconst x = 1\n```\n\nThat is the bug.' }))).toBe(
      'That is the bug.',
    )
  })

  it('falls back to the first line when the whole reply is code', () => {
    expect(turnOutline(turn({ text: '```ts\nconst x = 1\n```' }))).toBe('const x = 1')
  })

  it('shows the failure for a turn that failed, and says so for an empty one', () => {
    expect(turnOutline(turn({ text: '', error: 'the CLI exited 1' }))).toBe('the CLI exited 1')
    expect(turnOutline(turn({ text: '   ' }))).toBe('no reply')
  })
})

describe('seat naming', () => {
  it('slugs a profile name, because an address cannot contain a space', () => {
    expect(
      seatName({
        vendor: 'claude',
        model: '',
        effort: 'high',
        persona: '',
        profile: 'Fast reviewer',
      }),
    ).toBe('fast-reviewer')
  })

  it('falls back to the vendor when there is no profile', () => {
    expect(
      seatName({
        vendor: 'codex',
        model: 'gpt-5.6-sol',
        effort: 'high',
        persona: '',
      }),
    ).toBe('codex')
  })

  it('numbers a name that is already taken', () => {
    expect(uniqueSeatName('claude', ['claude'])).toBe('claude-2')
    expect(uniqueSeatName('claude', ['claude', 'claude-2'])).toBe('claude-3')
    expect(uniqueSeatName('claude', [])).toBe('claude')
  })
})

describe('a seat is told what it may actually do', () => {
  const config = { vendor: 'claude', model: 'opus', persona: '' } as never

  it('tells a read-only seat it cannot change files', () => {
    expect(roomSeatSystemPrompt(config)).toContain('cannot change anything here')
  })

  it('tells a write-authorised seat to make the change', () => {
    // The toggle granted a write sandbox and the prompt still said no, so the
    // model refused or described an edit instead of making one — which reads
    // as the feature being broken rather than the prompt contradicting it.
    const prompt = roomSeatSystemPrompt(config, true)
    expect(prompt).not.toContain('cannot change anything here')
    expect(prompt).toContain('authorised this seat to write')
  })
})

