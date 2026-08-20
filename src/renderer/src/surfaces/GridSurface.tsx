import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Columns2, FolderOpen, Grid2x2, Layers, MoreHorizontal, Play, Plus, Radio, Rows2, Terminal, Users, X } from 'lucide-react'
import {
  MAX_PANES,
  RESUME_PICKER_KINDS,
  type AgentConfig,
  type GridLayout,
  type Id,
  type LayoutNode,
  type PaneKind,
  type Room,
  type RoomCaps,
  type Skill,
  type SlotKind,
} from '@shared/domain'
import type { PaneIdentity } from '@shared/ipc'
import { api } from '../lib/api'
import { forgetPane } from '../lib/ptyBuffer'
import {
  collectSlotIds,
  countSlots,
  fromSavedLayout,
  leaf,
  nextSlot,
  previousSlot,
  swapLeaves,
  removeLeaf,
  setRatio,
  splitLeaf,
  toSavedLayout,
  arrangeInColumns,
  autoColumns,
  type Slot,
  type SplitPath,
} from '../lib/layout'
import { shortPath } from '../lib/format'
import { canReceiveRelay, forgetSelection, paneSelection, relayState, termAccess } from '../lib/termSelection'
import { reviewRequest } from '@shared/review'
import { cleanRelayText } from '../lib/relayText'
import { useStore } from '../state'
import { TerminalPane } from '../components/TerminalPane'
import { RosterDialog } from '../components/RosterDialog'
import { RoomPane } from '../components/RoomPane'
import { roomTranscript } from '@shared/room'
import { Chip, Dialog, Dot, Empty, Field, Menu, MenuItem, MenuSection } from '../components/ui'
import {
  KIND_LABEL as PANE_KIND_LABEL,
  slotPaneExit,
  slotPaneStatus,
  slotPaneTitle,
} from '../lib/panes'

const KIND_LABEL = PANE_KIND_LABEL
const PANE_KINDS: PaneKind[] = ['shell', 'claude', 'codex', 'agy']
/** Everything the toolbar can open. A room is last: it is the odd one out. */
const SLOT_KINDS: SlotKind[] = [...PANE_KINDS, 'room']

/**
 * The seat a new room opens with.
 *
 * Claude because it is the one vendor that is never tool-less, so a room is
 * usable the moment it exists; the seat control changes it in place.
 */
const DEFAULT_ROOM_SEAT: AgentConfig = { vendor: 'claude', model: '', effort: 'high', persona: '' }

/**
 * What a new room may spend before it stops and asks.
 *
 * Forty turns is a long conversation and a bounded one; no cost ceiling by
 * default because the subscriptions barely report cost, so a dollar cap would
 * be a number that never fires pretending to be a safeguard.
 */
const DEFAULT_ROOM_CAPS: RoomCaps = { turns: 40, costUsd: 0 }

/** The folder's own name, for labelling a saved file. */
function basenameOf(path: string): string {
  return path.replace(/\/+$/, '').split('/').pop() || 'room'
}

let slotSeq = 0
const mintSlotId = (): Id => `slot-${Date.now().toString(36)}-${(slotSeq += 1)}`

/**
 * The Grid: up to sixteen live terminals in a splittable layout.
 *
 * The agent panes run the real interactive CLIs, so a pane is a full Claude Code
 * or Codex session with its own prompts — not a re-hosted imitation.
 *
 * The tree is keyed by *slot*, not by pane. A slot is a position in the layout
 * that may or may not currently hold a running process, which is what lets a
 * saved layout be restored with its shells live and its agent panes waiting to
 * be started.
 */
