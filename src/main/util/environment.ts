import { accessSync, constants, existsSync, readFileSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { delimiter, dirname, join } from 'node:path'
import { capture } from './spawn'

/**
 * Environment bootstrap.
 *
 * Two macOS-specific problems are solved here, both of which make the app look
 * completely broken when they bite:
 *
 *  1. **A GUI-launched app does not inherit your shell's PATH.** Finder, Dock and
 *     Spotlight start apps from `launchd`, which hands over a minimal
 *     `/usr/bin:/bin:/usr/sbin:/sbin`. Anything installed by Homebrew, npm -g,
 *     bun, mise or an install script lives outside that, so `claude` and `codex`
 *     are simply not findable — even though they work perfectly in Terminal.
 *
 *  2. **node-pty needs its `spawn-helper` binary on macOS.** It is a separate
 *     executable built alongside `pty.node`, and `pty.fork` hands its path to
 *     `posix_spawnp`. If it is missing or not executable, *every* spawn fails —
 *     including `/bin/zsh` — with the singularly unhelpful message
 *     "posix_spawnp failed."
 */

const require = createRequire(import.meta.url)

/** Directories these CLIs commonly install into, none of which launchd exports. */
function candidateDirs(): string[] {
  const home = homedir()
  return [
    '/opt/homebrew/bin',
    '/usr/local/bin',
    join(home, '.local', 'bin'),
    join(home, '.bun', 'bin'),
    join(home, '.deno', 'bin'),
    join(home, '.cargo', 'bin'),
    join(home, '.npm-global', 'bin'),
    join(home, '.volta', 'bin'),
    join(home, '.local', 'share', 'mise', 'shims'),
    join(home, '.claude', 'local'),
    join(home, '.codex', 'bin'),
    '/opt/homebrew/opt/node/bin',
  ]
}

const SENTINEL_START = '__PARLEY_PATH_START__'
const SENTINEL_END = '__PARLEY_PATH_END__'

/**
 * Asks the user's login shell what its PATH is.
 *
 * This is the one place the app runs a shell, and it is a deliberate exception
 * to the no-shell rule: the command is a fixed literal with nothing interpolated
 * into it, and the point is precisely to obtain the shell's own environment.
 * Output is sentinel-delimited because login rc files print banners, version
 * managers, motd and worse.
 */
async function queryLoginShellPath(): Promise<string | null> {
  const shell = process.env['SHELL']?.trim() || '/bin/zsh'
  if (!existsSync(shell)) return null

  const script = `command printf '${SENTINEL_START}%s${SENTINEL_END}' "$PATH"`

  // This runs before the window is created, so it is on the launch critical
  // path. A cold login shell is typically well under a second; the budget only
  // exists to stop a pathological rc file turning startup into a hang.
  const ATTEMPT_TIMEOUT_MS = 2500

  // `-ilc` first: plenty of people set PATH in .zshrc, which a non-interactive
  // login shell never reads. Fall back to `-lc` for shells that refuse `-i`
  // without a tty, then give up rather than hang.
  for (const flags of [['-ilc', script], ['-lc', script]]) {
    try {
      const result = await capture(shell, flags, homedir(), ATTEMPT_TIMEOUT_MS)
      const start = result.stdout.indexOf(SENTINEL_START)
      const end = result.stdout.indexOf(SENTINEL_END)
      if (start !== -1 && end > start) {
        const value = result.stdout.slice(start + SENTINEL_START.length, end).trim()
        if (value) return value
      }
    } catch {
      // Try the next form.
    }
  }
  return null
}

export interface PathResolution {
  path: string
  source: 'login-shell' | 'inherited'
  /** Directories added that the inherited PATH did not already have. */
  added: string[]
}

/**
 * Computes the PATH the app should actually use, and applies it to
 * `process.env.PATH`.
 *
 * Mutating the process environment is deliberate: every downstream spawn —
 * the CLI adapters, the deterministic test runner, node-pty — inherits it
 * automatically, so there is no way to add a spawn site that forgets to thread
 * the corrected PATH through.
 */
export async function applyResolvedPath(): Promise<PathResolution> {
  const inheritedDirs = (process.env['PATH'] ?? '').split(delimiter).filter(Boolean)
  const inherited = new Set(inheritedDirs)

  // One guarded insert for every source. A PATH can legitimately arrive with
  // duplicates — from the inherited value, from the login shell's own PATH, or
  // from the two overlapping — and every duplicate is a wasted stat on every
  // lookup thereafter.
  const ordered: string[] = []
  const seen = new Set<string>()
  const add = (dir: string): boolean => {
    if (!dir || seen.has(dir)) return false
    seen.add(dir)
    ordered.push(dir)
    return true
  }

  const added: string[] = []
  let source: PathResolution['source'] = 'inherited'

  if (process.platform === 'darwin' || process.platform === 'linux') {
    const shellPath = await queryLoginShellPath()
    if (shellPath) {
      source = 'login-shell'
      // Shell PATH goes first: it reflects the user's own precedence, including
      // version managers that shadow system binaries on purpose.
      for (const dir of shellPath.split(delimiter)) {
        if (add(dir) && !inherited.has(dir)) added.push(dir)
      }
    }
  }

  for (const dir of inheritedDirs) add(dir)

  // Belt and braces for the case where even the login shell missed something,
  // e.g. an installer that appended to a profile the shell does not read.
  for (const dir of candidateDirs()) {
    if (seen.has(dir) || !existsSync(dir)) continue
    add(dir)
    added.push(dir)
  }

  const path = ordered.join(delimiter)
  process.env['PATH'] = path
  return { path, source, added }
}

/**
 * Locates an executable on the given PATH.
 *
 * Used both to give a precise "not installed" message and to spawn by absolute
 * path, which removes any remaining doubt about what got executed.
 */
export function findExecutable(name: string, path = process.env['PATH'] ?? ''): string | null {
  // An explicit path is used as-is.
  if (name.includes('/')) {
    return isExecutableFile(name) ? name : null
  }
  for (const dir of path.split(delimiter)) {
    if (!dir) continue
    const candidate = join(dir, name)
    if (isExecutableFile(candidate)) return candidate
  }
  return null
}

function isExecutableFile(candidate: string): boolean {
  try {
    if (!statSync(candidate).isFile()) return false
    accessSync(candidate, constants.X_OK)
    return true
  } catch {
    return false
  }
}

export function codexConfigPath(): string {
  return join(homedir(), '.codex', 'config.toml')
}

/**
 * The model the user's own `codex` is configured to use.
 *
 * Codex model ids are versioned (`gpt-5.6-sol`), so any list this app ships
 * starts rotting the day it ships — a hardcoded `gpt-5.1-codex` was already
 * being *rejected* by the CLI as unknown. Reading the user's config means the
 * first suggestion is always one their install accepts.
 *
 * Claude needs no equivalent: its aliases (`opus`, `sonnet`, `haiku`, `fable`)
 * resolve to the latest of each family, so they never go stale.
 */
export function readCodexDefaultModel(configPath = codexConfigPath()): string {
  try {
    const text = readFileSync(configPath, 'utf8')
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      // Stop at the first table header: a `model` inside [projects.…] or a
      // profile belongs to that scope, not to the global default.
      if (trimmed.startsWith('[')) break
      const match = /^model\s*=\s*["']([^"']+)["']/.exec(trimmed)
      if (match?.[1]) return match[1]
    }
  } catch {
    // No config, unreadable, or no default set — the CLI's own default applies.
  }
  return ''
}

