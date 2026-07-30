import { emptyUsage, type Effort, type Usage } from '@shared/domain'

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
