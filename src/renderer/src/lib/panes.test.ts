import { describe, expect, it } from 'vitest'
import type { Pane } from '@shared/domain'
import type { Slot } from './layout'
import { slotPaneExit, slotPaneStatus, slotPaneTitle } from './panes'

const slot: Slot = { kind: 'claude', cwd: '/Users/x/Developer/thing', paneId: 'p1' }
const idle: Slot = { kind: 'shell', cwd: '/tmp', paneId: null }
const pane: Pane = {
  id: 'p1',
  kind: 'claude',
  title: 'claude — thing',
  cwd: '/Users/x/Developer/thing',
  status: 'live',
  exitCode: null,
  createdAt: 1,
}

describe('pane header derivations', () => {
  it('prefers the registered title and falls back to a synthetic one', () => {
    expect(slotPaneTitle(slot, pane)).toBe('claude — thing')
    // Registry has not caught up: the synthetic names the kind and the folder.
    expect(slotPaneTitle(slot, undefined)).toBe('Claude — Developer/thing')
    expect(slotPaneTitle(undefined, undefined)).toBe('pane')
  })

  it('separates idle (no process) from starting (spawned, unheard-from)', () => {
    expect(slotPaneStatus(idle, undefined)).toBe('idle')
    expect(slotPaneStatus(slot, undefined)).toBe('starting')
    expect(slotPaneStatus(slot, pane)).toBe('live')
    expect(slotPaneStatus(slot, { ...pane, status: 'exited' })).toBe('exited')
  })

  it('reports the exit code only when a process actually carried one', () => {
    expect(slotPaneExit(idle, undefined)).toBeNull()
    expect(slotPaneExit(slot, undefined)).toBeNull()
    expect(slotPaneExit(slot, { ...pane, status: 'exited', exitCode: 130 })).toBe(130)
  })
})
