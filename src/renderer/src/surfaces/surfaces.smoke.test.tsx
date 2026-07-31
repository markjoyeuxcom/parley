// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import type {
  AgentConfig,
  BacklogItem,
  ForemanProposal,
  Learning,
  Milestone,
  Session,
  Turn,
  Usage,
  Verdict,
  WorkPlan,
} from '@shared/domain'
import type { AppEvent } from '@shared/events'
import {
  toInvokeResult,
  unwrapInvokeResult,
  type CommandName,
  type InvokeResult,
  type LedgerEntry,
} from '@shared/ipc'
import type { Hold } from '@shared/holds'
import type { SeatRole } from '@shared/vendors'
import { useEffect, useState, type ReactNode } from 'react'
import { StoreProvider, useStore, type Surface } from '../state'
import { AgentPicker } from '../components/AgentPicker'
import { Titlebar } from '../components/Titlebar'
import { HoldsButton, HoldsPopover } from '../components/HoldsPanel'
import { Notices } from '../components/Notices'
import { ParleySurface } from './ParleySurface'
import { BacklogSurface } from './BacklogSurface'
import { GridSurface } from './GridSurface'
import { PlanPanel } from '../components/PlanPanel'
import { NewWorkspaceDialog } from '../components/NewWorkspaceDialog'
import { PreviewCard } from '../components/PreviewCard'
import { LoopsSurface } from './LoopsSurface'

/** Activates a surface the way the titlebar would — some surfaces only fetch
 * while they are the active one. */
function OnSurface({ surface, children }: { surface: Surface; children: ReactNode }): ReactNode {
  const { state, dispatch } = useStore()
  useEffect(() => {
    dispatch({ type: 'surface', surface })
  }, [dispatch, surface])
  return state.surface === surface ? children : null
}

function AppMountedSurfaces(): ReactNode {
  const { state, dispatch } = useStore()
  return (
    <>
      <button onClick={() => dispatch({ type: 'surface', surface: 'parley' })}>
        Switch to Parley
      </button>
      <button onClick={() => dispatch({ type: 'surface', surface: 'backlog' })}>
        Switch to Repos
      </button>
      <HoldsButton />
      <div
        data-testid="parley-host"
        style={{ display: state.surface === 'parley' ? 'contents' : 'none' }}
      >
        <ParleySurface />
      </div>
      <div
        data-testid="backlog-host"
        style={{ display: state.surface === 'backlog' ? 'contents' : 'none' }}
      >
        <BacklogSurface />
      </div>
      <HoldsPopover />
    </>
  )
}

function PlanOpenHarness(): ReactNode {
  const { state, openPlan } = useStore()
  return (
    <>
      <button onClick={() => void openPlan(smokePlan.id)}>Open earlier plan</button>
      <button onClick={() => void openPlan(newerSmokePlan.id)}>Open newer plan</button>
      <div>{state.planDetail?.plan.title ?? 'No plan open'}</div>
      <div>{state.planLedger?.map((entry) => entry.text).join(', ') ?? 'Ledger unknown'}</div>
    </>
  )
}

function AgentPickerHarness({
  initial = claude,
  role = 'debate-seat',
  toolFree = true,
}: {
  initial?: AgentConfig
  role?: SeatRole
  toolFree?: boolean
}): ReactNode {
  const [config, setConfig] = useState<AgentConfig>(initial)
  return (
    <>
      <AgentPicker
        label="Debater"
        value={config}
        onChange={setConfig}
        role={role}
        toolFree={toolFree}
      />
      <output data-testid="picker-config">{`${config.vendor}:${config.model}`}</output>
    </>
  )
}

