import { clampNumber, extractJson, oneOf, safeString } from '@shared/extract'
import {
  type Evidence,
  type Finding,
  type FindingPriority,
  type FindingStatus,
  type Id,
  type ScoreDimension,
  type Session,
  type Turn,
  type Verdict,
} from '@shared/domain'
import { newId } from '@main/store/repo'

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
export function similarDecision(a: string, b: string): boolean {
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

const PRIORITIES: FindingPriority[] = ['P0', 'P1', 'P2', 'P3']
const STATUSES: FindingStatus[] = ['confirmed', 'dismissed', 'unsupported']

/**
 * Parses a findings block.
 *
 * Enforces the evidence rule at the boundary rather than trusting the model:
 * a finding claiming `confirmed` with no evidence entry is downgraded to
 * `unsupported`. An agent asserting a bug it cannot point at is the exact
 * failure this review protocol exists to catch, so it is not taken on trust.
 */
export function parseFindings(text: string, sessionId: Id, raisedBy: number): Finding[] {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return []
  const raw = data['findings']
  if (!Array.isArray(raw)) return []

  const now = Date.now()
  const findings: Finding[] = []

  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const item = entry as Record<string, unknown>
    const title = safeString(item['title'], 300)
    if (!title) continue

    const evidence = parseEvidence(item['evidence'])
    let status = oneOf<FindingStatus>(item['status'], STATUSES, 'unsupported')
    if (status === 'confirmed' && evidence.length === 0) status = 'unsupported'

    findings.push({
      id: newId(),
      sessionId,
      priority: oneOf<FindingPriority>(item['priority'], PRIORITIES, 'P3'),
      status,
      title,
      detail: safeString(item['detail'], 4000),
      evidence,
      raisedBy,
      createdAt: now,
    })
  }
  return findings
}

function parseEvidence(raw: unknown): Evidence[] {
  if (!Array.isArray(raw)) return []
  const out: Evidence[] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const item = entry as Record<string, unknown>
    const path = safeString(item['path'], 500)
    if (!path) continue
    const line = item['line']
    out.push({
      path,
      line: typeof line === 'number' && line > 0 ? Math.floor(line) : null,
      symbol: safeString(item['symbol'], 200),
      excerpt: safeString(item['excerpt'], 500),
    })
  }
  return out
}

// ─── Report rendering ────────────────────────────────────────────────────────

const PRIORITY_LABEL: Record<FindingPriority, string> = {
  P0: 'P0 — breaks correctness or security now',
  P1: 'P1 — will bite under realistic conditions',
  P2: 'P2 — latent hazard',
  P3: 'P3 — worth knowing',
}

/**
 * Renders the immutable record of a session.
 *
 * This is the artifact the whole design exists to produce: not a diff, but a
 * defensible account of what was decided, by whom, with what evidence, and what
 * was still disputed at the end.
 */