export function GridSurface(): ReactNode {
  const { state, dispatch, notify, attempt } = useStore()
  const [layout, setLayout] = useState<LayoutNode | null>(null)
  const [slots, setSlots] = useState<Record<Id, Slot>>({})
  const [focusedSlot, setFocusedSlot] = useState<Id | null>(null)
  const [cwd, setCwd] = useState('')
  const [dropTarget, setDropTarget] = useState<Id | null>(null)
  const [picked, setPicked] = useState<string[]>([])
  const [layouts, setLayouts] = useState<GridLayout[]>([])
  const [saving, setSaving] = useState(false)
  const [renaming, setRenaming] = useState<{ slotId: Id; value: string } | null>(null)
  const [broadcasting, setBroadcasting] = useState(false)
  const [roster, setRoster] = useState(false)
  /** The slot a recorded room is being chosen for. */
  const [reopening, setReopening] = useState<Id | null>(null)
  /** Null = closed; a string = the live query against the focused pane. */
  const [finding, setFinding] = useState<string | null>(null)
  const [maximizedSlot, setMaximizedSlot] = useState<Id | null>(null)
  /** Keyed by folder — panes sharing a cwd share one identity line. */
  const [identities, setIdentities] = useState<Record<string, PaneIdentity | null>>({})
  const [unreadSlots, setUnreadSlots] = useState<Set<Id>>(new Set())
  const draggingSkill = useRef<Skill | null>(null)

  const slotCount = countSlots(layout)
  const paneById = useMemo(() => new Map(state.panes.map((p) => [p.id, p])), [state.panes])

  const refreshLayouts = useCallback(async () => {
    const saved = await attempt(() => api.listLayouts())
    if (saved) setLayouts(saved)
  }, [attempt])

  // Reconcile the pane registry once at mount: events cover everything after
  // this moment, and the one-shot list covers panes born before the surface
  // was ready to hear about them.
  //
  // And put them back on the grid. Closing the window on macOS deliberately
  // leaves the panes running — that is what stops a stray ⌘W ending an agent
  // mid-task — but the Grid mounted with an empty layout, so reopening showed
  // nothing while claude and codex carried on spending against a subscription
  // with no way left to reach them or stop them. The registry knew; the
  // surface did not ask.
  //
  // Only when the grid is empty. A surface that already has a layout is one
  // the person is using, and adopting panes into it would rearrange their work
  // underneath them.
  useEffect(() => {
    void attempt(() => api.listPanes()).then((panes) => {
      if (!panes) return
      dispatch({ type: 'panes', panes })

      const adoptable = panes.filter((pane) => pane.status !== 'exited')
      if (adoptable.length === 0) return
      setLayout((current) => {
        if (current) return current
        const rebuilt: Record<Id, Slot> = {}
        let tree: LayoutNode | null = null
        adoptable.forEach((pane, index) => {
          const slotId = mintSlotId()
          rebuilt[slotId] = {
            kind: pane.kind,
            cwd: pane.cwd,
            paneId: pane.id,
            roomId: null,
            ...(pane.title ? { title: pane.title } : {}),
          }
          if (!tree) tree = leaf(slotId)
          else {
            const target = collectSlotIds(tree)[index - 1]
            // Alternating, so four adopted panes come back as a grid rather
            // than four slivers in a row.
            tree = target
              ? splitLeaf(tree, target, index % 2 === 1 ? 'row' : 'column', slotId)
              : tree
          }
        })
        setSlots(rebuilt)
        setFocusedSlot(Object.keys(rebuilt)[0] ?? null)
        return tree
      })
    })
  }, [attempt, dispatch])

  useEffect(() => {
    void refreshLayouts()
  }, [refreshLayouts])

  // The folders somebody added, from the record. Held in state as well so the
  // menu can offer them before anything is open in one.
  useEffect(() => {
    void attempt(() => api.listFolders()).then((folders) => {
      if (!folders) return
      setPicked(folders)
      // Where they were last working; a room's folder is only the fallback.
      setCwd((current) => current || folders[folders.length - 1] || '')
    })
  }, [attempt])


  /**
   * Folders worth offering: the durable list first, then whatever is open.
   */
  const recentFolders = useMemo(() => {
    const seen = new Set<string>()
    const out: string[] = []
    const add = (path?: string | null): void => {
      const trimmed = path?.trim()
      if (!trimmed || seen.has(trimmed)) return
      seen.add(trimmed)
      out.push(trimmed)
    }
    // Folders somebody added come first and come whole: slicing a list a
    // person curated is how it starts feeling lost again. Live pane folders
    // follow, so somewhere opened transiently is still reachable.
    for (const path of picked) add(path)
    if (cwd) add(cwd)
    for (const slot of Object.values(slots)) add(slot.cwd)
    return out.slice(0, 20)
  }, [cwd, picked, slots])

  /** Distinct folders the grid currently spans. */
  const activeFolders = useMemo(
    () => [...new Set(collectSlotIds(layout).map((id) => slots[id]?.cwd).filter((c): c is string => !!c))],
    [layout, slots],
  )

  const liveSlots = useMemo(
    () => collectSlotIds(layout).filter((id) => slots[id]?.paneId),
    [layout, slots],
  )

  /**
   * Rooms currently on the grid. Counted separately from `liveSlots`, which
   * several callers use to mean "has a pty" — a room has none.
   *
   * They exist because the confirmation before replacing the grid counted
   * panes only, so a grid holding nothing but a thinking room offered to
   * replace "0 panes" and then dropped the room without asking.
   */
  const liveRoomSlots = useMemo(
    () => collectSlotIds(layout).filter((id) => slots[id]?.roomId),
    [layout, slots],
  )

  /** Running agent panes — the broadcast audience. */
  const agentPanes = useMemo(
    () =>
      liveSlots
        .map((id) => slots[id])
        .filter((slot): slot is Slot => !!slot && slot.kind !== 'shell' && !!slot.paneId)
        .filter((slot) => {
          const pane = slot.paneId ? paneById.get(slot.paneId) : undefined
          return !pane || pane.status !== 'exited'
        }),
    [liveSlots, slots, paneById],
  )
  const agentPaneCount = agentPanes.length

  const focusedRef = useRef(focusedSlot)
  focusedRef.current = focusedSlot

  const refreshIdentity = useCallback(async (dir: string): Promise<void> => {
    const identity = await api.paneIdentity(dir).catch(() => null)
    setIdentities((current) => ({ ...current, [dir]: identity }))
  }, [])

  // Every folder the grid spans gets an identity line once; the focused
  // pane's folder refreshes on focus so a branch switch or commit shows up
  // the next time you look at it — never on a timer.
  useEffect(() => {
    for (const dir of activeFolders) {
      if (!(dir in identities)) void refreshIdentity(dir)
    }
  }, [activeFolders, identities, refreshIdentity])

  useEffect(() => {
    const dir = focusedSlot ? slots[focusedSlot]?.cwd : null
    if (dir) void refreshIdentity(dir)
    if (focusedSlot) {
      setUnreadSlots((current) => {
        if (!current.has(focusedSlot)) return current
        const next = new Set(current)
        next.delete(focusedSlot)
        return next
      })
    }
    // slots is deliberately not a dependency: focus is the refresh trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focusedSlot, refreshIdentity])

  /** Output landing in an unfocused pane marks it unread until looked at. */
  const markOutput = useCallback((slotId: Id) => {
    if (focusedRef.current === slotId) return
    setUnreadSlots((current) => {
      if (current.has(slotId)) return current
      const next = new Set(current)
      next.add(slotId)
      return next
    })
  }, [])

  /** Starts the process for a slot that has none. */
  const startSlot = useCallback(
    async (slotId: Id, opts: { resume?: boolean } = {}): Promise<void> => {
      const slot = slots[slotId]
      if (!slot || slot.paneId || slot.roomId) return
      const kind = slot.kind
      if (kind === 'room') {
        const room = await attempt(() => api.openRoom(slot.cwd, [DEFAULT_ROOM_SEAT], DEFAULT_ROOM_CAPS))
        if (!room) return
        setSlots((current) => ({ ...current, [slotId]: { ...slot, roomId: room.id } }))
        setFocusedSlot(slotId)
        return
      }
      const pane = await attempt(() => api.openPane(kind, slot.cwd, 80, 24, opts.resume ?? false))
      if (!pane) return
      setSlots((current) => ({ ...current, [slotId]: { ...slot, paneId: pane.id } }))
      setFocusedSlot(slotId)
    },
    [attempt, slots],
  )

  const commitRename = (): void => {
    if (!renaming) return
    const { slotId, value } = renaming
    setRenaming(null)
    setSlots((current) => {
      const slot = current[slotId]
      if (!slot) return current
      const title = value.trim()
      const next = { ...slot }
      if (title) next.title = title
      else delete next.title
      return { ...current, [slotId]: next }
    })
  }

  /** Kills the process; the slot keeps its corpse and its exit code. */
  const stopSlot = useCallback(
    (slotId: Id) => {
      const paneId = slots[slotId]?.paneId
      if (paneId) void attempt(() => api.stopPane(paneId))
    },
    [attempt, slots],
  )

  /**
   * One motion serves restart, reopen, replace-kind and resume: discard
   * whatever process the slot holds — the slot itself survives — and spawn
   * the next one into the same position. A failed spawn leaves the slot idle
   * with its Start button, never half-attached to a dead pane id.
   */
  const relaunchSlot = useCallback(
    async (slotId: Id, opts: { kind?: SlotKind; resume?: boolean } = {}): Promise<void> => {
      const slot = slots[slotId]
      if (!slot) return
      if (slot.paneId) {
        void api.closePane(slot.paneId).catch(() => undefined)
        forgetPane(slot.paneId)
      }
      // Replacing a room's kind ends its conversation, so the seat is
      // abandoned here rather than left talking into a slot that has moved on.
      if (slot.roomId) void api.closeRoom(slot.roomId).catch(() => undefined)
      const kind = opts.kind ?? slot.kind
      const opened =
        kind === 'room'
          ? await attempt(() => api.openRoom(slot.cwd, [DEFAULT_ROOM_SEAT], DEFAULT_ROOM_CAPS))
          : await attempt(() => api.openPane(kind, slot.cwd, 80, 24, opts.resume ?? false))
      setSlots((current) => {
        const existing = current[slotId]
        if (!existing) return current
        return {
          ...current,
          [slotId]: {
            ...existing,
            kind,
            paneId: kind === 'room' ? null : (opened?.id ?? null),
            roomId: kind === 'room' ? (opened?.id ?? null) : null,
          },
        }
      })
      if (opened) setFocusedSlot(slotId)
    },
    [attempt, slots],
  )

  const openPane = useCallback(
    async (
      kind: SlotKind,
      splitFrom?: { slotId: Id; direction: 'row' | 'column' },
      title?: string,
      dirOverride?: string,
    ) => {
      if (slotCount >= MAX_PANES) {
        notify('warn', `The grid holds at most ${MAX_PANES} panes.`)
        return
      }
      // A split inherits the folder of the pane it grew out of. Using the
      // toolbar's target instead would silently drop you into a different
      // repository than the pane you were just working in. An explicit
      // override wins over both — that's the cross-surface door.
      const inherited = splitFrom ? slots[splitFrom.slotId]?.cwd : null
      const dir = (dirOverride ?? inherited ?? cwd).trim()
      if (!dir) {
        notify('warn', 'Choose a folder first.')
        return
      }
      // A room opens a conversation where a pane opens a process. Same slot
      // machinery either way — the difference is which id the slot carries.
      const opened =
        kind === 'room'
          ? await attempt(() => api.openRoom(dir, [DEFAULT_ROOM_SEAT], DEFAULT_ROOM_CAPS))
          : await attempt(() => api.openPane(kind, dir, 80, 24))
      if (!opened) return

      const slotId = mintSlotId()
      setSlots((current) => ({
        ...current,
        [slotId]: {
          kind,
          cwd: dir,
          paneId: kind === 'room' ? null : opened.id,
          roomId: kind === 'room' ? opened.id : null,
          ...(title ? { title } : {}),
        },
      }))
      setLayout((current) => {
        if (!current) return leaf(slotId)
        if (splitFrom) return splitLeaf(current, splitFrom.slotId, splitFrom.direction, slotId)
        const target = focusedSlot ?? collectSlotIds(current)[0]
        if (!target) return leaf(slotId)
        return splitLeaf(current, target, 'row', slotId)
      })
      setFocusedSlot(slotId)
      setMaximizedSlot(null)
    },
    [attempt, cwd, focusedSlot, notify, slotCount, slots],
  )

  /** Puts an already-open room into a fresh slot. */
  const openRoomSlot = useCallback(
    (roomId: Id, dir: string) => {
      if (slotCount >= MAX_PANES) {
        notify('warn', `The grid holds at most ${MAX_PANES} panes.`)
        return
      }
      const slotId = mintSlotId()
      setSlots((current) => ({
        ...current,
        [slotId]: { kind: 'room', cwd: dir, paneId: null, roomId },
      }))
      setLayout((current) => {
        if (!current) return leaf(slotId)
        const target = focusedSlot ?? collectSlotIds(current)[0]
        return target ? splitLeaf(current, target, 'row', slotId) : leaf(slotId)
      })
      setFocusedSlot(slotId)
      setMaximizedSlot(null)
    },
    [focusedSlot, notify, slotCount],
  )

  // Search asks for a room by id; the Grid is the only place one can be read.
  // Consumed and cleared, so the same hit twice opens one pane, not two.
  useEffect(() => {
    const roomId = state.focusRoomId
    if (!roomId) return
    dispatch({ type: 'focusRoom', roomId: null })
    if (Object.values(slots).some((slot) => slot.roomId === roomId)) return
    void attempt(() => api.reopenRoom(roomId)).then((room) => {
      if (room) void openRoomSlot(room.id, room.cwd)
    })
  }, [state.focusRoomId, dispatch, attempt, slots, openRoomSlot])

  const closeSlot = useCallback(
    (slotId: Id) => {
      const paneId = slots[slotId]?.paneId
      if (paneId) {
        void api.closePane(paneId).catch(() => undefined)
        forgetPane(paneId)
      }
      const roomId = slots[slotId]?.roomId
      // Abandons any in-flight seat with it: an orphaned turn would keep
      // spending against the subscription for a room nobody can see.
      if (roomId) void api.closeRoom(roomId).catch(() => undefined)
      setSlots((current) => {
        const next = { ...current }
        delete next[slotId]
        return next
      })
      setLayout((current) => (current ? removeLeaf(current, slotId) : null))
      setFocusedSlot((current) => (current === slotId ? null : current))
      setMaximizedSlot((current) => (current === slotId ? null : current))
      setUnreadSlots((current) => {
        if (!current.has(slotId)) return current
        const next = new Set(current)
        next.delete(slotId)
        return next
      })
    },
    [slots],
  )

  /**
   * Rearranges what is open into even columns.
   *
   * An action, not a mode. The Tauri shell could treat this as a live setting
   * because it lays panes out with CSS grid, where the count is just a number.
   * Here the layout is a split tree somebody edits by hand — ⌘D to split, drag
   * to set a ratio — and a mode that rebuilt it whenever a pane appeared would
   * quietly undo that. So it happens when asked, and never on its own.
   *
   * Nothing is opened, closed or restarted: the tree is rebuilt over the same
   * slot ids, so an arrange cannot cost anybody a running CLI.
   */
  const arrange = useCallback((cols: number | 'auto') => {
    setLayout((current) => {
      const ids = collectSlotIds(current)
      if (ids.length < 2) return current
      return arrangeInColumns(ids, cols === 'auto' ? autoColumns(ids.length) : cols)
    })
  }, [])

  /**
   * Tears the whole grid down. Used before restoring a saved layout.
   *
   * Rooms are closed as well as panes. They were not, so opening a saved
   * layout cleared the slot and left the room running in the main process —
   * mid-turn, still spending, with nothing on screen pointing at it. Removing
   * a single slot has always closed its room; only the wholesale teardown
   * forgot to.
   */
  const closeAll = useCallback(() => {
    for (const slot of Object.values(slots)) {
      if (slot.paneId) {
        void api.closePane(slot.paneId).catch(() => undefined)
        forgetPane(slot.paneId)
      }
      if (slot.roomId) void api.closeRoom(slot.roomId).catch(() => undefined)
    }
    setSlots({})
    setLayout(null)
    setFocusedSlot(null)
  }, [slots])

  /**
   * Restores a saved layout: shells start immediately, agent panes wait.
   *
   * Respawning several `claude` and `codex` sessions unprompted would start real
   * CLI processes against the user's subscription that they did not ask for on
   * this launch. A shell costs nothing and is useless without one.
   */
  const openLayout = useCallback(
    async (saved: GridLayout) => {
      const losing = [
        liveSlots.length ? `${liveSlots.length} pane${liveSlots.length === 1 ? '' : 's'}` : '',
        liveRoomSlots.length ? `${liveRoomSlots.length} room${liveRoomSlots.length === 1 ? '' : 's'}` : '',
      ].filter(Boolean)
      if (losing.length) {
        const ok = window.confirm(
          `Opening “${saved.name}” closes the ${losing.join(' and ')} currently open. Continue?`,
        )
        if (!ok) return
      }
      closeAll()

      const { tree, slots: restored } = fromSavedLayout(saved.tree, mintSlotId)
      setLayout(tree)
      setSlots(restored)
      if (saved.defaultFolder) setCwd(saved.defaultFolder)

      const shells = Object.entries(restored).filter(([, slot]) => slot.kind === 'shell')
      const started: Record<Id, Slot> = {}
      for (const [slotId, slot] of shells) {
        const pane = await attempt(() => api.openPane('shell', slot.cwd, 80, 24))
        if (pane) started[slotId] = { ...slot, paneId: pane.id }
      }
      if (Object.keys(started).length) {
        setSlots((current) => ({ ...current, ...started }))
      }

      const waiting = Object.keys(restored).length - Object.keys(started).length
      notify(
        'info',
        waiting
          ? `Opened “${saved.name}”. ${waiting} agent pane${waiting === 1 ? '' : 's'} ready to start.`
          : `Opened “${saved.name}”.`,
      )
    },
    [attempt, closeAll, liveRoomSlots.length, liveSlots.length, notify],
  )

  // Default the folder to the last one a room was opened in. The record is
  // the only memory of where work happened now that sessions are gone.
  useEffect(() => {
    if (cwd) return
    void api
      .listRooms()
      .then((rooms) => {
        const recent = rooms[0]?.cwd
        if (recent) setCwd(recent)
      })
      .catch(() => {
        /* No memory is not an error; the folder picker still works. */
      })
  }, [cwd])

  // ⌘D splits right, ⌘⇧D splits down, ⌘W closes, ⌘]/⌘[ cycle, ⌘⏎ maximizes.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (!event.metaKey) return
      const key = event.key.toLowerCase()
      if (key === 'd' && focusedSlot) {
        event.preventDefault()
        void openPane('shell', { slotId: focusedSlot, direction: event.shiftKey ? 'column' : 'row' })
      } else if (key === 'w' && focusedSlot) {
        event.preventDefault()
        closeSlot(focusedSlot)
      } else if (key === ']') {
        event.preventDefault()
        setFocusedSlot((current) => nextSlot(layout, current))
      } else if (key === '[') {
        event.preventDefault()
        setFocusedSlot((current) => previousSlot(layout, current))
      } else if (key === 'enter' && focusedSlot) {
        event.preventDefault()
        setMaximizedSlot((current) => (current === focusedSlot ? null : focusedSlot))
      } else if (key === 'f' && focusedSlot) {
        event.preventDefault()
        setFinding((current) => current ?? '')
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [closeSlot, focusedSlot, layout, openPane])

  const chooseFolder = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Choose a folder for new panes'))
    if (result?.path) {
      const chosen = result.path
      setCwd(chosen)
      // Written through rather than held here: a folder somebody added has to
      // survive the window closing, which is the whole point of adding one.
      const folders = await attempt(() => api.rememberFolder(chosen))
      if (folders) setPicked(folders)
    }
  }

  const forgetFolder = async (path: string): Promise<void> => {
    const folders = await attempt(() => api.forgetFolder(path))
    if (folders) setPicked(folders)
  }

  /** What a pane is called when another pane is told where something came from. */
  const paneName = (slotId: Id): string => {
    const slot = slots[slotId]
    const pane = slot?.paneId ? paneById.get(slot.paneId) : undefined
    return pane?.title?.trim() || slot?.kind || 'pane'
  }

  /** The other live agent panes — a shell has no conversation to relay into. */
  const relayTargets = (fromSlotId: Id): Array<{ slotId: Id; name: string }> =>
    liveSlots
      .filter((slotId) => slotId !== fromSlotId)
      .filter((slotId) => {
        const slot = slots[slotId]
        if (!slot?.paneId) return false
        return canReceiveRelay(slot.kind, paneById.get(slot.paneId)?.status)
      })
      .map((slotId) => ({ slotId, name: paneName(slotId) }))

  /**
   * Hand what one CLI said to another.
   *
   * The loop this app exists for, which people run by hand: read Claude's
   * answer, copy it, paste it into Codex, paste the reply back. Both halves
   * were already here — every terminal registers a selection accessor, and
   * `pane.paste` types into a running session — and nothing joined them.
   *
   * Attribution travels with the text because the receiving CLI has no idea
   * where it came from, and an unattributed wall of someone else's reasoning
   * reads as the user's own words.
   */
  /**
   * Hands a pane's uncommitted work to a counterpart for review.
   *
   * The same loop as `relay`, one step earlier: rather than copying what a CLI
   * *said*, this sends what it *did*. A pane already knows its folder, so the
   * diff is git's answer about that folder — no tracking of which agent touched
   * what, which would be wrong the moment somebody edits a file themselves.
   *
   * The wording lives in shared/review.ts so a diff cannot be sent without the
   * ask that makes it a review rather than a dump. Pasted, never submitted —
   * the person in the receiving pane presses Enter, as with every other relay.
   */
  const relayChanges = async (fromSlotId: Id, toSlotId: Id): Promise<void> => {
    const from = slots[fromSlotId]
    const to = slots[toSlotId]
    if (!from?.cwd || !to?.paneId) return

    const work = await attempt(() => api.workingDiff(from.cwd))
    if (!work) {
      notify('warn', 'That pane is not in a git repository.')
      return
    }
    if (!work.diff.trim() && work.untracked.length === 0) {
      notify('info', `Nothing uncommitted in ${paneName(fromSlotId)}'s folder.`)
      return
    }

    const sent = await attempt(() =>
      api.pastePane(to.paneId as Id, reviewRequest(paneName(fromSlotId), work)),
    )
    if (!sent) return
    setFocusedSlot(toSlotId)
    notify(
      'info',
      work.truncated
        ? `Sent a truncated diff to ${paneName(toSlotId)} — it was over the size limit.`
        : `Sent ${paneName(fromSlotId)}'s changes to ${paneName(toSlotId)}.`,
    )
  }

  const relay = async (fromSlotId: Id, toSlotId: Id): Promise<void> => {
    const from = slots[fromSlotId]
    const to = slots[toSlotId]
    const selection = from?.paneId ? paneSelection(from.paneId) : ''
    // A selection wins when there is one: choosing text is somebody saying
    // "this part", and sending the whole answer instead would override them.
    // A selection is dragged across the same boxes the buffer is drawn in, so
    // it needs the same frame taken off — and the same bound, since the IPC
    // schema refuses an oversized payload and a whole scrollback can exceed it.
    const body = selection.trim()
      ? cleanRelayText(selection.split('\n'))
      : (from?.paneId ? termAccess(from.paneId)?.lastOutput() ?? '' : '')
    if (!body.trim() || !to?.paneId) {
      notify('warn', 'Nothing to relay from that pane yet.')
      return
    }
    const relayed = `${paneName(fromSlotId)} said:\n\n${body.trim()}`
    const sent = await attempt(() => api.pastePane(to.paneId as Id, relayed))
    if (!sent) return
    // Consumed. The next relay from this pane should offer its next answer,
    // not the selection that has already been sent.
    if (from?.paneId) forgetSelection(from.paneId)
    setFocusedSlot(toSlotId)
    notify('info', `Relayed to ${paneName(toSlotId)}.`)
  }

  const runSkillOnSlot = async (slotId: Id, skill: Skill): Promise<void> => {
    const slot = slots[slotId]
    if (!slot) return
    // A room takes a skill as what the person said — the prompt lands on the
    // transcript as their turn. Checked before the paneId guard below, which a
    // room can never satisfy and which used to tell you to start something
    // that was already running.
    if (slot.kind === 'room') {
      if (!slot.roomId) {
        notify('warn', 'Start this room before sending a skill to it.')
        return
      }
      const done = await attempt(() => api.runSkillInRoom(slot.roomId as Id, skill.id))
      if (done) notify('info', `Sent “${skill.name}” to the room.`)
      return
    }
    if (!slot.paneId) {
      notify('warn', 'Start this pane before sending a skill to it.')
      return
    }
    if (slot.kind === 'shell') {
      notify('warn', `“${skill.name}” is a prompt — drop it on an agent pane or a room.`)
      return
    }
    const done = await attempt(() => api.runSkill(slot.paneId as Id, skill.id))
    if (done) notify('info', `Sent “${skill.name}” to ${KIND_LABEL[slot.kind]}.`)
  }

  return (
    <div className="grid-surface">
      <div className="bar">
        <span className="label" style={{ flexShrink: 0 }}>
          New panes in
        </span>

        <Menu
          title={cwd || 'No folder chosen yet'}
          label={
            <>
              <FolderOpen size={12} strokeWidth={2} />
              {cwd ? shortPath(cwd) : 'Choose folder'}
            </>
          }
        >
          {(close) => (
            <>
              {recentFolders.map((folder) => (
                <div className="menu__row" key={folder}>
                  <MenuItem
                    selected={folder === cwd}
                    onClick={() => {
                      setCwd(folder)
                      close()
                    }}
                  >
                    {shortPath(folder)}
                  </MenuItem>
                  {picked.includes(folder) ? (
                    <button
                      className="menu__row-x"
                      title={`Forget ${folder}`}
                      aria-label={`Forget ${folder}`}
                      onClick={(event) => {
                        // A list edit, not a navigation: the menu stays open so
                        // several can go in one visit.
                        event.stopPropagation()
                        void forgetFolder(folder)
                      }}
                    >
                      <X size={11} strokeWidth={2} />
                    </button>
                  ) : null}
                </div>
              ))}
              <MenuItem
                onClick={() => {
                  close()
                  void chooseFolder()
                }}
              >
                Choose another folder…
              </MenuItem>
              <MenuSection>
                Only affects panes opened from this toolbar. Open panes keep the folder they
                started in, and a split inherits its neighbour&rsquo;s.
              </MenuSection>
            </>
          )}
        </Menu>

        <div className="divider" style={{ width: 1, height: 18, background: 'var(--line)' }} />

        {SLOT_KINDS.map((kind) => (
          <button
            key={kind}
            className="btn btn--sm"
            disabled={!cwd || slotCount >= MAX_PANES}
            onClick={() => void openPane(kind)}
            title={`New ${KIND_LABEL[kind]} pane`}
          >
            <Plus size={12} strokeWidth={2} />
            {KIND_LABEL[kind]}
          </button>
        ))}

        {agentPaneCount > 0 ? (
          <button
            className="btn btn--sm"
            onClick={() => setBroadcasting(true)}
            title="Type one prompt into every running agent pane"
          >
            <Radio size={12} strokeWidth={2} />
            Broadcast
          </button>
        ) : null}

        <button
          className="btn btn--sm"
          onClick={() => setRoster(true)}
          title="Named ways of configuring a seat"
        >
          <Users size={12} strokeWidth={2} />
          Roster
        </button>

        {finding !== null && focusedSlot ? (
          <input
            className="input"
            style={{ width: 180, height: 24, fontSize: 'var(--text-small)' }}
            autoFocus
            placeholder="Find in pane… (⏎ next, ⇧⏎ prev)"
            value={finding}
            onChange={(event) => {
              const query = event.target.value
              setFinding(query)
              const paneId = slots[focusedSlot]?.paneId
              if (paneId && query) termAccess(paneId)?.findNext(query)
            }}
            onKeyDown={(event) => {
              const paneId = slots[focusedSlot]?.paneId
              if (event.key === 'Escape') {
                if (paneId) termAccess(paneId)?.clearSearch()
                setFinding(null)
              } else if (event.key === 'Enter' && paneId && finding) {
                if (event.shiftKey) termAccess(paneId)?.findPrevious(finding)
                else termAccess(paneId)?.findNext(finding)
              }
            }}
          />
        ) : null}

        <div className="divider" style={{ width: 1, height: 18, background: 'var(--line)' }} />

        <Menu
          title="Arrange the open panes into even columns"
          label={
            <>
              <Grid2x2 size={12} strokeWidth={2} />
              Arrange
            </>
          }
        >
          {(close) => (
            <>
              <MenuItem
                onClick={() => {
                  close()
                  arrange('auto')
                }}
              >
                Auto ({autoColumns(slotCount)} column{autoColumns(slotCount) === 1 ? '' : 's'})
              </MenuItem>
              {[1, 2, 3, 4].map((cols) => (
                <MenuItem
                  key={cols}
                  onClick={() => {
                    close()
                    arrange(cols)
                  }}
                >
                  {cols} column{cols === 1 ? '' : 's'}
                </MenuItem>
              ))}
              <MenuSection>
                Rearranges what is already open — no pane is started or stopped.
                Splitting by hand still works; this never runs on its own.
              </MenuSection>
            </>
          )}
        </Menu>

        <Menu
          title="Saved layouts"
          label={
            <>
              <Layers size={12} strokeWidth={2} />
              Layouts
            </>
          }
        >
          {(close) => (
            <>
              {layouts.map((saved) => (
                <MenuItem
                  key={saved.id}
                  onClick={() => {
                    close()
                    void openLayout(saved)
                  }}
                >
                  {saved.name}
                </MenuItem>
              ))}
              <MenuItem
                onClick={() => {
                  close()
                  if (!layout) notify('warn', 'There is nothing to save yet.')
                  else setSaving(true)
                }}
              >
                Save this layout…
              </MenuItem>
              {layouts.length ? (
                <MenuSection>
                  Opening a layout restores its shells and leaves agent panes ready to start, so no
                  CLI session begins without you asking.
                </MenuSection>
              ) : (
                <MenuSection>
                  No saved layouts yet. Saving keeps the arrangement and each pane&rsquo;s folder.
                </MenuSection>
              )}
            </>
          )}
        </Menu>

        <div className="spacer" />

        {activeFolders.length > 1 ? (
          <Chip tone="chip--accent" title={activeFolders.join('\n')}>
            {activeFolders.length} folders
          </Chip>
        ) : null}

        <span className="dimmer tnum" style={{ fontSize: 'var(--text-tiny)' }}>
          {slotCount} / {MAX_PANES} panes
        </span>
      </div>

      <div className="grid-canvas">
        {layout ? (
          <LayoutView
            node={layout}
            path={[]}
            slots={slots}
            focusedSlot={focusedSlot}
            dropTarget={dropTarget}
            paneTitle={(id) => {
              const slot = slots[id]
              return slotPaneTitle(slot, slot?.paneId ? paneById.get(slot.paneId) : undefined)
            }}
            paneStatus={(id) => {
              const slot = slots[id]
              return slotPaneStatus(slot, slot?.paneId ? paneById.get(slot.paneId) : undefined)
            }}
            paneExit={(id) => {
              const slot = slots[id]
              return slotPaneExit(slot, slot?.paneId ? paneById.get(slot.paneId) : undefined)
            }}
            maximizedSlot={maximizedSlot}
            paneIdentity={(id) => {
              const dir = slots[id]?.cwd
              return dir ? identities[dir] : null
            }}
            unread={(id) => unreadSlots.has(id)}
            onOutput={markOutput}
            paneMenu={(id) => {
              const slot = slots[id]
              if (!slot) return null
              const status = slotPaneStatus(slot, slot.paneId ? paneById.get(slot.paneId) : undefined)
              const running = status === 'live' || status === 'starting'
              return (
                <Menu label={<MoreHorizontal size={12} strokeWidth={2} />} title="Pane actions">
                  {(close) => (
                    <>
                      <MenuSection>
                        {/* A room has no process to stop, restart or resume —
                            only a conversation, which the pane itself owns.
                            Offering the process verbs here would render
                            controls that quietly do nothing. */}
                        {slot.kind === 'room' ? (
                          // A room has no process to stop, restart or resume.
                          // Reopening is offered whether or not this slot
                          // already holds one: opening a Room from the toolbar
                          // mints a fresh one immediately, so gating this on
                          // an empty slot made it unreachable in practice.
                          <>
                            {!slot.roomId ? (
                              <MenuItem onClick={() => { close(); void startSlot(id) }}>
                                Start a new room
                              </MenuItem>
                            ) : null}
                            <MenuItem onClick={() => { close(); setReopening(id) }}>
                              Reopen a room…
                            </MenuItem>
                          </>
                        ) : (
                          <>
                        {running ? (
                          <MenuItem onClick={() => { close(); stopSlot(id) }}>
                            Stop — keep the pane
                          </MenuItem>
                        ) : null}
                        {running ? (
                          <MenuItem onClick={() => { close(); void relaunchSlot(id) }}>
                            Restart
                          </MenuItem>
                        ) : null}
                        {!running && slot.paneId ? (
                          <MenuItem onClick={() => { close(); void relaunchSlot(id) }}>
                            Reopen
                          </MenuItem>
                        ) : null}
                        {!running && !slot.paneId ? (
                          <MenuItem onClick={() => { close(); void startSlot(id) }}>
                            Start
                          </MenuItem>
                        ) : null}
                        {RESUME_PICKER_KINDS.includes(slot.kind) && !running ? (
                          <MenuItem
                            onClick={() => {
                              close()
                              // The CLI's own picker, in the pane. Governed
                              // resume ids never reach the Grid.
                              void (slot.paneId ? relaunchSlot(id, { resume: true }) : startSlot(id, { resume: true }))
                            }}
                          >
                            Resume a session…
                          </MenuItem>
                        ) : null}
                          </>
                        )}
                      </MenuSection>
                      {slot.kind !== 'room' && slot.paneId ? (
                        <MenuSection>
                          {/*
                            The relay. Every pane has registered a selection
                            accessor since the find bar landed and nothing has
                            ever called it — meanwhile the loop this app exists
                            for was somebody copying an answer out of one CLI
                            and pasting it into another by hand.

                            Read at open time, not at render: a menu built
                            before the drag would offer a stale selection.
                          */}
                          {(() => {
                            const term = termAccess(slot.paneId as Id)
                            const selection = paneSelection(slot.paneId as Id)
                            const output = term?.lastOutput() ?? ''
                            const state = relayState({
                              targets: relayTargets(id).length,
                              selection,
                              lastOutput: output,
                            })
                            if (state === 'no-targets') {
                              return <div className="menu__note">Open another agent pane to relay into.</div>
                            }
                            if (state === 'nothing') {
                              // ⌥ is named because a CLI that claims the mouse
                              // — Claude Code does — leaves a plain drag going
                              // to the application, which highlights its own
                              // text and looks selected.
                              return (
                                <div className="menu__note">
                                  Nothing to relay yet. Ask this CLI something, or select text —
                                  hold ⌥ while dragging if it captures the mouse.
                                </div>
                              )
                            }
                            const sending = state === 'selection' ? selection : output
                            const label = state === 'selection' ? 'selection' : 'last answer'
                            return (
                              <>
                                {/*
                                  What will be sent, in the menu. Neither source
                                  is visible as such — a selection may have lost
                                  its highlight, and the last answer was never
                                  highlighted at all — so relaying without
                                  showing it would be relaying a guess.
                                */}
                                <div className="menu__note" title={sending}>
                                  “{sending.trim().replace(/\s+/g, ' ').slice(0, 60)}
                                  {sending.trim().length > 60 ? '…' : ''}”
                                </div>
                                {relayTargets(id).map((target) => (
                                  <MenuItem
                                    key={target.slotId}
                                    onClick={() => {
                                      close()
                                      void relay(id, target.slotId)
                                    }}
                                  >
                                    Send {label} to {target.name}
                                  </MenuItem>
                                ))}
                              </>
                            )
                          })()}
                        </MenuSection>
                      ) : null}
                      {slot.cwd && relayTargets(id).length > 0 ? (
                        <MenuSection>
                          {/* Its own section, not part of the relay one above:
                              that block refuses when a pane has said nothing
                              yet, and what an agent has *done* is worth sending
                              whether or not it has spoken. */}
                          <div className="menu__note">
                            Send this folder&rsquo;s uncommitted diff for a second opinion.
                          </div>
                          {relayTargets(id).map((target) => (
                            <MenuItem
                              key={`changes-${target.slotId}`}
                              onClick={() => {
                                close()
                                void relayChanges(id, target.slotId)
                              }}
                            >
                              Send changes to {target.name}
                            </MenuItem>
                          ))}
                        </MenuSection>
                      ) : null}
                      <MenuSection>
                        <MenuItem
                          onClick={() => {
                            close()
                            setMaximizedSlot((current) => (current === id ? null : id))
                          }}
                        >
                          {maximizedSlot === id ? 'Restore size (⌘⏎)' : 'Maximize (⌘⏎)'}
                        </MenuItem>
                        <MenuItem
                          onClick={() => {
                            close()
                            const other = nextSlot(layout, id)
                            if (other && other !== id) {
                              setLayout((current) => (current ? swapLeaves(current, id, other) : current))
                            }
                          }}
                        >
                          Swap with next pane
                        </MenuItem>
                        <MenuItem
                          onClick={() => { close(); setRenaming({ slotId: id, value: slot.title ?? '' }) }}
                        >
                          Rename…
                        </MenuItem>
                        <MenuItem
                          onClick={() => { close(); void openPane(slot.kind, { slotId: id, direction: 'row' }, slot.title) }}
                        >
                          Duplicate
                        </MenuItem>
                        {PANE_KINDS.filter((kind) => kind !== slot.kind).map((kind) => (
                          <MenuItem
                            key={kind}
                            onClick={() => { close(); void relaunchSlot(id, { kind }) }}
                          >
                            Replace with {KIND_LABEL[kind]}
                          </MenuItem>
                        ))}
                      </MenuSection>
                      <MenuSection>
                        {slot.roomId ? (
                          <MenuItem
                            onClick={() => {
                              close()
                              const roomId = slot.roomId
                              if (!roomId) return
                              // Read from main rather than the pane's state:
                              // the record is there, and until rooms persist
                              // this file is the only copy that survives quit.
                              void attempt(async () => {
                                const room = await api.getRoom(roomId)
                                if (!room || room.turns.length === 0) {
                                  notify('warn', 'Nothing said in this room yet.')
                                  return null
                                }
                                const label = (slot.title ?? basenameOf(slot.cwd)).replace(/[^\w-]+/g, '-')
                                return api.savePaneTranscript(
                                  `ROOM-${label}.md`,
                                  roomTranscript(room),
                                )
                              }).then((result) => {
                                if (result?.saved && result.path) {
                                  notify('info', `Transcript saved to ${result.path}`)
                                }
                              })
                            }}
                          >
                            Save transcript…
                          </MenuItem>
                        ) : slot.paneId ? (
                          <MenuItem
                            onClick={() => {
                              close()
                              const paneId = slot.paneId
                              if (!paneId) return
                              const text = termAccess(paneId)?.serialize() ?? ''
                              if (!text.trim()) {
                                notify('warn', 'Nothing in the buffer yet.')
                                return
                              }
                              const label = (slot.title ?? KIND_LABEL[slot.kind]).replace(/[^\w-]+/g, '-')
                              void attempt(() => api.savePaneTranscript(`PANE-${label}.txt`, text)).then(
                                (result) => {
                                  if (result?.saved && result.path) {
                                    notify('info', `Transcript saved to ${result.path}`)
                                  }
                                },
                              )
                            }}
                          >
                            Save transcript…
                          </MenuItem>
                        ) : null}
                      </MenuSection>
                    </>
                  )}
                </Menu>
              )
            }}
            onFocus={setFocusedSlot}
            onClose={closeSlot}
            onStart={(id) => void startSlot(id)}
            onSplit={(slotId, direction) => void openPane('shell', { slotId, direction })}
            onRatio={(path, ratio) => setLayout((current) => (current ? setRatio(current, path, ratio) : current))}
            onDropTarget={setDropTarget}
            onReopenRoom={setReopening}
            onSkillDrop={(slotId) => {
              const skill = draggingSkill.current
              setDropTarget(null)
              draggingSkill.current = null
              if (skill) void runSkillOnSlot(slotId, skill)
            }}
          />
        ) : (
          <Empty
            title="No panes open"
            body={
              cwd
                ? 'Open a shell, or an interactive agent session — every CLI in the toolbar. Split with ⌘D, close with ⌘W, cycle with ⌘]. Panes can live in different folders — each keeps the one it started in.'
                : 'Choose a folder, then open a shell or an interactive agent session in it. You can work across several folders at once.'
            }
            action={
              cwd ? (
                <div className="row">
                  <button className="btn" onClick={() => void openPane('claude')}>
                    <Terminal size={12} strokeWidth={2} />
                    Open Claude
                  </button>
                  <button className="btn" onClick={() => void openPane('codex')}>
                    <Terminal size={12} strokeWidth={2} />
                    Open Codex
                  </button>
                </div>
              ) : (
                <button className="btn btn--primary" onClick={() => void chooseFolder()}>
                  <FolderOpen size={12} strokeWidth={2} />
                  Choose folder
                </button>
              )
            }
          />
        )}
      </div>

      <div className="skill-rail">
        <span className="label" style={{ flexShrink: 0, marginRight: 'var(--s2)' }}>
          Skills
        </span>
        {state.skills.length === 0 ? (
          <span className="dimmer" style={{ fontSize: 'var(--text-tiny)' }}>
            No skills yet.
          </span>
        ) : (
          state.skills.map((skill) => (
            <div
              key={skill.id}
              className="skill"
              draggable
              title={skill.description || skill.name}
              onDragStart={() => {
                draggingSkill.current = skill
              }}
              onDragEnd={() => {
                draggingSkill.current = null
                setDropTarget(null)
              }}
              onDoubleClick={() => {
                if (focusedSlot) void runSkillOnSlot(focusedSlot, skill)
                else notify('warn', 'Focus a pane first, or drag the skill onto one.')
              }}
            >
              {skill.name}
            </div>
          ))
        )}
        <div className="spacer" />
        <span className="dimmer" style={{ fontSize: 'var(--text-micro)', flexShrink: 0 }}>
          Drag onto an agent pane or a room
        </span>
      </div>

      {broadcasting ? (
        <BroadcastDialog
          count={agentPaneCount}
          onClose={() => setBroadcasting(false)}
          onSend={(text) => {
            setBroadcasting(false)
            // The same keystrokes-into-the-session shape as a Skill: flattened
            // newlines, one carriage return, into every running agent pane.
            for (const slot of agentPanes) {
              if (slot.paneId) {
                void api.writePane(slot.paneId, `${text.replace(/\r?\n/g, ' ')}\r`)
              }
            }
            notify('info', `Sent to ${agentPaneCount} agent pane${agentPaneCount === 1 ? '' : 's'}.`)
          }}
        />
      ) : null}

      {roster ? <RosterDialog onClose={() => setRoster(false)} /> : null}

      {reopening ? (
        <ReopenRoomDialog
          onClose={() => setReopening(null)}
          onPick={(roomId) => {
            const slotId = reopening
            setReopening(null)
            const previous = slots[slotId]?.roomId
            void attempt(() => api.reopenRoom(roomId)).then((room) => {
              if (!room) return
              // Let go of whatever this slot held. The record keeps it, and a
              // room opened by accident and never spoken in is swept at
              // startup rather than accumulating.
              if (previous && previous !== room.id) {
                void api.closeRoom(previous).catch(() => undefined)
              }
              setSlots((current) => {
                const slot = current[slotId]
                return slot ? { ...current, [slotId]: { ...slot, roomId: room.id } } : current
              })
              setFocusedSlot(slotId)
            })
          }}
        />
      ) : null}

      {renaming ? (
        <Dialog
          title="Rename pane"
          onClose={() => setRenaming(null)}
          footer={
            <>
              <button className="btn" onClick={() => setRenaming(null)}>
                Cancel
              </button>
              <button className="btn btn--primary" onClick={commitRename}>
                Rename
              </button>
            </>
          }
        >
          <Field label="Name" hint="Empty restores the automatic kind-and-folder title. Names ride saved layouts.">
            <input
              className="input"
              autoFocus
              value={renaming.value}
              onChange={(event) => setRenaming({ ...renaming, value: event.target.value })}
              onKeyDown={(event) => {
                if (event.key === 'Enter') commitRename()
              }}
            />
          </Field>
        </Dialog>
      ) : null}

      {saving ? (
        <SaveLayoutDialog
          suggested={cwd ? shortPath(cwd).split('/').pop() ?? 'Layout' : 'Layout'}
          existing={layouts}
          onClose={() => setSaving(false)}
          onSave={async (name) => {
            const tree = toSavedLayout(layout, slots)
            if (!tree) {
              notify('warn', 'There is nothing to save yet.')
              return
            }
            const saved = await attempt(() => api.saveLayout({ name, defaultFolder: cwd, tree }))
            if (saved) {
              notify('info', `Saved “${saved.name}”.`)
              void refreshLayouts()
            }
            setSaving(false)
          }}
        />
      ) : null}
    </div>
  )
}

function SaveLayoutDialog({
  suggested,
  existing,
  onClose,
  onSave,
}: {
  suggested: string
  existing: GridLayout[]
  onClose: () => void
  onSave: (name: string) => void | Promise<void>
}): ReactNode {
  const [name, setName] = useState(suggested)
  const clash = existing.some((l) => l.name === name.trim())

  return (
    <Dialog
      title="Save this layout"
      subtitle="Keeps the arrangement, each pane's kind, and the folder it runs in."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--primary" disabled={!name.trim()} onClick={() => void onSave(name.trim())}>
            {clash ? 'Replace' : 'Save'}
          </button>
        </>
      }
    >
      <Field
        label="Name"
        hint={clash ? `A layout called “${name.trim()}” already exists and will be replaced.` : undefined}
      >
        <input
          className="input"
          autoFocus
          value={name}
          onChange={(event) => setName(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && name.trim()) void onSave(name.trim())
          }}
        />
      </Field>
      <div className="field__hint">
        Reopening restores the shells straight away. Claude and Codex panes come back as
        placeholders you start with one click, so no CLI session begins on your subscription
        without you asking.
      </div>
    </Dialog>
  )
}

