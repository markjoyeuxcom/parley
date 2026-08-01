import { describe, expect, it } from 'vitest'
import { emptyUsage, type Session, type Turn } from '@shared/domain'
import { openDatabase } from './db'
import { newId, Repo } from './repo'
import { ftsQuery } from './search'

/**
 * One index over everything anybody wrote down.
 *
 * Two properties carry this: it finds things across kinds that nothing joins,
 * and it cannot be made to throw by what somebody types. The second matters
 * more than it sounds — MATCH takes a query language and a search box takes
 * whatever is being held down at the time, and a search that crashes mid-word
 * is worse than no search.
 */

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function seeded(): { repo: Repo; sessionId: string; planId: string } {
  const repo = new Repo(openDatabase(':memory:'))
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should the retry ceiling be configurable?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)

  repo.createTurn({
    id: newId(),
    sessionId: session.id,
    index: 0,
    seat: 0,
    vendor: 'claude',
    model: '',
    stage: 'opening',
    text: 'Retries should back off exponentially and surface exhaustion to the caller.',
    usage: emptyUsage(),
    startedAt: Date.now(),
    endedAt: Date.now(),
    error: null,
  } as unknown as Turn)

  const plan = repo.createPlan({
    id: newId(),
    sessionId: session.id,
    kind: 'implementation',
    title: 'Cap the retries',
    repoPath: '/repos/atlas',
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree' as const,
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: false,
    createdAt: Date.now(),
  })
  repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Surface exhaustion',
    intent: 'Make retry exhaustion observable to callers.',
    expectedPaths: [],
    status: 'audited',
    auditNote: '',
    testCommand: '',
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
  })
  repo.upsertLedgerFinding(session.id, 'The retry ceiling is not surfaced to the caller.')
  repo.fileBacklogItem({
    repoPath: '/repos/atlas',
    title: 'Document the retry policy',
    detail: 'Nobody can tell what the ceiling is without reading the source.',
    source: 'review-finding',
    originSessionId: session.id,
    mock: false,
  })
  return { repo, sessionId: session.id, planId: plan.id }
}

describe('what a query becomes', () => {
  it('never lets the grammar through, whatever was typed', () => {
    // Not escaped — unreachable. Every token is a quoted literal, so there is
    // no input that arrives at FTS5 as an operator.
    expect(ftsQuery('retry ceiling')).toBe('"retry"* AND "ceiling"*')
    expect(ftsQuery('a AND OR NOT b')).toBe('"a"* AND "AND"* AND "OR"* AND "NOT"* AND "b"*')
    expect(ftsQuery('"unclosed')).toBe('"unclosed"*')
    expect(ftsQuery('foo* NEAR/2 bar')).toBe('"foo"* AND "NEAR"* AND "2"* AND "bar"*')
  })

  it('says nothing to search for rather than searching for nothing', () => {
    // A caller has to be able to tell an empty box from a real miss.
    expect(ftsQuery('')).toBeNull()
    expect(ftsQuery('   ')).toBeNull()
    expect(ftsQuery('!!! ***')).toBeNull()
  })
})

describe('one question across things nothing joins', () => {
  it('finds the same subject in a debate, a plan, a finding and a backlog item', () => {
    const { repo } = seeded()
    const hits = repo.search('retry')
    const kinds = new Set(hits.map((hit) => hit.kind))
    // The answer to "where did anyone say anything about retries" lives in
    // four tables and used to require knowing which one to look in.
    expect(kinds).toContain('session')
    expect(kinds).toContain('turn')
    expect(kinds).toContain('plan')
    expect(kinds).toContain('finding')
    expect(kinds).toContain('backlog')
    expect(kinds).toContain('milestone')
  })

  it('stems, so the word someone typed is not the word they must have used', () => {
    // The turn says "Retries", the milestone says "retry". Someone searching
    // for either means both.
    const { repo } = seeded()
    expect(repo.search('retries').some((hit) => hit.kind === 'milestone')).toBe(true)
    expect(repo.search('retry').some((hit) => hit.kind === 'turn')).toBe(true)
  })

  it('matches a prefix, because nobody finishes typing before they look', () => {
    expect(seeded().repo.search('exhaust').length).toBeGreaterThan(0)
  })

  it('marks what matched and says where to go', () => {
    const { repo, sessionId } = seeded()
    const hit = repo.search('exponentially').find((entry) => entry.kind === 'turn')
    expect(hit?.snippet).toContain('«exponentially»')
    // The scope is the door: a turn belongs to its session.
    expect(hit?.scope).toBe(sessionId)
  })

  it('narrows by kind and by scope', () => {
    const { repo, sessionId } = seeded()
    const findings = repo.search('retry', { kinds: ['finding'] })
    expect(findings.every((hit) => hit.kind === 'finding')).toBe(true)
    expect(findings.length).toBe(1)

    const inRepo = repo.search('retry', { scope: '/repos/atlas' })
    expect(inRepo.every((hit) => hit.scope === '/repos/atlas')).toBe(true)
    expect(repo.search('retry', { scope: sessionId }).length).toBeGreaterThan(0)
  })

  it('requires every word, so a second one narrows rather than widens', () => {
    const { repo } = seeded()
    expect(repo.search('retry ceiling configurable').length).toBeGreaterThan(0)
    expect(repo.search('retry unicorn').length).toBe(0)
  })
})

describe('the index maintains itself', () => {
  it('follows an edit without anyone remembering to tell it', () => {
    // Triggers rather than write-through. An index kept current by discipline
    // is silently wrong the first time somebody adds a write site.
    const { repo, planId } = seeded()
    const milestone = repo.listMilestones(planId)[0]!
    expect(repo.search('kestrel')).toHaveLength(0)

    repo.updateMilestone(milestone.id, { reviewNote: 'The kestrel path is untested.' })
    const found = repo.search('kestrel')
    expect(found).toHaveLength(1)
    expect(found[0]?.refId).toBe(milestone.id)

    // And an old value stops matching, rather than the index accumulating
    // every sentence a row has ever held.
    repo.updateMilestone(milestone.id, { reviewNote: 'Resolved.' })
    expect(repo.search('kestrel')).toHaveLength(0)
  })

  it('forgets what was deleted', () => {
    const { repo, sessionId } = seeded()
    expect(repo.search('exponentially').length).toBeGreaterThan(0)
    repo.deleteSession(sessionId)
    // The turns went with the session by cascade, and so did their index rows.
    expect(repo.search('exponentially')).toHaveLength(0)
  })
})
