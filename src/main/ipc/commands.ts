import { writeFile } from 'node:fs/promises'
// Type-only, so this module never loads Electron at runtime — which is the
// point of its existence: the command table, its validation and its routing
// can be exercised by tests, and vitest cannot load Electron. Everything that
// genuinely needs the runtime (ipcMain, the native dialogs) lives in
// register.ts and reaches the handlers through the context.
import type { BrowserWindow } from 'electron'
import { z } from 'zod'
import {
  COMMANDS,
  type CliHealth,
  type CommandName,
  type PaneIdentity,
  type SkillTarget,
} from '@shared/ipc'
import type { AppEvent } from '@shared/events'
import { MAX_PANES, type AgentConfig, type GridLayout, type RoomCaps, type Skill } from '@shared/domain'
import { newId, type Repo } from '@main/store/repo'
import { readCodexDefaultModel } from '@main/util/environment'
import { gitIdentity } from '@main/util/gitIdentity'
import type { AgentRegistry } from '@main/agents'
import type { PtyManager } from '@main/pty/manager'
import { RoomError, type RoomManager } from '@main/rooms/manager'

/** Refused before anything is touched. Flattened into the invoke envelope. */
export class RequestError extends Error {}

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
 * Everything a handler may reach.
 *
 * Flat, since the Manager it used to go through was retired with the engine
 * it coordinated: what remains is a store, a registry of CLI adapters, and
 * the two managers that hold live process and conversation state.
 */
export interface IpcContext {
  repo: Repo
  registry: AgentRegistry
  pty: PtyManager
  rooms: RoomManager
  emit: (event: AppEvent) => void
  /** Injected like the dialogs — commands.ts never loads Electron. */
  openExternal: (url: string) => void
  window: () => BrowserWindow | null
  health: () => CliHealth[]
  agyModels: () => Promise<string[]>
  dialogs: IpcDialogs
}

type Handler = (payload: unknown, ctx: IpcContext) => unknown | Promise<unknown>

