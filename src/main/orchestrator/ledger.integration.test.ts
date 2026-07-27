import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import {
  emptyUsage,
  type FindingOccurrence,
  type Milestone,
  type Session,
  type WorkPlan,
} from '@shared/domain'
import { occurrenceState } from '@shared/ledger'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Pipeline } from './pipeline'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(): {
  pipeline: Pipeline
  repo: Repo
  registry: AgentRegistry
  events: AppEvent[]
  session: Session
} {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const pipeline = new Pipeline({ repo, registry, emit: (event) => events.push(event) })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should the retry path change?',
    project: '',
    repoPath: null,
    agentA: claude,
    agentB: codex,
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  return { pipeline, repo, registry, events, session }
}

function gitRepo(prefix: string): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
  }
  git('init', '-q')
  git('config', 'user.email', 'test@example.invalid')
  git('config', 'user.name', 'Parley Test')
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  git('commit', '-qm', 'seed')
  return repoPath
}

function makePlan(
  repo: Repo,
  sessionId: string,
  repoPath: string,
  status: WorkPlan['status'] = 'ready',
): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Retry plan',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status,
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  })
}

function makeMilestone(
  repo: Repo,
  planId: string,
  patch: Partial<Milestone> = {},
): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index: 0,
    title: 'Fix retry exhaustion',
    intent: 'Surface exhaustion and cover it with a deterministic check.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'audited',
    auditNote: '',
    testCommand: 'node --version',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
    ...patch,
  })
}

function recordOccurrence(
  repo: Repo,
  sessionId: string,
  text: string,
  provenance: Omit<FindingOccurrence, 'id' | 'findingId' | 'seq' | 'createdAt'>,
): FindingOccurrence {
  const finding = repo.upsertLedgerFinding(sessionId, text)
  return repo.recordFindingOccurrence({ findingId: finding.id, ...provenance })
}