interface LayoutViewProps {
  node: LayoutNode
  path: SplitPath
  slots: Record<Id, Slot>
  focusedSlot: Id | null
  dropTarget: Id | null
  paneTitle: (id: Id) => string
  paneStatus: (id: Id) => 'idle' | 'starting' | 'live' | 'exited'
  paneExit: (id: Id) => number | null
  paneMenu: (id: Id) => ReactNode
  paneIdentity: (id: Id) => PaneIdentity | null | undefined
  unread: (id: Id) => boolean
  maximizedSlot: Id | null
  onOutput: (id: Id) => void
  onFocus: (id: Id) => void
  onClose: (id: Id) => void
  onStart: (id: Id) => void
  onSplit: (id: Id, direction: 'row' | 'column') => void
  onRatio: (path: SplitPath, ratio: number) => void
  onDropTarget: (id: Id | null) => void
  onSkillDrop: (id: Id) => void
  onReopenRoom: (id: Id) => void
}

function BroadcastDialog({
  count,
  onClose,
  onSend,
}: {
  count: number
  onClose: () => void
  onSend: (text: string) => void
}): ReactNode {
  const [text, setText] = useState('')
  return (
    <Dialog
      title="Broadcast to agent panes"
      subtitle={`Types one prompt into all ${count} running agent pane${count === 1 ? '' : 's'} and submits it — exactly as if you had typed it in each.`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            disabled={!text.trim()}
            onClick={() => onSend(text.trim())}
          >
            Send to {count}
          </button>
        </>
      }
    >
      <Field label="Prompt" hint="Newlines are flattened — the CLIs treat them as submit.">
        <textarea
          className="input"
          rows={4}
          autoFocus
          value={text}
          onChange={(event) => setText(event.target.value)}
        />
      </Field>
    </Dialog>
  )
}

