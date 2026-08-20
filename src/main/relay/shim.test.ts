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