describe('pipeline finding ledger ingestion', () => {
  it('records audit blockers with provenance and keeps planner dispositions non-resolving', async () => {
    const { pipeline, repo, registry, events, session } = harness()
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-ledger-audit-'))
    const plan = makePlan(repo, session.id, repoPath, 'drafting')
    const auditor = registry.get('codex')
    const originalRun = auditor.run.bind(auditor)
    auditor.run = async (request) =>
      request.systemPrompt.includes('audit other engineers')
        ? {
            text: [
              '```json',
              JSON.stringify({
                verdict: 'needs-changes',
                dispositions: [
                  {
                    milestone: 0,
                    disposition: 'revise',
                    note: 'The approval route needs an explicit test.',
                  },
                  {
                    milestone: 1,
                    disposition: 'reject',
                    note: 'The rollback milestone deletes data.',
                  },
                ],
                blockingConcerns: ['The rollback policy is undefined.'],
              }),
              '```',
            ].join('\n'),
            usage: emptyUsage(),
            resumeId: 'audit-thread',
            exitCode: 0,
            error: null,
          }
        : originalRun(request)

    await pipeline.draft(plan, 'Bound the retry path.')

    const findings = repo.listLedgerFindings(session.id)
    const occurrences = repo.listFindingOccurrences(session.id)
    // Audit occurrences are plan-level, never milestone ids: correction deletes
    // the draft milestones this audit judged and recreates them with new ids, so
    // any id recorded here would dangle on every normal drafting run. The
    // milestone context lives in the text, where it survives plan replacement —
    // and the two distinct prefixes pin the index-to-context mapping, which the
    // previous expect.any(String) never did.
    expect(findings.map((finding) => finding.text).sort()).toEqual(
      [
        'Milestone 1 (Add a retry ceiling): The approval route needs an explicit test.',
        'Milestone 2 (Cover exhaustion with a test): The rollback milestone deletes data.',
        'The rollback policy is undefined.',
      ].sort(),
    )
    expect(occurrences).toHaveLength(3)
    for (const occurrence of occurrences) {
      expect(occurrence).toMatchObject({
        planId: plan.id,
        milestoneId: null,
        round: null,
        kind: 'blocking',
        source: 'audit',
      })
    }
    expect(repo.getPlan(plan.id)?.correctionDispositions.length).toBeGreaterThan(0)
    expect(repo.listFindingDispositions(session.id)).toEqual([])
    expect(events.filter((event) => event.type === 'session.ledger')).toHaveLength(3)
  })

  it('settles only open review blockers from the passing milestone across remediation rounds', async () => {
    const { pipeline, repo, events, session } = harness()
    const repoPath = gitRepo('parley-ledger-pass-')
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id)
    const otherMilestone = makeMilestone(repo, plan.id, {
      id: newId(),
      index: 1,
      title: 'Other milestone',
    })
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')
    const run = pipeline.runMilestone(milestone.id, approval.id)

    // These unrelated occurrences arrive after execution has synchronously
    // passed its approval gate. They remain useful for proving that a successful
    // milestone settles only its own review occurrences.
    const repeated = 'the retry ceiling is not surfaced to the caller'
    const auditOccurrence = recordOccurrence(repo, session.id, repeated, {
      planId: plan.id,
      milestoneId: milestone.id,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })
    const otherOccurrence = recordOccurrence(repo, session.id, repeated, {
      planId: plan.id,
      milestoneId: otherMilestone.id,
      round: 0,
      kind: 'blocking',
      source: 'review',
    })
    const done = await run

    expect(done.status).toBe('complete')
    const occurrences = repo.listFindingOccurrences(session.id)
    const dispositions = repo.listFindingDispositions(session.id)
    const milestoneBlockers = occurrences.filter(
      (occurrence) =>
        occurrence.milestoneId === milestone.id &&
        occurrence.source === 'review' &&
        occurrence.kind === 'blocking',
    )
    expect(milestoneBlockers).toHaveLength(2)
    expect(milestoneBlockers.map((occurrence) => occurrence.round)).toEqual([0, 0])
    expect(dispositions).toHaveLength(2)
    expect(dispositions).toEqual(
      expect.arrayContaining(
        milestoneBlockers.map((occurrence) =>
          expect.objectContaining({
            findingId: occurrence.findingId,
            occurrenceId: occurrence.id,
            state: 'resolved',
            source: 'pipeline',
          }),
        ),
      ),
    )
    expect(occurrenceState(auditOccurrence, dispositions)).toBe('open')
    expect(occurrenceState(otherOccurrence, dispositions)).toBe('open')
    // Pinned positively, not just iterated: with zero note occurrences this loop
    // ran zero times, so an implementation that silently dropped reviewer notes
    // passed every test and made the never-settle-notes guarantee vacuous.
    const noteOccurrences = occurrences.filter((occurrence) => occurrence.kind === 'note')
    expect(noteOccurrences.length).toBeGreaterThan(0)
    for (const note of noteOccurrences) {
      expect(note).toMatchObject({ source: 'review', milestoneId: milestone.id })
      expect(note.round).not.toBeNull()
      expect(occurrenceState(note, dispositions)).toBe('open')
    }
    expect(
      events.some(
        (event) =>
          event.type === 'session.ledger' &&
          event.entry.dispositions.some((disposition) => disposition.source === 'pipeline'),
      ),
    ).toBe(true)
  })

  it('does not stack a pipeline resolution on a blocker a human already dismissed', async () => {
    const { pipeline, repo, session } = harness()
    const repoPath = gitRepo('parley-ledger-dismissed-')
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id)

    // A review blocker from an earlier round, already dismissed by a person.
    const dismissed = recordOccurrence(repo, session.id, 'flaky assertion, not a defect', {
      planId: plan.id,
      milestoneId: milestone.id,
      round: 0,
      kind: 'blocking',
      source: 'review',
    })
    repo.disposeFinding({
      findingId: dismissed.findingId,
      occurrenceId: dismissed.id,
      state: 'dismissed',
      note: 'Human judgement: the objection was wrong.',
      source: 'human',
    })

    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')
    const done = await pipeline.runMilestone(milestone.id, approval.id)
    expect(done.status).toBe('complete')

    // The pass settles only occurrences that are still open. A pipeline
    // 'resolved' stacked on the human 'dismissed' would rewrite a person's
    // decision with the machine's, and the display state would flip.
    const dispositions = repo
      .listFindingDispositions(session.id)
      .filter((disposition) => disposition.occurrenceId === dismissed.id)
    expect(dispositions).toHaveLength(1)
    expect(dispositions[0]).toMatchObject({ state: 'dismissed', source: 'human' })
    expect(occurrenceState(dismissed, repo.listFindingDispositions(session.id))).toBe('dismissed')
  })

  it('does not settle review blockers when the milestone fails', async () => {
    const { pipeline, repo, session } = harness()
    const repoPath = gitRepo('parley-ledger-stubborn-')
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')

    const done = await pipeline.runMilestone(milestone.id, approval.id)

    expect(done.status).toBe('failed')
    const occurrences = repo.listFindingOccurrences(session.id)
    expect(occurrences.filter((occurrence) => occurrence.kind === 'blocking')).toHaveLength(6)
    expect(new Set(occurrences.map((occurrence) => occurrence.round))).toEqual(
      new Set([0, 1, 2]),
    )
    expect(repo.listFindingDispositions(session.id)).toEqual([])
  })

  it('leaves the ledger untouched during adoption', async () => {
    const { pipeline, repo, events, session } = harness()
    const repoPath = gitRepo('parley-ledger-adopt-')
    writeFileSync(join(repoPath, 'existing.txt'), 'already here\n')
    const plan = makePlan(repo, session.id, repoPath)
    const milestone = makeMilestone(repo, plan.id, {
      expectedPaths: ['existing.txt'],
    })
    recordOccurrence(repo, session.id, 'Existing audit concern.', {
      planId: plan.id,
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })
    recordOccurrence(repo, session.id, 'Earlier review blocker.', {
      planId: plan.id,
      milestoneId: milestone.id,
      round: 0,
      kind: 'blocking',
      source: 'review',
    })
    const beforeOccurrences = repo.listFindingOccurrences(session.id)
    const beforeDispositions = repo.listFindingDispositions(session.id)
    const ledgerEventCount = events.filter((event) => event.type === 'session.ledger').length

    const done = await pipeline.adoptMilestone(milestone.id)

    expect(done.status).toBe('complete')
    expect(done.adopted).toBe(true)
    expect(repo.listFindingOccurrences(session.id)).toEqual(beforeOccurrences)
    expect(repo.listFindingDispositions(session.id)).toEqual(beforeDispositions)
    expect(events.filter((event) => event.type === 'session.ledger')).toHaveLength(
      ledgerEventCount,
    )
  })
})
