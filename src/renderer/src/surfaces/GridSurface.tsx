import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Columns2, FolderOpen, Layers, MoreHorizontal, Play, Plus, Radio, Rows2, Terminal, Users, X } from 'lucide-react'
import {
  MAX_PANES,
  RESUME_PICKER_KINDS,
  type AgentConfig,
  type GridLayout,
  type Id,
  type LayoutNode,
  type PaneKind,
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
  type Slot,
  type SplitPath,
} from '../lib/layout'
import { shortPath } from '../lib/format'
import { paneSelection, termAccess } from '../lib/termSelection'
import { useStore } from '../state'
import { TerminalPane } from '../components/TerminalPane'
import { RosterDialog } from '../components/RosterDialog'
import { RoomPane } from '../components/RoomPane'
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
  const { state, dispatch, notify, attempt, openPlan } = useStore()
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
  useEffect(() => {
    void attempt(() => api.listPanes()).then((panes) => {
      if (panes) dispatch({ type: 'panes', panes })
    })
  }, [attempt, dispatch])

  useEffect(() => {
    void refreshLayouts()
  }, [refreshLayouts])


  /**
   * Folders worth offering, newest intent first. Drawn from what the user is
   * already working in rather than a stored list.
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
    if (cwd) add(cwd)
    for (const path of picked) add(path)
    for (const slot of Object.values(slots)) add(slot.cwd)
    for (const session of state.sessions) add(session.repoPath)
    for (const loop of state.loops) add(loop.repoPath)
    return out.slice(0, 8)
  }, [cwd, picked, slots, state.sessions, state.loops])

  /** Distinct folders the grid currently spans. */
  const activeFolders = useMemo(
    () => [...new Set(collectSlotIds(layout).map((id) => slots[id]?.cwd).filter((c): c is string => !!c))],
    [layout, slots],
  )

  const liveSlots = useMemo(
    () => collectSlotIds(layout).filter((id) => slots[id]?.paneId),
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
        const room = await attempt(() => api.openRoom(slot.cwd, DEFAULT_ROOM_SEAT))
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
          ? await attempt(() => api.openRoom(slot.cwd, DEFAULT_ROOM_SEAT))
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
          ? await attempt(() => api.openRoom(dir, DEFAULT_ROOM_SEAT))
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

  // Consume the cross-surface knock: another surface asked for a pane here.
  // Guarded on visibility so the hidden Grid never spawns behind your back.
  useEffect(() => {
    const spawn = state.focusGridSpawn
    if (!spawn || state.surface !== 'grid') return
    dispatch({ type: 'focusGridSpawn', spawn: null })
    void openPane(spawn.kind, undefined, undefined, spawn.cwd)
  }, [state.focusGridSpawn, state.surface, dispatch, openPane])

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

  /** Tears the whole grid down. Used before restoring a saved layout. */
  const closeAll = useCallback(() => {
    for (const slot of Object.values(slots)) {
      if (slot.paneId) {
        void api.closePane(slot.paneId).catch(() => undefined)
        forgetPane(slot.paneId)
      }
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
      if (liveSlots.length) {
        const ok = window.confirm(
          `Opening “${saved.name}” closes the ${liveSlots.length} pane${liveSlots.length === 1 ? '' : 's'} currently running. Continue?`,
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
    [attempt, closeAll, liveSlots.length, notify],
  )

  // Default the folder to the last repository the user worked in.
  useEffect(() => {
    if (cwd) return
    const recent = state.sessions.find((s) => s.repoPath)?.repoPath ?? state.loops[0]?.repoPath
    if (recent) setCwd(recent)
  }, [cwd, state.sessions, state.loops])

  // ⌘D splits right, ⌘⇧D splits down, ⌘W closes, ⌘]/⌘[ cycle, ⌘⏎ maximizes.
  useEffect(() => {
    const onKey = (event: KeyboardEvent): void => {
      if (!event.metaKey) return
      // The surface stays mounted while hidden; without this guard ⌘W on a
      // different surface silently closed the focused Grid pane.
      if (state.surface !== 'grid') return
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
  }, [closeSlot, focusedSlot, layout, openPane, state.surface])

  const chooseFolder = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Choose a folder for new panes'))
    if (result?.path) {
      const chosen = result.path
      setCwd(chosen)
      setPicked((current) => [chosen, ...current.filter((p) => p !== chosen)].slice(0, 8))
    }
  }

  const runSkillOnSlot = async (slotId: Id, skill: Skill): Promise<void> => {
    const slot = slots[slotId]
    if (!slot?.paneId) {
      notify('warn', 'Start this pane before sending a skill to it.')
      return
    }
    if (slot.kind === 'shell') {
      notify('warn', `“${skill.name}” is a prompt — drop it on a Claude or Codex pane.`)
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
                <MenuItem
                  key={folder}
                  selected={folder === cwd}
                  onClick={() => {
                    setCwd(folder)
                    close()
                  }}
                >
                  {shortPath(folder)}
                </MenuItem>
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
            onOpenPlan={(identity) => {
              if (!identity.worktree) return
              // The knock-and-consume pattern: the Repos surface owns the
              // plan panel, opened on the worktree's origin repository.
              dispatch({
                type: 'focusBacklogRepo',
                repoPath: identity.worktree.originPath,
                tab: 'plans',
              })
              dispatch({ type: 'surface', surface: 'backlog' })
              void openPlan(identity.worktree.planId)
            }}
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
                          !slot.roomId ? (
                            <MenuItem onClick={() => { close(); void startSlot(id) }}>
                              Start
                            </MenuItem>
                          ) : null
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
                        <MenuItem
                          onClick={() => {
                            close()
                            // Selected terminal text rides along as the brief's
                            // starting matter; nothing selected still opens the
                            // dialog on this pane's repository.
                            const matter = slot.paneId ? paneSelection(slot.paneId) : ''
                            const dir = slots[id]?.cwd ?? slot.cwd
                            const repoRoot = identities[dir]?.git?.root ?? dir
                            dispatch({
                              type: 'focusNewSession',
                              request: { kind: 'review', repoPath: repoRoot, matter },
                            })
                          }}
                        >
                          Review this in Parley…
                        </MenuItem>
                        {slot.paneId ? (
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
          Drag onto an agent pane
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
  onOpenPlan: (identity: PaneIdentity) => void
  onFocus: (id: Id) => void
  onClose: (id: Id) => void
  onStart: (id: Id) => void
  onSplit: (id: Id, direction: 'row' | 'column') => void
  onRatio: (path: SplitPath, ratio: number) => void
  onDropTarget: (id: Id | null) => void
  onSkillDrop: (id: Id) => void
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
function PaneIdentityChips({
  identity,
  onOpenPlan,
}: {
  identity: PaneIdentity | null | undefined
  onOpenPlan: (identity: PaneIdentity) => void
}): ReactNode {
  if (!identity?.git) return null
  const { git } = identity
  const drift =
    git.hasUpstream && (git.ahead || git.behind) ? ` ↑${git.ahead}↓${git.behind}` : ''
  const state = git.dirty ? 'uncommitted changes' : 'clean'
  const upstream = git.hasUpstream
    ? `${git.ahead} ahead / ${git.behind} behind upstream`
    : 'no upstream'
  return (
    <>
      <Chip tone="chip--mono" title={`${git.root} — ${state}, ${upstream}`}>
        {git.branch}
        {git.dirty ? '±' : ''}
        {drift}
      </Chip>
      {identity.worktree ? (
        <button
          className={`chip ${identity.worktree.landed ? '' : 'chip--accent'}`}
          title={`A plan worktree of ${identity.worktree.originPath} — its branch has ${identity.worktree.landed ? 'landed' : 'NOT landed'}. Opens the plan.`}
          onClick={() => onOpenPlan(identity)}
        >
          plan · {identity.worktree.landed ? 'landed' : 'unlanded'}
        </button>
      ) : null}
    </>
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
          <PaneIdentityChips
            identity={props.paneIdentity(id)}
            onOpenPlan={props.onOpenPlan}
          />
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
