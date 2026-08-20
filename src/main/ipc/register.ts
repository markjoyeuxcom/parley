import { dialog, ipcMain } from 'electron'
import { CH, toInvokeResult, type InvokeResult } from '@shared/ipc'
import { invokeCommand, RequestError, type IpcContext, type IpcDialogs } from './commands'

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

/**
 * Wires the single invoke channel.
 *
 * One channel with a validated command table rather than one channel per
 * operation: the renderer is sandboxed and untrusted, and a single audited
 * chokepoint is far easier to reason about than thirty separate handlers.
 */
export function registerIpc(ctx: Omit<IpcContext, 'dialogs'>): void {
  const full: IpcContext = { ...ctx, dialogs }
  ipcMain.handle(
    CH.invoke,
    (event, raw: unknown): Promise<InvokeResult<unknown>> =>
      toInvokeResult(() => {
        // Only the window's own top frame. There is one window, no <webview>
        // and no iframes, and will-navigate bounces everything — so today this
        // can only ever be true. It is here because the surface behind it
        // spawns terminals, writes keystrokes and grants seats write
        // capability, and "there are no subframes yet" is a property of this
        // week's code rather than of the boundary.
        if (event.senderFrame && event.senderFrame !== event.sender.mainFrame) {
          throw new RequestError('ipc from an unexpected frame')
        }
        return invokeCommand(full, raw)
      }),
  )
}

export function disposeIpc(): void {
  ipcMain.removeHandler(CH.invoke)
}
