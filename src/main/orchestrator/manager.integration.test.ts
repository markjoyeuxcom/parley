import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import type { Mutation } from '@shared/domain'
import { Manager, RequestError } from './manager'

/**
 * End-to-end exercises of the engine with the deterministic mock adapters.
 *
 * These run the real orchestrator, the real store and the real protocol — only
 * the two CLIs are substituted — so they cover the wiring that unit tests of the
 * individual pieces cannot: turn sequencing, resume-id plumbing, verdict merging
 * across two independent replies, cap enforcement, and the approval gate.
 */

function harness(): {
  manager: Manager
  repo: Repo
  events: AppEvent[]
  registry: AgentRegistry
} {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const manager = new Manager({ repo, registry, emit: (event) => events.push(event) })
  return { manager, repo, events, registry }
}

async function waitFor(predicate: () => boolean, timeoutMs = 15_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  throw new Error('timed out waiting for condition')
}

const claude = { vendor: 'claude' as const, model: 'opus', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

describe('debate session, end to end', () => {
  it('runs every stage, merges two independent verdicts, and writes a report', async () => {
    const { manager, repo } = harness()

    const session = manager.startSession({
      kind: 'debate',
      matter: 'Should the ingest pipeline move to a queue?',
      project: 'Ledger',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 4,
    })

    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    // Four exchange turns, plus one independent verdict turn from each side.
    const turns = repo.listTurns(session.id)
    expect(turns).toHaveLength(6)
    expect(turns.map((t) => t.stage)).toEqual([
      'Position',
      'Challenge',
      'Defence',
      'Convergence',
      'Verdict',
      'Verdict',
    ])

    // Sides must alternate through the exchange.
    const exchange = turns.slice(0, 4)
    expect(exchange.map((t) => t.side)).toEqual(['a', 'b', 'a', 'b'])

    // Both verdict turns are present and come from opposite sides.
    const verdictTurns = turns.filter((t) => t.stage === 'Verdict')
    expect(new Set(verdictTurns.map((t) => t.side))).toEqual(new Set(['a', 'b']))

    const verdict = repo.getVerdict(session.id)
    expect(verdict).not.toBeNull()
    expect(verdict?.decision).toBeTruthy()
    expect(verdict?.report).toContain('# Decision record')
    expect(verdict?.report).toContain('Ledger')

    // The mock's two sides disagree (0.72 vs 0.58 credence, and codex records
    // dissent), so the merged confidence must reflect that rather than the
    // higher of the two.
    expect(verdict?.confidence).toBeLessThan(0.72)
    expect(verdict?.dissent).toContain('migration cost')

    // Usage accumulated across every turn.
    const finished = repo.getSession(session.id)
    expect(finished?.usage.outputTokens).toBeGreaterThan(0)
    expect(finished?.usage.inputTokens).toBeGreaterThan(0)
  })

  it('stores a resume id per side so turns relay instead of replaying', async () => {
    const { manager, repo } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    expect(repo.getResumeId(session.id, 'a')).toBeTruthy()
    expect(repo.getResumeId(session.id, 'b')).toBeTruthy()
    expect(repo.getResumeId(session.id, 'a')).not.toBe(repo.getResumeId(session.id, 'b'))
  })

  it('delivers a whisper to one side only', async () => {
    const { manager, repo } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 6,
    })

    manager.interject(session.id, 'a', 'press harder on migration cost')
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const interjections = repo.listInterjections(session.id)
    expect(interjections).toHaveLength(1)
    expect(interjections[0]?.target).toBe('a')
    // Delivered means side A consumed it; side B never had a chance to.
    expect(interjections[0]?.deliveredAt).not.toBeNull()
  })

  it('warns when both sides are the same vendor', () => {
    const { manager, events } = harness()
    manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: { ...claude },
      maxTurns: 2,
    })
    const warning = events.find((e) => e.type === 'notice' && e.level === 'warn')
    expect(warning).toBeDefined()
    expect(warning && 'message' in warning ? warning.message : '').toMatch(/blind spots/i)
  })

  it('refuses a review-exit loop whose verifier shares the worker vendor', () => {
    const { manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))
    expect(() =>
      manager.createLoop({
        goal: 'x',
        repoPath,
        worker: codex,
        verifier: { ...codex },
        exit: { kind: 'review', command: '', criterion: 'the goal holds' },
        caps: { maxIterations: 3, maxSpendUsd: 0, maxWallClockMs: 60_000 },
        capability: 'read',
      }),
    ).toThrow(/cannot come from the model whose work it is checking/)
  })

  it('still allows a same-vendor pair when the exit is a deterministic command', () => {
    const { manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))
    const loop = manager.createLoop({
      goal: 'x',
      repoPath,
      worker: codex,
      verifier: { ...codex },
      // The verifier is unused here — the command is the check — so the pairing
      // costs nothing and blocking it would be a false stop.
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 3, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
    })
    expect(loop.status).toBe('idle')
  })

  it('refuses a review with no repository', () => {
    const { manager } = harness()
    expect(() =>
      manager.startSession({
        kind: 'review',
        matter: 'audit it',
        project: '',
        repoPath: null,
        agentA: claude,
        agentB: codex,
        maxTurns: 4,
      }),
    ).toThrow(RequestError)
  })

  it('refuses a relative repository path', () => {
    const { manager } = harness()
    expect(() =>
      manager.startSession({
        kind: 'review',
        matter: 'audit it',
        project: '',
        repoPath: './somewhere',
        agentA: claude,
        agentB: codex,
        maxTurns: 4,
      }),
    ).toThrow(/absolute/i)
  })
})

