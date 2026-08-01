import { describe, expect, it } from 'vitest'
import type { RunEvent } from './journal'
import { entryLabel, summariseRun, summariseRuns } from './runroom'

/**
 * What a run's story shows, and what it leaves out.
 *
 * The journal keeps everything; a room shows what happened. Rendering the
 * journal verbatim would produce a log, and a log is what people already
 * cannot read — so the decisions about what earns a line are made here, where
 * they can be argued with.
 */

let sequence = 0
function event(kind: RunEvent['kind'], payload: unknown, over: Partial<RunEvent> = {}): RunEvent {
  sequence += 1
  return {
    id: `e${sequence}`,
    runId: 'run-1',
    milestoneId: 'm1',
    planId: 'p1',
    sequence,
    occurredAt: 1_700_000_000_000 + sequence * 1000,
    actor: { kind: 'agent', vendor: 'codex' },
    kind,
    payload,
    ...over,
  }
}

const fact = (payload: unknown, over: Partial<RunEvent> = {}): RunEvent =>
  event('fact', payload, over)

describe('what earns a line', () => {
  it('turns a verification into its command and outcome', () => {
    const { lines } = summariseRun('run-1', [
      fact(
        { kind: 'verification', result: { command: 'npm test', exitCode: 0, durationMs: 3200 } },
        { actor: { kind: 'verifier' } },
      ),
    ])
    expect(lines[0]?.text).toBe('`npm test` exited 0 in 3.2s')
    expect(lines[0]?.tone).toBe('good')
    // Verification is nobody's opinion, and the line says so rather than
    // crediting whichever agent happened to be running.
    expect(lines[0]?.who).toBe('Verification')
  })

  it('says which way mutation testing went, not just how many ran', () => {
    // The strongest claim the pipeline makes. A count leaves the reader to
    // work out whether it was good news.
    const caught = summariseRun('r', [
      fact({ kind: 'mutations', results: [{ caught: true }, { caught: true }] }),
    ])
    expect(caught.lines[0]?.text).toContain('every deliberate break was caught')
    expect(caught.lines[0]?.tone).toBe('good')

    const missed = summariseRun('r', [
      fact({ kind: 'mutations', results: [{ caught: true }, { caught: false }] }),
    ])
    expect(missed.lines[0]?.text).toBe('1 of 2 deliberate breaks went undetected')
    expect(missed.lines[0]?.tone).toBe('bad')
  })

  it('puts where a finding is beside it, and leaves its words alone', () => {
    // The reference belongs in the line, not the detail. The detail is what
    // the reviewer wrote; editing a path into it would change what they said.
    const { lines } = summariseRun('r', [
      fact(
        {
          kind: 'finding',
          text: 'the retry ceiling is not surfaced',
          evidence: [
            { path: 'src/retry.ts', line: 42, symbol: 'retry', excerpt: '' },
            { path: 'src/queue.ts', line: null, symbol: '', excerpt: '' },
          ],
          blocking: true,
        },
        { actor: { kind: 'reviewer', vendor: 'claude' } },
      ),
    ])
    expect(lines[0]?.text).toBe(
      'raised a blocking finding — src/retry.ts:42 — retry, src/queue.ts',
    )
    expect(lines[0]?.detail).toBe('the retry ceiling is not surfaced')
  })

  it('reads the same when the reviewer named nowhere', () => {
    const { lines } = summariseRun('r', [
      fact({ kind: 'finding', text: 'nothing covers the empty case', blocking: true }),
    ])
    expect(lines[0]?.text).toBe('raised a blocking finding')
  })

  it('carries a finding’s own words as detail rather than flattening them', () => {
    const { lines } = summariseRun('r', [
      fact(
        { kind: 'finding', text: 'the retry ceiling is not surfaced', blocking: true },
        { actor: { kind: 'reviewer', vendor: 'claude' } },
      ),
    ])
    expect(lines[0]?.who).toBe('claude')
    expect(lines[0]?.text).toBe('raised a blocking finding')
    expect(lines[0]?.detail).toBe('the retry ceiling is not surfaced')
    expect(lines[0]?.tone).toBe('bad')
  })

  it('names the host when the work did not happen here', () => {
    const { lines } = summariseRun('r', [
      fact({ kind: 'phase', phase: 'executing' }, { actor: { kind: 'agent', vendor: 'codex', targetId: 'build-01' } }),
    ])
    expect(lines[0]?.who).toBe('codex on build-01')
  })

  it('distinguishes no verification command from a failed one', () => {
    // "nothing ran" and "it ran and failed" are opposite situations, and a
    // room that showed both as absence would hide the first entirely.
    const { lines } = summariseRun('r', [fact({ kind: 'verification', result: null })])
    expect(lines[0]?.text).toContain('no verification command')
    expect(lines[0]?.tone).toBe('warn')
  })
})

