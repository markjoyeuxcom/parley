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
  'pane.flow': 'pane_flow',
  'pane.list': 'pane_list',
  'folder.list': 'default_cwd',
}

/**
 * Arguments go over as they are.
 *
 * This used to rename `paneId` to `pane_id` on the way out, on the reasonable
 * sounding theory that Rust wants snake_case. Tauri's command macro does the
 * opposite: it lower-camel-cases each parameter name and looks that key up, so
 * a snake_case key is simply not found. The renderer already speaks camelCase,
 * which is what Tauri wants, and the translation was the whole problem.
 *
 * It hid because `pane_open` takes kind, cwd, cols and rows — four single
 * words, identical in both cases. So panes opened, CLIs started, output
 * streamed, and the app looked entirely healthy while every keystroke went to
 * `pane_write` with no pane id at all.
 */
function argsFor(payload: unknown): Record<string, unknown> {
  return payload && typeof payload === 'object' ? (payload as Record<string, unknown>) : {}
}

export function installTauriBridge(): void {
  if (window.parley) return
  window.parley = {
    invoke: async <T,>(command: CommandName, payload?: unknown): Promise<T> => {
      const rust = IMPLEMENTED[command]
      if (!rust) {
        // Loud, and specific about where the migration has reached.
        throw new Error(
          `“${command}” is not on Tauri yet. Implemented so far: ${Object.keys(IMPLEMENTED).join(', ')}.`,
        )
      }
      return invoke<T>(rust, argsFor(payload))
    },

    // Rust does not emit `app:event` yet — the store, rooms and agent adapters
    // that raise those events have not been migrated. Subscribing to it looked
    // like plumbing and was a listener on a channel nobody speaks, so it says
    // so instead. Pane lifecycle travels on `pane:status`, which TauriShell
    // reads directly.
    onEvent: (_handler: (event: AppEvent) => void) => {
      return () => {}
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

// Installed on import, not by a caller. `ptyBuffer` subscribes to pane output
// at module load — that is what stops a shell's first prompt being lost between
// spawn and mount — so anything importing it before the bridge existed would
// subscribe to nothing at all. Making the install a side effect of importing
// this module removes the ordering question instead of documenting it.
installTauriBridge()
