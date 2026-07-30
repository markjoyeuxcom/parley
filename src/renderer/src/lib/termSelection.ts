import type { Id } from '@shared/domain'

/**
 * Per-pane selection accessors, registered by each mounted terminal. A module
 * map like ptyBuffer's, for the same reason: the menu that promotes a
 * selection into a review brief lives outside the terminal component, and
 * threading a ref through the layout tree for one string is chrome the tree
 * does not need.
 */
const getters = new Map<Id, () => string>()

export function registerSelection(paneId: Id, get: () => string): () => void {
  getters.set(paneId, get)
  return () => {
    if (getters.get(paneId) === get) getters.delete(paneId)
  }
}

export function paneSelection(paneId: Id): string {
  try {
    return getters.get(paneId)?.() ?? ''
  } catch {
    return ''
  }
}
