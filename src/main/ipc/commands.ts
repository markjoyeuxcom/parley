import { writeFile } from 'node:fs/promises'
import { realpathSync } from 'node:fs'
// Type-only, so this module never loads Electron at runtime — which is the
// point of its existence: the command table, its validation and its routing
// can be exercised by tests, and vitest cannot load Electron. Everything that
// genuinely needs the runtime (ipcMain, the native dialogs) lives in
// register.ts and reaches the handlers through the context.
import type { BrowserWindow } from 'electron'
import { z } from 'zod'
import { COMMANDS, type CliHealth, type CommandName, type PaneIdentity } from '@shared/ipc'
import type { AppEvent } from '@shared/events'
import {
  MAX_PANES,
  type AgentConfig,
  type ApprovalScope,
  type EnvelopeCaps,
  type GridLayout,
  type Skill,
} from '@shared/domain'
import { RequestError, type Manager } from '@main/orchestrator/manager'
import { newId } from '@main/store/repo'
import { readCodexDefaultModel } from '@main/util/environment'
import { gitIdentity } from '@main/util/gitIdentity'
import { TEMPLATES } from '@main/orchestrator/templates'
import type { PtyManager } from '@main/pty/manager'
import { suggestPreviewCommand, type PreviewManager } from '@main/preview/manager'
import { disposeLedgerFinding, getSessionDetail, listSessionLedger } from './ledger'

/** The two native dialogs the command table uses, injected by register.ts. */
export interface IpcDialogs {
  showOpenDialog(
    window: BrowserWindow,
    options: { title: string; properties: Array<'openDirectory' | 'createDirectory'> },
  ): Promise<{ canceled: boolean; filePaths: string[] }>
  showSaveDialog(
    window: BrowserWindow,
    options: {
      title: string
      defaultPath: string
      filters: Array<{ name: string; extensions: string[] }>
    },
  ): Promise<{ canceled: boolean; filePath?: string }>
}

/**
 * The one app-lifecycle control a handler may reach, injected by register.ts
 * exactly as the dialogs are — commands.ts never loads Electron. The
 * implementation must go through app.quit (never app.exit): before-quit is
 * what disposes agent CLIs and ptys, and skipping it orphans paid runs.
 */
export interface IpcAppControl {
  relaunch(): void
}

export interface IpcContext {
  manager: Manager
  pty: PtyManager
  preview: PreviewManager
  /** Injected like the dialogs — commands.ts never loads Electron. */
  openExternal: (url: string) => void
  window: () => BrowserWindow | null
  health: () => CliHealth[]
  agyModels: () => Promise<string[]>
  dialogs: IpcDialogs
  appControl: IpcAppControl
}

type Handler = (payload: unknown, ctx: IpcContext) => unknown | Promise<unknown>

// Through the Manager's instrumented chain — never straight to the window.
// A handler-originated mutation is a durable transition like any other: the
// holds engine and the liveness watchdog must observe it, or the attention
// queue goes stale the moment triage happens through the UI.
function emit(ctx: IpcContext, event: AppEvent): void {
  ctx.manager.emit(event)
}

/**
 * Command handlers.
 *
 * Every entry is reached only after its schema in {@link COMMANDS} has parsed
 * the payload, so handlers receive validated input. An unknown command name is
 * rejected before it gets here.
 */
