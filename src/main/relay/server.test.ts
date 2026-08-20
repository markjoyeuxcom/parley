import { afterEach, describe, expect, it, vi } from 'vitest'
import { startRelayServer, type RelayServer } from './server'

const panes = [
  { id: 'a', kind: 'claude', title: 'claude — repo', status: 'live' },
  { id: 'b', kind: 'codex', title: 'codex — repo', status: 'live' },
] as never[]

let running: RelayServer | null = null
afterEach(() => { running?.close(); running = null })

/** Pane 'a''s credential. Pane 'b' holds a different one it never learns. */
const TOKEN_A = 'token-for-pane-a'
const TOKEN_B = 'token-for-pane-b'

const start = async (paste = vi.fn()) => {
  running = await startRelayServer({
    panes: () => panes,
    paste,
    nameOf: (id) => (id === 'a' ? 'claude' : 'codex'),
    paneForToken: (token) =>
      token === TOKEN_A ? 'a' : token === TOKEN_B ? 'b' : null,
  })
  return running
}

describe('the relay endpoint', () => {
  it('delivers a raw-body relay from a pane', async () => {
    const paste = vi.fn()
    const server = await start(paste)
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST',
      headers: { authorization: `Bearer ${TOKEN_A}` },
      body: 'line one\nline two',
    })
    expect(res.status).toBe(200)
    expect((await res.json() as { submitted: boolean }).submitted).toBe(false)
    // The body is taken raw, so a model's quotes and newlines need no escaping
    // by the shell script that sent them.
    expect((paste.mock.calls[0] as [string, string])[1]).toContain('line one\nline two')
  })

  it('refuses without the token', async () => {
    const paste = vi.fn()
    const server = await start(paste)
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST', headers: { 'x-parley-from': 'a' }, body: 'hi',
    })
    expect(res.status).toBe(401)
    expect(paste).not.toHaveBeenCalled()
  })

  it('refuses a wrong token of the same length', async () => {
    const server = await start()
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST',
      headers: { authorization: `Bearer ${'0'.repeat(TOKEN_A.length)}` },
      body: 'hi',
    })
    expect(res.status).toBe(401)
  })

  it('attributes to the credential, not to whatever the caller claims', async () => {
    // Every pane used to hold the same token and the endpoint read the sender
    // from `X-Parley-From`, checking only that some live pane had that id — so
    // a pane could post as its neighbour, and the ids are not secret from an
    // agent because the ambiguous-target refusal lists them.
    const paste = vi.fn()
    const server = await start(paste)
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${TOKEN_A}`,
        // A lie. Pane 'b' is a real live pane, and it is not the caller.
        'x-parley-from': 'b',
      },
      body: 'whose words are these',
    })

    expect(res.status).toBe(200)
    const [, text] = paste.mock.calls[0] as [string, string]
    // 'a' is claude; 'b' is codex. The header must have changed nothing.
    expect(text.startsWith('claude said:')).toBe(true)
    expect(text).not.toContain('codex said:')
  })

  it('refuses a credential whose pane has gone', async () => {
    const server = await start()
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST',
      headers: { authorization: 'Bearer token-for-a-pane-that-closed' },
      body: 'hi',
    })
    expect(res.status).toBe(401)
  })

  it('answers nothing else', async () => {
    const server = await start()
    const get = await fetch(`${server.url}/relay?to=codex`)
    expect(get.status).toBe(404)
    const other = await fetch(`${server.url}/anything`, { method: 'POST' })
    expect(other.status).toBe(404)
  })

  it('listens on loopback only', async () => {
    const server = await start()
    expect(server.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+$/)
  })
})
