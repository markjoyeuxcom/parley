import type { Id } from '@shared/domain'

/**
 * Per-pane terminal accessors, registered by each mounted terminal. A module
 * map like ptyBuffer's, for the same reason: the menus and the find bar live
 * outside the terminal component, and threading refs through the layout tree
 * for a handful of calls is chrome the tree does not need.
 */
export interface TermAccess {
  getSelection: () => string
  /**
   * Everything the CLI has drawn since the person last submitted something.
   *
   * The relay's whole point is "hand me its answer", and making somebody drag
   * a rectangle over a redrawing TUI to express that is asking them to do the
   * terminal's job. The boundary is the last Enter they pressed, which is
   * exactly where their question ended and the answer began.
   */
  lastOutput: () => string
  /** The full buffer as text — the transcript a save writes. */
  serialize: () => string
  findNext: (query: string) => boolean
  findPrevious: (query: string) => boolean
  clearSearch: () => void
}

const terms = new Map<Id, TermAccess>()

/**
 * The last thing actually selected in each pane.
 *
 * Selecting in a CLI that has claimed the mouse needs ⌥ held, and letting go
 * of ⌥ drops the highlight — so by the time the menu is open, xterm reports
 * nothing selected and the relay has nothing to send. The same happens when
 * the CLI redraws over the selection, which a live TUI does constantly.
 *
 * What somebody selected is not unselected by their hand leaving the
 * keyboard, so it is kept until they select something else or the pane goes.
 * A live selection always wins over the remembered one.
 */
const lastSelection = new Map<Id, string>()

export function rememberSelection(paneId: Id, text: string): void {
  if (text.trim()) lastSelection.set(paneId, text)
}

export function forgetSelection(paneId: Id): void {
  lastSelection.delete(paneId)
}

export function registerTerm(paneId: Id, access: TermAccess): () => void {
  terms.set(paneId, access)
  return () => {
    if (terms.get(paneId) === access) {
      terms.delete(paneId)
      lastSelection.delete(paneId)
    }
  }
}

export function termAccess(paneId: Id): TermAccess | null {
  return terms.get(paneId) ?? null
}

export function paneSelection(paneId: Id): string {
  let live = ''
  try {
    live = terms.get(paneId)?.getSelection() ?? ''
  } catch {
    live = ''
  }
  return live.trim() ? live : (lastSelection.get(paneId) ?? '')
}

/**
 * Why the relay cannot send from this pane yet, if it cannot.
 *
 * The awkward case: a CLI that draws clickable UI turns on mouse tracking, and
 * xterm then hands a drag to the application instead of selecting locally. The
 * application highlights the text itself, so it LOOKS selected while
 * `getSelection()` stays empty and the relay offers nothing. Claude Code does
 * this; selecting in its pane is impossible without `macOptionClickForcesSelection`
 * and a held ⌥.
 *
 * The hint mentions ⌥ unconditionally rather than detecting the mode.
 * `mouseTrackingMode` was measured against the real CLIs and came back
 * identical for Claude, whose pane cannot be drag-selected, and Codex, whose
 * pane can — so the mode does not distinguish the two cases and a hint keyed
 * on it would be wrong half the time. One sentence that is true either way
 * beats a detector that is confidently wrong.
 */
export type RelayState = 'no-targets' | 'selection' | 'output' | 'nothing'

/**
 * A selection wins when there is one: choosing text is somebody saying "this
 * part", and quietly sending the whole answer instead would be overriding
 * them. Without one, the last output is what they almost certainly mean.
 */
export function relayState(input: {
  targets: number
  selection: string
  lastOutput: string
}): RelayState {
  if (input.targets === 0) return 'no-targets'
  if (input.selection.trim()) return 'selection'
  return input.lastOutput.trim() ? 'output' : 'nothing'
}
