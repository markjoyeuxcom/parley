import { type Capability, type Effort, type Usage } from '@shared/domain'
import { emptyUsage } from '@shared/usage'
import type { CliHealth } from '@shared/ipc'
import { capture, runJsonl } from '@main/util/spawn'
import { findExecutable } from '@main/util/environment'

/**
 * The isolated configuration directory, if the app prepared one.
 *
 * Read at call time rather than at import, so a test can set it. Absent — in a
 * unit test, or if preparing it failed — the adapter runs as it always did
 * rather than refusing, and `agentToolPolicy` is what reports the difference.
 */
function codexEnv(): Record<string, string> {
  const home = process.env['PARLEY_CODEX_HOME']?.trim()
  return home ? { CODEX_HOME: home } : {}
}
import { describeCommand } from './activity'
import type { AgentAdapter, RunRequest, RunResult } from './types'

/**
 * Codex CLI adapter.
 *
 * Invoked as `codex exec --json`, which emits newline-delimited events. Quirks
 * that are load-bearing here:
 *
 *  • **stdin must be closed** or `codex exec` waits forever for more input. It
 *    even says so on stderr ("Reading additional input from stdin...").
 *  • `--skip-git-repo-check` is required to run outside a git repository.
 *  • **`codex exec resume` accepts a much smaller flag set than `codex exec`** —
 *    notably no `-s/--sandbox` and no `-C/--cd`. Verified against the CLI's own
 *    help. So the sandbox is set through `-c sandbox_mode=…`, which is accepted
 *    by both forms, and the working directory is set on the spawn instead of
 *    with `-C`. Using `-s` would work on the first turn and then fail on every
 *    resumed turn.
 *  • There is **no `--system-prompt`**, so the role instructions are prepended
 *    to the prompt body.
 *  • `exec` mode emits no incremental text deltas — the reply arrives whole in
 *    an `item.completed` event.
 */

/** Codex accepts a narrower effort range than Claude; fold the top end down. */
export function codexEffort(effort: Effort): string {
  switch (effort) {
    case 'low':
      return 'low'
    case 'medium':
      return 'medium'
    default:
      // 'high', 'xhigh' and 'max' all map to codex's ceiling.
      return 'high'
  }
}

/**
 * Maps our capability onto a codex sandbox mode.
 *
 * `danger-full-access` is never returned. `none` maps to `read-only` because
 * codex has no tool-free mode — read-only is its floor, and a pure-argument turn
 * simply has no reason to touch the filesystem.
 */
export function codexSandbox(capability: Capability): 'read-only' | 'workspace-write' {
  return capability === 'write' ? 'workspace-write' : 'read-only'
}

export function buildCodexArgs(req: {
  model: string
  effort: Effort
  capability: Capability
  resumeId?: string | null
}): string[] {
  const args = ['exec']

  // `resume <id>` must come directly after `exec`, before the flags.
  if (req.resumeId) args.push('resume', req.resumeId)

  args.push('--json', '--skip-git-repo-check')

  // Set through -c rather than -s so the same code path works when resuming,
  // where -s does not exist.
  args.push('-c', `sandbox_mode="${codexSandbox(req.capability)}"`)
  args.push('-c', `model_reasoning_effort="${codexEffort(req.effort)}"`)

  if (req.model.trim()) args.push('-m', req.model.trim())

  return args
}

/** Maps codex's usage block onto the shared shape. Codex reports no cost. */
export function codexUsage(raw: unknown): Usage {
  const usage = emptyUsage()
  if (raw && typeof raw === 'object') {
    const u = raw as Record<string, unknown>
    const num = (k: string): number => (typeof u[k] === 'number' ? (u[k] as number) : 0)
    usage.inputTokens = num('input_tokens')
    usage.cachedInputTokens = num('cached_input_tokens')
    usage.outputTokens = num('output_tokens')
    usage.reasoningTokens = num('reasoning_output_tokens')
  }
  return usage
}

/** Short activity line for the non-message item types codex reports. */
function activityFor(item: Record<string, unknown>): string | null {
  const type = item['type']
  if (type === 'command_execution') {
    const cmd = item['command']
    return typeof cmd === 'string' ? `run ${describeCommand(cmd)}` : 'run command'
  }
  if (type === 'file_change') {
    const changes = item['changes']
    if (Array.isArray(changes)) {
      const paths = changes
        .map((c) => (c && typeof c === 'object' ? (c as Record<string, unknown>)['path'] : null))
        .filter((p): p is string => typeof p === 'string')
      if (paths.length) return `edit ${paths.slice(0, 3).join(', ')}`
    }
    return 'edit files'
  }
  if (type === 'reasoning') return 'thinking'
  if (type === 'web_search') return 'search'
  return null
}

export class CodexAdapter implements AgentAdapter {
  readonly vendor = 'codex' as const
  readonly binary: string

  constructor(binary = 'codex') {
    this.binary = binary
  }

  /** Absolute path to the CLI, or null when it is not installed. */
  private locate(): string | null {
    return findExecutable(this.binary)
  }

