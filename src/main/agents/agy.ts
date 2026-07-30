import { mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { emptyUsage, type Capability, type Effort, type Usage } from '@shared/domain'
import type { CliHealth } from '@shared/ipc'
import { capture, runJsonl } from '@main/util/spawn'
import { findExecutable } from '@main/util/environment'
import type { AgentAdapter, RunRequest, RunResult } from './types'

export type AgyEffortTier = 'low' | 'medium' | 'high'

/** Agy exposes three reasoning tiers; fold Parley's higher tiers onto its ceiling. */
export function agyEffortTier(effort: Effort): AgyEffortTier {
  switch (effort) {
    case 'low':
      return 'low'
    case 'medium':
      return 'medium'
    default:
      return 'high'
  }
}

/**
 * Resolves an Agy model without inventing a slug the installed CLI did not list.
 *
 * Explicit tiered slugs are already complete. For a base slug, prefer the
 * matching effort variant only when discovery proved that exact variant exists.
 */
export function agyModelSlug(
  model: string,
  effort: Effort,
  available: readonly string[],
): string {
  const chosen = model.trim()
  if (!chosen || /-(?:low|medium|high)$/i.test(chosen)) return chosen

  const tiered = `${chosen}-${agyEffortTier(effort)}`
  return available.includes(tiered) ? tiered : chosen
}

/** Agy is a vendor surface, but Parley's first integration admits Gemini models only. */
export function isGeminiModel(model: string): boolean {
  return /^gemini-.+/i.test(model.trim())
}

export function agyModelRefusal(model: string): string | null {
  if (isGeminiModel(model)) return null
  return model.trim()
    ? 'Agy is limited to gemini-* models in this version of Parley.'
    : 'Agy requires an explicit gemini-* model in this version of Parley.'
}

/** Formats Parley's millisecond deadline for Agy's Go-duration flag. */
export function agyPrintTimeout(timeoutMs: number): string {
  const seconds =
    Number.isFinite(timeoutMs) && timeoutMs > 0 ? Math.max(1, Math.ceil(timeoutMs / 1000)) : 1
  return `${seconds}s`
}

export function buildAgyArgs(req: {
  model: string
  effort: Effort
  available: readonly string[]
  resumeId?: string | null
  timeoutMs?: number
}): string[] {
  const args = ['-p', '--output-format', 'stream-json']
  const model = agyModelSlug(req.model, req.effort, req.available)

  if (model) args.push('--model', model)
  if (req.resumeId) args.push('--conversation', req.resumeId)
  if (req.timeoutMs !== undefined) {
    args.push('--print-timeout', agyPrintTimeout(req.timeoutMs))
  }

  return args
}

/** Maps Agy's terminal result usage onto the shared shape. Agy reports no cost. */
export function agyUsage(raw: unknown): Usage {
  const usage = emptyUsage()
  if (raw && typeof raw === 'object') {
    const u = raw as Record<string, unknown>
    const num = (key: string): number => (typeof u[key] === 'number' ? (u[key] as number) : 0)
    usage.inputTokens = num('input_tokens')
    usage.cachedInputTokens = num('cache_read_tokens')
    usage.outputTokens = num('output_tokens')
    usage.reasoningTokens = num('thinking_tokens')
  }
  return usage
}

/**
 * Refuses a run whose prompt was not handed to stdin. Agy argv deliberately has
 * no prompt field, so silently continuing would otherwise run the wrong turn.
 */
export function promptDeliveryRefusal(prompt: string, stdinDelivered: boolean): string | null {
  if (!prompt || stdinDelivered) return null
  return 'Agy prompt delivery to stdin failed; refusing the incomplete run.'
}

export function scratchViolation(entries: readonly string[]): string | null {
  if (!entries.length) return null
  return `Agy wrote to its isolated scratch directory (${entries.join(', ')}); refusing the run`
}

function refused(error: string): RunResult {
  return {
    text: '',
    usage: emptyUsage(),
    resumeId: null,
    exitCode: -1,
    error,
  }
}

export class AgyAdapter implements AgentAdapter {
  readonly vendor = 'agy' as const
  readonly binary: string

  constructor(
    binary = 'agy',
    private readonly availableModels: readonly string[] = [],
  ) {
    this.binary = binary
  }

  private locate(): string | null {
    return findExecutable(this.binary)
  }

  async run(req: RunRequest): Promise<RunResult> {
    if (req.capability !== 'none') {
      return refused('Agy is tool-less in Parley and refuses repository capability above none.')
    }

    const modelRefusal = agyModelRefusal(req.cfg.model)
    if (modelRefusal) return refused(modelRefusal)

    const binary = this.locate()
    if (!binary) {
      return refused(
        'The agy CLI was not found on PATH. Install Antigravity CLI and sign in, then restart Parley.',
      )
    }

    const scratch = mkdtempSync(join(tmpdir(), 'parley-agy-'))
    try {
      const args = buildAgyArgs({
        model: req.cfg.model,
        effort: req.cfg.effort,
        available: this.availableModels,
        resumeId: req.resumeId ?? null,
        timeoutMs: req.timeoutMs,
      })
      const body = req.resumeId
        ? req.prompt
        : `${req.systemPrompt}\n\n---\n\n${req.prompt}`

      let resumeId: string | null = req.resumeId ?? null
      let finalText = ''
      let streamed = ''
      let usage = emptyUsage()
      let errorText: string | null = null

      const result = await runJsonl({
        command: binary,
        args,
        cwd: scratch,
        stdin: body,
        signal: req.signal,
        timeoutMs: req.timeoutMs,
        onEvent: (event) => {
          if (event['event'] === 'init') {
            const id = event['conversation_id']
            if (typeof id === 'string') resumeId = id
            return
          }

          if (event['event'] === 'step_update') {
            const update = event['step_update'] as Record<string, unknown> | undefined
            if (
              update?.['step_type'] === 'agent_response' &&
              typeof update['text_delta'] === 'string'
            ) {
              streamed += update['text_delta']
              req.onDelta?.(update['text_delta'])
            }
            return
          }

          if (event['event'] === 'result') {
            const terminal = event['result'] as Record<string, unknown> | undefined
            if (!terminal) return
            if (typeof terminal['conversation_id'] === 'string') {
              resumeId = terminal['conversation_id']
            }
            if (typeof terminal['response'] === 'string') finalText = terminal['response']
            usage = agyUsage(terminal['usage'])
            if (terminal['status'] !== 'SUCCESS') {
              errorText = `agy reported ${String(terminal['status'] ?? 'an unknown failure')}`
            }
          }
        },
      })

      errorText ??= promptDeliveryRefusal(body, result.stdinDelivered)

      if (result.exitCode !== 0 && !errorText) {
        errorText = result.terminated
          ? result.timedOut
            ? `run timed out after ${Math.max(1, Math.round((req.timeoutMs ?? 0) / 60_000))}m`
            : 'run was cancelled'
          : `agy exited ${result.exitCode}: ${result.stderr.trim().slice(0, 800) || 'no stderr'}`
      }

      const text = (finalText || streamed).trim()
      if (!text && !errorText) {
        errorText = `agy produced no output: ${result.stderr.trim().slice(0, 800) || 'no stderr'}`
      }

      try {
        errorText ??= scratchViolation(readdirSync(scratch))
      } catch (err) {
        errorText = `Agy scratch directory could not be inspected: ${err instanceof Error ? err.message : String(err)}`
      }

      return { text, usage, resumeId, exitCode: result.exitCode, error: errorText }
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  }

  async probe(): Promise<CliHealth> {
    const binary = this.locate()
    if (!binary) {
      return {
        vendor: 'agy',
        present: false,
        version: '',
        authenticated: false,
        detail:
          'agy was not found on PATH. Install Antigravity CLI and sign in. If it works in Terminal but not here, launch Parley from Terminal once so it can read your shell PATH.',
      }
    }

    const version = await capture(binary, ['--version'], process.cwd(), 20_000)
    if (version.exitCode !== 0) {
      return {
        vendor: 'agy',
        present: false,
        version: '',
        authenticated: false,
        detail: version.stderr.trim().slice(0, 300) || `${binary} could not be run.`,
      }
    }

    const auth = await this.run({
      systemPrompt: 'You answer with exactly the requested word and nothing else.',
      prompt: 'Reply with exactly: ready',
      cfg: { vendor: 'agy', model: 'gemini-3-flash-low', effort: 'low', persona: '' },
      capability: 'none',
      cwd: process.cwd(),
      timeoutMs: 120_000,
    })
    const ok = auth.error === null && /ready/i.test(auth.text)
    return {
      vendor: 'agy',
      present: true,
      version: version.stdout.trim().split('\n')[0] ?? '',
      authenticated: ok,
      detail: ok
        ? 'Signed in. Usage bills against your Google subscription.'
        : auth.error || 'agy is installed but did not answer. Run `agy` once to sign in.',
    }
  }
}
