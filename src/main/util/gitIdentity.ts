import { realpathSync } from 'node:fs'
import { capture } from './spawn'

/**
 * The cheap identity line for a pane header: which repository a folder is in,
 * what's checked out, whether it's dirty, and how far it sits from its
 * upstream. Deliberately NOT `readTree` — that runs six git calls with
 * 60–120s budgets for the pipeline's evidence chain; a header poll gets four
 * bounded ones and a five-second ceiling, and any failure degrades to "not a
 * repository" rather than an error the user must dismiss.
 */

export interface GitIdentity {
  /** The repository root (realpath), for registry lookups keyed on it. */
  root: string
  branch: string
  dirty: boolean
  /** Commits HEAD has that upstream lacks. Zero when there is no upstream. */
  ahead: number
  /** Commits upstream has that HEAD lacks. Zero when there is no upstream. */
  behind: number
  hasUpstream: boolean
}

const GIT_TIMEOUT_MS = 5_000

async function git(args: string[], cwd: string): Promise<string | null> {
  const result = await capture('git', args, cwd, GIT_TIMEOUT_MS)
  return result.exitCode === 0 ? result.stdout.trim() : null
}

export async function gitIdentity(cwd: string): Promise<GitIdentity | null> {
  const top = await git(['rev-parse', '--show-toplevel'], cwd)
  if (!top) return null

  const [branch, status, counts] = await Promise.all([
    git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd),
    git(['status', '--porcelain'], cwd),
    git(['rev-list', '--left-right', '--count', '@{upstream}...HEAD'], cwd),
  ])

  // `--left-right --count` prints "<behind>\t<ahead>" and fails when the
  // branch has no upstream — a normal state, not an error.
  let ahead = 0
  let behind = 0
  const hasUpstream = counts !== null
  if (counts) {
    const [left, right] = counts.split(/\s+/)
    behind = Number(left) || 0
    ahead = Number(right) || 0
  }

  let root = top
  try {
    root = realpathSync(top)
  } catch {
    // The toplevel vanished mid-query; the raw spelling still identifies it.
  }

  return {
    root,
    branch: branch ?? '(unknown)',
    dirty: (status ?? '').length > 0,
    ahead,
    behind,
    hasUpstream,
  }
}