/**
 * Mounted-tree smoke tests.
 *
 * The rest of the suite never renders React, which let a rules-of-hooks
 * violation ship with typecheck clean and 621 tests green — the window went
 * black the moment a session's detail loaded. These tests mount the real
 * surfaces over a fake IPC bridge and walk the exact transition that crashed:
 * a session opening (detail null → loaded). A render error anywhere in that
 * path fails here, before it reaches a screen.
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

const session: Session = {
  id: 'a'.repeat(36),
  kind: 'review',
  status: 'complete',
  matter: 'Audit the retry path for swallowed failures.',
  project: '',
  repoPath: '/tmp/smoke-repo',
  participants: [claude, codex],
  maxTurns: 6,
  usage,
  mock: true,
  createdAt: 1_700_000_000_000,
  endedAt: 1_700_000_100_000,
  error: null,
  archivedAt: null,
}

const turn: Turn = {
  id: 'b'.repeat(36),
  sessionId: session.id,
  index: 0,
  seat: 0,
  vendor: 'claude',
  model: '',
  stage: 'architecture-map',
  text: 'THE ARCHITECTURE MAP CONTENT',
  usage,
  startedAt: 1_700_000_000_000,
  endedAt: 1_700_000_050_000,
  error: null,
}

const verdict: Verdict = {
  sessionId: session.id,
  decision: 'Adopt the narrower option and revisit later.',
  rationale: 'It is reversible.',
  scores: { correctness: 7, robustness: 6, clarity: 8, maintainability: 7, risk: 6 },
  confidence: 0.72,
  dissent: '',
  report: '',
  createdAt: 1_700_000_100_000,
}

const openItem: BacklogItem = {
  id: 'c'.repeat(36),
  repoPath: '/tmp/smoke-repo',
  contentHash: 'hash',
  title: 'Unbounded retry in the codex path',
  detail: 'A failed call retries without a ceiling.',
  priority: 'P1',
  state: 'open',
  source: 'review-finding',
  originSessionId: session.id,
  originAcceptanceId: null,
  planId: null,
  evidence: [],
  blockedBy: [],
  mock: true,
  createdAt: 1_700_000_000_000,
  updatedAt: 1_700_000_000_000,
}

const proposal: ForemanProposal = {
  id: 'd'.repeat(36),
  repoPath: '/tmp/smoke-repo',
  state: 'proposed',
  title: 'Bound the retry path',
  rationale: 'The retry items gate everything else.',
  itemIds: [openItem.id],
  deferred: [],
  openSnapshot: [openItem.id],
  isolation: 'worktree',
  note: 'Land the cap first.',
  anchorSessionId: session.id,
  planId: null,
  vendor: 'claude',
  usage,
  mock: true,
  createdAt: 1_700_000_000_000,
  decidedAt: null,
  decisionNote: '',
}

const smokePlan: WorkPlan = {
  id: 'e'.repeat(36),
  sessionId: session.id,
  kind: 'implementation',
  title: 'Bound the retry path',
  repoPath: '/tmp/smoke-repo',
  planner: claude,
  executor: codex,
  reviewer: claude,
  status: 'ready',
  question: '',
  correctionNote: '',
  correctionDispositions: [],
  isolation: 'checkout',
  setupCommand: '',
  container: false,
  usage,
  mock: true,
  createdAt: 1_700_000_000_000,
}

const newerSmokePlan: WorkPlan = {
  ...smokePlan,
  id: '1'.repeat(36),
  sessionId: '2'.repeat(36),
  title: 'Keep the newer plan selected',
}

const smokeMilestone: Milestone = {
  id: 'f'.repeat(36),
  planId: smokePlan.id,
  index: 0,
  title: 'Add a retry ceiling',
  intent: 'Cap retries and surface exhaustion.',
  expectedPaths: [],
  status: 'audited',
  auditNote: '',
  testCommand: 'true',
  testResult: null,
  mutations: [],
  mutationResults: [],
  reviewNote: '',
  reviewBlocking: [],
  reviewNotes: [],
  reviewPassed: null,
  adopted: false,
  approvalId: null,
  createdAt: 1_700_000_000_000,
  completedAt: null,
}

const approvalWaitingHold: Hold = {
  id: 'hold-approval-smoke',
  kind: 'approval-waiting',
  sessionId: session.id,
  planId: smokePlan.id,
  milestoneId: smokeMilestone.id,
  loopId: null,
  repoPath: smokePlan.repoPath,
  title: 'Milestone 1 is ready for approval',
  detail: 'Review the scope and approve the audited milestone.',
  sinceAt: 1_700_000_000_000,
  mock: true,
  actionable: true,
}

const failedSmokeMilestone: Milestone = {
  ...smokeMilestone,
  expectedPaths: ['src/retry.ts'],
  status: 'failed',
  runState: {
    startedAt: 1_700_000_000_000,
    round: 1,
    lastActivityAt: 1_700_000_050_000,
    lastInspection: null,
  },
}

/** One open blocking occurrence: the approval gate must show as blocked. */
const blockingEntry: LedgerEntry = {
  id: 'finding-smoke-1',
  sessionId: session.id,
  text: 'The retry ceiling is asserted against the imported constant.',
  normalizedText: 'the retry ceiling is asserted against the imported constant',
  createdAt: 1_700_000_000_000,
  occurrences: [
    {
      id: 'occurrence-smoke-1',
      findingId: 'finding-smoke-1',
      planId: smokePlan.id,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
      seq: 1,
      createdAt: 1_700_000_000_000,
    },
  ],
  dispositions: [],
}

const newerLedgerEntry: LedgerEntry = {
  ...blockingEntry,
  id: 'finding-smoke-2',
  sessionId: newerSmokePlan.sessionId,
  text: 'The newer plan ledger survives.',
  normalizedText: 'the newer plan ledger survives',
  occurrences: [],
}

/**
 * The fake bridge: every command the mounted surfaces reach for, answered
 * with fixtures. An unlisted command resolves undefined, which the store's
 * attempt() guards tolerate — but list the ones under test explicitly so a
 * renamed command fails loudly here rather than passing vacuously.
 */
let appEventListener: ((event: AppEvent) => void) | null = null

