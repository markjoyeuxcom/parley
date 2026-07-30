import type { AppEvent } from '@shared/events'
import { EXECUTABLE_PAIRS } from '@shared/execution'
import type { Envelope, EnvelopeCaps, Id, Milestone, WorkPlan } from '@shared/domain'
import type { Repo } from '@main/store/repo'
import { newId } from '@main/store/repo'
import { assertNoUnresolvedBlockingOccurrences } from './gate'
import type { RunGate } from './types'

/**
 * The unattended driver.
 *
 * It adds no new power: it loops over the SAME single-milestone machinery a
 * human drives by hand, minting each milestone's own single-use approval from
 * the envelope's one recorded authorisation. Every gate that guards an
 * attended run guards this one — the findings check, the capability
 * assertion, the deterministic verification, the independent review.
 *
 * Three rules shape it:
 *  - **Caps bound dispatch, never a running milestone.** Checked before each
 *    mint; a milestone already executing always finishes. The loops
 *    precedent, for the same reason: killing work mid-flight leaves a mess
 *    no record can explain.
 *  - **Fail-park, never fail-through.** Anything a human would have to answer
 *    ends the run and leaves the existing hold to surface it. The envelope's
 *    detail says how far it got.
 *  - **Parked is terminal.** Continuing after the cause is fixed takes a
 *    fresh envelope. Re-entering autonomy is a new authorisation.
 */

export interface EnvelopeProgress {
  milestonesRun: number
  elapsedMs: number
  /** Spend since the envelope started, not the plan's lifetime total. */
  spentUsd: number
}

/**
 * The reason this envelope may not dispatch again, or null. `maxSpendUsd` of
 * zero disables the spend cap — subscription CLIs report notional or zero
 * cost, exactly as {@link LoopCaps} documents.
 */
export function envelopeCapBreach(caps: EnvelopeCaps, at: EnvelopeProgress): string | null {
  if (at.milestonesRun >= caps.maxMilestones) {
    return `the milestone cap was reached (${caps.maxMilestones})`
  }
  if (at.elapsedMs >= caps.maxWallClockMs) {
    return `the time limit was reached (${Math.round(caps.maxWallClockMs / 60_000)} minutes)`
  }
  if (caps.maxSpendUsd > 0 && at.spentUsd >= caps.maxSpendUsd) {
    return `the spend limit was reached ($${caps.maxSpendUsd.toFixed(2)})`
  }
  return null
}

/** The next milestone an envelope may execute, or null when none can. */
export function nextExecutableMilestone(
  plan: WorkPlan,
  milestones: readonly Milestone[],
): Milestone | null {
  return (
    milestones.find((milestone) =>
      EXECUTABLE_PAIRS.some(
        ([planStatus, milestoneStatus]) =>
          plan.status === planStatus && milestone.status === milestoneStatus,
      ),
    ) ?? null
  )
}

/** The durable record of what each minted approval authorised, and whose. */
export function mintedApprovalSummary(
  envelope: Envelope,
  plan: WorkPlan,
  milestone: Milestone,
): string {
  return (
    `Unattended run ${envelope.id.slice(0, 8)}: allow ${plan.executor.vendor} to write to an ` +
    `isolated worktree of ${plan.repoPath} for milestone ${milestone.index + 1}: ${milestone.title}. ` +
    `Minted from the envelope you approved; landing remains a separate decision.`
  )
}

export interface EnvelopeDriverDeps {
  repo: Repo
  emit: (event: AppEvent) => void
  /**
   * Runs one milestone through the manager's own in-flight registry, so an
   * unattended run and a stray click can never both drive one milestone.
   */
  runMilestone: (milestoneId: Id, approvalId: Id) => Promise<Milestone>
  now?: () => number
}

export type EnvelopeEnding = 'parked' | 'exhausted' | 'finished' | 'cancelled'

/**
 * Drives one envelope to its ending and returns the settled record.
 *
 * Never throws: every exit is a recorded state. A driver that threw would
 * leave the row `running` forever, which is the one outcome an authorisation
 * record must not have.
 */
