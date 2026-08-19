// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import type { Pane, Usage } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import {
  toInvokeResult,
  unwrapInvokeResult,
  type CommandName,
  type InvokeResult,
} from '@shared/ipc'
import { useEffect, type ReactNode } from 'react'
import { StoreProvider, useStore } from '../state'
import { Titlebar } from '../components/Titlebar'
import { CommandPalette } from '../components/CommandPalette'
import { GridSurface } from './GridSurface'
import { registerTerm } from '../lib/termSelection'

/**
 * Mounted-tree smoke tests.
 *
 * The rest of the suite never renders React, which once let a rules-of-hooks
 * violation ship with typecheck clean and every test green — the window went
 * black the moment a detail view loaded. These mount the real surface over a
 * fake IPC bridge and walk the transitions that matter.
 */

const usage: Usage = {
  inputTokens: 10,
  cachedInputTokens: 0,
  outputTokens: 5,
  reasoningTokens: 0,
  costUsd: 0,
}

const claude = {
  vendor: 'claude' as const,
  model: '',
  effort: 'high' as const,
  persona: '',
}
const codex = {
  vendor: 'codex' as const,
  model: '',
  effort: 'high' as const,
  persona: '',
}

let appEventListener: ((event: AppEvent) => void) | null = null

/** The palette, mounted open — it renders nothing while closed. */
function OpenPalette(): ReactNode {
  const { dispatch } = useStore()
  useEffect(() => {
    dispatch({ type: 'palette', open: true })
  }, [dispatch])
  return <CommandPalette actions={[]} />
}

function installBridge(
  overrides: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {},
  failures: Partial<Record<CommandName, string>> = {},
): void {
  const handlers: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {
    'app.info': () => ({
      mock: true,
      codexDefaultModel: '',
      agyModels: ['gemini-real-pro', 'gemini-real-flash-high'],
    }),
    'health.probe': () => [],
    'skill.list': () => [],
    'pane.list': () => [],
    'profile.list': () => [],
    // A prior room seeds the default folder, the way a returning user's
    // record does — without one the toolbar has no cwd and every button
    // that opens something is disabled.
    'room.list': () => [
      {
        id: 'room-prior',
        cwd: '/tmp/smoke-repo',
        seats: [],
        caps: { turns: 40, costUsd: 0 },
        turnsSpent: 0,
        status: 'idle',
        turns: [],
        usage: {
          inputTokens: 0,
          cachedInputTokens: 0,
          outputTokens: 0,
          reasoningTokens: 0,
          costUsd: 0,
        },
        mock: true,
        createdAt: 1_700_000_000_000,
      },
    ],
    'room.verdicts': () => [],
    ...overrides,
  }
  window.parley = {
    invoke: async <T,>(command: CommandName, payload?: unknown): Promise<T> => {
      const failure = failures[command]
      const result: InvokeResult<T> =
        failure === undefined
          ? await toInvokeResult(() => handlers[command]?.(payload) as T | Promise<T>)
          : { ok: false, error: failure }
      return unwrapInvokeResult(result)
    },
    onEvent: (listener) => {
      appEventListener = listener
      return () => {
        if (appEventListener === listener) appEventListener = null
      }
    },
    onPtyData: () => () => {},
    platform: 'darwin',
  }
}

beforeEach(() => {
  installBridge()
  // A real terminal pane needs two browser APIs jsdom does not ship: xterm
  // asks the window for its colour scheme, and the pane watches its own box
  // for resizes. Without both, mounting one throws during render and the whole
  // tree comes back empty — which reads as "the button is missing".
  if (!('ResizeObserver' in globalThis)) {
    ;(globalThis as { ResizeObserver?: unknown }).ResizeObserver = class {
      observe(): void {}
      unobserve(): void {}
      disconnect(): void {}
    }
  }
  {
    window.matchMedia = ((query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addListener: () => undefined,
      removeListener: () => undefined,
      addEventListener: () => undefined,
      removeEventListener: () => undefined,
      dispatchEvent: () => false,
    })) as unknown as typeof window.matchMedia
  }
})
afterEach(() => {
  cleanup()
  appEventListener = null
})

