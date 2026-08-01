import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { emptyUsage, type Milestone, type WorkPlan } from '@shared/domain'
import { candidateRefFor } from '@shared/remote'
import { milestonePatch, type MilestoneFact } from '@main/orchestrator/reporter'
import { FramingMilestoneReporter } from './reporter'
import { ensureMirror } from './worktree'
import { cleanupRun, runWorker, type WorkerRequest } from './worker'

/**
 * A milestone actually running on the remote side.
 *
 * Real git, a real worktree, the real execution core, and the mock adapters
 * standing in for the paid CLIs — which is the same substitution local
 * integration tests make, so what is exercised here is the remote wiring
 * rather than a simulation of it.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

function temp(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix))
  roots.push(root)
  return root
}

function sh(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Test',
      GIT_AUTHOR_EMAIL: 't@example.com',
      GIT_COMMITTER_NAME: 'Test',
      GIT_COMMITTER_EMAIL: 't@example.com',
    },
  }).trim()
}

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

/** A mirror with an input ref, exactly as the local side would have left one. */
async function submitted(): Promise<{ request: WorkerRequest; runsRoot: string }> {
  const source = temp('parley-worker-src-')
  sh(source, 'init', '-q', '-b', 'main')
  writeFileSync(join(source, 'seed.txt'), 'seed\n')
  sh(source, 'add', '-A')
  sh(source, 'commit', '-q', '-m', 'seed')
  const commit = sh(source, 'rev-parse', 'HEAD')

  const mirrorsRoot = temp('parley-worker-mirrors-')
  const mirror = await ensureMirror(mirrorsRoot, 'repo')
  sh(source, 'push', '-q', mirror.path!, `${commit}:refs/parley/runs/run-1/input`)

  const runsRoot = temp('parley-worker-runs-')
  const plan: WorkPlan = {
    id: 'plan-1',
    sessionId: 'session-1',
    kind: 'implementation',
    title: 'Remote plan',
    repoPath: source,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  } as WorkPlan
  const milestone: Milestone = {
    id: 'milestone-1',
    planId: plan.id,
    index: 0,
    title: 'Do the remote thing',
    intent: 'Something the mock adapter finishes.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'audited',
    auditNote: '',
    testCommand: 'node --version',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
  } as unknown as Milestone

  return {
    runsRoot,
    request: {
      runId: 'run-1',
      mirrorDir: mirror.path!,
      runsRoot,
      expectedCommit: commit,
      plan,
      milestone,
    },
  }
}

describe('a milestone that completes on the remote', () => {
  it('runs in the isolated worktree and publishes a candidate', async () => {
    const { request, runsRoot } = await submitted()
    const bodies: Array<{ type: string; fact?: MilestoneFact }> = []
    const { result, manifest } = await runWorker(request, (body) => bodies.push(body as never))

    expect(result.status).toBe('completed')
    expect(manifest).not.toBeNull()
    expect(manifest?.baseCommit).toBe(request.expectedCommit)

    // The candidate is in the mirror, and it descends from what was submitted.
    const at = sh(request.mirrorDir, 'rev-parse', candidateRefFor('run-1'))
    expect(at).toBe(manifest?.resultCommit)
    expect(() =>
      sh(request.mirrorDir, 'merge-base', '--is-ancestor', request.expectedCommit, at),
    ).not.toThrow()

    // The mock executor's file travelled: the run really produced a tree.
    expect(manifest?.changedPaths).toContain('parley-mock-work.txt')
    expect(sh(request.mirrorDir, 'ls-tree', '-r', '--name-only', at)).toContain(
      'parley-mock-work.txt',
    )

    // Work happened in the run directory, never in the submitting repository.
    expect(existsSync(join(runsRoot, 'run-1', 'parley-mock-work.txt'))).toBe(true)
    expect(existsSync(join(request.plan.repoPath, 'parley-mock-work.txt'))).toBe(false)
  }, 120_000)

  it('reports facts as bodies, never as rows', async () => {
    const { request } = await submitted()
    const bodies: Array<{ type: string; fact?: MilestoneFact }> = []
    await runWorker(request, (body) => bodies.push(body as never))

    const facts = bodies.filter((body) => body.type === 'fact').map((body) => body.fact!)
    expect(facts.length).toBeGreaterThan(3)
    // The same vocabulary the local reporter speaks — and the terminal fact is
    // what the local side will turn into a completed milestone row.
    expect(facts.some((fact) => fact.kind === 'phase')).toBe(true)
    expect(facts.some((fact) => fact.kind === 'verification')).toBe(true)
    expect(facts.some((fact) => fact.kind === 'finished' && fact.passed)).toBe(true)
    expect(bodies.some((body) => body.type === 'progress')).toBe(true)
  }, 120_000)
})

