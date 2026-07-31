import { spawn } from 'node:child_process'
import { accessSync, constants, existsSync, readFileSync, statSync } from 'node:fs'
import { homedir, userInfo } from 'node:os'
import { delimiter, join } from 'node:path'
import type { RemoteVendorDetail } from '@shared/remote'

/**
 * What this host can actually do.
 *
 * Every probe here is bounded. A handshake that hangs is worse than one that
 * reports an unknown: `parley remote status` exists to tell you what is wrong
 * with a host, and a status command that never returns has failed at its one
 * job. So a CLI that will not answer `--version` in two seconds is reported as
 * present-but-unversioned, with a warning, rather than being allowed to hold
 * the connection open.
 *
 * The probes deliberately do not authenticate. Finding a config file proves
 * intent, not a working subscription, and proving the subscription would mean
 * spending money on every status check. An expired login stays what it is: an
 * ordinary execution failure, reported by the run that hits it.
 */

const PROBE_TIMEOUT_MS = 2_000
const MAX_PROBE_OUTPUT = 8 * 1024

/** Adapters this bundle contains. Independent of what the host can run. */
export const SUPPORTED_VENDORS = ['claude', 'codex', 'agy'] as const

export interface ProbeResult {
  detail: RemoteVendorDetail
  /** Something a human should know that is not itself a failure. */
  warning: string | null
}

/**
 * Runs a bounded probe and never rejects.
 *
 * stdin is /dev/null rather than a pipe: a CLI that decides to prompt would
 * otherwise block forever on a read that nothing will answer, which looks
 * exactly like a hang and is one of the easier ways to make a status command
 * useless. The process group is killed on timeout so a probe cannot leave a
 * child behind.
 */
export function probeCommand(
  executable: string,
  args: string[],
  timeoutMs = PROBE_TIMEOUT_MS,
): Promise<{ stdout: string; code: number | null; timedOut: boolean }> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>
    try {
      child = spawn(executable, args, { stdio: ['ignore', 'pipe', 'pipe'], detached: true })
    } catch {
      resolve({ stdout: '', code: null, timedOut: false })
      return
    }

    let stdout = ''
    let settled = false
    let timedOut = false

    const finish = (code: number | null): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve({ stdout, code, timedOut })
    }

    const timer = setTimeout(() => {
      timedOut = true
      try {
        process.kill(-child.pid!, 'SIGKILL')
      } catch {
        child.kill('SIGKILL')
      }
      finish(null)
    }, timeoutMs)

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => {
      if (stdout.length < MAX_PROBE_OUTPUT) stdout += chunk
    })
    // Read and discard stderr: a probe whose stderr pipe fills would block on
    // the write and never exit, which is the hang this whole function avoids.
    child.stderr?.resume()
    child.on('error', () => finish(null))
    child.on('close', (code) => finish(code))
  })
}

