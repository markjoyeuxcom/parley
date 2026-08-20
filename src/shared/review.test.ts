import { describe, expect, it } from 'vitest'
import { MAX_DIFF_CHARS, hasWork, reviewRequest } from './review'
import type { WorkingDiff } from './ipc'

const work = (over: Partial<WorkingDiff> = {}): WorkingDiff => ({
  branch: 'feat/auth',
  diff: '--- a/src/x.ts\n+++ b/src/x.ts\n@@ -1 +1 @@\n-const a = 1\n+const a = 2\n',
  untracked: [],
  truncated: false,
  ...over,
})

describe('the review request', () => {
  it('names who did the work and where', () => {
    // The receiving CLI has no idea where this came from, and an unattributed
    // wall of somebody else's diff reads as the user's own.
    const out = reviewRequest('claude — parley', work())
    expect(out).toContain('claude — parley made the following uncommitted changes on feat/auth')
  })

  it('asks for something, rather than only pasting a diff', () => {
    // A bare diff with no instruction gets a summary of the diff back.
    const out = reviewRequest('claude', work())
    expect(out).toMatch(/review/i)
    expect(out).toMatch(/missing tests/i)
  })

  it('fences the diff so a TUI does not read it as instructions', () => {
    const out = reviewRequest('claude', work())
    expect(out).toContain('```diff')
    expect(out.match(/```/g)).toHaveLength(2)
  })

  it('names untracked files without inlining them', () => {
    // A new file is often the most interesting thing an agent did, but
    // inlining every one is how a review payload becomes a scrollback.
    const out = reviewRequest('claude', work({ untracked: ['src/new.ts', 'src/other.ts'] }))
    expect(out).toContain('src/new.ts, src/other.ts')
    expect(out).toMatch(/untracked files not included/i)
  })

  it('does not list a hundred untracked files', () => {
    const many = Array.from({ length: 60 }, (_, i) => `f${i}.ts`)
    const out = reviewRequest('claude', work({ untracked: many }))
    expect(out).toContain('…and 40 more.')
    expect(out).not.toContain('f59.ts')
  })

  it('says when the diff was cut rather than pretending it is whole', () => {
    const out = reviewRequest('claude', work({ truncated: true }))
    expect(out).toMatch(/truncated/i)
    expect(out).toContain(MAX_DIFF_CHARS.toLocaleString())
  })

  it('is honest when only untracked files changed', () => {
    const out = reviewRequest('claude', work({ diff: '', untracked: ['src/new.ts'] }))
    expect(out).toContain('(nothing tracked has changed)')
    expect(out).toContain('src/new.ts')
  })
})

describe('whether there is anything to send', () => {
  it('is false for a clean tree and for a folder that is not a repository', () => {
    expect(hasWork(null)).toBe(false)
    expect(hasWork(work({ diff: '   \n', untracked: [] }))).toBe(false)
  })

  it('is true for tracked changes, and for untracked files alone', () => {
    expect(hasWork(work())).toBe(true)
    expect(hasWork(work({ diff: '', untracked: ['src/new.ts'] }))).toBe(true)
  })
})