function emit(ctx: IpcContext, event: AppEvent): void {
  ctx.emit(event)
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
    mock: ctx.registry.mock,
    codexDefaultModel: readCodexDefaultModel(),
    agyModels: await ctx.agyModels(),
  }),
  'health.probe': (_p, ctx) => ctx.health(),

  // ── Sessions ───────────────────────────────────────────────────────────────
  'profile.list': (_p, ctx) => ctx.repo.listAgentProfiles(),
  'profile.add': (p, ctx) =>
    ctx.repo.createAgentProfile(
      p as { name: string; vendor: 'claude' | 'codex' | 'agy'; model: string; effort: 'low' | 'medium' | 'high' | 'xhigh' | 'max'; persona: string },
    ),
  // ── Rooms ──────────────────────────────────────────────────────────────────
  //
  // `room.send` deliberately does not await the seat. A turn can run for
  // minutes and the renderer learns what happened from the room.turn.* events
  // either way; holding the invoke open would give the surface a promise it
  // has no use for and a timeout it cannot survive.
  'room.open': (p, ctx) => {
    const { cwd, seats, caps } = p as { cwd: string; seats: AgentConfig[]; caps: RoomCaps }
    return ctx.rooms.open(cwd, seats, caps)
  },
  'room.get': (p, ctx) => ctx.rooms.get((p as { roomId: string }).roomId) ?? null,
  /** Every room the record holds, newest first. Turns are not loaded. */
  'room.list': (_p, ctx) => ctx.rooms.listStored(),
  'room.reopen': (p, ctx) => ctx.rooms.reopen((p as { roomId: string }).roomId),
  'room.send': (p, ctx) => {
    const { roomId, text } = p as { roomId: string; text: string }
    const room = ctx.rooms.get(roomId)
    if (!room) throw new RequestError('no such room')
    if (room.status !== 'idle') throw new RequestError('that room is already waiting on a reply')
    void ctx.rooms.send(roomId, text).catch((err: unknown) => {
      // The engine records failures on the turn; this catches only what
      // escapes it, which would otherwise be an unhandled rejection.
      emit(ctx, {
        type: 'notice',
        level: 'error',
        message: err instanceof Error ? err.message : String(err),
      })
    })
    return { ok: true }
  },
  'room.setSeat': (p, ctx) => {
    const { roomId, seat } = p as { roomId: string; seat: AgentConfig }
    return ctx.rooms.setSeat(roomId, seat)
  },
  'room.addSeat': (p, ctx) => {
    const { roomId, seat } = p as { roomId: string; seat: AgentConfig }
    return ctx.rooms.addSeat(roomId, seat)
  },
  'room.removeSeat': (p, ctx) => {
    const { roomId, seatId } = p as { roomId: string; seatId: string }
    return ctx.rooms.removeSeat(roomId, seatId)
  },
  'room.setSeatWrite': (p, ctx) => {
    const { roomId, seatId, write } = p as { roomId: string; seatId: string; write: boolean }
    return ctx.rooms.setSeatWrite(roomId, seatId, write)
  },
  'room.verdicts': (p, ctx) => ctx.rooms.listVerdicts((p as { roomId: string }).roomId),
  // Fire-and-forget like send: every seat has to answer, which takes as long
  // as a turn each, and the pane learns the outcome from room.verdict.
  'room.converge': (p, ctx) => {
    const { roomId, question } = p as { roomId: string; question: string }
    const room = ctx.rooms.get(roomId)
    if (!room) throw new RequestError('no such room')
    if (room.status !== 'idle') throw new RequestError('that room is not idle')
    void ctx.rooms.converge(roomId, question).catch((err: unknown) => {
      emit(ctx, {
        type: 'notice',
        level: 'error',
        message: err instanceof Error ? err.message : String(err),
      })
    })
    return { ok: true }
  },
  'room.setCaps': (p, ctx) => {
    const { roomId, caps } = p as { roomId: string; caps: RoomCaps }
    return ctx.rooms.setCaps(roomId, caps)
  },
  // Fire-and-forget for the same reason as room.send: an advance can run for
  // many minutes and the pane learns everything from the room.* events.
  'room.advance': (p, ctx) => {
    const { roomId, turns } = p as { roomId: string; turns: number }
    const room = ctx.rooms.get(roomId)
    if (!room) throw new RequestError('no such room')
    if (room.status !== 'idle') throw new RequestError('that room is not idle')
    void ctx.rooms.advance(roomId, turns).catch((err: unknown) => {
      emit(ctx, {
        type: 'notice',
        level: 'error',
        message: err instanceof Error ? err.message : String(err),
      })
    })
    return { ok: true }
  },
  'room.stop': (p, ctx) => {
    ctx.rooms.stop((p as { roomId: string }).roomId)
    return null
  },
  'room.close': (p, ctx) => {
    ctx.rooms.close((p as { roomId: string }).roomId)
    return null
  },
  'profile.update': (p, ctx) => {
    const { profileId, ...fields } = p as {
      profileId: string
      name: string
      vendor: 'claude' | 'codex' | 'agy'
      model: string
      effort: 'low' | 'medium' | 'high' | 'xhigh' | 'max'
      persona: string
    }
    return ctx.repo.updateAgentProfile(profileId, fields)
  },
  'profile.forget': (p, ctx) => {
    ctx.repo.forgetAgentProfile((p as { profileId: string }).profileId)
    return null
  },
  'search.query': (p, ctx) => {
    const input = p as { query: string; limit?: number }
    return ctx.repo.search(input.query, { limit: input.limit ?? 20 })
  },
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
  'pane.paste': (p, ctx) => {
    const { paneId, text } = p as { paneId: string; text: string }
    ctx.pty.paste(paneId, text)
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
  /**
   * What the pane's folder is. The worktree chip went with the plans it
   * pointed at; a folder's identity is now just git's answer about it.
   */
  'pane.identity': async (p, ctx) => {
    void ctx
    const { cwd } = p as { cwd: string }
    const git = await gitIdentity(cwd)
    if (!git) return null
    return {
      branch: git.branch,
      dirty: git.dirty,
      ahead: git.ahead,
      behind: git.behind,
    } satisfies PaneIdentity
  },
  'pane.saveTranscript': async (p, ctx) => {
    const { suggestedName, text } = p as { suggestedName: string; text: string }
    const window = ctx.window()
    if (!window) throw new Error('no window')
    const result = await ctx.dialogs.showSaveDialog(window, {
      title: 'Save transcript',
      defaultPath: suggestedName,
      // Follows the suggested name: a room transcript is markdown and saving
      // it as .txt would strip the structure the file exists to preserve.
      filters: suggestedName.endsWith('.md')
        ? [{ name: 'Markdown', extensions: ['md'] }]
        : [{ name: 'Text', extensions: ['txt'] }],
    })
    if (result.canceled || !result.filePath) return { saved: false, path: null }
    await writeFile(result.filePath, text, 'utf8')
    return { saved: true, path: result.filePath }
  },
  'pane.list': (_p, ctx) => ctx.pty.list(),

  // ── Saved layouts ──────────────────────────────────────────────────────────
  'layout.save': (p, ctx) => {
    const input = p as { name: string; defaultFolder: string; tree: GridLayout['tree'] }
    return ctx.repo.saveLayout({ id: newId(), ...input })
  },
  'folder.list': (_p, ctx) => ctx.repo.listFolders(),
  'folder.remember': (p, ctx) => ctx.repo.rememberFolder((p as { path: string }).path),
  'folder.forget': (p, ctx) => ctx.repo.forgetFolder((p as { path: string }).path),
  'layout.list': (_p, ctx) => ctx.repo.listLayouts(),
  'layout.delete': (p, ctx) => {
    ctx.repo.deleteLayout((p as { layoutId: string }).layoutId)
    return { ok: true }
  },

  // ── Skills ─────────────────────────────────────────────────────────────────
  'skill.list': (_p, ctx) => ctx.repo.listSkills(),
  'skill.save': (p, ctx) => {
    const input = p as Omit<Skill, 'builtIn'>
    const existing = input.id ? ctx.repo.getSkill(input.id) : null
    return ctx.repo.upsertSkill({
      ...input,
      id: existing?.id ?? input.id ?? newId(),
      // A built-in cannot be demoted to a user skill by editing it.
      builtIn: existing?.builtIn ?? false,
    })
  },
  'skill.run': (p, ctx) => {
    const { target, skillId } = p as { target: SkillTarget; skillId: string }
    const skill = ctx.repo.getSkill(skillId)
    if (!skill) throw new Error('no such skill')
    if (target.kind === 'room') {
      const room = ctx.rooms.get(target.roomId)
      if (!room) throw new RequestError('no such room')
      if (room.status !== 'idle') {
        throw new RequestError('that room is already waiting on a reply')
      }
      // A skill is a prompt, so in a room it is simply what the person said —
      // it lands on the transcript as their turn, exactly as typing it would.
      void ctx.rooms.send(target.roomId, skill.prompt).catch(() => {
        /* The engine records failures on the turn. */
      })
      return { ok: true }
    }
    ctx.pty.submit(target.paneId, skill.prompt)
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
 * envelope.
 */
export async function invokeCommand(ctx: IpcContext, raw: unknown): Promise<unknown> {
  const parsed = z.object({ command: z.string(), payload: z.unknown() }).safeParse(raw)
  if (!parsed.success) throw new RequestError('malformed request')

  const name = parsed.data.command as CommandName
  const schema = COMMANDS[name]
  if (schema === undefined) throw new RequestError(`unknown command: ${parsed.data.command}`)

  const handler = HANDLERS[name]
  if (!handler) throw new RequestError(`unhandled command: ${parsed.data.command}`)

  if (schema === null) return handler(undefined, ctx)
  const payload = schema.safeParse(parsed.data.payload)
  if (!payload.success) throw new RequestError(`invalid payload for ${name}: ${payload.error.message}`)
  return handler(payload.data, ctx)
}
