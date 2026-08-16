import { describe, expect, it } from 'vitest'
import type { Pane } from '@shared/domain'
import { INITIAL, reduce } from './state'

/**
 * The pane registry's fold.
 *
 * Its display moved when the surface switcher went, but the property did not:
 * a pane that exits keeps its row so the grid can show the corpse and its exit
 * code, and only the user closing it removes anything. Conflating the two is
 * how exit chips became unreachable once before.
 */

const pane: Pane = {
  id: 'pane-1',
  kind: 'shell',
  title: 'shell — smoke',
  cwd: '/tmp',
  status: 'live',
  exitCode: null,
  createdAt: 1_700_000_000_000,
}

describe('the pane registry', () => {
  it('keeps an exited pane, with its code', () => {
    const born = reduce(INITIAL, { type: 'pane', pane })
    const dead = reduce(born, { type: 'paneStatus', paneId: pane.id, status: 'exited', exitCode: 1 })

    expect(dead.panes).toHaveLength(1)
    expect(dead.panes[0]).toMatchObject({ status: 'exited', exitCode: 1 })
  })

  it('removes one only when it is closed', () => {
    const born = reduce(INITIAL, { type: 'pane', pane })
    expect(reduce(born, { type: 'paneClosed', paneId: pane.id }).panes).toEqual([])
  })

  it('updates in place rather than growing a duplicate', () => {
    const born = reduce(INITIAL, { type: 'pane', pane })
    const again = reduce(born, { type: 'pane', pane: { ...pane, title: 'renamed' } })
    expect(again.panes).toHaveLength(1)
    expect(again.panes[0]?.title).toBe('renamed')
  })
})
