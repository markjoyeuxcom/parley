import type { Id, LayoutNode, PaneKind, SavedLayoutNode } from '@shared/domain'

/**
 * The grid layout is a binary split tree over *slots*. Splits are addressed by the path taken
 * to reach them ('a'/'b' at each branch) rather than by an id, which keeps the
 * persisted shape in `shared/domain.ts` free of synthetic identifiers.
 */
export type SplitPath = Array<'a' | 'b'>

export function leaf(slotId: Id): LayoutNode {
  return { type: 'leaf', slotId }
}

/** Replaces the leaf holding `targetSlotId` with a split containing both panes. */
export function splitLeaf(
  node: LayoutNode,
  targetSlotId: Id,
  direction: 'row' | 'column',
  newSlotId: Id,
): LayoutNode {
  if (node.type === 'leaf') {
    if (node.slotId !== targetSlotId) return node
    return { type: 'split', direction, ratio: 0.5, a: leaf(targetSlotId), b: leaf(newSlotId) }
  }
  return {
    ...node,
    a: splitLeaf(node.a, targetSlotId, direction, newSlotId),
    b: splitLeaf(node.b, targetSlotId, direction, newSlotId),
  }
}

/**
 * Removes a pane, collapsing the split that held it.
 *
 * Returns null when the tree becomes empty, which the caller reads as "the grid
 * has no panes left".
 */
export function removeLeaf(node: LayoutNode, slotId: Id): LayoutNode | null {
  if (node.type === 'leaf') return node.slotId === slotId ? null : node

  const a = removeLeaf(node.a, slotId)
  const b = removeLeaf(node.b, slotId)
  if (a === null && b === null) return null
  // A split with one surviving child is not a split any more.
  if (a === null) return b
  if (b === null) return a
  return { ...node, a, b }
}

export function collectSlotIds(node: LayoutNode | null): Id[] {
  if (!node) return []
  if (node.type === 'leaf') return [node.slotId]
  return [...collectSlotIds(node.a), ...collectSlotIds(node.b)]
}

export function countSlots(node: LayoutNode | null): number {
  return collectSlotIds(node).length
}

/** Updates the ratio of the split at `path`, clamped to keep both sides usable. */
export function setRatio(node: LayoutNode, path: SplitPath, ratio: number): LayoutNode {
  if (node.type !== 'split') return node
  const clamped = Math.max(0.15, Math.min(0.85, ratio))
  if (path.length === 0) return { ...node, ratio: clamped }

  const [head, ...rest] = path
  if (head === 'a') return { ...node, a: setRatio(node.a, rest, ratio) }
  if (head === 'b') return { ...node, b: setRatio(node.b, rest, ratio) }
  return node
}

/** Finds the pane after `slotId` in reading order, for keyboard pane cycling. */
export function nextSlot(node: LayoutNode | null, slotId: Id | null): Id | null {
  const ids = collectSlotIds(node)
  if (!ids.length) return null
  if (!slotId) return ids[0] ?? null
  const index = ids.indexOf(slotId)
  if (index === -1) return ids[0] ?? null
  return ids[(index + 1) % ids.length] ?? null
}

export function previousSlot(node: LayoutNode | null, slotId: Id | null): Id | null {
  const ids = collectSlotIds(node)
  if (!ids.length) return null
  if (!slotId) return ids[ids.length - 1] ?? null
  const index = ids.indexOf(slotId)
  if (index === -1) return ids[0] ?? null
  return ids[(index - 1 + ids.length) % ids.length] ?? null
}

// ─── Saving and restoring ────────────────────────────────────────────────────

/** What a slot holds. `paneId` is null for a slot whose pane is not running. */
export interface Slot {
  kind: PaneKind
  cwd: string
  paneId: Id | null
  /** A human-given name. Survives restarts and rides saved layouts. */
  title?: string
}

/**
 * Converts the live tree into its persisted form.
 *
 * Drops every id. A saved layout describes what each pane *is*, so restoring it
 * mints new slots rather than trying to revive process ids that died with the
 * last run.
 */
export function toSavedLayout(
  node: LayoutNode | null,
  slots: Record<Id, Slot>,
): SavedLayoutNode | null {
  if (!node) return null
  if (node.type === 'leaf') {
    const slot = slots[node.slotId]
    if (!slot) return null
    return slot.title
      ? { type: 'leaf', kind: slot.kind, cwd: slot.cwd, title: slot.title }
      : { type: 'leaf', kind: slot.kind, cwd: slot.cwd }
  }
  const a = toSavedLayout(node.a, slots)
  const b = toSavedLayout(node.b, slots)
  if (!a && !b) return null
  if (!a) return b
  if (!b) return a
  return { type: 'split', direction: node.direction, ratio: node.ratio, a, b }
}

/**
 * Rebuilds a live tree from a saved one, minting a fresh slot per leaf.
 *
 * Returns the slots unstarted — `paneId` null throughout. The caller decides
 * which ones to spawn, which is how "restore shells, leave agents as
 * placeholders" is expressed without this function knowing about that policy.
 */
export function fromSavedLayout(
  saved: SavedLayoutNode,
  mintId: () => Id,
): { tree: LayoutNode; slots: Record<Id, Slot> } {
  const slots: Record<Id, Slot> = {}

  const walk = (node: SavedLayoutNode): LayoutNode => {
    if (node.type === 'leaf') {
      const slotId = mintId()
      slots[slotId] = { kind: node.kind, cwd: node.cwd, paneId: null, ...(node.title ? { title: node.title } : {}) }
      return { type: 'leaf', slotId }
    }
    return {
      type: 'split',
      direction: node.direction,
      ratio: node.ratio,
      a: walk(node.a),
      b: walk(node.b),
    }
  }

  return { tree: walk(saved), slots }
}
