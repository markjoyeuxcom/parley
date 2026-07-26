import type { ReactNode } from 'react'
import type { WorkPlan } from '@shared/domain'
import { RunActivity } from './RunActivity'

/**
 * What the pipeline is doing before there is anything to show.
 *
 * Drafting, auditing and correcting are three full agent turns, and until the
 * last of them lands there are no milestones to render — so the panel used to
 * be a spinner and one word for as long as twenty minutes. The honest question
 * that provoked this ("I had no clue this was all happening") is answered by
 * three things, in order of how quickly they answer it: which stage of a known
 * sequence we are in, how long it has been there, and what the agent is
 * actually touching right now.
 *
 * The feed is `RunActivity`, unchanged — `plan.stage` events land in the same
 * activity map keyed by plan id, so the milestone view and this one are the
 * same component looking at different subjects.
 */

/** The fixed sequence a plan walks before a human sees it. */
const STAGES: { id: WorkPlan['status']; label: string; caption: string }[] = [
  { id: 'drafting', label: 'Draft', caption: 'The planner reads the repository and proposes milestones' },
  { id: 'auditing', label: 'Audit', caption: 'The other vendor looks for what the planner assumed' },
  { id: 'correcting', label: 'Answer', caption: 'The planner replies to every finding' },
  { id: 'ready', label: 'Ready', caption: 'Yours to approve, one milestone at a time' },
]

export function PlanProgress({ plan }: { plan: WorkPlan }): ReactNode {
  const current = STAGES.findIndex((s) => s.id === plan.status)
  // 'running' and 'complete' are past the whole sequence; anything unrecognised
  // (failed, awaiting-clarification) is handled by the caller, not here.
  const activeIndex = current === -1 ? STAGES.length : current
  const live = ['drafting', 'auditing', 'correcting'].includes(plan.status)
  const active = STAGES[activeIndex]

  return (
    <div className="pipeline">
      <ol className="pipeline__stages">
        {STAGES.map((stage, index) => {
          const state = index < activeIndex ? 'done' : index === activeIndex ? 'active' : 'todo'
          return (
            <li className={`pipeline__stage pipeline__stage--${state}`} key={stage.id} title={stage.caption}>
              <span className="pipeline__marker" aria-hidden="true" />
              <span className="pipeline__label">{stage.label}</span>
            </li>
          )
        })}
      </ol>

      {live && active ? <p className="pipeline__caption">{active.caption}.</p> : null}

      <RunActivity subjectId={plan.id} live={live} />
    </div>
  )
}
