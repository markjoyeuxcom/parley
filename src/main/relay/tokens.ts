import { randomBytes, timingSafeEqual } from 'node:crypto'
import type { Id } from '@shared/domain'

/**
 * One relay credential per pane, so the sender is derived rather than claimed.
 *
 * Every pane used to hold the same token, and the endpoint took the sender's
 * identity from an `X-Parley-From` header, checking only that *some* live pane
 * had that id. So a pane holding the shared token could post as its neighbour
 * — and the ids are not secret from an agent, because the refusal for an
 * ambiguous target lists them.
 *
 * The harm ceiling was modest: a wrong name above text that a person still has
 * to press Enter on. But attribution is the only thing telling a reader that
 * words came from another model, and the fix is smaller than the argument. A
 * credential that *is* the identity removes the question instead of validating
 * it, and `X-Parley-From` stops existing.
 */
export class RelayTokens {
  private readonly byPane = new Map<Id, string>()

  /** Replaces any existing credential, so a reused pane id cannot inherit one. */
  mint(paneId: Id): string {
    const token = randomBytes(24).toString('hex')
    this.byPane.set(paneId, token)
    return token
  }

  /** A closed pane's credential stops working; it is not left to age out. */
  forget(paneId: Id): void {
    this.byPane.delete(paneId)
  }

  /**
   * Which pane presented this credential, or null.
   *
   * Every candidate is compared in full, and the loop does not stop at the
   * first match, so the work does not depend on which pane matched or on how
   * far down the list it sat.
   */
  paneFor(presented: string): Id | null {
    const given = Buffer.from(presented)
    let found: Id | null = null
    for (const [paneId, token] of this.byPane) {
      const known = Buffer.from(token)
      if (given.length === known.length && timingSafeEqual(given, known)) found = paneId
    }
    return found
  }

  /** For tests, and for a fixture that needs to know how many are live. */
  get size(): number {
    return this.byPane.size
  }
}
