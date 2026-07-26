import type { Id } from '@shared/domain'
import { api } from './api'

/**
 * Buffers terminal output that arrives before its terminal is mounted.
 *
 * A pane is spawned by the main process and its shell prints a prompt within
 * milliseconds — usually before React has rendered the pane and the xterm
 * instance has attached. Without this, the first thing the user would lose is
 * the prompt, which reads as a broken terminal.
 *
 * The subscription is installed at module load, so nothing between pane creation
 * and mount is dropped.
 */

const MAX_BUFFERED_CHARS = 256 * 1024

const pending = new Map<Id, string>()
const sinks = new Map<Id, (data: string) => void>()

api.onPtyData(({ paneId, data }) => {
  const sink = sinks.get(paneId)
  if (sink) {
    sink(data)
    return
  }
  const existing = pending.get(paneId) ?? ''
  const combined = existing + data
  pending.set(
    paneId,
    combined.length > MAX_BUFFERED_CHARS ? combined.slice(-MAX_BUFFERED_CHARS) : combined,
  )
})

/**
 * Routes a pane's output to `sink`, replaying anything buffered first. Returns a
 * detach function; output arriving after detach is buffered again, so a pane
 * that is unmounted and remounted does not lose the interim.
 */
export function attachPane(paneId: Id, sink: (data: string) => void): () => void {
  const buffered = pending.get(paneId)
  if (buffered) {
    pending.delete(paneId)
    sink(buffered)
  }
  sinks.set(paneId, sink)
  return () => {
    sinks.delete(paneId)
  }
}

/** Drops any buffered output for a pane that has been closed for good. */
export function forgetPane(paneId: Id): void {
  pending.delete(paneId)
  sinks.delete(paneId)
}
