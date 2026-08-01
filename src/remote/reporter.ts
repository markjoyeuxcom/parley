import type { Milestone } from '@shared/domain'
import { milestonePatch, type MilestoneFact, type MilestoneReporter } from '@main/orchestrator/reporter'
import { actorForFact, type RunRoles } from '@shared/journal'

/**
 * The reporter a remote run uses: facts become lines, not rows.
 *
 * Its counterpart writes to a database. This one writes JSON bodies that the
 * supervisor frames and the local side replays — through the SAME
 * milestonePatch that the store-backed reporter uses, which is the property
 * that keeps a remote run's record identical to a local one's. Two
 * implementations of "what a completed verification means" would agree right
 * up until the day they did not, and the disagreement would be invisible
 * because both sides would be confident.
 *
 * It keeps a projection for the same reason its counterpart does: the
 * execution core asks what the milestone currently looks like, and out here
 * there is nothing to ask but ourselves.
 */
export class FramingMilestoneReporter implements MilestoneReporter {
  private current: Milestone

  constructor(
    milestone: Milestone,
    private readonly write: (body: unknown) => void,
    /** Who is who on THIS machine, so attribution travels rather than being
     *  guessed at on arrival. */
    private readonly roles: RunRoles,
  ) {
    this.current = milestone
  }

  record(fact: MilestoneFact): Milestone {
    // The fact goes out FIRST, then the projection moves. If the write throws
    // — a closed pipe, a dead connection — the local record and this
    // projection are both left at the last state that was actually reported,
    // rather than this side quietly running ahead of what anyone knows.
    this.write({ type: 'fact', fact, actor: actorForFact(fact.kind, this.roles) })
    const patch = milestonePatch(fact)
    if (patch) this.current = { ...this.current, ...patch }
    return this.current
  }

  activity(phase: string, text: string): void {
    this.write({ type: 'progress', phase, text })
  }

  get milestone(): Milestone {
    return this.current
  }
}
