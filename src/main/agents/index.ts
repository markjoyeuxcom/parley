import type { Vendor } from '@shared/domain'
import type { CliHealth } from '@shared/ipc'
import { ClaudeAdapter } from './claude'
import { CodexAdapter } from './codex'
import { MockAdapter } from './mock'
import type { AgentAdapter } from './types'

export * from './types'
export { ClaudeAdapter } from './claude'
export { CodexAdapter } from './codex'
export { MockAdapter } from './mock'

/**
 * Adapter registry.
 *
 * `PARLEY_MOCK=1` swaps in the deterministic adapters so the app can be driven
 * end-to-end without spending subscription quota.
 */
export class AgentRegistry {
  private readonly adapters: Record<Vendor, AgentAdapter>

  /**
   * True when the deterministic adapters are in use.
   *
   * Exposed rather than kept private because the rest of the app has to be able
   * to say so out loud. A mock run produces verdicts, findings and reviews that
   * are structurally identical to real ones — and a stored record that cannot be
   * distinguished from a real one would undermine the only thing this tool
   * actually sells.
   */
  readonly mock: boolean

  constructor(mock = process.env['PARLEY_MOCK'] === '1') {
    this.mock = mock
    this.adapters = mock
      ? { claude: new MockAdapter('claude'), codex: new MockAdapter('codex') }
      : { claude: new ClaudeAdapter(), codex: new CodexAdapter() }
  }

  get(vendor: Vendor): AgentAdapter {
    return this.adapters[vendor]
  }

  /**
   * Picks a vendor different from `from` where possible.
   *
   * Cross-vendor independence is the point of the whole design: a reviewer that
   * shares a model family with the thing it reviews shares its blind spots.
   */
  counterpart(from: Vendor): Vendor {
    return from === 'claude' ? 'codex' : 'claude'
  }

  async probeAll(): Promise<CliHealth[]> {
    return Promise.all([this.adapters.claude.probe(), this.adapters.codex.probe()])
  }
}