describe('endings that are not results', () => {
  it('refuses to publish when the milestone did not complete', async () => {
    // The distinction that stops "whatever tree existed when the code stopped"
    // becoming a published result. A refusal is a real ending — the record
    // says so — but there is nothing to import.
    const { request } = await submitted()
    const stalled: WorkerRequest = {
      ...request,
      // No expected paths and a command that fails: the run ends without
      // completing, through the ordinary route rather than an exception.
      milestone: { ...request.milestone, testCommand: 'node --eval process.exit(3)' },
    }
    const { result, manifest } = await runWorker(stalled, () => {})
    expect(result.status).not.toBe('completed')
    expect(manifest).toBeNull()
    expect(() => sh(request.mirrorDir, 'rev-parse', candidateRefFor('run-1'))).toThrow()
  }, 120_000)

  it('fails without publishing when the input ref is not what was submitted', async () => {
    const { request } = await submitted()
    const wrong = { ...request, expectedCommit: 'f'.repeat(40) }
    const { result, manifest } = await runWorker(wrong, () => {})
    expect(result.status).toBe('failed')
    expect(manifest).toBeNull()
    expect(() => sh(request.mirrorDir, 'rev-parse', candidateRefFor('run-1'))).toThrow()
  }, 120_000)

  it('reports cancellation without publishing', async () => {
    const { request } = await submitted()
    const controller = new AbortController()
    controller.abort()
    const { result, manifest } = await runWorker(request, () => {}, controller.signal)
    expect(['cancelled', 'failed']).toContain(result.status)
    expect(manifest).toBeNull()
  }, 120_000)
})

describe('cleanup', () => {
  it('removes the run worktree and leaves the mirror usable', async () => {
    const { request, runsRoot } = await submitted()
    await runWorker(request, () => {})
    expect(existsSync(join(runsRoot, 'run-1'))).toBe(true)

    await cleanupRun(request.mirrorDir, runsRoot, 'run-1')
    expect(existsSync(join(runsRoot, 'run-1'))).toBe(false)
    // The candidate survives cleanup: the tree is gone, the result is not.
    expect(sh(request.mirrorDir, 'rev-parse', candidateRefFor('run-1')).length).toBe(40)
  }, 120_000)

  it('is safe to call when there is nothing to clean', async () => {
    const { request, runsRoot } = await submitted()
    await expect(cleanupRun(request.mirrorDir, runsRoot, 'never-ran')).resolves.toBeUndefined()
  }, 60_000)
})

describe('the framing reporter', () => {
  it('emits the fact before moving its own projection', () => {
    // If the write throws — a closed pipe, a dead connection — both sides are
    // left at the last state actually reported, rather than this one running
    // ahead of what anyone knows.
    const milestone = { id: 'm', status: 'pending' } as Milestone
    const seen: unknown[] = []
    const reporter = new FramingMilestoneReporter(milestone, (body) => {
      seen.push(body)
      expect(reporter.milestone.status).toBe('pending')
    })
    const after = reporter.record({ kind: 'phase', phase: 'executing' })
    expect(after.status).toBe('executing')
    expect(seen).toEqual([{ type: 'fact', fact: { kind: 'phase', phase: 'executing' } }])
  })

  it('projects exactly what the local reporter would persist', () => {
    // One definition of what a fact means, used by both sides. Two would agree
    // until they did not, and neither would notice.
    const milestone = { id: 'm', status: 'pending' } as Milestone
    const reporter = new FramingMilestoneReporter(milestone, () => {})
    const facts: MilestoneFact[] = [
      { kind: 'phase', phase: 'testing' },
      { kind: 'judgement', passed: true },
      { kind: 'finished', passed: true, note: 'done', completedAt: 7 },
    ]
    let expected = milestone
    for (const fact of facts) {
      reporter.record(fact)
      const patch = milestonePatch(fact)
      if (patch) expected = { ...expected, ...patch }
    }
    expect(reporter.milestone).toEqual(expected)
  })
})
