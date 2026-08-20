import type { Id } from '@shared/domain'

/**
 * Terminal output, coalesced into one message per frame.
 *
 * Every PTY chunk used to be its own IPC message and its own `term.write`. An
 * agent CLI redrawing its TUI emits thousands of chunks a second, and three of
 * them in a grid put the renderer permanently behind: it pegged a core, the
 * backlog grew, and Chromium killed it at around 15 GB with
 * `PartitionsOutOfMemoryUsing1G`. The visible symptom was a black window and a
 * stream of "Render frame was disposed" from main — which is the PTYs still
 * talking to a renderer that had already died, not the fault itself.
 *
 * A frame's worth of output in one message is the same bytes with a fraction
 * of the overhead, and xterm handles one large write far better than a
 * thousand small ones.
 *
 * Bounded as well as batched: a pane dumping a large file flushes immediately
 * rather than growing main's heap while the timer runs. Coalescing must not
 * become the thing it was added to prevent.
 */
export class PtyOutputBatcher {
  private readonly pending = new Map<Id, string>()
  private timer: ReturnType<typeof setInterval> | null = null

  constructor(
    private readonly flush: (paneId: Id, data: string) => void,
    private readonly everyMs = 16,
    private readonly maxChars = 256 * 1024,
  ) {}

  push(paneId: Id, data: string): void {
    const combined = (this.pending.get(paneId) ?? '') + data
    if (combined.length >= this.maxChars) {
      this.pending.delete(paneId)
      this.flush(paneId, combined)
      return
    }
    this.pending.set(paneId, combined)
    this.start()
  }

  /** A closed pane's pending output goes nowhere — there is no one to show it to. */
  forget(paneId: Id): void {
    this.pending.delete(paneId)
  }

  dispose(): void {
    this.pending.clear()
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  private start(): void {
    if (this.timer) return
    this.timer = setInterval(() => {
      if (this.pending.size === 0) {
        // Idle grids are the normal case; a timer ticking against an empty map
        // forever is a wakeup every frame for nothing.
        if (this.timer) clearInterval(this.timer)
        this.timer = null
        return
      }
      for (const [paneId, data] of [...this.pending]) {
        this.pending.delete(paneId)
        this.flush(paneId, data)
      }
    }, this.everyMs)
    // Never hold the process open for a flush.
    this.timer.unref?.()
  }
}
