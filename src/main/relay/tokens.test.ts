import { describe, expect, it } from 'vitest'
import { RelayTokens } from './tokens'

/**
 * The registry that makes the relay's sender derivable.
 *
 * Every pane used to hold the same token, and the endpoint read the sender
 * from an `X-Parley-From` header, checking only that some live pane had that
 * id — so a pane could post as its neighbour, and the ids are not secret from
 * an agent because the ambiguous-target refusal lists them.
 */

describe('one credential per pane', () => {
  it('resolves a credential back to the pane that holds it', () => {
    const tokens = new RelayTokens()
    const a = tokens.mint('pane-a')
    const b = tokens.mint('pane-b')

    expect(tokens.paneFor(a)).toBe('pane-a')
    expect(tokens.paneFor(b)).toBe('pane-b')
    expect(a).not.toBe(b)
  })

  it('gives every pane a different credential', () => {
    const tokens = new RelayTokens()
    const minted = new Set(Array.from({ length: 16 }, (_, i) => tokens.mint(`pane-${i}`)))
    expect(minted.size).toBe(16)
  })

  it('refuses anything it did not mint', () => {
    const tokens = new RelayTokens()
    const real = tokens.mint('pane-a')

    expect(tokens.paneFor('')).toBeNull()
    expect(tokens.paneFor('0'.repeat(real.length))).toBeNull()
    // A correct prefix is worth nothing.
    expect(tokens.paneFor(real.slice(0, -1))).toBeNull()
    expect(tokens.paneFor(`${real}x`)).toBeNull()
  })

  it('stops honouring a closed pane, rather than letting it age out', () => {
    const tokens = new RelayTokens()
    const a = tokens.mint('pane-a')
    tokens.forget('pane-a')

    expect(tokens.paneFor(a)).toBeNull()
    expect(tokens.size).toBe(0)
  })

  it('replaces a credential rather than leaving two live for one pane', () => {
    // A reused pane id must not inherit the previous occupant's credential.
    const tokens = new RelayTokens()
    const first = tokens.mint('pane-a')
    const second = tokens.mint('pane-a')

    expect(tokens.paneFor(second)).toBe('pane-a')
    expect(tokens.paneFor(first)).toBeNull()
    expect(tokens.size).toBe(1)
  })
})
