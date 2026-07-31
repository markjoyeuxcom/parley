import type { Id, Milestone, TestResult, Usage } from '@shared/domain'
import type { RunState } from './pipeline'

/**
 * What the execution core says happened.
 *
 * The core — execute, verify, mutate, review — is the part of the pipeline
 * that must eventually run on whichever machine holds the repository. It
 * cannot own a database, because on a remote host there is no database to own:
 * Parley's record stays on the user's machine. So the core reports FACTS, and
 * each side decides what a fact means.
 *
 * Locally a fact becomes a store write and a renderer event. Over the wire it
 * becomes one framed protocol message that the local side replays into exactly
 * the same store write, through exactly the same function below. That shared
 * definition is the point: two implementations of "what a completed
 * verification means" would drift, and the drift would be invisible until a
 * remote run recorded something a local run would not have.
 *
 * The vocabulary is deliberately about the work, not about rows. An interface
 * of updateMilestone/setStatus/insertLog would export today's persistence
 * model into a protocol and make every future schema change a wire change.
 */

export type MilestoneFact =
  /** The milestone entered a phase of work that the record shows. */
  | { kind: 'phase'; phase: 'executing' | 'testing' | 'reviewing' }
  /**
   * Where this run would resume from if it were interrupted right now, or null
   * once there is nothing left to resume. Presence is what "resumable" means,
   * so this is a fact about the run, not a cache.
   */
  | { kind: 'checkpoint'; runState: RunState | null }
  /** An agent turn completed and cost this. Recorded even when the turn errored. */
  | { kind: 'spend'; usage: Usage }
  /**
   * Parley ran the project's own verification command and observed this.
   *
   * Null when there was nothing to observe — a milestone with no test command,
   * or a run that could not get as far as one. That is a real state and must
   * be recordable: leaving a stale result in place would let the record show
   * a green suite for work that was never verified.
   */
  | { kind: 'verification'; result: TestResult | null }
  /**
   * The accumulated review narrative and what is currently outstanding. Written
   * as it accumulates rather than at the end: during a remediation round the
   * objection is exactly what is worth reading, and withholding it left the
   * record saying a review had failed and nothing about why.
   */
  | { kind: 'narrative'; note: string; blocking: string[]; notes: string[] }
  /** The reviewer reached a verdict. Null when it returned nothing usable. */
  | { kind: 'judgement'; passed: boolean | null }
  /**
   * Terminal. The milestone is over and this is how it ended.
   *
   * `judgement` and `completedAt` are optional because omitting a field and
   * setting it to null are different instructions: the byte-for-byte-unchanged
   * refusal ends a milestone without touching its completion stamp, and a
   * fact that always wrote one would quietly clear a stamp the record had a
   * reason to keep.
   */
  | {
      kind: 'finished'
      passed: boolean
      note: string
      completedAt?: number | null
      judgement?: boolean | null
    }
  /**
   * The plan's own status moved because of this milestone.
   *
   * Separate from the milestone's ending because the two are not the same
   * question — the last milestone completing makes a plan complete, while
   * any milestone failing makes a plan failed — and because working out which
   * one applies needs the plan's OTHER milestones, which is knowledge the
   * machine running this core may not have.
   */
  | { kind: 'planOutcome'; status: 'ready' | 'complete' | 'failed' }

/**
 * What a fact means for the milestone row.
 *
 * Pure and total, so the same fact produces the same record whether it was
 * observed in this process or reported from another machine. Everything that
 * is NOT a row change — emitting to the renderer, settling findings, moving
 * the plan's status — belongs to the reporter implementation, because those
 * are local consequences of a fact rather than the fact itself.
 */
export function milestonePatch(fact: MilestoneFact): Partial<Milestone> | null {
  switch (fact.kind) {
    case 'phase':
      return { status: fact.phase }
    case 'verification':
      return { testResult: fact.result }
    case 'narrative':
      return { reviewNote: fact.note, reviewBlocking: fact.blocking, reviewNotes: fact.notes }
    case 'judgement':
      return { reviewPassed: fact.passed }
    case 'finished': {
      const patch: Partial<Milestone> = {
        status: fact.passed ? 'complete' : 'failed',
        reviewNote: fact.note,
      }
      if ('completedAt' in fact) patch.completedAt = fact.completedAt ?? null
      if ('judgement' in fact) patch.reviewPassed = fact.judgement ?? null
      return patch
    }
    // None of these is a milestone column: run state has its own storage, and
    // spend and status accrue on the plan. Returning null rather than {} says
    // so — an empty patch would read as a write with nothing in it.
    case 'checkpoint':
    case 'spend':
    case 'planOutcome':
      return null
  }
}

/**
 * The core's only channel to the world outside its own execution.
 *
 * Synchronous by design. Every implementation either writes a local row or
 * writes a line to stdout, both of which are effectively immediate, and making
 * this async would put an await inside a loop whose ordering guarantees are
 * load-bearing — a checkpoint that lands after the thing it was meant to make
 * resumable is worse than no checkpoint.
 */
