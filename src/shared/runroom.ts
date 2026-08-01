import type { Evidence } from './domain'
import { evidenceLabel } from './evidenceLabel'
import type { RunEvent } from './journal'

/**
 * A run's story, as something a person reads.
 *
 * The journal keeps everything; a room shows what happened. Those are not the
 * same list. Checkpoints exist so an interrupted run can resume and say
 * nothing to a reader; a plan outcome is about the plan rather than this
 * milestone; spend is worth a total and not worth thirty lines. Rendering the
 * journal verbatim would produce a log, and the reason to build a room is that
 * a log is what people already cannot read.
 *
 * Pure, so what gets shown is decided somewhere testable rather than inside a
 * component.
 */

export type RunLineTone = 'plain' | 'good' | 'bad' | 'warn'

export interface RunLine {
  /** Stable across renders: the event it came from. */
  id: string
  at: number
  /** Who, in the fewest words that stay true. */
  who: string
  text: string
  tone: RunLineTone
  /** Set on findings, so a room can indent what a reviewer objected to. */
  detail?: string
}

export interface RunSummary {
  runId: string
  startedAt: number
  endedAt: number | null
  entry: string
  /** Null while the run is still in flight — which is a real state, not a gap. */
  outcome: string | null
  /** Total tokens across every turn in the attempt. */
  tokens: number
  lines: RunLine[]
}

function who(event: RunEvent): string {
  const at = event.actor.targetId ? ` on ${event.actor.targetId}` : ''
  switch (event.actor.kind) {
    case 'human':
      return 'You'
    case 'verifier':
      return `Verification${at}`
    case 'system':
      return 'Parley'
    default:
      // The profile is the identity someone chose and named; the vendor is
      // what happened to be behind it. When both exist, the name leads.
      return `${event.actor.profile ?? event.actor.vendor ?? 'agent'}${at}`
  }
}

const PHASE_TEXT: Record<string, string> = {
  executing: 'started work',
  testing: 'ran the verification command',
  reviewing: 'began reviewing',
}

