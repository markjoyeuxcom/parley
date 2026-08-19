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
 * An interactive CLI's first bytes are its splash screen, not an input-ready
 * boundary. Claude and Codex both redraw while entering raw mode; keystrokes
 * written during that window can be discarded. Treat a short quiet period as
 * the boundary instead, and only ever announce it once for a pane.
 */
export class PaneInputReadiness {
  private readonly timers = new Map<Id, {
    quiet?: ReturnType<typeof setTimeout>
    ceiling: ReturnType<typeof setTimeout>
  }>()
  private readonly ready = new Set<Id>()

  constructor(
    private readonly onReady: (paneId: Id) => void,
    private readonly quietMs = 750,
    private readonly ceilingMs = 3_000,
  ) {}

  /**
   * The pane exists. Starts the ceiling, and only the ceiling.
   *
   * Readiness used to begin at the first byte of output, which quietly assumed
   * every CLI says something on startup. One that does not — or one whose first
   * write lands after the user has given up — armed no timer at all and stayed
   * `starting` for as long as it lived. A work assignment queued against it was
   * never delivered, because the ready signal is the only thing that delivers
   * one, and the lane sat looking healthy having been told nothing.
   *
   * Deliberately not the quiet timer as well: 750ms of silence right after
   * spawn is the normal state of a CLI still loading, and treating it as an
   * input-ready prompt is the exact mistake this gate exists to prevent.
   */
  arm(paneId: Id): void {
    if (this.ready.has(paneId) || this.timers.has(paneId)) return
    this.timers.set(paneId, { ceiling: setTimeout(() => this.release(paneId), this.ceilingMs) })
  }

  observe(paneId: Id): void {
    if (this.ready.has(paneId)) return
    const pending = this.timers.get(paneId)
    if (pending?.quiet) clearTimeout(pending.quiet)
    const quiet = setTimeout(() => this.release(paneId), this.quietMs)
    const ceiling = pending?.ceiling ?? setTimeout(() => this.release(paneId), this.ceilingMs)
    this.timers.set(paneId, { quiet, ceiling })
  }

  forget(paneId: Id): void {
    const pending = this.timers.get(paneId)
    if (pending) {
      if (pending.quiet) clearTimeout(pending.quiet)
      clearTimeout(pending.ceiling)
    }
    this.timers.delete(paneId)
    this.ready.delete(paneId)
  }

  private release(paneId: Id): void {
    if (this.ready.has(paneId)) return
    const pending = this.timers.get(paneId)
    if (pending) {
      if (pending.quiet) clearTimeout(pending.quiet)
      clearTimeout(pending.ceiling)
    }
    this.timers.delete(paneId)
    this.ready.add(paneId)
    this.onReady(paneId)
  }
}

/**
 * Ink-style TUIs recognise a large write as a paste and fold it into a
 * placeholder asynchronously. Enter in that same write is consumed before
 * the paste has settled, leaving the CLI idle. Body and submission therefore
 * cross the PTY separately, just as a person pastes and then presses Enter.
 */
export class PanePromptSubmitter {
  private readonly timers = new Map<Id, ReturnType<typeof setTimeout>>()

  constructor(
    private readonly write: (paneId: Id, data: string) => void,
    private readonly settleMs = 200,
  ) {}

  /**
   * Hands a pane pasted content, the way ⌘V does.
   *
   * The relay carries what one CLI said into another — code blocks, file
   * listings, numbered findings — and neither of the obvious deliveries
   * works. `submit` flattens newlines to spaces, which is right for a
   * one-line instruction and ruins a diff. Writing the newlines raw is worse:
   * a TUI reads the first one as Enter and submits a message cut off after
   * its opening line.
   *
   * Bracketed paste is the mechanism the terminal already has for exactly
   * this. The CLI reads the span between the markers as pasted content rather
   * than as typing, newlines survive, and nothing is submitted until Enter
   * follows.
   */
  paste(paneId: Id, text: string): void {
    const pending = this.timers.get(paneId)
    if (pending) clearTimeout(pending)
    // A CR inside the payload IS Enter to the receiving TUI, and content
    // copied out of a terminal is full of them.
    const body = text.replace(/\r\n?/g, '\n')
    this.write(paneId, `\u001b[200~${body}\u001b[201~`)
    this.timers.set(paneId, setTimeout(() => {
      this.timers.delete(paneId)
      this.write(paneId, '\r')
    }, this.settleMs))
  }

