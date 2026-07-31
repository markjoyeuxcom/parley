import type { Session } from '@shared/domain'
import { shortPath } from './format'

/**
 * Grouping for the session sidebar.
 *
 * The list is chronological by default and stays that way — recency is the
 * right answer for "what was I just doing". Grouping exists for the other
 * question, "what have I done about X", which recency cannot answer once the
 * list is long.
 */

export type SessionGrouping = 'none' | 'project' | 'repository'

export interface SessionGroup {
  /** Stable key for React and for remembering which groups are collapsed. */
  key: string
  title: string
  sessions: Session[]
}

const UNGROUPED = '—'

/**
 * Groups without reordering.
 *
 * Sessions keep the order they arrived in, and groups appear in the order
 * their first session does. Sorting groups alphabetically would move the
 * thing you were just working on away from the top, which is the one
 * property the default view has that is worth keeping.
 */
export function groupSessions(
  sessions: readonly Session[],
  grouping: SessionGrouping,
): SessionGroup[] {
  if (grouping === 'none') {
    return [{ key: 'all', title: '', sessions: [...sessions] }]
  }

  const groups = new Map<string, SessionGroup>()
  for (const session of sessions) {
    const raw =
      grouping === 'project' ? session.project.trim() : (session.repoPath ?? '').trim()
    const key = raw || UNGROUPED
    const title =
      key === UNGROUPED
        ? grouping === 'project'
          ? 'No project'
          : 'No repository'
        : grouping === 'repository'
          ? shortPath(key)
          : key
    const existing = groups.get(key)
    if (existing) existing.sessions.push(session)
    else groups.set(key, { key, title, sessions: [session] })
  }

  // The ungrouped bucket sinks to the bottom: it is the least informative
  // group and it is often the largest.
  const ordered = [...groups.values()]
  const named = ordered.filter((group) => group.key !== UNGROUPED)
  const rest = ordered.filter((group) => group.key === UNGROUPED)
  return [...named, ...rest]
}

/**
 * The sessions that were run against a repository.
 *
 * A session's repoPath is whatever the user typed, so the compare trims a
 * trailing slash on both sides. It does no more than that: resolving symlinks
 * or `~` is main's job, and guessing here would claim a match the record
 * cannot back up.
 */
export function sessionsForRepo(sessions: readonly Session[], repoPath: string): Session[] {
  const target = repoPath.replace(/\/+$/, '')
  // No repository is not a repository: an empty target must collect nothing,
  // not every session that named no repo.
  if (!target) return []
  return sessions.filter((session) => (session.repoPath ?? '').replace(/\/+$/, '') === target)
}

/** The distinct projects worth offering as suggestions, most recent first. */
export function recentProjects(sessions: readonly Session[], limit = 8): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const session of sessions) {
    const project = session.project.trim()
    if (!project || seen.has(project)) continue
    seen.add(project)
    out.push(project)
    if (out.length >= limit) break
  }
  return out
}
