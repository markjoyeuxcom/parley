import { spawn, type ChildProcess } from 'node:child_process'
import { readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { isShellFree } from '@shared/command'
import type { Id, Preview } from '@shared/domain'
import { splitCommand } from '@main/util/spawn'
import { findExecutable } from '@main/util/environment'
import { newId } from '@main/store/repo'

/**
 * Long-running preview processes — a project's own dev server.
 *
 * Distinct from both other process paths on purpose. `capture` runs a command
 * to completion, which a dev server never reaches; a Grid pane is an
 * interactive terminal the user drives. A preview is neither: Parley starts
 * it, watches it, tells you where it is listening, and — the part that
 * actually matters — can reliably stop it again.
 *
 * **Process-group discipline is the whole feature.** `npm run dev` is npm
 * spawning vite: a plain SIGTERM to the child reaps npm and orphans the
 * server, which then holds the port and outlives the app. Every preview is
 * spawned detached so it leads its own group, and stopping signals the group.
 * That is also why quitting disposes them — an orphaned dev server the user
 * cannot see is worse than one that never started.
 */

export class PreviewError extends Error {}

/** Enough to diagnose a crash, bounded so a chatty server cannot grow forever. */
const MAX_LOG_CHARS = 64 * 1024
const STOP_ESCALATION_MS = 3000

export interface PreviewCallbacks {
  onChanged(preview: Preview): void
}

interface PreviewHandle {
  preview: Preview
  child: ChildProcess
  log: string
}

/**
 * Finds the address a dev server just announced.
 *
 * Deliberately a scan of its own output rather than a guess: every dev server
 * prints where it is listening, and the port it actually got may not be the
 * port it wanted — offering a link to a port nothing is serving would be
 * worse than offering none.
 */
export function detectUrl(text: string): string | null {
  const match = /https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0)(?::\d+)?[^\s"'`]*/i.exec(
    text,
  )
  if (!match) return null
  // 0.0.0.0 means "every interface" and is not a thing a browser should open.
  return match[0].replace('0.0.0.0', 'localhost')
}

/**
 * The command this project most likely uses to serve itself.
 *
 * Read from its own package.json rather than assumed: `npm run dev` is the
 * common case but not the universal one, and offering a command that does not
 * exist would make the first click a failure. Empty means "you tell me".
 */
export function suggestPreviewCommand(repoPath: string): string {
  try {
    const raw = readFileSync(join(repoPath, 'package.json'), 'utf8')
    const scripts = (JSON.parse(raw) as { scripts?: Record<string, string> }).scripts ?? {}
    if (scripts['dev']) return 'npm run dev'
    if (scripts['start']) return 'npm start'
    if (scripts['serve']) return 'npm run serve'
  } catch {
    // No package.json, or not JSON — a perfectly ordinary repository.
  }
  return ''
}

export class PreviewManager {
  private readonly previews = new Map<Id, PreviewHandle>()

  constructor(private readonly cb: PreviewCallbacks) {}

  list(): Preview[] {
    return [...this.previews.values()].map((handle) => handle.preview)
  }

  get(id: Id): Preview | null {
    return this.previews.get(id)?.preview ?? null
  }

  logs(id: Id): string {
    return this.previews.get(id)?.log ?? ''
  }

  forRepo(repoPath: string): Preview | null {
    return (
      [...this.previews.values()].find(
        (handle) => handle.preview.repoPath === repoPath && handle.preview.status !== 'exited',
      )?.preview ?? null
    )
  }

