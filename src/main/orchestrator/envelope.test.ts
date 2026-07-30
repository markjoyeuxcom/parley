import { describe, expect, it } from 'vitest'
import { emptyUsage, type Envelope, type Milestone, type WorkPlan } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import {
  driveEnvelope,
  envelopeCapBreach,
  mintedApprovalSummary,
  newEnvelope,
  nextExecutableMilestone,
} from './envelope'
import { RunGate } from './types'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }
const CAPS = { maxMilestones: 10, maxWallClockMs: 3_600_000, maxSpendUsd: 0 }

function seed(milestoneCount: number): {
  repo: Repo
  plan: WorkPlan
  envelope: Envelope
  events: AppEvent[]
} {
  const repo = new Repo(openDatabase(':memory:'))
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'unattended',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  const plan = repo.createPlan({
    id: newId(),
    sessionId: session.id,
    kind: 'implementation',
    title: 'Overnight work',
    repoPath: '/tmp/envelope-plan',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
  for (let index = 0; index < milestoneCount; index += 1) {
    repo.createMilestone({
      id: newId(),
      planId: plan.id,
      index,
      title: `Milestone ${index + 1}`,
      intent: 'do the thing',
      expectedPaths: [],
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
  const envelope = repo.createEnvelope(newEnvelope(plan.id, CAPS, 0), plan.repoPath)
  return { repo, plan, envelope, events: [] }
}

/** A fake milestone run: completes the milestone, and the plan with the last. */
function completingRun(repo: Repo, planId: string) {
  return async (milestoneId: string): Promise<Milestone> => {
    const done = repo.updateMilestone(milestoneId, { status: 'complete' })
    const all = repo.listMilestones(planId)
    if (all.every((m) => m.status === 'complete')) repo.setPlanStatus(planId, 'complete')
    return done
  }
}

describe('envelope caps', () => {
  it('names the bound that was reached, and nothing before it is', () => {
    const at = { milestonesRun: 0, elapsedMs: 0, spentUsd: 0 }
    expect(envelopeCapBreach(CAPS, at)).toBeNull()
    expect(envelopeCapBreach(CAPS, { ...at, milestonesRun: 10 })).toMatch(/milestone cap/)
    expect(envelopeCapBreach(CAPS, { ...at, elapsedMs: 3_600_000 })).toMatch(/time limit/)
  })

  it('treats a zero spend cap as disabled — subscription CLIs report no cost', () => {
    const at = { milestonesRun: 0, elapsedMs: 0, spentUsd: 9_999 }
    expect(envelopeCapBreach(CAPS, at)).toBeNull()
    expect(envelopeCapBreach({ ...CAPS, maxSpendUsd: 5 }, at)).toMatch(/spend limit/)
  })
})

describe('the unattended driver', () => {
  it('runs every milestone on one authorisation and finishes at merge-ready', async () => {
    const { repo, plan, envelope, events } = seed(3)
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: completingRun(repo, plan.id),
      },
      envelope.id,
      new RunGate(),
    )

    expect(settled?.state).toBe('finished')
    expect(settled?.detail).toMatch(/merge-ready/)
    expect(settled?.milestonesRun).toBe(3)

    // Three minted approvals, each single-use, each consumed by its own
    // milestone — the per-milestone record keeps exactly its old shape.
    const minted = repo.listApprovals().filter((a) => a.scope === 'milestone.execute')
    expect(minted).toHaveLength(3)
    expect(new Set(minted.map((a) => a.subjectId)).size).toBe(3)
    // Every one names the envelope it came from, in the durable summary.
    for (const approval of minted) {
      expect(approval.summary).toContain(envelope.id.slice(0, 8))
      expect(approval.summary).toContain('landing remains a separate decision')
    }
  })

  it('parks on a milestone that does not complete, leaving the rest unrun', async () => {
    const { repo, plan, envelope, events } = seed(3)
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: async (milestoneId) => repo.updateMilestone(milestoneId, { status: 'failed' }),
      },
      envelope.id,
      new RunGate(),
    )

    expect(settled?.state).toBe('parked')
    expect(settled?.detail).toMatch(/milestone 1 ended failed/)
    // One mint only: the run stopped rather than pressing on.
    expect(settled?.milestonesRun).toBe(1)
    expect(repo.listMilestones(plan.id).filter((m) => m.status === 'audited')).toHaveLength(2)
  })

  it('parks when a blocking finding is filed, before minting the next approval', async () => {
    const { repo, plan, envelope, events } = seed(3)
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: async (milestoneId) => {
          const done = repo.updateMilestone(milestoneId, { status: 'complete' })
          // The review of the milestone that just ran objects to something.
          const finding = repo.upsertLedgerFinding(plan.sessionId, 'the retry path is unbounded')
          repo.recordFindingOccurrence({
            findingId: finding.id,
            planId: plan.id,
            milestoneId,
            round: 1,
            kind: 'blocking',
            source: 'review',
          })
          return done
        },
      },
      envelope.id,
      new RunGate(),
    )

    expect(settled?.state).toBe('parked')
    expect(settled?.detail).toMatch(/blocking finding needs your disposition/)
    expect(settled?.milestonesRun).toBe(1)
  })

  it('exhausts at the milestone cap without touching the plan', async () => {
    const { repo, plan, envelope, events } = seed(4)
    repo.settleEnvelope(envelope.id, 'cancelled', 'replaced by a capped one')
    const capped = repo.createEnvelope(
      newEnvelope(plan.id, { ...CAPS, maxMilestones: 2 }, 0),
      plan.repoPath,
    )

    const settled = await driveEnvelope(
      { repo, emit: (event) => events.push(event), runMilestone: completingRun(repo, plan.id) },
      capped.id,
      new RunGate(),
    )

    expect(settled?.state).toBe('exhausted')
    expect(settled?.detail).toMatch(/milestone cap was reached \(2\)/)
    expect(settled?.detail).toMatch(/grant a fresh envelope/)
    expect(repo.listMilestones(plan.id).filter((m) => m.status === 'complete')).toHaveLength(2)
  })

  it('exhausts on the clock before dispatching, never mid-milestone', async () => {
    const { repo, plan, envelope, events } = seed(3)
    let clock = envelope.startedAt
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        now: () => clock,
        runMilestone: async (milestoneId) => {
          // Each milestone takes twenty minutes of wall clock.
          clock += 20 * 60_000
          const done = repo.updateMilestone(milestoneId, { status: 'complete' })
          const all = repo.listMilestones(plan.id)
          if (all.every((m) => m.status === 'complete')) repo.setPlanStatus(plan.id, 'complete')
          return done
        },
      },
      envelope.id,
      new RunGate(),
    )

    // A 60-minute budget dispatches at 0 and at 20 and at 40, then stops.
    expect(settled?.state).toBe('exhausted')
    expect(settled?.milestonesRun).toBe(3)
  })

  it('cancels on a stopped gate, and settles exactly once', async () => {
    const { repo, plan, envelope, events } = seed(3)
    const gate = new RunGate()
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: async (milestoneId) => {
          const done = repo.updateMilestone(milestoneId, { status: 'complete' })
          gate.stop() // the human hits Stop while milestone 1 runs
          return done
        },
      },
      envelope.id,
      gate,
    )

    expect(settled?.state).toBe('cancelled')
    expect(settled?.detail).toMatch(/stopped by you after 1 milestone/)
    // One ending only: a settled envelope cannot be re-ended.
    expect(repo.settleEnvelope(envelope.id, 'finished', 'late')).toBe(false)
    expect(events.filter((e) => e.type === 'envelope.changed')).toHaveLength(1)
  })

  it('reads a stopped milestone as your cancellation, never as a failure to answer', async () => {
    // Stopping an envelope stops the milestone in flight, which returns
    // non-complete. Filing that as a park would put the user's own Stop in
    // the queue as something needing their attention.
    const { repo, plan, envelope, events } = seed(3)
    const gate = new RunGate()
    const settled = await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: async (milestoneId) => {
          gate.stop()
          return repo.updateMilestone(milestoneId, { status: 'failed' })
        },
      },
      envelope.id,
      gate,
    )

    expect(settled?.state).toBe('cancelled')
    expect(settled?.detail).toMatch(/stopped by you during milestone 1/)
    expect(settled?.detail).toMatch(/resumes like any interrupted milestone/)
    expect(repo.listMilestones(plan.id)[1]?.status).toBe('audited')
  })

  it('refuses to drive an envelope that is not running', async () => {
    const { repo, plan, envelope, events } = seed(2)
    repo.settleEnvelope(envelope.id, 'parked', 'already dealt with')
    let ran = 0
    await driveEnvelope(
      {
        repo,
        emit: (event) => events.push(event),
        runMilestone: async (milestoneId) => {
          ran += 1
          return repo.updateMilestone(milestoneId, { status: 'complete' })
        },
      },
      envelope.id,
      new RunGate(),
    )
    expect(ran).toBe(0)
    expect(repo.listMilestones(plan.id).every((m) => m.status === 'audited')).toBe(true)
  })
})

describe('minted approval summaries', () => {
  it('names the envelope, the vendor, the worktree and the milestone', () => {
    const { plan, envelope, repo } = seed(1)
    const milestone = repo.listMilestones(plan.id)[0]
    if (!milestone) throw new Error('expected a milestone')
    const summary = mintedApprovalSummary(envelope, plan, milestone)
    expect(summary).toContain(envelope.id.slice(0, 8))
    expect(summary).toContain('codex')
    expect(summary).toContain('isolated worktree')
    expect(summary).toContain('milestone 1: Milestone 1')
  })

  it('finds only a milestone the plan/milestone status pair permits', () => {
    const { plan, repo } = seed(2)
    const milestones = repo.listMilestones(plan.id)
    expect(nextExecutableMilestone(plan, milestones)?.index).toBe(0)
    expect(nextExecutableMilestone({ ...plan, status: 'complete' }, milestones)).toBeNull()
    expect(
      nextExecutableMilestone(plan, milestones.map((m) => ({ ...m, status: 'complete' as const }))),
    ).toBeNull()
  })
})
