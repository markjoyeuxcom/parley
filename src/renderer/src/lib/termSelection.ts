import type { Id } from '@shared/domain'

/**
 * Per-pane terminal accessors, registered by each mounted terminal. A module
 * map like ptyBuffer's, for the same reason: the menus and the find bar live
 * outside the terminal component, and threading refs through the layout tree
 * for a handful of calls is chrome the tree does not need.
 */
export interface TermAccess {
  getSelection: () => string
  /** The full buffer as text — the transcript a save writes. */
  serialize: () => string
  findNext: (query: string) => boolean
  findPrevious: (query: string) => boolean
  clearSearch: () => void
}

const terms = new Map<Id, TermAccess>()

export function registerTerm(paneId: Id, access: TermAccess): () => void {
  terms.set(paneId, access)
  return () => {
    if (terms.get(paneId) === access) terms.delete(paneId)
  }
}

export function termAccess(paneId: Id): TermAccess | null {
  return terms.get(paneId) ?? null
}

export function paneSelection(paneId: Id): string {
  try {
    return terms.get(paneId)?.getSelection() ?? ''
  } catch {
    return ''
  }
}

/**
 * Why the relay cannot send from this pane yet, if it cannot.
 *
 * The awkward case: a CLI that draws clickable UI turns on mouse tracking, and
 * xterm then hands a drag to the application instead of selecting locally. The
 * application highlights the text itself, so it LOOKS selected while
 * `getSelection()` stays empty and the relay offers nothing. Claude Code does
 * this; selecting in its pane is impossible without `macOptionClickForcesSelection`
 * and a held ⌥.
 *
 * The hint mentions ⌥ unconditionally rather than detecting the mode.
 * `mouseTrackingMode` was measured against the real CLIs and came back
 * identical for Claude, whose pane cannot be drag-selected, and Codex, whose
 * pane can — so the mode does not distinguish the two cases and a hint keyed
 * on it would be wrong half the time. One sentence that is true either way
 * beats a detector that is confidently wrong.
 */
export type RelayState = 'ready' | 'no-targets' | 'needs-selection'

export function relayState(input: { targets: number; selection: string }): RelayState {
  if (input.targets === 0) return 'no-targets'
  return input.selection.trim() ? 'ready' : 'needs-selection'
}
