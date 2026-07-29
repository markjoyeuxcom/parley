import { app, dialog, ipcMain } from 'electron'
import { CH, type InvokeResult } from '@shared/ipc'
import { invokeCommand, type IpcAppControl, type IpcContext, type IpcDialogs } from './commands'
import { relaunchIntoFreshBuild } from './relaunch'

/**
 * The Electron half of the IPC surface, and nothing else.
 *
 * The command table, its validation and its routing live in commands.ts, which
 * never loads Electron and is therefore testable. This file contributes the
 * two things only the runtime can provide: the ipcMain wiring and the native
 * dialogs, injected through the context so the handlers stay loadable outside
 * the app.
 */

// Explicit wrappers rather than passing `dialog` itself, so the surface the
// handlers may touch is exactly the one IpcDialogs declares.
const dialogs: IpcDialogs = {
  showOpenDialog: (window, options) => dialog.showOpenDialog(window, options),
  showSaveDialog: (window, options) => dialog.showSaveDialog(window, options),
}

const appControl: IpcAppControl = {
  relaunch: () => relaunchIntoFreshBuild(app, process.argv),
}

/**
 * Wires the single invoke channel.
 *
 * One channel with a validated command table rather than one channel per
 * operation: the renderer is sandboxed and untrusted, and a single audited
 * chokepoint is far easier to reason about than thirty separate handlers.
 */
export function registerIpc(ctx: Omit<IpcContext, 'dialogs' | 'appControl'>): void {
  const full: IpcContext = { ...ctx, dialogs, appControl }
  ipcMain.handle(CH.invoke, async (_event, raw: unknown): Promise<InvokeResult<unknown>> => {
    try {
      return { ok: true, value: await invokeCommand(full, raw) }
    } catch (err) {
      return { ok: false, error: err instanceof Error ? err.message : String(err) }
    }
  })
}

export function disposeIpc(): void {
  ipcMain.removeHandler(CH.invoke)
}
