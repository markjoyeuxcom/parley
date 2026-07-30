import { createRequire } from 'node:module'
import { statSync } from 'node:fs'
import { homedir } from 'node:os'
import type { IPty } from 'node-pty'
import { MAX_PANES, type Id, type Pane, type PaneKind } from '@shared/domain'
import { newId } from '@main/store/repo'
import { findExecutable, preflightPty } from '@main/util/environment'

/**
 * Terminal panes.
 *
 * node-pty is a native module, so it is loaded through createRequire rather
 * than a static ESM import: the main bundle is ESM, and a native CJS addon
 * resolved at build time is exactly the thing that breaks when the app is
 * packaged and the module ends up unpacked from the asar.
 */
const require = createRequire(import.meta.url)
const pty = require('node-pty') as typeof import('node-pty')

export interface PaneHandle {
  pane: Pane
  proc: IPty
}

export interface PtyManagerCallbacks {
  onData(paneId: Id, data: string): void
  /** A pane now exists. The renderer's pane registry is fed from this. */
  onCreated(pane: Pane): void
  /**
   * The handle is GONE — user close only. A process *exit* is a status
   * (`'exited'`, with the code) and the pane row survives it so the UI can
   * show the corpse; conflating the two was how exit chips stayed unreachable.
   */
  onClosed(paneId: Id): void
  onStatus(paneId: Id, status: Pane['status'], exitCode: number | null): void
}

export class PaneLimitError extends Error {}
export class PaneCwdError extends Error {}
/** The command could not be started. Carries a cause the user can act on. */
export class PaneSpawnError extends Error {}

/**
 * The shell to use for a plain pane. Honours the user's login shell, since a
 * developer's aliases and PATH live in their own rc files and a pane that does
 * not have them is a pane they cannot work in.
 */
function loginShell(): string {
  const fromEnv = process.env['SHELL']
  if (fromEnv && fromEnv.trim()) return fromEnv
  return process.platform === 'darwin' ? '/bin/zsh' : '/bin/bash'
}

/**
 * Command line for each pane kind.
 *
 * The agent panes run the CLIs *interactively*, which is the point: the pane is
 * a real Claude Code or Codex session with its own permission prompts and its
 * own TUI, riding the user's subscription. Parley is not proxying or re-hosting
 * the agent here, just giving it a window.
 */
function commandFor(kind: PaneKind): { file: string; args: string[] } {
  switch (kind) {
    case 'claude':
      return { file: 'claude', args: [] }
    case 'codex':
      return { file: 'codex', args: [] }
    default:
      // -l so the shell reads the user's profile.
      return { file: loginShell(), args: ['-l'] }
  }
}

function assertUsableCwd(cwd: string): void {
  try {
    if (!statSync(cwd).isDirectory()) throw new PaneCwdError(`${cwd} is not a directory`)
  } catch (err) {
    if (err instanceof PaneCwdError) throw err
    throw new PaneCwdError(`cannot open ${cwd}`)
  }
}

export class PtyManager {
  private readonly panes = new Map<Id, PaneHandle>()

  constructor(private readonly cb: PtyManagerCallbacks) {}

  get count(): number {
    return this.panes.size
  }

  list(): Pane[] {
    return [...this.panes.values()].map((h) => h.pane)
  }