function installBridge(
  overrides: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {},
  failures: Partial<Record<CommandName, string>> = {},
): void {
  const handlers: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {
    'app.info': () => ({
      mock: true,
      codexDefaultModel: '',
      agyModels: ['gemini-real-pro', 'gemini-real-flash-high'],
      selfRepoPath: null,
    }),
    'health.probe': () => [],
    'session.list': () => ({ sessions: [session], archivedCount: 0 }),
    'session.get': () => ({
      session,
      turns: [turn],
      interjections: [],
      verdict,
      findings: [],
      ledger: [],
      plans: [],
    }),
    'holds.list': () => [],
    'envelope.list': () => [],
    'inflight.list': () => [],
    'workspace.list': () => [],
    'preview.list': () => [],
    'repo.containerStatus': () => ({
      enabled: false,
      configPresent: true,
      cli: { present: true, version: '0.87.0-smoke', detail: '/smoke/devcontainer' },
    }),
    'ledger.list': () => [blockingEntry],
    'backlog.list': () => [openItem],
    'learnings.list': () => [],
    'foreman.list': () => [proposal],
    'plan.list': (payload) =>
      (payload as { repoPath?: string } | undefined)?.repoPath === '/tmp/smoke-repo'
        ? [smokePlan]
        : [],
    'plan.get': () => ({ plan: smokePlan, milestones: [smokeMilestone], worktree: null }),
    'plan.inspect': () => ({
      existing: [...failedSmokeMilestone.expectedPaths],
      missing: [],
      dirtyPaths: [],
    }),
    'repos.list': () => ({
      repos: [
        {
          repoPath: '/tmp/smoke-repo',
          archived: false,
          planCount: 1,
          attentionPlans: 0,
          openItems: 1,
          pendingTriage: 0,
          hasPendingProposal: true,
        },
        // A repository whose only records are plans — it must appear and get
        // full tabs, or the surface dead-ends on exactly the repos it exists
        // for.
        {
          repoPath: '/tmp/smoke-plans-only',
          archived: false,
          planCount: 2,
          attentionPlans: 1,
          openItems: 0,
          pendingTriage: 0,
          hasPendingProposal: false,
        },
      ],
      archivedCount: 0,
    }),
    'loop.list': () => [],
    'skill.list': () => [],
    'pane.list': () => [],
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
  it('offers Agy only with models discovered through app.info', async () => {
    render(
      <StoreProvider>
        <AgentPickerHarness />
      </StoreProvider>,
    )

    const vendor = screen.getAllByRole('combobox')[0] as HTMLSelectElement
    expect(within(vendor).getByRole('option', { name: 'Agy' })).toBeTruthy()
    fireEvent.change(vendor, { target: { value: 'agy' } })

    await screen.findByPlaceholderText('Required Gemini model')
    await waitFor(() => {
      const values = Array.from(document.querySelectorAll('datalist option')).map(
        (option) => (option as HTMLOptionElement).value,
      )
      expect(values).toEqual(['gemini-real-pro', 'gemini-real-flash-high'])
    })
  })

  it('pane events drive the ⌘1 count: created counts, exited stops counting, closed removes', async () => {
    installBridge()
    render(
      <StoreProvider>
        <Titlebar />
      </StoreProvider>,
    )
    const pane = {
      id: 'p'.repeat(36),
      kind: 'shell' as const,
      title: 'shell — smoke',
      cwd: '/tmp',
      status: 'live' as const,
      exitCode: null,
      createdAt: 1_700_000_000_000,
    }

    // Born: the Grid tab counts it.
    act(() => appEventListener?.({ type: 'pane.created', pane }))
    await screen.findByText('1')

    // Exited: the row survives (the pane shows its corpse) but the count of
    // running panes drops — exit is a status, not a removal.
    act(() =>
      appEventListener?.({ type: 'pane.status', paneId: pane.id, status: 'exited', exitCode: 1 }),
    )
    await waitFor(() => expect(screen.queryByText('1')).toBeNull())

    // Closed by the user: the row itself is gone.
    act(() => appEventListener?.({ type: 'pane.closed', paneId: pane.id }))
    act(() => appEventListener?.({ type: 'pane.created', pane: { ...pane, id: 'q'.repeat(36) } }))
    await screen.findByText('1')
  })

  it('the preview card starts a suggested command and opens the URL in the browser', async () => {
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const preview = {
      id: 'p'.repeat(36),
      repoPath: '/tmp/smoke-repo',
      command: 'npm run dev',
      status: 'running' as const,
      url: 'http://localhost:5173/',
      exitCode: null,
      startedAt: Date.now(),
    }
    installBridge({
      'preview.suggest': () => ({ command: 'npm run dev' }),
      'preview.start': (payload) => {
        invoked.push({ name: 'preview.start', payload })
        return preview
      },
      'preview.open': (payload) => {
        invoked.push({ name: 'preview.open', payload })
        return { ok: true }
      },
      'preview.logs': () => ({ text: 'VITE ready' }),
    })

    render(
      <StoreProvider>
        <PreviewCard repo="/tmp/smoke-repo" />
      </StoreProvider>,
    )

    // The command comes from the project itself, not from a guess.
    await waitFor(() =>
      expect((screen.getByPlaceholderText('npm run dev') as HTMLInputElement).value).toBe(
        'npm run dev',
      ),
    )

    fireEvent.click(screen.getByRole('button', { name: /Start/ }))
    await waitFor(() => expect(invoked.map((entry) => entry.name)).toEqual(['preview.start']))
    expect(invoked[0]?.payload).toEqual({ repoPath: '/tmp/smoke-repo', command: 'npm run dev' })

    // Once running, the address is offered — and opening it goes through the
    // main process, never a navigation inside the app.
    act(() => appEventListener?.({ type: 'preview.changed', preview }))
    const link = await screen.findByRole('button', { name: /localhost:5173/ })
    fireEvent.click(link)
    await waitFor(() =>
      expect(invoked.map((entry) => entry.name)).toEqual(['preview.start', 'preview.open']),
    )

    // A running preview offers Stop, not Start.
    expect(screen.queryByRole('button', { name: /^Start/ })).toBeNull()
    await screen.findByRole('button', { name: /Stop/ })
  })

  it('the new-app dialog shows a refusal live, and grants against the resolved path', async () => {
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    installBridge({
      'workspace.templates': () => [
        { id: 'web-app', name: 'Local web app', description: 'TypeScript + Vite + Vitest.' },
      ],
      'dialog.pickDirectory': () => ({ path: '/tmp/projects' }),
      'workspace.preview': (payload) => {
        const path = (payload as { path: string }).path
        return path.endsWith('/taken')
          ? { ok: false, path: '', refusal: '/tmp/projects/taken is not empty' }
          : { ok: true, path, refusal: '' }
      },
      'approval.grant': (payload) => {
        invoked.push({ name: 'approval.grant', payload })
        return { id: 'w'.repeat(36), scope: 'workspace.create', subjectId: '' }
      },
      'workspace.create': (payload) => {
        invoked.push({ name: 'workspace.create', payload })
        return {
          id: 'k'.repeat(36),
          repoPath: '/tmp/projects/my-app',
          name: 'My App',
          templateId: 'web-app',
          state: 'building',
          detail: '',
          createdAt: Date.now(),
          readyAt: null,
          mock: false,
        }
      },
    })

    render(
      <StoreProvider>
        <NewWorkspaceDialog onClose={() => {}} onCreated={() => {}} />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByRole('button', { name: /Choose a folder/ }))
    const nameField = screen.getByPlaceholderText('My great app')

    // A destination that cannot be used says so while you are still typing —
    // not after you have committed to it.
    fireEvent.change(nameField, { target: { value: 'taken' } })
    await screen.findByText('/tmp/projects/taken is not empty')
    expect((screen.getByRole('button', { name: 'Approve and create' }) as HTMLButtonElement).disabled).toBe(true)

    fireEvent.change(nameField, { target: { value: 'My App' } })
    // The folder name is derived from the project name, visibly.
    await screen.findByText('/tmp/projects/my-app')

    // The dialog states what will happen before anything is granted.
    expect(screen.getByText(/only marked ready if that verification/i)).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Approve and create' }))
    await waitFor(() =>
      expect(invoked.map((entry) => entry.name)).toEqual(['approval.grant', 'workspace.create']),
    )
    const grant = invoked[0]?.payload as { scope: string; subjectId: string; summary: string }
    // The approval is granted against the RESOLVED path — the same subject
    // the main process will check when it spends it.
    expect(grant.scope).toBe('workspace.create')
    expect(grant.subjectId).toBe('/tmp/projects/my-app')
    expect(grant.summary).toMatch(/Nothing outside that folder is touched/)
  })

  it('the in-flight popover badges what is running and opens a row at its home', async () => {
    installBridge({
      'inflight.list': () => [
        {
          id: 'envelope:v',
          kind: 'envelope',
          title: 'Unattended: Bound the retry path',
          detail: '1 of 4 milestones authorised',
          startedAt: Date.now() - 60_000,
          repoPath: '/tmp/smoke-repo',
          jump: { to: 'plan', planId: smokePlan.id },
          progress: [
            { label: 'milestones', value: 0.25 },
            { label: 'time', value: 0.1 },
          ],
          mock: true,
        },
      ],
    })

    function InFlightHarness(): ReactNode {
      const { state } = useStore()
      return (
        <>
          <Titlebar />
          <div data-testid="active-surface">{state.surface}</div>
        </>
      )
    }
    render(
      <StoreProvider>
        <InFlightHarness />
      </StoreProvider>,
    )

    // The badge counts what is running, without the popover being open.
    const button = await screen.findByRole('button', { name: /In flight/ })
    await waitFor(() => expect(within(button).getByText('1')).toBeTruthy())

    fireEvent.click(button)
    await screen.findByText('Unattended: Bound the retry path')
    await screen.findByText(/1 of 4 milestones authorised/)

    // Every row opens where its work lives — a status you cannot act on is
    // decoration.
    fireEvent.click(screen.getByText('Unattended: Bound the retry path'))
    await waitFor(() => expect(screen.getByTestId('active-surface').textContent).toBe('backlog'))
  })

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

  it('hides Agy for an executor seat and replaces an ineligible preset', async () => {
    render(
      <StoreProvider>
        <AgentPickerHarness
          initial={{
            vendor: 'agy',
            model: 'gemini-real-pro',
            effort: 'high',
            persona: '',
          }}
          role="executor"
        />
      </StoreProvider>,
    )

    const vendor = screen.getAllByRole('combobox')[0] as HTMLSelectElement
    expect(within(vendor).queryByRole('option', { name: 'Agy' })).toBeNull()
    await waitFor(() => {
      expect(screen.getByTestId('picker-config').textContent).toBe('claude:')
    })
  })

  it('the Parley surface survives a session opening, and the exchange folds', async () => {
    render(
      <StoreProvider>
        <ParleySurface />
      </StoreProvider>,
    )

    // Opening drives SessionView through detail null → loaded — the exact
    // transition that once changed the hook count and blacked the window.
    const row = await screen.findByText(session.matter)
    fireEvent.click(row)

    await screen.findByText(verdict.decision)

    // Settled with an outcome: the exchange is folded to its bar, and the
    // transcript's content is not in the tree until the bar is opened.
    expect(screen.queryByText(turn.text)).toBeNull()
    const bar = await screen.findByText('Exchange')
    fireEvent.click(bar)
    await screen.findByText(turn.text)
  })

  it('the Backlog surface mounts with items and a pending foreman proposal', async () => {
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )

    // All-repos view: the cross-repo board, no tabs.
    await screen.findByText(openItem.title)

    // Selecting the repo lands on the Overview tab: the ForemanPanel with
    // its pending proposal — and the board is genuinely elsewhere.
    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    await screen.findByText(proposal.title)
    await screen.findByText('Accept into a plan')
    // The board is genuinely elsewhere. Its column header is the marker —
    // the item TITLE also appears in the foreman card's Selected list.
    expect(screen.queryByText('Closure proposed')).toBeNull()

    // The Backlog tab carries the board — asserted explicitly so the tab
    // shell can never quietly render nothing while this suite stays green.
    fireEvent.click(screen.getByRole('tab', { name: /Backlog/ }))
    await screen.findByText('Closure proposed')
    await screen.findByText(openItem.title)

    fireEvent.click(screen.getByRole('tab', { name: /Learnings/ }))
    expect(screen.queryByText('Closure proposed')).toBeNull()
  })

  it('a worktree plan offers its Grid door, and the knock spawns at the worktree path', async () => {
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const worktreePlan = { ...smokePlan, isolation: 'worktree' as const, status: 'ready' as const }
    installBridge({
      'plan.get': () => ({
        plan: worktreePlan,
        milestones: [smokeMilestone],
        worktree: {
          planId: worktreePlan.id,
          originPath: '/tmp/smoke-repo',
          path: '/tmp/smoke-worktree',
          branch: 'parley/plan-x',
          baseBranch: 'main',
          baseCommit: 'c'.repeat(40),
          createdAt: 1_700_000_000_000,
          landedAt: null,
          lastError: '',
          orphaned: false,
        },
      }),
      'ledger.list': () => [],
      'pane.open': (payload) => {
        invoked.push({ name: 'pane.open', payload })
        throw new Error('no pty in the smoke harness')
      },
    })

    function GridDoorHarness(): ReactNode {
      const { state, openPlan } = useStore()
      return (
        <>
          <button onClick={() => void openPlan(worktreePlan.id)}>Open the plan</button>
          <div data-testid="active-surface">{state.surface}</div>
          {state.planDetail ? (
            <PlanPanel
              detail={state.planDetail}
              ledger={state.planLedger}
              onRefresh={() => {}}
              host="backlog"
            />
          ) : null}
          <div style={{ display: state.surface === 'grid' ? 'contents' : 'none' }}>
            <GridSurface />
          </div>
        </>
      )
    }
    render(
      <StoreProvider>
        <GridDoorHarness />
      </StoreProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Open the plan' }))
    // Mid-run worktree plans get the door too, not only landed-waiting ones.
    const door = await screen.findByRole('button', { name: 'Open worktree in Grid' })
    fireEvent.click(door)

    // The knock switched surfaces and the Grid consumed it: a shell spawn was
    // requested at the worktree's own path.
    await waitFor(() => expect(screen.getByTestId('active-surface').textContent).toBe('grid'))
    await waitFor(() => expect(invoked).toHaveLength(1))
    expect((invoked[0]?.payload as { cwd: string; kind: string }).cwd).toBe('/tmp/smoke-worktree')
    expect((invoked[0]?.payload as { cwd: string; kind: string }).kind).toBe('shell')
  })

  it('offers an unattended run on a worktree plan, states its bounds, and grants the envelope', async () => {
    const invoked: Array<{ name: CommandName; payload: unknown }> = []
    const worktreePlan = { ...smokePlan, isolation: 'worktree' as const }
    installBridge({
      'plan.get': () => ({ plan: worktreePlan, milestones: [smokeMilestone], worktree: null }),
      'ledger.list': () => [],
      'approval.grant': (payload) => {
        invoked.push({ name: 'approval.grant', payload })
        return { id: 'z'.repeat(36), scope: 'plan.envelope', subjectId: worktreePlan.id }
      },
      'envelope.start': (payload) => {
        invoked.push({ name: 'envelope.start', payload })
        return {
          id: 'v'.repeat(36),
          planId: worktreePlan.id,
          state: 'running',
          caps: { maxMilestones: 1, maxWallClockMs: 28_800_000, maxSpendUsd: 0 },
          milestonesRun: 0,
          startCostUsd: 0,
          detail: '',
          startedAt: Date.now(),
          endedAt: null,
        }
      },
    })

    function EnvelopeHarness(): ReactNode {
      const { state, openPlan } = useStore()
      return (
        <>
          <button onClick={() => void openPlan(worktreePlan.id)}>Open the plan</button>
          {state.planDetail ? (
            <PlanPanel
              detail={state.planDetail}
              ledger={state.planLedger}
              onRefresh={() => {}}
              host="backlog"
            />
          ) : null}
        </>
      )
    }
    render(
      <StoreProvider>
        <EnvelopeHarness />
      </StoreProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Open the plan' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Run unattended…' }))

    // The dialog states what it will NOT do — the part that makes the one
    // click honest.
    await screen.findByText(/never lands the branch|always ends before landing/i)
    await screen.findByText(/continuing takes\s+a fresh envelope/i)
    await screen.findByText(/Closing the lid still suspends the/i)

    // Exact: the milestone row's own 'Approve and run' sits behind the dialog.
    fireEvent.click(screen.getByRole('button', { name: 'Approve and run 1' }))

    await waitFor(() => expect(invoked.map((i) => i.name)).toEqual(['approval.grant', 'envelope.start']))
    const grant = invoked[0]?.payload as { scope: string; summary: string }
    expect(grant.scope).toBe('plan.envelope')
    // The durable summary names the bounds and the two hard limits.
    expect(grant.summary).toMatch(/unattended in an isolated worktree/)
    expect(grant.summary).toMatch(/never lands the branch/)
    const start = invoked[1]?.payload as { caps: { maxMilestones: number } }
    expect(start.caps.maxMilestones).toBe(1)
  })

  it('the dev-container card renders the choice and the toggle invokes by name', async () => {
    const invoked: CommandName[] = []
    let enabled = false
    installBridge({
      'repo.containerStatus': () => ({
        enabled,
        configPresent: true,
        cli: { present: true, version: '0.87.0-smoke', detail: '/smoke/devcontainer' },
      }),
      'repo.setContainer': (payload) => {
        invoked.push('repo.setContainer')
        enabled = (payload as { enabled: boolean }).enabled
        return {
          enabled,
          configPresent: true,
          cli: { present: true, version: '0.87.0-smoke', detail: '/smoke/devcontainer' },
        }
      },
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    await screen.findByText('Dev container')
    // Off: the hint names the machine and the available CLI.
    await screen.findByText(/devcontainer 0.87.0-smoke is available/)

    fireEvent.click(screen.getByRole('button', { name: 'Enable' }))
    await waitFor(() => expect(invoked).toEqual(['repo.setContainer']))
    // On: the card reports the routed state and the snapshot rule.
    await screen.findByText(/run in its dev container/)
    await screen.findByRole('button', { name: 'Disable' })
  })

  it('archives, hides, reveals and restores a repository from the mounted sidebar', async () => {
    const archiveCalls: Array<{ repoPath: string; archived: boolean }> = []
    let archived = false
    installBridge({
      'repos.list': (payload) => {
        const includeArchived = (payload as { includeArchived: boolean }).includeArchived
        return {
          repos:
            archived && !includeArchived
              ? []
              : [
                  {
                    repoPath: '/tmp/smoke-repo',
                    archived,
                    planCount: 1,
                    attentionPlans: 0,
                    openItems: 1,
                    pendingTriage: 0,
                    hasPendingProposal: false,
                  },
                ],
          archivedCount: archived ? 1 : 0,
        }
      },
      'repos.archive': (payload) => {
        const request = payload as { repoPath: string; archived: boolean }
        archiveCalls.push(request)
        archived = request.archived
        return { ok: true }
      },
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    fireEvent.click(await screen.findByRole('button', { name: 'Archive repository' }))

    await screen.findByRole('button', { name: 'Show 1 archived' })
    await waitFor(() => {
      expect(screen.queryByTitle('/tmp/smoke-repo')).toBeNull()
      expect(screen.queryByRole('tab', { name: /Overview/ })).toBeNull()
    })

    fireEvent.click(screen.getByRole('button', { name: 'Show 1 archived' }))
    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    await screen.findByText('archived')
    fireEvent.click(await screen.findByRole('button', { name: 'Restore repository' }))

    await waitFor(() => {
      expect(screen.queryByText('archived')).toBeNull()
    })
    expect(archiveCalls).toEqual([
      { repoPath: '/tmp/smoke-repo', archived: true },
      { repoPath: '/tmp/smoke-repo', archived: false },
    ])
  })

  it("never renders one repository's cached actions under another repository", async () => {
    const repoB = '/tmp/smoke-repo-b'
    const scopedItem = { ...openItem, title: 'Repo A scoped action' }
    const scopedLearning: Learning = {
      id: 'learning-smoke-a',
      repoPath: openItem.repoPath,
      text: 'Repo A scoped learning',
      state: 'confirmed',
      source: 'manual',
      originSessionId: null,
      mock: true,
      createdAt: 1_700_000_000_000,
    }
    installBridge({
      'backlog.list': (payload) => {
        const repoPath = (payload as { repoPath?: string }).repoPath
        if (repoPath === repoB) throw new Error('Repo B backlog unavailable.')
        return repoPath === openItem.repoPath ? [scopedItem] : []
      },
      'learnings.list': (payload) => {
        const repoPath = (payload as { repoPath?: string }).repoPath
        if (repoPath === repoB) throw new Error('Repo B learnings unavailable.')
        return repoPath === openItem.repoPath ? [scopedLearning] : []
      },
      'repos.list': () => ({
        repos: [
          {
            repoPath: openItem.repoPath,
            archived: false,
            planCount: 1,
            attentionPlans: 0,
            openItems: 1,
            pendingTriage: 0,
            hasPendingProposal: false,
          },
          {
            repoPath: repoB,
            archived: false,
            planCount: 0,
            attentionPlans: 0,
            openItems: 0,
            pendingTriage: 0,
            hasPendingProposal: false,
          },
        ],
        archivedCount: 0,
      }),
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
        <Notices />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle(openItem.repoPath))
    fireEvent.click(screen.getByRole('tab', { name: /Backlog/ }))
    await screen.findByText(scopedItem.title)
    fireEvent.click(screen.getByRole('tab', { name: /Learnings/ }))
    await screen.findByText(scopedLearning.text)

    fireEvent.click(await screen.findByTitle(repoB))
    fireEvent.click(screen.getByRole('tab', { name: /Backlog/ }))
    await screen.findByText('Repo B backlog unavailable.')
    expect(screen.queryByText(scopedItem.title)).toBeNull()
    fireEvent.click(screen.getByRole('tab', { name: /Learnings/ }))
    await screen.findByText('Repo B learnings unavailable.')
    expect(screen.queryByText(scopedLearning.text)).toBeNull()
  })

  it("surfaces a repository archive refusal verbatim", async () => {
    installBridge({}, { 'repos.archive': 'Repository has a running milestone.' })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
        <Notices />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    fireEvent.click(await screen.findByRole('button', { name: 'Archive repository' }))

    await screen.findByText('Repository has a running milestone.')
  })

  it('refetches repository summaries after each repository activity family changes', async () => {
    let summaryReads = 0
    installBridge({
      'repos.list': () => {
        summaryReads += 1
        return {
          repos: [
            {
              repoPath: '/tmp/smoke-repo',
              archived: false,
              planCount: 1,
              attentionPlans: 0,
              openItems: 1,
              pendingTriage: 0,
              hasPendingProposal: false,
            },
          ],
          archivedCount: 0,
        }
      },
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )
    await screen.findByTitle('/tmp/smoke-repo')

    const events: AppEvent[] = [
      { type: 'session.status', sessionId: session.id, status: 'complete' },
      { type: 'plan.status', planId: smokePlan.id, status: 'ready' },
      { type: 'loop.status', loopId: 'loop-smoke', status: 'succeeded' },
      { type: 'backlog.changed', repoPath: '/tmp/smoke-repo' },
    ]
    for (const event of events) {
      const before = summaryReads
      act(() => appEventListener?.(event))
      await waitFor(() => expect(summaryReads).toBeGreaterThan(before))
    }
  })

  it('a plan opens in place on the Plans tab, and the gate fails closed', async () => {
    const invoked: CommandName[] = []
    installBridge({
      'plan.get': () => ({
        plan: smokePlan,
        milestones: [failedSmokeMilestone],
        worktree: null,
      }),
      'approval.grant': () => invoked.push('approval.grant'),
      'plan.runMilestone': () => invoked.push('plan.runMilestone'),
      'plan.resumeMilestone': () => invoked.push('plan.resumeMilestone'),
      'plan.adoptMilestone': () => invoked.push('plan.adoptMilestone'),
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )

    // A plans-only repo appears from the summaries and gets full tabs.
    await screen.findByTitle('/tmp/smoke-plans-only')

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    fireEvent.click(await screen.findByRole('tab', { name: /Plans/ }))
    fireEvent.click(await screen.findByText(smokePlan.title))

    // The first mounted PlanPanel in the suite's history: the milestone
    // renders, and its approval gate sees the blocking ledger fixture.
    await screen.findByText(failedSmokeMilestone.title)
    fireEvent.click(await screen.findByText('Approve and retry'))
    await screen.findByText(/finding needs a disposition/)
    await screen.findByText(blockingEntry.text)
    await assertLedgerGateActionsDisabled(invoked)
  })

  it('an unavailable ledger disables the gate instead of un-gating it', async () => {
    const invoked: CommandName[] = []
    installBridge({
      'ledger.list': () => undefined,
      'plan.get': () => ({
        plan: smokePlan,
        milestones: [failedSmokeMilestone],
        worktree: null,
      }),
      'approval.grant': () => invoked.push('approval.grant'),
      'plan.runMilestone': () => invoked.push('plan.runMilestone'),
      'plan.resumeMilestone': () => invoked.push('plan.resumeMilestone'),
      'plan.adoptMilestone': () => invoked.push('plan.adoptMilestone'),
    })
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    fireEvent.click(await screen.findByRole('tab', { name: /Plans/ }))
    fireEvent.click(await screen.findByText(smokePlan.title))
    await screen.findByText(failedSmokeMilestone.title)
    fireEvent.click(await screen.findByText('Approve and retry'))

    // Null means unknown, and unknown fails CLOSED.
    await screen.findByText(/ledger could not be loaded/)
    await assertLedgerGateActionsDisabled(invoked)
  })

  it("a rejected ledger keeps the gate closed and shows main's message", async () => {
    const invoked: CommandName[] = []
    installBridge(
      {
        'plan.get': () => ({
          plan: smokePlan,
          milestones: [failedSmokeMilestone],
          worktree: null,
        }),
        'approval.grant': () => invoked.push('approval.grant'),
        'plan.runMilestone': () => invoked.push('plan.runMilestone'),
        'plan.resumeMilestone': () => invoked.push('plan.resumeMilestone'),
        'plan.adoptMilestone': () => invoked.push('plan.adoptMilestone'),
      },
      { 'ledger.list': 'Main refused to read the findings ledger.' },
    )
    render(
      <StoreProvider>
        <OnSurface surface="backlog">
          <BacklogSurface />
        </OnSurface>
        <Notices />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByTitle('/tmp/smoke-repo'))
    fireEvent.click(await screen.findByRole('tab', { name: /Plans/ }))
    fireEvent.click(await screen.findByText(smokePlan.title))
    await screen.findByText(failedSmokeMilestone.title)
    await screen.findByText('Main refused to read the findings ledger.')
    fireEvent.click(await screen.findByText('Approve and retry'))

    await screen.findByText(/ledger could not be loaded/)
    await assertLedgerGateActionsDisabled(invoked)
  })

  it('a rejected plan.get leaves no plan open', async () => {
    installBridge({}, { 'plan.get': 'Main refused to open this plan.' })
    render(
      <StoreProvider>
        <PlanOpenHarness />
        <Notices />
      </StoreProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Open earlier plan' }))

    await screen.findByText('Main refused to open this plan.')
    expect(screen.getByText('No plan open')).toBeTruthy()
    expect(screen.queryByText(smokeMilestone.title)).toBeNull()
  })

  it('a slower earlier openPlan loses to the newer selection', async () => {
    let resolveEarlierLedger!: (ledger: LedgerEntry[] | undefined) => void
    let markEarlierLedgerStarted!: () => void
    const earlierLedger = new Promise<LedgerEntry[] | undefined>((resolve) => {
      resolveEarlierLedger = resolve
    })
    const earlierLedgerStarted = new Promise<void>((resolve) => {
      markEarlierLedgerStarted = resolve
    })

    installBridge({
      'plan.get': (payload) => {
        const planId = (payload as { planId: string }).planId
        return {
          plan: planId === newerSmokePlan.id ? newerSmokePlan : smokePlan,
          milestones: [smokeMilestone],
          worktree: null,
        }
      },
      'ledger.list': (payload) => {
        const sessionId = (payload as { sessionId: string }).sessionId
        if (sessionId === newerSmokePlan.sessionId) return [newerLedgerEntry]
        markEarlierLedgerStarted()
        return earlierLedger
      },
    })
    render(
      <StoreProvider>
        <PlanOpenHarness />
      </StoreProvider>,
    )

    fireEvent.click(screen.getByRole('button', { name: 'Open earlier plan' }))
    await earlierLedgerStarted
    fireEvent.click(screen.getByRole('button', { name: 'Open newer plan' }))
    await screen.findByText(newerSmokePlan.title)
    await screen.findByText(newerLedgerEntry.text)

    await act(async () => {
      resolveEarlierLedger(undefined)
      await earlierLedger
    })

    expect(screen.getByText(newerSmokePlan.title)).toBeTruthy()
    expect(screen.getByText(newerLedgerEntry.text)).toBeTruthy()
    expect(screen.queryByText(smokePlan.title)).toBeNull()
    expect(screen.queryByText('Ledger unknown')).toBeNull()
  })

  it('a holds deep link opens one approval gate across the two mounted hosts', async () => {
    installBridge({
      'session.get': () => ({
        session,
        turns: [turn],
        interjections: [],
        verdict,
        findings: [],
        ledger: [],
        plans: [smokePlan],
      }),
      'holds.list': () => [approvalWaitingHold],
    })
    render(
      <StoreProvider>
        <AppMountedSurfaces />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByText(session.matter))
    fireEvent.click(
      await screen.findByTitle(`${smokePlan.title} — ${smokePlan.kind}, ${smokePlan.status}`),
    )

    fireEvent.click(screen.getByRole('button', { name: 'Switch to Repos' }))
    const backlogHost = screen.getByTestId('backlog-host')
    fireEvent.click(await within(backlogHost).findByTitle(smokePlan.repoPath))
    fireEvent.click(await within(backlogHost).findByRole('tab', { name: /Plans/ }))
    fireEvent.click(
      await within(backlogHost).findByTitle(
        `${smokePlan.title} — ${smokePlan.kind}, ${smokePlan.status}`,
      ),
    )
    await waitFor(() => {
      expect(within(backlogHost).getByText(smokeMilestone.title)).toBeTruthy()
    })

    fireEvent.click(screen.getByTitle('Holds — what is waiting on you'))
    fireEvent.click(await screen.findByRole('button', { name: 'Open' }))

    const parleyHost = screen.getByTestId('parley-host')
    const approvalDialogs = (): NodeListOf<Element> =>
      document.querySelectorAll('[role="dialog"][aria-label="Approve milestone 1"]')
    await waitFor(() => {
      expect(approvalDialogs()).toHaveLength(1)
    })
    expect(parleyHost.contains(approvalDialogs()[0] ?? null)).toBe(true)

    fireEvent.click(screen.getByRole('button', { name: 'Switch to Repos' }))
    await waitFor(() => {
      expect(approvalDialogs()).toHaveLength(0)
    })
  })

  it('the Loops surface mounts empty', async () => {
    render(
      <StoreProvider>
        <LoopsSurface />
      </StoreProvider>,
    )
    await screen.findByText(/No loops yet/)
  })
})

// ─── Self-update in the holds popover ───────────────────────────────────────

const selfUpdateHold: Hold = {
  id: 'hold-self-update-smoke',
  kind: 'self-update',
  sessionId: null,
  planId: null,
  milestoneId: null,
  loopId: null,
  repoPath: '/tmp/parley-checkout',
  title: 'A new Parley build is verified',
  detail: 'Relaunch to run the new build, or decline to keep this one.',
  sinceAt: 1_700_000_000_000,
  mock: false,
  actionable: true,
}

const pendingUpdate = {
  id: '9'.repeat(36),
  planId: 'e'.repeat(36),
  state: 'green' as const,
  detail: 'built',
  createdAt: 1_700_000_000_000,
  decidedAt: null,
}

/** Opens the popover the way the titlebar chip would; the provider's own
 * hydration supplies the holds from the bridge's stateful queue. */
function OpenHolds(): ReactNode {
  const { dispatch } = useStore()
  useEffect(() => {
    dispatch({ type: 'holdsPanel', open: true })
  }, [dispatch])
  return <HoldsPopover />
}

describe('the self-update hold in the popover', () => {
  it('declines through the real command, resolved from the live offer', async () => {
    const invoked: Array<{ command: string; payload: unknown }> = []
    // Stateful on purpose: the provider hydrates from holds.list, so a static
    // fixture would either race the seed or never clear after the decision.
    let queue: Hold[] = [selfUpdateHold]
    installBridge({
      'holds.list': () => queue,
      'selfupdate.pending': () => pendingUpdate,
      'selfupdate.decline': (payload) => {
        invoked.push({ command: 'selfupdate.decline', payload })
        queue = []
        return { ...pendingUpdate, state: 'declined' }
      },
    })
    render(
      <StoreProvider>
        <OpenHolds />
      </StoreProvider>,
    )

    // Inline controls, not a jump: this row has nowhere else to go.
    await screen.findByText(selfUpdateHold.title)
    expect(screen.queryByText('Open')).toBeNull()
    await screen.findByText('Relaunch')

    fireEvent.click(screen.getByText('Not now'))
    // Declining resolves the CURRENT offer's id, then clears the queue.
    await screen.findByText(/Nothing is waiting on you/)
    expect(invoked).toEqual([
      { command: 'selfupdate.decline', payload: { updateId: pendingUpdate.id } },
    ])
  })

  it('relaunch confirms the costs first, then invokes by name', async () => {
    const invoked: string[] = []
    let queue: Hold[] = [selfUpdateHold]
    installBridge({
      'holds.list': () => queue,
      'selfupdate.pending': () => pendingUpdate,
      'selfupdate.relaunch': (payload) => {
        invoked.push(`selfupdate.relaunch:${(payload as { updateId: string }).updateId}`)
        queue = []
        return { ...pendingUpdate, state: 'relaunched' }
      },
    })
    render(
      <StoreProvider>
        <OpenHolds />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByText('Relaunch'))

    // The confirm names the costs before anything quits.
    await screen.findByText(/quits Parley/)
    await screen.findByText(/npm run dev/)
    expect(invoked).toEqual([])

    fireEvent.click(screen.getByText('Quit and relaunch'))
    await screen.findByText(/Nothing is waiting on you/)
    expect(invoked).toEqual([`selfupdate.relaunch:${pendingUpdate.id}`])
  })

  it('a vanished offer refreshes the queue instead of confirming a ghost', async () => {
    let queue: Hold[] = [selfUpdateHold]
    installBridge({
      'holds.list': () => queue,
      // Decided elsewhere: the offer is gone, and so is its hold.
      'selfupdate.pending': () => {
        queue = []
        return null
      },
    })
    render(
      <StoreProvider>
        <OpenHolds />
      </StoreProvider>,
    )

    fireEvent.click(await screen.findByText('Relaunch'))
    // No confirm — the stale chip resolves to nothing and the queue reloads.
    await screen.findByText(/Nothing is waiting on you/)
    expect(screen.queryByText(/quits Parley/)).toBeNull()
  })
})
