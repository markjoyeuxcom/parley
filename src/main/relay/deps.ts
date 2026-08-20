import type { Id, Pane } from '@shared/domain'
import type { RelayDeps } from './handle'

/**
 * What the relay endpoint is allowed to do to a pane.
 *
 * A function rather than an object literal in `index.ts`, because the safety
 * property of the entire feature lives in one line of it — `pasteOnly`, not
 * `paste` — and that line was untested. Every relay test passed a mock, so
 * swapping in the submitting variant would have left the suite green while
 * giving an agent the ability to press Enter in another agent's session.
 *
 * The narrow surface is the point: the endpoint gets exactly these three
 * things and no route to a pty otherwise.
 */
export interface RelayPty {
  list: () => Pane[]
  get: (id: Id) => Pane | null
  /** Lands in the prompt and waits for a person. The only writer offered here. */
  pasteOnly: (paneId: Id, text: string) => void
  /** Present so the test can prove it is never reached. */
  paste?: (paneId: Id, text: string) => void
  /** One credential per pane; see relay/tokens.ts. */
  paneForToken: (token: string) => Id | null
}

export function relayDepsFor(pty: RelayPty): RelayDeps {
  return {
    panes: () => pty.list(),
    paneForToken: (token) => pty.paneForToken(token),
    paste: (paneId, text) => pty.pasteOnly(paneId, text),
    nameOf: (paneId) => {
      const pane = pty.get(paneId)
      // No fallback to the id. Falling through to whatever string arrived is
      // how a forged `X-Parley-From` became "System Admin said:"; a sender
      // that is not a pane is refused before this, and anything else that
      // slips through gets a name that claims nothing.
      return pane ? pane.title.trim() || pane.kind : 'an unknown pane'
    },
  }
}
