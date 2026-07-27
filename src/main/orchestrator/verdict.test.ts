import { describe, expect, it } from 'vitest'
import { mergeVerdicts, parseFindings, parseSeatVerdict, similarDecision, type SeatVerdict } from './verdict'

function side(overrides: Partial<SeatVerdict> = {}): SeatVerdict {
  return {
    decision: 'Adopt the narrower option',
    rationale: 'reversible',
    confidence: 0.8,
    scores: { correctness: 7, robustness: 7, clarity: 7, maintainability: 7, risk: 7 },
    dissent: '',
    ...overrides,
  }
}

describe('parseSeatVerdict', () => {
  it('reads a well-formed verdict block', () => {
    const text = [
      'My reasoning.',
      '```json',
      JSON.stringify({
        decision: 'Adopt the queue',
        rationale: 'because throughput',
        confidence: 0.7,
        scores: { correctness: 8, robustness: 6, clarity: 7, maintainability: 5, risk: 4 },
        dissent: 'migration cost understated',
      }),
      '```',
    ].join('\n')

    const parsed = parseSeatVerdict(text)
    expect(parsed?.decision).toBe('Adopt the queue')
    expect(parsed?.confidence).toBe(0.7)
    expect(parsed?.scores.correctness).toBe(8)
    expect(parsed?.dissent).toBe('migration cost understated')
  })

  it('returns null when there is no decision to record', () => {
    expect(parseSeatVerdict('just prose')).toBeNull()
    expect(parseSeatVerdict('```json\n{"rationale":"no decision field"}\n```')).toBeNull()
  })

  it('defaults missing scores to the midpoint rather than zero', () => {
    // Zero would read as "scored badly", which is a different claim from
    // "did not answer".
    const parsed = parseSeatVerdict('```json\n{"decision":"do it","scores":{"correctness":9}}\n```')
    expect(parsed?.scores.correctness).toBe(9)
    expect(parsed?.scores.robustness).toBe(5)
  })

  it('clamps out-of-range values instead of trusting them', () => {
    const parsed = parseSeatVerdict(
      '```json\n{"decision":"x","confidence":9,"scores":{"correctness":99,"risk":-4}}\n```',
    )
    expect(parsed?.confidence).toBe(1)
    expect(parsed?.scores.correctness).toBe(10)
    expect(parsed?.scores.risk).toBe(0)
  })
})

describe('mergeVerdicts', () => {
  it('averages the scores of two agreeing sides', () => {
    const merged = mergeVerdicts([
      side({ scores: { correctness: 8, robustness: 6, clarity: 7, maintainability: 7, risk: 7 } }),
      side({ scores: { correctness: 6, robustness: 8, clarity: 7, maintainability: 7, risk: 7 } }),
    ])
    expect(merged?.scores.correctness).toBe(7)
    expect(merged?.scores.robustness).toBe(7)
  })

  it('lowers confidence when the two sides diverge', () => {
    // The point of the whole design: two confident advisors who disagree have
    // not produced a confident answer.
    const agreeing = mergeVerdicts([side({ confidence: 0.9 }), side({ confidence: 0.9 })])
    const diverging = mergeVerdicts([
      side({ confidence: 0.9, scores: { correctness: 10, robustness: 10, clarity: 10, maintainability: 10, risk: 10 } }),
      side({ confidence: 0.9, scores: { correctness: 1, robustness: 1, clarity: 1, maintainability: 1, risk: 1 } }),
    ])

    expect(agreeing?.confidence).toBeCloseTo(0.9, 1)
    expect(diverging?.confidence).toBeLessThan(0.3)
    expect(diverging?.agreement).toBeLessThan(0.2)
  })

  it('takes the wording from the more confident side', () => {
    const merged = mergeVerdicts([
      side({ decision: 'quiet option', confidence: 0.4 }),
      side({ decision: 'confident option', confidence: 0.95 }),
    ])
    expect(merged?.decision).toBe('confident option')
  })

  it('preserves both sides dissent rather than resolving it', () => {
    const merged = mergeVerdicts([
      side({ dissent: 'A still objects to the schema' }),
      side({ dissent: 'B still objects to the rollout' }),
    ])
    expect(merged?.dissent).toContain('A still objects to the schema')
    expect(merged?.dissent).toContain('B still objects to the rollout')
  })

  it('flags a material disagreement about the decision itself', () => {
    const merged = mergeVerdicts([
      side({ decision: 'Adopt the message queue immediately' }),
      side({ decision: 'Keep everything synchronous and revisit next quarter' }),
    ])
    expect(merged?.dissent).toMatch(/did not reach the same decision/i)
  })

  it('caps a single-source verdict so it cannot present as corroborated', () => {
    const merged = mergeVerdicts([side({ confidence: 0.99 }), null])
    expect(merged?.singleSource).toBe(true)
    expect(merged?.confidence).toBeLessThanOrEqual(0.6)
  })

  it('returns null only when neither side answered', () => {
    expect(mergeVerdicts([null, null])).toBeNull()
    expect(mergeVerdicts([null, side()])).not.toBeNull()
  })

  it('merges three seats, labelling every dissent by its seat', () => {
    const merged = mergeVerdicts([
      side({ dissent: 'the schema worry' }),
      side({ dissent: 'the rollout worry' }),
      side({ dissent: 'the cost worry' }),
    ])
    expect(merged?.dissent).toContain('Side A: the schema worry')
    expect(merged?.dissent).toContain('Side B: the rollout worry')
    expect(merged?.dissent).toContain('Seat 3: the cost worry')
    expect(merged?.singleSource).toBe(false)
  })

  it('lets one dissenting seat lower a three-way confidence', () => {
    // Two agreeing seats and one far apart: the disagreement is real and the
    // recorded confidence must say so, exactly as it always did for a pair.
    const united = mergeVerdicts([side({ confidence: 0.9 }), side({ confidence: 0.9 }), side({ confidence: 0.9 })])
    const contested = mergeVerdicts([
      side({ confidence: 0.9 }),
      side({ confidence: 0.9 }),
      side({
        confidence: 0.9,
        scores: { correctness: 1, robustness: 1, clarity: 1, maintainability: 1, risk: 1 },
      }),
    ])
    expect(united?.confidence).toBeCloseTo(0.9, 1)
    expect(contested?.confidence).toBeLessThan(united?.confidence ?? 0)
    expect(contested?.agreement).toBeLessThan(1)
  })

  it('takes the wording from the most confident of three seats', () => {
    const merged = mergeVerdicts([
      side({ decision: 'first option', confidence: 0.5 }),
      side({ decision: 'third option', confidence: 0.95 }),
      side({ decision: 'second option', confidence: 0.7 }),
    ])
    expect(merged?.decision).toBe('third option')
  })

  it('names every conclusion when three seats do not converge', () => {
    const merged = mergeVerdicts([
      side({ decision: 'Adopt the message queue immediately' }),
      side({ decision: 'Keep everything synchronous forever' }),
      side({ decision: 'Rewrite the ingest layer in a batch job' }),
    ])
    expect(merged?.dissent).toMatch(/did not all reach the same decision/i)
    expect(merged?.dissent).toContain('Side A concluded:')
    expect(merged?.dissent).toContain('Side B concluded:')
    expect(merged?.dissent).toContain('Seat 3 concluded:')
  })

  it('caps two failed seats and one usable one as single-source', () => {
    // A jury that mostly failed to answer is one unchallenged opinion, however
    // many chairs were in the room.
    const merged = mergeVerdicts([null, side({ confidence: 0.99 }), null])
    expect(merged?.singleSource).toBe(true)
    expect(merged?.confidence).toBeLessThanOrEqual(0.6)
  })

  it('keeps seat labels honest when an inner seat produced nothing', () => {
    // Seats 0 and 2 usable, seat 1 silent: the third chair must still be
    // called Seat 3, not shifted into the missing seat's name.
    const merged = mergeVerdicts([
      side({ dissent: 'the schema worry' }),
      null,
      side({ dissent: 'the cost worry' }),
    ])
    expect(merged?.dissent).toContain('Side A: the schema worry')
    expect(merged?.dissent).toContain('Seat 3: the cost worry')
    expect(merged?.dissent).not.toContain('Side B:')
  })
})

