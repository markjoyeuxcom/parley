import type { SearchKind } from '@shared/domain'
import type { Db } from './db'

export type { SearchKind }

/**
 * Asking the record a question in words.
 *
 * The record has always been able to say what the state of a plan is, and has
 * never been able to say where anybody said anything about retries — an answer
 * spread across a debate, a milestone's intent, a reviewer's finding and a
 * backlog item filed six weeks later, in four tables nothing joins.
 */

export interface SearchHit {
  kind: SearchKind
  /** The row this came from, for whoever is going to open it. */
  refId: string
  /** A session id or a repository path — where the thing lives. */
  scope: string
  title: string
  /** The matching text with the query's words marked by «…». */
  snippet: string
}

/**
 * What someone typed, as something FTS5 will accept.
 *
 * MATCH takes a query language, and a search box takes whatever a person is
 * holding down at the time. Passing one to the other throws on an unbalanced
 * quote, a bare `AND`, a lone `*` — and a search that crashes on a half-typed
 * word is worse than no search, because it fails while somebody is mid-thought.
 *
 * So nothing is interpreted. Every token is quoted as a literal phrase and
 * joined with AND, which makes the whole grammar unreachable rather than
 * escaped: there is no input that reaches FTS5 as an operator. The trailing
 * `*` gives prefix matching, because typing "retr" and getting nothing is not
 * what anyone means by search.
 *
 * Returns null when there is nothing to search for, so a caller can tell an
 * empty query from a query with no results.
 */
export function ftsQuery(input: string): string | null {
  const tokens = input
    .split(/[^\p{L}\p{N}_]+/u)
    .filter((token) => token.length > 0)
    .slice(0, 12)
  if (tokens.length === 0) return null
  // Doubling `"` is belt and braces: the split above already removed every
  // quote, and relying on that to stay true is how injection bugs are born.
  return tokens.map((token) => `"${token.replace(/"/g, '""')}"*`).join(' AND ')
}

export interface SearchOptions {
  limit?: number
  /** Restrict to some kinds. Empty or absent means everything. */
  kinds?: readonly SearchKind[]
  /** Restrict to one session id or repository path. */
  scope?: string | null
}

export function searchRecord(db: Db, input: string, options: SearchOptions = {}): SearchHit[] {
  const match = ftsQuery(input)
  if (!match) return []

  const limit = Math.min(Math.max(options.limit ?? 50, 1), 500)
  const kinds = options.kinds ?? []
  const params: unknown[] = [match]
  let where = 'search_index MATCH ?'
  if (kinds.length > 0) {
    where += ` AND kind IN (${kinds.map(() => '?').join(', ')})`
    params.push(...kinds)
  }
  if (options.scope) {
    where += ' AND scope = ?'
    params.push(options.scope)
  }
  params.push(limit)

  // bm25 puts the title ahead of the body: a finding whose own sentence is
  // the match matters more than a turn that mentioned the word in passing.
  // Ordering by rank ASC because bm25 returns negative scores, best first.
  return db
    .all(
      `SELECT kind, ref_id, scope, title,
              snippet(search_index, 4, '«', '»', '…', 12) AS snippet
       FROM search_index
       WHERE ${where}
       ORDER BY bm25(search_index, 0.0, 0.0, 0.0, 10.0, 1.0)
       LIMIT ?`,
      ...params,
    )
    .map((row) => ({
      kind: String(row['kind']) as SearchKind,
      refId: String(row['ref_id']),
      scope: String(row['scope'] ?? ''),
      title: String(row['title'] ?? ''),
      snippet: String(row['snippet'] ?? ''),
    }))
}
