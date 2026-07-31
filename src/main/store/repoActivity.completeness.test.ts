import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { emptyUsage, type Milestone, type WorkPlan } from '@shared/domain'
import { canonicalRepoPath } from '@main/util/repoPath'
import { openDatabase, type Db, type Row } from './db'
import { newId, Repo } from './repo'

type Classification = 'direct' | 'child' | 'out-of-scope'

const DECLARED_PARENTS: Readonly<Record<string, string>> = {
  ledger_findings: 'sessions',
  self_updates: 'plans',
  // FK-less on purpose, like self_updates: an authorisation record outlives
  // the plan a session deletion cascades away.
  envelopes: 'plans',
}

const OUT_OF_SCOPE: Readonly<Record<string, string>> = {
  agent_threads: 'Opaque vendor resume handles do not change repository attention or summaries.',
  approvals: 'Authorisation evidence is polymorphic and deliberately survives its subject.',
  grid_layouts: 'Saved terminal layout is application-global UI state.',
  hold_acks: 'Acknowledgements are keyed by global content identity, not by repository.',
  hold_notifications: 'Notification stamps are keyed by global content identity, not by repository.',
  meta: 'Schema bookkeeping is database-global.',
  skills: 'Saved agent instructions are application-global.',
  worktrees: 'The checkout registry mirrors plan-owned filesystem state and is not repository activity.',
}

const WRITE_EXEMPTIONS: Readonly<Record<string, string>> = {
  'noteRepoActivity:repo_activity':
    'This INSERT is the activity record itself and cannot recursively record another activity row.',
  'archiveRepo:repo_archives':
    'The archive watermark is the visibility operation itself; activity here would immediately undo it.',
  'createTurn:turns':
    'Transcript streaming is detail beneath the session and does not change repository attention.',
  'finishTurn:turns':
    'Transcript streaming is detail beneath the session and does not change repository attention.',
  'addInterjection:interjections':
    'Queued conversation input is session transport state, not repository attention.',
  'takeInterjections:interjection_deliveries':
    'Per-seat delivery bookkeeping is session transport state, not repository attention.',
  'saveVerdict:verdicts':
    'The enclosing session lifecycle records the repository-visible completion.',
  'replaceFindings:findings':
    'Legacy finding rows are verdict detail covered by the enclosing session lifecycle.',
  'upsertLedgerFinding:ledger_findings':
    'Ledger ingestion is followed by its session or milestone lifecycle transition.',
  'recordFindingOccurrence:ledger_sightings':
    'Occurrence ingestion is followed by its plan or milestone lifecycle transition.',
  'disposeFinding:ledger_dispositions':
    'A disposition changes the global finding gate, which remains visible even for archived repositories.',
  'fileBacklogItemCore:backlog_items':
    'The appended backlog event is the transaction choke point that records activity for filing and resighting.',
  'transitionBacklogItemCore:backlog_items':
    'The appended backlog event is the transaction choke point that records activity for every state change.',
  'fileSelfUpdateAttempt:self_updates':
    'Self-update attention is intentionally unfiltered and its plan lifecycle records repository activity.',
  'supersedeSelfUpdate:self_updates':
    'Self-update attention is intentionally unfiltered and its plan lifecycle records repository activity.',
  'finalizeSelfUpdate:self_updates':
    'Self-update attention is intentionally unfiltered and its plan lifecycle records repository activity.',
  'decideSelfUpdate:self_updates':
    'Self-update attention is intentionally unfiltered and its plan lifecycle records repository activity.',
  'reconcileSelfUpdates:self_updates':
    'Startup reconciliation repairs durable gate state before repository visibility is evaluated.',
  'createMilestone:milestones':
    'Milestones are created while their plan creation or correction records the repository activity.',
  'setMilestoneRunState:milestones':
    'The opaque checkpoint is internal run state; visible milestone transitions use updateMilestone.',
  'createIteration:loop_iterations':
    'Iteration detail is covered by its loop lifecycle activity.',
  'finishIteration:loop_iterations':
    'Iteration detail is covered by its loop lifecycle activity.',
  'settleEnvelope:envelopes':
    'An envelope ending is recorded by the milestone transitions it drove, and by the hold its outcome derives.',
  'bumpEnvelopeMilestones:envelopes':
    'The mint counter is internal cap bookkeeping; the milestone it authorised records the visible activity.',
  'reconcileEnvelopes:envelopes':
    'Startup reconciliation repairs durable envelope state before repository visibility is evaluated.',
  'settleWorkspace:workspaces':
    'The build outcome is recorded by createWorkspace’s activity; a workspace that never went ready is not repository work.',
  'reconcileWorkspaces:workspaces':
    'Startup reconciliation repairs durable workspace state before repository visibility is evaluated.',
}