describe('similarDecision', () => {
  it('treats reworded versions of the same conclusion as similar', () => {
    expect(
      similarDecision('Adopt the narrower option and revisit later', 'Adopt the narrower option, revisit later'),
    ).toBe(true)
  })

  it('treats genuinely different conclusions as different', () => {
    expect(
      similarDecision('Adopt the message queue immediately', 'Keep everything synchronous forever'),
    ).toBe(false)
  })

  it('does not flag a divergence when one side said nothing meaningful', () => {
    expect(similarDecision('', 'anything')).toBe(true)
  })
})

describe('parseFindings', () => {
  it('parses findings with their evidence', () => {
    const text = [
      '```json',
      JSON.stringify({
        findings: [
          {
            title: 'Unbounded retry',
            detail: 'spins on a persistent outage',
            priority: 'P1',
            status: 'confirmed',
            evidence: [{ path: 'src/net.ts', line: 88, symbol: 'retry', excerpt: 'while (true)' }],
          },
        ],
      }),
      '```',
    ].join('\n')

    const findings = parseFindings(text, 'session-1', 1)
    expect(findings).toHaveLength(1)
    expect(findings[0]?.priority).toBe('P1')
    expect(findings[0]?.status).toBe('confirmed')
    expect(findings[0]?.evidence[0]?.line).toBe(88)
    expect(findings[0]?.raisedBy).toBe(1)
  })

  it('downgrades a confirmed finding that carries no evidence', () => {
    // An agent asserting a bug it cannot point at is exactly what the review
    // protocol exists to catch, so the claim is not taken on trust.
    const text = '```json\n{"findings":[{"title":"Race condition","status":"confirmed","evidence":[]}]}\n```'
    const findings = parseFindings(text, 's', 0)
    expect(findings[0]?.status).toBe('unsupported')
  })

  it('keeps a dismissed finding, because the record of what was cleared matters', () => {
    const text = '```json\n{"findings":[{"title":"Not actually a leak","status":"dismissed","evidence":[]}]}\n```'
    expect(parseFindings(text, 's', 0)[0]?.status).toBe('dismissed')
  })

  it('defaults an unknown priority to the lowest rather than the highest', () => {
    const text = '```json\n{"findings":[{"title":"x","priority":"URGENT","status":"unsupported"}]}\n```'
    expect(parseFindings(text, 's', 0)[0]?.priority).toBe('P3')
  })

  it('drops entries with no title and evidence entries with no path', () => {
    const text =
      '```json\n{"findings":[{"detail":"no title"},{"title":"ok","evidence":[{"line":3},{"path":"a.ts"}]}]}\n```'
    const findings = parseFindings(text, 's', 0)
    expect(findings).toHaveLength(1)
    expect(findings[0]?.evidence).toHaveLength(1)
    expect(findings[0]?.evidence[0]?.path).toBe('a.ts')
  })

  it('returns nothing for malformed or absent blocks', () => {
    expect(parseFindings('prose only', 's', 0)).toEqual([])
    expect(parseFindings('```json\n{"findings":"not an array"}\n```', 's', 0)).toEqual([])
  })
})
