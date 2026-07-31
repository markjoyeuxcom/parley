import { describe, expect, it, vi } from 'vitest'
import type { Milestone, TestResult, Usage } from '@shared/domain'
import { emptyUsage } from '@shared/domain'
import type { RunState } from './pipeline'
import {
  decodeMilestoneFact,
  milestonePatch,
  StoreMilestoneReporter,
  type MilestoneFact,
} from './reporter'

const milestone = {
  id: 'm1',
  expectedPaths: ['src/a.ts'],
  planId: 'p1',
  index: 0,
  title: 'Do the thing',
  intent: '',
  files: [],
  testCommand: 'npm test',
  mutations: [],
  status: 'pending',
  reviewNote: '',
  reviewBlocking: [],
  reviewNotes: [],
  reviewPassed: null,
  testResult: null,
  completedAt: null,
  adopted: false,
  auditNote: '',
} as unknown as Milestone

const testResult: TestResult = {
  command: 'npm test',
  exitCode: 0,
  stdout: '',
  stderr: '',
  durationMs: 10,
} as TestResult

const runState = { round: 2, before: null } as unknown as RunState

function harness(): {
  reporter: StoreMilestoneReporter
  rows: Array<Partial<Milestone>>
  runStates: Array<RunState | null>
  spend: Usage[]
  planStatuses: string[]
  findings: Array<Record<string, unknown>>
  emitted: Milestone[]
} {
  const rows: Array<Partial<Milestone>> = []
  const runStates: Array<RunState | null> = []
  const spend: Usage[] = []
  const planStatuses: string[] = []
  const findings: Array<Record<string, unknown>> = []
  const emitted: Milestone[] = []
  let current = milestone
  const reporter = new StoreMilestoneReporter(
    {
      updateMilestone: (_id, patch) => {
        rows.push(patch)
        current = { ...current, ...patch }
        return current
      },
      setRunState: (_id, state) => runStates.push(state),
      addPlanUsage: (_planId, usage) => spend.push(usage),
      setPlanStatus: (_planId, status) => planStatuses.push(status),
      recordFinding: (finding, id) => findings.push({ ...finding, milestoneId: id }),
      emitMilestone: (row) => emitted.push(row),
      emitActivity: () => {},
    },
    milestone,
    'p1',
  )
  return { reporter, rows, runStates, spend, planStatuses, findings, emitted }
}

describe('what a fact means for the record', () => {
  it('maps each row-changing fact to its patch', () => {
    expect(milestonePatch({ kind: 'phase', phase: 'reviewing' })).toEqual({ status: 'reviewing' })
    expect(milestonePatch({ kind: 'verification', result: testResult })).toEqual({
      testResult,
    })
    expect(
      milestonePatch({ kind: 'narrative', note: 'n', blocking: ['b'], notes: ['x'] }),
    ).toEqual({ reviewNote: 'n', reviewBlocking: ['b'], reviewNotes: ['x'] })
    expect(milestonePatch({ kind: 'judgement', passed: null })).toEqual({ reviewPassed: null })
  })

  it('ends a milestone as complete or failed, carrying the completion stamp', () => {
    expect(milestonePatch({ kind: 'finished', passed: true, note: 'ok', completedAt: 42 })).toEqual({
      status: 'complete',
      reviewNote: 'ok',
      completedAt: 42,
    })
    // A failure has no completion time: the record must not imply it finished.
    expect(
      milestonePatch({ kind: 'finished', passed: false, note: 'no', completedAt: null }),
    ).toEqual({ status: 'failed', reviewNote: 'no', completedAt: null })
  })

  it('says plainly that spend and checkpoints are not milestone columns', () => {
    // Null rather than {} — an empty patch would read as "a write with nothing
    // in it" and quietly invite an UPDATE that touches no column.
    expect(milestonePatch({ kind: 'checkpoint', runState: null })).toBeNull()
    expect(milestonePatch({ kind: 'spend', usage: emptyUsage() })).toBeNull()
  })

  it('keeps an unverified milestone unverified rather than leaving a stale result', () => {
    // Null is a real observation: no test command, or a run that never got
    // that far. Without it the record would show a green suite for work that
    // was never verified.
    expect(milestonePatch({ kind: 'verification', result: null })).toEqual({ testResult: null })
  })

  it('is total — every fact kind has an answer', () => {
    const facts: MilestoneFact[] = [
      { kind: 'phase', phase: 'executing' },
      { kind: 'phase', phase: 'testing' },
      { kind: 'planOutcome', status: 'failed' },
      { kind: 'finding', text: 'x', round: 0, blocking: true, source: 'review' },
      { kind: 'checkpoint', runState: null },
      { kind: 'spend', usage: emptyUsage() },
      { kind: 'verification', result: testResult },
      { kind: 'narrative', note: '', blocking: [], notes: [] },
      { kind: 'judgement', passed: true },
      { kind: 'finished', passed: true, note: '', completedAt: 1 },
    ]
    // No throw, no undefined: undefined would be indistinguishable from "this
    // fact changes nothing", which is a decision, not an oversight.
    for (const fact of facts) expect(milestonePatch(fact)).not.toBeUndefined()
  })
})