  async run(req: RunRequest): Promise<RunResult> {
    const binary = this.locate()
    if (!binary) {
      return {
        text: '',
        usage: emptyUsage(),
        resumeId: null,
        exitCode: -1,
        error: 'The codex CLI was not found on PATH. Install it and run `codex login`, then restart Parley.',
      }
    }

    const args = buildCodexArgs({
      model: req.cfg.model,
      effort: req.cfg.effort,
      capability: req.capability,
      resumeId: req.resumeId ?? null,
    })

    // No --system-prompt exists, so the role instructions ride on the prompt. On
    // a resumed turn the CLI already holds the role from the first turn, so
    // re-sending it would just burn tokens restating what it knows.
    const body = req.resumeId
      ? req.prompt
      : `${req.systemPrompt}\n\n---\n\n${req.prompt}`

    let resumeId: string | null = req.resumeId ?? null
    let usage: Usage = emptyUsage()
    let errorText: string | null = null
    const messages: string[] = []

    const result = await runJsonl({
      command: binary,
      args,
      cwd: req.cwd,
      // CODEX_HOME points at a config with no MCP servers — see codexHome.ts.
      // Without it a seat dispatched as `read` still inherits whatever tools
      // the user has configured globally, and the filesystem sandbox has no
      // opinion about what an MCP server does.
      env: { ...(req.env ?? {}), ...codexEnv() },
      stdin: body,
      signal: req.signal,
      timeoutMs: req.timeoutMs,
      onEvent: (event) => {
        const type = event['type']

        if (type === 'thread.started') {
          const id = event['thread_id']
          if (typeof id === 'string') resumeId = id
          return
        }

        if (type === 'item.started' || type === 'item.completed') {
          const item = event['item'] as Record<string, unknown> | undefined
          if (!item) return
          if (item['type'] === 'agent_message') {
            if (type === 'item.completed' && typeof item['text'] === 'string') {
              messages.push(item['text'])
              req.onDelta?.(item['text'])
            }
            return
          }
          if (item['type'] === 'error') {
            const msg = item['message']
            errorText = typeof msg === 'string' ? msg : 'codex reported an error'
            return
          }
          if (type === 'item.started') {
            const activity = activityFor(item)
            if (activity) req.onActivity?.(activity)
          }
          return
        }

        if (type === 'turn.completed') {
          usage = codexUsage(event['usage'])
          return
        }

        if (type === 'turn.failed') {
          const err = event['error']
          if (err && typeof err === 'object') {
            const msg = (err as Record<string, unknown>)['message']
            errorText = typeof msg === 'string' ? msg : 'codex turn failed'
          } else {
            errorText = 'codex turn failed'
          }
          return
        }
      },
    })

    const text = messages.join('\n\n').trim()

    if (result.exitCode !== 0 && !errorText) {
      errorText = result.terminated
        ? result.timedOut
          ? `run timed out after ${Math.max(1, Math.round((req.timeoutMs ?? 0) / 60_000))}m`
          : 'run was cancelled'
        : `codex exited ${result.exitCode}: ${cleanStderr(result.stderr) || 'no stderr'}`
    }
    if (!text && !errorText) {
      errorText = `codex produced no output: ${cleanStderr(result.stderr) || 'no stderr'}`
    }

    return { text, usage, resumeId, exitCode: result.exitCode, error: errorText }
  }

  async probe(): Promise<CliHealth> {
    const binary = this.locate()
    if (!binary) {
      return {
        vendor: 'codex',
        present: false,
        version: '',
        authenticated: false,
        detail:
          'codex was not found on PATH. Install the Codex CLI and run `codex login`. If it works in Terminal but not here, launch Parley from Terminal once so it can read your shell PATH.',
      }
    }

    const version = await capture(binary, ['--version'], process.cwd(), 20_000)
    if (version.exitCode !== 0) {
      return {
        vendor: 'codex',
        present: false,
        version: '',
        authenticated: false,
        detail: version.stderr.trim().slice(0, 300) || `${binary} could not be run.`,
      }
    }
    // `login status`, not a real turn.
    //
    // This used to run `codex exec 'Reply with exactly: ready'` on every
    // launch, which is a paid turn against the user's ChatGPT subscription
    // spent to draw a status dot. It also answered the wrong question when it
    // mattered most: at the usage limit the turn fails, so the app reported
    // "codex is installed but did not answer — run `codex login`", sending
    // somebody to re-authenticate an account that was already signed in and
    // simply out of credit until Tuesday.
    //
    // `login status` costs nothing, cannot be defeated by a spent quota, and
    // answers exactly what the dot claims to show. It exits 0 either way, so
    // the text is what to read.
    const auth = await capture(binary, ['login', 'status'], process.cwd(), 20_000)
    const said = `${auth.stdout} ${auth.stderr}`
    const ok = /logged in/i.test(said) && !/not logged in/i.test(said)
    return {
      vendor: 'codex',
      present: true,
      version: version.stdout.trim().split('\n')[0] ?? '',
      authenticated: ok,
      detail: ok
        ? 'Signed in. Usage bills against your ChatGPT subscription.'
        : cleanStderr(auth.stderr).slice(0, 300) ||
          auth.stdout.trim().slice(0, 300) ||
          'codex is installed but not signed in. Run `codex login`.',
    }
  }
}

/** Drops the stdin notice codex always prints, which is noise rather than error. */
function cleanStderr(stderr: string): string {
  return stderr
    .split('\n')
    .filter((l) => !/Reading additional input from stdin/i.test(l))
    .join('\n')
    .trim()
}
