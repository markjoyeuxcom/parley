import type { WorkPlan } from '@shared/domain'

/**
 * Which plans may run somewhere else.
 *
 * Three refusals, and each one is a case where remote execution would either
 * be meaningless or would put work somewhere a person cannot get it back.
 */

export interface RemoteEligibilityInput {
  plan: WorkPlan
  /** Parley's own checkout, or null in a packaged build where there is none. */
  selfRepoPath: string | null
  /** Canonicalised, so a symlinked path cannot slip past the self check. */
  canonical: (path: string) => string
}

export function remoteRefusal(input: RemoteEligibilityInput): string | null {
  const { plan } = input

  // Worktree-only, and for the same reason envelopes and the self repo are.
  // A checkout plan executes in the user's own tree, so importing a remote
  // result would mean applying another machine's commit on top of whatever
  // they have open right now — the exact conflict this whole design routes
  // around by keeping the result in a branch until a human lands it.
  if (plan.isolation !== 'worktree') {
    return 'remote execution runs in a worktree only — a result built elsewhere must land as a branch a person reviews, not on top of the checkout they are working in'
  }

  // A mock plan proves nothing about a host, and shipping a snapshot across a
  // network to have fake adapters answer it is spend and latency for a result
  // that was never going to be real.
  if (plan.mock) {
    return 'a mock plan has nothing to gain from another machine — its adapters answer without running anything'
  }

  if (input.selfRepoPath && input.canonical(plan.repoPath) === input.canonical(input.selfRepoPath)) {
    // Parley's own repository is exempt for the reason the self-update series
    // established: the one uncontrolled case is an agent writing into the
    // source of the app that is running, and doing it on a machine we cannot
    // see makes it less controlled rather than more.
    return "Parley's own repository is not executed remotely — the self-update gate has to observe the build it verifies"
  }

  return null
}