const HANDLERS: Record<CommandName, Handler> = {
  'app.info': async (_p, ctx) => ({
    mock: ctx.manager.registry.mock,
    codexDefaultModel: readCodexDefaultModel(),
    agyModels: await ctx.agyModels(),
    selfRepoPath: ctx.manager.selfRepoPath,
  }),
  'health.probe': (_p, ctx) => ctx.health(),

  // ── Sessions ───────────────────────────────────────────────────────────────
  'session.start': (p, ctx) => ctx.manager.startSession(p as never),
  'session.list': (p, ctx) => {
    const { includeArchived } = p as { includeArchived: boolean }
    return {
      sessions: ctx.manager.repo.listSessions(200, includeArchived),
      archivedCount: ctx.manager.repo.countArchivedSessions(),
    }
  },
  // Refuses while the session is live: archiving something mid-run would hide a
  // session that is still writing to the list it just vanished from.
  'session.archive': (p, ctx) => {
    const { sessionId, archived } = p as { sessionId: string; archived: boolean }
    const session = ctx.manager.repo.getSession(sessionId)
    if (!session) throw new RequestError('no such session')
    if (archived && (session.status === 'running' || session.status === 'paused')) {
      throw new RequestError('stop the session before archiving it')
    }
    const updated = ctx.manager.repo.setSessionArchived(sessionId, archived)
    // Archiving reaches the database without any event, and it hides (or
    // reveals) every hold the session was contributing.
    ctx.manager.holdsChanged()
    return updated
  },

  'session.deletionImpact': (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    if (!ctx.manager.repo.getSession(sessionId)) throw new RequestError('no such session')
    return ctx.manager.repo.describeSessionDeletion(sessionId)
  },

  /**
   * Deletion is permanent, so it is gated twice: the session must be stopped,
   * and it must already be archived. Archiving first is not bureaucracy — it
   * means nothing is ever destroyed by a single click on a list you were
   * scrolling past.
   */
  'session.delete': (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    const session = ctx.manager.repo.getSession(sessionId)
    if (!session) throw new RequestError('no such session')
    if (session.status === 'running' || session.status === 'paused') {
      throw new RequestError('stop the session before deleting it')
    }
    if (session.archivedAt === null) {
      throw new RequestError('archive the session before deleting it')
    }
    ctx.manager.repo.deleteSession(sessionId)
    return { deleted: true }
  },
  'session.get': (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    return getSessionDetail(ctx.manager.repo, sessionId)
  },
  'session.interject': (p, ctx) => {
    const { sessionId, target, text } = p as { sessionId: string; target: 'all' | number; text: string }
    ctx.manager.interject(sessionId, target, text)
    return { ok: true }
  },
  'session.pause': (p, ctx) => {
    ctx.manager.pauseSession((p as { sessionId: string }).sessionId)
    return { ok: true }
  },
  'session.resume': (p, ctx) => {
    ctx.manager.resumeSession((p as { sessionId: string }).sessionId)
    return { ok: true }
  },
  'session.stop': (p, ctx) => {
    ctx.manager.stopSession((p as { sessionId: string }).sessionId)
    return { ok: true }
  },
  'session.export': async (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    const verdict = ctx.manager.repo.getVerdict(sessionId)
    if (!verdict) throw new Error('that session has no report yet')
    const session = ctx.manager.repo.getSession(sessionId)
    const window = ctx.window()
    if (!window) throw new Error('no window')

    const suggested = `${session?.kind === 'review' ? 'REVIEW' : 'VERDICT'}-${sessionId.slice(0, 8)}.md`
    const result = await ctx.dialogs.showSaveDialog(window, {
      title: 'Export report',
      defaultPath: suggested,
      filters: [{ name: 'Markdown', extensions: ['md'] }],
    })
    if (result.canceled || !result.filePath) return { saved: false, path: null }
    await writeFile(result.filePath, verdict.report, 'utf8')
    return { saved: true, path: result.filePath }
  },

  'session.stow': (p, ctx) => ctx.manager.stowSession((p as { sessionId: string }).sessionId),

  // ── Finding ledger ────────────────────────────────────────────────────────
  'ledger.list': (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    return listSessionLedger(ctx.manager.repo, sessionId)
  },
  'ledger.dispose': (p, ctx) =>
    disposeLedgerFinding(ctx.manager.repo, p as never, (event) => emit(ctx, event)),

  // ── Decision holds ────────────────────────────────────────────────────────
  'holds.list': (_p, ctx) => ctx.manager.listHolds(),
  'inflight.list': (_p, ctx) => ctx.manager.listInFlight(),

  // ── New projects ───────────────────────────────────────────────────────────
  'workspace.templates': () => TEMPLATES.map(({ id, name, description }) => ({ id, name, description })),
  'workspace.list': (_p, ctx) => ctx.manager.repo.listWorkspaces(),
  'workspace.create': (p, ctx) =>
    ctx.manager.createWorkspace(
      p as { name: string; path: string; templateId: string; approvalId: string },
    ),
  /**
   * Answers "could a project be created here?" without granting anything, so
   * the dialog can show the refusal while the user is still typing rather
   * than after they have committed to it.
   */
  'preview.list': (_p, ctx) => ctx.preview.list(),
  'preview.suggest': (p) => ({
    command: suggestPreviewCommand((p as { repoPath: string }).repoPath),
  }),
  'preview.start': (p, ctx) => {
    const { repoPath, command } = p as { repoPath: string; command: string }
    return ctx.preview.start(repoPath, command)
  },
  'preview.stop': (p, ctx) => {
    ctx.preview.stop((p as { previewId: string }).previewId)
    return { ok: true }
  },
  'preview.forget': (p, ctx) => {
    ctx.preview.forget((p as { previewId: string }).previewId)
    return { ok: true }
  },
  'preview.logs': (p, ctx) => ({
    text: ctx.preview.logs((p as { previewId: string }).previewId),
  }),
  /**
   * The preview opens in the user's own browser, never inside Parley. The
   * renderer has no navigation and no remote origins by design, and a dev
   * server is exactly the kind of content that must not get an exception.
   */
  'preview.open': (p, ctx) => {
    const preview = ctx.preview.get((p as { previewId: string }).previewId)
    if (!preview?.url) throw new RequestError('that preview has no address yet')
    ctx.openExternal(preview.url)
    return { ok: true }
  },

  'acceptance.record': (p, ctx) =>
    ctx.manager.recordAcceptance(
      p as {
        milestoneId: string
        state: 'accepted' | 'changes-requested'
        note: string
        changes: string[]
      },
    ),
  'journey.list': (_p, ctx) => ctx.manager.listJourneyViews(),
  'journey.create': (p, ctx) => {
    const { name, brief } = p as { name: string; brief: string }
    return ctx.manager.repo.createJourney({
      id: newId(),
      name,
      brief,
      sessionId: null,
      workspaceId: null,
      planId: null,
      hardenSessionId: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      mock: ctx.manager.registry.mock,
    })
  },
  'journey.update': (p, ctx) => {
    const { journeyId, ...patch } = p as { journeyId: string } & Record<string, unknown>
    return ctx.manager.repo.updateJourney(journeyId, patch)
  },
  'journey.delete': (p, ctx) => {
    ctx.manager.repo.deleteJourney((p as { journeyId: string }).journeyId)
    return { ok: true }
  },

  'acceptance.list': (p, ctx) =>
    ctx.manager.repo.listAcceptancesForPlan((p as { planId: string }).planId),

  'workspace.preview': (p, ctx) => {
    try {
      const path = ctx.manager.previewWorkspacePath((p as { path: string }).path)
      return { ok: true as const, path, refusal: '' }
    } catch (err) {
      return {
        ok: false as const,
        path: '',
        refusal: err instanceof Error ? err.message : String(err),
      }
    }
  },
  'holds.ack': (p, ctx) => ctx.manager.ackHold((p as { holdId: string }).holdId),

  // ── Backlog ───────────────────────────────────────────────────────────────
  'backlog.list': (p, ctx) => {
    const { repoPath, includeArchived } = p as {
      repoPath?: string
      includeArchived: boolean
    }
    const items = ctx.manager.repo.listBacklogItems(repoPath ? { repoPath } : {})
    if (repoPath || includeArchived) return items
    const hidden = new Set(ctx.manager.repo.archivedRepoPaths())
    return items.filter((item) => !hidden.has(item.repoPath))
  },
  'backlog.drop': (p, ctx) => {
    const { itemId, note } = p as { itemId: string; note: string }
    const item = ctx.manager.repo.transitionBacklogItem(itemId, 'dropped', {
      source: 'human',
      note,
    })
    emit(ctx, { type: 'backlog.changed', repoPath: item.repoPath })
    return item
  },
  'backlog.reopen': (p, ctx) => {
    const { itemId } = p as { itemId: string }
    const item = ctx.manager.repo.transitionBacklogItem(itemId, 'open', { source: 'human' })
    emit(ctx, { type: 'backlog.changed', repoPath: item.repoPath })
    return item
  },
  'backlog.setBlockedBy': (p, ctx) => {
    const { itemId, blockedBy } = p as { itemId: string; blockedBy: string[] }
    const item = ctx.manager.repo.setBacklogBlockedBy(itemId, blockedBy)
    emit(ctx, { type: 'backlog.changed', repoPath: item.repoPath })
    return item
  },
  'backlog.confirm': (p, ctx) => {
    const { itemId } = p as { itemId: string }
    const item = ctx.manager.repo.transitionBacklogItem(itemId, 'open', { source: 'human' })
    emit(ctx, { type: 'backlog.changed', repoPath: item.repoPath })
    return item
  },
  'backlog.close': (p, ctx) => {
    const { itemId, note } = p as { itemId: string; note: string }
    const item = ctx.manager.repo.transitionBacklogItem(itemId, 'done', { source: 'human', note })
    emit(ctx, { type: 'backlog.changed', repoPath: item.repoPath })
    return item
  },
  'learnings.list': (p, ctx) => {
    const { repoPath, includeArchived } = p as {
      repoPath?: string
      includeArchived: boolean
    }
    const learnings = ctx.manager.repo.listLearnings(repoPath ? { repoPath } : {})
    if (repoPath || includeArchived) return learnings
    const hidden = new Set(ctx.manager.repo.archivedRepoPaths())
    return learnings.filter((learning) => !hidden.has(learning.repoPath))
  },
  'learnings.confirm': (p, ctx) => {
    const { learningId } = p as { learningId: string }
    const learning = ctx.manager.repo.transitionLearning(learningId, 'confirmed')
    emit(ctx, { type: 'backlog.changed', repoPath: learning.repoPath })
    return learning
  },
  'learnings.retire': (p, ctx) => {
    const { learningId } = p as { learningId: string }
    const learning = ctx.manager.repo.transitionLearning(learningId, 'retired')
    emit(ctx, { type: 'backlog.changed', repoPath: learning.repoPath })
    return learning
  },
  'foreman.run': (p, ctx) => {
    const { repoPath, cfg } = p as { repoPath: string; cfg: AgentConfig }
    return ctx.manager.runForeman(repoPath, cfg)
  },
  'foreman.list': (p, ctx) =>
    ctx.manager.repo.listForemanProposals(p as { repoPath?: string }),
  'foreman.reject': (p, ctx) => {
    const { proposalId, note } = p as { proposalId: string; note: string }
    const proposal = ctx.manager.repo.decideForemanProposal(proposalId, 'rejected', { note })
    // The hold must clear in the same breath as the decision.
    emit(ctx, { type: 'backlog.changed', repoPath: proposal.repoPath })
    return proposal
  },

  // ── Self-update (dev mode) ─────────────────────────────────────────────────
  // The hold's identity hashes the row id away, so the renderer re-resolves
  // the one live offer at action time — always the current truth, never a
  // stale chip's memory of it.
  'selfupdate.pending': (_p, ctx) => ctx.manager.repo.getPendingSelfUpdate(),
  // Decide THEN relaunch: the decision must be durable before the process
  // goes down, or a crash mid-restart would resurrect the offer for a build
  // the user already chose.
  'selfupdate.relaunch': (p, ctx) => {
    const { updateId } = p as { updateId: string }
    const row = ctx.manager.repo.getSelfUpdate(updateId)
    if (!row) throw new Error('no such self-update')
    if (row.state !== 'green') {
      throw new Error(
        row.state === 'superseded'
          ? 'that build offer was superseded by a newer landing — a fresh gate decides again'
          : `that build offer is ${row.state}, not awaiting a decision`,
      )
    }
    const busy = ctx.manager.busyWithRuns()
    if (busy) {
      throw new Error(`relaunch refused while ${busy} — it would be killed mid-flight`)
    }
    const decided = ctx.manager.repo.decideSelfUpdate(updateId, 'relaunched')
    ctx.manager.holdsChanged()
    ctx.appControl.relaunch()
    return decided
  },
  'selfupdate.decline': (p, ctx) => {
    const { updateId } = p as { updateId: string }
    const decided = ctx.manager.repo.decideSelfUpdate(updateId, 'declined')
    // The hold must clear in the same breath as the decision.
    ctx.manager.holdsChanged()
    return decided
  },

  // ── Plans ──────────────────────────────────────────────────────────────────
  'plan.create': (p, ctx) => ctx.manager.createPlan(p as never),
  'plan.cancel': (p, ctx) => {
    const { planId } = p as { planId: string }
    return ctx.manager.closeOutPlan(planId)
  },
  'plan.list': (p, ctx) => {
    const { repoPath } = p as { repoPath: string | null }
    return repoPath
      ? ctx.manager.repo.listPlansForRepo(repoPath)
      : ctx.manager.repo.listPlans()
  },
  'repos.list': (p, ctx) => {
    const { includeArchived } = p as { includeArchived: boolean }
    const hidden = new Set(ctx.manager.repo.archivedRepoPaths())
    const repos = ctx.manager.repo
      .listRepoSummaries(ctx.manager.registry.mock)
      .filter((summary) => includeArchived || !summary.archived)
    return { repos, archivedCount: hidden.size }
  },
  'repos.archive': (p, ctx) => {
    const { repoPath, archived } = p as { repoPath: string; archived: boolean }
    ctx.manager.setRepoArchived(repoPath, archived)
    return { ok: true }
  },
  'repo.containerStatus': (p, ctx) =>
    ctx.manager.repoContainerStatus((p as { repoPath: string }).repoPath),
  'plan.milestoneRuns': (p, ctx) =>
    ctx.manager.listMilestoneRuns((p as { milestoneId: string }).milestoneId),
  'remote.list': (_p, ctx) => ctx.manager.listRemoteTargets(),
  'remote.add': (p, ctx) =>
    ctx.manager.addRemoteTarget(p as { label: string; host: string; nodeCommand?: string }),
  'remote.forget': (p, ctx) => {
    ctx.manager.forgetRemoteTarget((p as { targetId: string }).targetId)
    return { ok: true }
  },
  'remote.status': (p, ctx) => ctx.manager.remoteStatus((p as { targetId: string }).targetId),
  'remote.recover': (p, ctx) => ctx.manager.recoverRemoteRun((p as { runId: string }).runId),
  'remote.install': (p, ctx) => ctx.manager.installRemote((p as { targetId: string }).targetId),
  'remote.rollback': (p, ctx) => ctx.manager.rollbackRemote((p as { targetId: string }).targetId),
  'plan.runMilestoneRemotely': (p, ctx) => {
    const { milestoneId, approvalId, targetId } = p as {
      milestoneId: string
      approvalId: string
      targetId: string
    }
    return ctx.manager.runMilestoneRemotely(milestoneId, approvalId, targetId)
  },
  'repo.setContainer': (p, ctx) => {
    const { repoPath, enabled } = p as { repoPath: string; enabled: boolean }
    return ctx.manager.setRepoContainer(repoPath, enabled)
  },
  'plan.get': (p, ctx) => {
    const { planId } = p as { planId: string }
    const plan = ctx.manager.repo.getPlan(planId)
    if (!plan) throw new Error('no such plan')
    return {
      plan,
      milestones: ctx.manager.repo.listMilestones(planId),
      worktree: ctx.manager.repo.getWorktreeForPlan(planId),
    }
  },
  'plan.land': (p, ctx) => {
    const { planId, approvalId } = p as { planId: string; approvalId: string }
    return ctx.manager.landPlan(planId, approvalId)
  },
  'plan.setTestCommand': (p, ctx) => {
    const { milestoneId, command } = p as { milestoneId: string; command: string }
    return ctx.manager.setMilestoneTestCommand(milestoneId, command)
  },
  'plan.answer': (p, ctx) => {
    const { planId, answer } = p as { planId: string; answer: string }
    return ctx.manager.answerPlan(planId, answer)
  },
  'plan.inspect': (p, ctx) => ctx.manager.inspectMilestone((p as { milestoneId: string }).milestoneId),
  'plan.adoptMilestone': (p, ctx) =>
    ctx.manager.adoptMilestone((p as { milestoneId: string }).milestoneId),
  'plan.stopMilestone': (p, ctx) => {
    ctx.manager.stopMilestone((p as { milestoneId: string }).milestoneId)
    return { ok: true }
  },
  'plan.resumeMilestone': (p, ctx) => {
    const { milestoneId, approvalId } = p as { milestoneId: string; approvalId: string }
    return ctx.manager.resumeMilestone(milestoneId, approvalId)
  },
  'plan.runMilestone': (p, ctx) => {
    const { milestoneId, approvalId } = p as { milestoneId: string; approvalId: string }
    return ctx.manager.runMilestone(milestoneId, approvalId)
  },

  // ── Approvals ──────────────────────────────────────────────────────────────
  'approval.grant': (p, ctx) => {
    const { scope, subjectId, summary } = p as {
      scope: ApprovalScope
      subjectId: string
      summary: string
    }
    // Exhaustive on purpose: a scope added without a routing decision must
    // fail typecheck here, not silently fall into an ungated branch — which
    // is exactly what the previous binary ternary would have done.
    switch (scope) {
      case 'milestone.execute':
        return ctx.manager.grantMilestoneApproval(subjectId, summary)
      case 'plan.land':
        return ctx.manager.grantLandApproval(subjectId, summary)
      case 'plan.envelope':
        return ctx.manager.grantEnvelopeApproval(subjectId, summary)
      case 'loop.write':
        return ctx.manager.repo.grantApproval(scope, subjectId, summary)
    }
  },
  'approval.list': (_p, ctx) => ctx.manager.repo.listApprovals(),

  // ── Unattended runs ────────────────────────────────────────────────────────
  'envelope.start': (p, ctx) => {
    const { planId, approvalId, caps } = p as {
      planId: string
      approvalId: string
      caps: EnvelopeCaps
    }
    return ctx.manager.startEnvelope(planId, approvalId, caps)
  },
  'envelope.stop': (p, ctx) => {
    ctx.manager.stopEnvelope((p as { planId: string }).planId)
    return { ok: true }
  },
  'envelope.list': (p, ctx) =>
    ctx.manager.repo.listEnvelopesForPlan((p as { planId: string }).planId),

  // ── Loops ──────────────────────────────────────────────────────────────────
  'loop.create': (p, ctx) => ctx.manager.createLoop(p as never),
  'loop.start': (p, ctx) => {
    const { loopId, approvalId } = p as { loopId: string; approvalId: string | null }
    return ctx.manager.startLoop(loopId, approvalId)
  },
  'loop.list': (_p, ctx) => ctx.manager.repo.listLoops(),
  'loop.get': (p, ctx) => {
    const { loopId } = p as { loopId: string }
    const loop = ctx.manager.repo.getLoop(loopId)
    if (!loop) throw new Error('no such loop')
    return { loop, iterations: ctx.manager.repo.listIterations(loopId) }
  },
  'loop.pause': (p, ctx) => {
    ctx.manager.pauseLoop((p as { loopId: string }).loopId)
    return { ok: true }
  },
  'loop.resume': (p, ctx) => {
    ctx.manager.resumeLoop((p as { loopId: string }).loopId)
    return { ok: true }
  },
  'loop.kill': (p, ctx) => {
    ctx.manager.killLoop((p as { loopId: string }).loopId)
    return { ok: true }
  },

  // ── Grid ───────────────────────────────────────────────────────────────────
  'pane.open': (p, ctx) => {
    const { kind, cwd, cols, rows, resume } = p as {
      kind: 'shell' | 'claude' | 'codex'
      cwd: string
      cols: number
      rows: number
      resume: boolean
    }
    if (ctx.pty.count >= MAX_PANES) throw new Error(`the grid holds at most ${MAX_PANES} panes`)
    return ctx.pty.open(kind, cwd, cols, rows, resume)
  },
  'pane.write': (p, ctx) => {
    const { paneId, data } = p as { paneId: string; data: string }
    ctx.pty.write(paneId, data)
    return { ok: true }
  },
  'pane.resize': (p, ctx) => {
    const { paneId, cols, rows } = p as { paneId: string; cols: number; rows: number }
    ctx.pty.resize(paneId, cols, rows)
    return { ok: true }
  },
  'pane.close': (p, ctx) => {
    ctx.pty.close((p as { paneId: string }).paneId)
    return { ok: true }
  },
  'pane.stop': (p, ctx) => {
    ctx.pty.stop((p as { paneId: string }).paneId)
    return { ok: true }
  },
  'pane.identity': async (p, ctx) => {
    const { cwd } = p as { cwd: string }
    const git = await gitIdentity(cwd)
    let worktree: PaneIdentity['worktree'] = null
    if (git) {
      // Worktree paths are stored raw; the registry match must be realpath
      // to realpath or a symlinked spelling would hide the plan chip.
      const match = ctx.manager.repo.listWorktrees().find((w) => {
        try {
          return realpathSync(w.path) === git.root
        } catch {
          return false
        }
      })
      if (match) {
        worktree = {
          planId: match.planId,
          originPath: match.originPath,
          branch: match.branch,
          landed: match.landedAt !== null,
          orphaned: match.orphaned,
        }
      }
    }
    return { git, worktree } satisfies PaneIdentity
  },
  'pane.saveTranscript': async (p, ctx) => {
    const { suggestedName, text } = p as { suggestedName: string; text: string }
    const window = ctx.window()
    if (!window) throw new Error('no window')
    const result = await ctx.dialogs.showSaveDialog(window, {
      title: 'Save transcript',
      defaultPath: suggestedName,
      filters: [{ name: 'Text', extensions: ['txt'] }],
    })
    if (result.canceled || !result.filePath) return { saved: false, path: null }
    await writeFile(result.filePath, text, 'utf8')
    return { saved: true, path: result.filePath }
  },
  'pane.list': (_p, ctx) => ctx.pty.list(),

  // ── Saved layouts ──────────────────────────────────────────────────────────
  'layout.save': (p, ctx) => {
    const input = p as { name: string; defaultFolder: string; tree: GridLayout['tree'] }
    return ctx.manager.repo.saveLayout({ id: newId(), ...input })
  },
  'layout.list': (_p, ctx) => ctx.manager.repo.listLayouts(),
  'layout.delete': (p, ctx) => {
    ctx.manager.repo.deleteLayout((p as { layoutId: string }).layoutId)
    return { ok: true }
  },

  // ── Skills ─────────────────────────────────────────────────────────────────
  'skill.list': (_p, ctx) => ctx.manager.repo.listSkills(),
  'skill.save': (p, ctx) => {
    const input = p as Omit<Skill, 'builtIn'>
    const existing = input.id ? ctx.manager.repo.getSkill(input.id) : null
    return ctx.manager.repo.upsertSkill({
      ...input,
      id: existing?.id ?? input.id ?? newId(),
      // A built-in cannot be demoted to a user skill by editing it.
      builtIn: existing?.builtIn ?? false,
    })
  },
  'skill.run': (p, ctx) => {
    const { paneId, skillId } = p as { paneId: string; skillId: string }
    const skill = ctx.manager.repo.getSkill(skillId)
    if (!skill) throw new Error('no such skill')
    ctx.pty.submit(paneId, skill.prompt)
    return { ok: true }
  },

  // ── Dialogs ────────────────────────────────────────────────────────────────
  'dialog.pickDirectory': async (p, ctx) => {
    const { title } = p as { title: string }
    const window = ctx.window()
    if (!window) throw new Error('no window')
    const result = await ctx.dialogs.showOpenDialog(window, {
      title,
      properties: ['openDirectory', 'createDirectory'],
    })
    return { path: result.canceled ? null : (result.filePaths[0] ?? null) }
  },
}

