/**
 * Building a new app, as a guided sequence.
 *
 * Explicitly NOT a fourth engine and not a generator. Every stage hands the
 * user to machinery that already exists and is already gated — a debate, the
 * workspace creator, the audited pipeline, the preview, a scoped review. The
 * journey's whole job is to remember which of those belong together and what
 * sensibly comes next.
 *
 * The record therefore stores only LINKS. Where you are is derived from what
 * those links point at, the same discipline the holds queue and the in-flight
 * view use: a stored stage would be a second opinion about state the record
 * already answers, and the two would disagree the first time someone acted
 * outside the guide — which they must remain free to do.
 */

export type JourneyStage =
  /** Say what you want to build. */
  | 'brief'
  /** Put it to two model families before writing anything. */
  | 'challenge'
  /** Scaffold the project, proven green. */
  | 'foundation'
  /** Build it in audited slices. */
  | 'build'
  /** Run it and say whether it is what you wanted. */
  | 'preview'
  /** A scoped review of what now exists. */
  | 'harden'
  | 'done'

export const JOURNEY_STAGES: readonly JourneyStage[] = [
  'brief',
  'challenge',
  'foundation',
  'build',
  'preview',
  'harden',
  'done',
]

export const STAGE_TITLE: Record<JourneyStage, string> = {
  brief: 'Brief',
  challenge: 'Challenge',
  foundation: 'Foundation',
  build: 'Build',
  preview: 'Preview',
  harden: 'Harden',
  done: 'Done',
}

/** What the journey's links currently point at. Every field is observed. */
export interface JourneyProgress {
  hasBrief: boolean
  /** The challenge debate reached a verdict. */
  challengeSettled: boolean
  /** The scaffolded project's harness went green. */
  foundationReady: boolean
  /** Every milestone of the build plan completed. */
  buildComplete: boolean
  /** The human recorded a judgement on at least one completed milestone. */
  judged: boolean
  /** The hardening review finished. */
  hardened: boolean
}

/**
 * Where this journey has got to.
 *
 * Strictly ordered: a later stage cannot be "current" while an earlier one is
 * unfinished, because the guide's only value is telling you the next honest
 * step. Someone who works ahead outside the guide simply finds the stage
 * already satisfied when they come back.
 */
export function journeyStage(progress: JourneyProgress): JourneyStage {
  if (!progress.hasBrief) return 'brief'
  if (!progress.challengeSettled) return 'challenge'
  if (!progress.foundationReady) return 'foundation'
  if (!progress.buildComplete) return 'build'
  if (!progress.judged) return 'preview'
  if (!progress.hardened) return 'harden'
  return 'done'
}

/** How far along, for a progress line that does not lie about the last step. */
export function journeyStep(stage: JourneyStage): { index: number; total: number } {
  // 'done' is an ending, not a step: six stages, and being done is past them.
  const steps = JOURNEY_STAGES.filter((entry) => entry !== 'done')
  return {
    index: stage === 'done' ? steps.length : steps.indexOf(stage),
    total: steps.length,
  }
}

/** The one sentence the card shows for the stage the user is standing in. */
export const STAGE_PROMPT: Record<JourneyStage, string> = {
  brief: 'Say what you want to build, in your own words.',
  challenge:
    'Put the brief to two model families before any code exists — the cheapest moment to find out an idea does not survive contact.',
  foundation:
    'Scaffold the project. Parley proves its tests pass before any agent touches it.',
  build:
    'Plan the work against the new project and run it in audited slices, each verified and independently reviewed.',
  preview: 'Run it, look at it, and say whether it is what you wanted.',
  harden: 'Review what now exists, scoped to what you actually built.',
  done: 'The app exists, was reviewed, and you said it was what you wanted.',
}
