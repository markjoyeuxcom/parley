import { clampNumber, extractJson, safeString } from '@shared/extract'
import { type ScoreDimension } from '@shared/domain'

const DIMENSIONS: ScoreDimension[] = ['correctness', 'robustness', 'clarity', 'maintainability', 'risk']

export interface SeatVerdict {
  decision: string
  rationale: string
  confidence: number
  scores: Record<ScoreDimension, number>
  dissent: string
}

/** Parses one seat's structured verdict. Returns null if nothing usable was emitted. */
export function parseSeatVerdict(text: string): SeatVerdict | null {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return null

  const decision = safeString(data['decision'], 500)
  if (!decision) return null

  const rawScores = (data['scores'] ?? {}) as Record<string, unknown>
  const scores = {} as Record<ScoreDimension, number>
  for (const dim of DIMENSIONS) {
    scores[dim] = clampNumber(rawScores[dim], 0, 10, 5)
  }

  return {
    decision,
    rationale: safeString(data['rationale'], 2000),
    confidence: clampNumber(data['confidence'], 0, 1, 0.5),
    scores,
    dissent: safeString(data['dissent'], 2000),
  }
}

export interface MergedVerdict extends SeatVerdict {
  /** 0–1. How closely the seats' scores align. 1 means identical. */
  agreement: number
  /** True when only one seat produced a usable verdict. */
  singleSource: boolean
}

/** The dissent label a seat wears: the classic sides for 0 and 1, then numbers. */
function seatName(seat: number): string {
  return seat === 0 ? 'Side A' : seat === 1 ? 'Side B' : `Seat ${seat + 1}`
}

/**
 * Merges independently-produced verdicts, one slot per seat.
 *
 * The rule that matters: **disagreement lowers recorded confidence.** Advisors
 * who each claim 0.9 confidence but score the option ten points apart have not
 * produced a confident answer, and reporting 0.9 would be a lie about how much
 * the exercise actually established. Agreement is measured on the scores,
 * which are numeric and comparable, rather than on the prose — as the mean
 * score distance across every usable pair, which for two seats is exactly the
 * delta the two-sided merge always measured. The verdict tests hold the
 * two-seat outputs to that reduction.
 *
 * Dissent is concatenated rather than resolved. A losing seat's objection is
 * the most perishable and most useful output of an adversarial session, so it
 * is preserved verbatim, labelled with the seat that holds it.
 */
export function mergeVerdicts(verdicts: ReadonlyArray<SeatVerdict | null>): MergedVerdict | null {
  const usable = verdicts
    .map((verdict, seat) => (verdict ? { seat, verdict } : null))
    .filter((entry): entry is { seat: number; verdict: SeatVerdict } => entry !== null)
  if (usable.length === 0) return null

  if (usable.length === 1) {
    const only = usable[0]!.verdict
    return {
      ...only,
      // One seat's unchallenged opinion is not a cross-checked verdict. Cap it
      // so a single-source result never presents as strongly as a corroborated
      // one, however sure that seat claims to be.
      confidence: Math.min(only.confidence, 0.6),
      agreement: 0,
      singleSource: true,
    }
  }

  const scores = {} as Record<ScoreDimension, number>
  for (const dim of DIMENSIONS) {
    let sum = 0
    for (const { verdict } of usable) sum += verdict.scores[dim]
    scores[dim] = Math.round((sum / usable.length) * 10) / 10
  }

  let totalDelta = 0
  let pairs = 0
  for (let i = 0; i < usable.length; i += 1) {
    for (let j = i + 1; j < usable.length; j += 1) {
      pairs += 1
      for (const dim of DIMENSIONS) {
        totalDelta += Math.abs(usable[i]!.verdict.scores[dim] - usable[j]!.verdict.scores[dim])
      }
    }
  }
  const meanDelta = totalDelta / (pairs * DIMENSIONS.length)
  const agreement = Math.max(0, 1 - meanDelta / 10)

  // The most confident seat supplies the wording; every seat supplies the
  // number. Ties go to the earliest seat, as they always did.
  let lead = usable[0]!
  for (const entry of usable) {
    if (entry.verdict.confidence > lead.verdict.confidence) lead = entry
  }
  const meanConfidence =
    usable.reduce((sum, { verdict }) => sum + verdict.confidence, 0) / usable.length
  const confidence = Math.round(meanConfidence * agreement * 100) / 100

  const dissentParts: string[] = []
  for (const { seat, verdict } of usable) {
    if (verdict.dissent.trim()) dissentParts.push(`${seatName(seat)}: ${verdict.dissent.trim()}`)
  }

  let diverging = false
  for (let i = 0; i < usable.length && !diverging; i += 1) {
    for (let j = i + 1; j < usable.length; j += 1) {
      if (!similarDecision(usable[i]!.verdict.decision, usable[j]!.verdict.decision)) {
        diverging = true
        break
      }
    }
  }
  if (diverging) {
    // The classic pair keeps its exact historical wording — that sentence is
    // in every existing report and pinned by the tests. More seats get the
    // general form, every conclusion quoted.
    const classicPair = usable.length === 2 && usable[0]!.seat === 0 && usable[1]!.seat === 1
    dissentParts.unshift(
      classicPair
        ? `The two advisors did not reach the same decision. A concluded: "${usable[0]!.verdict.decision}" B concluded: "${usable[1]!.verdict.decision}"`
        : [
            `The advisors did not all reach the same decision.`,
            ...usable.map(
              ({ seat, verdict }) => `${seatName(seat)} concluded: "${verdict.decision}"`,
            ),
          ].join(' '),
    )
  }

  return {
    decision: lead.verdict.decision,
    rationale: lead.verdict.rationale,
    confidence,
    scores,
    dissent: dissentParts.join('\n\n'),
    agreement: Math.round(agreement * 100) / 100,
    singleSource: false,
  }
}

/**
 * Cheap lexical check for "did these two say roughly the same thing".
 *
 * Deliberately crude: it exists to decide whether to *flag* a divergence for the
 * reader, not to adjudicate one. A false flag costs a line of text; a missed
 * divergence hides the most important thing in the report.
 */
/**
 * Words that reverse a sentence, and are all too short to survive the filter
 * below. "Adopt the queue" and "Do not adopt the queue" normalise to the same
 * two words, so the one word carrying the entire disagreement was the one
 * being discarded — and two seats saying opposite things scored as complete
 * agreement, with no dissent recorded, in a report somebody later reads as
 * settled.
 */
const NEGATION = /\b(?:not|never|cannot|can't|won't|don't|doesn't|didn't|shouldn't|no|nor|none)\b/

/** Whether a sentence turns its own claim around. */
function negates(text: string): boolean {
  return NEGATION.test(text.toLowerCase())
}

export function similarDecision(a: string, b: string): boolean {
  // Checked before the vocabulary overlap, and decisive on its own: two
  // sentences built from the same words mean opposite things when one of them
  // negates. Erring toward flagging is this function's stated bias — a false
  // flag costs a line of text.
  if (negates(a) !== negates(b)) return false

  const norm = (s: string): Set<string> =>
    new Set(
      s
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter((w) => w.length > 3),
    )
  const setA = norm(a)
  const setB = norm(b)
  if (setA.size === 0 || setB.size === 0) return true
  let shared = 0
  for (const word of setA) if (setB.has(word)) shared += 1
  return shared / Math.min(setA.size, setB.size) >= 0.4
}

// ─── Findings ────────────────────────────────────────────────────────────────
