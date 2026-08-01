import { describe, expect, it } from 'vitest'
import type { WorkPlan } from '@shared/domain'
import { remoteRefusal } from './eligibility'

/**
 * Which plans may run somewhere else.
 *
 * Each refusal is a case where remote execution would either prove nothing or
 * would put work where a person cannot get it back, so each is checked before
 * anything is snapshotted, pushed or spent.
 */

function plan(over: Partial<WorkPlan> = {}): WorkPlan {
  return {
    id: 'p1',
    repoPath: '/repos/atlas',
    isolation: 'worktree',
    mock: false,
    ...over,
  } as WorkPlan
}

const canonical = (path: string): string => path.replace(/\/+$/, '')

describe('what may run remotely', () => {
  it('allows an ordinary worktree plan', () => {
    expect(remoteRefusal({ plan: plan(), selfRepoPath: null, canonical })).toBeNull()
  })

  it('refuses a checkout plan, because the result would land on the open tree', () => {
    // The conflict the whole design routes around: a result built elsewhere
    // has to arrive as a branch a person reviews, not on top of whatever they
    // have open right now.
    const refusal = remoteRefusal({
      plan: plan({ isolation: 'checkout' }),
      selfRepoPath: null,
      canonical,
    })
    expect(refusal).toContain('worktree only')
  })

  it('refuses a mock plan, which would prove nothing about the host', () => {
    const refusal = remoteRefusal({ plan: plan({ mock: true }), selfRepoPath: null, canonical })
    expect(refusal).toContain('nothing to gain')
  })

  it('refuses Parley’s own repository, however the path is written', () => {
    // Same rule the self-update series established, and the same reason: the
    // gate has to observe the build it verifies, which it cannot do from here
    // if the build happened somewhere else.
    for (const repoPath of ['/repos/parley', '/repos/parley/']) {
      const refusal = remoteRefusal({
        plan: plan({ repoPath }),
        selfRepoPath: '/repos/parley',
        canonical,
      })
      expect(refusal).toContain("Parley's own repository")
    }
  })

  it('is dormant when there is no self repository to protect', () => {
    // A packaged build has no checkout of its own, so the rule has nothing to
    // apply to and must not accidentally refuse everything.
    expect(
      remoteRefusal({ plan: plan({ repoPath: '/repos/parley' }), selfRepoPath: null, canonical }),
    ).toBeNull()
  })

  it('reports the first reason rather than a list', () => {
    // A plan that is both mock and a checkout gets one actionable sentence.
    const refusal = remoteRefusal({
      plan: plan({ isolation: 'checkout', mock: true }),
      selfRepoPath: null,
      canonical,
    })
    expect(refusal).toContain('worktree only')
    expect(refusal).not.toContain('nothing to gain')
  })
})