  start(repoPath: string, command: string): Preview {
    const trimmed = command.trim()
    if (!trimmed) throw new PreviewError('a preview command is required')
    if (!isShellFree(trimmed)) {
      throw new PreviewError(
        'the preview command needs shell syntax, which Parley spawns without. Use one command, or a script in the project.',
      )
    }
    const argv = splitCommand(trimmed)
    if (!argv || !argv[0]) throw new PreviewError('the preview command could not be parsed')

    try {
      if (!statSync(repoPath).isDirectory()) throw new PreviewError(`${repoPath} is not a directory`)
    } catch (err) {
      if (err instanceof PreviewError) throw err
      throw new PreviewError(`cannot open ${repoPath}`)
    }

    // One per repository: two dev servers in one project fight over the same
    // port, and the second one's failure would look like the first one's.
    const existing = this.forRepo(repoPath)
    if (existing) throw new PreviewError('a preview is already running for this project')

    const resolved = findExecutable(argv[0])
    if (!resolved) {
      throw new PreviewError(
        `${argv[0]} was not found on PATH. If it works in Terminal but not here, launch Parley from Terminal once so it can read your shell's PATH.`,
      )
    }

    const id = newId()
    const preview: Preview = {
      id,
      repoPath,
      command: trimmed,
      status: 'starting',
      url: null,
      exitCode: null,
      startedAt: Date.now(),
    }

    // Detached so the child leads its own process group — see the class note.
    const child = spawn(resolved, argv.slice(1), {
      cwd: repoPath,
      env: process.env,
      detached: true,
    })
    const handle: PreviewHandle = { preview, child, log: '' }
    this.previews.set(id, handle)

    const absorb = (chunk: string): void => {
      handle.log = (handle.log + chunk).slice(-MAX_LOG_CHARS)
      // Output can arrive after the process is gone — a grandchild still
      // holding the pipe, or buffered bytes draining. It must never revive a
      // preview the record has already called exited.
      if (handle.preview.status === 'exited') return
      let changed = false
      if (handle.preview.status === 'starting') {
        handle.preview.status = 'running'
        changed = true
      }
      if (!handle.preview.url) {
        const url = detectUrl(chunk)
        if (url) {
          handle.preview.url = url
          changed = true
        }
      }
      if (changed) this.cb.onChanged({ ...handle.preview })
    }

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', absorb)
    child.stderr?.setEncoding('utf8')
    child.stderr?.on('data', absorb)

    child.on('error', (err) => {
      handle.log = `${handle.log}\nfailed to start: ${err.message}`.slice(-MAX_LOG_CHARS)
      handle.preview.status = 'exited'
      handle.preview.exitCode = -1
      this.cb.onChanged({ ...handle.preview })
    })

    // 'exit', deliberately not 'close': close waits for every writer to
    // release the pipe, and a dev server's own grandchild (vite spawning
    // esbuild) routinely holds it open. Waiting for that would leave a dead
    // server showing as running forever, which is the exact confusion this
    // whole feature exists to remove.
    child.on('exit', (code) => {
      handle.preview.status = 'exited'
      handle.preview.exitCode = code ?? -1
      handle.preview.url = null
      // The handle stays so the log survives the process — a dev server that
      // died on startup is exactly when its last twenty lines matter most.
      this.cb.onChanged({ ...handle.preview })
    })

    this.cb.onChanged({ ...preview })
    return preview
  }

  /** Signals the whole process group, so npm's children go with it. */
  stop(id: Id): void {
    const handle = this.previews.get(id)
    if (!handle) throw new PreviewError('no such preview')
    if (handle.preview.status === 'exited') return
    this.signal(handle, 'SIGTERM')
    setTimeout(() => {
      if (handle.preview.status !== 'exited') this.signal(handle, 'SIGKILL')
    }, STOP_ESCALATION_MS).unref?.()
  }

  /** Frees the record entirely. Only ever a user's act. */
  forget(id: Id): void {
    const handle = this.previews.get(id)
    if (!handle) return
    if (handle.preview.status !== 'exited') this.signal(handle, 'SIGKILL')
    this.previews.delete(id)
  }

  private signal(handle: PreviewHandle, signal: NodeJS.Signals): void {
    const pid = handle.child.pid
    try {
      if (pid) {
        // Negative pid: the whole group the detached child leads.
        process.kill(-pid, signal)
        return
      }
    } catch {
      // The group is already gone, or the spawn failed before it led one.
    }
    try {
      handle.child.kill(signal)
    } catch {
      // Already gone.
    }
  }

  /**
   * Kills every preview. Called on quit: a dev server that outlives the app
   * holds its port and cannot be stopped from anywhere the user can see.
   */
  disposeAll(): void {
    for (const id of [...this.previews.keys()]) this.forget(id)
  }
}
