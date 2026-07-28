// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type {
  BacklogItem,
  ForemanProposal,
  Milestone,
  Session,
  Turn,
  Usage,
  Verdict,
  WorkPlan,
} from '@shared/domain'
import type { CommandName, LedgerEntry } from '@shared/ipc'
import { useEffect, type ReactNode } from 'react'
import { StoreProvider, useStore, type Surface } from '../state'
import { ParleySurface } from './ParleySurface'
import { BacklogSurface } from './BacklogSurface'
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
  usage,
  mock: true,
  createdAt: 1_700_000_000_000,
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

/**
 * The fake bridge: every command the mounted surfaces reach for, answered
 * with fixtures. An unlisted command resolves undefined, which the store's
 * attempt() guards tolerate — but list the ones under test explicitly so a
 * renamed command fails loudly here rather than passing vacuously.
 */
function installBridge(
  overrides: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {},
): void {
  const handlers: Partial<Record<CommandName, (payload?: unknown) => unknown>> = {
    'app.info': () => ({ mock: true, codexDefaultModel: '', selfRepoPath: null }),
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
    'ledger.list': () => [blockingEntry],
    'backlog.list': () => [openItem],
    'learnings.list': () => [],
    'foreman.list': () => [proposal],
    'plan.list': (payload) =>
      (payload as { repoPath?: string } | undefined)?.repoPath === '/tmp/smoke-repo'
        ? [smokePlan]
        : [],
    'plan.get': () => ({ plan: smokePlan, milestones: [smokeMilestone], worktree: null }),
    'repos.list': () => [
      {
        repoPath: '/tmp/smoke-repo',
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
        planCount: 2,
        attentionPlans: 1,
        openItems: 0,
        pendingTriage: 0,
        hasPendingProposal: false,
      },
    ],
    'loop.list': () => [],
    'skill.list': () => [],
    'pane.list': () => [],
    ...overrides,
  }
  window.parley = {
    invoke: <T,>(command: CommandName, payload?: unknown): Promise<T> =>
      Promise.resolve(handlers[command]?.(payload) as T),
    onEvent: () => () => {},
    onPtyData: () => () => {},
    platform: 'darwin',
  }
}

beforeEach(installBridge)
afterEach(cleanup)

describe('mounted-surface smoke', () => {
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

  it('a plan opens in place on the Plans tab, and the gate fails closed', async () => {
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
    await screen.findByText(smokeMilestone.title)
    fireEvent.click(await screen.findByText('Approve and run'))
    await screen.findByText(/finding needs a disposition/)
    await screen.findByText(blockingEntry.text)
  })

  it('an unavailable ledger disables the gate instead of un-gating it', async () => {
    installBridge({ 'ledger.list': () => undefined })
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
    await screen.findByText(smokeMilestone.title)
    fireEvent.click(await screen.findByText('Approve and run'))

    // Null means unknown, and unknown fails CLOSED.
    await screen.findByText(/ledger could not be loaded/)
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
