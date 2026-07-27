import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import { emptyUsage, type Mutation } from '@shared/domain'
import { occurrenceState } from '@shared/ledger'
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

function disposeOpenBlockingOccurrences(repo: Repo, sessionId: string): void {
  const dispositions = repo.listFindingDispositions(sessionId)
  for (const occurrence of repo.listFindingOccurrences(sessionId)) {
    if (
      occurrence.kind !== 'blocking' ||
      occurrenceState(occurrence, dispositions) !== 'open'
    ) {
      continue
    }
    repo.disposeFinding({
      findingId: occurrence.findingId,
      occurrenceId: occurrence.id,
      state: 'accepted-risk',
      note: 'The test operator explicitly accepted this audited risk.',
      source: 'human',
    })
  }
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

    // Seats must alternate through the exchange.
    const exchange = turns.slice(0, 4)
    expect(exchange.map((t) => t.seat)).toEqual([0, 1, 0, 1])

    // Both verdict turns are present and come from different seats.
    const verdictTurns = turns.filter((t) => t.stage === 'Verdict')
    expect(new Set(verdictTurns.map((t) => t.seat))).toEqual(new Set([0, 1]))

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

    expect(repo.getResumeId(session.id, 0)).toBeTruthy()
    expect(repo.getResumeId(session.id, 1)).toBeTruthy()
    expect(repo.getResumeId(session.id, 0)).not.toBe(repo.getResumeId(session.id, 1))
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

describe('the two-participant contract', () => {
  /**
   * Pinned ahead of the Participants series. These are the observable
   * properties of a two-sided session that the N-participant rewrite must
   * preserve exactly when N is two: what each side is told, what it is never
   * told, how its conversation threads, and what it may touch. They assert
   * behaviour through the adapters' recorded requests, not implementation, so
   * the session runner can be rebuilt underneath them.
   */
  type Recorded = {
    systemPrompt: string
    prompt: string
    capability: string
    cwd: string
    resumeId: string | null
  }

  function requestsOf(registry: AgentRegistry, vendor: 'claude' | 'codex'): Recorded[] {
    return (registry.get(vendor) as unknown as { requests: Recorded[] }).requests
  }

  async function debate(maxTurns: number, repoPath: string | null = null) {
    const { manager, repo, registry } = harness()
    const session = manager.startSession({
      kind: 'debate',
      matter: 'Should the ingest pipeline move to a queue?',
      project: '',
      repoPath,
      agentA: claude,
      agentB: codex,
      maxTurns,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')
    return { manager, repo, registry, session }
  }

  it("relays only the opponent's latest message, never the transcript", async () => {
    // Token cost stays linear because each side is resumed and handed one
    // message. A six-turn debate gives each side several replies, so a prompt
    // carrying an *older* opponent message is distinguishable from the latest.
    const { registry } = await debate(6)
    const codexRequests = requestsOf(registry, 'codex')
    const claudeRequests = requestsOf(registry, 'claude')

    // Codex's second exchange turn (attack 2) hears claude's second reply,
    // not its opening position.
    expect(codexRequests[1]?.prompt).toContain("The other advisor's latest message")
    expect(codexRequests[1]?.prompt).toContain('(claude mock, turn 2)')
    expect(codexRequests[1]?.prompt).not.toContain('(claude mock, turn 1)')

    // Claude's third exchange turn hears codex's second reply only.
    expect(claudeRequests[2]?.prompt).toContain('(codex mock, turn 2)')
    expect(claudeRequests[2]?.prompt).not.toContain('(codex mock, turn 1)')
  })

  it('threads each side on its own resume id, never the other side\'s', async () => {
    const { registry } = await debate(6)

    for (const vendor of ['claude', 'codex'] as const) {
      const requests = requestsOf(registry, vendor)
      // First contact starts a fresh conversation; every later turn resumes
      // the thread that first turn minted.
      expect(requests[0]?.resumeId).toBeNull()
      for (const request of requests.slice(1)) {
        expect(request.resumeId).toBe(`mock-${vendor}-1`)
      }
      // And no side is ever resumed onto the other side's thread.
      const other = vendor === 'claude' ? 'codex' : 'claude'
      for (const request of requests) {
        expect(request.resumeId ?? '').not.toContain(`mock-${other}`)
      }
    }
  })

  it('assigns the affirmative to side a and the negative to side b, verdicts included', async () => {
    const { registry } = await debate(4)

    for (const request of requestsOf(registry, 'claude')) {
      expect(request.systemPrompt).toContain('You argue the affirmative')
    }
    for (const request of requestsOf(registry, 'codex')) {
      expect(request.systemPrompt).toContain('You argue the negative')
    }
  })

  it('keeps each verdict ask independent of the other side', async () => {
    const { registry } = await debate(4)
    const lastClaude = requestsOf(registry, 'claude').at(-1)
    const lastCodex = requestsOf(registry, 'codex').at(-1)

    expect(lastClaude?.prompt).toContain('Do not try to guess or match')
    expect(lastCodex?.prompt).toContain('Do not try to guess or match')
    // Neither verdict prompt carries anything the other side said — the
    // exchange is over, and the ask is deliberately context-free beyond each
    // side's own resumed conversation.
    expect(lastClaude?.prompt).not.toContain('(codex mock')
    expect(lastCodex?.prompt).not.toContain('(claude mock')
  })

  it('runs a repo-less debate tool-free and an attached one read-only', async () => {
    const bare = await debate(2)
    for (const vendor of ['claude', 'codex'] as const) {
      for (const request of requestsOf(bare.registry, vendor)) {
        expect(request.capability).toBe('none')
      }
    }

    const repoPath = mkdtempSync(join(tmpdir(), 'parley-contract-'))
    const attached = await debate(2, repoPath)
    for (const vendor of ['claude', 'codex'] as const) {
      for (const request of requestsOf(attached.registry, vendor)) {
        expect(request.capability).toBe('read')
        expect(request.cwd).toBe(repoPath)
      }
    }
  })

  it('runs a review read-only, cartographer on side a and reviewer on side b', async () => {
    const { manager, repo, registry } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-contract-review-'))
    const session = manager.startSession({
      kind: 'review',
      matter: 'audit it',
      project: '',
      repoPath,
      agentA: claude,
      agentB: codex,
      maxTurns: 4,
    })
    await waitFor(() => repo.getSession(session.id)?.status === 'complete')

    for (const request of requestsOf(registry, 'claude')) {
      expect(request.capability).toBe('read')
      expect(request.systemPrompt).toContain('Codebase Cartographer')
    }
    for (const request of requestsOf(registry, 'codex')) {
      expect(request.capability).toBe('read')
      expect(request.systemPrompt).toContain('Principal Reviewer')
    }
  })

  it('never grants a session write capability, whatever the kind', async () => {
    const { registry } = await debate(4, mkdtempSync(join(tmpdir(), 'parley-contract-')))
    for (const vendor of ['claude', 'codex'] as const) {
      for (const request of requestsOf(registry, vendor)) {
        expect(request.capability).not.toBe('write')
      }
    }
  })

  it("delivers a whisper into the targeted side's prompt and no other", async () => {
    const { manager, repo, registry } = harness()
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

    const claudePrompts = requestsOf(registry, 'claude').map((request) => request.prompt)
    const codexPrompts = requestsOf(registry, 'codex').map((request) => request.prompt)
    const delivered = claudePrompts.filter((prompt) =>
      prompt.includes('press harder on migration cost'),
    )
    // Exactly once, framed as direction from the director — and side b's
    // prompts never carry a trace of it. The other side must not even be able
    // to infer the whisper happened.
    expect(delivered).toHaveLength(1)
    expect(delivered[0]).toContain('DIRECTION FROM THE HUMAN DIRECTOR')
    for (const prompt of codexPrompts) {
      expect(prompt).not.toContain('press harder')
      expect(prompt).not.toContain('DIRECTION FROM THE HUMAN DIRECTOR')
    }
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

  it('charges review checks as usage without spending worker iterations', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'never satisfiable in two checks',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'review', command: '', criterion: 'the goal is complete' },
      caps: { maxIterations: 2, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
    })
    manager.startLoop(loop.id, null)

    await waitFor(() => repo.getLoop(loop.id)?.status === 'exhausted')

    const final = repo.getLoop(loop.id)
    const iterations = repo.listIterations(loop.id)
    expect(final?.iterationCount).toBe(2)
    expect(iterations).toHaveLength(2)
    expect(final?.usage.inputTokens).toBeGreaterThan(
      iterations.reduce((total, iteration) => total + iteration.usage.inputTokens, 0),
    )
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

  it('persists the approval and starts the wall-clock budget when the loop starts', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-loop-'))

    const loop = manager.createLoop({
      goal: 'fix it',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'node --version', criterion: '' },
      caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 10 },
      capability: 'write',
    })
    const approval = repo.grantApproval('loop.write', loop.id, 'allow writes')

    await new Promise((resolve) => setTimeout(resolve, 20))
    const started = manager.startLoop(loop.id, approval.id)

    expect(started.status).toBe('running')
    expect(started.approvalId).toBe(approval.id)
    expect(started.startedAt).toBeGreaterThan(loop.startedAt)
    expect(repo.getLoop(loop.id)).toMatchObject({
      status: 'running',
      approvalId: approval.id,
      startedAt: started.startedAt,
    })

    await waitFor(() => repo.getLoop(loop.id)?.status === 'succeeded')
    expect(repo.listIterations(loop.id)).toHaveLength(1)
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
    expectedPaths = ['parley-mock-work.txt'],
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
    repo.updateMilestone(first.id, {
      testCommand,
      mutations,
      expectedPaths,
    })
    disposeOpenBlockingOccurrences(repo, session.id)
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

  it('fails, reviews, and remediates when any declared output is missing', async () => {
    const missingPath = 'src/net/client.ts'
    const { done, registry } = await runFirstMilestone(
      gitRepo(),
      'node --version',
      [],
      ['parley-mock-work.txt', missingPath],
    )

    expect(done.status).toBe('failed')
    expect(done.reviewNote).toContain(missingPath)
    expect(done.reviewBlocking).toContainEqual(expect.stringContaining(missingPath))

    const reviewer = registry.get('claude') as unknown as { prompts: string[] }
    expect(
      reviewer.prompts.some(
        (prompt) => prompt.includes('DECLARED OUTPUTS THAT DO NOT EXIST') && prompt.includes(missingPath),
      ),
    ).toBe(true)

    const executor = registry.get('codex') as unknown as { prompts: string[] }
    expect(
      executor.prompts.some(
        (prompt) => prompt.includes('This is remediation round') && prompt.includes(missingPath),
      ),
    ).toBe(true)
  })

  it('keeps the no-command rule unchanged for executed milestones', async () => {
    const { done } = await runFirstMilestone(gitRepo(), '')

    expect(done.status).toBe('complete')
    expect(done.testResult).toBeNull()
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
  function repoWithExistingWork(
    prefix = 'parley-adopt-',
    content = 'export const capped = true\n',
  ): string {
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
    // The mock plan's first milestone expects src/net/client.ts.
    mkdirSync(join(repoPath, 'src', 'net'), { recursive: true })
    writeFileSync(join(repoPath, 'src/net/client.ts'), content)
    return repoPath
  }

  /**
   * The mock plan's test command is `npm test`, which cannot pass in a bare
   * temporary repository. Substituting a command that genuinely runs keeps these
   * tests exercising the real verification path rather than asserting against a
   * failure caused by the fixture.
   */
  async function planIn(repoPath: string, testCommand = 'node --version', settleLedger = true) {
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
    const updated = milestones.map((m) => repo.updateMilestone(m.id, { testCommand }))
    // Drafting leaves the audit's revise finding open in the ledger, and
    // adoption is gated on it exactly like approval. These tests exercise
    // post-gate behaviour; the refusal itself has its own test below.
    if (settleLedger) disposeOpenBlockingOccurrences(repo, session.id)
    return { manager, repo, events, registry, milestones: updated }
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

  it('refuses to adopt while a blocking finding occurrence is unresolved', async () => {
    // The m6 review's top carried finding: "Adopt & verify" completes a
    // milestone through review, so it must be stopped by exactly the blockers
    // that stop "Approve and run" — otherwise adoption is a side door around
    // the ledger. The refusal fires before the tree is even read.
    const { manager, repo, milestones } = await planIn(repoWithExistingWork(), 'node --version', false)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    await expect(manager.adoptMilestone(first.id)).rejects.toThrow(
      /blocking finding occurrence.*unresolved/i,
    )
    // Nothing ran: the milestone is exactly as the audit left it.
    expect(repo.getMilestone(first.id)?.status).toBe('audited')
    expect(repo.getMilestone(first.id)?.testResult).toBeNull()
  })

  it('clears mutation results left by an earlier execution attempt', async () => {
    // Adoption never runs the declared breaks, so results from a previous
    // execution must not sit beside adoption's fresh verdict as if it had
    // produced them.
    const { manager, repo, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutationResults: [
        {
          describes: 'left over from a failed run',
          file: 'src/net/client.ts',
          caught: false,
          skipped: 'stale',
          skipKind: 'unapplied',
          exitCode: null,
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.mutationResults).toEqual([])
  })

  it('fails rather than adopting when a declared break survives the suite', async () => {
    // Adoption runs the declared breaks exactly as execution does. A test
    // command that cannot notice the break leaves it surviving, and a
    // surviving break is the strongest possible evidence the milestone's
    // central claim rests on nothing — adopted or not.
    const { manager, repo, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutations: [
        {
          file: 'src/net/client.ts',
          find: 'capped = true',
          replace: 'capped = false',
          describes: 'the cap must stay on',
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.adopted).toBe(false)
    expect(done.mutationResults[0]).toMatchObject({ caught: false, skipped: '' })
    expect(done.reviewNote).toMatch(/did not catch/i)
    // The suite itself was green; the failure must not be misread as a test
    // failure.
    expect(done.reviewNote).not.toMatch(/Verification failed/)
  })

  it('adopts when the declared breaks are caught, and shows the reviewer they were', async () => {
    // grep -q capped fails once the mutation strips the word, so the break is
    // caught — and the adopt reviewer is handed the outcome as evidence about
    // the tests, exactly as a supervised review would be.
    const { manager, repo, registry, milestones } = await planIn(
      repoWithExistingWork(),
      'grep -q capped src/net/client.ts',
    )
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutations: [
        {
          file: 'src/net/client.ts',
          find: 'capped = true',
          replace: 'CAP_REMOVED = true',
          describes: 'the cap flag must be load-bearing',
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('complete')
    expect(done.adopted).toBe(true)
    expect(done.mutationResults[0]).toMatchObject({ caught: true, skipKind: '' })

    const reviewer = registry.get('claude') as unknown as { prompts: string[] }
    expect(
      reviewer.prompts.some(
        (prompt) => prompt.includes('MUTATION CHECKS') && prompt.includes('CAUGHT'),
      ),
    ).toBe(true)

    // The scariest part of running breaks against work nobody authored: the
    // file must be byte-identical afterwards.
    const plan = repo.getPlan(first.planId)
    if (!plan) throw new Error('expected the plan')
    expect(readFileSync(join(plan.repoPath, 'src/net/client.ts'), 'utf8')).toBe(
      'export const capped = true\n',
    )
  })

  it('re-anchors a stale check against adopted work and catches the break', async () => {
    // The planner wrote the anchor before any code existed, and for adopted
    // work the author is unknown — so the anchor missing is the normal case,
    // and the repair round (the reviewer's vendor, never a party with a stake)
    // points the same check at the code that is actually there.
    const repoPath = repoWithExistingWork('parley-adopt-repair-', 'RESOLVED\n')
    const { manager, repo, milestones } = await planIn(repoPath, 'grep -q RESOLVED src/net/client.ts')
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutations: [
        {
          file: 'src/net/client.ts',
          find: 'WINNER_HARDCODED',
          replace: 'x',
          describes: 'the resolved marker must be load-bearing',
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('complete')
    expect(done.mutationResults).toHaveLength(1)
    expect(done.mutationResults[0]).toMatchObject({ caught: true, skipKind: '' })
  })

  it('fails when a check cannot be expressed against the adopted code', async () => {
    // The "unfixable" sentinel makes the mock repair refuse. A check that
    // cannot be applied even after re-anchoring is unverifiable, and an
    // unverifiable claim must not adopt — same rule as execution.
    const repoPath = repoWithExistingWork('parley-adopt-unfixable-')
    const { manager, repo, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutations: [
        {
          file: 'src/net/client.ts',
          find: 'WINNER_HARDCODED',
          replace: 'x',
          describes: 'a claim nothing in this file decides',
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.adopted).toBe(false)
    expect(done.mutationResults[0]?.skipKind).toBe('unapplied')
    expect(done.reviewNote).toMatch(/even after being re-anchored/i)
  })

  it('does not run break checks against a red suite', async () => {
    // With a failing suite every applied break would "fail" and prove nothing,
    // so the stage is skipped — the adoption already fails on the tests.
    const { manager, repo, milestones } = await planIn(
      repoWithExistingWork(),
      'node --definitely-not-a-flag',
    )
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      mutations: [
        {
          file: 'src/net/client.ts',
          find: 'capped = true',
          replace: 'capped = false',
          describes: 'the cap must stay on',
        },
      ],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.mutationResults).toEqual([])
    expect(done.reviewNote).toMatch(/verification failed/i)
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

  it('refuses when only unrelated paths are dirty', async () => {
    const repoPath = repoWithExistingWork()
    execFileSync('git', ['add', 'src/net/client.ts'], { cwd: repoPath, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'existing milestone path'], {
      cwd: repoPath,
      stdio: 'ignore',
    })
    writeFileSync(join(repoPath, 'unrelated.md'), '# unrelated\n')

    const { manager, milestones } = await planIn(repoPath)
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    await expect(manager.adoptMilestone(first.id)).rejects.toThrow(/dirty paths.*expected paths/i)
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

  it('does not treat a missing verification command as a pass', async () => {
    const { manager, milestones } = await planIn(repoWithExistingWork(), '')
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.adopted).toBe(false)
    expect(done.testResult).toBeNull()
    expect(done.reviewNote).toMatch(/verification was not performed/i)
  })

  it('does not adopt partially present declared output', async () => {
    const missingPath = 'src/net/client.test.ts'
    const { manager, repo, registry, milestones } = await planIn(repoWithExistingWork())
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    repo.updateMilestone(first.id, {
      expectedPaths: [...first.expectedPaths, missingPath],
    })

    const done = await manager.adoptMilestone(first.id)
    expect(done.status).toBe('failed')
    expect(done.adopted).toBe(false)
    expect(done.reviewNote).toContain(missingPath)

    const reviewer = registry.get('claude') as unknown as { prompts: string[] }
    expect(
      reviewer.prompts.some(
        (prompt) => prompt.includes('DECLARED OUTPUTS THAT DO NOT EXIST') && prompt.includes(missingPath),
      ),
    ).toBe(true)
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
  async function planIn(
    repoPath: string,
    brief = 'x',
    configure?: (registry: AgentRegistry) => void,
  ) {
    const { manager, repo, events, registry } = harness()
    configure?.(registry)
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
      registry,
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

  it('blocks when the planner adapter cannot answer the audit', async () => {
    const { repo, plan, milestones } = await planIn(
      mkdtempSync(join(tmpdir(), 'parley-correction-error-')),
      'x',
      (registry) => {
        const planner = registry.get('claude')
        const originalRun = planner.run.bind(planner)
        planner.run = async (request) =>
          request.systemPrompt.includes('correcting your own plan')
            ? {
                text: '',
                usage: emptyUsage(),
                resumeId: null,
                exitCode: 1,
                error: 'mock correction failure',
              }
            : originalRun(request)
      },
    )
    const stored = repo.getPlan(plan.id)

    expect(stored?.status).toBe('blocked')
    expect(stored?.correctionNote).toMatch(/audited the plan and judged it/i)
    expect(stored?.correctionNote).toMatch(/mock correction failure/i)
    expect(milestones).toHaveLength(2)
  })

  it('blocks when the planner reply is not a usable correction', async () => {
    const { repo, plan, milestones } = await planIn(
      mkdtempSync(join(tmpdir(), 'parley-CORRECTION_UNREADABLE-')),
    )
    const stored = repo.getPlan(plan.id)

    expect(stored?.status).toBe('blocked')
    expect(stored?.correctionNote).toMatch(/audited the plan and judged it/i)
    expect(stored?.correctionNote).toMatch(/did not return a usable corrected plan/i)
    expect(milestones).toHaveLength(2)
  })

  it('blocks when audit findings receive no dispositions', async () => {
    const { repo, plan, milestones } = await planIn(
      mkdtempSync(join(tmpdir(), 'parley-NO_DISPOSITIONS-')),
    )
    const stored = repo.getPlan(plan.id)

    expect(stored?.status).toBe('blocked')
    expect(stored?.correctionNote).toMatch(/recorded no disposition/i)
    expect(milestones).toHaveLength(2)
  })

  it.each([
    {
      name: 'no findings',
      dispositions: [],
      blockingConcerns: [],
      expectedStatus: 'ready',
    },
    {
      name: 'only an accepted disposition',
      dispositions: [{ milestone: 0, disposition: 'accept', note: 'No change needed.' }],
      blockingConcerns: [],
      expectedStatus: 'ready',
    },
    {
      name: 'a rejected disposition',
      dispositions: [{ milestone: 0, disposition: 'reject', note: 'The approach is unsafe.' }],
      blockingConcerns: [],
      expectedStatus: 'blocked',
    },
    {
      name: 'a blocking concern',
      dispositions: [],
      blockingConcerns: ['The rollback path is missing.'],
      expectedStatus: 'blocked',
    },
  ])(
    'treats a disposition-free correction correctly after an audit with $name',
    async ({ name, dispositions, blockingConcerns, expectedStatus }) => {
      const auditText = [
        '```json',
        JSON.stringify({ verdict: 'sound', dispositions, blockingConcerns }),
        '```',
      ].join('\n')
      const { repo, plan, milestones } = await planIn(
        mkdtempSync(join(tmpdir(), `parley-NO_DISPOSITIONS-${name.replaceAll(' ', '-')}-`)),
        'x',
        (registry) => {
          const auditor = registry.get('codex')
          const originalRun = auditor.run.bind(auditor)
          auditor.run = async (request) =>
            request.systemPrompt.includes('audit other engineers')
              ? {
                  text: auditText,
                  usage: emptyUsage(),
                  resumeId: 'controlled-audit',
                  exitCode: 0,
                  error: null,
                }
              : originalRun(request)
        },
      )
      const stored = repo.getPlan(plan.id)

      expect(stored?.status).toBe(expectedStatus)
      expect(milestones).toHaveLength(expectedStatus === 'ready' ? 1 : 2)
    },
  )

  it('keeps the audit summary when a correction question is resumed', async () => {
    const { manager, repo, plan, milestones } = await planIn(
      mkdtempSync(join(tmpdir(), 'parley-correction-ASK_ME-')),
    )
    const parked = repo.getPlan(plan.id)

    expect(parked?.status).toBe('awaiting-clarification')
    expect(parked?.correctionNote).toMatch(/audited the plan and judged it/i)
    expect(milestones).toHaveLength(2)

    const resumed = await manager.answerPlan(plan.id, 'Apply the cap per host.')
    const note = repo.getPlan(plan.id)?.correctionNote ?? ''

    expect(resumed.plan.status).toBe('ready')
    expect(resumed.milestones).toHaveLength(1)
    expect(note).toMatch(/audited the plan and judged it/i)
    expect(note).toMatch(/The planner answered the audit/i)
  })

  it('keeps the audit finding count when a correction question is resumed', async () => {
    const { manager, repo, plan } = await planIn(
      mkdtempSync(join(tmpdir(), 'parley-correction-ASK_ME-NO_DISPOSITIONS-')),
    )

    expect(repo.getPlan(plan.id)?.status).toBe('awaiting-clarification')

    const resumed = await manager.answerPlan(plan.id, 'Apply the cap per host.')

    expect(resumed.plan.status).toBe('blocked')
    expect(repo.getPlan(plan.id)?.correctionNote).toMatch(/recorded no disposition/i)
    expect(resumed.milestones).toHaveLength(2)
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
    disposeOpenBlockingOccurrences(repo, session.id)
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
    disposeOpenBlockingOccurrences(repo, session.id)
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
    disposeOpenBlockingOccurrences(repo, session.id)
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
    disposeOpenBlockingOccurrences(repo, session.id)
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
  async function readyPlan() {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-gate-'))
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
    await manager.whenPlanSettled(plan.id)
    const milestone = repo.listMilestones(plan.id)[0]
    if (!milestone) throw new Error('expected a milestone')
    repo.updateMilestone(milestone.id, { testCommand: 'node --version' })
    return { manager, repo, plan, milestone }
  }

  it('fails a session with no usable verdict and refuses to plan from it', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-'))
    const session = manager.startSession({
      kind: 'debate',
      matter: 'NO_VERDICT',
      project: '',
      repoPath: null,
      agentA: claude,
      agentB: codex,
      maxTurns: 2,
    })

    await waitFor(() => repo.getSession(session.id)?.status === 'failed')

    const failed = repo.getSession(session.id)
    expect(failed?.error).toMatch(/neither advisor produced a usable structured verdict/i)
    expect(repo.getVerdict(session.id)).toBeNull()
    expect(repo.listTurns(session.id).filter((turn) => turn.stage === 'Verdict')).toHaveLength(2)

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

    // The Manager refuses to grant approval while the audit occurrence remains
    // unresolved, and direct execution cannot bypass the same gate.
    const first = milestones[0]
    if (!first) throw new Error('expected a milestone')
    expect(() =>
      manager.grantMilestoneApproval(first.id, 'allow the write'),
    ).toThrow(/blocking finding occurrence.*unresolved/i)
    const premature = repo.grantApproval(
      'milestone.execute',
      first.id,
      'must remain unused',
    )
    await expect(manager.runMilestone(first.id, premature.id)).rejects.toThrow(
      /blocking finding occurrence.*unresolved/i,
    )
    expect(
      repo.listApprovals().find((approval) => approval.id === premature.id)?.consumedAt,
    ).toBeNull()
    // Adoption is the third door to a completed milestone, and the same gate
    // closes it. No tree setup is needed: the gate is checked before the tree
    // is read, so the refusal cannot depend on what happens to be on disk.
    await expect(manager.adoptMilestone(first.id)).rejects.toThrow(
      /blocking finding occurrence.*unresolved/i,
    )

    disposeOpenBlockingOccurrences(repo, session.id)
    const approval = manager.grantMilestoneApproval(first.id, 'allow the write')
    const done = await manager.runMilestone(first.id, approval.id)

    expect(done.approvalId).toBe(approval.id)
    expect(['complete', 'failed']).toContain(done.status)
    expect(repo.listApprovals().find((a) => a.id === approval.id)?.consumedAt).not.toBeNull()

    // Re-running needs a fresh approval; the spent one is refused.
    await expect(manager.runMilestone(first.id, approval.id)).rejects.toThrow()
  })

  it('refuses an approval id that does not exist, before anything runs', async () => {
    // Restores an assertion the m6 rework deleted with its test: the engine
    // must refuse a fabricated approval id outright. The store test pins
    // consumeApproval itself; this pins that runMilestone reaches it and that
    // the refusal leaves the milestone untouched. The ledger is settled first
    // so the finding gate cannot be the thing doing the refusing.
    const { manager, repo, plan, milestone } = await readyPlan()
    disposeOpenBlockingOccurrences(repo, plan.sessionId)

    await expect(manager.runMilestone(milestone.id, 'no-such-approval')).rejects.toThrow(
      /no such approval/i,
    )
    expect(repo.getMilestone(milestone.id)?.status).toBe('audited')
    expect(repo.getMilestone(milestone.id)?.testResult).toBeNull()
  })

  it('does not expose audited draft milestones after an interrupted correction', async () => {
    const { manager, repo, plan, milestone } = await readyPlan()
    repo.setPlanStatus(plan.id, 'correcting')
    repo.reconcileInterrupted()
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'must remain unused')

    await expect(manager.runMilestone(milestone.id, approval.id)).rejects.toThrow(/status pair/i)
    await expect(manager.adoptMilestone(milestone.id)).rejects.toThrow(/status pair/i)
    expect(repo.getPlan(plan.id)?.status).toBe('blocked')
    expect(repo.listApprovals().find((item) => item.id === approval.id)?.consumedAt).toBeNull()
  })

  it('blocks a plan whose audit could not run instead of offering its unaudited milestones', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-AUDIT_FAILS-'))
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
    await manager.whenPlanSettled(plan.id)
    const milestone = repo.listMilestones(plan.id)[0]
    if (!milestone) throw new Error('expected a milestone')
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'must remain unused')

    expect(repo.getPlan(plan.id)?.status).toBe('blocked')
    expect(milestone.status).toBe('planned')
    expect(milestone.auditNote).toMatch(/execution is blocked/i)
    await expect(manager.runMilestone(milestone.id, approval.id)).rejects.toThrow(/status pair/i)
    expect(repo.listApprovals().find((item) => item.id === approval.id)?.consumedAt).toBeNull()
  })

  it('blocks a plan whose audit reply is unreadable instead of marking its milestones audited', async () => {
    const { manager, repo } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-AUDIT_UNREADABLE-'))
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
    await manager.whenPlanSettled(plan.id)
    const milestones = repo.listMilestones(plan.id)

    expect(repo.getPlan(plan.id)?.status).toBe('blocked')
    expect(milestones.length).toBeGreaterThan(0)
    expect(milestones.every((milestone) => milestone.status === 'planned')).toBe(true)
    expect(milestones.every((milestone) => /reply could not be read/i.test(milestone.auditNote))).toBe(true)
  })

  it('does not block a parseable audit that found nothing', async () => {
    const { manager, repo, registry } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-plan-clean-audit-'))
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

    const auditor = registry.get('codex')
    const originalRun = auditor.run.bind(auditor)
    auditor.run = async (request) =>
      request.systemPrompt.includes('audit other engineers')
        ? {
            text: '```json\n{"verdict":"sound","dispositions":[],"blockingConcerns":[]}\n```',
            usage: emptyUsage(),
            resumeId: 'clean-audit',
            exitCode: 0,
            error: null,
          }
        : originalRun(request)

    const { plan } = await manager.createPlan({
      sessionId: session.id,
      kind: 'implementation',
      repoPath,
      planner: claude,
      executor: codex,
      reviewer: claude,
    })
    await manager.whenPlanSettled(plan.id)

    expect(repo.getPlan(plan.id)?.status).toBe('ready')
    expect(repo.listMilestones(plan.id).every((milestone) => milestone.status === 'audited')).toBe(true)
  })

  it('refuses a concurrent milestone start before spending its approval', async () => {
    const { manager, repo, plan, milestone } = await readyPlan()
    disposeOpenBlockingOccurrences(repo, plan.sessionId)
    const firstApproval = repo.grantApproval('milestone.execute', milestone.id, 'first start')
    const racingApproval = repo.grantApproval('milestone.execute', milestone.id, 'racing start')

    const firstRun = manager.runMilestone(milestone.id, firstApproval.id)
    expect(repo.getMilestone(milestone.id)?.status).toBe('executing')

    await expect(manager.runMilestone(milestone.id, racingApproval.id)).rejects.toThrow(
      /already executing/i,
    )
    expect(repo.listApprovals().find((item) => item.id === racingApproval.id)?.consumedAt).toBeNull()

    await firstRun
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
