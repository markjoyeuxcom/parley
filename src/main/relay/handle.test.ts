import { describe, expect, it, vi } from 'vitest'
import { handleRelay } from './handle'

const panes = [
  { id: 'a', kind: 'claude', title: 'claude — repo', status: 'live' },
  { id: 'b', kind: 'codex', title: 'codex — repo', status: 'live' },
] as never[]

const deps = (paste = vi.fn()) => ({
  panes: () => panes,
  paste,
  nameOf: (id: string) => (id === 'a' ? 'claude' : 'codex'),
})

describe('an agent asking to relay', () => {
  it('pastes into the named pane, attributed, without pressing Enter', () => {
    const paste = vi.fn()
    const out = handleRelay({ from: 'a', to: 'codex', text: 'hello' }, deps(paste))
    expect(out.status).toBe(200)
    expect(paste).toHaveBeenCalledTimes(1)
    const [paneId, text] = paste.mock.calls[0] as [string, string]
    expect(paneId).toBe('b')
    // Attributed, like every other relay: the receiving CLI has no idea where
    // this came from, and unattributed text reads as the user's own words.
    expect(text).toContain('claude')
    expect(text).toContain('hello')
  })

  it('refuses an unknown target and says what is open', () => {
    const paste = vi.fn()
    const out = handleRelay({ from: 'a', to: 'gemini', text: 'hi' }, deps(paste))
    expect(out.status).toBe(400)
    expect(out.body.ok === false && out.body.error).toContain('codex')
    expect(paste).not.toHaveBeenCalled()
  })

  it('refuses a request that is not shaped like one', () => {
    expect(handleRelay({ to: 'codex' }, deps()).status).toBe(400)
    expect(handleRelay({ from: 'a', to: 'codex', text: '   ' }, deps()).status).toBe(400)
    expect(handleRelay('nonsense', deps()).status).toBe(400)
  })

  it('bounds the payload, since it arrives over a socket', () => {
    const out = handleRelay({ from: 'a', to: 'codex', text: 'x'.repeat(200_000) }, deps())
    expect(out.status).toBe(400)
    expect(out.body.ok === false && out.body.error).toMatch(/too (long|large)/i)
  })

  it('reports a paste that failed rather than claiming success', () => {
    const paste = vi.fn(() => { throw new Error('the pane is no longer live') })
    const out = handleRelay({ from: 'a', to: 'codex', text: 'hi' }, deps(paste))
    expect(out.status).toBe(409)
    expect(out.body.ok === false && out.body.error).toContain('no longer live')
  })

  it('tells the caller it was not submitted, because that is the contract', () => {
    const out = handleRelay({ from: 'a', to: 'codex', text: 'hi' }, deps())
    expect(JSON.stringify(out.body)).toMatch(/not sent|awaiting|press|confirm/i)
  })
})