async function assertLedgerGateActionsDisabled(invoked: CommandName[]): Promise<void> {
  const buttons = [
    screen.getByRole('button', { name: 'Approve and run' }),
    await screen.findByRole('button', { name: 'Resume from where it stopped' }),
    await screen.findByRole('button', {
      name: 'Adopt & verify the existing work',
    }),
  ]

  for (const button of buttons) {
    expect((button as HTMLButtonElement).disabled).toBe(true)
    fireEvent.click(button)
    expect(invoked).toEqual([])
  }
}

describe('mounted-surface smoke', () => {
  it('a missing agy gets the neutral dot while a missing required CLI stays red', async () => {
    installBridge({
      'health.probe': () => [
        {
          vendor: 'claude',
          present: true,
          version: '2.1.0',
          authenticated: true,
          detail: 'Signed in.',
        },
        {
          vendor: 'codex',
          present: false,
          version: '',
          authenticated: false,
          detail: 'codex was not found on PATH.',
        },
        {
          vendor: 'agy',
          present: false,
          version: '',
          authenticated: false,
          detail: 'agy was not found on PATH.',
        },
      ],
    })
    render(
      <StoreProvider>
        <Titlebar />
      </StoreProvider>,
    )

    const chip = (vendor: string) => screen.getByTitle(new RegExp(`^${vendor} `))
    await waitFor(() => expect(chip('agy')).toBeTruthy())

    // agy absent is a configuration, not a failure — bare neutral dot, and
    // the tooltip says it is optional. codex absent is still an error.
    expect(chip('agy').querySelector('.dot')?.className).toBe('dot ')
    expect(chip('agy').getAttribute('title')).toContain('optional')
    expect(chip('codex').querySelector('.dot--fail')).toBeTruthy()
    expect(chip('claude').querySelector('.dot--pass')).toBeTruthy()
  })

  it('relays a selection from one CLI pane into another, attributed and pasted', async () => {
    // The loop this app exists for: read Claude's answer, hand it to Codex,
    // hand the reply back. Both halves were already present — every terminal
    // registers a selection accessor, and a pane can be typed into — and
    // nothing joined them, so people did it with ⌘C.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    let opened = 0
    const born: Pane[] = []
    installBridge({
      'pane.open': (payload) => {
        opened += 1
        const kind = (payload as { kind: string }).kind as Pane['kind']
        const pane: Pane = {
          id: `pane-${opened}`, kind, title: kind === 'claude' ? 'Claude' : 'Codex',
          cwd: '/tmp/smoke-repo', status: 'live', exitCode: null, createdAt: opened,
        }
        born.push(pane)
        return pane
      },
      'pane.paste': (payload) => {
        invoked.push({ name: 'pane.paste', payload })
        return { ok: true }
      },
    })

    render(<StoreProvider><GridSurface /></StoreProvider>)
    fireEvent.click(await screen.findByTitle('New Claude pane'))
    await waitFor(() => expect(screen.getAllByTitle('Pane actions')).toHaveLength(1))
    fireEvent.click(await screen.findByTitle('New Codex pane'))
    await waitFor(() => expect(screen.getAllByTitle('Pane actions')).toHaveLength(2))
    // The registry is fed by the event, not the invoke result — without it a
    // pane has no title and the relay would name it by vendor.
    act(() => {
      for (const pane of born) appEventListener?.({ type: 'pane.created', pane })
    })

    // Stand in for xterm's own selection.
    registerTerm('pane-1', {
      getSelection: () => 'function add(a, b) {\n  return a + b\n}',
      serialize: () => '', findNext: () => false, findPrevious: () => false, clearSearch: () => {},
    })

    const menus = await screen.findAllByTitle('Pane actions')
    fireEvent.click(menus[0] as HTMLElement)
    fireEvent.click(await screen.findByRole('menuitem', { name: /Send selection to codex/i }))

    await waitFor(() => expect(invoked).toHaveLength(1))
    const { paneId, text } = invoked[0]!.payload as { paneId: string; text: string }
    // Into the OTHER pane, carrying where it came from, with its newlines.
    expect(paneId).toBe('pane-2')
    // Named by its title when the registry has one, by its vendor otherwise —
    // either way the receiving CLI is told where this came from, because an
    // unattributed wall of someone else's reasoning reads as the user's own.
    expect(text.toLowerCase()).toContain('claude said:')
    expect(text).toContain('function add(a, b) {\n  return a + b\n}')
  })

  it('a room opens as a pane, sends a turn, and renders the streamed reply', async () => {
    // The pivot, end to end through the renderer: a slot that holds a
    // conversation rather than a process, driven by the same event channel
    // everything else uses.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats: [
        {
          id: 'seat-1',
          name: 'claude',
          config: {
            vendor: 'claude' as const,
            model: '',
            effort: 'high' as const,
            persona: '',
          },
          write: false,
        },
      ],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage: {
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        costUsd: 0,
      },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'dialog.pickDirectory': () => ({ path: '/tmp/smoke-repo' }),
      'room.open': (payload) => {
        invoked.push({ name: 'room.open', payload })
        return room
      },
      'room.get': () => room,
      // A verdict this room reached earlier, so the mount-time fetch has
      // something to find.
      'room.verdicts': () => [
        {
          id: 'v-earlier',
          roomId: 'room-1',
          question: 'was the gate sound?',
          decision: 'the gate is unsound',
          rationale: 'the statistic is bimodal',
          scores: {
            correctness: 5,
            robustness: 5,
            clarity: 5,
            maintainability: 5,
            risk: 5,
          },
          confidence: 0.4,
          agreement: 0.5,
          singleSource: false,
          dissent: '',
          report: '# the gate is unsound',
          createdAt: 1_700_000_000_000,
        },
      ],
      'room.send': (payload) => {
        invoked.push({ name: 'room.send', payload })
        return { ok: true }
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    // The toolbar already targets a folder (the seeded session's repo), so
    // opening a room is the one click.
    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))

    // A room opened without spawning anything: no pane.open in sight.
    await waitFor(() => expect(invoked.some((i) => i.name === 'room.open')).toBe(true))
    expect(invoked.some((i) => i.name === 'pane.open')).toBe(false)
    expect((invoked[0]?.payload as { cwd: string }).cwd).toBe('/tmp/smoke-repo')

    const composer = await screen.findByPlaceholderText('Say something…')
    fireEvent.change(composer, {
      target: { value: 'what does this repo do?' },
    })
    fireEvent.keyDown(composer, { key: 'Enter' })

    await waitFor(() => expect(invoked.some((i) => i.name === 'room.send')).toBe(true))

    // The human's own message is announced by main rather than optimistically
    // drawn here — one source of truth, so a refused send leaves no ghost.
    act(() => {
      appEventListener?.({
        type: 'room.turn.ended',
        roomId: 'room-1',
        turn: {
          id: 'turn-1',
          roomId: 'room-1',
          author: 'human',
          seat: '',
          vendor: null,
          profile: '',
          text: 'what does this repo do?',
          usage: room.usage,
          startedAt: 1_700_000_000_000,
          endedAt: 1_700_000_000_000,
          error: null,
        },
      })
    })
    expect(await screen.findByText('what does this repo do?')).toBeTruthy()

    // The seat answers over the event channel, in pieces, exactly as a real
    // adapter streams — and the finished turn replaces the streamed text.
    const turn = {
      id: 'turn-2',
      roomId: 'room-1',
      author: 'agent' as const,
      seat: 'claude',
      vendor: 'claude' as const,
      profile: '',
      text: '',
      usage: room.usage,
      startedAt: 1_700_000_000_001,
      endedAt: null,
      error: null,
    }
    act(() => {
      appEventListener?.({ type: 'room.turn.started', roomId: 'room-1', turn })
    })

    // Before a single delta, the seat says what it is doing. This is the
    // whole gap against a terminal pane, which shows tool calls scrolling by
    // while a room used to show nothing at all.
    act(() => {
      appEventListener?.({
        type: 'room.activity',
        roomId: 'room-1',
        turnId: 'turn-2',
        seat: 'claude',
        text: 'Read src/index.ts',
      })
    })
    // Collapsed, the header names the count and the most recent action.
    expect(
      await screen.findByRole('button', {
        name: /1 action · Read src\/index\.ts/,
      }),
    ).toBeTruthy()

    // A second action accumulates rather than replacing the first — a room
    // showing only the latest could never say what a seat actually read.
    act(() => {
      appEventListener?.({
        type: 'room.activity',
        roomId: 'room-1',
        turnId: 'turn-2',
        seat: 'claude',
        text: 'Grep renderApp',
      })
    })
    const fold = await screen.findByRole('button', { name: /2 actions/ })
    fireEvent.click(fold)
    // Scoped to the list: the seat chip also shows the latest action, which is
    // the point of having both — a live status line and the working behind it.
    const actions = within(screen.getByRole('list'))
    expect(actions.getByText('Read src/index.ts')).toBeTruthy()
    expect(actions.getByText('Grep renderApp')).toBeTruthy()

    act(() => {
      appEventListener?.({
        type: 'room.turn.delta',
        roomId: 'room-1',
        turnId: 'turn-2',
        text: 'It ',
      })
      appEventListener?.({
        type: 'room.turn.delta',
        roomId: 'room-1',
        turnId: 'turn-2',
        text: 'governs agents.',
      })
    })
    expect(await screen.findByText('It governs agents.')).toBeTruthy()

    act(() => {
      appEventListener?.({
        type: 'room.turn.ended',
        roomId: 'room-1',
        turn: {
          ...turn,
          text: 'It governs agents.',
          endedAt: 1_700_000_000_002,
        },
      })
    })
    // Idle arrives with room.changed, not with a turn ending: with several
    // seats, one finishing says nothing about whether the room is free.
    act(() => {
      appEventListener?.({
        type: 'room.changed',
        roomId: 'room-1',
        room: { ...room, status: 'idle', turnsSpent: 1 },
      })
    })

    // Back to idle, so the composer takes the next message — and the activity
    // line is gone, because nothing is happening for it to describe.
    expect(await screen.findByPlaceholderText('Say something…')).toBeTruthy()
    // The finished turn keeps what it did — it is the working behind the
    // answer, and a terminal pane has always shown it.
    expect(screen.getByRole('button', { name: /2 actions/ })).toBeTruthy()

    // A verdict reached earlier is fetched on mount, not only received live.
    // The call that does it sat below the effect's cleanup return and never
    // ran — through a clean typecheck and a green suite.
    expect(screen.getByText('the gate is unsound')).toBeTruthy()

    // A long fenced block folds rather than burying the prose above it. A
    // converge always ends in one, and its parsed form is already on screen.
    act(() => {
      appEventListener?.({
        type: 'room.turn.ended',
        roomId: 'room-1',
        turn: {
          id: 'turn-long',
          roomId: 'room-1',
          author: 'agent',
          seat: 'claude',
          vendor: 'claude',
          profile: '',
          text: [
            'My verdict.',
            '',
            '```json',
            ...Array.from({ length: 20 }, (_, i) => `  "line${i}": 1,`),
            '```',
          ].join('\n'),
          usage: room.usage,
          startedAt: 1_700_000_000_003,
          endedAt: 1_700_000_000_004,
          error: null,
        },
      })
    })
    // The prose stays visible; the block collapses behind a count.
    expect(await screen.findByText('My verdict.')).toBeTruthy()
    const codeFold = screen.getByRole('button', { name: /json · 20 lines/ })
    expect(screen.queryByText(/"line19"/)).toBeNull()
    fireEvent.click(codeFold)
    expect(screen.getByText(/"line19"/)).toBeTruthy()
  })

  it('says who will answer before ⏎, and completes a half-typed seat name', async () => {
    // Addressing is the one part of a room with semantics nothing else has,
    // and until now it was legible only in a placeholder and provable only by
    // spending. Both halves of the fix are here: the reading of what is in the
    // box, and the list that makes a name typable without remembering it.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats: [
        { id: 'seat-1', name: 'claude', config: claude, write: false },
        { id: 'seat-2', name: 'code-reviewer', config: codex, write: false },
      ],
      caps: { turns: 3, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage,
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'room.open': () => room,
      'room.get': () => room,
      'room.send': (payload) => {
        invoked.push({ name: 'room.send', payload })
        return { ok: true }
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )
    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))

    // At rest, with an empty box: what an unaddressed message would do.
    const composer = await screen.findByRole('textbox', { name: '' })
    const audience = (): string => screen.getByRole('status').textContent ?? ''
    await waitFor(() => expect(audience()).toContain('2 independent seats'))
    expect(audience()).toContain('spends 2 turns')

    // Addressing one seat is one turn, and the reading follows the keystroke.
    fireEvent.change(composer, {
      target: { value: '@code-reviewer check that' },
    })
    await waitFor(() => expect(audience()).toContain('@code-reviewer'))
    expect(audience()).toContain('spends 1 turn')
    expect(audience()).not.toContain('2 independent seats')

    // A mid-sentence mention relays a turn rather than spending one.
    fireEvent.change(composer, {
      target: { value: '@code-reviewer check what @claude said' },
    })
    await waitFor(() => expect(audience()).toContain("@claude's last turn"))
    expect(audience()).toContain('spends 1 turn')

    // A name that matches nothing is refused HERE, before the send.
    fireEvent.change(composer, { target: { value: '@revewer go' } })
    await waitFor(() => expect(audience()).toContain('no seat called'))

    // Completion: type an @ and a fragment, arrow to the right seat, ⏎ takes
    // it instead of sending — the mistake the list exists to prevent.
    fireEvent.change(composer, {
      target: { value: '@rev', selectionStart: 4 },
    })
    const options = await screen.findAllByRole('option')
    expect(options.map((o) => o.textContent)).toEqual(['@code-reviewercodex'])
    fireEvent.keyDown(composer, { key: 'Enter' })
    expect(invoked).toEqual([])
    await waitFor(() => expect((composer as HTMLTextAreaElement).value).toBe('@code-reviewer '))

    // And with the list closed, ⏎ sends again.
    fireEvent.change(composer, {
      target: { value: '@code-reviewer go', selectionStart: 17 },
    })
    expect(screen.queryAllByRole('option')).toHaveLength(0)
    fireEvent.keyDown(composer, { key: 'Enter' })
    await waitFor(() => expect(invoked).toHaveLength(1))
    expect((invoked[0]?.payload as { text: string }).text).toBe('@code-reviewer go')
  })

  it('indexes a long room, jumps to a turn, and folds one down to its gist', async () => {
    // A room that ran long is a document, and until now the only way through
    // it was the scrollbar.
    const scrollIntoView = vi.fn()
    Element.prototype.scrollIntoView = scrollIntoView
    const turn = (id: string, over: Record<string, unknown>) => ({
      id,
      roomId: 'room-1',
      author: 'agent' as const,
      seat: 'claude',
      vendor: 'claude' as const,
      profile: '',
      text: '',
      usage,
      startedAt: 1,
      endedAt: 2,
      error: null,
      ...over,
    })
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats: [{ id: 'seat-1', name: 'claude', config: claude, write: false }],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 2,
      status: 'idle' as const,
      turns: [
        turn('t1', {
          author: 'human' as const,
          seat: '',
          vendor: null,
          text: 'Is the gate sound?',
        }),
        turn('t2', {
          text: `## Verdict\n\n${'The gate is unsound. '.repeat(60)}`,
        }),
        turn('t3', {
          author: 'human' as const,
          seat: '',
          vendor: null,
          text: 'Say more.',
        }),
      ],
      usage,
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({ 'room.open': () => room, 'room.get': () => room })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )
    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))

    // The index is titled by how much there is to index.
    const index = await screen.findByRole('button', { name: '3' })
    fireEvent.click(index)

    // Each entry names who spoke and enough of the turn to recognise it — the
    // heading, not the "## " in front of it.
    const entries = await screen.findAllByRole('menuitem')
    expect(entries.map((e) => e.textContent)).toEqual([
      'Collapse every turn',
      'YouIs the gate sound?',
      '@claudeVerdict',
      'YouSay more.',
    ])

    fireEvent.click(entries[2] as HTMLElement)
    expect(scrollIntoView).toHaveBeenCalled()

    // Folding replaces a long turn with its one line. Only the long one: a
    // short turn has nothing to gain and would just lose its text.
    expect(screen.getByText(/The gate is unsound/)).toBeTruthy()
    fireEvent.click(index)
    fireEvent.click(await screen.findByRole('menuitem', { name: 'Collapse every turn' }))
    await waitFor(() => expect(screen.queryByText(/The gate is unsound/)).toBeNull())
    expect(screen.getByText('Verdict')).toBeTruthy()
    expect(screen.getByText('Is the gate sound?')).toBeTruthy()

    // And what was said comes back.
    fireEvent.click(screen.getByRole('button', { name: 'Expand' }))
    await waitFor(() => expect(screen.getByText(/The gate is unsound/)).toBeTruthy())

    // Scrolled away from the tail, there is a way back to it — and only then,
    // because a button that is always there is a button nobody reads.
    expect(screen.queryByRole('button', { name: 'Latest' })).toBeNull()
    const transcript = document.querySelector('.room__transcript') as HTMLElement
    Object.defineProperty(transcript, 'scrollHeight', {
      value: 2000,
      configurable: true,
    })
    Object.defineProperty(transcript, 'clientHeight', {
      value: 400,
      configurable: true,
    })
    fireEvent.scroll(transcript)
    fireEvent.click(await screen.findByRole('button', { name: 'Latest' }))
    expect(transcript.scrollTop).toBe(2000)
  })

  it('a room shows its seats, its spend, and stops at the budget', async () => {
    // m3's shape in one mount: several named seats, a visible bound, and an
    // exhausted room that refuses rather than quietly continuing.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const seats = [
      {
        id: 'seat-1',
        name: 'claude',
        config: {
          vendor: 'claude' as const,
          model: '',
          effort: 'high' as const,
          persona: '',
        },
        write: false,
      },
      {
        id: 'seat-2',
        name: 'reviewer',
        config: {
          vendor: 'claude' as const,
          model: '',
          effort: 'high' as const,
          persona: '',
          profile: 'Reviewer',
        },
        write: false,
      },
    ]
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats,
      caps: { turns: 4, costUsd: 0 },
      turnsSpent: 2,
      status: 'idle' as const,
      turns: [],
      usage: {
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        costUsd: 0.25,
      },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'room.open': () => room,
      'room.get': () => room,
      'room.setCaps': (payload) => {
        invoked.push({ name: 'room.setCaps', payload })
        return { ...room, caps: { turns: 24, costUsd: 0 }, status: 'idle' }
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))

    // Both seats are named and addressable, and the spend is on screen with
    // turns leading — the cap that actually bites on a subscription.
    expect(await screen.findByText('@claude')).toBeTruthy()
    expect(screen.getByText('@reviewer')).toBeTruthy()
    expect(screen.getByText(/2\/4 turns/)).toBeTruthy()
    expect(screen.getByText(/\$0\.25/)).toBeTruthy()

    // Spending the budget closes the composer and offers the only way on.
    act(() => {
      appEventListener?.({
        type: 'room.changed',
        roomId: 'room-1',
        room: { ...room, turnsSpent: 4, status: 'exhausted' },
      })
    })
    const composer = await screen.findByPlaceholderText('Budget spent — raise it to continue.')
    expect((composer as HTMLTextAreaElement).disabled).toBe(true)

    fireEvent.click(screen.getByRole('button', { name: 'Raise budget' }))
    await waitFor(() => expect(invoked).toHaveLength(1))
    expect(invoked[0]?.payload).toMatchObject({
      roomId: 'room-1',
      caps: { turns: 24 },
    })
  })

  it('a room states who may write, and converges on a stated question', async () => {
    // The two halves of m5 in one mount. The write state is header furniture
    // rather than a setting you go looking for, because the flag is standing
    // authorisation and a capability nobody is reminded of is one nobody
    // remembers granting.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const seats = [
      {
        id: 'seat-1',
        name: 'auditor',
        config: {
          vendor: 'claude' as const,
          model: '',
          effort: 'high' as const,
          persona: '',
        },
        write: false,
      },
    ]
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats,
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 1,
      status: 'idle' as const,
      turns: [
        {
          id: 'turn-1',
          roomId: 'room-1',
          author: 'agent' as const,
          seat: 'auditor',
          vendor: 'claude' as const,
          profile: '',
          text: 'the gate is unsound',
          usage: {
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            costUsd: 0,
          },
          startedAt: 1_700_000_000_000,
          endedAt: 1_700_000_000_001,
          error: null,
        },
      ],
      usage: {
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        costUsd: 0,
      },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'room.open': () => room,
      'room.get': () => room,
      'room.verdicts': () => [],
      'room.setSeatWrite': (payload) => {
        invoked.push({ name: 'room.setSeatWrite', payload })
        return { ...room, seats: [{ ...seats[0]!, write: true }] }
      },
      'room.converge': (payload) => {
        invoked.push({ name: 'room.converge', payload })
        return { ok: true }
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))
    expect(await screen.findByText('read-only')).toBeTruthy()

    // Granting write is one click, and the header stops saying read-only.
    fireEvent.click(screen.getByRole('button', { name: 'Let @auditor write' }))
    await waitFor(() => expect(invoked).toHaveLength(1))
    expect(invoked[0]?.payload).toMatchObject({
      seatId: 'seat-1',
      write: true,
    })
    expect(await screen.findByText('@auditor can write')).toBeTruthy()
    expect(screen.queryByText('read-only')).toBeNull()

    // Converging asks for the question first — a verdict on nothing in
    // particular is the failure the beat exists to prevent.
    fireEvent.click(screen.getByRole('button', { name: 'Converge' }))
    const question = await screen.findByPlaceholderText(/Should we decompose/)
    fireEvent.change(question, { target: { value: 'ship or measure?' } })
    fireEvent.click(screen.getByRole('button', { name: 'Ask the seats' }))

    await waitFor(() => expect(invoked).toHaveLength(2))
    expect(invoked[1]?.payload).toMatchObject({
      roomId: 'room-1',
      question: 'ship or measure?',
    })

    // The verdict lands as an event and reports confidence AND agreement —
    // two different questions that one number would hide.
    act(() => {
      appEventListener?.({
        type: 'room.verdict',
        roomId: 'room-1',
        verdict: {
          id: 'v1',
          roomId: 'room-1',
          question: 'ship or measure?',
          decision: 'measure first',
          rationale: 'the gate cannot detect the change',
          scores: {
            correctness: 5,
            robustness: 5,
            clarity: 5,
            maintainability: 5,
            risk: 5,
          },
          confidence: 0.27,
          agreement: 0.3,
          singleSource: false,
          dissent: 'Side B: the decomposition still stands on its own merits',
          report: '# measure first',
          createdAt: 1_700_000_000_002,
        },
      })
    })
    expect(await screen.findByText('measure first')).toBeTruthy()
    expect(screen.getByText(/confidence 0\.27/)).toBeTruthy()
    expect(screen.getByText(/agreement 0\.30/)).toBeTruthy()
    // Dissent is surfaced without being opened — it is the first thing a
    // summary would drop.
    expect(screen.getByText(/the decomposition still stands/)).toBeTruthy()
  })

  it('offers the record from a room that already has one, and from an empty one', async () => {
    // The path this closes: the toolbar mints a room immediately, so a room
    // pane never exists WITHOUT one — and "Reopen a room…" was gated on an
    // empty slot, which made it unreachable in the only situation anybody
    // wants it, right after a reload.
    const room = {
      id: 'room-fresh',
      cwd: '/tmp/smoke-repo',
      seats: [
        {
          id: 'seat-1',
          name: 'claude',
          config: {
            vendor: 'claude' as const,
            model: '',
            effort: 'high' as const,
            persona: '',
          },
          write: false,
        },
      ],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage: {
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        costUsd: 0,
      },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    const earlier = { ...room, id: 'room-earlier', cwd: '/tmp/older-repo' }
    installBridge({
      'room.open': () => room,
      'room.get': () => room,
      'room.list': () => [earlier],
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))

    // The empty room offers the record where somebody looking for it lands.
    fireEvent.click(await screen.findByRole('button', { name: 'Reopen an earlier room…' }))
    const dialog = within(await screen.findByRole('dialog'))
    expect(dialog.getByText(/older-repo/)).toBeTruthy()
  })

  it('a skill dropped on a room reaches its seat, not the pty', async () => {
    // The m2 regression: rooms became a pane kind that skills silently
    // rejected, with a message telling you to start something already running.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const room = {
      id: 'room-1',
      cwd: '/tmp/smoke-repo',
      seats: [
        {
          id: 'seat-1',
          name: 'claude',
          config: {
            vendor: 'claude' as const,
            model: '',
            effort: 'high' as const,
            persona: '',
          },
          write: false,
        },
      ],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage: {
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningTokens: 0,
        costUsd: 0,
      },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'skill.list': () => [
        {
          id: 'skill-1',
          name: 'Orient me',
          description: '',
          prompt: 'Orient me.',
          vendorHint: null,
          builtIn: true,
        },
      ],
      'room.open': () => room,
      'room.get': () => room,
      'skill.run': (payload) => {
        invoked.push({ name: 'skill.run', payload })
        return { ok: true }
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Room' }))
    await screen.findByPlaceholderText('Say something…')

    // Double-clicking a skill runs it on the focused slot — the room.
    fireEvent.doubleClick(await screen.findByText('Orient me'))

    await waitFor(() => expect(invoked).toHaveLength(1))
    // Addressed as a room, so main can never hand it to pty.submit.
    expect(invoked[0]?.payload).toMatchObject({
      skillId: 'skill-1',
      target: { kind: 'room', roomId: 'room-1' },
    })
  })

  it('the roster lists, edits and forgets a profile without leaving the Grid', async () => {
    // Profiles could be saved and chosen from a seat picker since schema 32,
    // and never listed, corrected or retired — profile.forget shipped with no
    // caller. This pins the missing half, including that an edit routes
    // through profile.update rather than a delete-and-recreate.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const profiles = [
      {
        id: 'prof-1',
        name: 'Fast reviewer',
        vendor: 'codex' as const,
        model: 'gpt-5.6-sol',
        effort: 'low' as const,
        persona: 'terse',
        createdAt: 1_700_000_000_000,
      },
    ]
    installBridge({
      'profile.list': () => profiles,
      'profile.update': (payload) => {
        invoked.push({ name: 'profile.update', payload })
        return { ...profiles[0], name: 'Careful reviewer' }
      },
      'profile.forget': (payload) => {
        invoked.push({ name: 'profile.forget', payload })
        return null
      },
    })

    render(
      <StoreProvider>
        <GridSurface />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: 'Roster' }))
    // Scoped to the dialog throughout: the Grid toolbar carries its own
    // "Codex" button, and an unscoped query would match the wrong surface.
    const dialog = within(await screen.findByRole('dialog'))

    // The stored profile is shown with the vocabulary a seat picker uses —
    // the CLI's label, not its enum value.
    expect(await dialog.findByText('Fast reviewer')).toBeTruthy()
    expect(dialog.getByText('Codex')).toBeTruthy()
    expect(dialog.getByText('gpt-5.6-sol')).toBeTruthy()

    fireEvent.click(dialog.getByRole('button', { name: 'Edit Fast reviewer' }))
    const nameField = dialog.getByDisplayValue('Fast reviewer')
    fireEvent.change(nameField, { target: { value: 'Careful reviewer' } })
    fireEvent.click(dialog.getByRole('button', { name: 'Save changes' }))

    await waitFor(() => expect(invoked).toHaveLength(1))
    expect(invoked[0]?.name).toBe('profile.update')
    // The id travels, which is what makes this an edit and not a new row.
    expect((invoked[0]?.payload as { profileId: string }).profileId).toBe('prof-1')

    // Forgetting asks first: a roster row is cheap to recreate but the name is
    // stamped on work, so a stray click should not silently retire it.
    fireEvent.click(dialog.getByRole('button', { name: 'Forget Fast reviewer' }))
    fireEvent.click(dialog.getByRole('button', { name: 'Forget' }))
    await waitFor(() => expect(invoked).toHaveLength(2))
    expect(invoked[1]?.name).toBe('profile.forget')
  })

  it('shows nothing from the record while the box is empty', async () => {
    const invoked: string[] = []
    installBridge({
      'search.query': () => {
        invoked.push('search.query')
        return []
      },
    })
    render(
      <StoreProvider>
        <OpenPalette />
      </StoreProvider>,
    )
    // The debounce window passes with no query; the record is never asked.
    await new Promise((resolve) => setTimeout(resolve, 250))
    expect(invoked).toEqual([])
  })
})
