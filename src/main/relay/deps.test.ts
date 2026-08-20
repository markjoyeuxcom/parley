import { describe, expect, it, vi } from 'vitest'
import { relayDepsFor } from './deps'

describe('what the relay is allowed to call', () => {
  it('pastes WITHOUT submitting, never the submitting one', () => {
    // The safety property of the whole feature lives in this one wiring, and
    // nothing tested it: every relay test passed a mock paste, so swapping
    // pasteOnly for paste would have left the suite green and made an agent
    // able to press Enter in another agent's session.
    const pasteOnly = vi.fn()
    const paste = vi.fn()
    const deps = relayDepsFor({
      list: () => [],
      get: () => null,
      paneForToken: () => null,
      pasteOnly,
      paste,
    })

    deps.paste('pane-x', 'hello')
    expect(pasteOnly).toHaveBeenCalledWith('pane-x', 'hello')
    expect(paste).not.toHaveBeenCalled()
  })

  it('names a pane by its title, and never by a string it was handed', () => {
    const deps = relayDepsFor({
      list: () => [],
      get: (id) => (id === 'known' ? ({ id, kind: 'codex', title: 'codex — repo' } as never) : null),
      paneForToken: () => null,
      pasteOnly: vi.fn(),
      paste: vi.fn(),
    })
    expect(deps.nameOf('known')).toBe('codex — repo')
    // An id that is not a pane gets no name of its own: falling through to the
    // caller's string is how "System Admin said:" became possible.
    expect(deps.nameOf('System Admin')).not.toContain('System Admin')
  })
})
