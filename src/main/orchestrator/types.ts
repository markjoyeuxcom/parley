import type { AppEvent } from '@shared/events'
import type { AgentRegistry } from '@main/agents'
import type { Repo } from '@main/store/repo'

export interface OrchestratorDeps {
  repo: Repo
  registry: AgentRegistry
  emit: (event: AppEvent) => void
  /**
   * Native notification hook, injected by the entrypoint so the orchestrator
   * never imports Electron (tests cannot load it). Optional: absent in tests,
   * and holds still publish and persist — the banner is supplementary.
   */
  notifyUser?: (title: string, body: string) => void
}

/**
 * A cooperative pause/stop gate.
 *
 * Pause takes effect at the next turn boundary rather than mid-request: killing
 * a CLI mid-turn would waste the tokens already spent on it and leave the
 * vendor-side session in a state we cannot resume cleanly. Stop is the escape
 * hatch that does kill in flight, because the user asking to stop outranks
 * tidiness.
 */
export class RunGate {
  private paused = false
  private stopped = false
  private waiters: Array<() => void> = []
  readonly controller = new AbortController()

  get isStopped(): boolean {
    return this.stopped
  }

  get isPaused(): boolean {
    return this.paused
  }

  get signal(): AbortSignal {
    return this.controller.signal
  }

  pause(): void {
    if (!this.stopped) this.paused = true
  }

  resume(): void {
    this.paused = false
    const waiting = this.waiters
    this.waiters = []
    for (const resolve of waiting) resolve()
  }

  stop(): void {
    this.stopped = true
    this.paused = false
    this.resume()
    this.controller.abort()
  }

  /** Resolves when it is safe to start the next unit of work. */
  async wait(): Promise<void> {
    while (this.paused && !this.stopped) {
      await new Promise<void>((resolve) => this.waiters.push(resolve))
    }
  }
}
