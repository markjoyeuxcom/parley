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
    appControl: {
      relaunch: () => {
        throw new Error('appControl must not be touched')
      },
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
    isolation: 'checkout' as const,
    setupCommand: '',
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

  it('rejects a session request outside the seat bounds, naming the field', async () => {
    // The ceiling lives at the surface, exactly where the m2 note said it
    // would arrive: the exchange is two-seat, extra chairs are assessors, and
    // a bench of more than two of them is spend without conversation.
    const { ctx } = harness()
    const seat = { vendor: 'claude', model: '', effort: 'medium', persona: '' }

    await expect(
      invokeCommand(ctx, {
        command: 'session.start',
        payload: { kind: 'debate', matter: 'x', participants: [seat], maxTurns: 2 },
      }),
    ).rejects.toThrow(/invalid session\.start request at participants/i)
    await expect(
      invokeCommand(ctx, {
        command: 'session.start',
        payload: { kind: 'debate', matter: 'x', participants: [seat, seat, seat, seat, seat], maxTurns: 2 },
      }),
    ).rejects.toThrow(/invalid session\.start request at participants/i)
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

describe('handler emits and the attention queue', () => {
  /**
   * Pins the seam the mock walkthrough exposed: IPC handlers mutate durable
   * state too, and their events must flow through the Manager's instrumented
   * emit. The original helper sent straight to the window — the renderer's
   * board refreshed while the holds engine never recomputed, so the badge
   * kept showing a backlog-review hold whose proposals were already triaged.
   */
  it('backlog triage over IPC recomputes the holds queue', async () => {
    const events: import('@shared/events').AppEvent[] = []
    const repo = new Repo(openDatabase(':memory:'))
    // A proposal already waiting when the app starts; the constructor's
    // initial recompute publishes its hold.
    const { item } = repo.fileBacklogItem({
      repoPath: '/tmp/queue-live',
      title: 'A stow proposal awaiting triage.',
      source: 'stow',
      mock: true,
      state: 'proposed',
    })
    const manager = new Manager({
      repo,
      registry: new AgentRegistry(true),
      emit: (event) => events.push(event),
    })
    const ctx: IpcContext = {
      manager,
      pty: new Proxy({}, { get: () => () => { throw new Error('pty must not be touched') } }) as PtyManager,
      window: () => null,
      health: () => [],
      dialogs: {
        showOpenDialog: () => Promise.reject(new Error('dialogs must not be touched')),
        showSaveDialog: () => Promise.reject(new Error('dialogs must not be touched')),
      },
      appControl: {
        relaunch: () => {
          throw new Error('appControl must not be touched')
        },
      },
    }
    const lastHolds = () => {
      const event = events.filter((e) => e.type === 'holds.changed').at(-1)
      return event && 'holds' in event ? event.holds : []
    }

    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(lastHolds().some((h) => h.kind === 'backlog-review')).toBe(true)

    // Triage the only proposal over IPC. The forwarded backlog.changed must
    // reach the holds engine, whose recompute publishes the cleared queue.
    await invokeCommand(ctx, {
      command: 'backlog.drop',
      payload: { itemId: item.id, note: 'Not worth tracking.' },
    })
    expect(events.some((e) => e.type === 'backlog.changed')).toBe(true)
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(lastHolds().some((h) => h.kind === 'backlog-review')).toBe(false)
  })
})

describe('foreman commands', () => {
  it('foreman.reject decides the proposal through the validated table', async () => {
    const { ctx, repo } = harness()
    const item = repo.fileBacklogItem({
      repoPath: '/tmp/ipc-foreman',
      title: 'An open item',
      source: 'manual',
      mock: true,
      state: 'open',
    }).item
    const attempt = repo.fileForemanAttempt({
      repoPath: '/tmp/ipc-foreman',
      vendor: 'claude',
      mock: true,
      openSnapshot: [item.id],
    })
    const proposal = repo.finalizeForemanAttempt(attempt.id, {
      state: 'proposed',
      title: 'Bound the retry path',
      rationale: 'x',
      itemIds: [item.id],
      deferred: [],
      isolation: 'worktree',
      note: '',
      anchorSessionId: newId(),
      usage: emptyUsage(),
    })

    const rejected = (await invokeCommand(ctx, {
      command: 'foreman.reject',
      payload: { proposalId: proposal.id, note: 'Not this batch.' },
    })) as { state: string; decisionNote: string }
    expect(rejected.state).toBe('rejected')
    expect(rejected.decisionNote).toMatch(/not this batch/i)
    expect(repo.getPendingForemanProposal('/tmp/ipc-foreman', true)).toBeNull()
  })
})

describe('plan.list arms', () => {
  it('empty payload lists globally; a repoPath lists that repo uncapped', async () => {
    const { ctx, repo, session } = harness()
    const repoPath = '/tmp/ipc-plan-arms'
    for (let i = 0; i < 205; i += 1) {
      repo.createPlan({
        id: newId(),
        sessionId: session.id,
        kind: 'implementation',
        title: `Plan ${i}`,
        repoPath,
        planner: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
        executor: { vendor: 'codex', model: '', effort: 'medium', persona: '' },
        reviewer: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
        status: 'ready',
        question: '',
        correctionNote: '',
        correctionDispositions: [],
        isolation: 'checkout',
        setupCommand: '',
        usage: emptyUsage(),
        mock: true,
        createdAt: Date.now() + i,
      })
    }

    // The no-payload caller must keep working after the schema change.
    const global = (await invokeCommand(ctx, { command: 'plan.list', payload: {} })) as unknown[]
    expect(global).toHaveLength(200)
    const scoped = (await invokeCommand(ctx, {
      command: 'plan.list',
      payload: { repoPath },
    })) as unknown[]
    expect(scoped).toHaveLength(205)

    const summaries = (await invokeCommand(ctx, { command: 'repos.list' })) as Array<{
      repoPath: string
      planCount: number
    }>
    expect(summaries.find((s) => s.repoPath === repoPath)?.planCount).toBe(205)
  })
})

describe('self-update commands', () => {
  it('decline records the decision and clears the offer', async () => {
    const { ctx, repo } = harness()
    const attempt = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(attempt.id, 'green', 'built')

    const decided = (await invokeCommand(ctx, {
      command: 'selfupdate.decline',
      payload: { updateId: attempt.id },
    })) as { state: string }
    expect(decided.state).toBe('declined')
    expect(repo.getPendingSelfUpdate()).toBeNull()
  })

  it('relaunch decides the row BEFORE the process control fires', async () => {
    const { ctx, repo } = harness()
    const attempt = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(attempt.id, 'green', 'built')

    // The fake records what the database said at the moment the app would
    // have gone down: a crash mid-restart must not resurrect the offer.
    const seenAtRelaunch: string[] = []
    ctx.appControl = {
      relaunch: () => {
        seenAtRelaunch.push(repo.getSelfUpdate(attempt.id)?.state ?? 'missing')
      },
    }
    await invokeCommand(ctx, {
      command: 'selfupdate.relaunch',
      payload: { updateId: attempt.id },
    })
    expect(seenAtRelaunch).toEqual(['relaunched'])
  })

  it('relaunch refuses anything not green-undecided', async () => {
    const { ctx, repo } = harness()
    const red = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(red.id, 'red', 'broke')
    await expect(
      invokeCommand(ctx, { command: 'selfupdate.relaunch', payload: { updateId: red.id } }),
    ).rejects.toThrow(/red/)

    const green = repo.fileSelfUpdateAttempt('plan-b')
    repo.finalizeSelfUpdate(green.id, 'green', 'built')
    const superseded = repo.fileSelfUpdateAttempt('plan-c')
    await expect(
      invokeCommand(ctx, { command: 'selfupdate.relaunch', payload: { updateId: green.id } }),
    ).rejects.toThrow(/superseded/)
    // The still-running new attempt is not decidable either.
    await expect(
      invokeCommand(ctx, { command: 'selfupdate.relaunch', payload: { updateId: superseded.id } }),
    ).rejects.toThrow(/running/)
    await expect(
      invokeCommand(ctx, { command: 'selfupdate.relaunch', payload: { updateId: newId() } }),
    ).rejects.toThrow(/no such/)
  })

  it('relaunch refuses while runs are in flight, and the offer survives', async () => {
    const { ctx, repo } = harness()
    const attempt = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(attempt.id, 'green', 'built')

    const original = ctx.manager.busyWithRuns.bind(ctx.manager)
    ctx.manager.busyWithRuns = () => 'a milestone is executing'
    try {
      await expect(
        invokeCommand(ctx, { command: 'selfupdate.relaunch', payload: { updateId: attempt.id } }),
      ).rejects.toThrow(/while a milestone is executing/)
    } finally {
      ctx.manager.busyWithRuns = original
    }
    // Refused means undecided: the offer must still be there to take later.
    expect(repo.getPendingSelfUpdate()?.id).toBe(attempt.id)
  })
})

describe('plan close-out', () => {
  it('cancels a failed plan, releases its planned items, and refuses the rest', async () => {
    const { ctx, repo, session } = harness()
    const { plan } = makeMilestone(repo, session.id)
    const { item } = repo.fileBacklogItem({
      repoPath: plan.repoPath,
      title: 'A finding the failed plan claimed',
      source: 'review-finding',
      mock: true,
    })
    repo.transitionBacklogItem(item.id, 'planned', { source: 'human', planId: plan.id })
    repo.setPlanStatus(plan.id, 'failed')

    const cancelled = (await invokeCommand(ctx, {
      command: 'plan.cancel',
      payload: { planId: plan.id },
    })) as WorkPlan
    expect(cancelled.status).toBe('cancelled')

    // The dead plan released its claim: the item is open again, unlinked.
    const released = repo.getBacklogItem(item.id)
    expect(released?.state).toBe('open')
    expect(released?.planId).toBeNull()

    // Close-out is terminal and narrow: cancelled, complete and ready all refuse.
    await expect(
      invokeCommand(ctx, { command: 'plan.cancel', payload: { planId: plan.id } }),
    ).rejects.toThrow(/cancelled plan cannot/)
    const { plan: fine } = makeMilestone(repo, session.id)
    repo.setPlanStatus(fine.id, 'complete')
    await expect(
      invokeCommand(ctx, { command: 'plan.cancel', payload: { planId: fine.id } }),
    ).rejects.toThrow(/complete plan cannot/)
    const { plan: ready } = makeMilestone(repo, session.id)
    await expect(
      invokeCommand(ctx, { command: 'plan.cancel', payload: { planId: ready.id } }),
    ).rejects.toThrow(/ready plan cannot/)

    // Blocked is the other stuck state, and it closes out too.
    const { plan: blocked } = makeMilestone(repo, session.id)
    repo.setPlanStatus(blocked.id, 'blocked')
    const closedBlocked = (await invokeCommand(ctx, {
      command: 'plan.cancel',
      payload: { planId: blocked.id },
    })) as WorkPlan
    expect(closedBlocked.status).toBe('cancelled')
  })
})