function tableClassifications(db: Db): Map<string, Classification> {
  const tables = db
    .all<{ name: string }>(
      `SELECT name FROM sqlite_schema
       WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
       ORDER BY name ASC`,
    )
    .map((row) => row.name)
  const tableSet = new Set(tables)
  const classified = new Map<string, Classification>()

  for (const table of tables) {
    const columns = db.all<{ name: string }>(`PRAGMA table_info("${table}")`)
    if (columns.some((column) => column.name === 'repo_path')) classified.set(table, 'direct')
  }

  let changed = true
  while (changed) {
    changed = false
    for (const table of tables) {
      if (classified.has(table)) continue
      const parents = db
        .all<{ table: string }>(`PRAGMA foreign_key_list("${table}")`)
        .map((foreignKey) => foreignKey.table)
      const declared = DECLARED_PARENTS[table]
      if (declared) {
        expect(tableSet.has(declared), `${table}'s declared parent ${declared}`).toBe(true)
        parents.push(declared)
      }
      if (parents.some((parent) => classified.get(parent) === 'direct' || classified.get(parent) === 'child')) {
        classified.set(table, 'child')
        changed = true
      }
    }
  }

  for (const [table, reason] of Object.entries(OUT_OF_SCOPE)) {
    expect(reason.trim(), `${table} needs a written out-of-scope reason`).not.toBe('')
    if (tableSet.has(table) && !classified.has(table)) classified.set(table, 'out-of-scope')
  }

  const unclassified = tables.filter((table) => !classified.has(table))
  expect(unclassified, 'every schema table must be classified').toEqual([])
  return classified
}

