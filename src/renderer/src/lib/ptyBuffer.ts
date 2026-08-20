import type { Id } from '@shared/domain'
import { api } from './api'

/**
 * Terminal output, buffered before mount and flow-controlled after it.
 *
 * Two jobs, both about a consumer that is slower than its producer.
 *
 * Before mount: a pane is spawned by the main process and its shell prints a
 * prompt within milliseconds, usually before React has rendered the pane and
 * xterm has attached. Without buffering, the first thing lost is the prompt,
 * which reads as a broken terminal.
 *
 * After mount: xterm parses on the main thread, and `write` queues whatever it
 * cannot get through. Nothing bounded that queue, and three panes redrawing
 * faster than one thread could parse grew the backlog until Chromium killed
 * the renderer — measured at 11.3GB and eight minutes.
 *
 * This comment used to end "It was the backlog." That was wrong, and the
 * measurement that disproved it is the one below: bounding the queue moved
 * time-to-death from eight minutes to past an hour without stopping the climb,
 * so the backlog was a real cost and not the cause. See AGENTS.md.
 *
 * The fix is the one a terminal has always had. Hand xterm one write at a time
 * and wait to be told it landed; let what arrives meanwhile pile into a single
 * next write, which coalesces for free; and when that pile passes a bound, stop
 * reading the pty. The child then blocks on its next write, exactly as it would
 * against a real terminal nobody is reading, and starts again when we catch up.
 *
 * Nothing is dropped. Dropping was the obvious alternative and it is wrong: a
 * terminal stream is stateful, and bytes removed from the middle of it are an
 * escape sequence cut in half — a corrupted screen rather than a slow one.
 */

/** Unmounted panes still cannot buffer forever; this pane has nowhere to draw. */
const MAX_BUFFERED_CHARS = 256 * 1024

/**
 * Pause the child once this much is waiting to be parsed, and let it run again
 * once the backlog is back under {@link LOW_WATER}.
 *
 * A gap between the two on purpose. Pausing and resuming on the same number
 * means a pane hovering at the bound sends an IPC message per chunk, and the
 * flow control becomes its own load.
 */
const HIGH_WATER = 1024 * 1024
const LOW_WATER = 256 * 1024

/** Hands a chunk to a terminal, calling `done` once it has been parsed. */
export type PaneSink = (data: string, done: () => void) => void

interface Flow {
  /** Arrived, not yet handed to xterm. */
  queue: string
  /** A write is out and we have not been told it landed. */
  writing: boolean
  /** We have asked the main process to stop reading this pty. */
  paused: boolean
  /**
   * Which terminal the in-flight write belongs to.
   *
   * Bumped every time a pane attaches. A pane unmounted mid-write leaves a
   * `done` that belongs to a terminal which no longer exists — it may never
   * arrive, or it may arrive long after a new terminal has taken over. Neither
   * should touch the live one.
   */
  generation: number
}

const pending = new Map<Id, string>()
const sinks = new Map<Id, PaneSink>()
const flows = new Map<Id, Flow>()

function flowFor(paneId: Id): Flow {
  const existing = flows.get(paneId)
  if (existing) return existing
  const fresh: Flow = { queue: '', writing: false, paused: false, generation: 0 }
  flows.set(paneId, fresh)
  return fresh
}

/** Asks the main process to stop or restart reading, but only on a change. */
function applyPressure(paneId: Id, flow: Flow): void {
  const wants = flow.paused ? flow.queue.length > LOW_WATER : flow.queue.length >= HIGH_WATER
  if (wants === flow.paused) return
  flow.paused = wants
  void api.setPaneFlow(paneId, wants).catch(() => {
    // A pane that went while we were deciding. The next chunk, if there is
    // one, will ask again.
  })
}

/**
 * Hands the queue to xterm, one write at a time.
 *
 * Taking the whole queue rather than a fixed slice is what makes this batch:
 * everything that arrived while the last write was being parsed goes over as a
 * single call, which is far cheaper for xterm than the same bytes in pieces.
 */
function pump(paneId: Id, flow: Flow): void {
  if (flow.writing || flow.queue.length === 0) return
  const sink = sinks.get(paneId)
  if (!sink) return

  const chunk = flow.queue
  flow.queue = ''
  flow.writing = true
  applyPressure(paneId, flow)

  const generation = flow.generation
  sink(chunk, () => {
    // From a terminal that has since been replaced. Ignoring it is the point:
    // acting on it would drive the live terminal from a dead one's schedule.
    if (generation !== flow.generation) return
    flow.writing = false
    applyPressure(paneId, flow)
    pump(paneId, flow)
  })
}

function receive(paneId: Id, data: string): void {
  if (!sinks.has(paneId)) {
    // Nothing mounted to draw it. Keep the tail: the head of a long backlog is
    // the least interesting part of it, and this pane has no flow control to
    // apply — there is no reader to be slow.
    const combined = (pending.get(paneId) ?? '') + data
    pending.set(
      paneId,
      combined.length > MAX_BUFFERED_CHARS ? combined.slice(-MAX_BUFFERED_CHARS) : combined,
    )
    return
  }
  const flow = flowFor(paneId)
  flow.queue += data
  applyPressure(paneId, flow)
  pump(paneId, flow)
}

// Subscribing at module load is the point: nothing between spawn and mount is
// lost. Defensive because this runs at import time — a missing bridge (the
// test harness installs its own after imports) must degrade to no buffering,
// not take every surface down through the import chain.
try {
  api.onPtyData(({ paneId, data }) => receive(paneId, data))
} catch (err) {
  // Loudly. This was silent, and a renderer with no pty subscription looks
  // exactly like a terminal whose child said nothing: a blank pane, no error,
  // and the two need opposite fixes. Found while wiring Tauri, where the
  // bridge and this module's load order genuinely can differ.
  // eslint-disable-next-line no-console
  console.error('parley: pane output is not subscribed —', err)
}

/**
 * Routes a pane's output to `sink`, replaying anything buffered first. Returns a
 * detach function; output arriving after detach is buffered again, so a pane
 * that is unmounted and remounted does not lose the interim.
 */
export function attachPane(paneId: Id, sink: PaneSink): () => void {
  sinks.set(paneId, sink)
  const flow = flowFor(paneId)

  // A new terminal, so nothing is in flight for it — whatever the last one was
  // told to draw went with it. Without this reset a pane unmounted mid-write
  // stayed `writing` for ever, `pump` returned early every time, and the
  // remounted terminal never drew again: a blank pane, no error anywhere. The
  // grid remounts panes whenever the layout is rearranged, so this is the
  // ordinary path, not an edge case.
  flow.generation += 1
  flow.writing = false

  const buffered = pending.get(paneId)
  if (buffered) {
    pending.delete(paneId)
    flow.queue = buffered + flow.queue
  }
  pump(paneId, flow)

  return () => {
    sinks.delete(paneId)
    // Let the child run again. It is blocked on a write nobody is going to
    // read now, and leaving it that way would wedge the process behind an
    // unmounted pane — a hang with no visible cause.
    if (flow.paused) {
      flow.paused = false
      void api.setPaneFlow(paneId, false).catch(() => undefined)
    }
  }
}

/** Drops any buffered output for a pane that has been closed for good. */
export function forgetPane(paneId: Id): void {
  pending.delete(paneId)
  sinks.delete(paneId)
  flows.delete(paneId)
}

/** The backlog waiting on xterm, in characters. Exposed for tests and probes. */
export function backlogOf(paneId: Id): number {
  return flows.get(paneId)?.queue.length ?? pending.get(paneId)?.length ?? 0
}
