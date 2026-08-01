import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { MAX_ACTIVITY_CHARS, type RunEvent } from '@shared/journal'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { milestonePatch, type MilestoneFact } from './reporter'
import { Pipeline } from './pipeline'

/**
 * What a run leaves behind once it is over.
 *
 * The point of the journal is that the story survives, not just the ending. A
 * milestone row can say "failed"; only the journal can say the reviewer
 * blocked it, the executor addressed it, and the second attempt still did not
 * verify. These tests run real milestones and read what was kept.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function gitRepo(): string {
  const repoPath = mkdtempSync(join(tmpdir(), 'parley-journal-'))
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

function harness(): { pipeline: Pipeline; repo: Repo; registry: AgentRegistry; session: Session } {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const pipeline = new Pipeline({ repo, registry, emit: (event) => events.push(event) })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'journal',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  return { pipeline, repo, registry, session }
}

function makePlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Journal plan',
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
    title: 'Journalled milestone',
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
  })
}

async function runOnce(): Promise<{ repo: Repo; milestone: Milestone; runs: Array<{ runId: string; events: RunEvent[] }> }> {
  const { pipeline, repo, session } = harness()
  const plan = makePlan(repo, session.id, gitRepo())
  const milestone = makeMilestone(repo, plan.id)
  const approval = repo.grantApproval('milestone.execute', milestone.id, 'journal')
  await pipeline.runMilestone(milestone.id, approval.id)
  return { repo, milestone, runs: repo.listMilestoneRuns(milestone.id) }
}

describe('a run leaves a story behind', () => {
  it('opens with run.started and closes with run.ended', async () => {
    const { runs } = await runOnce()
    expect(runs).toHaveLength(1)
    const events = runs[0]!.events
    expect(events[0]?.kind).toBe('run.started')
    expect(events[0]?.payload).toMatchObject({ entry: 'fresh' })
    expect(events[events.length - 1]?.kind).toBe('run.ended')
    expect(events[events.length - 1]?.payload).toMatchObject({ outcome: 'complete' })
  }, 60_000)

  it('numbers its events from one with no gaps', async () => {
    // Ordering is the point of a journal, and occurred_at cannot provide it —
    // two events can land in the same millisecond.
    const { runs } = await runOnce()
    const sequences = runs[0]!.events.map((event) => event.sequence)
    expect(sequences).toEqual(sequences.map((_, index) => index + 1))
  }, 60_000)

  it('keeps the facts, and they rebuild the row the run actually produced', async () => {
    // The property the whole journal rests on: replaying what was kept lands
    // on the state that was persisted. If these diverge, the journal is a
    // plausible fiction rather than a record.
    const { repo, milestone, runs } = await runOnce()
    const facts = runs[0]!.events
      .filter((event) => event.kind === 'fact')
      .map((event) => event.payload as MilestoneFact)
    expect(facts.length).toBeGreaterThan(3)

    let projected = milestone
    for (const fact of facts) {
      const patch = milestonePatch(fact)
      if (patch) projected = { ...projected, ...patch }
    }
    const persisted = repo.getMilestone(milestone.id)!
    expect(projected.status).toBe(persisted.status)
    expect(projected.reviewPassed).toBe(persisted.reviewPassed)
    expect(projected.completedAt).toBe(persisted.completedAt)
    expect(projected.reviewNote).toBe(persisted.reviewNote)
  }, 60_000)

  it('attributes each fact to whoever actually produced it', async () => {
    // A run has more than one actor, and flattening them would make "which
    // agent raised this finding" unanswerable — one of the questions a journal
    // exists to answer.
    const { runs } = await runOnce()
    const by = (kind: string): RunEvent[] =>
      runs[0]!.events.filter(
        (event) => event.kind === 'fact' && (event.payload as { kind: string }).kind === kind,
      )

    for (const event of by('phase')) {
      expect(event.actor).toMatchObject({ kind: 'agent', vendor: 'codex' })
    }
    for (const event of by('judgement')) {
      expect(event.actor).toMatchObject({ kind: 'reviewer', vendor: 'claude' })
    }
    // Verification is nobody's opinion: Parley ran the command and watched.
    // That is exactly why it outweighs anything an agent says about its work.
    for (const event of by('verification')) {
      expect(event.actor.kind).toBe('verifier')
      expect(event.actor.vendor).toBeUndefined()
    }
    for (const event of by('planOutcome')) {
      expect(event.actor.kind).toBe('system')
    }
    // Nothing ran elsewhere, so nothing claims a host.
    expect(runs[0]!.events.every((event) => event.actor.targetId === undefined)).toBe(true)
  }, 60_000)

  it('keeps the narrative, truncated rather than whole', async () => {
    const { runs } = await runOnce()
    const activity = runs[0]!.events.filter((event) => event.kind === 'activity')
    expect(activity.length).toBeGreaterThan(0)
    for (const event of activity) {
      const text = (event.payload as { text: string }).text
      expect(text.length).toBeLessThanOrEqual(MAX_ACTIVITY_CHARS)
    }
  }, 60_000)
})

describe('a milestone accumulates attempts', () => {
  it('gives each attempt its own run rather than flattening them', async () => {
    // A resume spends a fresh approval and is a new attempt. Three tries are
    // three stories, and a reader who cannot tell them apart cannot see that
    // the first two failed.
    const { pipeline, repo, registry, session } = harness()
    const plan = makePlan(repo, session.id, gitRepo())
    const milestone = makeMilestone(repo, plan.id)

    const executor = registry.get('codex')
    executor.run = async () => ({
      text: 'Done, nothing to change.',
      usage: emptyUsage(),
      error: null,
      resumeId: null,
      exitCode: 0,
    })

    const first = repo.grantApproval('milestone.execute', milestone.id, 'attempt one')
    await pipeline.runMilestone(milestone.id, first.id)
    const second = repo.grantApproval('milestone.execute', milestone.id, 'attempt two')
    await pipeline.runMilestone(milestone.id, second.id)

    const runs = repo.listMilestoneRuns(milestone.id)
    expect(runs).toHaveLength(2)
    expect(new Set(runs.map((run) => run.runId)).size).toBe(2)
    // Each attempt's sequence starts again at one: sequences are per run.
    for (const run of runs) expect(run.events[0]?.sequence).toBe(1)
  }, 90_000)
})

describe('the journal and the record cannot half-apply', () => {
  it('rolls the event back when the write beside it fails', async () => {
    // A journal entry recording a fact whose row write failed is worse than no
    // journal, because it reads as authoritative.
    const repo = new Repo(openDatabase(':memory:'))
    const before = repo.listRunEvents('run-x').length
    expect(() =>
      repo.transaction(() => {
        repo.appendRunEvent({
          id: newId(),
          runId: 'run-x',
          milestoneId: 'm',
          planId: 'p',
          sequence: 1,
          occurredAt: Date.now(),
          actor: { kind: 'system' },
          kind: 'fact',
          payload: { kind: 'phase', phase: 'testing' },
        })
        throw new Error('the row write failed')
      }),
    ).toThrow('the row write failed')
    expect(repo.listRunEvents('run-x')).toHaveLength(before)
  })

  it('lets a caller join a transaction that is already open', async () => {
    // The re-entrancy this milestone needed: updateMilestone opens its own,
    // and a nested BEGIN used to throw — which is why two -Core variants exist
    // in this codebase for no other reason.
    const repo = new Repo(openDatabase(':memory:'))
    const kept = repo.transaction(() =>
      repo.transaction(() => {
        repo.appendRunEvent({
          id: newId(),
          runId: 'run-y',
          milestoneId: 'm',
          planId: 'p',
          sequence: 1,
          occurredAt: Date.now(),
          actor: { kind: 'system' },
          kind: 'run.started',
          payload: { entry: 'fresh' },
        })
        return 'committed'
      }),
    )
    expect(kept).toBe('committed')
    expect(repo.listRunEvents('run-y')).toHaveLength(1)
  })
})
