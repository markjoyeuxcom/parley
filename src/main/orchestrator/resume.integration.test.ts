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
import { Pipeline, readTree, revParseHead, type RunState } from './pipeline'

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
    matter: 'Can an interrupted run continue as a critique?',
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

function makeFailedPlan(repo: Repo, sessionId: string, repoPath: string): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Interrupted work',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'failed',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'checkout',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
}

function makeFailedMilestone(repo: Repo, planId: string): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Write the mock work file',
    intent: 'Produce the observable file.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'failed',
    auditNote: '',
    testCommand: 'true',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: 'Interrupted when Parley last quit. The run state was preserved, so this milestone can be resumed with a fresh approval.',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
  })
}

async function fabricateInterruption(
  repo: Repo,
  sessionId: string,
  origin: string,
  options: { workPresent: boolean },
): Promise<{ plan: WorkPlan; milestone: Milestone; state: RunState }> {
  // The baseline is captured before the "interrupted" work lands, exactly as a
  // real run captures it before the executor's first byte.
  const before = await readTree(origin)
  const baselineHead = await revParseHead(origin)
  if (options.workPresent) {
    writeFileSync(join(origin, 'parley-mock-work.txt'), 'RESOLVED\n')
  }
  const plan = makeFailedPlan(repo, sessionId, origin)
  const milestone = makeFailedMilestone(repo, plan.id)
  const state: RunState = {
    startedAt: Date.now() - 60_000,
    round: 0,
    previousConcerns: [],
    reviewerNote: '',
    executionReport: 'the executor reported writing the file before the crash',
    executorResumeId: 'mock-codex-99',
    reviewerResumeId: null,
    before,
    baselineHead,
    lastActivityAt: null,
    lastInspection: null,
  }
  repo.setMilestoneRunState(milestone.id, state)
  return { plan, milestone, state }
}

describe('resuming an interrupted milestone', () => {
  it('verifies work already present instead of re-executing, and marks the round resumed', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-resume-verify-')
    const { milestone } = await fabricateInterruption(repo, session.id, origin, {
      workPresent: true,
    })
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'resume test')

    const resumed = await pipeline.resumeMilestone(milestone.id, approval.id)

    expect(resumed.status).toBe('complete')
    // The interrupted note survives as history, and the resumed round says so.
    expect(resumed.reviewNote).toMatch(/interrupted when parley last quit/i)
    expect(resumed.reviewNote).toMatch(/Round 1 \(resumed after interruption\)/)
    expect(resumed.completedAt).not.toBeNull()
    // Complete clears the state; the fresh approval was spent.
    expect(repo.getMilestoneRunState(milestone.id)).toBeNull()
    expect(repo.listApprovals().find((a) => a.id === approval.id)?.consumedAt).not.toBeNull()
    expect(repo.getPlan(resumed.planId)?.status).toBe('complete')
  })

  it('re-enters execution as a continuation when nothing had landed', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-resume-exec-')
    const { milestone } = await fabricateInterruption(repo, session.id, origin, {
      workPresent: false,
    })
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'resume test')

    const resumed = await pipeline.resumeMilestone(milestone.id, approval.id)

    // The mock executor's first write is the objectionable sentinel, so the
    // resumed run remediates once — proving the loop continues normally after
    // a resumed entry rather than being a one-shot pass.
    expect(resumed.status).toBe('complete')
    expect(resumed.reviewNote).toMatch(/Round 1 \(resumed after interruption\)/)
    expect(resumed.reviewNote).toMatch(/Round 2 — /)
    expect(resumed.reviewNote).not.toMatch(/Round 2 \(resumed/)
    expect(repo.getMilestoneRunState(milestone.id)).toBeNull()
  })

  it('refuses when the repository moved since the interruption, spending nothing', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-resume-moved-')
    const { milestone } = await fabricateInterruption(repo, session.id, origin, {
      workPresent: true,
    })
    // The user (or a retry) committed after the crash: every baseline
    // signature is now relative to a HEAD that no longer exists here.
    writeFileSync(join(origin, 'seed.txt'), 'moved on\n')
    execFileSync('git', ['commit', '-aqm', 'the world moved'], { cwd: origin })
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'resume test')

    await expect(pipeline.resumeMilestone(milestone.id, approval.id)).rejects.toThrow(
      /repository has moved|baseline no longer matches/i,
    )
    expect(repo.listApprovals().find((a) => a.id === approval.id)?.consumedAt).toBeNull()
    expect(repo.getMilestoneRunState(milestone.id)).not.toBeNull()
    expect(repo.getMilestone(milestone.id)?.status).toBe('failed')
  })

  it('refuses a milestone with no preserved state, pointing at retry', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-resume-none-')
    const plan = makeFailedPlan(repo, session.id, origin)
    const milestone = makeFailedMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'resume test')

    await expect(pipeline.resumeMilestone(milestone.id, approval.id)).rejects.toThrow(
      /no preserved run state.*retry/i,
    )
    expect(repo.listApprovals().find((a) => a.id === approval.id)?.consumedAt).toBeNull()
  })
})
