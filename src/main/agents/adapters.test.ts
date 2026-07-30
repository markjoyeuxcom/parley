import { describe, expect, it } from 'vitest'
import {
  AgyAdapter,
  agyEffortTier,
  agyModelRefusal,
  agyModelSlug,
  agyPrintTimeout,
  agyToolViolation,
  agyUsage,
  buildAgyArgs,
  isGeminiModel,
  parseAgyModels,
  promptDeliveryRefusal,
  scratchViolation,
} from './agy'
import { buildClaudeArgs, claudeUsage } from './claude'
import { buildCodexArgs, codexEffort, codexSandbox, codexUsage } from './codex'
import { assertCapability, CapabilityError } from './types'

describe('claude argument construction', () => {
  const base = { systemPrompt: 'be terse', model: 'opus', effort: 'high', repoAttached: false }

  it('always pairs stream-json with --verbose', () => {
    // The CLI rejects stream-json without it, so this pairing is not optional.
    const args = buildClaudeArgs({ ...base, capability: 'none' })
    expect(args).toContain('--output-format')
    expect(args[args.indexOf('--output-format') + 1]).toBe('stream-json')
    expect(args).toContain('--verbose')
  })

  it('disables every tool for a pure argument turn', () => {
    const args = buildClaudeArgs({ ...base, capability: 'none' })
    expect(args[args.indexOf('--tools') + 1]).toBe('')
    // With no tools to explain, replacing the system prompt is safe.
    expect(args).toContain('--system-prompt')
    expect(args).not.toContain('--append-system-prompt')
  })

  it('grants only read tools at read capability', () => {
    const args = buildClaudeArgs({ ...base, capability: 'read' })
    const toolsAt = args.indexOf('--tools')
    expect(args.slice(toolsAt + 1, toolsAt + 4)).toEqual(['Read', 'Glob', 'Grep'])
    // Appends so Claude Code keeps its own guidance on using those tools.
    expect(args).toContain('--append-system-prompt')
    expect(args).not.toContain('--system-prompt')
  })

  it('never passes a dangerous permission flag at any capability', () => {
    for (const capability of ['none', 'read', 'write'] as const) {
      const args = buildClaudeArgs({ ...base, capability })
      const joined = args.join(' ')
      expect(joined).not.toContain('dangerously')
      expect(joined).not.toContain('bypassPermissions')
    }
  })

  it('pins MCP config so a governed run cannot inherit global servers', () => {
    expect(buildClaudeArgs({ ...base, capability: 'read' })).toContain('--strict-mcp-config')
  })

  it('resumes by session id when one is supplied', () => {
    const args = buildClaudeArgs({ ...base, capability: 'read', resumeId: 'abc-123' })
    expect(args[args.indexOf('--resume') + 1]).toBe('abc-123')
  })

  it('omits --model and --effort when unset rather than passing empty strings', () => {
    const args = buildClaudeArgs({ ...base, model: '', effort: '', capability: 'none' })
    expect(args).not.toContain('--model')
    expect(args).not.toContain('--effort')
  })
})

