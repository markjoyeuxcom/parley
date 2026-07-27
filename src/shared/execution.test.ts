import { describe, expect, it } from 'vitest'
import type { Milestone, WorkPlan } from './domain'
import { EXECUTABLE_PAIRS, executionRefusal } from './execution'

const PLAN_STATUSES: WorkPlan['status'][] = [
  'drafting',
  'auditing',
  'correcting',
  'awaiting-clarification',
  'ready',
  'running',
  'complete',
  'failed',
  'blocked',
  'cancelled',
]

const MILESTONE_STATUSES: Milestone['status'][] = [
  'planned',
  'audited',
  'approved',
  'executing',
  'testing',
  'reviewing',
  'complete',
  'rejected',
  'failed',
]

function pair(planStatus: WorkPlan['status'], milestoneStatus: Milestone['status']): string {
  return executionRefusal(
    { status: planStatus } as WorkPlan,
    { status: milestoneStatus } as Milestone,
  )
}

describe('milestone execution gate', () => {
  it('allows exactly the approved plan and milestone status pairs', () => {
    expect(EXECUTABLE_PAIRS).toEqual([
      ['ready', 'audited'],
      ['ready', 'approved'],
      ['ready', 'failed'],
      ['failed', 'failed'],
    ])

    for (const planStatus of PLAN_STATUSES) {
      for (const milestoneStatus of MILESTONE_STATUSES) {
        const listed = EXECUTABLE_PAIRS.some(
          ([allowedPlan, allowedMilestone]) =>
            planStatus === allowedPlan && milestoneStatus === allowedMilestone,
        )
        expect(pair(planStatus, milestoneStatus) === '').toBe(listed)
      }
    }
  })

  it('keeps specific refusals for settled and in-flight milestones', () => {
    expect(pair('ready', 'complete')).toBe('this milestone has already been completed')
    expect(pair('ready', 'rejected')).toBe(
      'the auditor rejected this milestone; revise the plan rather than forcing it',
    )
    expect(pair('running', 'executing')).toBe('this milestone is already executing')
    expect(pair('running', 'testing')).toBe('this milestone is already testing')
    expect(pair('running', 'reviewing')).toBe('this milestone is already reviewing')
  })
})
