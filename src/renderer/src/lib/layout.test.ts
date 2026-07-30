import { describe, expect, it } from 'vitest'
import {
  collectSlotIds,
  countSlots,
  leaf,
  nextSlot,
  previousSlot,
  fromSavedLayout,
  removeLeaf,
  setRatio,
  splitLeaf,
  swapLeaves,
  toSavedLayout,
  type Slot,
} from './layout'

describe('pane layout tree', () => {
  it('splits a single pane into two', () => {
    const layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    expect(layout.type).toBe('split')
    expect(collectSlotIds(layout)).toEqual(['p1', 'p2'])
  })

  it('splits a nested pane without disturbing its siblings', () => {
    let layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    layout = splitLeaf(layout, 'p2', 'column', 'p3')
    expect(collectSlotIds(layout)).toEqual(['p1', 'p2', 'p3'])
  })

  it('ignores a split targeting a pane that is not there', () => {
    const layout = splitLeaf(leaf('p1'), 'nope', 'row', 'p2')
    expect(collectSlotIds(layout)).toEqual(['p1'])
  })

  it('collapses the split when one side is removed', () => {
    let layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    const after = removeLeaf(layout, 'p2')
    expect(after).toEqual(leaf('p1'))

    layout = splitLeaf(leaf('a'), 'a', 'row', 'b')
    layout = splitLeaf(layout, 'b', 'column', 'c')
    const pruned = removeLeaf(layout, 'c')
    expect(collectSlotIds(pruned)).toEqual(['a', 'b'])
    // The column split that held b and c should be gone, not left with one child.
    expect(pruned?.type).toBe('split')
  })

  it('returns null when the last pane is removed', () => {
    expect(removeLeaf(leaf('only'), 'only')).toBeNull()
  })

  it('leaves the tree untouched when removing an unknown pane', () => {
    const layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    expect(collectSlotIds(removeLeaf(layout, 'ghost'))).toEqual(['p1', 'p2'])
  })

  it('counts panes across arbitrary nesting', () => {
    let layout = leaf('a')
    for (const id of ['b', 'c', 'd', 'e']) layout = splitLeaf(layout, 'a', 'row', id)
    expect(countSlots(layout)).toBe(5)
    expect(countSlots(null)).toBe(0)
  })
})

describe('setRatio', () => {
  it('updates the root split', () => {
    const layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    const updated = setRatio(layout, [], 0.7)
    expect(updated.type === 'split' && updated.ratio).toBe(0.7)
  })

  it('clamps so neither side can be dragged to nothing', () => {
    const layout = splitLeaf(leaf('p1'), 'p1', 'row', 'p2')
    const tiny = setRatio(layout, [], -1)
    const huge = setRatio(layout, [], 5)
    expect(tiny.type === 'split' && tiny.ratio).toBe(0.15)
    expect(huge.type === 'split' && huge.ratio).toBe(0.85)
  })

  it('addresses a nested split by path', () => {
    let layout = splitLeaf(leaf('a'), 'a', 'row', 'b')
    layout = splitLeaf(layout, 'b', 'column', 'c')
    const updated = setRatio(layout, ['b'], 0.25)
    const branch = updated.type === 'split' ? updated.b : null
    expect(branch?.type === 'split' && branch.ratio).toBe(0.25)
    // The root ratio must be untouched.
    expect(updated.type === 'split' && updated.ratio).toBe(0.5)
  })
})

