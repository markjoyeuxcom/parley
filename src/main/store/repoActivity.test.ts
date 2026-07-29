import { mkdtempSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { emptyUsage, type WorkPlan } from '@shared/domain'
import { canonicalRepoPath } from '@main/util/repoPath'
import { openDatabase } from './db'
import { newId, Repo } from './repo'

const claude = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'medium' as const, persona: '' }

function makePlan(sessionId: string, repoPath: string): WorkPlan {
  return {
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'A plan',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'drafting',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  }
}

describe('repository activity', () => {
  it('appends one globally increasing sequence and canonicalises its path', () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const real = mkdtempSync(join(tmpdir(), 'parley-activity-real-'))
    const link = join(tmpdir(), `parley-activity-link-${Date.now()}`)
    symlinkSync(real, link)

    repo.noteRepoActivity(`${real}/`)
    repo.noteRepoActivity(link)
    repo.noteRepoActivity('/tmp/another-repository')

    expect(
      db.all<{ seq: number; repoPath: string }>(
        `SELECT seq, repo_path AS repoPath FROM repo_activity ORDER BY seq`,
      ),
    ).toEqual([
      { seq: 1, repoPath: canonicalRepoPath(real) },
      { seq: 2, repoPath: canonicalRepoPath(real) },
      { seq: 3, repoPath: canonicalRepoPath('/tmp/another-repository') },
    ])
    expect(repo.repoActivitySeq(real)).toBe(2)
    expect(repo.repoActivitySeq('/tmp/unknown-repository')).toBe(0)
    expect(() =>
      db.run(`INSERT INTO repo_activity (seq, repo_path) VALUES (3, '/tmp/collision')`),
    ).toThrow()
  })

  it('records every direct repo-path insert', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const repoPath = mkdtempSync(join(tmpdir(), 'parley-direct-activity-'))
    const session = repo.createSession({
      id: newId(),
      kind: 'debate',
      status: 'complete',
      matter: 'What should happen?',
      project: '',
      repoPath,
      participants: [claude, codex],
      maxTurns: 2,
      mock: true,
      createdAt: Date.now(),
    })
    repo.createPlan(makePlan(session.id, repoPath))
    repo.fileBacklogItem({
      repoPath,
      title: 'A backlog item',
      source: 'manual',
      mock: true,
    })
    repo.fileLearning({
      repoPath,
      text: 'A durable fact.',
      source: 'manual',
      mock: true,
    })
    repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })
    repo.createLoop({
      id: newId(),
      goal: 'Inspect the repository',
      repoPath,
      worker: codex,
      verifier: claude,
      exit: { kind: 'command', command: 'true', criterion: '' },
      caps: { maxIterations: 1, maxSpendUsd: 0, maxWallClockMs: 60_000 },
      capability: 'read',
      approvalId: null,
      status: 'idle',
      usage: emptyUsage(),
      iterationCount: 0,
      mock: true,
      startedAt: Date.now(),
      endedAt: null,
      stopReason: '',
      lastActivityAt: null,
    })

    expect(repo.repoActivitySeq(repoPath)).toBe(6)
  })

  it('does not create activity for a session without a repository', () => {
    const repo = new Repo(openDatabase(':memory:'))
    repo.createSession({
      id: newId(),
      kind: 'debate',
      status: 'complete',
      matter: 'A repository-free discussion',
      project: '',
      repoPath: null,
      participants: [claude, codex],
      maxTurns: 2,
      mock: true,
      createdAt: Date.now(),
    })

    expect(repo.repoActivitySeq('/tmp/no-repository')).toBe(0)
  })

  it('keeps late session writes tolerant after the session row is gone', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const delta = {
      inputTokens: 10,
      cachedInputTokens: 2,
      outputTokens: 3,
      reasoningTokens: 1,
      costUsd: 0,
    }

    expect(() => repo.setSessionStatus('deleted-session', 'cancelled')).not.toThrow()
    expect(repo.addSessionUsage('deleted-session', delta)).toEqual(delta)
  })

  it('keeps archive records and derives visibility from their watermarks', () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const real = mkdtempSync(join(tmpdir(), 'parley-archive-real-'))
    const link = join(tmpdir(), `parley-archive-link-${Date.now()}`)
    symlinkSync(real, link)
    const canonical = canonicalRepoPath(real)

    repo.noteRepoActivity(real)
    repo.archiveRepo(link)
    expect(repo.archivedRepoPaths()).toEqual([canonical])

    repo.restoreRepo(real)
    expect(repo.archivedRepoPaths()).toEqual([])
    expect(
      db.get<{ archivedSeq: number }>(
        `SELECT archived_seq AS archivedSeq FROM repo_archives WHERE repo_path = ?`,
        canonical,
      )?.archivedSeq,
    ).toBe(1)

    repo.archiveRepo(`${real}/`)
    expect(repo.archivedRepoPaths()).toEqual([canonical])
    expect(
      db.get<{ archivedSeq: number }>(
        `SELECT archived_seq AS archivedSeq FROM repo_archives WHERE repo_path = ?`,
        canonical,
      )?.archivedSeq,
    ).toBe(2)
  })

  it('makes a repository visible when a direct record is updated after archiving', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const plan = makePlan('session', '/tmp/revived-plan')
    repo.createPlan(plan)
    repo.archiveRepo(plan.repoPath)
    expect(repo.archivedRepoPaths()).toEqual([canonicalRepoPath(plan.repoPath)])

    repo.setPlanStatus(plan.id, 'ready')

    expect(repo.archivedRepoPaths()).toEqual([])
  })

  it('rolls plan creation back when its activity row cannot be recorded', () => {
    const db = openDatabase(':memory:')
    const repo = new Repo(db)
    const plan = makePlan('session', '/tmp/atomic-plan')
    db.exec(`DROP TABLE repo_activity`)

    expect(() => repo.createPlan(plan)).toThrow()
    expect(repo.getPlan(plan.id)).toBeNull()
  })

  it('binds a plan without nesting its transaction', () => {
    const repo = new Repo(openDatabase(':memory:'))
    const plan = makePlan('session', '/tmp/bound-plan')

    expect(repo.bindPlanCreation(plan, [], null)).toEqual(plan)
    expect(repo.getPlan(plan.id)).toEqual(plan)
    expect(repo.repoActivitySeq(plan.repoPath)).toBe(1)
  })
})
