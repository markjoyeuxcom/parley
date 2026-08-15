import { describe, expect, it, vi } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage } from '@shared/usage'
import type { AgentRegistry, RunRequest, RunResult } from '@main/agents'
import { RoomManager, RoomError } from './manager'

/**
 * Free-flow rooms.
 *
 * The properties worth pinning are the ones that separate a room from the
 * scheduled exchange it replaces: nobody decides who speaks next but the
 * person typing, the seat is resumed rather than replayed, and a failed turn
 * leaves the room usable instead of wedged.
 */

function fakeRegistry(
  reply: (req: RunRequest) => Partial<RunResult>,
): { registry: AgentRegistry; seen: RunRequest[] } {
  const seen: RunRequest[] = []
  const registry = {
    mock: false,
    get: () => ({
      vendor: 'claude' as const,
      binary: 'claude',
      run: async (req: RunRequest): Promise<RunResult> => {
        seen.push(req)
        const answer = reply(req)
        // A tool use lands before any text, which is the shape that matters:
        // it is the silence before the first delta that a room has to fill.
        req.onActivity?.('Read src/index.ts')
        // Deltas arrive before the result, exactly as a real adapter streams.
        answer.text?.split(' ').forEach((word) => req.onDelta?.(`${word} `))
        return {
          text: '',
          usage: emptyUsage(),
          resumeId: null,
          exitCode: 0,
          error: null,
          ...answer,
        }
      },
      probe: async () => ({ vendor: 'claude' as const, present: true, authenticated: true, detail: '' }),
    }),
  } as unknown as AgentRegistry
  return { registry, seen }
}

const SEAT = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }

