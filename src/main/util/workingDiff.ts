import type { WorkingDiff } from '@shared/ipc'
import { MAX_DIFF_CHARS } from '@shared/review'
import { capture } from './spawn'

/**
 * What an agent has changed in a folder but not committed.
 *
 * The loop this app exists for, done by hand, is: Claude writes some code, you
 * copy the diff into Codex and ask whether it holds up. Both halves are already
 * here — a pane knows its folder, and the relay types into another pane — and
 * nothing joined them.
 *
 * `git diff HEAD` rather than `git diff`, so staged work counts: an agent that
 * has staged its edits has still not had them reviewed.
 *
 * Untracked files are named but not included. A new file is often the most
 * interesting thing an agent did, and inlining every one of them is how a
 * review payload becomes a scrollback — the names let the reviewer ask.
 */

/** Five seconds, like the header poll. A review is not worth a stall. */
const GIT_TIMEOUT_MS = 5_000

async function git(args: string[], cwd: string): Promise<string | null> {
  const result = await capture('git', args, cwd, GIT_TIMEOUT_MS)
  return result.exitCode === 0 ? result.stdout : null
}

/**
 * Returns null when the folder is not a repository — the caller shows nothing
 * rather than an error, the same way the pane header does.
 */
export async function workingDiff(cwd: string): Promise<WorkingDiff | null> {
  const top = await git(['rev-parse', '--show-toplevel'], cwd)
  if (top === null) return null

  const [branch, diff, untracked] = await Promise.all([
    git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd),
    git(['diff', 'HEAD'], cwd),
    git(['ls-files', '--others', '--exclude-standard'], cwd),
  ])

  const body = diff ?? ''
  const truncated = body.length > MAX_DIFF_CHARS

  return {
    branch: (branch ?? '').trim() || 'HEAD',
    diff: truncated ? body.slice(0, MAX_DIFF_CHARS) : body,
    untracked: (untracked ?? '')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean),
    truncated,
  }
}