describe('saving and restoring a layout', () => {
  const slots = {
    s1: { kind: 'shell' as const, cwd: '/repo/a', paneId: 'pane-1' },
    s2: { kind: 'claude' as const, cwd: '/repo/a', paneId: 'pane-2' },
    s3: { kind: 'codex' as const, cwd: '/repo/b', paneId: 'pane-3' },
  }

  function tree() {
    let node = splitLeaf(leaf('s1'), 's1', 'row', 's2')
    node = splitLeaf(node, 's2', 'column', 's3')
    return node
  }

  it('drops every id, because process ids do not survive a restart', () => {
    const saved = toSavedLayout(tree(), slots)
    expect(JSON.stringify(saved)).not.toContain('pane-')
    expect(JSON.stringify(saved)).not.toContain('s1')
  })

  it('keeps each pane’s own folder, not one folder for the layout', () => {
    // The whole point of not making a layout a single-folder workspace.
    const saved = toSavedLayout(tree(), slots)
    const json = JSON.stringify(saved)
    expect(json).toContain('/repo/a')
    expect(json).toContain('/repo/b')
  })

  it('round-trips shape, kinds and folders', () => {
    const saved = toSavedLayout(tree(), slots)
    if (!saved) throw new Error('expected a saved tree')

    let n = 0
    const { tree: restored, slots: restoredSlots } = fromSavedLayout(saved, () => `r${(n += 1)}`)

    const ids = collectSlotIds(restored)
    expect(ids).toHaveLength(3)
    expect(ids.map((id) => restoredSlots[id]?.kind)).toEqual(['shell', 'claude', 'codex'])
    expect(ids.map((id) => restoredSlots[id]?.cwd)).toEqual(['/repo/a', '/repo/a', '/repo/b'])
  })

  it('a human-given name rides the save and the restore; unnamed slots stay unnamed', () => {
    const named: Record<string, Slot> = {
      ...slots,
      s2: { ...slots.s2, title: 'auth spike' },
    }
    const saved = toSavedLayout(tree(), named)
    if (!saved) throw new Error('expected a saved tree')
    expect(JSON.stringify(saved)).toContain('auth spike')

    let n = 0
    const { tree: restored, slots: restoredSlots } = fromSavedLayout(saved, () => `r${(n += 1)}`)
    const ids = collectSlotIds(restored)
    expect(ids.map((id) => restoredSlots[id]?.title)).toEqual([undefined, 'auth spike', undefined])
  })

  it('restores nothing running — the caller decides what to start', () => {
    const saved = toSavedLayout(tree(), slots)
    if (!saved) throw new Error('expected a saved tree')
    let n = 0
    const { slots: restoredSlots } = fromSavedLayout(saved, () => `r${(n += 1)}`)
    for (const slot of Object.values(restoredSlots)) expect(slot.paneId).toBeNull()
  })

  it('preserves split direction and ratio', () => {
    const original = setRatio(splitLeaf(leaf('s1'), 's1', 'column', 's2'), [], 0.3)
    const saved = toSavedLayout(original, slots)
    expect(saved?.type === 'split' && saved.direction).toBe('column')
    expect(saved?.type === 'split' && saved.ratio).toBe(0.3)
  })

  it('mints fresh ids so a layout can be opened twice without collision', () => {
    const saved = toSavedLayout(tree(), slots)
    if (!saved) throw new Error('expected a saved tree')
    let n = 0
    const mint = (): string => `r${(n += 1)}`
    const first = fromSavedLayout(saved, mint)
    const second = fromSavedLayout(saved, mint)
    const overlap = collectSlotIds(first.tree).filter((id) => collectSlotIds(second.tree).includes(id))
    expect(overlap).toEqual([])
  })

  it('skips a leaf whose slot has gone rather than emitting a hole', () => {
    const saved = toSavedLayout(tree(), { s1: slots.s1, s3: slots.s3 })
    const json = JSON.stringify(saved)
    expect(json).toContain('/repo/b')
    // The surviving split collapses; nothing references the missing slot.
    expect(json).not.toContain('claude')
  })

  it('returns null for an empty grid', () => {
    expect(toSavedLayout(null, slots)).toBeNull()
  })
})

describe('pane cycling', () => {
  const layout = (() => {
    let node = splitLeaf(leaf('a'), 'a', 'row', 'b')
    node = splitLeaf(node, 'b', 'row', 'c')
    return node
  })()

  it('wraps forward and backward', () => {
    expect(nextSlot(layout, 'a')).toBe('b')
    expect(nextSlot(layout, 'c')).toBe('a')
    expect(previousSlot(layout, 'a')).toBe('c')
    expect(previousSlot(layout, 'b')).toBe('a')
  })

  it('falls back to the first pane when nothing is focused', () => {
    expect(nextSlot(layout, null)).toBe('a')
    expect(nextSlot(layout, 'ghost')).toBe('a')
  })

  it('swaps two leaves in place, and refuses ghosts and self-swaps', () => {
    const swapped = swapLeaves(layout, 'a', 'c')
    expect(collectSlotIds(swapped)).toEqual(
      collectSlotIds(layout).map((id) => (id === 'a' ? 'c' : id === 'c' ? 'a' : id)),
    )
    // The tree's shape and ratios are untouched — the panes traded places.
    expect(JSON.stringify(swapped).replace(/"slotId":"[^"]*"/g, '')).toBe(
      JSON.stringify(layout).replace(/"slotId":"[^"]*"/g, ''),
    )
    // A ghost id must never duplicate the survivor.
    expect(swapLeaves(layout, 'a', 'ghost')).toBe(layout)
    expect(swapLeaves(layout, 'a', 'a')).toBe(layout)
  })

  it('returns null for an empty grid', () => {
    expect(nextSlot(null, null)).toBeNull()
    expect(previousSlot(null, 'a')).toBeNull()
  })
})
