import { describe, expect, it } from 'vitest'
import { clampNumber, extractJson, oneOf, safeString } from './extract'

describe('extractJson', () => {
  it('pulls a fenced json block and keeps the prose', () => {
    const message = 'Here is my reasoning.\n\n```json\n{"decision":"ship it"}\n```'
    const result = extractJson<{ decision: string }>(message)
    expect(result.data?.decision).toBe('ship it')
    expect(result.prose).toBe('Here is my reasoning.')
    expect(result.problem).toBeNull()
  })

  it('prefers the last block, so an illustrative example above does not win', () => {
    const message = [
      'The shape looks like this:',
      '```json',
      '{"decision":"EXAMPLE"}',
      '```',
      'And my actual verdict:',
      '```json',
      '{"decision":"REAL"}',
      '```',
    ].join('\n')
    expect(extractJson<{ decision: string }>(message).data?.decision).toBe('REAL')
  })

  it('accepts a bare fence with no language tag', () => {
    const result = extractJson<{ met: boolean }>('done\n```\n{"met": true}\n```')
    expect(result.data?.met).toBe(true)
  })

  it('falls back to a balanced object when the model forgot the fence', () => {
    const result = extractJson<{ passed: boolean }>('Looks fine.\n{"passed": true, "concerns": []}')
    expect(result.data?.passed).toBe(true)
    expect(result.prose).toBe('Looks fine.')
  })

  it('tolerates a trailing comma, the most common malformation', () => {
    const result = extractJson<{ a: number }>('```json\n{"a": 1,}\n```')
    expect(result.data?.a).toBe(1)
  })

  it('handles braces inside string values without truncating', () => {
    const result = extractJson<{ note: string }>('```json\n{"note":"use {curly} braces"}\n```')
    expect(result.data?.note).toBe('use {curly} braces')
  })

  it('handles escaped quotes inside strings', () => {
    const result = extractJson<{ note: string }>('{"note":"he said \\"no\\" firmly"}')
    expect(result.data?.note).toBe('he said "no" firmly')
  })

  it('never throws on unparseable input, and says what went wrong', () => {
    const result = extractJson('```json\n{not json at all\n```')
    expect(result.data).toBeNull()
    expect(result.prose).toContain('not json')
    expect(result.problem).toMatch(/did not parse/)
  })

  it('reports no block found when there is only prose', () => {
    const result = extractJson('Just an opinion, no structured output.')
    expect(result.data).toBeNull()
    expect(result.problem).toMatch(/no JSON block/)
  })

  it('returns empty for empty input', () => {
    expect(extractJson('').data).toBeNull()
    expect(extractJson('').prose).toBe('')
  })

  it('ignores a top-level array, which is not a valid contract response', () => {
    expect(extractJson('```json\n[1,2,3]\n```').data).toBeNull()
  })
})

describe('coercion helpers', () => {
  it('clamps numbers into range with a fallback', () => {
    expect(clampNumber(5, 0, 10, 1)).toBe(5)
    expect(clampNumber(50, 0, 10, 1)).toBe(10)
    expect(clampNumber(-5, 0, 10, 1)).toBe(0)
    expect(clampNumber('7', 0, 10, 1)).toBe(7)
    expect(clampNumber('abc', 0, 10, 1)).toBe(1)
    expect(clampNumber(undefined, 0, 10, 1)).toBe(1)
    expect(clampNumber(Number.NaN, 0, 10, 1)).toBe(1)
    expect(clampNumber(Infinity, 0, 10, 1)).toBe(1)
  })

  it('bounds string length so a runaway reply cannot bloat a row', () => {
    expect(safeString('  trimmed  ')).toBe('trimmed')
    expect(safeString('x'.repeat(100), 10)).toHaveLength(10)
    expect(safeString(null)).toBe('')
    expect(safeString({ a: 1 })).toBe('')
    expect(safeString(42)).toBe('42')
  })

  it('rejects values outside the allowed set', () => {
    expect(oneOf('P0', ['P0', 'P1'] as const, 'P1')).toBe('P0')
    expect(oneOf('P9', ['P0', 'P1'] as const, 'P1')).toBe('P1')
    expect(oneOf(undefined, ['P0', 'P1'] as const, 'P1')).toBe('P1')
  })
})

describe('extractJson on unfenced JSON containing nested objects', () => {
  it('returns the whole object, not the first thing nested inside it', () => {
    const { data } = extractJson<Record<string, unknown>>(
      '{"title":"Plan","milestones":[{"title":"M1","intent":"do it"}]}',
    )
    expect(Object.keys(data ?? {})).toEqual(['title', 'milestones'])
    expect(Array.isArray((data ?? {})['milestones'])).toBe(true)
  })

  it('still prefers a trailing block over an earlier one', () => {
    const { data } = extractJson<Record<string, unknown>>(
      'First thought: {"passed":false} — on reflection: {"passed":true}',
    )
    expect(data).toEqual({ passed: true })
  })

  it('handles deep nesting without descending', () => {
    const { data } = extractJson<Record<string, unknown>>('{"a":{"b":{"c":{"d":1}}}}')
    expect(Object.keys(data ?? {})).toEqual(['a'])
  })
})