describe('codex argument construction', () => {
  const base = { model: '', effort: 'medium' as const, capability: 'read' as const }

  it('closes over the resume asymmetry by setting the sandbox through -c', () => {
    // `codex exec resume` has no -s/--sandbox. Using -c means the same code path
    // sandboxes both the first turn and every resumed turn.
    const first = buildCodexArgs(base)
    const resumed = buildCodexArgs({ ...base, resumeId: 'thread-1' })
    expect(first).not.toContain('-s')
    expect(resumed).not.toContain('-s')
    expect(first).toContain('sandbox_mode="read-only"')
    expect(resumed).toContain('sandbox_mode="read-only"')
  })

  it('puts `resume <id>` immediately after `exec`', () => {
    const args = buildCodexArgs({ ...base, resumeId: 'thread-1' })
    expect(args.slice(0, 3)).toEqual(['exec', 'resume', 'thread-1'])
  })

  it('always skips the git repo check so non-repo directories work', () => {
    expect(buildCodexArgs(base)).toContain('--skip-git-repo-check')
  })

  it('never selects the unsandboxed mode', () => {
    for (const capability of ['none', 'read', 'write'] as const) {
      const joined = buildCodexArgs({ ...base, capability }).join(' ')
      expect(joined).not.toContain('danger-full-access')
      expect(joined).not.toContain('dangerously')
    }
  })

  it('maps capability onto the sandbox mode', () => {
    expect(codexSandbox('none')).toBe('read-only')
    expect(codexSandbox('read')).toBe('read-only')
    expect(codexSandbox('write')).toBe('workspace-write')
  })

  it('folds claude-only effort levels down to codex range', () => {
    expect(codexEffort('low')).toBe('low')
    expect(codexEffort('medium')).toBe('medium')
    expect(codexEffort('high')).toBe('high')
    expect(codexEffort('xhigh')).toBe('high')
    expect(codexEffort('max')).toBe('high')
  })
})

describe('agy argument construction', () => {
  const available = [
    'gemini-3-flash-low',
    'gemini-3-flash-medium',
    'gemini-3-flash-high',
    'gemini-3-pro',
  ] as const
  const base = {
    model: 'gemini-3-flash',
    effort: 'medium' as const,
    available,
    timeoutMs: 180_000,
  }

  it('keeps only discovered Gemini entries, in CLI order without duplicates', () => {
    expect(
      parseAgyModels(
        [
          'MODEL                         DESCRIPTION',
          'gemini-3-pro                  Gemini 3 Pro',
          'claude-sonnet-4-5             Claude Sonnet',
          'gemini-3-flash-high           Gemini 3 Flash',
          'gemini-3-pro                  duplicate',
          'not-gemini-3-flash-low        ineligible',
        ].join('\n'),
      ),
    ).toEqual(['gemini-3-pro', 'gemini-3-flash-high'])
  })

  it('memoises model discovery on the adapter', async () => {
    const adapter = new AgyAdapter('/definitely/missing/agy')
    const first = adapter.models()
    expect(adapter.models()).toBe(first)
    await expect(first).resolves.toEqual([])
  })

  it('folds Parley effort onto Agy tiers without passing --effort', () => {
    expect(agyEffortTier('low')).toBe('low')
    expect(agyEffortTier('medium')).toBe('medium')
    expect(agyEffortTier('high')).toBe('high')
    expect(agyEffortTier('xhigh')).toBe('high')
    expect(agyEffortTier('max')).toBe('high')

    const args = buildAgyArgs(base)
    expect(args).not.toContain('--effort')
    expect(args[args.indexOf('--model') + 1]).toBe('gemini-3-flash-medium')
  })

  it('never fabricates a tiered model missing from discovery', () => {
    expect(agyModelSlug('gemini-3-pro', 'high', available)).toBe('gemini-3-pro')
    expect(agyModelSlug('gemini-3-flash-high', 'low', available)).toBe(
      'gemini-3-flash-high',
    )
    expect(agyModelSlug('gemini-3-flash', 'high', [])).toBe('gemini-3-flash')
  })

  it('resumes with --conversation and never --continue', () => {
    const args = buildAgyArgs({ ...base, resumeId: 'conversation-1' })
    expect(args[args.indexOf('--conversation') + 1]).toBe('conversation-1')
    expect(args).not.toContain('--continue')
    expect(args).not.toContain('-c')
  })

  it('passes no print flag at all — piped stdin is the delivery', () => {
    const args = buildAgyArgs(base)
    expect(args.slice(0, 2)).toEqual(['--output-format', 'stream-json'])
    // Bare -p swallows the next token as its prompt (the first live seat
    // answered the literal question "--output-format" that way), and -p with
    // a value puts the brief in the process table. Flagless with a non-TTY
    // stdin, agy runs headless and reads the prompt from the pipe.
    expect(args).not.toContain('-p')
    expect(args).not.toContain('--print')
    expect(args[args.indexOf('--print-timeout') + 1]).toBe('180s')
    expect(agyPrintTimeout(1_001)).toBe('2s')
    expect(args.join(' ')).not.toContain('prompt')
  })

  it('fails a turn in which agy executed any tool, naming each once', () => {
    expect(agyToolViolation([])).toBeNull()
    const refusal = agyToolViolation(['run_command', 'run_command', 'write_to_file'])
    expect(refusal).toContain('run_command, write_to_file')
    expect(refusal).toContain('permissions.allow')
  })

  it('admits only explicit Gemini model slugs', () => {
    expect(isGeminiModel(' gemini-3-flash-high ')).toBe(true)
    expect(isGeminiModel('claude-sonnet-4-5')).toBe(false)
    expect(isGeminiModel('gemini-')).toBe(false)
    expect(agyModelRefusal('gemini-3-pro')).toBeNull()
    expect(agyModelRefusal('gpt-oss-120b')).toContain('gemini-*')
    expect(agyModelRefusal('')).toContain('explicit')
  })

  it('refuses a non-empty prompt that was not delivered to stdin', () => {
    expect(promptDeliveryRefusal('make the case', true)).toBeNull()
    expect(promptDeliveryRefusal('', false)).toBeNull()
    expect(promptDeliveryRefusal('make the case', false)).toContain('stdin')
  })

  it('fails closed when the isolated scratch directory is not empty', () => {
    expect(scratchViolation([])).toBeNull()
    expect(scratchViolation(['created.txt', 'nested'])).toContain('created.txt, nested')
  })
})

