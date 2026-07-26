import { describe, expect, it } from 'vitest'
import { type FindingOccurrence, type Session } from '@shared/domain'
import { openDatabase } from './db'
import { newId, Repo } from './repo'

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function makeSession(repo: Repo, matter = 'review the approval gate'): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'running',
    matter,
    project: '',
    repoPath: null,
    agentA: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
    agentB: { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    maxTurns: 6,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
}

function occurrence(
  findingId: string,
  patch: Partial<FindingOccurrence> = {},
): Omit<FindingOccurrence, 'id' | 'createdAt'> &
  Partial<Pick<FindingOccurrence, 'id' | 'createdAt'>> {
  return {
    findingId,
    planId: 'plan-1',
    milestoneId: 'milestone-1',
    round: 0,
    kind: 'blocking',
    source: 'review',
    ...patch,
  }
}

describe('finding ledger persistence', () => {
  it('upserts formatting variants by content identity but resurfaces a rewording', () => {
    const repo = freshRepo()
    const session = makeSession(repo)

    const first = repo.upsertLedgerFinding(
      session.id,
      'Approval routing is not tested.',
      10,
    )
    const formattingVariant = repo.upsertLedgerFinding(
      session.id,
      '  approval   ROUTING is not tested?! ',
      20,
    )
    const reworded = repo.upsertLedgerFinding(
      session.id,
      'Manager approval routing needs an explicit test.',
      30,
    )

    expect(formattingVariant).toEqual(first)
    expect(reworded.id).not.toBe(first.id)
    expect(repo.listLedgerFindings(session.id)).toEqual([first, reworded])
  })

  it('keeps repeated content as append-only occurrences with complete provenance', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const finding = repo.upsertLedgerFinding(session.id, 'The gate is not tested.', 1)

    const audit = repo.recordFindingOccurrence(
      occurrence(finding.id, {
        id: 'audit-occurrence',
        planId: 'plan-1',
        milestoneId: null,
        round: null,
        source: 'audit',
        createdAt: 2,
      }),
    )
    const firstReview = repo.recordFindingOccurrence(
      occurrence(finding.id, {
        id: 'first-review',
        planId: 'plan-1',
        milestoneId: 'milestone-1',
        round: 0,
        createdAt: 3,
      }),
    )
    const otherMilestone = repo.recordFindingOccurrence(
      occurrence(finding.id, {
        id: 'other-milestone',
        planId: 'plan-1',
        milestoneId: 'milestone-2',
        round: 1,
        kind: 'note',
        createdAt: 4,
      }),
    )

    expect(repo.listFindingOccurrences(session.id)).toEqual([
      audit,
      firstReview,
      otherMilestone,
    ])
    expect(() =>
      repo.recordFindingOccurrence(
        occurrence(finding.id, {
          id: audit.id,
          createdAt: 5,
        }),
      ),
    ).toThrow()
  })

  it('records immutable dispositions scoped to one occurrence or the finding', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const finding = repo.upsertLedgerFinding(session.id, 'The gate is not tested.', 1)
    const first = repo.recordFindingOccurrence(
      occurrence(finding.id, { id: 'first', createdAt: 2 }),
    )
    repo.recordFindingOccurrence(
      occurrence(finding.id, {
        id: 'second',
        milestoneId: 'milestone-2',
        createdAt: 3,
      }),
    )

    const scoped = repo.disposeFinding({
      id: 'scoped',
      findingId: finding.id,
      occurrenceId: first.id,
      state: 'resolved',
      note: 'The passing review settled this occurrence.',
      source: 'pipeline',
      createdAt: 4,
    })
    const allPrior = repo.disposeFinding({
      id: 'all-prior',
      findingId: finding.id,
      occurrenceId: null,
      state: 'accepted-risk',
      note: 'Accepted by the user.',
      source: 'human',
      createdAt: 5,
    })

    expect(repo.listFindingDispositions(session.id)).toEqual([scoped, allPrior])
  })

  it('refuses to scope a disposition to another finding occurrence', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const first = repo.upsertLedgerFinding(session.id, 'First finding.', 1)
    const second = repo.upsertLedgerFinding(session.id, 'Second finding.', 2)
    const sighting = repo.recordFindingOccurrence(
      occurrence(first.id, { id: 'first-sighting', createdAt: 3 }),
    )

    expect(() =>
      repo.disposeFinding({
        findingId: second.id,
        occurrenceId: sighting.id,
        state: 'dismissed',
        note: '',
        source: 'human',
      }),
    ).toThrow(/different finding/i)
    expect(repo.listFindingDispositions(session.id)).toHaveLength(0)
  })
})

describe('finding ledger session deletion', () => {
  it('reports and explicitly removes findings, occurrences, and dispositions', () => {
    const repo = freshRepo()
    const session = makeSession(repo)
    const first = repo.upsertLedgerFinding(session.id, 'First finding.', 1)
    repo.upsertLedgerFinding(session.id, 'Second finding.', 2)
    const sighting = repo.recordFindingOccurrence(
      occurrence(first.id, { id: 'first-sighting', createdAt: 3 }),
    )
    repo.disposeFinding({
      findingId: first.id,
      occurrenceId: sighting.id,
      state: 'resolved',
      note: '',
      source: 'human',
      createdAt: 4,
    })
    repo.disposeFinding({
      findingId: first.id,
      occurrenceId: null,
      state: 'dismissed',
      note: '',
      source: 'human',
      createdAt: 5,
    })

    const impact = repo.describeSessionDeletion(session.id)
    expect(impact.findings).toBe(2)
    expect(impact.dispositions).toBe(2)

    repo.deleteSession(session.id)

    expect(repo.listLedgerFindings(session.id)).toHaveLength(0)
    expect(repo.listFindingOccurrences(session.id)).toHaveLength(0)
    expect(repo.listFindingDispositions(session.id)).toHaveLength(0)
  })

  it('leaves another session ledger untouched', () => {
    const repo = freshRepo()
    const doomed = makeSession(repo, 'doomed')
    const keeper = makeSession(repo, 'keeper')
    repo.upsertLedgerFinding(doomed.id, 'Same text.', 1)
    const keptFinding = repo.upsertLedgerFinding(keeper.id, 'Same text.', 2)
    const keptOccurrence = repo.recordFindingOccurrence(
      occurrence(keptFinding.id, { id: 'kept-occurrence', createdAt: 3 }),
    )

    repo.deleteSession(doomed.id)

    expect(repo.listLedgerFindings(keeper.id)).toEqual([keptFinding])
    expect(repo.listFindingOccurrences(keeper.id)).toEqual([keptOccurrence])
  })
})
