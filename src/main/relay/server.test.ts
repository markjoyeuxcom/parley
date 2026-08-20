import { afterEach, describe, expect, it, vi } from 'vitest'
import { startRelayServer, type RelayServer } from './server'

const panes = [
  { id: 'a', kind: 'claude', title: 'claude — repo', status: 'live' },
  { id: 'b', kind: 'codex', title: 'codex — repo', status: 'live' },
] as never[]

let running: RelayServer | null = null
afterEach(() => { running?.close(); running = null })

const start = async (paste = vi.fn()) => {
  running = await startRelayServer({
    panes: () => panes,
    paste,
    nameOf: (id) => (id === 'a' ? 'claude' : 'codex'),
  })
  return running
}

describe('the relay endpoint', () => {
  it('delivers a raw-body relay from a pane', async () => {
    const paste = vi.fn()
    const server = await start(paste)
    const res = await fetch(`${server.url}/relay?to=codex`, {
      method: 'POST',
      headers: { authorization: `Bearer ${server.token}`, 'x-parley-from': 'a' },
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
      headers: { authorization: `Bearer ${'0'.repeat(server.token.length)}`, 'x-parley-from': 'a' },
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
