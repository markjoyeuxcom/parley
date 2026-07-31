/**
 * Token and cost accounting, as plain values.
 *
 * This module is a dependency LEAF, and that is its whole reason for existing
 * separately from the domain schemas. The remote execution bundle must contain
 * Parley's own code, Node built-ins, and nothing from node_modules — a rule
 * that is worth keeping absolute, because "no npm, except zod" becomes "except
 * zod and this one harmless utility" and the appliance grows barnacles.
 *
 * The execution core needs exactly one runtime value from the domain —
 * `emptyUsage` — and importing it used to drag the schema library along with
 * it. Schema validation belongs at input and protocol boundaries; a static
 * default should not make the execution engine inherit a validator.
 *
 * So: this file must never import the schemas, Electron, or anything that can
 * reach node_modules. `domain.ts` imports THIS, never the other way round, and
 * re-exports these so existing callers are unaffected. There is still exactly
 * one definition of each value.
 */

export interface Usage {
  inputTokens: number
  cachedInputTokens: number
  outputTokens: number
  reasoningTokens: number
  /**
   * Cost as *reported by the CLI*, in USD. Subscription plans generally report
   * 0, so this is an observability figure and a loop-cap input — never a bill.
   */
  costUsd: number
}

export const emptyUsage = (): Usage => ({
  inputTokens: 0,
  cachedInputTokens: 0,
  outputTokens: 0,
  reasoningTokens: 0,
  costUsd: 0,
})

export const addUsage = (a: Usage, b: Usage): Usage => ({
  inputTokens: a.inputTokens + b.inputTokens,
  cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
  outputTokens: a.outputTokens + b.outputTokens,
  reasoningTokens: a.reasoningTokens + b.reasoningTokens,
  costUsd: a.costUsd + b.costUsd,
})