describe('review session, end to end', () => {
  it('produces findings and downgrades the unsupported one', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-review-'))

    const session = manager.startSession({
      kind: 'review',
      matter: 'Audit correctness and error handling.',
      project: '',
      repoPath,
      agentA: claude,
      agentB: codex,
      maxTurns: 4,
    })

    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const turns = repo.listTurns(session.id)
    expect(turns.map((t) => t.stage).slice(0, 4)).toEqual([
      'Architecture map',
      'Independent audit',
      'Cross-examination',
      'Reconciliation',
    ])

    const findings = repo.listFindings(session.id)
    expect(findings.length).toBeGreaterThan(0)

    const confirmed = findings.filter((f) => f.status === 'confirmed')
    expect(confirmed.length).toBeGreaterThan(0)
    // Every confirmed finding must carry evidence — the parser enforces it.
    for (const finding of confirmed) expect(finding.evidence.length).toBeGreaterThan(0)

    // The mock emits one finding claiming a race with no evidence; it must not
    // have survived as confirmed.
    const race = findings.find((f) => f.title.includes('race'))
    expect(race?.status).toBe('unsupported')

    expect(repo.getVerdict(session.id)?.report).toContain('# Codebase review')
  })
})

describe('loops, end to end', () => {
  it('succeeds when the exit command exits zero, and never asks the agent', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'make the build pass',
      repoPath,
      worker: codex,
      verifier: claude,
      // `node --version` is a real command that exits 0 — the exit condition is
      // observed, not self-reported.
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 5, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
    })

    // Creating does not start.
    expect(repo.getLoop(loop.id)?.status).toBe('idle')

    manager.startLoop(loop.id, null)
    await waitFor(() => repo.getLoop(loop.id)?.status === 'succeeded')

    const iterations = repo.listIterations(loop.id)
    expect(iterations).toHaveLength(1)
    expect(iterations[0]?.exitMet).toBe(true)
    expect(repo.getLoop(loop.id)?.stopReason).toContain('exited 0')
  })

  it('reports exhausted rather than succeeded when a cap stops it', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'never satisfiable',
      repoPath,
      worker: codex,
      verifier: claude,
      // A flag node does not accept, so this always exits non-zero.
      exit: { kind: 'command', command: 'node --definitely-not-a-flag', criterion: '' },
      caps: { maxIterations: 2, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
    })
    manager.startLoop(loop.id, null)

    await waitFor(() => {
      const status = repo.getLoop(loop.id)?.status
      return status === 'exhausted' || status === 'failed' || status === 'succeeded'
    })

    const final = repo.getLoop(loop.id)
    // Hitting a cap is not success, and the distinction is preserved.
    expect(final?.status).toBe('exhausted')
    expect(final?.stopReason).toMatch(/2-iteration cap/)
    expect(repo.listIterations(loop.id)).toHaveLength(2)
  })

  it('refuses to start a write-capable loop without an approval', () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'fix it',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'write',
    })

    expect(() => manager.startLoop(loop.id, null)).toThrow(/needs an approval/i)
    expect(repo.getLoop(loop.id)?.status).toBe('idle')
  })

  it('spends the approval on start, so restarting requires a fresh one', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'fix it',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'write',
    })

    const approval = repo.grantApproval('loop.write', loop.id, 'allow writes')
    manager.startLoop(loop.id, approval.id)
    await waitFor(() => repo.getLoop(loop.id)?.status === 'succeeded')

    expect(repo.listApprovals()[0]?.consumedAt).not.toBeNull()
    // The same approval cannot be reused.
    expect(() => manager.startLoop(loop.id, approval.id)).toThrow()
  })

  it('rejects an exit command that needs a shell, before spending anything', () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    expect(() =>
      manager.createLoop({
        goal: 'x',
        repoPath,
        worker: codex,
        verifier: claude,
        exit: { kind: 'command', command: 'npm test | tee log', criterion: '' },
        caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 },
        capability: 'read',
      }),
    ).toThrow(/shell/i)

    // Nothing was persisted for the rejected loop.
    expect(repo.listLoops()).toHaveLength(0)
  })

  it('kills a running loop on request', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'runs for a while',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'node --definitely-not-a-flag', criterion: '' },
      caps: { maxIterations: 60, maxSpendUsd: 0, maxWallClockMs: 120_000 },
      capability: 'read',
    })
    manager.startLoop(loop.id, null)

    await waitFor(() => repo.listIterations(loop.id).length >= 1)
    manager.killLoop(loop.id)

    await waitFor(() => {
      const status = repo.getLoop(loop.id)?.status
      return status === 'killed' || status === 'failed'
    })
    expect(repo.getLoop(loop.id)?.status).toBe('killed')
  })
})