/**
 * Validates and dispatches one renderer request.
 *
 * The single audited chokepoint, minus the Electron wiring: an unknown command
 * or a payload its schema refuses is rejected before any handler runs, and a
 * refusal is a thrown Error — register.ts flattens it into the InvokeResult
 * envelope. Separated from ipcMain so the routing itself is testable; before
 * this split, the approval.grant dispatch (Manager-gated for milestones,
 * direct for loops) had no test because nothing could load this table.
 */
export async function invokeCommand(ctx: IpcContext, raw: unknown): Promise<unknown> {
  if (!raw || typeof raw !== 'object') throw new Error('malformed request')
  const { command, payload } = raw as { command?: unknown; payload?: unknown }

  if (typeof command !== 'string' || !(command in COMMANDS)) {
    throw new Error(`unknown command: ${String(command)}`)
  }
  const name = command as CommandName
  const schema = COMMANDS[name] as z.ZodType | null

  let parsed: unknown
  if (schema) {
    const outcome = schema.safeParse(payload)
    if (!outcome.success) {
      const first = outcome.error.issues[0]
      const where = first?.path.length ? ` at ${first.path.join('.')}` : ''
      throw new Error(`invalid ${name} request${where}: ${first?.message ?? 'validation failed'}`)
    }
    parsed = outcome.data
  }

  return HANDLERS[name](parsed, ctx)
}