export function renderReport(
  session: Session,
  turns: Turn[],
  merged: MergedVerdict,
  findings: Finding[],
): string {
  const lines: string[] = []
  const when = new Date(session.createdAt).toISOString().replace('T', ' ').slice(0, 16)

  lines.push(session.kind === 'review' ? '# Codebase review' : '# Decision record')
  lines.push('')

  // The exported file outlives the app window, so the warning has to travel with
  // it. A mock report that reads as genuine is the worst artifact this tool
  // could produce.
  if (session.mock) {
    lines.push(
      '> **NOT REAL WORK.** This record was produced by Parley\'s mock adapters. ' +
        'No model was consulted, no repository was read, and every judgement below is fabricated test data.',
    )
    lines.push('')
  }
  lines.push(`**Matter** — ${session.matter}`)
  if (session.project) lines.push(`**Project** — ${session.project}`)
  if (session.repoPath) lines.push(`**Repository** — \`${session.repoPath}\``)
  lines.push(`**Opened** — ${when} UTC`)
  // Seats render as the sides they are. When the closing sequence learns to
  // seat more than two, this line grows with it.
  lines.push(
    `**Advisors** — ` +
      session.participants
        .map((seat, index) => {
          const side = index === 0 ? 'A' : index === 1 ? 'B' : `${index + 1}`
          return `${side}: ${seat.vendor}${seat.model ? ` (${seat.model})` : ''}`
        })
        .join(' · '),
  )
  lines.push('')

  lines.push('## Decision')
  lines.push('')
  lines.push(merged.decision)
  if (merged.rationale) {
    lines.push('')
    lines.push(merged.rationale)
  }
  lines.push('')

  lines.push('## Confidence')
  lines.push('')
  lines.push(`- Recorded confidence: **${(merged.confidence * 100).toFixed(0)}%**`)
  if (merged.singleSource) {
    lines.push(
      `- Only one advisor produced a structured verdict, so this is capped and not cross-checked.`,
    )
  } else {
    lines.push(`- Advisor agreement: **${(merged.agreement * 100).toFixed(0)}%**`)
    lines.push(
      `- Confidence is the two advisors' mean credence scaled by how closely their scores agreed. Divergence lowers it deliberately.`,
    )
  }
  lines.push('')

  lines.push('## Scores')
  lines.push('')
  lines.push('| Dimension | Score |')
  lines.push('| --- | --- |')
  for (const dim of DIMENSIONS) {
    const label = dim === 'risk' ? 'risk (10 = lowest)' : dim
    lines.push(`| ${label} | ${merged.scores[dim].toFixed(1)} / 10 |`)
  }
  lines.push('')

  if (merged.dissent.trim()) {
    lines.push('## Unresolved')
    lines.push('')
    lines.push(merged.dissent.trim())
    lines.push('')
  }

  if (findings.length) {
    const confirmed = findings.filter((f) => f.status === 'confirmed')
    const dismissed = findings.filter((f) => f.status === 'dismissed')
    const unsupported = findings.filter((f) => f.status === 'unsupported')

    lines.push('## Findings')
    lines.push('')
    for (const priority of PRIORITIES) {
      const group = confirmed.filter((f) => f.priority === priority)
      if (!group.length) continue
      lines.push(`### ${PRIORITY_LABEL[priority]}`)
      lines.push('')
      for (const f of group) {
        lines.push(`**${f.title}**`)
        lines.push('')
        if (f.detail) {
          lines.push(f.detail)
          lines.push('')
        }
        for (const e of f.evidence) {
          const where = e.line ? `${e.path}:${e.line}` : e.path
          lines.push(`- \`${where}\`${e.symbol ? ` — \`${e.symbol}\`` : ''}`)
        }
        lines.push('')
      }
    }

    if (dismissed.length) {
      lines.push('### Investigated and dismissed')
      lines.push('')
      lines.push('Raised by one reviewer, checked by the other, and found not to hold.')
      lines.push('')
      for (const f of dismissed) lines.push(`- **${f.title}** — ${f.detail || 'no counter-explanation recorded'}`)
      lines.push('')
    }

    if (unsupported.length) {
      lines.push('### Raised without sufficient evidence')
      lines.push('')
      for (const f of unsupported) lines.push(`- **${f.title}** — ${f.detail || 'no detail recorded'}`)
      lines.push('')
    }
  }

  lines.push('## Exchange')
  lines.push('')
  for (const turn of turns) {
    // Seats 0 and 1 read as the sides they were; later seats read as numbers
    // until the report learns the role vocabulary.
    const speaker = turn.seat === 0 ? 'A' : turn.seat === 1 ? 'B' : `Seat ${turn.seat + 1}`
    const who = `${speaker} · ${turn.vendor}${turn.model ? ` (${turn.model})` : ''}`
    lines.push(`### ${turn.stage} — ${who}`)
    lines.push('')
    lines.push(turn.error ? `_Turn failed: ${turn.error}_` : turn.text || '_no output_')
    lines.push('')
  }

  const u = session.usage
  lines.push('---')
  lines.push('')
  lines.push(
    `Tokens: ${u.inputTokens.toLocaleString()} in (${u.cachedInputTokens.toLocaleString()} cached) · ` +
      `${u.outputTokens.toLocaleString()} out. Run through the local \`claude\`, \`codex\` and \`agy\` CLIs against your own subscriptions.`,
  )

  return lines.join('\n')
}

/** Assembles the persisted verdict row from a merge result. */
export function toVerdict(sessionId: Id, merged: MergedVerdict, report: string): Verdict {
  return {
    sessionId,
    decision: merged.decision,
    rationale: merged.rationale,
    scores: merged.scores,
    confidence: merged.confidence,
    dissent: merged.dissent,
    report,
    createdAt: Date.now(),
  }
}
