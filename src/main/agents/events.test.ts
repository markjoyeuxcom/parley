import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { ClaudeAdapter } from './claude'
import { CodexAdapter } from './codex'

/**
 * Captured NDJSON from each real CLI, replayed offline through the public
 * `run` methods — the production parse loop meets a genuine protocol stream
 * on every suite run, not only behind PARLEY_LIVE.
 *
 * Provenance (the fixtures are recordings, never hand-authored):
 *  • Captured 2026-07-29 on macOS against Claude Code 2.1.220 and
 *    codex-cli 0.145.0, in a probe directory holding only a three-line
 *    package.json, by the operator outside the pipeline — the executor's own
 *    sandbox blocks network, so a milestone can never invoke a live CLI; that
 *    refusal is on the plan record.
 *  • claude-stream.ndjson: `claude -p --output-format stream-json --verbose
 *    --include-partial-messages --strict-mcp-config --tools Read Glob Grep
 *    --append-system-prompt <probe role> --permission-mode dontAsk
 *    --add-dir .` with the prompt on stdin: "Use the Read tool exactly once
 *    to read package.json, then reply with exactly: parley" — the argv
 *    buildClaudeArgs produces for a read turn.
 *  • codex-exec.ndjson: `codex exec --json --skip-git-repo-check
 *    -c sandbox_mode="read-only" -c model_reasoning_effort="high"` with the
 *    system prompt and instruction joined on stdin, as buildCodexArgs and
 *    CodexAdapter.run send them.
 *  • Scrubbing: machine paths were rewritten to /scrubbed/… by walking every
 *    JSON string, and the input_json_delta fragments (which stream the tool
 *    input in path-splitting chunks) were emptied — the parser ignores that
 *    delta type entirely. Event names, ids, ordering, usage numbers and text
 *    are untouched.
 *
 * Success arms only, per the plan's audit: error shapes are not fabricated
 * here; a real error stream gets captured when one is actually observed.
 *
 * Every expectation below is a literal from the recording, so renaming a
 * load-bearing key or event in the stream contract — session_id, result,
 * thread_id, agent_message, turn.completed — turns this file red.
 */

const claudeFixture = fileURLToPath(new URL('./fixtures/claude-stream.ndjson', import.meta.url))
const codexFixture = fileURLToPath(new URL('./fixtures/codex-exec.ndjson', import.meta.url))

/** An executable that ignores its arguments and stdin and replays a recording. */
function shimFor(fixture: string): string {
  const dir = mkdtempSync(join(tmpdir(), 'parley-cli-shim-'))
  const shim = join(dir, 'replay-cli')
  writeFileSync(shim, `#!/bin/sh\nexec cat "${fixture}"\n`)
  chmodSync(shim, 0o755)
  return shim
}

const cfg = { model: '', effort: 'high' as const, persona: '' }

describe('captured Claude stream through ClaudeAdapter.run', () => {
  it('parses resume id, deltas, activity, final text and usage from the recording', async () => {
    const adapter = new ClaudeAdapter(shimFor(claudeFixture))
    const deltas: string[] = []
    const activity: string[] = []

    const reply = await adapter.run({
      systemPrompt: 'You are a capture probe.',
      prompt: 'Use the Read tool exactly once to read package.json, then reply with exactly: parley',
      cfg: { vendor: 'claude', ...cfg },
      capability: 'read',
      cwd: process.cwd(),
      onDelta: (text) => deltas.push(text),
      onActivity: (line) => activity.push(line),
    })

    expect(reply.error).toBeNull()
    expect(reply.exitCode).toBe(0)
    // From the system/init event's session_id.
    expect(reply.resumeId).toBe('83a376de-ec1f-434c-a2dc-ab266a40d945')
    // From the result event — not reassembled from deltas.
    expect(reply.text).toBe('parley')
    // The two text_delta fragments, in order; input_json_delta is ignored.
    expect(deltas).toEqual(['par', 'ley'])
    // The tool_use block on the assistant event, described by file_path.
    expect(activity).toEqual(['Read /scrubbed/fixture-probe/package.json'])
    // input_tokens / output_tokens / cache_read + cache_creation / cost.
    expect(reply.usage).toEqual({
      inputTokens: 4,
      cachedInputTokens: 12837,
      outputTokens: 143,
      reasoningTokens: 0,
      costUsd: 0.045811000000000004,
    })
  })
})

describe('captured Codex stream through CodexAdapter.run', () => {
  it('parses thread id, message, activity and usage from the recording', async () => {
    const adapter = new CodexAdapter(shimFor(codexFixture))
    const deltas: string[] = []
    const activity: string[] = []

    const reply = await adapter.run({
      systemPrompt: 'You are a capture probe.',
      prompt: 'Read the file package.json in the working directory (one command), then reply with exactly: parley',
      cfg: { vendor: 'codex', ...cfg },
      capability: 'read',
      cwd: process.cwd(),
      onDelta: (text) => deltas.push(text),
      onActivity: (line) => activity.push(line),
    })

    expect(reply.error).toBeNull()
    expect(reply.exitCode).toBe(0)
    // From thread.started's thread_id.
    expect(reply.resumeId).toBe('019fad5f-080f-7293-aa8c-01c409ad2ace')
    // The item.completed agent_message text; exec mode has no partial deltas,
    // so the whole message arrives as one onDelta call.
    expect(reply.text).toBe('parley')
    expect(deltas).toEqual(['parley'])
    // The command_execution item.started, with the zsh wrapper unwrapped.
    expect(activity).toEqual(['run cat package.json'])
    // From turn.completed's usage block. Codex reports no cost.
    expect(reply.usage).toEqual({
      inputTokens: 37820,
      cachedInputTokens: 18176,
      outputTokens: 149,
      reasoningTokens: 46,
      costUsd: 0,
    })
  })
})
