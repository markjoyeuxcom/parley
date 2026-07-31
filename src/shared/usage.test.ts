import { describe, expect, it } from 'vitest'
import { addUsage, emptyUsage } from './usage'
import * as domain from './domain'

/**
 * The dependency leaf's values.
 *
 * The boundary this module exists to protect — that the remote execution
 * bundle contains no npm code — is asserted in
 * src/main/remote/boundary.test.ts, which needs Node APIs that shared/ is not
 * typechecked for.
 */

describe('the values themselves', () => {
  it('starts every counter at zero', () => {
    expect(emptyUsage()).toEqual({
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      costUsd: 0,
    })
  })

  it('returns a fresh object each time, so accumulating cannot alias', () => {
    const a = emptyUsage()
    a.inputTokens = 5
    expect(emptyUsage().inputTokens).toBe(0)
  })

  it('adds every field', () => {
    expect(
      addUsage(
        { inputTokens: 1, cachedInputTokens: 2, outputTokens: 3, reasoningTokens: 4, costUsd: 0.5 },
        { inputTokens: 10, cachedInputTokens: 20, outputTokens: 30, reasoningTokens: 40, costUsd: 1.5 },
      ),
    ).toEqual({
      inputTokens: 11,
      cachedInputTokens: 22,
      outputTokens: 33,
      reasoningTokens: 44,
      costUsd: 2,
    })
  })
})

describe('existing callers are unaffected', () => {
  it('still reaches the same values through domain', () => {
    // The re-export is what makes this a narrow extraction rather than a
    // repository-wide import rewrite. One definition, two doors.
    expect(domain.emptyUsage).toBe(emptyUsage)
    expect(domain.addUsage).toBe(addUsage)
  })

  it('still validates a usage object against the schema', () => {
    // The schema stays where it was. Splitting the VALUE out must not have
    // changed what the boundary accepts.
    expect(domain.Usage.parse(emptyUsage())).toEqual(emptyUsage())
    expect(() => domain.Usage.parse({ inputTokens: -1 })).toThrow()
  })
})
