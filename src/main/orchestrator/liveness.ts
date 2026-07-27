import type { AppEvent } from '@shared/events'
import { STALL_AFTER_MS } from '@shared/holds'
import type { Id } from '@shared/domain'
import type { Repo } from '@main/store/repo'
import type { RunState } from './pipeline'

/**
 * Stall detection for in-flight runs.
 *
 * The activity stream is the liveness signal: the adapters report every tool
 * use and command, and a run that has said nothing for minutes is either
 * thinking very hard or wedged — a distinction a timeout cannot make and a
 * human should not have to watch for. The watchdog keeps an in-memory
 * last-activity map fed by the events the Manager already emits, persists a
 * throttled stamp so the stall is *derivable* (holds are computed from
 * durable state, and this is the durable trace), and asks for one read-only
 * cross-vendor inspection per stall episode. It never aborts anything: the
 * stopper stays human, per the fixed product decision.
 *
 * Two disciplines keep the derived hold honest:
 *
 * - **Stamps are written on real activity only, throttled.** A quiet run
 *   writes nothing, so the persisted stamp freezes at the last real activity
 *   — which is exactly the stable generation the hold's notify-once needs. A
 *   tick-driven write would re-mint the identity mid-episode and re-notify.
 * - **Persistence is silent.** The stamp write emits no event; the watchdog
 *   calls the explicit holds recompute instead, the archive/landing
 *   precedent. An emitted milestone event every throttle interval would be
 *   renderer churn carrying nothing.
 */

const THROTTLE_MS = 60 * 1000
const TICK_MS = 30 * 1000

interface TrackedRun {
  kind: 'milestone' | 'loop'
  /** In-memory truth; the persisted stamp trails it by at most the throttle. */
  lastActivityAt: number
  persistedAt: number
  /** One inspection per episode; cleared when activity resumes. */
  inspected: boolean
}

export class LivenessWatchdog {
  private readonly runs = new Map<Id, TrackedRun>()
  private timer: NodeJS.Timeout | null = null

  constructor(
    private readonly deps: {
      repo: Repo
      /** The explicit holds recompute — Manager.holdsChanged. */
      holdsChanged: () => void
      /** Fire-and-forget deep inspection; the watchdog never awaits it. */
      inspectMilestone: (milestoneId: Id) => void
      now?: () => number
      stallAfterMs?: number
    },
  ) {}

  private now(): number {
    return (this.deps.now ?? Date.now)()
  }

  private stallAfter(): number {
    return this.deps.stallAfterMs ?? STALL_AFTER_MS
  }

  start(): void {
    if (this.timer) return
    this.timer = setInterval(() => this.tick(), TICK_MS)
    this.timer.unref?.()
  }

  dispose(): void {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  /**
   * Observes the event stream. Sits in front of the holds engine in the
   * Manager's emit chain; it only reads, never swallows.
   */
  readonly observe = (event: AppEvent): void => {
    switch (event.type) {
      case 'plan.activity':
        this.touch(event.milestoneId, 'milestone')
        return
      case 'loop.activity':
        this.touch(event.loopId, 'loop')
        return
      // Tracking begins at the transition into flight — a run that hangs at
      // spawn produces zero activity events, and seeding from the transition
      // is what lets the tick catch it.
      case 'plan.milestone': {
        const inFlight = ['executing', 'testing', 'reviewing'].includes(event.milestone.status)
        if (inFlight) this.ensure(event.milestone.id, 'milestone')
        else this.forget(event.milestone.id)
        return
      }
      case 'loop.status': {
        if (event.status === 'running') this.ensure(event.loopId, 'loop')
        else if (event.status !== 'paused') this.forget(event.loopId)
        return
      }
      default:
        return
    }
  }

  private ensure(id: Id, kind: TrackedRun['kind']): void {
    if (this.runs.has(id)) return
    const now = this.now()
    this.runs.set(id, { kind, lastActivityAt: now, persistedAt: 0, inspected: false })
    this.persist(id, now)
  }

  private forget(id: Id): void {
    this.runs.delete(id)
  }

  private touch(id: Id, kind: TrackedRun['kind']): void {
    const run = this.runs.get(id)
    if (!run) {
      this.ensure(id, kind)
      return
    }
    const now = this.now()
    const wasStalled = now - run.lastActivityAt > this.stallAfter()
    run.lastActivityAt = now
    // Persist immediately when a stall just ended — the derived hold clears on
    // the next recompute — and on the throttle otherwise.
    if (wasStalled || now - run.persistedAt >= THROTTLE_MS) {
      this.persist(id, now)
    }
    if (wasStalled) {
      run.inspected = false
      this.deps.holdsChanged()
    }
  }

  private persist(id: Id, at: number): void {
    const run = this.runs.get(id)
    if (!run) return
    run.persistedAt = at
    if (run.kind === 'loop') {
      this.deps.repo.setLoopActivity(id, at)
      return
    }
    const state = this.deps.repo.getMilestoneRunState<RunState>(id)
    if (!state) return
    this.deps.repo.setMilestoneRunState(id, { ...state, lastActivityAt: at })
  }

  /** One pass: surface anything newly stalled. Public for tests. */
  tick(): void {
    const now = this.now()
    for (const [id, run] of this.runs) {
      if (now - run.lastActivityAt <= this.stallAfter()) continue
      // The recompute derives the hold from the naturally-frozen stamp; the
      // tick only announces that it is time to look.
      this.deps.holdsChanged()
      if (run.kind === 'milestone' && !run.inspected) {
        run.inspected = true
        this.deps.inspectMilestone(id)
      }
    }
  }
}
