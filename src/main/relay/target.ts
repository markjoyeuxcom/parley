import type { Id, Pane } from '@shared/domain'

/**
 * Which pane an agent meant.
 *
 * A CLI asked to "say hello to codex" knows the word `codex` and nothing else
 * — not pane ids, not what else is open. So a vendor name resolves when it is
 * unambiguous, and a pane id always works.
 *
 * Every refusal names what IS available. The caller is a language model
 * reading a one-line error in a terminal, and "no such pane" tells it nothing
 * it can act on; "codex, agy" tells it what to try instead.
 */
export type RelayTarget = { ok: true; paneId: Id } | { ok: false; error: string }

/** A shell has no conversation to receive one; a room takes turns, not keys. */
const RECEIVES = (pane: Pane): boolean => pane.kind !== 'shell'

export function resolveRelayTarget(
  panes: readonly Pane[],
  target: string,
  fromPaneId: Id,
): RelayTarget {
  const wanted = target.trim().toLowerCase()
  if (!wanted) return { ok: false, error: 'name a pane to relay to' }

  const open = panes.filter((pane) => RECEIVES(pane) && pane.id !== fromPaneId)
  const available = [...new Set(open.filter((p) => p.status === 'live').map((p) => p.kind))]
  const naming = available.length ? available.join(', ') : 'nothing else is open'

  if (panes.some((pane) => pane.id === fromPaneId && pane.kind.toLowerCase() === wanted)) {
    // Only when the name would ALSO have matched something else does this
    // matter; otherwise the vendor lookup below simply finds nobody.
    const others = open.filter((pane) => pane.kind.toLowerCase() === wanted)
    if (others.length === 0) {
      return { ok: false, error: `that is your own pane — relay targets are ${naming}` }
    }
  }

  const byId = panes.find((pane) => pane.id === wanted || pane.id === target.trim())
  const matches = byId ? [byId] : open.filter((pane) => pane.kind.toLowerCase() === wanted)

  if (matches.length === 0) return { ok: false, error: `no pane called “${target}” — try ${naming}` }
  if (matches.length > 1) {
    // Never guess. The sender cannot see which pane it went to, so picking one
    // silently would put somebody's work in front of the wrong agent.
    const ids = matches.map((pane) => pane.id).join(', ')
    return {
      ok: false,
      error: `${matches.length} panes are “${target}” — name one by id: ${ids}`,
    }
  }

  const found = matches[0] as Pane
  if (found.id === fromPaneId) {
    return { ok: false, error: `that is your own pane — relay targets are ${naming}` }
  }
  if (!RECEIVES(found)) return { ok: false, error: `a ${found.kind} pane cannot receive a relay` }
  if (found.status === 'exited') return { ok: false, error: `the ${found.kind} pane has exited` }
  if (found.status === 'starting') {
    // A paste during a CLI's startup, before it has put its terminal in raw
    // mode, is swallowed — and reporting success over it would be a lie.
    return { ok: false, error: `the ${found.kind} pane is still starting — try again in a moment` }
  }
  return { ok: true, paneId: found.id }
}
