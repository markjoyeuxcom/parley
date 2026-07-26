import type { AgentConfig, Capability, Usage, Vendor } from '@shared/domain'
import type { CliHealth } from '@shared/ipc'

export interface RunRequest {
  /** Role and protocol instructions. How this is applied is vendor-specific. */
  systemPrompt: string
  /** The turn's actual prompt. */
  prompt: string
  cfg: AgentConfig
  capability: Capability
  /** Working directory for the process. Also the repository root when attached. */
  cwd: string
  /**
   * Vendor session/thread id to resume. Resuming is what keeps cost linear:
   * the CLI retains its own history, so Parley relays only the opponent's last
   * message rather than replaying the transcript.
   */
  resumeId?: string | null
  signal?: AbortSignal
  timeoutMs?: number
  /** Live text as it arrives, where the vendor supports streaming. */
  onDelta?: (text: string) => void
  /** Coarse progress for the UI, e.g. "reading src/index.ts". */
  onActivity?: (activity: string) => void
}

export interface RunResult {
  text: string
  usage: Usage
  /** Session/thread id to pass as `resumeId` next turn, if the vendor gave one. */
  resumeId: string | null
  exitCode: number
  /** Populated when the run failed or was cut short. */
  error: string | null
}

export interface AgentAdapter {
  readonly vendor: Vendor
  readonly binary: string
  run(req: RunRequest): Promise<RunResult>
  probe(): Promise<CliHealth>
}

/** Thrown when a caller asks for a capability the governance rules forbid. */
export class CapabilityError extends Error {}

/**
 * Guards the one escalation that matters.
 *
 * `write` is reachable only when the caller has already consumed a recorded
 * approval; the orchestrator passes `approved` to prove it. This is belt and
 * braces alongside the store's single-use check — the adapter is the last place
 * a write could slip through, so it refuses on its own account.
 */
export function assertCapability(capability: Capability, approved: boolean): void {
  if (capability === 'write' && !approved) {
    throw new CapabilityError(
      'write capability requires a recorded, unconsumed human approval; refusing to spawn',
    )
  }
}
