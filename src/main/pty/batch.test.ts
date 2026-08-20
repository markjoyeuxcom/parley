import { afterEach, describe, expect, it, vi } from 'vitest'
import { PtyOutputBatcher } from './batch'

afterEach(() => vi.useRealTimers())

describe('coalescing terminal output', () => {
  it('sends one message per frame instead of one per chunk', () => {
    // A redrawing agent TUI emits thousands of chunks a second, and each one
    // was its own IPC message and its own xterm write. The renderer fell
    // behind, the backlog grew, and it died at 15 GB.
    vi.useFakeTimers()
    const sent: Array<[string, string]> = []
    const batcher = new PtyOutputBatcher((paneId, data) => sent.push([paneId, data]), 16)

    for (let at = 0; at < 500; at += 1) batcher.push('pane-1', `chunk${at} `)
    expect(sent).toHaveLength(0)

    vi.advanceTimersByTime(16)
    expect(sent).toHaveLength(1)
    expect(sent[0]?.[0]).toBe('pane-1')
    expect(sent[0]?.[1]).toContain('chunk0 ')
    expect(sent[0]?.[1]).toContain('chunk499 ')
  })

  it('keeps panes apart', () => {
    vi.useFakeTimers()
    const sent: Array<[string, string]> = []
    const batcher = new PtyOutputBatcher((paneId, data) => sent.push([paneId, data]), 16)

    batcher.push('a', 'from a')
    batcher.push('b', 'from b')
    vi.advanceTimersByTime(16)

    expect(sent).toEqual([['a', 'from a'], ['b', 'from b']])
  })

  it('flushes early rather than letting a burst grow without bound', () => {
    // Coalescing must not become its own memory hole: a pane dumping a large
    // file would otherwise sit in main's heap until the timer.
    vi.useFakeTimers()
    const sent: Array<[string, string]> = []
    const batcher = new PtyOutputBatcher((paneId, data) => sent.push([paneId, data]), 16, 1_000)

    batcher.push('a', 'x'.repeat(1_200))
    expect(sent).toHaveLength(1)
    expect(sent[0]?.[1]).toHaveLength(1_200)
  })

  it('drops what a closed pane had pending', () => {
    vi.useFakeTimers()
    const sent: Array<[string, string]> = []
    const batcher = new PtyOutputBatcher((paneId, data) => sent.push([paneId, data]), 16)

    batcher.push('a', 'orphaned')
    batcher.forget('a')
    vi.advanceTimersByTime(50)

    expect(sent).toEqual([])
  })

  it('stops its timer when disposed', () => {
    vi.useFakeTimers()
    const sent: Array<[string, string]> = []
    const batcher = new PtyOutputBatcher((paneId, data) => sent.push([paneId, data]), 16)

    batcher.push('a', 'pending')
    batcher.dispose()
    vi.advanceTimersByTime(100)

    expect(sent).toEqual([])
  })
})
