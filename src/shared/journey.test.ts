import { describe, expect, it } from 'vitest'
import { journeyStage, journeyStep, JOURNEY_STAGES, type JourneyProgress } from './journey'

const nothing: JourneyProgress = {
  hasBrief: false,
  challengeSettled: false,
  foundationReady: false,
  buildComplete: false,
  judged: false,
  hardened: false,
}

/** The observations that satisfy each stage, in order. */
const SATISFIES: Array<keyof JourneyProgress> = [
  'hasBrief',
  'challengeSettled',
  'foundationReady',
  'buildComplete',
  'judged',
  'hardened',
]

function after(count: number): JourneyProgress {
  const progress = { ...nothing }
  for (const key of SATISFIES.slice(0, count)) progress[key] = true
  return progress
}

describe('where a journey has got to', () => {
  it('walks the stages in order as each one is satisfied', () => {
    const walked = SATISFIES.map((_, index) => journeyStage(after(index)))
    expect(walked).toEqual(['brief', 'challenge', 'foundation', 'build', 'preview', 'harden'])
    expect(journeyStage(after(SATISFIES.length))).toBe('done')
  })

  it('never skips ahead, even when later work is already finished', () => {
    // Someone who builds before briefing has not made the brief unnecessary —
    // the guide's only value is naming the next honest step.
    expect(journeyStage({ ...nothing, buildComplete: true, judged: true })).toBe('brief')
    expect(journeyStage({ ...after(2), hardened: true })).toBe('foundation')
  })

  it('counts work done outside the guide as done', () => {
    // A user who ran the debate themselves and pointed the journey at it
    // arrives at foundation, not back at challenge.
    expect(journeyStage({ ...nothing, hasBrief: true, challengeSettled: true })).toBe('foundation')
  })

  it('reports a step count that does not lie about the ending', () => {
    // Six stages; 'done' is past them rather than the seventh.
    expect(journeyStep('brief')).toEqual({ index: 0, total: 6 })
    expect(journeyStep('harden')).toEqual({ index: 5, total: 6 })
    expect(journeyStep('done')).toEqual({ index: 6, total: 6 })
    expect(JOURNEY_STAGES).toHaveLength(7)
  })
})
