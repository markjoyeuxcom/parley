import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { Columns2, FolderOpen, Layers, Play, Plus, Rows2, Terminal, X } from 'lucide-react'
import {
  MAX_PANES,
  type GridLayout,
  type Id,
  type LayoutNode,
  type PaneKind,
  type Skill,
} from '@shared/domain'
import { api } from '../lib/api'
import { forgetPane } from '../lib/ptyBuffer'
import {
  collectSlotIds,
  countSlots,
  fromSavedLayout,
  leaf,
  nextSlot,
  removeLeaf,
  setRatio,
  splitLeaf,
  toSavedLayout,
  type Slot,
  type SplitPath,
} from '../lib/layout'
import { shortPath } from '../lib/format'
import { useStore } from '../state'
import { TerminalPane } from '../components/TerminalPane'
import { Chip, Dialog, Dot, Empty, Field, Menu, MenuItem, MenuSection } from '../components/ui'

const KIND_LABEL: Record<PaneKind, string> = {
  shell: 'Shell',
  claude: 'Claude',
  codex: 'Codex',
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
  const { state, notify, attempt } = useStore()
  const [layout, setLayout] = useState<LayoutNode | null>(null)
  const [slots, setSlots] = useState<Record<Id, Slot>>({})
  const [focusedSlot, setFocusedSlot] = useState<Id | null>(null)
  const [cwd, setCwd] = useState('')
  const [dropTarget, setDropTarget] = useState<Id | null>(null)
  const [picked, setPicked] = useState<string[]>([])
  const [layouts, setLayouts] = useState<GridLayout[]>([])
  const [saving, setSaving] = useState(false)
  const draggingSkill = useRef<Skill | null>(null)

  const slotCount = countSlots(layout)
  const paneById = useMemo(() => new Map(state.panes.map((p) => [p.id, p])), [state.panes])

  const refreshLayouts = useCallback(async () => {
    const saved = await attempt(() => api.listLayouts())
    if (saved) setLayouts(saved)
  }, [attempt])

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

  /** Starts the process for a slot that has none. */
  const startSlot = useCallback(
    async (slotId: Id): Promise<void> => {
      const slot = slots[slotId]
      if (!slot || slot.paneId) return
      const pane = await attempt(() => api.openPane(slot.kind, slot.cwd, 80, 24))
      if (!pane) return
      setSlots((current) => ({ ...current, [slotId]: { ...slot, paneId: pane.id } }))
      setFocusedSlot(slotId)
    },
    [attempt, slots],
  )

  const openPane = useCallback(
    async (kind: PaneKind, splitFrom?: { slotId: Id; direction: 'row' | 'column' }) => {
      if (slotCount >= MAX_PANES) {
        notify('warn', `The grid holds at most ${MAX_PANES} panes.`)
        return
      }
      // A split inherits the folder of the pane it grew out of. Using the
      // toolbar's target instead would silently drop you into a different
      // repository than the pane you were just working in.
      const inherited = splitFrom ? slots[splitFrom.slotId]?.cwd : null
      const dir = (inherited ?? cwd).trim()
      if (!dir) {
        notify('warn', 'Choose a folder first.')
        return
      }
      const pane = await attempt(() => api.openPane(kind, dir, 80, 24))
      if (!pane) return

      const slotId = mintSlotId()
      setSlots((current) => ({ ...current, [slotId]: { kind, cwd: dir, paneId: pane.id } }))
      setLayout((current) => {
        if (!current) return leaf(slotId)
        if (splitFrom) return splitLeaf(current, splitFrom.slotId, splitFrom.direction, slotId)
        const target = focusedSlot ?? collectSlotIds(current)[0]
        if (!target) return leaf(slotId)
        return splitLeaf(current, target, 'row', slotId)
      })
      setFocusedSlot(slotId)
    },
    [attempt, cwd, focusedSlot, notify, slotCount, slots],
  )

  const closeSlot = useCallback(
    (slotId: Id) => {
      const paneId = slots[slotId]?.paneId
      if (paneId) {
        void api.closePane(paneId).catch(() => undefined)
        forgetPane(paneId)
      }
      setSlots((current) => {
        const next = { ...current }
        delete next[slotId]
        return next
      })
      setLayout((current) => (current ? removeLeaf(current, slotId) : null))
      setFocusedSlot((current) => (current === slotId ? null : current))
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
        const pane = await attempt(() => api.openPane(slot.kind, slot.cwd, 80, 24))
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

  // ⌘D splits right, ⌘⇧D splits down, ⌘W closes, ⌘] cycles.
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

        {(['shell', 'claude', 'codex'] as PaneKind[]).map((kind) => (
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
              if (!slot) return 'pane'
              const pane = slot.paneId ? paneById.get(slot.paneId) : undefined
              return pane?.title ?? `${KIND_LABEL[slot.kind]} — ${shortPath(slot.cwd)}`
            }}
            paneStatus={(id) => {
              const slot = slots[id]
              if (!slot?.paneId) return 'idle'
              return paneById.get(slot.paneId)?.status ?? 'starting'
            }}
            paneExit={(id) => {
              const slot = slots[id]
              return slot?.paneId ? (paneById.get(slot.paneId)?.exitCode ?? null) : null
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
                ? 'Open a shell, or an interactive Claude or Codex session. Split with ⌘D, close with ⌘W, cycle with ⌘]. Panes can live in different folders — each keeps the one it started in.'
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
  onFocus: (id: Id) => void
  onClose: (id: Id) => void
  onStart: (id: Id) => void
  onSplit: (id: Id, direction: 'row' | 'column') => void
  onRatio: (path: SplitPath, ratio: number) => void
  onDropTarget: (id: Id | null) => void
  onSkillDrop: (id: Id) => void
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
        className={`pane ${focused ? 'is-focused' : ''} ${isDrop ? 'is-drop-target' : ''}`}
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
          {status === 'exited' ? (
            <Chip tone={exitCode === 0 ? '' : 'chip--fail'}>exit {exitCode ?? '?'}</Chip>
          ) : null}
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

        {slot?.paneId ? (
          <TerminalPane paneId={slot.paneId} focused={focused} onFocus={() => props.onFocus(id)} />
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