describe('rooms', () => {
  it('records the human turn before the seat has said anything', async () => {
    // The human is a seat, so what they said is on the record the moment they
    // said it — not retroactively, once a reply arrives to attach it to.
    const events: AppEvent[] = []
    const { registry } = fakeRegistry(() => ({ text: 'An answer.' }))
    const rooms = new RoomManager({ registry, emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', SEAT)
    const sending = rooms.send(room.id, 'A question.')

    expect(rooms.get(room.id)?.turns[0]).toMatchObject({ author: 'human', text: 'A question.' })
    expect(rooms.get(room.id)?.status).toBe('thinking')
    await sending
    expect(rooms.get(room.id)?.status).toBe('idle')
  })

  it('streams the reply and closes the turn with the whole text', async () => {
    const events: AppEvent[] = []
    const { registry } = fakeRegistry(() => ({ text: 'one two three' }))
    const rooms = new RoomManager({ registry, emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'go')

    const deltas = events.filter((e) => e.type === 'room.turn.delta')
    expect(deltas.length).toBe(3)
    // The ended turn carries the complete text, so a client that missed a
    // delta is corrected rather than left holding a partial reply.
    const ended = events.filter((e) => e.type === 'room.turn.ended')
    expect(ended).toHaveLength(1)
    expect(rooms.get(room.id)?.turns.at(-1)).toMatchObject({
      author: 'agent',
      text: 'one two three',
      error: null,
    })
  })

  it('reports what the seat is doing, without recording it', async () => {
    // The gap against a TUI pane: a terminal shows tool calls scrolling past,
    // so you can see work happening. A room saw nothing between "Thinking…"
    // and prose. Activity is ephemeral like plan.activity — it says what is
    // happening NOW, and the durable account of the turn is the turn.
    const events: AppEvent[] = []
    const { registry } = fakeRegistry(() => ({ text: 'done' }))
    const rooms = new RoomManager({ registry, emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'go')

    expect(events.filter((e) => e.type === 'room.activity')).toEqual([
      { type: 'room.activity', roomId: room.id, text: 'Read src/index.ts' },
    ])
    // Nothing about it reaches the record.
    const turn = rooms.get(room.id)?.turns.at(-1)
    expect(turn?.text).toBe('done')
    expect(JSON.stringify(turn)).not.toContain('src/index.ts')
  })

  it('resumes the seat instead of replaying the transcript', async () => {
    // The cost property the whole design rests on: turn two sends only the new
    // message, because the CLI still holds the conversation.
    const { registry, seen } = fakeRegistry((req) => ({
      text: 'ok',
      resumeId: req.resumeId ? 'thread-1' : 'thread-1',
    }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'first')
    await rooms.send(room.id, 'second')

    expect(seen[0]?.resumeId ?? null).toBe(null)
    expect(seen[1]?.resumeId).toBe('thread-1')
    // Turn two's prompt is the new message alone — no transcript replay.
    expect(seen[1]?.prompt).toContain('second')
    expect(seen[1]?.prompt).not.toContain('first')
  })

  it('reads the folder it sits in, and never writes', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'go')

    expect(seen[0]?.cwd).toBe('/tmp/repo')
    // m5 adds the per-seat write opt-in. Until then a room seat is read-only,
    // and this is the assertion that has to be deliberately changed to move it.
    expect(seen[0]?.capability).toBe('read')
  })

  it('refuses a tool-less vendor as a seat, at open and at reseat', () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    expect(() => rooms.open('/tmp/repo', { ...SEAT, vendor: 'agy' })).toThrow(/tool-less/)

    const room = rooms.open('/tmp/repo', SEAT)
    expect(() => rooms.setSeat(room.id, { ...SEAT, vendor: 'agy' })).toThrow(/tool-less/)
  })

  it('keeps a failed turn on the record and leaves the room usable', async () => {
    // A wedged room would be the worst failure here: the transcript is the
    // work, and losing access to it because one turn errored is unrecoverable
    // in a way the error itself is not.
    const { registry } = fakeRegistry(() => ({ error: 'the CLI exited 1', exitCode: 1 }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'go')

    expect(rooms.get(room.id)?.turns.at(-1)?.error).toBe('the CLI exited 1')
    expect(rooms.get(room.id)?.status).toBe('idle')
  })

  it('refuses a second send while a seat is mid-turn', async () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    const first = rooms.send(room.id, 'one')
    await expect(rooms.send(room.id, 'two')).rejects.toThrow(RoomError)
    await first
    // And accepts one again the moment the seat is free.
    await expect(rooms.send(room.id, 'two')).resolves.toBeDefined()
  })

  it('accumulates usage across turns', async () => {
    const { registry } = fakeRegistry(() => ({
      text: 'ok',
      usage: { ...emptyUsage(), inputTokens: 10, outputTokens: 5, costUsd: 0.5 },
    }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    await rooms.send(room.id, 'one')
    await rooms.send(room.id, 'two')

    expect(rooms.get(room.id)?.usage.inputTokens).toBe(20)
    expect(rooms.get(room.id)?.usage.costUsd).toBe(1)
  })

  it('stop abandons the in-flight turn without killing the room', async () => {
    const aborted = vi.fn()
    const registry = {
      mock: false,
      get: () => ({
        run: (req: RunRequest) =>
          new Promise<RunResult>((resolve) => {
            req.signal?.addEventListener('abort', () => {
              aborted()
              resolve({ text: '', usage: emptyUsage(), resumeId: null, exitCode: -1, error: 'Stopped.' })
            })
          }),
      }),
    } as unknown as AgentRegistry
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    const sending = rooms.send(room.id, 'go')
    rooms.stop(room.id)
    await sending

    expect(aborted).toHaveBeenCalled()
    expect(rooms.get(room.id)?.status).toBe('idle')
    expect(rooms.get(room.id)?.turns).toHaveLength(2)
  })

  it('closing forgets the room; a send afterwards is refused, not ignored', async () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, emit: () => {} })

    const room = rooms.open('/tmp/repo', SEAT)
    rooms.close(room.id)

    expect(rooms.get(room.id)).toBeUndefined()
    await expect(rooms.send(room.id, 'go')).rejects.toThrow(/no such room/)
  })
})
