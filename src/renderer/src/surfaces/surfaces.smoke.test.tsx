// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
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

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

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
        usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
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

beforeEach(() => installBridge())
afterEach(() => {
  cleanup()
  appEventListener = null
})

async function assertLedgerGateActionsDisabled(invoked: CommandName[]): Promise<void> {
  const buttons = [
    screen.getByRole('button', { name: 'Approve and run' }),
    await screen.findByRole('button', { name: 'Resume from where it stopped' }),
    await screen.findByRole('button', { name: 'Adopt & verify the existing work' }),
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
        { vendor: 'claude', present: true, version: '2.1.0', authenticated: true, detail: 'Signed in.' },
        { vendor: 'codex', present: false, version: '', authenticated: false, detail: 'codex was not found on PATH.' },
        { vendor: 'agy', present: false, version: '', authenticated: false, detail: 'agy was not found on PATH.' },
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
          config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' },
          write: false,
        },
      ],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
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
          scores: { correctness: 5, robustness: 5, clarity: 5, maintainability: 5, risk: 5 },
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
    fireEvent.change(composer, { target: { value: 'what does this repo do?' } })
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

    // Before a single delta, the seat says what it is doing. This is the
    // whole gap against a terminal pane, which shows tool calls scrolling by
    // while a room used to show nothing at all.
    act(() => {
      appEventListener?.({
        type: 'room.activity',
        roomId: 'room-1',
        seat: 'claude',
        text: 'Read src/index.ts',
      })
    })
    expect(await screen.findByText('Read src/index.ts')).toBeTruthy()

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
      appEventListener?.({ type: 'room.turn.delta', roomId: 'room-1', turnId: 'turn-2', text: 'It ' })
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
        turn: { ...turn, text: 'It governs agents.', endedAt: 1_700_000_000_002 },
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
    expect(screen.queryByText('Read src/index.ts')).toBeNull()

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
          text: ['My verdict.', '', '```json', ...Array.from({ length: 20 }, (_, i) => `  "line${i}": 1,`), '```'].join('\n'),
          usage: room.usage,
          startedAt: 1_700_000_000_003,
          endedAt: 1_700_000_000_004,
          error: null,
        },
      })
    })
    // The prose stays visible; the block collapses behind a count.
    expect(await screen.findByText('My verdict.')).toBeTruthy()
    const fold = screen.getByRole('button', { name: /json · 20 lines/ })
    expect(screen.queryByText(/"line19"/)).toBeNull()
    fireEvent.click(fold)
    expect(screen.getByText(/"line19"/)).toBeTruthy()
  })

  it('a room shows its seats, its spend, and stops at the budget', async () => {
    // m3's shape in one mount: several named seats, a visible bound, and an
    // exhausted room that refuses rather than quietly continuing.
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const seats = [
      {
        id: 'seat-1',
        name: 'claude',
        config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' },
        write: false,
      },
      {
        id: 'seat-2',
        name: 'reviewer',
        config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '', profile: 'Reviewer' },
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
      usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0.25 },
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
    expect(invoked[0]?.payload).toMatchObject({ roomId: 'room-1', caps: { turns: 24 } })
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
        config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' },
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
          usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
          startedAt: 1_700_000_000_000,
          endedAt: 1_700_000_000_001,
          error: null,
        },
      ],
      usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
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
    expect(invoked[0]?.payload).toMatchObject({ seatId: 'seat-1', write: true })
    expect(await screen.findByText('@auditor can write')).toBeTruthy()
    expect(screen.queryByText('read-only')).toBeNull()

    // Converging asks for the question first — a verdict on nothing in
    // particular is the failure the beat exists to prevent.
    fireEvent.click(screen.getByRole('button', { name: 'Converge' }))
    const question = await screen.findByPlaceholderText(/Should we decompose/)
    fireEvent.change(question, { target: { value: 'ship or measure?' } })
    fireEvent.click(screen.getByRole('button', { name: 'Ask the seats' }))

    await waitFor(() => expect(invoked).toHaveLength(2))
    expect(invoked[1]?.payload).toMatchObject({ roomId: 'room-1', question: 'ship or measure?' })

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
          scores: { correctness: 5, robustness: 5, clarity: 5, maintainability: 5, risk: 5 },
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
          config: { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' },
          write: false,
        },
      ],
      caps: { turns: 40, costUsd: 0 },
      turnsSpent: 0,
      status: 'idle' as const,
      turns: [],
      usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'skill.list': () => [
        { id: 'skill-1', name: 'Orient me', description: '', prompt: 'Orient me.', vendorHint: null, builtIn: true },
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