  open(kind: PaneKind, cwd: string, cols: number, rows: number): Pane {
    if (this.panes.size >= MAX_PANES) {
      throw new PaneLimitError(`the grid holds at most ${MAX_PANES} panes`)
    }
    const dir = cwd.trim() || homedir()
    assertUsableCwd(dir)

    const { file, args } = commandFor(kind)

    // Resolve to an absolute path first. This separates "the CLI is not
    // installed" from "the pty layer is broken" — two failures that produce the
    // same opaque message from node-pty and need completely different fixes.
    const resolved = findExecutable(file)
    if (!resolved) {
      throw new PaneSpawnError(
        kind === 'shell'
          ? `${file} was not found. Set $SHELL to a shell that exists.`
          : `The ${kind} CLI was not found on PATH. Install it and sign in, then restart Parley so it picks up your shell's PATH.`,
      )
    }

    // A missing spawn-helper makes every spawn fail, so check before blaming the
    // command the user asked for.
    const preflight = preflightPty()
    if (!preflight.ok) throw new PaneSpawnError(preflight.detail)

    const id = newId()

    let proc: IPty
    try {
      proc = pty.spawn(resolved, args, {
        name: 'xterm-256color',
        cols,
        rows,
        cwd: dir,
        env: {
          ...process.env,
          TERM: 'xterm-256color',
          // Marks the session so a user's rc files can adjust if they want to.
          PARLEY_PANE: '1',
        } as Record<string, string>,
      })
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err)
      // node-pty reports nearly every failure as this one string, so add the
      // context it omits rather than passing it through bare.
      const hint = /posix_spawnp/i.test(detail)
        ? ' node-pty could not spawn the process. This is usually its spawn-helper binary being missing or unsigned — run "npm run rebuild".'
        : ''
      throw new PaneSpawnError(`Could not start ${resolved}: ${detail}.${hint}`)
    }

    const pane: Pane = {
      id,
      kind,
      title: kind === 'shell' ? shortenPath(dir) : `${kind} — ${shortenPath(dir)}`,
      cwd: dir,
      status: 'starting',
      exitCode: null,
      createdAt: Date.now(),
    }

    const handle: PaneHandle = { pane, proc }
    this.panes.set(id, handle)

    proc.onData((data) => {
      if (handle.pane.status === 'starting') {
        handle.pane.status = 'live'
        this.cb.onStatus(id, 'live', null)
      }
      this.cb.onData(id, data)
    })

    proc.onExit(({ exitCode }) => {
      handle.pane.status = 'exited'
      handle.pane.exitCode = exitCode
      this.cb.onStatus(id, 'exited', exitCode)
      // The handle stays in the map so the UI can show the final scrollback and
      // the exit code until the user closes the pane themselves.
    })

    this.cb.onCreated(pane)
    return pane
  }

  write(paneId: Id, data: string): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') return
    handle.proc.write(data)
  }

  resize(paneId: Id, cols: number, rows: number): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') return
    try {
      handle.proc.resize(cols, rows)
    } catch {
      // A resize racing a process exit throws; the exit handler covers it.
    }
  }

  /**
   * Types a prompt into a pane and submits it.
   *
   * This is how a Skill reaches an agent pane: it is keystrokes into the
   * interactive session, not a separate spawn, so the agent keeps its context
   * and the user sees exactly what was sent.
   */
  submit(paneId: Id, text: string): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') return
    // Newlines inside a prompt would submit early, so flatten them. The CLIs'
    // own multi-line paste handling is inconsistent between versions.
    handle.proc.write(`${text.replace(/\r?\n/g, ' ')}\r`)
  }

  close(paneId: Id): void {
    const handle = this.panes.get(paneId)
    if (!handle) return
    this.panes.delete(paneId)
    if (handle.pane.status !== 'exited') {
      try {
        handle.proc.kill()
      } catch {
        // Already gone.
      }
    }
    this.cb.onClosed(paneId)
  }

  /** Kills every pane. Called on window close and app quit. */
  disposeAll(): void {
    for (const id of [...this.panes.keys()]) this.close(id)
  }
}

/** `/Users/x/Developer/thing` becomes `~/Developer/thing`, then just the tail. */
export function shortenPath(dir: string): string {
  const home = homedir()
  const withTilde = dir.startsWith(home) ? `~${dir.slice(home.length)}` : dir
  const parts = withTilde.split('/').filter(Boolean)
  if (parts.length <= 2) return withTilde
  return `${parts.at(-2)}/${parts.at(-1)}`
}
