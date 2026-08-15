import { describe, expect, it } from 'vitest'
import { emptyUsage } from '@shared/usage'
import { openDatabase } from './db'
import { Repo } from './repo'

/**
 * Room persistence.
 *
 * The properties worth pinning are the ones that decide whether a transcript
 * can be trusted after a restart: everything derived stays derived, a closed
 * room keeps its words, and an empty one does not accumulate.
 */

const SEATS = [
  {
    id: 'seat-1',
    name: 'auditor',
    config: { vendor: 'claude' as const, model: 'opus', effort: 'high' as const, persona: '' },
    write: false,
  },
]
const CAPS = { turns: 40, costUsd: 0 }

function turn(over: Partial<Parameters<Repo['appendRoomTurn']>[1]> = {}) {
  return {
    id: `turn-${Math.random().toString(36).slice(2)}`,
    roomId: 'room-1',
    author: 'agent' as const,
    seat: 'auditor',
    vendor: 'claude' as const,
    profile: '',
    text: 'said something',
    usage: { ...emptyUsage(), costUsd: 1.5 },
    startedAt: 1,
    endedAt: 2,
    error: null,
    ...over,
  }
}

describe('rooms in the record', () => {
  it('round-trips a room and its turns in order', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.appendRoomTurn('room-1', turn({ id: 't1', author: 'human', seat: '', vendor: null, text: 'first' }))
    repo.appendRoomTurn('room-1', turn({ id: 't2', text: 'second' }))

    const loaded = repo.getRoom('room-1')
    expect(loaded?.cwd).toBe('/tmp/repo')
    expect(loaded?.seats).toEqual(SEATS)
    expect(loaded?.caps).toEqual(CAPS)
    expect(loaded?.turns.map((t) => t.text)).toEqual(['first', 'second'])
  })

  it('derives spend from the turns rather than storing it', () => {
    // No turnsSpent or usage column. A stored total is a second copy of the
    // turns that can disagree with them; a derived one cannot.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    // A human turn carries no usage, which is what the engine writes: saying
    // something costs nothing until a seat answers it.
    repo.appendRoomTurn(
      'room-1',
      turn({ id: 't1', author: 'human', seat: '', vendor: null, usage: emptyUsage() }),
    )
    repo.appendRoomTurn('room-1', turn({ id: 't2' }))
    repo.appendRoomTurn('room-1', turn({ id: 't3' }))

    const loaded = repo.getRoom('room-1')
    // Two agent turns; the human's is free.
    expect(loaded?.turnsSpent).toBe(2)
    expect(loaded?.usage.costUsd).toBeCloseTo(3)
  })

  it('reports exhausted when the caps are spent, and idle otherwise', () => {
    // Status is not stored either: after a restart nothing is thinking, so
    // the only question left is whether the room may spend another turn.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: { turns: 2, costUsd: 0 }, mock: false })
    repo.appendRoomTurn('room-1', turn({ id: 't1' }))
    expect(repo.getRoom('room-1')?.status).toBe('idle')

    repo.appendRoomTurn('room-1', turn({ id: 't2' }))
    expect(repo.getRoom('room-1')?.status).toBe('exhausted')
  })

  it('updates a turn in place when it ends', () => {
    // A turn is written when it starts, with no text, and filled when it
    // finishes — so the record holds the question even if the answer never
    // arrives.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.appendRoomTurn('room-1', turn({ id: 't1', text: '', endedAt: null }))
    repo.finishRoomTurn(turn({ id: 't1', text: 'the answer', endedAt: 9 }))

    const loaded = repo.getRoom('room-1')
    expect(loaded?.turns).toHaveLength(1)
    expect(loaded?.turns[0]).toMatchObject({ text: 'the answer', endedAt: 9 })
  })

  it('keeps a closed room and everything said in it', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.appendRoomTurn('room-1', turn({ id: 't1', text: 'worth keeping' }))
    repo.closeRoom('room-1')

    // Closing a pane is not a decision to destroy hours of reading.
    expect(repo.getRoom('room-1')?.turns[0]?.text).toBe('worth keeping')
    expect(repo.listRooms().map((r) => r.id)).toEqual(['room-1'])
  })

  it('forgets closed rooms that never held a turn', () => {
    // An accidentally-opened pane should not accumulate as a record. One that
    // was spoken in always survives, closed or not.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'empty', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.createRoom({ id: 'spoken', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.appendRoomTurn('spoken', turn({ id: 't1' }))
    repo.closeRoom('empty')
    repo.closeRoom('spoken')

    expect(repo.reconcileRooms()).toBe(1)
    expect(repo.listRooms().map((r) => r.id)).toEqual(['spoken'])
  })

  it('leaves an OPEN empty room alone', () => {
    // Reconciliation runs at startup, when nothing is open — but a room the
    // app is still holding must never be swept out from under it.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'empty', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    expect(repo.reconcileRooms()).toBe(0)
    expect(repo.getRoom('empty')).toBeDefined()
  })

  it('records a reseat and a new budget', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    const grown = [
      ...SEATS,
      {
        id: 'seat-2',
        name: 'sceptic',
        config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' },
        write: false,
      },
    ]
    repo.setRoomSeats('room-1', grown)
    repo.setRoomCaps('room-1', { turns: 60, costUsd: 5 })

    const loaded = repo.getRoom('room-1')
    expect(loaded?.seats).toEqual(grown)
    expect(loaded?.caps).toEqual({ turns: 60, costUsd: 5 })
  })

  it('finds what was said in a room, by seat', () => {
    // The index that arrives free: rooms are the one place a long argument
    // lives, and "where did anyone mention bimodal" is the question the
    // record could never answer.
    const repo = new Repo(openDatabase(':memory:'))
    repo.createRoom({ id: 'room-1', cwd: '/tmp/repo', seats: SEATS, caps: CAPS, mock: false })
    repo.appendRoomTurn('room-1', turn({ id: 't1', text: '', endedAt: null }))
    repo.finishRoomTurn(turn({ id: 't1', text: 'the distribution is bimodal', endedAt: 9 }))

    const hits = repo.search('bimodal')
    expect(hits.map((h) => h.kind)).toContain('room-turn')
    const hit = hits.find((h) => h.kind === 'room-turn')
    expect(hit?.scope).toBe('room-1')
    expect(hit?.title).toBe('@auditor')
  })
})
