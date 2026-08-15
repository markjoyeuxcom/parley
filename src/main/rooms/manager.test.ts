import { describe, expect, it, vi } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage } from '@shared/usage'
import type { AgentRegistry, RunRequest, RunResult } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import { RoomManager, RoomError } from './manager'

/** A real store — rooms write through, so a fake would test nothing. */
const store = (): Repo => new Repo(openDatabase(':memory:'))

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
const CAPS = { turns: 100, costUsd: 0 }

describe('rooms', () => {
  it('records the human turn before the seat has said anything', async () => {
    // The human is a seat, so what they said is on the record the moment they
    // said it — not retroactively, once a reply arrives to attach it to.
    const events: AppEvent[] = []
    const { registry } = fakeRegistry(() => ({ text: 'An answer.' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    const sending = rooms.send(room.id, 'A question.')

    expect(rooms.get(room.id)?.turns[0]).toMatchObject({ author: 'human', text: 'A question.' })
    expect(rooms.get(room.id)?.status).toBe('thinking')
    await sending
    expect(rooms.get(room.id)?.status).toBe('idle')
  })

  it('streams the reply and closes the turn with the whole text', async () => {
    const events: AppEvent[] = []
    const { registry } = fakeRegistry(() => ({ text: 'one two three' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'go')

    const deltas = events.filter((e) => e.type === 'room.turn.delta')
    expect(deltas.length).toBe(3)
    // The ended turn carries the complete text, so a client that missed a
    // delta is corrected rather than left holding a partial reply. Two of
    // them: the human's message is announced the same way, so the pane never
    // has to draw an optimistic copy of what somebody typed.
    const ended = events.filter((e) => e.type === 'room.turn.ended')
    expect(ended).toHaveLength(2)
    expect(ended.map((e) => e.turn.author)).toEqual(['human', 'agent'])
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
    const rooms = new RoomManager({ registry, repo: store(), emit: (event) => events.push(event) })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'go')

    expect(events.filter((e) => e.type === 'room.activity')).toEqual([
      { type: 'room.activity', roomId: room.id, seat: 'claude', text: 'Read src/index.ts' },
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
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
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
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'go')

    expect(seen[0]?.cwd).toBe('/tmp/repo')
    // A seat with its write flag off dispatches at read, and every seat a
    // room opens with has it off. Turning it on is a separate, deliberate act.
    expect(seen[0]?.capability).toBe('read')
  })

  it('refuses a tool-less vendor as a seat, at open and at reseat', () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    expect(() => rooms.open('/tmp/repo', [{ ...SEAT, vendor: 'agy' }], CAPS)).toThrow(/tool-less/)

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    expect(() => rooms.setSeat(room.id, { ...SEAT, vendor: 'agy' })).toThrow(/tool-less/)
  })

  it('keeps a failed turn on the record and leaves the room usable', async () => {
    // A wedged room would be the worst failure here: the transcript is the
    // work, and losing access to it because one turn errored is unrecoverable
    // in a way the error itself is not.
    const { registry } = fakeRegistry(() => ({ error: 'the CLI exited 1', exitCode: 1 }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'go')

    expect(rooms.get(room.id)?.turns.at(-1)?.error).toBe('the CLI exited 1')
    expect(rooms.get(room.id)?.status).toBe('idle')
  })

  it('refuses a second send while a seat is mid-turn', async () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
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
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
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
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    const sending = rooms.send(room.id, 'go')
    rooms.stop(room.id)
    await sending

    expect(aborted).toHaveBeenCalled()
    expect(rooms.get(room.id)?.status).toBe('idle')
    expect(rooms.get(room.id)?.turns).toHaveLength(2)
  })

  it('names its seats, disambiguating a repeat', () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Fast reviewer' }, SEAT], CAPS)
    expect(room.seats.map((s) => s.name)).toEqual(['claude', 'fast-reviewer', 'claude-2'])
  })

  it('answers an unaddressed message from every seat, independently', async () => {
    // The property the manual two-room workflow proved worth having: seats
    // answering the same question must not see each other's replies, or the
    // second one is agreeing with the first rather than answering.
    const { registry, seen } = fakeRegistry(() => ({ text: 'an answer' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Reviewer' }], CAPS)
    const turns = await rooms.send(room.id, 'what does this do?')

    expect(turns).toHaveLength(2)
    expect(seen).toHaveLength(2)
    // Both got the human's message and nothing else.
    expect(seen[0]?.prompt).toBe('what does this do?')
    expect(seen[1]?.prompt).toBe('what does this do?')
    expect(rooms.get(room.id)?.turnsSpent).toBe(2)
  })

  it('sends an addressed message to that seat alone', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Reviewer' }], CAPS)
    const turns = await rooms.send(room.id, '@reviewer check that')

    expect(turns).toHaveLength(1)
    expect(turns[0]?.seat).toBe('reviewer')
    expect(seen).toHaveLength(1)
    // The mention is stripped: the seat knows it was addressed.
    expect(seen[0]?.prompt).toBe('check that')
  })

  it('refuses a misaddressed message without spending anything', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await expect(rooms.send(room.id, '@nobody go')).rejects.toThrow(/no seat called/)
    expect(seen).toHaveLength(0)
    // And nothing was recorded, so the transcript does not grow a turn that
    // never happened.
    expect(rooms.get(room.id)?.turns).toHaveLength(0)
  })

  it('relays a named seat’s last turn to whoever was addressed', async () => {
    // The failure this fixes, verbatim from a real room: "@auditor check the
    // claims @sceptic just made" reached the auditor with no idea who sceptic
    // was, and it correctly answered that it could not see them.
    let n = 0
    const { registry, seen } = fakeRegistry(() => ({ text: `answer ${(n += 1)}` }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open(
      '/tmp/repo',
      [{ ...SEAT, profile: 'Sceptic' }, { ...SEAT, profile: 'Auditor' }],
      CAPS,
    )
    await rooms.send(room.id, '@sceptic open')
    await rooms.send(room.id, '@auditor check what @sceptic just said')

    expect(seen).toHaveLength(2)
    // The auditor is shown the sceptic's words, attributed, ahead of the ask.
    expect(seen[1]?.prompt).toContain('@sceptic said')
    expect(seen[1]?.prompt).toContain('answer 1')
    expect(seen[1]?.prompt).toContain('check what @sceptic just said')
    // And it is one turn, not two: relaying is context, not a dispatch.
    expect(rooms.get(room.id)?.turnsSpent).toBe(2)
  })

  it('never relays a seat its own words back', async () => {
    // Every seat but the mentioned one is shown the turn; the mentioned seat
    // is resumed and already has it, so paying to send it again would be
    // paying twice for the same sentence.
    let n = 0
    const { registry, seen } = fakeRegistry(() => ({ text: `answer ${(n += 1)}` }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open(
      '/tmp/repo',
      [{ ...SEAT, profile: 'Sceptic' }, { ...SEAT, profile: 'Auditor' }],
      CAPS,
    )
    await rooms.send(room.id, '@sceptic open')
    await rooms.send(room.id, 'what do you both make of @sceptic’s point?')

    const [, sceptic, auditor] = seen
    expect(sceptic?.prompt).not.toContain('@sceptic said')
    expect(auditor?.prompt).toContain('@sceptic said')
  })

  it('refuses to reference a seat that has not spoken', async () => {
    // Sending anyway would reproduce the exact bug — a seat replying "I
    // cannot see what you mean" — except now it would look like the feature
    // had worked.
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open(
      '/tmp/repo',
      [{ ...SEAT, profile: 'Sceptic' }, { ...SEAT, profile: 'Auditor' }],
      CAPS,
    )
    await expect(rooms.send(room.id, '@auditor check what @sceptic said')).rejects.toThrow(
      /has not said anything yet/,
    )
    expect(seen).toHaveLength(0)
    expect(rooms.get(room.id)?.turns).toHaveLength(0)
  })

  it('advances seat to seat, each hearing the one before', async () => {
    // Round-robin: the mode where seats actually talk to each other rather
    // than answering the same question in parallel.
    let n = 0
    const { registry, seen } = fakeRegistry(() => ({ text: `reply ${(n += 1)}` }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Reviewer' }], CAPS)
    await rooms.send(room.id, '@claude open')
    await rooms.advance(room.id, 2)

    // The unit is turns, not rounds: two more seats speak, in order.
    // One opening turn, then two more: reviewer, then claude again.
    const spoken = rooms.get(room.id)?.turns.filter((t) => t.author === 'agent') ?? []
    expect(spoken.map((t) => t.seat)).toEqual(['claude', 'reviewer', 'claude'])
    // Each advance turn relays the previous seat's text, naming the speaker.
    expect(seen[1]?.prompt).toContain('@claude said')
    expect(seen[1]?.prompt).toContain('reply 1')
    expect(seen[2]?.prompt).toContain('@reviewer said')
  })

  it('stops at the turn cap and says exhausted, never done', async () => {
    // Invariant 7, kept in substance: the bound is checked before dispatch,
    // reaching it is exhausted rather than success, and a seat never sees it.
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], { turns: 2, costUsd: 0 })
    await rooms.send(room.id, 'one')
    await rooms.send(room.id, 'two')

    expect(rooms.get(room.id)?.status).toBe('exhausted')
    await expect(rooms.send(room.id, 'three')).rejects.toThrow(/turn budget/)
    expect(seen).toHaveLength(2)
    // No prompt ever mentioned the budget — an agent that can see a cap can
    // argue about it.
    for (const req of seen) {
      expect(`${req.systemPrompt}${req.prompt}`).not.toMatch(/budget|cap|turns? remaining/i)
    }
  })

  it('refuses a send that cannot be answered by every seat it addresses', async () => {
    // Two seats and one turn left is not "answer with one of them": which
    // seat got dropped would be arbitrary, and the answer would look complete.
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Reviewer' }], {
      turns: 1,
      costUsd: 0,
    })
    await expect(rooms.send(room.id, 'go')).rejects.toThrow(/turn budget/)
    expect(seen).toHaveLength(0)
  })

  it('stops at the cost ceiling when one is set', async () => {
    const { registry } = fakeRegistry(() => ({
      text: 'ok',
      usage: { ...emptyUsage(), costUsd: 0.4 },
    }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], { turns: 100, costUsd: 1 })
    await rooms.send(room.id, 'one')
    await rooms.send(room.id, 'two')
    await rooms.send(room.id, 'three')

    expect(rooms.get(room.id)?.status).toBe('exhausted')
    await expect(rooms.send(room.id, 'four')).rejects.toThrow(/cost/)
  })

  it('raising the budget revives an exhausted room', async () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], { turns: 1, costUsd: 0 })
    await rooms.send(room.id, 'one')
    expect(rooms.get(room.id)?.status).toBe('exhausted')

    rooms.setCaps(room.id, { turns: 4, costUsd: 0 })
    expect(rooms.get(room.id)?.status).toBe('idle')
    await expect(rooms.send(room.id, 'two')).resolves.toBeDefined()
  })

  it('advance stops on the budget rather than running to its round count', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Reviewer' }], {
      turns: 3,
      costUsd: 0,
    })
    await rooms.send(room.id, '@claude open')
    // Asks for six more turns; the budget allows two.
    await rooms.advance(room.id, 6)

    expect(seen).toHaveLength(3)
    expect(rooms.get(room.id)?.status).toBe('exhausted')
  })

  it('dispatches a write seat at write, and everyone else at read', async () => {
    // The one escalation in the arc. Capability is DERIVED from the seat's
    // flag rather than passed alongside it, so the two cannot disagree.
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Writer' }], CAPS)
    const writer = room.seats[1]!
    rooms.setSeatWrite(room.id, writer.id, true)
    await rooms.send(room.id, 'go')

    expect(seen.map((r) => r.capability)).toEqual(['read', 'write'])
  })

  it('turns write off again, and refuses while a seat is mid-turn', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    const only = room.seats[0]!
    rooms.setSeatWrite(room.id, only.id, true)
    // Mid-turn is exactly when a flip would be ambiguous: the dispatch it
    // would change has already happened.
    const sending = rooms.send(room.id, 'go')
    expect(() => rooms.setSeatWrite(room.id, only.id, false)).toThrow(/mid-turn/)
    await sending

    rooms.setSeatWrite(room.id, only.id, false)
    await rooms.send(room.id, 'again')
    expect(seen.map((r) => r.capability)).toEqual(['write', 'read'])
  })

  it('converges: every seat scores independently, and the merge is recorded', async () => {
    // The one thing genuinely lost to free flow, kept as an action rather
    // than a schedule. Seats do not see each other's verdicts — that is the
    // whole reason a merged confidence means anything.
    const verdicts = [
      '```json\n{"decision":"ship it","rationale":"a","confidence":0.9,"scores":{"correctness":9,"robustness":9,"clarity":9,"maintainability":9,"risk":9},"dissent":""}\n```',
      '```json\n{"decision":"do not ship","rationale":"b","confidence":0.9,"scores":{"correctness":2,"robustness":2,"clarity":2,"maintainability":2,"risk":2},"dissent":"the gate is unsound"}\n```',
    ]
    // Keyed on the prompt rather than a call counter: the opening message goes
    // to every seat too, and counting calls fed the canned verdicts to the
    // discussion instead of the closing.
    let v = 0
    const { registry, seen } = fakeRegistry((req) =>
      req.prompt.includes('record your own verdict')
        ? { text: verdicts[v++] ?? verdicts[0] }
        : { text: 'discussion' },
    )
    const repo = store()
    const rooms = new RoomManager({ registry, repo, emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Sceptic' }], CAPS)
    await rooms.send(room.id, 'open')
    const verdict = await rooms.converge(room.id, 'should we ship?')

    expect(verdict).not.toBeNull()
    // Seven points apart on every dimension: two seats each claiming 0.9 have
    // not produced a confident answer, and the record must not say they did.
    expect(verdict!.confidence).toBeLessThan(0.9)
    expect(verdict!.agreement).toBeLessThan(0.5)
    expect(verdict!.singleSource).toBe(false)
    // The losing side's objection survives verbatim.
    expect(verdict!.dissent).toContain('the gate is unsound')
    expect(repo.listRoomVerdicts(room.id)).toHaveLength(1)

    // Neither seat was shown the other's verdict.
    const closing = seen.slice(-2)
    for (const req of closing) {
      expect(req.prompt).not.toContain('ship it')
      expect(req.prompt).not.toContain('do not ship')
    }
  })

  it('keeps every verdict, so a room can change its mind on the record', async () => {
    const { registry } = fakeRegistry(() => ({
      text: '```json\n{"decision":"d","rationale":"r","confidence":0.5,"scores":{"correctness":5,"robustness":5,"clarity":5,"maintainability":5,"risk":5},"dissent":""}\n```',
    }))
    const repo = store()
    const rooms = new RoomManager({ registry, repo, emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'open')
    await rooms.converge(room.id, 'first question')
    await rooms.converge(room.id, 'second question')

    // Newest first, and the earlier one is still there — what they thought
    // before is the more interesting half.
    expect(repo.listRoomVerdicts(room.id).map((v) => v.question)).toEqual([
      'second question',
      'first question',
    ])
  })

  it('caps a lone seat’s confidence rather than reporting it as corroborated', async () => {
    const { registry } = fakeRegistry(() => ({
      text: '```json\n{"decision":"d","rationale":"r","confidence":0.95,"scores":{"correctness":9,"robustness":9,"clarity":9,"maintainability":9,"risk":9},"dissent":""}\n```',
    }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'open')
    const verdict = await rooms.converge(room.id, 'q')

    expect(verdict!.singleSource).toBe(true)
    expect(verdict!.confidence).toBeLessThanOrEqual(0.6)
  })

  it('refuses to converge on a budget it cannot pay, and on an empty room', async () => {
    const { registry, seen } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const empty = rooms.open('/tmp/repo', [SEAT], CAPS)
    await expect(rooms.converge(empty.id, 'q')).rejects.toThrow(/nothing has been said/)

    const room = rooms.open('/tmp/repo', [SEAT, { ...SEAT, profile: 'Two' }], { turns: 2, costUsd: 0 })
    await rooms.send(room.id, 'open')
    // Two turns spent, two seats to hear from, two allowed: no room to close.
    await expect(rooms.converge(room.id, 'q')).rejects.toThrow(/turn budget/)
    expect(seen).toHaveLength(2)
  })

  it('records nothing when no seat produces a usable verdict', async () => {
    // A converge that yielded prose instead of a contract has established
    // nothing, and a row saying otherwise would be the worst kind of record.
    const { registry } = fakeRegistry(() => ({ text: 'I would rather not answer in JSON.' }))
    const repo = store()
    const rooms = new RoomManager({ registry, repo, emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'open')
    expect(await rooms.converge(room.id, 'q')).toBeNull()
    expect(repo.listRoomVerdicts(room.id)).toHaveLength(0)
  })

  it('closing lets go of the room without losing it', async () => {
    // Closing a pane is not a decision to destroy hours of reading. The live
    // room goes; the transcript stays readable, and a send is refused until
    // somebody deliberately reopens it.
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'worth keeping')
    rooms.close(room.id)

    await expect(rooms.send(room.id, 'go')).rejects.toThrow(/no such room/)
    expect(rooms.get(room.id)?.turns[0]?.text).toBe('worth keeping')
  })

  it('reopens a room with its transcript and no seat running', async () => {
    // The saved-layout rule applied to seats: nothing begins against a
    // subscription without being asked for. And the vendor thread does NOT
    // come back — a stale resume id fails at the next turn in a way that
    // looks like the seat breaking rather than the thread being gone.
    const { registry, seen } = fakeRegistry(() => ({ text: 'an answer', resumeId: 'thread-1' }))
    const repo = store()
    const rooms = new RoomManager({ registry, repo, emit: () => {} })

    const room = rooms.open('/tmp/repo', [SEAT], CAPS)
    await rooms.send(room.id, 'first')
    rooms.close(room.id)

    // A fresh manager over the same record: what a restart looks like.
    const after = new RoomManager({ registry, repo, emit: () => {} })
    const reopened = after.reopen(room.id)
    expect(reopened.turns.map((t) => t.text)).toEqual(['first', 'an answer'])
    expect(reopened.status).toBe('idle')
    expect(reopened.turnsSpent).toBe(1)

    await after.send(room.id, 'second')
    expect(seen[1]?.resumeId ?? null).toBe(null)
  })

  it('refuses to reopen something that was never recorded', async () => {
    const { registry } = fakeRegistry(() => ({ text: 'ok' }))
    const rooms = new RoomManager({ registry, repo: store(), emit: () => {} })
    expect(() => rooms.reopen('room-nope')).toThrow(/no such room/)
  })
})
