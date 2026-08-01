import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Pipeline } from './pipeline'

/**
 * The order a finished milestone touches the record in.
 *
 * Written BEFORE the execution core is extracted into a standalone function,
 * and deliberately: the sequence below is observable behaviour that no
 * existing test pins, which makes it exactly the kind of thing a refactor can
 * change while staying green. Settling the ledger before the plan's status
 * moves, rather than after, is a decision — and it should have to be a
 * decision again if anyone reverses it.
 *
 * This is a characterisation test. It does not argue that this order is the
 * only correct one; it records what today's code does so that the extraction
 * has something to be identical to.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function gitRepo(): string {
  const repoPath = mkdtempSync(join(tmpdir(), 'parley-order-'))
  roots.push(repoPath)
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
  }
  git('init', '-q')
  git('config', 'user.email', 'test@example.invalid')
  git('config', 'user.name', 'Parley Test')
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  git('commit', '-qm', 'seed')
  return repoPath
}

/**
 * Wraps the repository so every write worth ordering announces itself.
 *
 * A proxy rather than a mock: the real Repo still does the real work, so the
 * run behaves exactly as it would otherwise and the trace is an observation
 * rather than a script.
 */
function tracingRepo(repo: Repo, trace: string[]): Repo {
  const watched: Record<string, (args: unknown[]) => string | null> = {
    recordFindingOccurrence: (args) => {
      const provenance = args[0] as { kind?: string }
      return `finding:${provenance.kind ?? '?'}`
    },
    updateMilestone: (args) => {
      const patch = args[1] as Partial<Milestone>
      if (patch.status === 'complete' || patch.status === 'failed') {
        return `milestone:${patch.status}`
      }
      return null
    },
    disposeFinding: () => 'settle',
    setPlanStatus: (args) => `plan:${String(args[1])}`,
  }
  return new Proxy(repo, {
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver) as unknown
      if (typeof value !== 'function') return value
      const label = watched[property as string]
      if (!label) return (value as (...a: unknown[]) => unknown).bind(target)
      return (...args: unknown[]) => {
        const entry = label(args)
        if (entry) trace.push(entry)
        return (value as (...a: unknown[]) => unknown).apply(target, args)
      }
    },
  }) as Repo
}

function harness(trace: string[]): {
  pipeline: Pipeline
  repo: Repo
  registry: AgentRegistry
  events: AppEvent[]
  session: Session
} {
  const real = new Repo(openDatabase(':memory:'))
  const repo = tracingRepo(real, trace)
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const pipeline = new Pipeline({ repo, registry, emit: (event) => events.push(event) })
  const session = real.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'ordering',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  return { pipeline, repo: real, registry, events, session }
}

function makePlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Ordering plan',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout' as const,
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
}

function makeMilestone(repo: Repo, planId: string): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Do the ordered thing',
    intent: 'Something the mock adapter will happily finish.',
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
  })
}

describe('the order a milestone settles in', () => {
  it('records findings, then ends the milestone, then settles, then moves the plan', async () => {
    const trace: string[] = []
    const { pipeline, repo, session } = harness(trace)
    const repoPath = gitRepo()
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'ordering')

    await pipeline.runMilestone(milestone.id, approval.id)

    // The shape that must survive the extraction. Findings are recorded while
    // the review is being read; the terminal milestone fact lands next; the
    // ledger is settled against that completion; the plan's status moves last,
    // because it is derived from where the milestone ended up.
    // A plan's status also moves at the START of a run ('running'), so the
    // one that matters is the LAST — the outcome derived from where the
    // milestone ended up.
    const milestoneAt = trace.findIndex((entry) => entry.startsWith('milestone:'))
    const planAt = trace.map((entry) => entry.startsWith('plan:')).lastIndexOf(true)
    expect(trace[0]).toBe('plan:running')
    expect(milestoneAt).toBeGreaterThan(0)
    expect(planAt).toBeGreaterThan(milestoneAt)
    expect(trace[planAt]).toBe('plan:complete')

    const findings = trace.filter((entry) => entry.startsWith('finding:'))
    for (const [index, entry] of trace.entries()) {
      if (entry.startsWith('finding:')) {
        // Every finding is recorded before the milestone is declared over: a
        // finding filed afterwards would be provenance for a milestone that
        // had already been judged without it.
        expect(index).toBeLessThan(milestoneAt)
      }
      if (entry === 'settle') {
        // Settlement reads the milestone's completion, so it must come after
        // the terminal fact and before the plan status derived from it.
        expect(index).toBeGreaterThan(milestoneAt)
        expect(index).toBeLessThan(planAt)
      }
    }
    // The trace must actually contain the things it claims to order. A rename
    // that made every probe stop matching would otherwise leave this test
    // passing forever while observing nothing.
    expect(findings.length).toBeGreaterThan(0)
    expect(trace).toContain('settle')
  }, 60_000)

  it('moves the plan to failed without settling when the milestone fails', async () => {
    // The other branch through the same tail. A failed milestone must not
    // settle findings — they are exactly what is still outstanding.
    const trace: string[] = []
    const { pipeline, repo, registry, session } = harness(trace)
    const repoPath = gitRepo()
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'ordering')

    // An executor that reports success while changing nothing: the tree guard
    // refuses it, which is the cheapest deterministic failure available.
    const executor = registry.get('codex')
    executor.run = async () => ({
      text: 'Done, nothing to change.',
      usage: emptyUsage(),
      error: null,
      resumeId: null,
      exitCode: 0,
    })

    await pipeline.runMilestone(milestone.id, approval.id)

    expect(trace).toContain('milestone:failed')
    expect(trace).not.toContain('settle')
    expect(trace[trace.length - 1]).toBe('plan:failed')
  }, 60_000)
})
