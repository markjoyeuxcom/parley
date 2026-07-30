import type { Pane, PaneKind } from '@shared/domain'
import type { Slot } from './layout'
import { shortPath } from './format'

export const KIND_LABEL: Record<PaneKind, string> = {
  shell: 'Shell',
  claude: 'Claude',
  codex: 'Codex',
}

/**
 * Header derivations for a slot and whatever the pane registry knows about
 * its process. Pure and small so their fallback ladders are pinned by unit
 * tests — these strings and states are the only truth the pane header shows.
 */

export function slotPaneTitle(slot: Slot | undefined, pane: Pane | undefined): string {
  if (!slot) return 'pane'
  return pane?.title ?? `${KIND_LABEL[slot.kind]} — ${shortPath(slot.cwd)}`
}

/** `'idle'` = a slot with no process; `'starting'` = spawned but unheard-from. */
export function slotPaneStatus(
  slot: Slot | undefined,
  pane: Pane | undefined,
): 'idle' | Pane['status'] {
  if (!slot?.paneId) return 'idle'
  return pane?.status ?? 'starting'
}

export function slotPaneExit(slot: Slot | undefined, pane: Pane | undefined): number | null {
  if (!slot?.paneId) return null
  return pane?.exitCode ?? null
}
