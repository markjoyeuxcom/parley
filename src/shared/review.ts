import type { WorkingDiff } from './ipc'

/**
 * Turning a diff into a review request.
 *
 * Shared rather than main-side because the author's name is a renderer notion —
 * it is what the pane calls itself — while the size limit belongs with the code
 * that gathers the diff. Both ends need the same wording, so it lives with
 * neither.
 */

/**
 * Bounded well under the 200,000-character paste limit, leaving room for the
 * framing and for whatever the reviewing CLI puts around it. A diff longer than
 * this is not a review request, it is a branch.
 */
export const MAX_DIFF_CHARS = 60_000

/**
 * The message that lands in the other pane.
 *
 * Written as a request rather than a dump: the receiving CLI is being asked to
 * do something, and a bare diff with no instruction gets a summary of the diff
 * back. Attribution is first because the reader has no idea where this came
 * from — see the relay's own note on unattributed walls of text.
 */
export function reviewRequest(author: string, work: WorkingDiff): string {
  const lines = [`${author} made the following uncommitted changes on ${work.branch}:`, '']

  if (work.diff.trim()) {
    lines.push('```diff', work.diff.trimEnd(), '```')
  } else {
    lines.push('(nothing tracked has changed)')
  }

  if (work.truncated) {
    lines.push('', `— diff truncated at ${MAX_DIFF_CHARS.toLocaleString()} characters —`)
  }

  if (work.untracked.length > 0) {
    // Named, not inlined. The reviewer can ask for any of them.
    const shown = work.untracked.slice(0, 20)
    lines.push('', `Untracked files not included: ${shown.join(', ')}`)
    if (work.untracked.length > shown.length) {
      lines.push(`…and ${work.untracked.length - shown.length} more.`)
    }
  }

  lines.push(
    '',
    'Please review for correctness, edge cases and missing tests. Say what is wrong before what is right, and skip anything you would only call style.',
  )
  return lines.join('\n')
}

/** Whether there is anything worth sending. */
export function hasWork(work: WorkingDiff | null): work is WorkingDiff {
  return work !== null && (work.diff.trim().length > 0 || work.untracked.length > 0)
}
