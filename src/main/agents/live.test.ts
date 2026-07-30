import { mkdtempSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { AgyAdapter } from './agy'
import { ClaudeAdapter } from './claude'
import { CodexAdapter } from './codex'

/**
 * Live adapter probe.
 *
 * Skipped unless `PARLEY_LIVE=1`, because it really invokes the CLIs and really
 * spends a little of the user's subscription quota. Everything else in the suite
 * runs against the deterministic mocks and proves the wiring; only this proves
 * the *flags* are right — that the argv we construct is accepted, that the event
 * schemas we parse are the ones actually emitted, and that resuming works.
 *
 *   PARLEY_LIVE=1 npx vitest run src/main/agents/live.test.ts
 */
const live = process.env['PARLEY_LIVE'] === '1'

describe.skipIf(!live)('claude adapter against the real CLI', () => {
  it('runs a tool-free turn and reports usage and a resumable session id', async () => {
    const adapter = new ClaudeAdapter()
    const result = await adapter.run({
      systemPrompt: 'You answer with exactly the word requested and nothing else.',
      prompt: 'Reply with exactly: alpha',
      cfg: { vendor: 'claude', model: 'haiku', effort: 'low', persona: '' },
      capability: 'none',
      cwd: tmpdir(),
      timeoutMs: 180_000,
    })

    expect(result.error).toBeNull()
    expect(result.exitCode).toBe(0)
    expect(result.text.toLowerCase()).toContain('alpha')
    // A resume id is what makes the debate protocol cost linear rather than
    // quadratic, so its absence is a real failure and not a nicety.
    expect(result.resumeId).toBeTruthy()
    expect(result.usage.outputTokens).toBeGreaterThan(0)
  }, 200_000)

  it('resumes a session, retaining context across turns', async () => {
    const adapter = new ClaudeAdapter()
    const first = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'Remember the word "quorum". Reply with exactly: stored',
      cfg: { vendor: 'claude', model: 'haiku', effort: 'low', persona: '' },
      capability: 'none',
      cwd: tmpdir(),
      timeoutMs: 180_000,
    })
    expect(first.resumeId).toBeTruthy()

    const second = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'What word did I ask you to remember? Reply with just that word.',
      cfg: { vendor: 'claude', model: 'haiku', effort: 'low', persona: '' },
      capability: 'none',
      cwd: tmpdir(),
      resumeId: first.resumeId,
      timeoutMs: 180_000,
    })

    expect(second.error).toBeNull()
    expect(second.text.toLowerCase()).toContain('quorum')
  }, 400_000)

  it('honours a structured output contract', async () => {
    const adapter = new ClaudeAdapter()
    const result = await adapter.run({
      systemPrompt: 'You follow output contracts exactly.',
      prompt:
        'End your reply with a fenced json block exactly of the form {"met": true, "reason": "short"}. Nothing after it.',
      cfg: { vendor: 'claude', model: 'haiku', effort: 'low', persona: '' },
      capability: 'none',
      cwd: tmpdir(),
      timeoutMs: 180_000,
    })
    expect(result.error).toBeNull()
    expect(result.text).toMatch(/"met"/)
  }, 200_000)
})

describe.skipIf(!live)('codex adapter against the real CLI', () => {
  it('runs a sandboxed turn and reports a resumable thread id', async () => {
    const adapter = new CodexAdapter()
    const result = await adapter.run({
      systemPrompt: 'You answer with exactly the word requested and nothing else.',
      prompt: 'Reply with exactly: beta',
      cfg: { vendor: 'codex', model: '', effort: 'low', persona: '' },
      capability: 'read',
      cwd: tmpdir(),
      timeoutMs: 240_000,
    })

    expect(result.error).toBeNull()
    expect(result.exitCode).toBe(0)
    expect(result.text.toLowerCase()).toContain('beta')
    expect(result.resumeId).toBeTruthy()
    expect(result.usage.inputTokens).toBeGreaterThan(0)
  }, 260_000)

  it('resumes a thread — the path where -s would have failed', async () => {
    // `codex exec resume` rejects -s/--sandbox, so the adapter sets the sandbox
    // through `-c sandbox_mode=...` instead. This test is the reason that choice
    // is not guesswork.
    const adapter = new CodexAdapter()
    const first = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'Remember the word "lattice". Reply with exactly: stored',
      cfg: { vendor: 'codex', model: '', effort: 'low', persona: '' },
      capability: 'read',
      cwd: tmpdir(),
      timeoutMs: 240_000,
    })
    expect(first.resumeId).toBeTruthy()

    const second = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'What word did I ask you to remember? Reply with just that word.',
      cfg: { vendor: 'codex', model: '', effort: 'low', persona: '' },
      capability: 'read',
      cwd: tmpdir(),
      resumeId: first.resumeId,
      timeoutMs: 240_000,
    })

    expect(second.error).toBeNull()
    expect(second.text.toLowerCase()).toContain('lattice')
  }, 500_000)
})

