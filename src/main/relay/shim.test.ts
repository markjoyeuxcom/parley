import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { installShim } from './shim'

const dirs: string[] = []
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }) })

const install = (): string => {
  const dir = mkdtempSync(join(tmpdir(), 'parley-shim-'))
  dirs.push(dir)
  return installShim(dir)
}

describe('the parley shim', () => {
  it('is a valid shell script and executable', () => {
    const bin = join(install(), 'parley')
    // Parsed by the real sh, not eyeballed: a syntax error here would only
    // ever surface inside somebody's pane.
    execFileSync('/bin/sh', ['-n', bin])
    expect(statSync(bin).mode & 0o111).toBeTruthy()
  })

  it('refuses politely outside a pane, instead of erroring obscurely', () => {
    const bin = join(install(), 'parley')
    let stderr = ''
    try {
      execFileSync('/bin/sh', [bin, 'relay', 'codex', 'hi'], { env: { PATH: '/usr/bin:/bin' } })
    } catch (err) {
      stderr = String((err as { stderr?: Buffer }).stderr ?? '')
    }
    expect(stderr).toMatch(/not running inside a Parley pane/)
  })

  it('terminates when given no message, instead of blocking on stdin', () => {
    // `parley relay codex` with nothing to say used to fall into `cat` and
    // wait forever — an agent hanging its own shell. Guarded with `[ -t 0 ]`
    // for a real terminal; here stdin is /dev/null, which proves the other
    // half: it reads to EOF and finishes rather than waiting.
    const bin = join(install(), 'parley')
    let finished = false
    try {
      execFileSync('/bin/sh', [bin, 'relay', 'codex'], {
        env: { PATH: '/usr/bin:/bin', PARLEY_RELAY_URL: 'http://127.0.0.1:1', PARLEY_RELAY_TOKEN: 't' },
        stdio: ['ignore', 'pipe', 'pipe'],
        timeout: 5_000,
      })
      finished = true
    } catch (err) {
      // A non-zero exit is fine — the port is closed. A timeout is not.
      finished = (err as { signal?: string }).signal !== 'SIGTERM'
    }
    expect(finished).toBe(true)
  })

  it('explains itself when misused', () => {
    const bin = join(install(), 'parley')
    let stderr = ''
    try {
      execFileSync('/bin/sh', [bin], { env: { PATH: '/usr/bin:/bin' } })
    } catch (err) {
      stderr = String((err as { stderr?: Buffer }).stderr ?? '')
    }
    expect(stderr).toMatch(/usage: parley relay/)
  })
})
