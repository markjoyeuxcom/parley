import type { Evidence } from './domain'

/**
 * A reference as one line: `path:line — symbol`.
 *
 * Its own module, and a dependency leaf, for the reason `usage.ts` and
 * `ids.ts` are: `domain.ts` builds zod schemas at module scope, so ANY value
 * imported from it pulls the whole of zod in behind it. That is fine in the
 * app and fatal in `parley-remote`, whose defining property is that it
 * contains no npm code — and the execution core, which the remote bundle is
 * built from, formats findings. Putting one small function beside the schemas
 * turned the boundary red immediately; the type import here erases, so
 * nothing follows it.
 *
 * Shared so the ledger panel, the run room and the backlog brief cannot drift
 * into three notations for the same fact. `path:line` because that is what
 * every editor, terminal and reviewer already reads as a location — the
 * format is the affordance.
 */
export function evidenceLabel(entry: Evidence): string {
  const at = entry.line ? `:${entry.line}` : ''
  return `${entry.path}${at}${entry.symbol ? ` — ${entry.symbol}` : ''}`
}
