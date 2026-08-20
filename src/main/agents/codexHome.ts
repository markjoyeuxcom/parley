import { existsSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * A Codex configuration directory with no tools in it.
 *
 * Claude's adapter passes `--strict-mcp-config`, so a governed seat gets only
 * the tools Parley names. Codex's adapter set `sandbox_mode` and nothing else,
 * and Codex loads MCP servers from `~/.codex/config.toml` regardless — so a
 * seat dispatched as `read` could still reach any server the user happens to
 * have configured. On this machine that included one called `computer-use`.
 * A filesystem sandbox has no opinion about a tool that drives the computer,
 * and the room header would still have said "read".
 *
 * `-c mcp_servers={}` looked like the cheap fix and does not work: `codex mcp
 * list` reports the same servers with and without it. What does work is
 * pointing `CODEX_HOME` at a directory whose `config.toml` declares none —
 * verified against codex-cli 0.148.0, where the isolated home lists no servers
 * at all.
 *
 * Authentication lives in the same directory, which is the part that makes
 * this fiddly rather than obvious: an isolated home with no `auth.json` is a
 * seat that cannot sign in. The real credentials are linked rather than
 * copied, so signing in or out in the user's own Codex still governs Parley's
 * seats, and no second copy of a token exists to go stale or leak.
 *
 * This is for governed dispatch only. A codex *pane* is the person running
 * their own CLI in their own terminal, and it keeps their configuration —
 * taking their tools away there would be Parley deciding how they work.
 */

/** Where the user's real Codex configuration lives. */
export function realCodexHome(env: NodeJS.ProcessEnv = process.env): string {
  const explicit = env['CODEX_HOME']?.trim()
  return explicit && explicit.length > 0 ? explicit : join(homedir(), '.codex')
}

const CONFIG = `# Written by Parley. Do not edit — it is replaced on every launch.
#
# This is the configuration a room seat runs under. It declares no MCP servers
# on purpose: a seat dispatched as "read" must not be able to reach a tool that
# writes, and Codex's filesystem sandbox does not constrain what an MCP server
# does. The user's own configuration is untouched and still governs their panes.
`

export interface IsolatedHome {
  path: string
  /** False when the user is not signed in to Codex at all; the seat will say so. */
  authLinked: boolean
}

/**
 * Builds the directory and returns it. Rewritten every launch, like the relay
 * shim, so a config left behind by an older build cannot govern a seat.
 */
export function prepareIsolatedCodexHome(
  dir: string,
  real: string = realCodexHome(),
): IsolatedHome {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'config.toml'), CONFIG, 'utf8')

  const link = join(dir, 'auth.json')
  const source = join(real, 'auth.json')
  // Replaced rather than left in place: the user may have signed in to a
  // different account since, and a stale link is a confusing failure.
  rmSync(link, { force: true })

  if (!existsSync(source)) return { path: dir, authLinked: false }
  try {
    symlinkSync(source, link)
    return { path: dir, authLinked: true }
  } catch {
    // A filesystem without symlinks, or a race with another launch. Copying
    // the credential instead would leave a second copy of a token on disk,
    // which is worse than a seat that reports it cannot sign in.
    return { path: dir, authLinked: false }
  }
}