function methodBodies(source: string): Array<{ name: string; body: string }> {
  const starts = [
    ...source.matchAll(
      /^  (?:(?:private|public|protected)\s+)?(?:async\s+)?([A-Za-z_$][\w$]*)\s*(?:<[^\n]+>)?\s*\(/gm,
    ),
  ].map((match) => ({ name: match[1] ?? '', start: match.index }))

  return starts.map((method, index) => ({
    name: method.name,
    body: source.slice(method.start, starts[index + 1]?.start ?? source.length),
  }))
}

class TransactionRecordingDb implements Db {
  readonly writes: Array<{ table: string; transaction: number | null }> = []
  readonly committed = new Set<number>()
  private activeTransaction: number | null = null
  private nextTransaction = 0

  constructor(private readonly inner: Db) {}

  exec(sql: string): void {
    this.inner.exec(sql)
  }

  run(sql: string, ...params: unknown[]): { changes: number } {
    const write = /\b(?:INSERT\s+INTO|UPDATE)\s+([a-z_]+)\s*(?=\(|SET)/i.exec(sql)
    if (write?.[1]) {
      this.writes.push({ table: write[1].toLowerCase(), transaction: this.activeTransaction })
    }
    return this.inner.run(sql, ...params)
  }

  get<T = Row>(sql: string, ...params: unknown[]): T | undefined {
    return this.inner.get<T>(sql, ...params)
  }

  all<T = Row>(sql: string, ...params: unknown[]): T[] {
    return this.inner.all<T>(sql, ...params)
  }

  transaction<T>(fn: () => T): T {
    if (this.activeTransaction !== null) throw new Error('nested transaction in test decorator')
    const transaction = ++this.nextTransaction
    this.inner.exec('BEGIN')
    this.activeTransaction = transaction
    try {
      const result = fn()
      this.inner.exec('COMMIT')
      this.committed.add(transaction)
      return result
    } catch (error) {
      this.inner.exec('ROLLBACK')
      throw error
    } finally {
      this.activeTransaction = null
    }
  }

  close(): void {
    this.inner.close()
  }
}

const claude = { vendor: 'claude' as const, model: '', effort: 'medium' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'medium' as const, persona: '' }

function makePlan(repoPath: string): WorkPlan {
  return {
    id: newId(),
    sessionId: 'session',
    kind: 'implementation',
    title: 'Completeness drill',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
  }
}

function makeMilestone(planId: string): Milestone {
  return {
    id: newId(),
    planId,
    index: 0,
    title: 'Exercise child activity',
    intent: '',
    expectedPaths: [],
    status: 'planned',
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
    runState: null,
  }
}

function expectAtomicActivity(
  db: TransactionRecordingDb,
  table: string,
  action: () => unknown,
): void {
  const start = db.writes.length
  action()
  const writes = db.writes
    .slice(start)
    .filter((write) => write.table === table || write.table === 'repo_activity')
  expect(writes.some((write) => write.table === table), `${table} write`).toBe(true)
  expect(writes.some((write) => write.table === 'repo_activity'), `${table} activity`).toBe(true)
  const transactions = new Set(writes.map((write) => write.transaction))
  expect(transactions.size, `${table} and its activity must share one transaction`).toBe(1)
  const transaction = [...transactions][0]
  expect(transaction, `${table} must be between BEGIN and COMMIT`).not.toBeNull()
  expect(db.committed.has(transaction as number), `${table} transaction must commit`).toBe(true)
}

describe('repository activity completeness', () => {
  it('totally classifies the schema from direct paths, child links, or a written exclusion', () => {
    const db = openDatabase(':memory:')
    const classified = tableClassifications(db)
    const tables = (kind: Classification): string[] =>
      [...classified.entries()]
        .filter(([, classification]) => classification === kind)
        .map(([table]) => table)
        .sort()

    expect(tables('direct')).toEqual([
      'acceptances',
      'backlog_items',
      'foreman_proposals',
      'learnings',
      'loops',
      'plans',
      'repo_activity',
      'repo_archives',
      'repo_containers',
      'sessions',
      'workspaces',
    ])
    expect(tables('child')).toEqual([
      'backlog_events',
      'envelopes',
      'findings',
      'interjection_deliveries',
      'interjections',
      'ledger_dispositions',
      'ledger_findings',
      'ledger_sightings',
      'loop_iterations',
      'milestones',
      'self_updates',
      'turns',
      'verdicts',
    ])
    expect(tables('out-of-scope')).toEqual(Object.keys(OUT_OF_SCOPE).sort())
  })

  it('requires every direct or child INSERT/UPDATE site to record activity or explain why not', () => {
    const db = openDatabase(':memory:')
    const classifications = tableClassifications(db)
    const source = readFileSync(fileURLToPath(new URL('./repo.ts', import.meta.url)), 'utf8')
    const usedExemptions = new Set<string>()
    const failures: string[] = []

    for (const method of methodBodies(source)) {
      const recordsActivity = method.body.includes('this.noteRepoActivity(')
      for (const call of method.body.matchAll(/this\.db\.run\(\s*`([\s\S]*?)`/g)) {
        const sql = call[1] ?? ''
        for (const write of sql.matchAll(
          /\b(?:INSERT\s+INTO|UPDATE)\s+([a-z_]+)\s*(?=\(|SET)/gi,
        )) {
          const table = write[1]?.toLowerCase() ?? ''
          const classification = classifications.get(table)
          if (classification !== 'direct' && classification !== 'child') continue
          const key = `${method.name}:${table}`
          const exemption = WRITE_EXEMPTIONS[key]
          if (recordsActivity) continue
          if (exemption?.trim()) usedExemptions.add(key)
          else failures.push(key)
        }
      }
    }

    expect([...new Set(failures)].sort(), 'untracked repository write sites').toEqual([])
    expect(
      [...usedExemptions].sort(),
      'written exemptions must stay attached to a live write site',
    ).toEqual(Object.keys(WRITE_EXEMPTIONS).sort())
  })

  it('records backlog, learning, and foreman branches inside their write transactions', () => {
    const db = new TransactionRecordingDb(openDatabase(':memory:'))
    const repo = new Repo(db)
    const repoPath = '/tmp/repo-activity-completeness'

    let itemId = ''
    expectAtomicActivity(db, 'backlog_events', () => {
      const result = repo.fileBacklogItem({
        repoPath,
        title: 'One issue',
        source: 'manual',
        mock: true,
      })
      expect(result.resighted).toBe(false)
      itemId = result.item.id
    })
    expectAtomicActivity(db, 'backlog_events', () => {
      const result = repo.fileBacklogItem({
        repoPath,
        title: 'One issue',
        source: 'manual',
        mock: true,
      })
      expect(result).toMatchObject({ resighted: true, item: { id: itemId } })
    })
    repo.archiveRepo(repoPath)
    expect(repo.archivedRepoPaths()).toEqual([canonicalRepoPath(repoPath)])
    expectAtomicActivity(db, 'backlog_events', () => {
      repo.transitionBacklogItem(itemId, 'done', {
        source: 'human',
        note: 'Verified complete.',
      })
    })
    expect(repo.archivedRepoPaths()).toEqual([])

    expectAtomicActivity(db, 'learnings', () => {
      expect(
        repo.fileLearning({
          repoPath,
          text: 'A durable fact.',
          source: 'manual',
          mock: true,
        }).duplicate,
      ).toBe(false)
    })
    const beforeDuplicate = db.writes.length
    expect(
      repo.fileLearning({
        repoPath,
        text: 'A durable fact.',
        source: 'manual',
        mock: true,
      }).duplicate,
    ).toBe(true)
    expect(db.writes).toHaveLength(beforeDuplicate)

    const failed = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })
    expectAtomicActivity(db, 'foreman_proposals', () => {
      repo.finalizeForemanAttempt(failed.id, {
        state: 'failed',
        error: 'No selection.',
        usage: emptyUsage(),
      })
    })

    const proposed = repo.fileForemanAttempt({
      repoPath,
      vendor: 'claude',
      mock: true,
      openSnapshot: [],
    })
    expectAtomicActivity(db, 'foreman_proposals', () => {
      repo.finalizeForemanAttempt(proposed.id, {
        state: 'proposed',
        title: 'A proposal',
        rationale: 'This work belongs together.',
        itemIds: [],
        deferred: [],
        isolation: 'worktree',
        note: '',
        anchorSessionId: 'session',
        usage: emptyUsage(),
      })
    })
  })

  it('records milestone updates inside the same transaction', () => {
    const db = new TransactionRecordingDb(openDatabase(':memory:'))
    const repo = new Repo(db)
    const plan = makePlan('/tmp/milestone-activity-completeness')
    repo.createPlan(plan)
    const milestone = repo.createMilestone(makeMilestone(plan.id))
    repo.archiveRepo(plan.repoPath)
    const beforeUpdate = repo.repoActivitySeq(plan.repoPath)
    expect(repo.archivedRepoPaths()).toEqual([canonicalRepoPath(plan.repoPath)])

    expectAtomicActivity(db, 'milestones', () => {
      expect(repo.updateMilestone(milestone.id, { status: 'executing' }).status).toBe('executing')
    })
    expect(repo.repoActivitySeq(plan.repoPath)).toBeGreaterThan(beforeUpdate)
    expect(repo.archivedRepoPaths()).toEqual([])
  })
})