describe('what stays out of the story', () => {
  it('drops bookkeeping that says nothing to a reader', () => {
    // A checkpoint is how a run stays resumable; a plan outcome is about the
    // plan; spend is a total; the narrative is prose the findings already
    // carry. None of them is a moment in this milestone's story.
    const { lines } = summariseRun('r', [
      fact({ kind: 'checkpoint', runState: null }),
      fact({ kind: 'planOutcome', status: 'ready' }),
      fact({ kind: 'spend', usage: { inputTokens: 10, outputTokens: 5 } }),
      fact({ kind: 'narrative', note: 'a long accumulated note', blocking: [], notes: [] }),
    ])
    expect(lines).toEqual([])
  })

  it('totals the spend it did not show', () => {
    const summary = summariseRun('r', [
      fact({ kind: 'spend', usage: { inputTokens: 1200, outputTokens: 300 } }),
      fact({ kind: 'spend', usage: { inputTokens: 400, outputTokens: 100 } }),
    ])
    expect(summary.tokens).toBe(2000)
  })

  it('keeps narrative activity, which is the only prose left', () => {
    const { lines } = summariseRun('r', [
      event('activity', { phase: 'executing', text: 'codex started on /repos/atlas' }),
    ])
    expect(lines[0]?.text).toBe('codex started on /repos/atlas')
  })
})

describe('attempts', () => {
  it('reports a run still in flight as unfinished rather than as nothing', () => {
    // A run with no ending is a real state, and the difference between "still
    // going" and "stopped without saying so" is the whole reason run.ended
    // exists.
    const open = summariseRun('r', [event('run.started', { entry: 'fresh' })])
    expect(open.outcome).toBeNull()
    expect(open.endedAt).toBeNull()

    const closed = summariseRun('r', [
      event('run.started', { entry: 'fresh' }),
      event('run.ended', { outcome: 'complete' }),
    ])
    expect(closed.outcome).toBe('complete')
    expect(closed.endedAt).not.toBeNull()
  })

  it('orders attempts newest first, and each story oldest first', () => {
    // "What happened just now" is almost always the question; within an
    // attempt, chronological is the only order that reads.
    const older = [event('run.started', { entry: 'fresh' }), fact({ kind: 'phase', phase: 'executing' })]
    const newer = [event('run.started', { entry: 'resumed' }), fact({ kind: 'phase', phase: 'testing' })]
    const summaries = summariseRuns([
      { runId: 'older', events: older },
      { runId: 'newer', events: newer },
    ])
    expect(summaries.map((run) => run.runId)).toEqual(['newer', 'older'])
    expect(summaries[0]?.entry).toBe('resumed')
    expect(summaries[0]?.lines[0]?.text).toBe('ran the verification command')
  })

  it('labels how each attempt was entered', () => {
    expect(entryLabel('fresh')).toBe('Attempt')
    expect(entryLabel('resumed')).toBe('Resumed')
    expect(entryLabel('adopted')).toBe('Adopted')
    expect(entryLabel('remote')).toBe('Ran remotely')
  })
})
