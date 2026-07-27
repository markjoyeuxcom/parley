import { spawn } from 'node:child_process'
import type { SpawnOptionsWithoutStdio } from 'node:child_process'
import { isShellFree } from '@shared/command'

/**
 * Process helpers.
 *
 * Everything here spawns with an explicit argv array and never a shell. That is
 * a hard invariant: agent-authored strings (goals, milestone titles, test
 * commands) reach these functions, and a shell would turn any of them into an
 * injection vector.
 */

export interface JsonlRunOptions {
  command: string
  args: string[]
  cwd: string
  /** Written to stdin, then stdin is closed. Closing matters: codex blocks otherwise. */
  stdin?: string
  env?: Record<string, string>
  signal?: AbortSignal
  timeoutMs?: number
  /** Called for each parsed stdout JSON line. Non-JSON lines go to `onRaw`. */
  onEvent: (event: Record<string, unknown>) => void
  onRaw?: (line: string) => void
}

export interface JsonlRunResult {
  exitCode: number
  signal: string | null
  stderr: string
  /** True when the run was cut short by abort or timeout rather than exiting. */
  terminated: boolean
  /**
   * True when Parley's own deadline did the cutting. "The run was cancelled"
   * and "the run hit its time limit" demand opposite responses — one was asked
   * for, the other means the work never finished — and both arrive as a
   * termination. Same distinction capture() already records, for the same
   * reason.
   */
  timedOut: boolean
}

const MAX_STDERR = 64 * 1024

/**
 * Runs a process that emits newline-delimited JSON on stdout.
 *
 * Resolves rather than rejects on a non-zero exit: a CLI that fails is a normal,
 * reportable outcome for us, and callers need the stderr to explain it.
 */
export function runJsonl(opts: JsonlRunOptions): Promise<JsonlRunResult> {
  return new Promise((resolve) => {
    const spawnOpts: SpawnOptionsWithoutStdio & { cwd: string } = {
      cwd: opts.cwd,
      // shell is never enabled — see the module note.
      env: { ...process.env, ...(opts.env ?? {}) } as NodeJS.ProcessEnv,
    }

    const child = spawn(opts.command, opts.args, spawnOpts)

    let stderr = ''
    let stdoutTail = ''
    let settled = false
    let terminated = false
    let timedOut = false

    const finish = (exitCode: number, signalName: string | null) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      opts.signal?.removeEventListener('abort', onAbort)
      // Flush a trailing partial line — some CLIs omit the final newline.
      if (stdoutTail.trim()) handleLine(stdoutTail)
      resolve({ exitCode, signal: signalName, stderr, terminated, timedOut })
    }

    const handleLine = (line: string) => {
      const trimmed = line.trim()
      if (!trimmed) return
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          const parsed = JSON.parse(trimmed) as unknown
          if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            opts.onEvent(parsed as Record<string, unknown>)
            return
          }
        } catch {
          // Fall through to onRaw: a truncated or interleaved line is not fatal.
        }
      }
      opts.onRaw?.(trimmed)
    }

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => {
      stdoutTail += chunk
      let newline = stdoutTail.indexOf('\n')
      while (newline !== -1) {
        handleLine(stdoutTail.slice(0, newline))
        stdoutTail = stdoutTail.slice(newline + 1)
        newline = stdoutTail.indexOf('\n')
      }
    })

    child.stderr?.setEncoding('utf8')
    child.stderr?.on('data', (chunk: string) => {
      if (stderr.length < MAX_STDERR) stderr += chunk
    })

    const kill = () => {
      terminated = true
      child.kill('SIGTERM')
      // Escalate if the CLI ignores SIGTERM while mid-request.
      setTimeout(() => {
        if (!settled) child.kill('SIGKILL')
      }, 3000).unref?.()
    }

    const onAbort = () => kill()
    opts.signal?.addEventListener('abort', onAbort, { once: true })

    // The flag is set in the timer callback, never inside kill(): kill() also
    // serves aborts, and conflating the two causes is the defect this exists
    // to remove.
    const timer = opts.timeoutMs
      ? setTimeout(() => {
          timedOut = true
          kill()
        }, opts.timeoutMs)
      : (undefined as unknown as NodeJS.Timeout)

    child.on('error', (err) => {
      stderr += `\nspawn error: ${err.message}`
      finish(-1, null)
    })

    child.on('close', (code, signalName) => finish(code ?? -1, signalName ?? null))

    // Write the prompt and close stdin. `codex exec` reads instructions from
    // stdin and will wait forever if the stream stays open.
    if (child.stdin) {
      child.stdin.on('error', () => {
        // The child may exit before we finish writing; that surfaces via 'close'.
      })
      if (opts.stdin) child.stdin.write(opts.stdin)
      child.stdin.end()
    }

    if (opts.signal?.aborted) kill()
  })
}

