import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Pipeline, type RunState } from './pipeline'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(): { pipeline: Pipeline; repo: Repo; session: Session } {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const pipeline = new Pipeline({ repo, registry, emit: (event) => events.push(event) })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Does a crashed run leave enough behind?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  return { pipeline, repo, session }
}

function gitRepo(prefix: string): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
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

function makePlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Run-state lifecycle',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout',
    setupCommand: '',
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
    title: 'Write the mock work file',
    intent: 'Produce something observable.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'audited',
    auditNote: '',
    testCommand: 'true',
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

describe('run-state lifecycle', () => {
  it('a completed run clears its run state', async () => {
    const { pipeline, repo, session } = harness()
    const plan = makePlan(repo, session.id, gitRepo('parley-rs-pass-'))
    const milestone = makeMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test')

    const done = await pipeline.runMilestone(milestone.id, approval.id)
    expect(done.status).toBe('complete')
    expect(repo.getMilestoneRunState(milestone.id)).toBeNull()
    expect(done.runState ?? null).toBeNull()
  })

  it('a failed run preserves everything a resumption needs', async () => {
    const { pipeline, repo, session } = harness()
    // The stubborn sentinel keeps the mock reviewer objecting through every
    // round, so the run exhausts its remediation budget and fails.
    const plan = makePlan(repo, session.id, gitRepo('parley-rs-stubborn-'))
    const milestone = makeMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test')

    const failed = await pipeline.runMilestone(milestone.id, approval.id)
    expect(failed.status).toBe('failed')

    const state = repo.getMilestoneRunState<RunState>(milestone.id)
    if (!state) throw new Error('expected the run state to survive the failure')
    expect(state.round).toBe(2)
    expect(state.previousConcerns.length).toBeGreaterThan(0)
    expect(state.reviewerNote.length).toBeGreaterThan(0)
    expect(state.executionReport.length).toBeGreaterThan(0)
    expect(state.executorResumeId).toMatch(/^mock-/)
    expect(state.reviewerResumeId).toMatch(/^mock-/)
    expect(state.baselineHead).toMatch(/^[0-9a-f]{40}$/)
    expect(state.before.unknown).toBe(false)
    // The wire summary carries the round but never the baseline or the ids.
    expect(failed.runState?.round).toBe(2)

    // Adoption entry supersedes the interrupted attempt and clears it. The
    // failed run's review blockers gate adoption, so they are dispositioned
    // first — the same order a human would clear them in.
    for (const finding of repo.listLedgerFindings(session.id)) {
      repo.disposeFinding({
        findingId: finding.id,
        occurrenceId: null,
        state: 'dismissed',
        note: 'Cleared to exercise the adoption entry.',
        source: 'human',
      })
    }
    await pipeline.adoptMilestone(milestone.id).catch(() => {
      // The stubborn tree fails adoption review; the entry-clear is the point.
    })
    expect(repo.getMilestoneRunState(milestone.id)).toBeNull()
  })
})
