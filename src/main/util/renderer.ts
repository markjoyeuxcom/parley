/**
 * Pushing to the renderer, when the renderer may not be there.
 *
 * A PTY outlives the window on purpose: closing it on macOS leaves the panes
 * running so reopening finds the work where it was. That makes "send to a
 * window that is not currently receiving" a normal state rather than a bug,
 * and the send has to be boring about it.
 *
 * Checking `isDestroyed()` is not enough. A window can be alive while its
 * render frame is gone — a reload, a crash, a navigation — and the check still
 * answers false, so the send throws:
 *
 *     Render frame was disposed before WebFrameMain could be accessed
 *
 * On the terminal data path that is one exception per chunk, thousands of them
 * from a busy pane, for output nobody can receive. The frame can also go
 * between the check and the call, which no check can close.
 *
 * So the throw is swallowed and nothing is remembered. The window comes back —
 * that is what a reload is — and the next chunk has to find the channel open.
 */
export interface RendererTarget {
  isDestroyed: () => boolean
  send: (channel: string, payload: unknown) => void
}

export function sendToRenderer(
  target: RendererTarget | null | undefined,
  channel: string,
  payload: unknown,
): void {
  if (!target || target.isDestroyed()) return
  try {
    target.send(channel, payload)
  } catch {
    // A frame that went while we were talking to it. The chunk is lost, which
    // is correct — there is nobody to show it to — and the next one will land
    // if the renderer returns.
  }
}
