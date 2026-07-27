import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import type { FindingOccurrence, Session } from '@shared/domain'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { disposeLedgerFinding, getSessionDetail, listSessionLedger } from './ledger'

function harness(): { repo: Repo; session: Session } {
  const repo = new Repo(openDatabase(':memory:'))
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should this change ship?',
    project: '',
    repoPath: null,
    agentA: { vendor: 'claude', model: '', effort: 'medium', persona: '' },
    agentB: { vendor: 'codex', model: '', effort: 'medium', persona: '' },
    maxTurns: 6,
    createdAt: 1,
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  return { repo, session }
}

function occurrence(
  findingId: string,
  id: string,
  milestoneId: string,
): Omit<FindingOccurrence, 'seq' | 'createdAt'> {
  return {
    id,
    findingId,
    planId: 'plan-1',
    milestoneId,
    round: 0,
    kind: 'blocking',
    source: 'review',
  }
}

describe('ledger IPC operations', () => {
  it('groups occurrences and dispositions under only their own finding', () => {
    const { repo, session } = harness()
    const first = repo.upsertLedgerFinding(session.id, 'First finding.', 1)
    const second = repo.upsertLedgerFinding(session.id, 'Second finding.', 2)
    const firstOccurrence = repo.recordFindingOccurrence(
      occurrence(first.id, 'first-occurrence', 'milestone-1'),
    )
    const secondOccurrence = repo.recordFindingOccurrence(
      occurrence(second.id, 'second-occurrence', 'milestone-2'),
    )
    const secondDisposition = repo.disposeFinding({
      findingId: second.id,
      occurrenceId: secondOccurrence.id,
      state: 'resolved',
      note: 'The second issue was fixed.',
      source: 'pipeline',
    })

    const entries = listSessionLedger(repo, session.id)

    expect(entries).toHaveLength(2)
    expect(entries.find((entry) => entry.id === first.id)).toMatchObject({
      occurrences: [firstOccurrence],
      dispositions: [],
    })
    expect(entries.find((entry) => entry.id === second.id)).toMatchObject({
      occurrences: [secondOccurrence],
      dispositions: [secondDisposition],
    })
  })

  it('includes the grouped ledger in the session detail read by session.get', () => {
    const { repo, session } = harness()
    const finding = repo.upsertLedgerFinding(session.id, 'Approval routing is untested.', 1)
    const sighting = repo.recordFindingOccurrence(
      occurrence(finding.id, 'occurrence-1', 'milestone-1'),
    )

    const detail = getSessionDetail(repo, session.id)

    expect(detail.ledger).toEqual([
      {
        ...finding,
        occurrences: [sighting],
        dispositions: [],
      },
    ])
  })

  it('records a human disposition and emits the updated session ledger entry', () => {
    const { repo, session } = harness()
    const finding = repo.upsertLedgerFinding(session.id, 'Approval routing is untested.', 1)
    const sighting = repo.recordFindingOccurrence(
      occurrence(finding.id, 'occurrence-1', 'milestone-1'),
    )
    const events: AppEvent[] = []

    const entry = disposeLedgerFinding(
      repo,
      {
        sessionId: session.id,
        findingId: finding.id,
        occurrenceId: sighting.id,
        state: 'accepted-risk',
        note: 'The user accepts this bounded risk.',
      },
      (event) => events.push(event),
    )

    expect(entry.dispositions).toHaveLength(1)
    expect(entry.dispositions[0]).toMatchObject({
      findingId: finding.id,
      occurrenceId: sighting.id,
      state: 'accepted-risk',
      note: 'The user accepts this bounded risk.',
      source: 'human',
    })
    expect(events).toEqual([{ type: 'session.ledger', entry }])
  })
})
