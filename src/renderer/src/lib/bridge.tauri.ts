import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import type { AppEvent, PtyChunk } from '@shared/events'
import type { CommandName } from '@shared/ipc'

/**
 * The Electron preload bridge, answered by Tauri instead.
 *
 * This file is why the migration is a sequence rather than a leap. The renderer
 * — six and a half thousand lines of it — reaches the outside world through
 * exactly one interface: `invoke`, `onEvent`, `onPtyData`, `platform`. Every
 * surface, every pane, every room goes through that. So the runtime underneath
 * can be replaced command by command while the React app above stays put.
 *
 * What is NOT here is as important as what is. A command with no Rust
 * implementation yet fails loudly and says so, listing what does work. During a
 * migration the dangerous failure is the quiet one: a store call that resolves
 * to undefined, a surface that renders empty, and an afternoon spent deciding
 * whether that is a bug or a gap.
 */

/**
 * IPC names, as Rust spells them. `pane.open` cannot be a Rust function name,
 * and inventing a convention on each side separately is how they drift.
 */
const IMPLEMENTED: Partial<Record<CommandName, string>> = {
  'pane.open': 'pane_open',
  'pane.write': 'pane_write',
  'pane.resize': 'pane_resize',
  'pane.close': 'pane_close',
  'pane.list': 'pane_list',
}

/** Tauri takes snake_case argument names; the renderer speaks camelCase. */
function toSnake(payload: unknown): Record<string, unknown> {
  if (!payload || typeof payload !== 'object') return {}
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(payload as Record<string, unknown>)) {
    out[key.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)] = value
  }
  return out
}

export function installTauriBridge(): void {
  window.parley = {
    invoke: async <T,>(command: CommandName, payload?: unknown): Promise<T> => {
      const rust = IMPLEMENTED[command]
      if (!rust) {
        // Loud, and specific about where the migration has reached.
        throw new Error(
          `“${command}” is not on Tauri yet. Implemented so far: ${Object.keys(IMPLEMENTED).join(', ')}.`,
        )
      }
      return invoke<T>(rust, toSnake(payload))
    },

    onEvent: (handler: (event: AppEvent) => void) => {
      const stop = listen<AppEvent>('app:event', (e) => handler(e.payload))
      return () => void stop.then((off) => off())
    },

    // Its own channel, as in the Electron build: high-volume opaque bytes that
    // would swamp the validated one. The coalescing that build ended up needing
    // belongs on the Rust side of this before real use.
    onPtyData: (handler: (chunk: PtyChunk) => void) => {
      const stop = listen<PtyChunk>('pty:data', (e) => handler(e.payload))
      return () => void stop.then((off) => off())
    },

    platform: 'darwin',
  }
}
