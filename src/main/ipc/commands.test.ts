import { describe, expect, it } from 'vitest'
import { emptyUsage, type Approval, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Manager } from '@main/orchestrator/manager'
import type { PtyManager } from '@main/pty/manager'
import { invokeCommand, type IpcContext } from './commands'

/**
 * Routing tests for the validated command table.
 *
 * These exist because the approval.grant dispatch went untested through three
 * milestone series: a milestone.execute grant must pass through the Manager —
 * where the finding gate lives — while a loop.write grant is a direct store
 * write. Nothing could load the table while it shared a module with ipcMain.
 */
function harness(): { ctx: IpcContext; repo: Repo; session: Session } {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const manager = new Manager({ repo, registry, emit: () => {} })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should the retry path change?',
    project: '',
    repoPath: null,
    participants: [
      { vendor: 'claude', model: '', effort: 'medium', persona: '' },
      { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    ],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)

  const ctx: IpcContext = {
    manager,
    // These tests never open a pane or a dialog; a call reaching either stub is
    // itself a routing bug worth failing on.
    pty: new Proxy({}, { get: () => () => { throw new Error('pty must not be touched') } }) as PtyManager,
    window: () => null,
    health: () => [],
    dialogs: {
      showOpenDialog: () => Promise.reject(new Error('dialogs must not be touched')),
      showSaveDialog: () => Promise.reject(new Error('dialogs must not be touched')),
    },
  }
  return { ctx, repo, session }
}

function makeMilestone(repo: Repo, sessionId: string): { plan: WorkPlan; milestone: Milestone } {
  const plan = repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Retry plan',
    repoPath: '/tmp',
    planner: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
    executor: { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    reviewer: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
  const milestone = repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Fix retry exhaustion',
    intent: 'Surface exhaustion.',
    expectedPaths: [],
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
  return { plan, milestone }
}

describe('invokeCommand routing', () => {
  it('routes a milestone.execute grant through the Manager, where the finding gate lives', async () => {
    const { ctx, repo, session } = harness()
    const { milestone } = makeMilestone(repo, session.id)
    const finding = repo.upsertLedgerFinding(session.id, 'An unresolved blocker.')
    const open = repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: milestone.planId,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })

    // A raw store grant would succeed here. The route must not: the gate is
    // the Manager's, and this is the proof the dispatch goes through it.
    await expect(
      invokeCommand(ctx, {
        command: 'approval.grant',
        payload: { scope: 'milestone.execute', subjectId: milestone.id, summary: 'allow the write' },
      }),
    ).rejects.toThrow(/blocking finding occurrence.*unresolved/i)
    expect(repo.listApprovals()).toHaveLength(0)

    repo.disposeFinding({
      findingId: finding.id,
      occurrenceId: open.id,
      state: 'accepted-risk',
      note: 'Accepted for this test.',
      source: 'human',
    })
    const approval = (await invokeCommand(ctx, {
      command: 'approval.grant',
      payload: { scope: 'milestone.execute', subjectId: milestone.id, summary: 'allow the write' },
    })) as Approval
    expect(approval).toMatchObject({
      scope: 'milestone.execute',
      subjectId: milestone.id,
      consumedAt: null,
    })
  })

  it('grants a loop.write approval directly — loops gate at start, not at grant', async () => {
    const { ctx, repo, session } = harness()
    // An open blocker in the session must not block a loop grant: the loop
    // path's own guards are capability plus consume-on-start.
    const finding = repo.upsertLedgerFinding(session.id, 'An unresolved blocker.')
    repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: newId(),
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })

    const approval = (await invokeCommand(ctx, {
      command: 'approval.grant',
      payload: { scope: 'loop.write', subjectId: 'loop-1', summary: 'allow the loop' },
    })) as Approval
    expect(approval).toMatchObject({ scope: 'loop.write', subjectId: 'loop-1', consumedAt: null })
  })

  it('rejects an unknown command before any handler runs', async () => {
    const { ctx } = harness()
    await expect(invokeCommand(ctx, { command: 'nope.nothing', payload: {} })).rejects.toThrow(
      /unknown command/i,
    )
    await expect(invokeCommand(ctx, 'not even an object')).rejects.toThrow(/malformed request/i)
  })

  it('rejects a payload its schema refuses, naming the offending field', async () => {
    const { ctx, repo } = harness()
    await expect(
      invokeCommand(ctx, {
        command: 'approval.grant',
        payload: { scope: 'milestone.execute', subjectId: 'm1', summary: '' },
      }),
    ).rejects.toThrow(/invalid approval\.grant request at summary/i)
    expect(repo.listApprovals()).toHaveLength(0)
  })
})