export interface PtyPreflight {
  ok: boolean
  /** Empty when ok; otherwise an actionable explanation. */
  detail: string
  helperPath: string | null
}

export interface PtyPreflightProbe {
  platform: NodeJS.Platform
  resolveEntry: () => string
}

/**
 * Verifies node-pty can actually spawn before the user tries to open a pane.
 *
 * On macOS `pty.fork` shells out through a `spawn-helper` executable that
 * binding.gyp builds as a separate target. npm's `allow-scripts` policy blocks
 * node-pty's build script by default, which can leave `pty.node` present (so the
 * module imports fine) while `spawn-helper` is missing — and then every single
 * spawn fails with "posix_spawnp failed", pointing at nothing useful.
 */
export function preflightPty(
  probe: PtyPreflightProbe = {
    platform: process.platform,
    resolveEntry: () => require.resolve('node-pty'),
  },
): PtyPreflight {
  if (probe.platform !== 'darwin') {
    return { ok: true, detail: '', helperPath: null }
  }

  let releaseDir: string
  try {
    // Resolve through the package's own entry so this follows whatever layout
    // the installed version uses.
    const entry = probe.resolveEntry()
    releaseDir = join(dirname(entry), '..', 'build', 'Release')
  } catch (err) {
    return {
      ok: false,
      helperPath: null,
      detail: `node-pty could not be loaded (${err instanceof Error ? err.message : String(err)}). Run "npm run rebuild".`,
    }
  }

  // Mirrors node-pty's own asar rewriting.
  const helperPath = join(releaseDir, 'spawn-helper')
    .replace('app.asar', 'app.asar.unpacked')
    .replace('node_modules.asar', 'node_modules.asar.unpacked')

  if (!existsSync(helperPath)) {
    return {
      ok: false,
      helperPath,
      detail:
        'node-pty is missing its spawn-helper binary, so no terminal can start — not even a plain shell. ' +
        'This happens when npm blocks node-pty\'s build script. Fix it with "npm run rebuild".',
    }
  }

  if (!isExecutableFile(helperPath)) {
    return {
      ok: false,
      helperPath,
      detail:
        `node-pty's spawn-helper at ${helperPath} is not executable, so every terminal spawn fails. ` +
        'Fix it with "chmod +x" on that file, or re-run "npm run rebuild".',
    }
  }

  return { ok: true, detail: '', helperPath }
}
