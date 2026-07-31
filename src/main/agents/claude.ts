import { type Capability, type Usage } from '@shared/domain'
import { emptyUsage } from '@shared/usage'
import type { CliHealth } from '@shared/ipc'
import { capture, runJsonl } from '@main/util/spawn'
import { findExecutable } from '@main/util/environment'
import { describeCommand } from './activity'
import type { AgentAdapter, RunRequest, RunResult } from './types'

/**
 * Claude Code adapter.
 *
 * Invoked as `claude -p --output-format stream-json`, which streams the whole
 * run as newline-delimited JSON. Quirks that cost real time to discover and are
 * load-bearing here:
 *
 *  • `--output-format stream-json` requires `--verbose`, or the CLI refuses.
 *  • The prompt goes on **stdin**, not argv — argv would blow the length limit
 *    on a long brief and would put user text in the process table.
 *  • Deltas only arrive with `--include-partial-messages`.
 *  • `assistant` messages carry `thinking` blocks alongside `text` blocks; only
 *    the text blocks are the reply.
 *  • The session id to resume comes from the `system`/`init` event.
 *  • The final `result` event carries the complete text, so the transcript does
 *    not have to be reassembled from deltas.
 */

/** Read-only tool set. Nothing here can mutate the working tree. */
const READ_TOOLS = ['Read', 'Glob', 'Grep']

export function buildClaudeArgs(req: {
  systemPrompt: string
  model: string
  effort: string
  capability: Capability
  repoAttached: boolean
  resumeId?: string | null
}): string[] {
  const args = ['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages']

  if (req.model.trim()) args.push('--model', req.model.trim())
  if (req.effort.trim()) args.push('--effort', req.effort.trim())

  // Only explicitly-passed MCP servers may load. Without this a governed run
  // would silently inherit whatever servers the user has configured globally,
  // which makes runs unreproducible and widens the tool surface.
  args.push('--strict-mcp-config')

  if (req.capability === 'none') {
    // A pure argument turn. Replacing the default system prompt is safe here
    // because there are no tools whose usage instructions we'd be discarding.
    args.push('--tools', '')
    args.push('--system-prompt', req.systemPrompt)
    args.push('--permission-mode', 'dontAsk')
  } else if (req.capability === 'read') {
    args.push('--tools', ...READ_TOOLS)
    // Append rather than replace: Claude Code's own instructions on how to use
    // its file tools are worth keeping.
    args.push('--append-system-prompt', req.systemPrompt)
    // Safe because the tool set above contains no mutating tool, and it stops a
    // permission prompt from deadlocking a non-interactive run.
    args.push('--permission-mode', 'dontAsk')
  } else {
    args.push('--append-system-prompt', req.systemPrompt)
    args.push('--permission-mode', 'acceptEdits')
  }

  if (req.repoAttached) args.push('--add-dir', '.')
  if (req.resumeId) args.push('--resume', req.resumeId)

  return args
}

interface ContentBlock {
  type?: string
  text?: string
}

function textFromContent(content: unknown): string {
  if (!Array.isArray(content)) return ''
  return content
    .filter((b): b is ContentBlock => !!b && typeof b === 'object')
    .filter((b) => b.type === 'text' && typeof b.text === 'string')
    .map((b) => b.text as string)
    .join('')
}

/** Maps Claude's usage block onto the shared shape. */
export function claudeUsage(raw: unknown, costUsd: unknown): Usage {
  const usage = emptyUsage()
  if (raw && typeof raw === 'object') {
    const u = raw as Record<string, unknown>
    const num = (k: string): number => (typeof u[k] === 'number' ? (u[k] as number) : 0)
    usage.inputTokens = num('input_tokens')
    usage.outputTokens = num('output_tokens')
    usage.cachedInputTokens = num('cache_read_input_tokens') + num('cache_creation_input_tokens')
  }
  if (typeof costUsd === 'number' && Number.isFinite(costUsd)) usage.costUsd = costUsd
  return usage
}

/** Turns a tool_use block into a short human-readable activity line. */
function activityFor(block: Record<string, unknown>): string | null {
  if (block['type'] !== 'tool_use') return null
  const name = typeof block['name'] === 'string' ? block['name'] : 'tool'
  const input = (block['input'] ?? {}) as Record<string, unknown>

  // `command` first: a Bash tool use otherwise reports the bare word "Bash",
  // which is the least informative line the feed can show.
  const target =
    (typeof input['command'] === 'string' && describeCommand(input['command'])) ||
    (typeof input['file_path'] === 'string' && input['file_path']) ||
    (typeof input['pattern'] === 'string' && input['pattern']) ||
    (typeof input['path'] === 'string' && input['path']) ||
    ''
  return target ? `${name} ${target}` : name
}

export class ClaudeAdapter implements AgentAdapter {
  readonly vendor = 'claude' as const
  readonly binary: string