/** One event as a line, or null when it is bookkeeping rather than story. */
function lineFor(event: RunEvent): RunLine | null {
  const base = { id: event.id, at: event.occurredAt, who: who(event) }

  if (event.kind === 'activity') {
    const payload = event.payload as { phase: string; text: string }
    return { ...base, text: payload.text, tone: 'plain' }
  }
  if (event.kind === 'decision') {
    // Worth a line of its own and never merged into the agent's story: the
    // whole point is that a person, not an agent, did this.
    const decision = event.payload as { kind: string }
    if (decision.kind === 'approved') {
      return { ...base, text: 'approved this run', tone: 'plain' }
    }
    if (decision.kind === 'adopted') {
      return { ...base, text: 'decided the work already in the tree counts', tone: 'plain' }
    }
    if (decision.kind === 'stopped') {
      // Not a failure. A run somebody ended and a run that fell over read the
      // same in a list of attempts, and they call for opposite responses.
      return { ...base, text: 'stopped this run', tone: 'warn' }
    }
    return null
  }
  if (event.kind === 'run.started' || event.kind === 'run.ended') return null
  if (event.kind !== 'fact') return null

  const fact = event.payload as Record<string, unknown>
  switch (fact.kind) {
    case 'phase':
      return { ...base, text: PHASE_TEXT[String(fact.phase)] ?? String(fact.phase), tone: 'plain' }

    case 'verification': {
      const result = fact.result as { command?: string; exitCode?: number; durationMs?: number } | null
      if (!result) return { ...base, text: 'no verification command to run', tone: 'warn' }
      const passed = result.exitCode === 0
      const seconds = result.durationMs ? ` in ${(result.durationMs / 1000).toFixed(1)}s` : ''
      return {
        ...base,
        text: `\`${result.command}\` exited ${result.exitCode}${seconds}`,
        tone: passed ? 'good' : 'bad',
      }
    }

    case 'mutations': {
      const results = (fact.results as Array<{ caught?: boolean; skipped?: boolean }>) ?? []
      const live = results.filter((entry) => !entry.caught && !entry.skipped).length
      return {
        ...base,
        // The strongest claim the pipeline makes, so it says which way it went
        // rather than reporting a count and leaving the reader to work it out.
        text:
          live === 0
            ? `every deliberate break was caught (${results.length})`
            : `${live} of ${results.length} deliberate breaks went undetected`,
        tone: live === 0 ? 'good' : 'bad',
      }
    }

    case 'finding': {
      // The reference goes in the LINE, not the detail: the detail is the
      // reviewer's own words and putting a path inside them would edit what
      // they said. Where it is belongs beside "raised a blocking finding".
      const where = (fact.evidence as Evidence[] | undefined) ?? []
      const at = where.length ? ` — ${where.map(evidenceLabel).join(', ')}` : ''
      return {
        ...base,
        text: `${fact.blocking ? 'raised a blocking finding' : 'left a note'}${at}`,
        detail: String(fact.text),
        tone: fact.blocking ? 'bad' : 'warn',
      }
    }

    case 'judgement':
      if (fact.passed === null) {
        return { ...base, text: 'returned no usable judgement', tone: 'warn' }
      }
      return {
        ...base,
        text: fact.passed ? 'passed the work' : 'asked for changes',
        tone: fact.passed ? 'good' : 'bad',
      }

    case 'parked':
      // Worth a line of its own, and worth the reason: this is the one ending
      // whose fix is outside the repository.
      return {
        ...base,
        text: 'parked — the verification could not run',
        detail: String(fact.reason),
        tone: 'warn',
      }

    case 'finished':
      return {
        ...base,
        text: fact.passed ? 'milestone completed' : 'milestone failed',
        tone: fact.passed ? 'good' : 'bad',
      }

    // Deliberately silent. A checkpoint is how a run stays resumable, a plan
    // outcome is about the plan, spend is a total rather than a line, and the
    // narrative is the accumulated prose the findings above already carry.
    case 'checkpoint':
    case 'planOutcome':
    case 'spend':
    case 'narrative':
      return null

    default:
      return null
  }
}

export function summariseRun(runId: string, events: readonly RunEvent[]): RunSummary {
  const started = events.find((event) => event.kind === 'run.started')
  const ended = events.find((event) => event.kind === 'run.ended')
  const tokens = events
    .filter(
      (event) => event.kind === 'fact' && (event.payload as { kind?: string }).kind === 'spend',
    )
    .reduce((total, event) => {
      const usage = (event.payload as { usage?: { inputTokens?: number; outputTokens?: number } })
        .usage
      return total + (usage?.inputTokens ?? 0) + (usage?.outputTokens ?? 0)
    }, 0)

  return {
    runId,
    startedAt: started?.occurredAt ?? events[0]?.occurredAt ?? 0,
    endedAt: ended?.occurredAt ?? null,
    entry: String((started?.payload as { entry?: string })?.entry ?? 'fresh'),
    outcome: ended ? String((ended.payload as { outcome?: string })?.outcome ?? '') : null,
    tokens,
    lines: events.map(lineFor).filter((line): line is RunLine => line !== null),
  }
}

/**
 * Every attempt, newest first.
 *
 * Newest first because the question is almost always "what happened just now";
 * the story WITHIN an attempt stays chronological, because that is the only
 * order in which it makes sense.
 */
export function summariseRuns(
  runs: ReadonlyArray<{ runId: string; events: RunEvent[] }>,
): RunSummary[] {
  return runs
    .map((run) => summariseRun(run.runId, run.events))
    .sort((a, b) => b.startedAt - a.startedAt)
}

/** How an attempt is labelled in its header. */
export function entryLabel(entry: string): string {
  switch (entry) {
    case 'resumed':
      return 'Resumed'
    case 'adopted':
      return 'Adopted'
    case 'remote':
      return 'Ran remotely'
    default:
      return 'Attempt'
  }
}
