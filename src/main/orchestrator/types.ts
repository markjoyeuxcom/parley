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
  /**
   * Holds off idle sleep while unattended work runs, injected for the same
   * Electron-free reason as notifyUser. Returns a release function. Honest
   * limit, stated where users read it: this defers IDLE sleep only — a
   * closed lid still suspends the machine, and the run parks for the
   * recovery machinery to pick up on wake.
   */
  keepAwake?: (reason: string) => () => void
  /**
   * Where per-plan execution worktrees live — under userData in the app, a
   * tmpdir in tests. Injected for the same Electron-free reason as notifyUser.
   * Optional because only worktree-isolation plans need it; running one
   * without it is a refusal, not a fallback to the live checkout.
   */
  worktreesRoot?: string
  /**
   * The checkout this running app was built from — the repository Parley
   * must treat as itself. Null when packaged (or in tests that don't care):
   * every self rule stays dormant. Injected raw; the Manager canonicalises
   * it once, so every comparison is canonical-to-canonical.
   */
  selfRepoPath?: string | null
  /**
   * This build's own root — `app.getAppPath()`, packaged or not.
   *
   * Distinct from {@link OrchestratorDeps.selfRepoPath}, which is null when
   * packaged because there is no checkout to treat as a repository. This one
   * is never null, because a packaged build still ships the remote runner and
   * still has to find it. Conflating them is what left remote execution
   * usable only from a dev checkout.
   */
  appPath?: string | null
  /**
   * Parley's own record directory. Injected only so the workspace creator can
   * refuse to scaffold inside it — the app's record is not a place for the
   * user's projects.
   */
  userDataPath?: string | null
  /**
   * The devcontainer CLI to route container-snapshot commands through — a
   * shim in tests, omitted in the app so PATH resolution applies. Injected
   * because the routing must be provable without docker.
   */
  devcontainerBinary?: string
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
