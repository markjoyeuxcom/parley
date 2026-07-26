import { describe, expect, it } from 'vitest'
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

  it('survives a malformed or absent usage block', () => {
    expect(claudeUsage(undefined, undefined).inputTokens).toBe(0)
    expect(codexUsage('nonsense').outputTokens).toBe(0)
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