  submit(paneId: Id, text: string): void {
    const pending = this.timers.get(paneId)
    if (pending) clearTimeout(pending)
    this.write(paneId, text.replace(/\r?\n/g, ' '))
    this.timers.set(paneId, setTimeout(() => {
      this.timers.delete(paneId)
      this.write(paneId, '\r')
    }, this.settleMs))
  }

  forget(paneId: Id): void {
    const pending = this.timers.get(paneId)
    if (pending) clearTimeout(pending)
    this.timers.delete(paneId)
  }
}

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
export function commandFor(kind: PaneKind, resume = false): { file: string; args: string[] } {
  switch (kind) {
    case 'claude':
      // `--resume` bare opens the CLI's OWN interactive session picker —
      // Parley's governed resume ids never reach a pane.
      return { file: 'claude', args: resume ? ['--resume'] : [] }
    case 'codex':
      return { file: 'codex', args: resume ? ['resume'] : [] }
    case 'agy':
      // Bare, always. Agy's headless mode is triggered by a non-TTY stdin (see
      // the adapter's buildAgyArgs) — a pane gives it a real TTY, so no flag is
      // needed to get the interactive session, and none is passed.
      //
      // `resume` is ignored rather than honoured: agy resumes by id, not
      // through a picker, so it is not in RESUME_PICKER_KINDS and the menu
      // item never appears. Ignoring it here keeps that true even if some
      // caller passes the flag anyway.
      return { file: 'agy', args: [] }
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
  private readonly readiness: PaneInputReadiness
  private readonly submitter: PanePromptSubmitter

  constructor(private readonly cb: PtyManagerCallbacks) {
    this.readiness = new PaneInputReadiness((paneId) => {
      const handle = this.panes.get(paneId)
      if (!handle || handle.pane.status !== 'starting') return
      handle.pane.status = 'live'
      this.cb.onStatus(paneId, 'live', null)
    })
    this.submitter = new PanePromptSubmitter((paneId, data) => {
      const handle = this.panes.get(paneId)
      if (!handle || handle.pane.status === 'exited') return
      handle.proc.write(data)
    })
  }

  get count(): number {
    return this.panes.size
  }

  list(): Pane[] {
    return [...this.panes.values()].map((h) => h.pane)
  }

  get(id: Id): Pane | null {
    return this.panes.get(id)?.pane ?? null
  }

  open(kind: PaneKind, cwd: string, cols: number, rows: number, resume = false): Pane {
    if (this.panes.size >= MAX_PANES) {
      throw new PaneLimitError(`the grid holds at most ${MAX_PANES} panes`)
    }
    const dir = cwd.trim() || homedir()
    assertUsableCwd(dir)

    const { file, args } = commandFor(kind, resume)

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
    // From creation, not from the first byte: a CLI that prints nothing must
    // still reach an input-ready prompt.
    this.readiness.arm(id)

    proc.onData((data) => {
      this.cb.onData(id, data)
      if (handle.pane.status === 'starting') this.readiness.observe(id)
    })

    proc.onExit(({ exitCode }) => {
      this.readiness.forget(id)
      this.submitter.forget(id)
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
  /**
   * Kills the process but keeps the handle: the slot survives, the pane shows
   * its corpse with the exit code, and Reopen can bring it back. Close is the
   * only way a handle leaves the map.
   */
  stop(paneId: Id): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') return
    try {
      handle.proc.kill()
    } catch {
      // Already gone; the exit handler records it.
    }
  }

  paste(paneId: Id, text: string): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') return
    this.submitter.paste(paneId, text)
  }

  submit(paneId: Id, text: string): void {
    const handle = this.panes.get(paneId)
    if (!handle || handle.pane.status === 'exited') throw new Error('the pane is no longer live')
    this.submitter.submit(paneId, text)
  }

  close(paneId: Id): void {
    const handle = this.panes.get(paneId)
    if (!handle) return
    this.readiness.forget(paneId)
    this.submitter.forget(paneId)
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
