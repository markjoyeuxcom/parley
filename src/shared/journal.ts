/**
 * The durable record of what happened during a run.
 *
 * Facts already exist as a vocabulary — the execution core states them and
 * each side decides what they mean. What has been missing is durability: a
 * fact was applied to a row and dropped, so a run's story survived only as the
 * end state it left behind. "The tests passed" was recoverable; "the reviewer
 * blocked it, the executor addressed it, and the second attempt passed" was
 * not.
 *
 * A journal keeps the story. It is what a Run Room reads, what a resume would
 * replay, what per-agent cost is summed from, and what search indexes. None of
 * it needs new semantics — only somewhere for the existing ones to live.
 *
 * Kept free of dependencies on purpose: the renderer displays these and the
 * remote bundle's reporter builds them, so this file must stay importable by
 * both without dragging anything behind it.
 */

/** Who did the thing. Not who is to blame — several actors are not people. */
export interface RunActor {
  kind: 'human' | 'agent' | 'verifier' | 'reviewer' | 'system'
  /**
   * The adapter behind an agent or reviewer, when there is one. A placeholder
   * for the agent profile this will become: a profile id belongs here, and
   * everything reading this field will keep working when one arrives.
   */
  vendor?: string
  /** The execution host, when the actor was not this machine. */
  targetId?: string
}

export type RunEventKind =
  /** A run began. Carries how it was entered — fresh, resumed, adopted. */
  | 'run.started'
  /** One thing the execution core observed. Payload is a MilestoneFact. */
  | 'fact'
  /** Narrative shown while a long stage ran. */
  | 'activity'
  /** A run ended, however it ended. */
  | 'run.ended'

export interface RunEvent {
  id: string
  /**
   * One execution ATTEMPT, not one milestone.
   *
   * A resume spends a fresh approval and is a new run; a milestone
   * accumulates several over its life. Grouping by attempt is what lets a Run
   * Room show "this was tried three times" instead of flattening three
   * stories into one.
   */
  runId: string
  milestoneId: string
  planId: string
  /** Monotonic from 1 within a run. Ordering is the whole point of a journal. */
  sequence: number
  occurredAt: number
  actor: RunActor
  kind: RunEventKind
  payload: unknown
}

/** How a run was entered, recorded on its opening event. */
export type RunEntry = 'fresh' | 'resumed' | 'adopted' | 'remote'

/**
 * Narrative is truncated on the way in, not on the way out.
 *
 * A long-running milestone emits activity steadily, and an agent that decides
 * to narrate a file listing can produce a very long line. Storing it whole
 * would make a run's journal the largest thing in the database to no benefit —
 * nothing reads past the first line of one of these.
 */
export const MAX_ACTIVITY_CHARS = 500

/**
 * The ceiling on activity events kept for a single run.
 *
 * Facts are never dropped: there are tens of them and each one changed the
 * record. Activity is unbounded by nature, so it stops being recorded once a
 * run has produced enough to explain itself, and the journal says so rather
 * than silently thinning out.
 */
export const MAX_ACTIVITY_EVENTS = 400

/**
 * Who a given fact should be attributed to.
 *
 * A run has more than one actor. The executor writes the code; the reviewer
 * names the findings; verification is a deterministic command that is nobody's
 * opinion. Attributing all of it to whoever happened to be driving the loop
 * would make "which agent raised this finding" unanswerable, which is one of
 * the questions a journal exists to answer.
 *
 * Pure, and shared by both reporters, for the same reason milestonePatch is:
 * two implementations of "who did this" would agree until they did not, and a
 * remote run would start attributing work differently from a local one.
 */
export interface RunRoles {
  executor: string
  reviewer: string
  /** The host, when the run is not on this machine. */
  targetId?: string
}

export function actorForFact(kind: string, roles: RunRoles): RunActor {
  switch (kind) {
    case 'finding':
    case 'judgement':
    case 'narrative':
      // The reviewer's output. A finding is the clearest case: it is an
      // opinion, and whose opinion it was is the point of recording it.
      return { kind: 'reviewer', vendor: roles.reviewer, targetId: roles.targetId }
    case 'verification':
    case 'mutations':
      // Neither agent's claim. Parley ran the command and observed the result,
      // which is exactly why these carry more weight than anything an agent
      // says about its own work.
      return { kind: 'verifier', targetId: roles.targetId }
    case 'planOutcome':
      // Derived from the plan's other milestones by whoever holds the record.
      return { kind: 'system' }
    default:
      return { kind: 'agent', vendor: roles.executor, targetId: roles.targetId }
  }
}
