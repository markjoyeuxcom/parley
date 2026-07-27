import { writeFile } from 'node:fs/promises'
import { BrowserWindow, dialog, ipcMain } from 'electron'
import { z } from 'zod'
import {
  COMMANDS,
  type CliHealth,
  type CommandName,
  type InvokeResult,
} from '@shared/ipc'
import { CH } from '@shared/ipc'
import type { AppEvent } from '@shared/events'
import { MAX_PANES, type GridLayout, type Skill } from '@shared/domain'
import { RequestError, type Manager } from '@main/orchestrator/manager'
import { newId } from '@main/store/repo'
import { readCodexDefaultModel } from '@main/util/environment'
import type { PtyManager } from '@main/pty/manager'
import { disposeLedgerFinding, getSessionDetail, listSessionLedger } from './ledger'

export interface IpcContext {
  manager: Manager
  pty: PtyManager
  window: () => BrowserWindow | null
  health: () => CliHealth[]
}

type Handler = (payload: unknown, ctx: IpcContext) => unknown | Promise<unknown>

function emit(ctx: IpcContext, event: AppEvent): void {
  ctx.window()?.webContents.send(CH.event, event)
}

/**
 * Command handlers.
 *
 * Every entry is reached only after its schema in {@link COMMANDS} has parsed
 * the payload, so handlers receive validated input. An unknown command name is
 * rejected before it gets here.
 */
const HANDLERS: Record<CommandName, Handler> = {
  'app.info': (_p, ctx) => ({
    mock: ctx.manager.registry.mock,
    codexDefaultModel: readCodexDefaultModel(),
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
    return ctx.manager.repo.setSessionArchived(sessionId, archived)
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
    const { sessionId, target, text } = p as { sessionId: string; target: 'both' | 'a' | 'b'; text: string }
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
    const result = await dialog.showSaveDialog(window, {
      title: 'Export report',
      defaultPath: suggested,
      filters: [{ name: 'Markdown', extensions: ['md'] }],
    })
    if (result.canceled || !result.filePath) return { saved: false, path: null }
    await writeFile(result.filePath, verdict.report, 'utf8')
    return { saved: true, path: result.filePath }
  },

  // ── Finding ledger ────────────────────────────────────────────────────────
  'ledger.list': (p, ctx) => {
    const { sessionId } = p as { sessionId: string }
    return listSessionLedger(ctx.manager.repo, sessionId)
  },
  'ledger.dispose': (p, ctx) =>
    disposeLedgerFinding(ctx.manager.repo, p as never, (event) => emit(ctx, event)),

  // ── Plans ──────────────────────────────────────────────────────────────────
  'plan.create': (p, ctx) => ctx.manager.createPlan(p as never),
  'plan.list': (_p, ctx) => ctx.manager.repo.listPlans(),
  'plan.get': (p, ctx) => {
    const { planId } = p as { planId: string }
    const plan = ctx.manager.repo.getPlan(planId)
    if (!plan) throw new Error('no such plan')
    return { plan, milestones: ctx.manager.repo.listMilestones(planId) }
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
  'plan.runMilestone': (p, ctx) => {
    const { milestoneId, approvalId } = p as { milestoneId: string; approvalId: string }
    return ctx.manager.runMilestone(milestoneId, approvalId)
  },

  // ── Approvals ──────────────────────────────────────────────────────────────
  'approval.grant': (p, ctx) => {
    const { scope, subjectId, summary } = p as {
      scope: 'milestone.execute' | 'loop.write'
      subjectId: string
      summary: string
    }
    return ctx.manager.repo.grantApproval(scope, subjectId, summary)
  },
  'approval.list': (_p, ctx) => ctx.manager.repo.listApprovals(),

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
    const { kind, cwd, cols, rows } = p as {
      kind: 'shell' | 'claude' | 'codex'
      cwd: string
      cols: number
      rows: number
    }
    if (ctx.pty.count >= MAX_PANES) throw new Error(`the grid holds at most ${MAX_PANES} panes`)
    return ctx.pty.open(kind, cwd, cols, rows)
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
    const result = await dialog.showOpenDialog(window, {
      title,
      properties: ['openDirectory', 'createDirectory'],
    })
    return { path: result.canceled ? null : (result.filePaths[0] ?? null) }
  },
}

/**
 * Wires the single invoke channel.
 *
 * One channel with a validated command table rather than one channel per
 * operation: the renderer is sandboxed and untrusted, and a single audited
 * chokepoint is far easier to reason about than thirty separate handlers.
 */
export function registerIpc(ctx: IpcContext): void {
  ipcMain.handle(CH.invoke, async (_event, raw: unknown): Promise<InvokeResult<unknown>> => {
    try {
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

      const value = await HANDLERS[name](parsed, ctx)
      return { ok: true, value }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  })
}

export function disposeIpc(): void {
  ipcMain.removeHandler(CH.invoke)
}
