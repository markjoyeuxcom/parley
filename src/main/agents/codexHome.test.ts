import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { prepareIsolatedCodexHome, realCodexHome } from './codexHome'

/**
 * Codex loads MCP servers from its config directory whatever sandbox mode it
 * is given, so a seat dispatched as `read` could reach any tool the user had
 * configured — on the machine this was found on, one of them drove the
 * computer. The fix is a config directory with none declared.
 */

const made: string[] = []
function scratch(): string {
  const dir = mkdtempSync(join(tmpdir(), 'parley-codex-'))
  made.push(dir)
  return dir
}
afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

describe('the isolated Codex home', () => {
  it('declares no MCP servers', () => {
    const home = prepareIsolatedCodexHome(join(scratch(), 'codex-home'), scratch())
    const config = readFileSync(join(home.path, 'config.toml'), 'utf8')
    // The whole point. `codex mcp list` under this directory reports none.
    expect(config).not.toContain('[mcp_servers')
    expect(config).toContain('declares no MCP servers')
  })

  it('links the real credentials rather than copying them', () => {
    const real = scratch()
    writeFileSync(join(real, 'auth.json'), '{"token":"not-a-real-token"}', 'utf8')

    const home = prepareIsolatedCodexHome(join(scratch(), 'codex-home'), real)
    const link = join(home.path, 'auth.json')

    expect(home.authLinked).toBe(true)
    // A link, not a copy: signing out in the user's own Codex has to govern
    // Parley's seats too, and a second copy of a token is a second thing to
    // leak.
    expect(lstatSync(link).isSymbolicLink()).toBe(true)
    expect(readFileSync(link, 'utf8')).toContain('not-a-real-token')
  })

  it('says so when there are no credentials to link', () => {
    // Honest rather than fatal: the seat will report it cannot sign in, and
    // the app logs why before it does.
    const home = prepareIsolatedCodexHome(join(scratch(), 'codex-home'), scratch())
    expect(home.authLinked).toBe(false)
    expect(existsSync(join(home.path, 'auth.json'))).toBe(false)
  })

  it('replaces what an earlier launch left behind', () => {
    // A stale config from an older build must never govern a seat, and a link
    // to an account the user has since signed out of is a confusing failure.
    const dir = join(scratch(), 'codex-home')
    const stale = scratch()
    writeFileSync(join(stale, 'auth.json'), '{"token":"old"}', 'utf8')
    prepareIsolatedCodexHome(dir, stale)

    mkdirSync(dir, { recursive: true })
    writeFileSync(join(dir, 'config.toml'), '[mcp_servers.sneaky]\ncommand="x"\n', 'utf8')

    const fresh = scratch()
    writeFileSync(join(fresh, 'auth.json'), '{"token":"new"}', 'utf8')
    const home = prepareIsolatedCodexHome(dir, fresh)

    expect(readFileSync(join(home.path, 'config.toml'), 'utf8')).not.toContain('sneaky')
    expect(readFileSync(join(home.path, 'auth.json'), 'utf8')).toContain('new')
  })
})

describe('finding the real home', () => {
  it('honours CODEX_HOME when the user has set one', () => {
    expect(realCodexHome({ CODEX_HOME: '/somewhere/else' })).toBe('/somewhere/else')
  })

  it('falls back to ~/.codex', () => {
    expect(realCodexHome({})).toMatch(/\.codex$/)
  })
})
