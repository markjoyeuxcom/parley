import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Flow control, which is the part that is easy to get subtly wrong.
 *
 * The failure it exists to prevent took eight minutes and 11.3GB to reproduce
 * by hand, and it looked like a memory leak rather than a queue. These pin the
 * behaviour in milliseconds: one write outstanding at a time, everything that
 * arrives meanwhile coalesced into the next one, the child paused when the
 * backlog passes a bound, and — the one that would wedge a pane rather than
 * crash it — the child let go again when the terminal goes away.
 */

const h = vi.hoisted(() => ({
  emit: null as null | ((chunk: { paneId: string; data: string }) => void),
  setPaneFlow: vi.fn(() => Promise.resolve()),
}))

vi.mock('./api', () => ({
  api: {
    onPtyData: (fn: (chunk: { paneId: string; data: string }) => void) => {
      h.emit = fn
      return () => {}
    },
    setPaneFlow: h.setPaneFlow,
  },
}))

const { attachPane, forgetPane, backlogOf } = await import('./ptyBuffer')

/** A terminal that only finishes parsing when the test says so. */
function slowTerminal(): {
  sink: (data: string, done: () => void) => void
  writes: string[]
  drain: () => void
} {
  const writes: string[] = []
  let pendingDone: (() => void) | null = null
  return {
    writes,
    sink: (data, done) => {
      writes.push(data)
      pendingDone = done
    },
    drain: () => {
      const done = pendingDone
      pendingDone = null
      done?.()
    },
  }
}

const send = (paneId: string, data: string): void => h.emit?.({ paneId, data })

beforeEach(() => {
  h.setPaneFlow.mockClear()
})

describe('one write at a time, and the rest coalesced', () => {
  it('holds back everything that arrives while xterm is still parsing', () => {
    const pane = 'p-coalesce'
    const term = slowTerminal()
    attachPane(pane, term.sink)

    send(pane, 'first')
    expect(term.writes).toEqual(['first'])

    // xterm has not finished 'first'. These must not become two more writes.
    send(pane, 'second')
    send(pane, 'third')
    expect(term.writes).toEqual(['first'])

    term.drain()
    // One call carrying both, which is what makes this cheaper for xterm than
    // the same bytes in pieces.
    expect(term.writes).toEqual(['first', 'secondthird'])

    term.drain()
    expect(term.writes).toHaveLength(2)
    forgetPane(pane)
  })

  it('loses nothing — a terminal stream cut in half is a corrupt screen', () => {
    const pane = 'p-lossless'
    const term = slowTerminal()
    attachPane(pane, term.sink)

    const chunks = Array.from({ length: 50 }, (_, i) => `<${i}>`)
    for (const chunk of chunks) send(pane, chunk)
    for (let i = 0; i < 60; i += 1) term.drain()

    expect(term.writes.join('')).toBe(chunks.join(''))
    forgetPane(pane)
  })
})

describe('the child is paused when the terminal falls behind', () => {
  it('pauses past the high-water mark and resumes once drained', () => {
    const pane = 'p-pressure'
    const term = slowTerminal()
    attachPane(pane, term.sink)

    send(pane, 'x') // taken immediately; the backlog is what counts
    expect(h.setPaneFlow).not.toHaveBeenCalled()

    // Over a megabyte waiting behind an unfinished write.
    send(pane, 'y'.repeat(1024 * 1024 + 1))
    expect(h.setPaneFlow).toHaveBeenCalledWith(pane, true)
    expect(backlogOf(pane)).toBeGreaterThan(1024 * 1024)

    h.setPaneFlow.mockClear()
    term.drain() // the backlog goes over as one write
    term.drain()
    expect(h.setPaneFlow).toHaveBeenCalledWith(pane, false)
    forgetPane(pane)
  })

  it('does not send a message per chunk while hovering at the bound', () => {
    // Pausing and resuming on the same number would make the flow control its
    // own load — an IPC round trip for every chunk a busy pane produces.
    const pane = 'p-hysteresis'
    const term = slowTerminal()
    attachPane(pane, term.sink)

    send(pane, 'x')
    send(pane, 'y'.repeat(1024 * 1024 + 1))
    expect(h.setPaneFlow).toHaveBeenCalledTimes(1)

    for (let i = 0; i < 20; i += 1) send(pane, 'z'.repeat(1024))
    // Still one. Already paused, and still above the low-water mark.
    expect(h.setPaneFlow).toHaveBeenCalledTimes(1)
    forgetPane(pane)
  })

  it('lets a paused child go when its terminal unmounts', () => {
    // Otherwise the process stays blocked on a write nobody will ever read,
    // which is a hang with no visible cause rather than a crash.
    const pane = 'p-detach'
    const term = slowTerminal()
    const detach = attachPane(pane, term.sink)

    send(pane, 'x')
    send(pane, 'y'.repeat(1024 * 1024 + 1))
    expect(h.setPaneFlow).toHaveBeenCalledWith(pane, true)

    h.setPaneFlow.mockClear()
    detach()
    expect(h.setPaneFlow).toHaveBeenCalledWith(pane, false)
    forgetPane(pane)
  })
})

describe('output that arrives before anything is mounted', () => {
  it('replays the buffered prompt on attach', () => {
    // The original job of this module: a shell prints its prompt within
    // milliseconds of spawning, usually before React has rendered the pane.
    const pane = 'p-early'
    send(pane, 'a prompt$ ')

    const term = slowTerminal()
    attachPane(pane, term.sink)
    expect(term.writes).toEqual(['a prompt$ '])
    forgetPane(pane)
  })

  it('keeps the tail rather than growing forever with nowhere to draw', () => {
    const pane = 'p-unmounted'
    send(pane, 'q'.repeat(300 * 1024))
    expect(backlogOf(pane)).toBeLessThanOrEqual(256 * 1024)
    forgetPane(pane)
  })
})
