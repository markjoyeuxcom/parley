import { contextBridge, ipcRenderer } from 'electron'
import { CH, unwrapInvokeResult, type CommandName, type InvokeResult } from '@shared/ipc'
import type { AppEvent, PtyChunk } from '@shared/events'

/**
 * The renderer's entire view of the outside world.
 *
 * Deliberately narrow: one invoke function over a validated command table, and
 * two read-only event subscriptions. No filesystem, no child processes, no
 * Node. Adding capability means adding a command with a schema in
 * `shared/ipc.ts`, not widening this surface.
 */
const api = {
  /**
   * Calls a main-process command. Rejects with the main process's own message
   * rather than a generic IPC error, so failures surface something a person can
   * act on.
   */
  async invoke<T = unknown>(command: CommandName, payload?: unknown): Promise<T> {
    const result = (await ipcRenderer.invoke(CH.invoke, { command, payload })) as InvokeResult<T>
    return unwrapInvokeResult(result)
  },

  /** Subscribes to application events. Returns an unsubscribe function. */
  onEvent(handler: (event: AppEvent) => void): () => void {
    const listener = (_e: unknown, payload: AppEvent): void => handler(payload)
    ipcRenderer.on(CH.event, listener)
    return () => ipcRenderer.removeListener(CH.event, listener)
  },

  /** Subscribes to terminal output. Separate channel: high volume, unvalidated. */
  onPtyData(handler: (chunk: PtyChunk) => void): () => void {
    const listener = (_e: unknown, payload: PtyChunk): void => handler(payload)
    ipcRenderer.on(CH.ptyData, listener)
    return () => ipcRenderer.removeListener(CH.ptyData, listener)
  },

  platform: process.platform,
}

export type ParleyApi = typeof api

contextBridge.exposeInMainWorld('parley', api)
