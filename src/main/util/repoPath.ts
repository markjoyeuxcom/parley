import { realpathSync } from 'node:fs'

/**
 * The canonical form of a repository path, for backlog and learnings keys.
 *
 * Nothing else in the app normalises repo paths — plans, worktrees and
 * sessions key on the raw trimmed string the user provided, and changing
 * that would re-key every existing row. The backlog is new and cross-session
 * by nature, so it canonicalises at its own boundary instead: symlinked
 * spellings and trailing slashes must not fork one repository's backlog into
 * several. Falls back to the trimmed, slash-stripped input when the path
 * does not resolve (a vanished repo still owns its backlog).
 */
export function canonicalRepoPath(path: string): string {
  const trimmed = path.trim().replace(/\/+$/, '') || path.trim()
  try {
    return realpathSync(trimmed)
  } catch {
    return trimmed
  }
}
