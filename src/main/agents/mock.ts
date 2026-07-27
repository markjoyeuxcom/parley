import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { emptyUsage, type Vendor } from '@shared/domain'
import type { CliHealth } from '@shared/ipc'
import type { AgentAdapter, RunRequest, RunResult } from './types'

/**
 * A deterministic stand-in for a real CLI.
 *
 * Exists so the orchestrator, the loop caps, and the whole UI can be exercised
 * without spending subscription quota. It answers the protocol's structured
 * contracts well enough to drive every downstream code path, including the
 * failure paths.
 */
export class MockAdapter implements AgentAdapter {
  readonly binary = '(mock)'
  /** Every prompt this adapter has been sent, for tests that assert on the
   * pipeline's side of the conversation rather than the mock's. */
  readonly prompts: string[] = []
  private counter = 0
  private writes = 0

  constructor(readonly vendor: Vendor) {}

  async run(req: RunRequest): Promise<RunResult> {
    this.prompts.push(req.prompt)
    this.counter += 1
    const n = this.counter
    await new Promise((r) => setTimeout(r, 40))

    // A write-capable turn writes something. Without this the mock can never
    // get past the unchanged-tree guard, so the execute → verify → review →
    // remediate path would be untestable — which is most of the pipeline.
    //
    // The first write leaves a sentinel the mock reviewer objects to and later
    // writes clear it, so a remediation round has something real to fix. A cwd
    // containing "stubborn" never clears it, for testing the give-up path.
    if (req.capability === 'write' && !req.cwd.includes('noop')) {
      this.writes += 1
      const unresolved = req.cwd.includes('stubborn') || this.writes === 1
      // A cwd containing "acknowledge" produces work the reviewer will describe
      // as blocking while still ticking passed:true — the real-world failure the
      // review contract exists to make impossible.
      const body = req.cwd.includes('acknowledge')
        ? 'ACKNOWLEDGE_ONLY\n'
        : unresolved
          ? 'NEEDS_WORK\n'
          : 'RESOLVED\n'
      try {
        writeFileSync(join(req.cwd, 'parley-mock-work.txt'), body)
      } catch {
        // A read-only or missing cwd is the caller's problem to report.
      }
    }

    if (req.signal?.aborted) {
      return { text: '', usage: emptyUsage(), resumeId: null, exitCode: -1, error: 'run was cancelled' }
    }

    if (req.systemPrompt.includes('audit other engineers') && req.cwd.includes('AUDIT_FAILS')) {
      return {
        text: '',
        usage: emptyUsage(),
        resumeId: null,
        exitCode: 1,
        error: 'mock audit failure',
      }
    }

    const text = this.reply(req, n)
    for (const chunk of text.match(/.{1,80}/gs) ?? []) req.onDelta?.(chunk)

    return {
      text,
      usage: { ...emptyUsage(), inputTokens: 1200 + n * 10, outputTokens: 300 + n * 5, costUsd: 0 },
      resumeId: req.resumeId ?? `mock-${this.vendor}-${n}`,
      exitCode: 0,
      error: null,
    }
  }

