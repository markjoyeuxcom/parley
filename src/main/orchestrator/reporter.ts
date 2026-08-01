import type { Id, Milestone, MutationResult, TestResult, Usage } from '@shared/domain'
import type { RunState } from './pipeline'
import {
  actorForFact,
  MAX_ACTIVITY_CHARS,
  MAX_ACTIVITY_EVENTS,
  type RunActor,
  type RunEntry,
  type RunEvent,
  type RunRoles,
} from '@shared/journal'

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
   * The mutation stage finished, and this is what each deliberate break did.
   *
   * The evidence behind the strongest claim this pipeline makes — that the
   * tests would actually have caught the work being wrong — so it is recorded
   * as its own observation rather than folded into the verification result.
   */
  | { kind: 'mutations'; results: MutationResult[] }
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
   * A reviewer named something specific about the work.
   *
   * The core OBSERVES the finding; turning it into a ledger row, an
   * occurrence with provenance and a renderer event is a local consequence of
   * that observation — and one a machine with no ledger cannot perform. The
   * same fact reported from a remote run is recorded here identically, which
   * is the entire reason this is a fact and not a store call.
   */
  | {
      kind: 'finding'
      text: string
      /** Which remediation round said it, or null outside a round. */
      round: number | null
      /** Blocking findings gate the milestone; notes are recorded and do not. */
      blocking: boolean
      source: 'audit' | 'review' | 'adoption'
    }
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
    case 'mutations':
      return { mutationResults: fact.results }
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
    case 'finding':
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
  record(fact: MilestoneFact, actor?: RunActor): Milestone
  /** Progress worth showing a human while a long stage runs. */
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
  private sequence = 0
  private activityKept: number

  constructor(
    private readonly deps: {
      updateMilestone: (id: Id, patch: Partial<Milestone>) => Milestone
      setRunState: (id: Id, state: RunState | null) => void
      addPlanUsage: (planId: Id, usage: Usage) => void
      setPlanStatus: (planId: Id, status: 'ready' | 'complete' | 'failed') => void
      recordFinding: (finding: Extract<MilestoneFact, { kind: 'finding' }>, milestoneId: Id) => void
      /**
       * The journal, and the transaction that keeps it honest.
       *
       * A journal entry recording a fact whose row write failed is worse than
       * no journal, because it reads as authoritative. These two go together
       * or neither happens.
       */
      appendEvent: (event: RunEvent) => void
      transact: <T>(fn: () => T) => T
      activityKept: () => number
      emitMilestone: (milestone: Milestone) => void
      emitActivity: (phase: string, text: string) => void
    },
    milestone: Milestone,
    private readonly planId: Id,
    /** This execution ATTEMPT. A resume is a new run against the same milestone. */
    private readonly runId: Id,
    /**
     * Who the run's actors are. Supplied here rather than carried in the fact,
     * because a fact is the wire vocabulary and attribution is local context —
     * and derived per fact, because a run has more than one actor.
     */
    private readonly roles: RunRoles,
    private readonly newEventId: () => string,
  ) {
    this.current = milestone
    this.activityKept = deps.activityKept()
  }

  private event(kind: RunEvent['kind'], payload: unknown, actor?: RunActor): RunEvent {
    this.sequence += 1
    return {
      id: this.newEventId(),
      runId: this.runId,
      milestoneId: this.current.id,
      planId: this.planId,
      sequence: this.sequence,
      occurredAt: Date.now(),
      actor: actor ?? actorForFact(kind === 'fact' ? (payload as { kind: string }).kind : kind, this.roles),
      kind,
      payload,
    }
  }

  /** Opens a run's journal, so an attempt that produced nothing still says so. */
  started(entry: RunEntry): void {
    this.deps.transact(() => {
      this.deps.appendEvent(this.event('run.started', { entry }))
    })
  }

  ended(outcome: string, detail: string): void {
    this.deps.transact(() => {
      this.deps.appendEvent(this.event('run.ended', { outcome, detail }))
    })
  }

  record(fact: MilestoneFact, actor?: RunActor): Milestone {
    // The journal entry and the row write are one transaction. Re-entrant
    // `transaction` is what allows this: the dep calls below open their own,
    // and before that a nested BEGIN threw.
    //
    // `actor` is supplied only when a fact arrived from somewhere else and
    // that machine already worked out who produced it. Recomputing it here
    // would attribute a remote reviewer's finding to whatever this side
    // happens to think the roles are.
    return this.deps.transact(() => {
      this.deps.appendEvent(this.event('fact', fact, actor))
      return this.applyFact(fact)
    })
  }

  private applyFact(fact: MilestoneFact): Milestone {
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
    if (fact.kind === 'finding') {
      this.deps.recordFinding(fact, this.current.id)
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
    // Facts are never dropped; activity is unbounded by nature, so it stops
    // being kept once a run has produced enough to explain itself. The cap is
    // recorded as its own event rather than the journal quietly thinning out.
    if (this.activityKept > MAX_ACTIVITY_EVENTS) return
    this.activityKept += 1
    const capped = this.activityKept === MAX_ACTIVITY_EVENTS + 1
    this.deps.transact(() => {
      this.deps.appendEvent(
        this.event(
          'activity',
          capped
            ? { phase: 'journal', text: `further narrative from this run is not being kept (${MAX_ACTIVITY_EVENTS} lines)` }
            : { phase, text: text.slice(0, MAX_ACTIVITY_CHARS) },
          capped ? { kind: 'system' } : undefined,
        ),
      )
    })
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
    case 'mutations':
      return Array.isArray(raw.results)
        ? { kind: 'mutations', results: raw.results as MutationResult[] }
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
    case 'finding': {
      if (typeof raw.text !== 'string' || !raw.text) return null
      if (raw.source !== 'audit' && raw.source !== 'review' && raw.source !== 'adoption') return null
      if (!present('round')) return null
      if (raw.round !== null && typeof raw.round !== 'number') return null
      return {
        kind: 'finding',
        text: raw.text,
        round: raw.round,
        // Fail closed: a finding whose blocking flag did not survive the wire
        // must not silently become a note that gates nothing.
        blocking: raw.blocking === true,
        source: raw.source,
      }
    }
    default:
      return null
  }
}

function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((entry): entry is string => typeof entry === 'string')
    : []
}