/**
 * The identity line: branch · dirty · drift from upstream, and — when the
 * folder IS a registered plan worktree — a chip that says landed or unlanded
 * and opens the plan. It never says "safe to remove"; landing is the plan's
 * record, disposal is the human's call.
 */
function PaneIdentityChips({ identity }: { identity: PaneIdentity | null | undefined }): ReactNode {
  if (!identity) return null
  const drift = identity.ahead || identity.behind ? ` ↑${identity.ahead}↓${identity.behind}` : ''
  const state = identity.dirty ? 'uncommitted changes' : 'clean'
  return (
    <Chip tone="chip--mono" title={`${identity.branch} — ${state}`}>
      {identity.branch}
      {identity.dirty ? '±' : ''}
      {drift}
    </Chip>
  )
}

function LayoutView(props: LayoutViewProps): ReactNode {
  const { node, path } = props

  if (node.type === 'leaf') {
    const id = node.slotId
    const slot = props.slots[id]
    const status = props.paneStatus(id)
    const exitCode = props.paneExit(id)
    const focused = props.focusedSlot === id
    const isDrop = props.dropTarget === id

    return (
      <div
        className={`pane ${focused ? 'is-focused' : ''} ${isDrop ? 'is-drop-target' : ''} ${props.maximizedSlot === id ? 'is-maximized' : ''}`}
        onDragOver={(event) => {
          event.preventDefault()
          props.onDropTarget(id)
        }}
        onDragLeave={() => props.onDropTarget(null)}
        onDrop={(event) => {
          event.preventDefault()
          props.onSkillDrop(id)
        }}
      >
        <div className="pane__chrome" onMouseDown={() => props.onFocus(id)}>
          <Dot
            tone={status === 'live' ? 'dot--live' : status === 'exited' ? 'dot--fail' : ''}
            title={status}
          />
          <span className="pane__title" title={slot?.cwd}>
            {props.paneTitle(id)}
          </span>
          <PaneIdentityChips identity={props.paneIdentity(id)} />
          {props.unread(id) && !focused ? (
            <Dot tone="dot--accent" title="new output since you last looked" />
          ) : null}
          {status === 'exited' ? (
            <Chip tone={exitCode === 0 ? '' : 'chip--fail'}>exit {exitCode ?? '?'}</Chip>
          ) : null}
          {props.paneMenu(id)}
          <button
            className="btn btn--subtle btn--icon btn--sm"
            title="Split right (⌘D)"
            onClick={() => props.onSplit(id, 'row')}
          >
            <Columns2 size={12} strokeWidth={2} />
          </button>
          <button
            className="btn btn--subtle btn--icon btn--sm"
            title="Split down (⌘⇧D)"
            onClick={() => props.onSplit(id, 'column')}
          >
            <Rows2 size={12} strokeWidth={2} />
          </button>
          <button
            className="btn btn--subtle btn--icon btn--sm"
            title="Close pane (⌘W)"
            onClick={() => props.onClose(id)}
          >
            <X size={12} strokeWidth={2} />
          </button>
        </div>

        {slot?.roomId ? (
          <RoomPane
            roomId={slot.roomId}
            focused={focused}
            onFocus={() => props.onFocus(id)}
            onOutput={() => props.onOutput(id)}
            onReopen={() => props.onReopenRoom(id)}
          />
        ) : slot?.paneId ? (
          <TerminalPane
            paneId={slot.paneId}
            focused={focused}
            onFocus={() => props.onFocus(id)}
            onOutput={() => props.onOutput(id)}
          />
        ) : (
          <div className="pane__idle">
            <div className="pane__idle-title">{slot ? KIND_LABEL[slot.kind] : 'Pane'} not started</div>
            <div className="pane__idle-body">{slot ? shortPath(slot.cwd) : ''}</div>
            <button className="btn btn--primary btn--sm" onClick={() => props.onStart(id)}>
              <Play size={12} strokeWidth={2} />
              Start {slot ? KIND_LABEL[slot.kind] : 'pane'}
            </button>
          </div>
        )}
      </div>
    )
  }

  return (
    <div className={node.direction === 'column' ? 'split split--column' : 'split'}>
      <div style={{ flex: `${node.ratio} 1 0`, display: 'flex', minWidth: 0, minHeight: 0 }}>
        <LayoutView {...props} node={node.a} path={[...path, 'a']} />
      </div>
      <Handle direction={node.direction} onDrag={(fraction) => props.onRatio(path, fraction)} />
      <div style={{ flex: `${1 - node.ratio} 1 0`, display: 'flex', minWidth: 0, minHeight: 0 }}>
        <LayoutView {...props} node={node.b} path={[...path, 'b']} />
      </div>
    </div>
  )
}