/** Resolves a name against PATH, the way a spawn would. Never runs a shell. */
export function resolveExecutable(name: string, path: string): string | null {
  if (name.includes('/')) return isExecutableFile(name) ? name : null
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

/* ------------------------------------------------------------------ */
/* Vendors                                                             */
/* ------------------------------------------------------------------ */

/** Where each CLI keeps the configuration that proves someone set it up. */
function configPresent(vendor: string, home: string): boolean {
  switch (vendor) {
    case 'claude':
      return existsSync(join(home, '.claude')) || existsSync(join(home, '.claude.json'))
    case 'codex':
      return existsSync(join(home, '.codex', 'config.toml'))
    case 'agy':
      return existsSync(join(home, '.gemini', 'antigravity-cli', 'settings.json'))
    default:
      return false
  }
}

/**
 * The permission posture worth naming, or null when the CLI has none.
 *
 * agy is the one that matters today, and it matters a lot: a non-empty
 * `permissions.allow` means a headless run will EXECUTE those tools without
 * asking anybody. Parley's adapter already fails a turn closed when it sees
 * tool steps, but a human choosing a host should be told before the run, not
 * discover it from a refusal afterwards.
 *
 * An unreadable settings file reports 'unknown' rather than 'ask'. Not being
 * able to tell is closer to the permissive case than to the safe one, and
 * silence would be the wrong default for a safety property.
 */
function permissionMode(vendor: string, home: string): string | null {
  if (vendor !== 'agy') return null
  const settings = join(home, '.gemini', 'antigravity-cli', 'settings.json')
  if (!existsSync(settings)) return 'ask'
  try {
    const parsed = JSON.parse(readFileSync(settings, 'utf8')) as {
      permissions?: { allow?: unknown }
    }
    const allow = parsed.permissions?.allow
    if (Array.isArray(allow) && allow.length > 0) return 'allow'
    return 'ask'
  } catch {
    return 'unknown'
  }
}

export async function probeVendor(vendor: string, path: string, home: string): Promise<ProbeResult> {
  const executable = resolveExecutable(vendor, path)
  if (!executable) {
    return {
      detail: { executable: null, version: null, configured: false, permissionMode: null },
      warning: null,
    }
  }

  const probe = await probeCommand(executable, ['--version'])
  const version = firstLine(probe.stdout)
  return {
    detail: {
      executable,
      version,
      configured: configPresent(vendor, home),
      permissionMode: permissionMode(vendor, home),
    },
    // A CLI that is installed but will not say what it is stays usable — the
    // run will find out. Refusing the host over an unanswered --version would
    // be stricter than the situation warrants.
    warning: probe.timedOut
      ? `${vendor} did not answer --version within ${PROBE_TIMEOUT_MS}ms`
      : version === null
        ? `${vendor} produced no version output`
        : null,
  }
}

function firstLine(text: string): string | null {
  const line = text.split('\n').find((entry) => entry.trim().length > 0)
  return line ? line.trim().slice(0, 200) : null
}

/* ------------------------------------------------------------------ */
/* The host itself                                                     */
/* ------------------------------------------------------------------ */

export interface HostFacts {
  user: string
  home: string
  path: string
  nodeVersion: string
  nodeExecutable: string
  git: string | null
  vendorDetails: Record<string, RemoteVendorDetail>
  availableVendors: string[]
  warnings: string[]
}

/**
 * Everything the handshake reports about where it is running.
 *
 * The PATH is included verbatim and on purpose. A non-interactive ssh session
 * does not read the shell startup files where nvm, asdf and mise install their
 * shims, so a CLI that works perfectly in an interactive ssh terminal can be
 * entirely absent here. Printing the PATH turns that from an occult failure
 * into a one-line diagnosis.
 */
export async function probeHost(runsRoot: string): Promise<HostFacts> {
  const path = process.env.PATH ?? ''
  const home = process.env.HOME ?? homedir()
  const warnings: string[] = []

  const gitExecutable = resolveExecutable('git', path)
  let git: string | null = null
  if (gitExecutable) {
    const probe = await probeCommand(gitExecutable, ['--version'])
    git = firstLine(probe.stdout)
    if (probe.timedOut) warnings.push('git did not answer --version')
  } else {
    warnings.push(`git was not found on this host's PATH (${path})`)
  }

  const vendorDetails: Record<string, RemoteVendorDetail> = {}
  const availableVendors: string[] = []
  for (const vendor of SUPPORTED_VENDORS) {
    const result = await probeVendor(vendor, path, home)
    vendorDetails[vendor] = result.detail
    // Available means "there is something to run". Whether it is signed in is
    // the run's problem, and an ordinary failure when it is not.
    if (result.detail.executable) availableVendors.push(vendor)
    if (result.warning) warnings.push(result.warning)
    if (result.detail.permissionMode === 'unknown') {
      warnings.push(`${vendor}'s permission settings could not be read — treat this host as permissive`)
    }
  }

  return {
    user: safeUser(),
    home,
    path,
    nodeVersion: process.version,
    nodeExecutable: process.execPath,
    git,
    vendorDetails,
    availableVendors,
    warnings,
  }
}

function safeUser(): string {
  try {
    return userInfo().username
  } catch {
    // Containers without a passwd entry for the running uid throw here; the
    // handshake should still work, so report what we can.
    return process.env.USER ?? `uid:${process.getuid?.() ?? 'unknown'}`
  }
}