export interface MilestoneReporter {
  /**
   * Records a fact and returns the milestone as it now stands.
   *
   * The return keeps the core's own view current without a store read, which
   * is what lets the same code run where there is no store to read.
   */
  record(fact: MilestoneFact): Milestone
  /** Progress worth showing a human while a long stage runs. Never persisted. */
  activity(phase: string, text: string): void
  /**
   * The milestone as it now stands, projected from every fact recorded so far.
   *
   * This is what removes the last store read from the execution core. The core
   * used to re-read the row whenever it needed current state; a machine with
   * no database cannot, so the reporter — which already applies every fact —
   * keeps the projection and hands it back.
   */
  readonly milestone: Milestone
}

/**
 * The local reporter: facts become rows.
 *
 * Holds the milestone it is reporting on so the core can keep working from the
 * returned value, exactly as it did when it called updateMilestone directly.
 */
export class StoreMilestoneReporter implements MilestoneReporter {
  private current: Milestone

  constructor(
    private readonly deps: {
      updateMilestone: (id: Id, patch: Partial<Milestone>) => Milestone
      setRunState: (id: Id, state: RunState | null) => void
      addPlanUsage: (planId: Id, usage: Usage) => void
      setPlanStatus: (planId: Id, status: 'ready' | 'complete' | 'failed') => void
      emitMilestone: (milestone: Milestone) => void
      emitActivity: (phase: string, text: string) => void
    },
    milestone: Milestone,
    private readonly planId: Id,
  ) {
    this.current = milestone
  }

  record(fact: MilestoneFact): Milestone {
    if (fact.kind === 'checkpoint') {
      this.deps.setRunState(this.current.id, fact.runState)
      return this.current
    }
    if (fact.kind === 'spend') {
      this.deps.addPlanUsage(this.planId, fact.usage)
      return this.current
    }
    if (fact.kind === 'planOutcome') {
      this.deps.setPlanStatus(this.planId, fact.status)
      return this.current
    }
    const patch = milestonePatch(fact)
    if (!patch) return this.current
    this.current = this.deps.updateMilestone(this.current.id, patch)
    this.deps.emitMilestone(this.current)
    return this.current
  }

  activity(phase: string, text: string): void {
    this.deps.emitActivity(phase, text)
  }

  /** The milestone as last recorded, for callers that need it without a fact. */
  get milestone(): Milestone {
    return this.current
  }
}

/* ------------------------------------------------------------------ */
/* Facts that arrived from somewhere else                              */
/* ------------------------------------------------------------------ */

/**
 * Validates a fact that came off the wire before it can touch the record.
 *
 * Nothing that arrives from another machine reaches {@link milestonePatch}
 * without passing through here. The reason is not distrust of our own helper —
 * it is that a fact is an instruction to write the user's record, and an
 * instruction with a field of the wrong type would be applied as enthusiastically
 * as a correct one.
 *
 * The optional fields are the delicate part. `completedAt` omitted means leave
 * the stamp alone; `completedAt: null` means clear it. JSON drops undefined, so
 * the wire preserves that distinction for free — but only if this function asks
 * whether the key is PRESENT rather than whether its value is undefined. An
 * object built locally can hold an explicit undefined, and testing for
 * undefined would silently merge the two instructions.
 */
export function decodeMilestoneFact(value: unknown): MilestoneFact | null {
  if (typeof value !== 'object' || value === null) return null
  const raw = value as Record<string, unknown>
  const present = (key: string): boolean => Object.prototype.hasOwnProperty.call(raw, key)

  switch (raw.kind) {
    case 'phase':
      return raw.phase === 'executing' || raw.phase === 'testing' || raw.phase === 'reviewing'
        ? { kind: 'phase', phase: raw.phase }
        : null
    case 'checkpoint':
      // Any shape is legitimate here — run state is the driver's own private
      // vocabulary — but presence is not: an absent checkpoint and a cleared
      // one mean opposite things about whether a run can be resumed.
      return present('runState') ? { kind: 'checkpoint', runState: raw.runState as never } : null
    case 'spend':
      return typeof raw.usage === 'object' && raw.usage !== null
        ? { kind: 'spend', usage: raw.usage as never }
        : null
    case 'verification':
      if (!present('result')) return null
      if (raw.result !== null && typeof raw.result !== 'object') return null
      return { kind: 'verification', result: raw.result as never }
    case 'narrative':
      return typeof raw.note === 'string'
        ? {
            kind: 'narrative',
            note: raw.note,
            blocking: strings(raw.blocking),
            notes: strings(raw.notes),
          }
        : null
    case 'judgement':
      if (!present('passed')) return null
      if (raw.passed !== null && typeof raw.passed !== 'boolean') return null
      return { kind: 'judgement', passed: raw.passed }
    case 'finished': {
      if (typeof raw.passed !== 'boolean' || typeof raw.note !== 'string') return null
      const fact: MilestoneFact = { kind: 'finished', passed: raw.passed, note: raw.note }
      if (present('completedAt')) {
        if (raw.completedAt !== null && typeof raw.completedAt !== 'number') return null
        fact.completedAt = raw.completedAt
      }
      if (present('judgement')) {
        if (raw.judgement !== null && typeof raw.judgement !== 'boolean') return null
        fact.judgement = raw.judgement
      }
      return fact
    }
    case 'planOutcome':
      return raw.status === 'ready' || raw.status === 'complete' || raw.status === 'failed'
        ? { kind: 'planOutcome', status: raw.status }
        : null
    default:
      return null
  }
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === 'string')
    : []
}