export async function driveEnvelope(
  deps: EnvelopeDriverDeps,
  envelopeId: Id,
  gate: RunGate,
): Promise<Envelope | null> {
  const now = deps.now ?? (() => Date.now())
  const settle = (state: EnvelopeEnding, detail: string): Envelope | null => {
    deps.repo.settleEnvelope(envelopeId, state, detail)
    const settled = deps.repo.getEnvelope(envelopeId)
    if (settled) deps.emit({ type: 'envelope.changed', envelope: settled })
    return settled
  }

  try {
    for (;;) {
      const envelope = deps.repo.getEnvelope(envelopeId)
      if (!envelope || envelope.state !== 'running') return envelope ?? null

      if (gate.signal.aborted) {
        return settle('cancelled', `stopped by you after ${envelope.milestonesRun} milestone${envelope.milestonesRun === 1 ? '' : 's'}`)
      }

      const plan = deps.repo.getPlan(envelope.planId)
      if (!plan) return settle('parked', 'the plan this envelope authorised no longer exists')

      const breach = envelopeCapBreach(envelope.caps, {
        milestonesRun: envelope.milestonesRun,
        elapsedMs: now() - envelope.startedAt,
        spentUsd: Math.max(0, plan.usage.costUsd - envelope.startCostUsd),
      })
      if (breach) {
        return settle(
          'exhausted',
          `${breach} after ${envelope.milestonesRun} milestone${envelope.milestonesRun === 1 ? '' : 's'}. The plan is unharmed — grant a fresh envelope to continue.`,
        )
      }

      const milestones = deps.repo.listMilestones(plan.id)
      const next = nextExecutableMilestone(plan, milestones)
      if (!next) {
        const outstanding = milestones.filter(
          (milestone) => milestone.status !== 'complete' && milestone.status !== 'rejected',
        )
        if (outstanding.length === 0) {
          return settle(
            'finished',
            `every milestone completed. The branch waits at merge-ready — landing is yours.`,
          )
        }
        return settle(
          'parked',
          `nothing further can execute: the plan is ${plan.status} and ${outstanding.length} milestone${outstanding.length === 1 ? ' is' : 's are'} not in an executable state.`,
        )
      }

      // The same gate an attended grant passes. A blocking finding filed by
      // the milestone that just ran lands here — which is precisely how an
      // unattended run parks instead of steamrolling a real objection.
      try {
        assertNoUnresolvedBlockingOccurrences(deps.repo, plan.sessionId)
      } catch (err) {
        return settle(
          'parked',
          `a blocking finding needs your disposition before milestone ${next.index + 1} can run: ${err instanceof Error ? err.message : String(err)}`,
        )
      }

      // Mint, count, run. The count is recorded BEFORE the run so a crash
      // mid-milestone can never look like a cap that was never spent.
      const approval = deps.repo.grantApproval(
        'milestone.execute',
        next.id,
        mintedApprovalSummary(envelope, plan, next),
      )
      deps.repo.bumpEnvelopeMilestones(envelopeId)

      let result: Milestone
      try {
        result = await deps.runMilestone(next.id, approval.id)
      } catch (err) {
        return settle(
          'parked',
          `milestone ${next.index + 1} could not run: ${err instanceof Error ? err.message : String(err)}`,
        )
      }

      if (result.status !== 'complete') {
        // Order matters: a milestone stopped BY the human is a cancellation,
        // not a park. Reading the result first would file the user's own Stop
        // as a failure needing their attention.
        if (gate.signal.aborted) {
          return settle(
            'cancelled',
            `stopped by you during milestone ${next.index + 1}. Its run state is preserved, so it resumes like any interrupted milestone.`,
          )
        }
        return settle(
          'parked',
          `milestone ${next.index + 1} ended ${result.status}. Its own record carries the reason, and the queue is holding it for you.`,
        )
      }
    }
  } catch (err) {
    // Nothing should reach here; if it does, the record still ends honestly.
    return settle(
      'parked',
      `the unattended run stopped unexpectedly: ${err instanceof Error ? err.message : String(err)}`,
    )
  }
}

/** The envelope record an about-to-start run writes. */
export function newEnvelope(planId: Id, caps: EnvelopeCaps, startCostUsd: number): Envelope {
  return {
    id: newId(),
    planId,
    state: 'running',
    caps,
    milestonesRun: 0,
    startCostUsd,
    detail: '',
    startedAt: Date.now(),
    endedAt: null,
  }
}
