import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { startRelayServer, type RelayServer } from './server'
import { installShim } from './shim'

/**
 * The command an agent actually runs, against the server that actually
 * answers. Everything else here tests a half.
 */
// Async, always. execFileSync blocks the event loop, so the server running in
// this same process could never answer the curl it had just spawned.
const run = promisify(execFile)

const panes = [
  { id: 'a', kind: 'claude', title: 'claude — repo', status: 'live' },
  { id: 'b', kind: 'codex', title: 'codex — repo', status: 'live' },
] as never[]

let server: RelayServer | null = null
const dirs: string[] = []
/** Pane 'a''s relay credential. Pane 'b' would hold a different one. */
const TOKEN_A = 'token-for-pane-a'

afterEach(() => {
  server?.close(); server = null
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true })
})

async function shell(paste = vi.fn()): Promise<{ bin: string; env: Record<string, string>; paste: typeof paste }> {
  server = await startRelayServer({
    panes: () => panes,
    paste,
    nameOf: (id) => (id === 'a' ? 'claude' : 'codex'),
    // The credential is the identity now: this one belongs to pane 'a'.
    paneForToken: (token) => (token === TOKEN_A ? 'a' : null),
  })
  const dir = mkdtempSync(join(tmpdir(), 'parley-e2e-'))
  dirs.push(dir)
  const binDir = installShim(dir)
  return {
    bin: join(binDir, 'parley'),
    env: {
      PATH: '/usr/bin:/bin',
      PARLEY_RELAY_URL: server.url,
      PARLEY_RELAY_TOKEN: TOKEN_A,
      PARLEY_PANE_ID: 'a',
    },
    paste,
  }
}

describe('parley relay, run as an agent would run it', () => {
  it('carries an argument message into the other pane', async () => {
    const { bin, env, paste } = await shell()
    const { stdout } = await run('/bin/sh', [bin, 'relay', 'codex', 'have a look at this'], { env })
    expect(JSON.parse(stdout)).toMatchObject({ ok: true, delivered: 'codex', submitted: false })
    const [paneId, text] = paste.mock.calls[0] as [string, string]
    expect(paneId).toBe('b')
    expect(text).toContain('have a look at this')
    expect(text).toContain('claude')
  })

  it('carries piped stdin, newlines and quotes intact', async () => {
    // The reason the body is raw rather than JSON: a model's output is full of
    // quotes, backticks and newlines, and escaping those from `sh` is a bug in
    // waiting.
    const { bin, env, paste } = await shell()
    const payload = 'line one\nsaid "hello" and `backticks`\n  indented'
    await run('/bin/sh', ['-c', `printf '%s' "$1" | "$2" relay codex`, 'sh', payload, bin], { env })
    expect((paste.mock.calls[0] as [string, string])[1]).toContain(payload)
  })

  it('reports a refusal from the server on stderr and exits non-zero', async () => {
    const { bin, env, paste } = await shell()
    let failed = false
    let output = ''
    try {
      await run('/bin/sh', [bin, 'relay', 'gemini', 'hi'], { env })
    } catch (err) {
      failed = true
      const e = err as { stdout?: string; stderr?: string }
      output = `${e.stdout ?? ''}${e.stderr ?? ''}`
    }
    expect(failed).toBe(true)
    expect(output).toContain('codex')
    expect(paste).not.toHaveBeenCalled()
  })

  it('cannot relay with the wrong token', async () => {
    const { bin, env, paste } = await shell()
    let failed = false
    try {
      await run('/bin/sh', [bin, 'relay', 'codex', 'hi'], { env: { ...env, PARLEY_RELAY_TOKEN: 'nope' } })
    } catch {
      failed = true
    }
    expect(failed).toBe(true)
    expect(paste).not.toHaveBeenCalled()
  })
})
