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
