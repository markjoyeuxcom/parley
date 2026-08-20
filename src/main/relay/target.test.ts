import { describe, expect, it } from 'vitest'
import { resolveRelayTarget } from './target'

const pane = (id: string, kind: string, over = {}) =>
  ({ id, kind, title: `${kind} — repo`, status: 'live', ...over }) as never

describe('which pane an agent means', () => {
  const panes = [pane('a', 'claude'), pane('b', 'codex'), pane('c', 'agy')]

  it('takes a vendor name when exactly one is running', () => {
    expect(resolveRelayTarget(panes, 'codex', 'a')).toEqual({ ok: true, paneId: 'b' })
    expect(resolveRelayTarget(panes, 'AGY', 'a')).toEqual({ ok: true, paneId: 'c' })
  })

  it('takes a pane id outright', () => {
    expect(resolveRelayTarget(panes, 'c', 'a')).toEqual({ ok: true, paneId: 'c' })
  })

  it('refuses to guess between two of the same vendor', () => {
    // Picking one silently would send somebody's work to the wrong agent, and
    // the sender cannot see which pane it went to.
    const two = [...panes, pane('d', 'codex')]
    const out = resolveRelayTarget(two, 'codex', 'a')
    expect(out.ok).toBe(false)
    expect(out.ok === false && out.error).toMatch(/two panes|b.*d|ambiguous/i)
  })

  it('will not relay to itself', () => {
    const out = resolveRelayTarget(panes, 'claude', 'a')
    expect(out.ok).toBe(false)
    expect(out.ok === false && out.error).toMatch(/itself|own pane/i)
  })

  it('names what is available when the target is unknown', () => {
    const out = resolveRelayTarget(panes, 'gemini', 'a')
    expect(out.ok).toBe(false)
    expect(out.ok === false && out.error).toContain('codex')
  })

  it('refuses a pane that is not live', () => {
    const dead = [pane('a', 'claude'), pane('b', 'codex', { status: 'exited' })]
    expect(resolveRelayTarget(dead, 'codex', 'a').ok).toBe(false)
    const booting = [pane('a', 'claude'), pane('b', 'codex', { status: 'starting' })]
    expect(resolveRelayTarget(booting, 'codex', 'a').ok).toBe(false)
  })

  it('refuses a shell, which has no conversation to receive one', () => {
    const withShell = [pane('a', 'claude'), pane('s', 'shell')]
    expect(resolveRelayTarget(withShell, 'shell', 'a').ok).toBe(false)
  })
})