  /**
   * Picks a canned reply by sniffing which structured contract the prompt asked
   * for.
   *
   * Order matters and is not arbitrary: several prompts *quote* an earlier
   * stage's output, so more than one marker can be present. The audit prompt
   * embeds the plan it is auditing, so it contains both "dispositions" and
   * "milestones"; the diff review prompt embeds a diff that could contain
   * anything. Each case is therefore tested from most specific to least, and the
   * broad ones come last.
   *
   * A real model does not have this problem — the contract it must satisfy is the
   * instruction at the end of the prompt, and `extractJson` takes the last block
   * in the reply.
   */
  private reply(req: RunRequest, n: number): string {
    const p = req.prompt
    const correcting = req.systemPrompt.includes('correcting your own plan')

    if (req.systemPrompt.includes('audit other engineers') && req.cwd.includes('AUDIT_UNREADABLE')) {
      return `I inspected the plan, but this reply contains no structured audit.`
    }

    // The mutation repair contract. Matched first because it is the only prompt
    // carrying whole file contents, which could contain any other marker.
    if (p.includes('"repairs"')) {
      // A cwd containing "unfixable" refuses the repair, so the pipeline's
      // still-cannot-be-checked path has something to fail on.
      if (req.cwd.includes('unfixable')) {
        return [
          `That check cannot be expressed against this file.`,
          '```json',
          JSON.stringify(
            {
              repairs: [],
              impossible: [{ index: 1, why: 'nothing in this file decides the behaviour named' }],
            },
            null,
            2,
          ),
          '```',
        ].join('\n')
      }
      return [
        `Re-anchored the check against the code as written.`,
        '```json',
        JSON.stringify(
          { repairs: [{ index: 1, find: 'RESOLVED', replace: 'BROKEN' }], impossible: [] },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    // A brief containing this sentinel makes the planner block on a question
    // once, so the clarification round-trip is exercisable.
    if (
      p.includes('"clarification"') &&
      p.includes('ASK_ME') &&
      !p.includes('HAS ANSWERED') &&
      (!req.cwd.includes('ASK_ME') || correcting)
    ) {
      return [
        `I cannot settle this without you.`,
        '```json',
        JSON.stringify(
          {
            clarification: 'Should the cap apply per host or globally?',
            context: 'Per host is safer under partial outage; global is simpler to reason about.',
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    // The correction contract asks for dispositions *and* milestones together,
    // so it must be matched before the plan-only case below.
    if (correcting && p.includes('"dispositions"') && p.includes('"milestones"')) {
      if (req.cwd.includes('CORRECTION_UNREADABLE')) {
        return `I reconsidered the plan, but this reply contains no structured correction.`
      }
      const dispositions = req.cwd.includes('NO_DISPOSITIONS')
        ? []
        : [
            { finding: 'The named test file does not exist yet', disposition: 'accepted', note: 'Created by milestone 2 now.' },
            { finding: 'Milestone ordering', disposition: 'rejected', note: 'The cap must land before the test that asserts it.' },
          ]
      return [
        `Answered the audit and reissued the plan.`,
        '```json',
        JSON.stringify(
          {
            dispositions,
            title: 'Bound the retry path',
            milestones: [
              {
                title: 'Add a retry ceiling',
                intent: 'Cap retries and surface exhaustion to the caller.',
                expectedPaths: ['src/net/client.ts'],
                testCommand: 'npm test',
              },
            ],
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    if (p.includes('"dispositions"')) {
      return [
        `Audited the plan against the tree.`,
        '```json',
        JSON.stringify(
          {
            verdict: 'needs-changes',
            dispositions: [
              { milestone: 0, disposition: 'accept', note: 'File exists and the cap belongs there.' },
              { milestone: 1, disposition: 'revise', note: 'The named test file does not exist yet.' },
            ],
            blockingConcerns: [],
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    if (p.includes('"passed"')) {
      // The sentinel in the diff drives this, not the round number: a
      // remediated diff no longer contains it and so passes, while a "stubborn"
      // cwd keeps it there and keeps being rejected.
      const objecting = p.includes('NEEDS_WORK')
      if (objecting) {
        return [
          `Reviewed the diff. It does not yet satisfy the milestone.`,
          '```json',
          JSON.stringify(
            {
              passed: false,
              blocking: [
                'the retry ceiling is not surfaced to the caller',
                'no test covers exhaustion',
              ],
              notes: ['the helper name reads oddly'],
              note: 'The cap exists but exhaustion is swallowed, so a caller cannot tell a give-up from a success.',
            },
            null,
            2,
          ),
          '```',
        ].join('\n')
      }
      // Reproduces the real failure this contract exists to stop: a reviewer that
      // names a blocking problem and ticks the box anyway. The pipeline must fail
      // the milestone on the finding, not on the flag.
      if (p.includes('ACKNOWLEDGE_ONLY')) {
        return [
          `Reviewed the diff.`,
          '```json',
          JSON.stringify(
            {
              passed: true,
              blocking: ['a hardcoded snapshot would pass this suite unchanged'],
              notes: [],
              note: 'Delivered as specified; main gap is that the central claim is unverified.',
            },
            null,
            2,
          ),
          '```',
        ].join('\n')
      }
      return [
        `Reviewed the diff against the milestone.`,
        '```json',
        JSON.stringify(
          { passed: true, blocking: [], notes: ['tidy'], note: 'Scope matches; no test was weakened.' },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    if (p.includes('"met"')) {
      // Report success on the third check so loop termination is exercised
      // without every mock loop ending on its first iteration.
      const met = n >= 3
      return [
        `Checked the repository rather than trusting the report.`,
        '```json',
        JSON.stringify({ met, reason: met ? 'The stated goal now holds.' : 'Still outstanding.' }, null, 2),
        '```',
      ].join('\n')
    }

    if (p.includes('"findings"')) {
      return [
        `Read the entry point and the request path. One real problem and one I could not corroborate.`,
        '```json',
        JSON.stringify(
          {
            findings: [
              {
                title: `Unbounded retry in the ${this.vendor} path`,
                detail: 'A failed call retries without a ceiling, so a persistent outage spins.',
                priority: 'P1',
                status: 'confirmed',
                evidence: [{ path: 'src/net/client.ts', line: 88, symbol: 'retry', excerpt: 'while (true) {' }],
              },
              {
                title: 'Possible race on the cache write',
                detail: 'Two writers may interleave, but I could not find a concurrent caller.',
                priority: 'P3',
                status: 'unsupported',
                evidence: [],
              },
            ],
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    if (p.includes('"decision"')) {
      const confidence = this.vendor === 'claude' ? 0.72 : 0.58
      return [
        `My verdict, recorded independently.`,
        '```json',
        JSON.stringify(
          {
            decision: 'Adopt the narrower option and revisit once the load profile is known.',
            rationale: 'It is reversible, and the wider option commits to an interface we cannot yet specify.',
            confidence,
            scores: { correctness: 7, robustness: 6, clarity: 8, maintainability: 7, risk: 6 },
            dissent: this.vendor === 'codex' ? 'I still think the migration cost is understated.' : '',
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    if (p.includes('"milestones"')) {
      return [
        `Plan drafted from a read-only pass.`,
        '```json',
        JSON.stringify(
          {
            title: 'Bound the retry path',
            milestones: [
              {
                title: 'Add a retry ceiling',
                intent: 'Cap retries and surface exhaustion to the caller.',
                expectedPaths: ['src/net/client.ts'],
                testCommand: 'npm test',
              },
              {
                title: 'Cover exhaustion with a test',
                intent: 'Assert the caller sees a terminal error after the cap.',
                expectedPaths: ['src/net/client.test.ts'],
                testCommand: 'npm test',
              },
            ],
          },
          null,
          2,
        ),
        '```',
      ].join('\n')
    }

    return `(${this.vendor} mock, turn ${n}) A concrete position with a named failure mode and the condition under which it would be wrong.`
  }

  async probe(): Promise<CliHealth> {
    return {
      vendor: this.vendor,
      present: true,
      version: 'mock',
      authenticated: true,
      detail: 'Mock adapter — no subscription usage.',
    }
  }
}
