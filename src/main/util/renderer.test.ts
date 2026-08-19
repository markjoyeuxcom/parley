import { describe, expect, it, vi } from 'vitest'
import { sendToRenderer } from './renderer'

describe('pushing to the renderer', () => {
  it('delivers while the frame is alive', () => {
    const send = vi.fn()
    sendToRenderer({ isDestroyed: () => false, send }, 'pty', { data: 'x' })
    expect(send).toHaveBeenCalledWith('pty', { data: 'x' })
  })

  it('says nothing to a window that has gone', () => {
    const send = vi.fn()
    sendToRenderer(null, 'pty', {})
    sendToRenderer({ isDestroyed: () => true, send }, 'pty', {})
    expect(send).not.toHaveBeenCalled()
  })

  it('survives a frame disposed between the check and the call', () => {
    // The real failure: "Render frame was disposed before WebFrameMain could
    // be accessed". A window can be alive while its render frame is gone — a
    // reload, a crash, a navigation — and isDestroyed() still answers false.
    // Every PTY chunk then threw, which on a busy pane is thousands of
    // exceptions for output nobody can receive.
    const send = vi.fn(() => {
      throw new Error('Render frame was disposed before WebFrameMain could be accessed')
    })
    expect(() => sendToRenderer({ isDestroyed: () => false, send }, 'pty', {})).not.toThrow()
  })

  it('keeps delivering once a frame comes back', () => {
    // The window survives a reload, so a dropped chunk must not latch the
    // channel closed for the rest of the session.
    let alive = false
    const send = vi.fn(() => { if (!alive) throw new Error('disposed') })
    const target = { isDestroyed: () => false, send }
    sendToRenderer(target, 'pty', {})
    alive = true
    sendToRenderer(target, 'pty', { data: 'after' })
    expect(send).toHaveBeenCalledTimes(2)
    expect(send).toHaveBeenLastCalledWith('pty', { data: 'after' })
  })
})