/**
 * Split handle.
 *
 * Reports the pointer position as a fraction of the *parent* split's box, so the
 * ratio follows the cursor exactly rather than accumulating drift from deltas.
 */
function Handle({
  direction,
  onDrag,
}: {
  direction: 'row' | 'column'
  onDrag: (fraction: number) => void
}): ReactNode {
  const [dragging, setDragging] = useState(false)

  return (
    <div
      className={`split__handle ${dragging ? 'is-dragging' : ''}`}
      onMouseDown={(event) => {
        event.preventDefault()
        const parent = event.currentTarget.parentElement
        if (!parent) return
        const box = parent.getBoundingClientRect()
        setDragging(true)

        const move = (e: MouseEvent): void => {
          const fraction =
            direction === 'row'
              ? (e.clientX - box.left) / box.width
              : (e.clientY - box.top) / box.height
          onDrag(fraction)
        }
        const up = (): void => {
          setDragging(false)
          window.removeEventListener('mousemove', move)
          window.removeEventListener('mouseup', up)
        }
        window.addEventListener('mousemove', move)
        window.addEventListener('mouseup', up)
      }}
    />
  )
}

/**
 * Rooms in the record, for putting one back in a slot.
 *
 * Saved layouts deliberately do NOT carry a room id — a layout describes what
 * each pane IS, not which conversation it held, and minting fresh slots is the
 * rule that keeps a restored arrangement from resurrecting dead process ids.
 * So reopening is its own act: you pick the conversation you meant.
 */