  constructor(binary = 'claude') {
    this.binary = binary
  }

  /**
   * Absolute path to the CLI, or null when it is not installed.
   *
   * Not memoised: a user who installs the CLI while Parley is open should be
   * able to retry without restarting, and a PATH lookup is a few stat calls.
   */
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
        error:
          'The claude CLI was not found on PATH. Install Claude Code and sign in, then restart Parley.',
      }
    }

    const args = buildClaudeArgs({
      systemPrompt: req.systemPrompt,
      model: req.cfg.model,
      effort: req.cfg.effort,
      capability: req.capability,
      repoAttached: req.capability !== 'none',
      resumeId: req.resumeId ?? null,
    })

    let resumeId: string | null = null
    let finalText = ''
    let streamed = ''
    let errorText: string | null = null
    let usage: Usage = emptyUsage()

    const result = await runJsonl({
      command: binary,
      args,
      cwd: req.cwd,
      env: req.env,
      stdin: req.prompt,
      signal: req.signal,
      timeoutMs: req.timeoutMs,
      onEvent: (event) => {
        const type = event['type']

        if (type === 'system' && event['subtype'] === 'init') {
          const id = event['session_id']
          if (typeof id === 'string') resumeId = id
          return
        }

        // Partial text, emitted because of --include-partial-messages. The
        // wrapper name has moved between CLI versions, so accept both shapes.
        if (type === 'stream_event' || type === 'content_block_delta') {
          const inner = (type === 'stream_event' ? event['event'] : event) as
            | Record<string, unknown>
            | undefined
          if (inner && inner['type'] === 'content_block_delta') {
            const delta = inner['delta'] as Record<string, unknown> | undefined
            if (delta && delta['type'] === 'text_delta' && typeof delta['text'] === 'string') {
              streamed += delta['text']
              req.onDelta?.(delta['text'])
            }
          }
          return
        }

        if (type === 'assistant') {
          const message = event['message'] as Record<string, unknown> | undefined
          const content = message?.['content']
          if (Array.isArray(content)) {
            for (const block of content) {
              if (block && typeof block === 'object') {
                const activity = activityFor(block as Record<string, unknown>)
                if (activity) req.onActivity?.(activity)
              }
            }
          }
          return
        }

        if (type === 'result') {
          if (typeof event['result'] === 'string') finalText = event['result']
          if (event['is_error'] === true) {
            errorText =
              typeof event['result'] === 'string' && event['result']
                ? event['result']
                : `claude reported an error (${String(event['subtype'] ?? 'unknown')})`
          }
          usage = claudeUsage(event['usage'], event['total_cost_usd'])
          return
        }
      },
    })

    const text = (finalText || streamed).trim()

    if (result.exitCode !== 0 && !errorText) {
      errorText = result.terminated
        ? result.timedOut
          ? `run timed out after ${Math.max(1, Math.round((req.timeoutMs ?? 0) / 60_000))}m`
          : 'run was cancelled'
        : `claude exited ${result.exitCode}: ${result.stderr.trim().slice(0, 800) || 'no stderr'}`
    }
    if (!text && !errorText) {
      errorText = `claude produced no output: ${result.stderr.trim().slice(0, 800) || 'no stderr'}`
    }

    return { text, usage, resumeId, exitCode: result.exitCode, error: errorText }
  }

  async probe(): Promise<CliHealth> {
    const binary = this.locate()
    if (!binary) {
      return {
        vendor: 'claude',
        present: false,
        version: '',
        authenticated: false,
        detail:
          'claude was not found on PATH. Install Claude Code and sign in. If it works in Terminal but not here, launch Parley from Terminal once so it can read your shell PATH.',
      }
    }

    const version = await capture(binary, ['--version'], process.cwd(), 20_000)
    if (version.exitCode !== 0) {
      return {
        vendor: 'claude',
        present: false,
        version: '',
        authenticated: false,
        detail: version.stderr.trim().slice(0, 300) || `${binary} could not be run.`,
      }
    }
    // A trivial tool-free prompt is the only reliable way to tell "installed"
    // from "installed and signed in". It costs a handful of tokens.
    const auth = await capture(
      binary,
      ['-p', '--tools', '', '--model', 'haiku', 'Reply with exactly: ready'],
      process.cwd(),
      90_000,
    )
    const ok = auth.exitCode === 0 && /ready/i.test(auth.stdout)
    return {
      vendor: 'claude',
      present: true,
      version: version.stdout.trim().split('\n')[0] ?? '',
      authenticated: ok,
      detail: ok
        ? 'Signed in. Usage bills against your Claude subscription.'
        : (auth.stderr.trim() || auth.stdout.trim()).slice(0, 300) ||
          'claude is installed but did not answer. Run `claude` once to sign in.',
    }
  }
}