describe('the local reporter', () => {
  it('writes the patch, emits the row, and returns what the core should work from', () => {
    const { reporter, rows, emitted } = harness()
    const after = reporter.record({ kind: 'phase', phase: 'executing' })
    expect(rows).toEqual([{ status: 'executing' }])
    expect(after.status).toBe('executing')
    expect(emitted).toHaveLength(1)
    expect(emitted[0]?.status).toBe('executing')
  })

  it('accumulates so the core never has to re-read the store', () => {
    // The property that lets this same core run where there is no store.
    const { reporter } = harness()
    reporter.record({ kind: 'phase', phase: 'executing' })
    reporter.record({ kind: 'verification', result: testResult })
    const after = reporter.record({ kind: 'judgement', passed: true })
    expect(after.status).toBe('executing')
    expect(after.testResult).toEqual(testResult)
    expect(after.reviewPassed).toBe(true)
  })

  it('routes a checkpoint to run state and never to the milestone row', () => {
    const { reporter, rows, runStates, emitted } = harness()
    reporter.record({ kind: 'checkpoint', runState })
    reporter.record({ kind: 'checkpoint', runState: null })
    expect(runStates).toEqual([runState, null])
    expect(rows).toEqual([])
    // No row changed, so nothing may be emitted: a renderer event that carries
    // an unchanged milestone is noise the surfaces would re-render for.
    expect(emitted).toEqual([])
  })

  it('routes spend to the plan, not the milestone', () => {
    const { reporter, rows, spend } = harness()
    const usage = { ...emptyUsage(), outputTokens: 12 }
    reporter.record({ kind: 'spend', usage })
    expect(spend).toEqual([usage])
    expect(rows).toEqual([])
  })

  it('leaves the returned milestone unchanged for facts that change no row', () => {
    const { reporter } = harness()
    const before = reporter.record({ kind: 'phase', phase: 'executing' })
    const after = reporter.record({ kind: 'spend', usage: emptyUsage() })
    expect(after).toEqual(before)
  })

  it('passes activity straight through without touching the record', () => {
    const emitActivity = vi.fn()
    const reporter = new StoreMilestoneReporter(
      {
        updateMilestone: () => milestone,
        setRunState: () => {},
        addPlanUsage: () => {},
        setPlanStatus: () => {},
        recordFinding: () => {},
        emitMilestone: () => {},
        emitActivity,
      },
      milestone,
      'p1',
    )
    reporter.activity('executing', 'started')
    expect(emitActivity).toHaveBeenCalledWith('executing', 'started')
  })
})

describe('the projection that replaced the store read', () => {
  it('exposes the milestone as every fact has left it', () => {
    // The execution core used to re-read the row whenever it needed current
    // state. A machine with no database cannot, so the reporter — which
    // already applies every fact — keeps the projection and hands it back.
    const { reporter } = harness()
    expect(reporter.milestone.status).toBe('pending')
    reporter.record({ kind: 'phase', phase: 'testing' })
    expect(reporter.milestone.status).toBe('testing')
    reporter.record({ kind: 'verification', result: testResult })
    expect(reporter.milestone.testResult).toEqual(testResult)
  })

  it('leaves the definition alone, whatever facts arrive', () => {
    // The proof that carrying the definition instead of re-reading it changes
    // nothing: no fact the core can state touches expectedPaths, testCommand,
    // mutations, title or intent. They are fixed when the milestone is drafted
    // and fixed again by the approval that authorised this run.
    const { reporter } = harness()
    const definition = {
      title: reporter.milestone.title,
      intent: reporter.milestone.intent,
      testCommand: reporter.milestone.testCommand,
      mutations: reporter.milestone.mutations,
      expectedPaths: reporter.milestone.expectedPaths,
    }
    const everyFact: MilestoneFact[] = [
      { kind: 'phase', phase: 'executing' },
      { kind: 'phase', phase: 'testing' },
      { kind: 'phase', phase: 'reviewing' },
      { kind: 'checkpoint', runState: null },
      { kind: 'spend', usage: emptyUsage() },
      { kind: 'verification', result: testResult },
      { kind: 'verification', result: null },
      { kind: 'narrative', note: 'n', blocking: ['b'], notes: ['x'] },
      { kind: 'judgement', passed: false },
      { kind: 'planOutcome', status: 'failed' },
      { kind: 'finished', passed: true, note: 'done', completedAt: 1, judgement: true },
    ]
    for (const fact of everyFact) reporter.record(fact)
    expect({
      title: reporter.milestone.title,
      intent: reporter.milestone.intent,
      testCommand: reporter.milestone.testCommand,
      mutations: reporter.milestone.mutations,
      expectedPaths: reporter.milestone.expectedPaths,
    }).toEqual(definition)
  })
})

describe('findings the reviewer named', () => {
  it('routes to the ledger, never to the milestone row', () => {
    // The core observes the finding; turning it into a ledger row with
    // provenance is a local consequence that a machine with no ledger cannot
    // perform — which is the whole reason this is a fact.
    const { reporter, rows, findings } = harness()
    reporter.record({ kind: 'finding', text: 'unsafe cast', round: 1, blocking: true, source: 'review' })
    expect(rows).toEqual([])
    expect(findings).toEqual([
      { kind: 'finding', text: 'unsafe cast', round: 1, blocking: true, source: 'review', milestoneId: 'm1' },
    ])
  })

  it('fails a wire finding closed when its blocking flag did not survive', () => {
    // A blocking finding that arrived as a note would gate nothing, and the
    // milestone would pass on work a reviewer had objected to.
    expect(
      decodeMilestoneFact({ kind: 'finding', text: 'x', round: null, source: 'review' }),
    ).toMatchObject({ blocking: false })
    expect(
      decodeMilestoneFact({ kind: 'finding', text: 'x', round: null, blocking: true, source: 'review' }),
    ).toMatchObject({ blocking: true })
  })

  it('refuses a finding with no text, no round key, or an invented source', () => {
    expect(decodeMilestoneFact({ kind: 'finding', text: '', round: null, source: 'review' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'finding', text: 'x', source: 'review' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'finding', text: 'x', round: null, source: 'vibes' })).toBeNull()
  })
})