describe('usage mapping', () => {
  it('folds both claude cache counters into cachedInputTokens', () => {
    const usage = claudeUsage(
      { input_tokens: 10, output_tokens: 40, cache_read_input_tokens: 100, cache_creation_input_tokens: 6652 },
      0.014095,
    )
    expect(usage.inputTokens).toBe(10)
    expect(usage.outputTokens).toBe(40)
    expect(usage.cachedInputTokens).toBe(6752)
    expect(usage.costUsd).toBeCloseTo(0.014095)
  })

  it('reads codex reasoning tokens, which claude reports differently', () => {
    const usage = codexUsage({
      input_tokens: 15603,
      cached_input_tokens: 12,
      output_tokens: 5,
      reasoning_output_tokens: 64,
    })
    expect(usage.inputTokens).toBe(15603)
    expect(usage.cachedInputTokens).toBe(12)
    expect(usage.reasoningTokens).toBe(64)
    expect(usage.costUsd).toBe(0)
  })

  it('reads Agy thinking and cache tokens from its terminal usage block', () => {
    const usage = agyUsage({
      input_tokens: 9824,
      output_tokens: 35,
      thinking_tokens: 29,
      cache_read_tokens: 8140,
      total_tokens: 9859,
    })
    expect(usage.inputTokens).toBe(9824)
    expect(usage.cachedInputTokens).toBe(8140)
    expect(usage.outputTokens).toBe(35)
    expect(usage.reasoningTokens).toBe(29)
    expect(usage.costUsd).toBe(0)
  })

  it('survives a malformed or absent usage block', () => {
    expect(claudeUsage(undefined, undefined).inputTokens).toBe(0)
    expect(codexUsage('nonsense').outputTokens).toBe(0)
    expect(agyUsage(null).reasoningTokens).toBe(0)
  })
})

describe('capability guard', () => {
  it('refuses write without a consumed approval', () => {
    expect(() => assertCapability('write', false)).toThrow(CapabilityError)
  })

  it('allows write once approval is proven', () => {
    expect(() => assertCapability('write', true)).not.toThrow()
  })

  it('never blocks read or none', () => {
    expect(() => assertCapability('read', false)).not.toThrow()
    expect(() => assertCapability('none', false)).not.toThrow()
  })
})
