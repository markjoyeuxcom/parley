import type { Milestone, WorkPlan } from './domain'

export const EXECUTABLE_PAIRS = [
  ['ready', 'audited'],
  ['ready', 'approved'],
  ['ready', 'failed'],
  ['failed', 'failed'],
  // A park exists to be left. It means a human has to change something
  // outside Parley first — install the runtime, fix the command — and running
  // again is what they do next. Refusing to re-run it would make parking a
  // dead end, which is the one thing it must not be: the milestone is not
  // wrong, the machine was.
  ['ready', 'parked'],
  ['failed', 'parked'],
] as const satisfies ReadonlyArray<readonly [WorkPlan['status'], Milestone['status']]>

export function executionRefusal(plan: WorkPlan, milestone: Milestone): string {
  if (milestone.status === 'complete') {
    return 'this milestone has already been completed'
  }
  if (milestone.status === 'rejected') {
    return 'the auditor rejected this milestone; revise the plan rather than forcing it'
  }
  if (milestone.status === 'executing' || milestone.status === 'testing' || milestone.status === 'reviewing') {
    return `this milestone is already ${milestone.status}`
  }

  const executable = EXECUTABLE_PAIRS.some(
    ([planStatus, milestoneStatus]) => plan.status === planStatus && milestone.status === milestoneStatus,
  )
  return executable
    ? ''
    : `the plan is ${plan.status} and the milestone is ${milestone.status}; this status pair cannot be executed`
}