describe('handing a rejection back to the executor', () => {
  /**
   * A clean git repo. The mock executor writes into it, leaving a sentinel the
   * mock reviewer objects to on the first pass and clearing it on the next —
   * the shape of a genuinely remediated milestone.
   *
   * A prefix containing "stubborn" makes the mock never clear the sentinel, for
   * the give-up path.
   */
  function gitRepo(prefix = 'parley-remediate-'): string {
    const repoPath = mkdtempSync(join(tmpdir(), prefix))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    return repoPath
  }

  async function runFirstMilestone(
    repoPath: string,
    testCommand = 'node --version',
    mutations: Mutation[] = [],
  ) {
    const { manager, repo, events, registry } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, { testCommand, mutations })
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    const done = await manager.runMilestone(first.id, approval.id)
    return { done, events, repo, registry }
  }

  /**
   * The mock executor leaves `RESOLVED` in the tree on its second write, so a
   * verification command that greps for it passes only on a remediated milestone,
   * and a mutation that replaces it makes that command fail. That gives a real
   * green-then-broken pair to check the mutation stage against, with no engine
   * and no shell.
   *
   * The declared anchor is deliberately stale — the text is nowhere in the file —
   * because that is the normal case: the planner writes the anchor before the
   * executor has written the code it is supposed to point at.
   */
  const staleAnchor: Mutation[] = [
    {
      file: 'parley-mock-work.txt',
      find: 'WINNER_HARDCODED',
      replace: 'x',
      describes: 'the suite must notice if the resolved marker is wrong',
    },
  ]
  const grepResolved = 'grep -q RESOLVED parley-mock-work.txt'

  it('tells the remediating executor which declared break survived', async () => {
    // grep -q RESOLVED matches RESOLVEDX too, so this mutation survives a green
    // suite: the milestone fails while the reviewer passes and the tests pass.
    // The only actionable fact is the surviving break itself, so the remediation
    // prompt must carry it — without it the executor is told "rejected", shown
    // green verification, and given nothing to fix.
    const { done, registry } = await runFirstMilestone(
      gitRepo('parley-mutate-survive-'),
      'grep -q RESOLVED parley-mock-work.txt',
      [
        {
          file: 'parley-mock-work.txt',
          find: 'RESOLVED',
          replace: 'RESOLVEDX',
          describes: 'a marker change the tests cannot distinguish',
        },
      ],
    )

    expect(done.status).toBe('failed')
    expect(done.mutationResults[0]).toMatchObject({ caught: false, skipped: '' })

    // The executor is the codex mock; its remediation round must have been told.
    const adapter = registry.get('codex') as unknown as { prompts: string[] }
    const remediation = adapter.prompts.filter((p) => p.includes('This is remediation round'))
    expect(remediation.length).toBeGreaterThan(0)
    const mutationRound = remediation.find((p) => p.includes('MUTATION CHECKS'))
    expect(mutationRound).toBeDefined()
    expect(mutationRound).toMatch(/SURVIVED — parley-mock-work\.txt/)
    expect(mutationRound).toMatch(/strengthen the tests/)
  })

  it('re-anchors a stale mutation against the real file and catches the break', async () => {
    const repoPath = gitRepo('parley-mutate-')
    const { done } = await runFirstMilestone(repoPath, grepResolved, staleAnchor)

    expect(done.status).toBe('complete')
    // One result, re-anchored and then caught: the repair round closed the loop
    // rather than the milestone passing on an unchecked claim.
    expect(done.mutationResults).toHaveLength(1)
    expect(done.mutationResults[0]).toMatchObject({ caught: true, skipKind: '' })
    // And the file the mutation edited is back exactly as the executor left it,
    // which is the property that makes running this against a real repo safe.
    expect(readFileSync(join(repoPath, 'parley-mock-work.txt'), 'utf8')).toBe('RESOLVED\n')
  })

  it('fails the milestone when a check still cannot be applied after re-anchoring', async () => {
    const { done } = await runFirstMilestone(
      gitRepo('parley-mutate-unfixable-'),
      grepResolved,
      staleAnchor,
    )

    expect(done.status).toBe('failed')
    const result = done.mutationResults[0]
    expect(result).toMatchObject({ caught: false, skipKind: 'unapplied' })
    // The refusal is carried into the record, not just the fact of the failure.
    expect(result?.skipped).toMatch(/cannot be checked here/)
    expect(done.reviewNote).toMatch(/could not be applied to the code as written/)
  })

  it('fails a milestone whose review names a blocking problem but ticks the box', async () => {
    // End-to-end guard for the failure this contract exists to stop. On three
    // consecutive real milestones the reviewer found a defect, wrote it into the
    // review, and set passed:true beside it — and the milestone shipped. The
    // pipeline must decide on the finding, not on the flag.
    const { done } = await runFirstMilestone(gitRepo('parley-acknowledge-'))

    expect(done.status).toBe('failed')
    expect(done.reviewPassed).toBe(false)
    // And the reason survives into the record, so an approver sees why.
    expect(done.reviewNote).toMatch(/hardcoded snapshot/i)
  })

  it('remediates a rejection and completes without asking the human again', async () => {
    const { done } = await runFirstMilestone(gitRepo())

    expect(done.status).toBe('complete')
    // Both rounds are in the record, so the pass is not mistaken for a clean
    // first attempt.
    expect(done.reviewNote).toMatch(/Round 1 —/)
    expect(done.reviewNote).toMatch(/Round 2 —/)
    expect(done.reviewNote).toMatch(/remediated/i)
  })

  it("carries the reviewer's concerns into the executor's next turn", async () => {
    const { events } = await runFirstMilestone(gitRepo())
    const texts = events
      .filter((e) => e.type === 'plan.activity')
      .map((e) => (e.type === 'plan.activity' ? e.text : ''))

    // The executor is told how many objections it is answering, and which round.
    expect(texts.some((t) => /addressing 2 objections — round 1 of 2/.test(t))).toBe(true)
    expect(texts.some((t) => /re-reviewing after remediation/.test(t))).toBe(true)
  })

  it('spends only the original approval — remediation is inside the same run', async () => {
    // The human authorised this milestone. Bounded self-correction toward that
    // same milestone is within it; a fresh gate per round would just train
    // people to click through gates.
    const { done, repo } = await runFirstMilestone(gitRepo())
    expect(done.status).toBe('complete')
    expect(repo.listApprovals()).toHaveLength(1)
  })

  it('remediates a failing verification even when the reviewer objects to nothing', async () => {
    // The test output is actionable on its own. Stopping because the reviewer
    // was content would waste the one signal the executor could have acted on.
    const { done } = await runFirstMilestone(gitRepo(), 'node --definitely-not-a-flag')

    expect(done.status).toBe('failed')
    expect(done.reviewNote).toMatch(/Round 2 —/)
    expect(done.reviewNote).toMatch(/remediation budget/i)
  })

  it('gives up after the budget rather than looping forever', async () => {
    // A reviewer that objects every round no matter what the executor does. The
    // loop must stop at its budget and say a person is needed, not spin.
    const { done } = await runFirstMilestone(gitRepo('parley-stubborn-'))

    expect(done.status).toBe('failed')
    expect(done.reviewNote).toMatch(/remediation budget/i)
    expect(done.reviewNote).toMatch(/need a person/i)
    // Exactly the budget: an initial attempt plus MAX_REMEDIATION_ROUNDS.
    expect(done.reviewNote.match(/Round \d+ —/g)).toHaveLength(3)
  })
})