describe.skipIf(!live)('agy adapter against the real CLI', () => {
  const cfg = {
    vendor: 'agy' as const,
    model: 'gemini-3-flash-low',
    effort: 'low' as const,
    persona: '',
  }

  it('runs tool-free with stdin, reports usage and returns a conversation id', async () => {
    const requestedCwd = mkdtempSync(join(tmpdir(), 'parley-agy-live-'))
    const result = await new AgyAdapter().run({
      systemPrompt: 'You answer with exactly the word requested and nothing else.',
      prompt: 'Reply with exactly: gamma',
      cfg,
      capability: 'none',
      cwd: requestedCwd,
      timeoutMs: 180_000,
    })

    expect(result.error).toBeNull()
    expect(result.exitCode).toBe(0)
    expect(result.text.toLowerCase()).toContain('gamma')
    expect(result.resumeId).toBeTruthy()
    expect(result.usage.outputTokens).toBeGreaterThan(0)
    expect(readdirSync(requestedCwd)).toEqual([])
  }, 200_000)

  it('resumes with --conversation and retains context', async () => {
    const adapter = new AgyAdapter()
    const first = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'Remember the word "keystone". Reply with exactly: stored',
      cfg,
      capability: 'none',
      cwd: tmpdir(),
      timeoutMs: 180_000,
    })
    expect(first.resumeId).toBeTruthy()

    const second = await adapter.run({
      systemPrompt: 'You are terse.',
      prompt: 'What word did I ask you to remember? Reply with just that word.',
      cfg,
      capability: 'none',
      cwd: tmpdir(),
      resumeId: first.resumeId,
      timeoutMs: 180_000,
    })

    expect(second.error).toBeNull()
    expect(second.text.toLowerCase()).toContain('keystone')
  }, 400_000)

  it('observes a denied mutation without allowing a scratch write', async () => {
    const requestedCwd = mkdtempSync(join(tmpdir(), 'parley-agy-live-denied-'))
    const result = await new AgyAdapter().run({
      systemPrompt:
        'Attempt the requested file operation once. If permission is denied, say exactly: denied.',
      prompt: 'Create a file named forbidden.txt containing one word.',
      cfg,
      capability: 'none',
      cwd: requestedCwd,
      timeoutMs: 180_000,
    })

    expect(result.error).toBeNull()
    expect(result.text.toLowerCase()).toContain('denied')
    expect(readdirSync(requestedCwd)).toEqual([])
  }, 200_000)
})

describe.skipIf(!live)('cli health probes', () => {
  it('detects all CLIs as present and signed in', async () => {
    const [claude, codex, agy] = await Promise.all([
      new ClaudeAdapter().probe(),
      new CodexAdapter().probe(),
      new AgyAdapter().probe(),
    ])

    expect(claude.present).toBe(true)
    expect(claude.authenticated).toBe(true)
    expect(claude.version).toBeTruthy()

    expect(codex.present).toBe(true)
    expect(codex.authenticated).toBe(true)
    expect(codex.version).toBeTruthy()

    expect(agy.present).toBe(true)
    expect(agy.authenticated).toBe(true)
    expect(agy.version).toBeTruthy()
  }, 400_000)
})
