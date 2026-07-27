import { describe, expect, it } from 'vitest'
import type { Session } from '@shared/domain'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import {
  assertNoUnresolvedBlockingOccurrences,
  FindingGateError,
  unresolvedBlockingOccurrences,
} from './gate'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function session(repo: Repo): Session {
  return repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Gate execution on unresolved findings',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
}

function occurrence(
  repo: Repo,
  sessionId: string,
  kind: 'blocking' | 'note' = 'blocking',
) {
  const finding = repo.upsertLedgerFinding(sessionId, `Finding ${newId()}`)
  return repo.recordFindingOccurrence({
    findingId: finding.id,
    planId: newId(),
    milestoneId: null,
    round: null,
    kind,
    source: 'audit',
  })
}

describe('unresolved finding gate', () => {
  it('refuses synchronously while a blocking occurrence has no disposition', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const active = session(repo)
    const blocker = occurrence(repo, active.id)
    occurrence(repo, active.id, 'note')

    expect(unresolvedBlockingOccurrences(repo, active.id)).toEqual([blocker])
    expect(() => assertNoUnresolvedBlockingOccurrences(repo, active.id)).toThrow(
      FindingGateError,
    )
    expect(() => assertNoUnresolvedBlockingOccurrences(repo, active.id)).toThrow(
      /record a disposition/i,
    )
  })

  it('allows a disposed blocker and does not mix sessions', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const active = session(repo)
    const other = session(repo)
    const blocker = occurrence(repo, active.id)
    occurrence(repo, other.id)

    repo.disposeFinding({
      findingId: blocker.findingId,
      occurrenceId: blocker.id,
      state: 'accepted-risk',
      note: 'The operator accepts this risk.',
      source: 'human',
    })

    expect(() => assertNoUnresolvedBlockingOccurrences(repo, active.id)).not.toThrow()
    expect(() => assertNoUnresolvedBlockingOccurrences(repo, other.id)).toThrow(
      FindingGateError,
    )
  })

  it('reopens repeated content raised after a finding-wide disposition', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const active = session(repo)
    const finding = repo.upsertLedgerFinding(active.id, 'Approval routing is unsafe.')
    repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: newId(),
      milestoneId: null,
      round: null,
      kind: 'blocking',
      source: 'audit',
    })
    repo.disposeFinding({
      findingId: finding.id,
      occurrenceId: null,
      state: 'resolved',
      note: 'The first occurrence was addressed.',
      source: 'human',
    })
    expect(() => assertNoUnresolvedBlockingOccurrences(repo, active.id)).not.toThrow()

    repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: newId(),
      milestoneId: newId(),
      round: 1,
      kind: 'blocking',
      source: 'review',
    })

    expect(() => assertNoUnresolvedBlockingOccurrences(repo, active.id)).toThrow(
      FindingGateError,
    )
  })
})