describe('adopting work that is already in the tree', () => {
  /** A git repo whose working tree already contains the milestone's files. */
  function repoWithExistingWork(): string {
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-adopt-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    // The mock plan's first milestone expects src/net/client.ts.
    mkdirSync(join(repoPath, 'src', 'net'), { recursive: true })
    writeFileSync(join(repoPath, 'src/net/client.ts'), 'export const capped = true\n')
    return repoPath
  }

  /**
   * The mock plan's test command is `npm test`, which cannot pass in a bare
   * temporary repository. Substituting a command that genuinely runs keeps these
   * tests exercising the real verification path rather than asserting against a
   * failure caused by the fixture.
   */
  async function planIn(repoPath: string, testCommand = 'node --version') {
    const { manager, repo, events } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const updated = milestones.map((m) => repo.updateMilestone(m.id, { testCommand }))
    return { manager, repo, events, milestones: updated }
  }

  it('completes without an approval, because it writes nothing', async () => {
    const { manager, repo, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)

    expect(done.status).toBe('complete')
    expect(done.adopted).toBe(true)
    // No approval was granted or spent — nothing was written.
    expect(repo.listApprovals()).toHaveLength(0)
    expect(done.approvalId).toBeNull()
  })

  it('records plainly that Parley did not author the work', async () => {
    // The audit trail must never imply the executor wrote code it did not.
    const { manager, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)
    expect(done.reviewNote).toMatch(/adopted, not executed/i)
    expect(done.reviewNote).toMatch(/verified, not written/i)
  })

  it('still runs the deterministic tests and the independent review', async () => {
    const { manager, events, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)

    // The two checks that actually establish anything both ran.
    expect(done.testResult).not.toBeNull()
    expect(done.reviewPassed).toBe(true)

    const phases = new Set(
      events.filter((e) => e.type === 'plan.activity').map((e) => (e.type === 'plan.activity' ? e.phase : '')),
    )
    expect(phases).toContain('testing')
    expect(phases).toContain('reviewing')
    // Nothing was executed.
    expect(phases).not.toContain('executing')
  })

  it('refuses when there is nothing to adopt', async () => {
    // A clean tree means no pre-existing work, so adoption would be a lie.
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-adopt-clean-'))
    execFileSync('git', ['init', '-q'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['config', 'user.email', 't@e.invalid'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['config', 'user.name', 't'], { cwd: repoPath, stdio: 'ignore' })
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    execFileSync('git', ['add', '.'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'seed'], { cwd: repoPath, stdio: 'ignore' })

    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    await expect(manager.adoptMilestone(first.id)).rejects.toThrow(/nothing to adopt/i)
  })

  it('refuses to adopt a milestone that is already complete', async () => {
    const { manager, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    await manager.adoptMilestone(first.id)
    await expect(manager.adoptMilestone(first.id)).rejects.toThrow(/already been completed/i)
  })

  it('fails rather than adopting work whose tests do not pass', async () => {
    // Adoption drops the executor, not the verification. Work that does not
    // pass must not become a completed milestone.
    const { manager, milestones } = await planIn(repoWithExistingWork(), 'node --definitely-not-a-flag')
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.adopted).toBe(false)
    expect(done.reviewNote).toMatch(/verification failed/i)
  })

  it('says which changed paths the verification never exercised', async () => {
    // The reviewer caught this by hand on a real run; it should be structural.
    const repoPath = repoWithExistingWork()
    writeFileSync(join(repoPath, 'unrelated.md'), '# not in scope\n')

    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)
    expect(done.reviewNote).toMatch(/outside this milestone's scope/i)
    expect(done.reviewNote).toContain('unrelated.md')
  })

  it('does not claim to have adopted work it rejected', async () => {
    const { manager, milestones } = await planIn(repoWithExistingWork(), 'node --definitely-not-a-flag')
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)
    expect(done.reviewNote).toMatch(/^Not adopted\./)
    expect(done.reviewNote).not.toMatch(/^Adopted/)
  })

  it('survives the round trip through the database', async () => {
    const { manager, repo, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    await manager.adoptMilestone(first.id)
    expect(repo.getMilestone(first.id)?.adopted).toBe(true)
    expect(repo.listMilestones(first.planId)[0]?.adopted).toBe(true)
  })
})

describe('the planner answers its own audit', () => {
  async function planIn(repoPath: string, brief = 'x') {
    const { manager, repo, events } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: brief,
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const detail = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    await manager.whenPlanSettled(detail.plan.id)
    return {
      manager,
      repo,
      events,
      plan: repo.getPlan(detail.plan.id) ?? detail.plan,
      milestones: repo.listMilestones(detail.plan.id),
    }
  }

  it('records both halves of the exchange, not just the audit', async () => {
    // The corrected milestones replace the draft ones, so without this the
    // auditor's findings would vanish with them.
    const { repo, plan } = await planIn(mkdtempSync(join(tmpdir(), 'parley-correct-')))
    const note = repo.getPlan(plan.id)?.correctionNote ?? ''

    expect(note).toMatch(/audited the plan and judged it/i)
    expect(note).toMatch(/The planner answered the audit/i)
    expect(note).toMatch(/ACCEPTED/)
    expect(note).toMatch(/REJECTED/)
  })

  it('hands the human the corrected plan, not the draft', async () => {
    const { milestones } = await planIn(mkdtempSync(join(tmpdir(), 'parley-correct2-')))
    // The mock planner consolidates two draft milestones into one.
    expect(milestones).toHaveLength(1)
    expect(milestones[0]?.status).toBe('audited')
  })

  it('reaches ready, so the plan is approvable', async () => {
    const { repo, plan } = await planIn(mkdtempSync(join(tmpdir(), 'parley-correct3-')))
    expect(repo.getPlan(plan.id)?.status).toBe('ready')
  })
})

describe('a planner that needs a decision from the user', () => {
  async function planAsking() {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-ask-'))
    const session = manager.startSession({
      kind: 'debate',
      // The brief reaches the planner, and this sentinel makes the mock block.
      matter: 'ASK_ME whether the cap is per host',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const detail = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    await manager.whenPlanSettled(detail.plan.id)
    return {
      manager,
      repo,
      plan: repo.getPlan(detail.plan.id) ?? detail.plan,
      milestones: repo.listMilestones(detail.plan.id),
    }
  }

  it('parks the plan on the question instead of guessing', async () => {
    const { repo, plan, milestones } = await planAsking()
    const parked = repo.getPlan(plan.id)

    expect(parked?.status).toBe('awaiting-clarification')
    expect(parked?.question).toMatch(/per host or globally/i)
    // Nothing is planned yet — the question blocks the work, not just the UI.
    expect(milestones).toEqual([])
  })

  it('continues once answered, and does not ask twice', async () => {
    const { manager, repo, plan } = await planAsking()
    const resumed = await manager.answerPlan(plan.id, 'Per host.')

    expect(resumed.plan.status).toBe('ready')
    expect(resumed.plan.question).toBe('')
    expect(resumed.milestones.length).toBeGreaterThan(0)
    expect(repo.getPlan(plan.id)?.status).toBe('ready')
  })

  it('refuses an answer when nothing was asked', async () => {
    const { manager, plan } = await planAsking()
    await manager.answerPlan(plan.id, 'Per host.')
    await expect(manager.answerPlan(plan.id, 'again')).rejects.toThrow(/not waiting/i)
  })

  it('refuses an empty answer', async () => {
    const { manager, plan } = await planAsking()
    await expect(manager.answerPlan(plan.id, '   ')).rejects.toThrow(/answer is required/i)
  })
})

describe('pre-flight before spending agent time', () => {
  async function planIn(repoPath: string) {
    const { manager, repo } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    return { manager, repo, milestones }
  }

  it('reports which expected paths are already present, before any run', async () => {
    // The 41-minute dead end: every file the milestone would create already
    // exists, the executor declines to overwrite, and nothing changes. All of
    // that is knowable up front.
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-preflight-'))
    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    // The mock plan expects src/net/client.ts. Create it.
    mkdirSync(join(repoPath, 'src', 'net'), { recursive: true })
    writeFileSync(join(repoPath, 'src/net/client.ts'), 'export const x = 1\n')

    const report = await manager.inspectMilestone(first.id)
    expect(report.existing).toContain('src/net/client.ts')
    expect(report.missing).not.toContain('src/net/client.ts')
  })

  it('reports paths as missing when the repository is untouched', async () => {
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-preflight2-'))
    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const report = await manager.inspectMilestone(first.id)
    expect(report.existing).toEqual([])
    expect(report.missing).toEqual(first.expectedPaths)
  })

  it('lists the uncommitted paths already in the tree', async () => {
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-preflight3-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    writeFileSync(join(repoPath, 'VERDICT-leftover.md'), '# leftover\n')

    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const report = await manager.inspectMilestone(first.id)
    expect(report.dirtyPaths).toContain('VERDICT-leftover.md')
  })

  it('refuses to inspect a milestone that does not exist', async () => {
    const { manager } = harness()
    await expect(manager.inspectMilestone('nope')).rejects.toThrow(/no such milestone/i)
  })
})

describe('a running milestone reports what it is doing', () => {
  it('emits live activity for each phase, so it is not an opaque spinner', async () => {
    // A non-git directory, so the unchanged-tree guard cannot judge and the run
    // proceeds through every phase.
    const { manager, repo, events } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-activity-'))

    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    await manager.runMilestone(first.id, approval.id)

    const activity = events.filter((e) => e.type === 'plan.activity')
    expect(activity.length).toBeGreaterThan(0)

    const phases = new Set(activity.map((e) => (e.type === 'plan.activity' ? e.phase : '')))
    // The three stages a user needs distinguished while waiting.
    expect(phases).toContain('executing')
    expect(phases).toContain('testing')
    expect(phases).toContain('reviewing')

    // Every line is attributed to the milestone it belongs to and carries text.
    for (const event of activity) {
      if (event.type !== 'plan.activity') continue
      expect(event.milestoneId).toBe(first.id)
      expect(event.text.length).toBeGreaterThan(0)
    }
  })

  it('names the verification command and its exit code in the feed', async () => {
    const { manager, repo, events } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-activity2-'))

    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    await manager.runMilestone(first.id, approval.id)

    const texts = events
      .filter((e) => e.type === 'plan.activity')
      .map((e) => (e.type === 'plan.activity' ? e.text : ''))

    expect(texts.some((t) => t.includes('running npm test'))).toBe(true)
    expect(texts.some((t) => /exited \d+ in/.test(t))).toBe(true)
  })
})

describe('mock runs are marked as such, permanently', () => {
  it('stamps every record the mock adapters produce', async () => {
    // The harness uses AgentRegistry(true). Without this flag a mock session is
    // indistinguishable from a real one in the database and in the UI, which is
    // how fabricated verdicts get read as findings.
    const { manager, repo } = harness()

    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    expect(session.mock).toBe(true)
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    // Survives the round trip through SQLite.
    expect(repo.getSession(session.id)?.mock).toBe(true)
    expect(repo.listSessions()[0]?.mock).toBe(true)
  })

  it('puts the warning inside the exported report, which outlives the app', async () => {
    const { manager, repo } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const report = repo.getVerdict(session.id)?.report ?? ''
    expect(report).toMatch(/NOT REAL WORK/)
    expect(report).toMatch(/fabricated/i)
  })

  it('marks loops and plans too', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-mockmark-'))

    const loop = manager.createLoop({
      goal: 'g',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
    })
    expect(repo.getLoop(loop.id)?.mock).toBe(true)

    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    expect(repo.getPlan(plan.id)?.mock).toBe(true)
  })

  it('names mock mode without blaming it for an unchanged tree', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-noop-mockwhy-'))
    execFileSync('git', ['init', '-q'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['config', 'user.email', 't@e.invalid'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['config', 'user.name', 't'], { cwd: repoPath, stdio: 'ignore' })
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    execFileSync('git', ['add', '.'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'seed'], { cwd: repoPath, stdio: 'ignore' })

    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow')
    const done = await manager.runMilestone(first.id, approval.id)

    // Mock mode is named, because it is context the user cannot deduce — but it is
    // no longer blamed for the empty tree. The mock executor does write a
    // placeholder, so claiming otherwise sent people to restart the app when the
    // real cause was an unwritable path.
    expect(done.reviewNote).toMatch(/PARLEY_MOCK/)
    expect(done.reviewNote).toMatch(/not writable/i)
    expect(done.reviewNote).not.toMatch(/never write files/i)
  })
})

describe('an executor that writes nothing', () => {
  function seededRepo(extraUntracked?: string): string {
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-noop-empty-'))
    const git = (...args: string[]): void => {
      execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
    }
    git('init', '-q')
    git('config', 'user.email', 't@e.invalid')
    git('config', 'user.name', 't')
    writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
    git('add', '.')
    git('commit', '-qm', 'seed')
    if (extraUntracked) writeFileSync(join(repoPath, extraUntracked), '# leftover\n')
    return repoPath
  }

  async function runFirstMilestone(repoPath: string) {
    const { manager, repo } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow the write')
    return manager.runMilestone(first.id, approval.id)
  }

  it('fails the milestone rather than letting the reviewer pass nothing', async () => {
    // The mock executor never touches the filesystem, which reproduces the real
    // case: the agent reports success, the tree is untouched, and a reviewer
    // handed no work has nothing to object to.
    const done = await runFirstMilestone(seededRepo())

    expect(done.status).toBe('failed')
    expect(done.reviewPassed).toBe(false)
    expect(done.reviewNote).toMatch(/unchanged/i)
    expect(done.reviewNote).not.toMatch(/scope matches/i)
  })

  it('still fails when the repository was ALREADY dirty before the milestone ran', async () => {
    // The regression: one stray untracked file — exactly the exported
    // VERDICT-*.md sitting in the real repository — made the previous check see
    // "changes" and let a milestone that wrote nothing reach tests and review.
    const done = await runFirstMilestone(seededRepo('VERDICT-bff89618.md'))

    expect(done.status).toBe('failed')
    expect(done.reviewPassed).toBe(false)
    expect(done.reviewNote).toMatch(/unchanged/i)
    expect(done.reviewNote).not.toMatch(/scope matches/i)
  })

  it('names the expected paths the executor never created', async () => {
    const done = await runFirstMilestone(seededRepo('VERDICT-bff89618.md'))
    // The mock plan expects src/net/client.ts, which does not exist.
    expect(done.reviewNote).toMatch(/src\/net\/client\.ts/)
  })
})

describe('plans and the approval gate', () => {
  it('refuses to plan from a session with no verdict', async () => {
    const { manager } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-'))
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })

    await expect(
      manager.createPlan({
        sessionId: session.id,
        kind: 'implementation',
        repoPath,
        planner: claude,
        executor: codex,
        reviewer: claude,
      }),
    ).rejects.toThrow(/no verdict/i)
  })

  it('drafts milestones, records the cross-vendor audit, and gates execution', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-'))

    const session = manager.startSession({
      kind: 'debate',
      matter: 'Bound the retry path',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    // createPlan returns as soon as the record exists; the pipeline runs on.
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)

    // What reaches the human is the *corrected* plan, not the draft: the mock
    // planner answers the audit and reissues a single consolidated milestone.
    expect(milestones).toHaveLength(1)
    // Auditing does not approve: nothing is executable without a human.
    for (const milestone of milestones) {
      expect(milestone.status).toBe('audited')
      expect(milestone.approvalId).toBeNull()
    }

    // Running without an approval at all is refused.
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    await expect(manager.runMilestone(first.id, 'not-a-real-approval')).rejects.toThrow()

    // With an approval it runs, and the approval is spent.
    const approval = repo.grantApproval('milestone.execute', first.id, 'allow the write')
    const done = await manager.runMilestone(first.id, approval.id)

    expect(done.approvalId).toBe(approval.id)
    expect(['complete', 'failed']).toContain(done.status)
    expect(repo.listApprovals().find((a) => a.id === approval.id)?.consumedAt).not.toBeNull()

    // Re-running needs a fresh approval; the spent one is refused.
    await expect(manager.runMilestone(first.id, approval.id)).rejects.toThrow()
  })
})

describe('a corrected plan replaces its draft', () => {
  it('emits the whole milestone set so superseded drafts cannot linger', async () => {
    const { manager, repo, events } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'x',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath: mkdtempSync(join(tmpdir(), 'parley-correct-')),
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    await manager.whenPlanSettled(plan.id)

    // The mock's correction reissues one milestone where the draft had two, so a
    // client merging by id would end up showing three.
    const stored = repo.listMilestones(plan.id)
    expect(stored).toHaveLength(1)

    const sets = events.filter((e) => e.type === 'plan.milestones')
    expect(sets.length).toBeGreaterThanOrEqual(2)
    const last = sets.at(-1)
    // The final set is authoritative and matches the database exactly, ids and all.
    expect(last?.milestones.map((m) => m.id)).toEqual(stored.map((m) => m.id))

    // And the ids it replaced are genuinely gone, not merely reordered.
    const draftIds = new Set(sets[0]?.milestones.map((m) => m.id) ?? [])
    expect(draftIds.size).toBeGreaterThan(0)
    expect(stored.some((m) => draftIds.has(m.id))).toBe(false)
  })
})