function ReopenRoomDialog({
  onClose,
  onPick,
}: {
  onClose: () => void
  onPick: (roomId: Id) => void
}): ReactNode {
  const [rooms, setRooms] = useState<Room[] | null>(null)

  useEffect(() => {
    let cancelled = false
    void api
      .listRooms()
      .then((rows) => {
        if (!cancelled) setRooms(Array.isArray(rows) ? rows : [])
      })
      .catch(() => {
        if (!cancelled) setRooms([])
      })
    return () => {
      cancelled = true
    }
  }, [])

  return (
    <Dialog title="Reopen a room" subtitle="Its transcript comes back; no seat starts." onClose={onClose}>
      {rooms === null ? (
        <Empty title="Reading the record…" compact />
      ) : rooms.length === 0 ? (
        <Empty title="No rooms recorded yet" body="Open one and say something." compact />
      ) : (
        <div className="stack stack--tight">
          {rooms.map((room) => (
            <button key={room.id} className="row-button" onClick={() => onPick(room.id)}>
              <span className="spacer" style={{ textAlign: 'left' }}>
                {shortPath(room.cwd)}
                {room.mock ? ' · mock' : ''}
              </span>
              <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
                {room.seats.map((seat) => `@${seat.name}`).join(' ')}
              </span>
            </button>
          ))}
        </div>
      )}
    </Dialog>
  )
}