export interface CaptureResult {
  exitCode: number
  /**
   * The signal that killed the process, if one did.
   *
   * A command that segfaults and a command whose tests failed both arrive as a
   * non-zero result, and they call for opposite responses: one means the code
   * is wrong, the other means the verification never happened. Discarding this
   * told the reviewer "the tests failed" when the truth was "the runner
   * crashed", which sends an executor off fixing tests that never ran.
   */
  signal: string | null
  stdout: string
  stderr: string
  durationMs: number
  timedOut: boolean
}

/**
 * Runs a command to completion and captures its output.
 *
 * Used for the deterministic verification step: Parley runs the project's own
 * test command itself, so a green result is an observed fact rather than
 * something an agent reported about itself.
 */
export function capture(
  command: string,
  args: string[],
  cwd: string,
  timeoutMs = 15 * 60 * 1000,
  signal?: AbortSignal,
): Promise<CaptureResult> {
  const startedAt = Date.now()
  return new Promise((resolve) => {
    const child = spawn(command, args, { cwd, env: process.env })
    let stdout = ''
    let stderr = ''
    let settled = false
    let timedOut = false
    const LIMIT = 512 * 1024

    const finish = (exitCode: number, killedBy: string | null = null) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', onAbort)
      resolve({
        exitCode,
        signal: killedBy,
        stdout,
        stderr,
        durationMs: Date.now() - startedAt,
        timedOut,
      })
    }

    const kill = () => {
      child.kill('SIGTERM')
      setTimeout(() => {
        if (!settled) child.kill('SIGKILL')
      }, 3000).unref?.()
    }
    const onAbort = () => kill()
    signal?.addEventListener('abort', onAbort, { once: true })

    const timer = setTimeout(() => {
      timedOut = true
      kill()
    }, timeoutMs)

    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (c: string) => {
      if (stdout.length < LIMIT) stdout += c
    })
    child.stderr?.setEncoding('utf8')
    child.stderr?.on('data', (c: string) => {
      if (stderr.length < LIMIT) stderr += c
    })
    child.on('error', (err) => {
      stderr += `\nspawn error: ${err.message}`
      finish(-1)
    })
    child.on('close', (code, killedBy) => finish(code ?? -1, killedBy ?? null))
    child.stdin?.end()
  })
}

/**
 * Splits a user- or agent-supplied command line into argv.
 *
 * Handles single and double quotes so `npm test -- --grep "a b"` survives, but
 * deliberately understands *nothing* else — no pipes, no redirection, no
 * substitution, no globbing. A command needing shell features is rejected by
 * the caller rather than quietly given a shell.
 */
export function splitCommand(line: string): string[] | null {
  const out: string[] = []
  let current = ''
  let quote: '"' | "'" | null = null
  let sawAny = false

  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i]
    if (ch === undefined) break
    if (quote) {
      if (ch === quote) quote = null
      else current += ch
      continue
    }
    if (ch === '"' || ch === "'") {
      quote = ch
      sawAny = true
      continue
    }
    if (ch === ' ' || ch === '\t') {
      if (current || sawAny) {
        out.push(current)
        current = ''
        sawAny = false
      }
      continue
    }
    current += ch
  }
  if (quote) return null // unbalanced quotes
  if (current || sawAny) out.push(current)
  return out.length ? out : null
}

// The rule itself lives in shared, so the UI can apply it before you approve.
export { isShellFree } from '@shared/command'
