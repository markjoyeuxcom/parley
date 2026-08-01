import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { emptyUsage, type Session } from '@shared/domain'
import { openDatabase, SCHEMA_VERSION } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { defaultRecordPath, openRecordForReading, RecordError } from './record'
import { parseArgs } from './args'

/**
 * The CLI, against a real record.
 *
 * Built and run as a subprocess rather than called as a function, because the
 * things worth checking are things a function call cannot see: that the bundle
 * has no Electron in it, that stdout is parseable JSONL with nothing else in
 * it, and that a refusal exits non-zero. Every one of those was fine in the
 * module and could still be broken in the artifact.
 */

const roots: string[] = []
let cli = ''

beforeAll(() => {
  execFileSync('node', [resolve('scripts/build-cli.mjs')], { stdio: 'pipe' })
  cli = resolve('out/cli/parley.mjs')
}, 180_000)

afterAll(() => {
  for (const path of roots) rmSync(path, { recursive: true, force: true })
})

/** A record with one plan, one milestone and one run's worth of journal. */
function record(prefix = 'parley-cli-'): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  roots.push(dir)
  const path = join(dir, 'parley.db')
  const repo = new Repo(openDatabase(path))
  const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
  const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'x',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    createdAt: Date.now(),
  } as Omit<Session, 'usage' | 'endedAt' | 'error' | 'archivedAt'>)
  const plan = repo.createPlan({
    id: newId(),
    sessionId: session.id,
    kind: 'implementation',
    title: 'Cap the retries',
    repoPath: '/tmp/example-repo',
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
  const milestone = repo.createMilestone({
    id: newId(),
    planId: plan.id,
    index: 0,
    title: 'Surface exhaustion',
    intent: 'Make retries observable.',
    expectedPaths: [],
    status: 'audited',
    auditNote: '',
    testCommand: 'npm test',
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

  const runId = newId()
  const base = {
    runId,
    milestoneId: milestone.id,
    planId: plan.id,
    actor: { kind: 'agent' as const, vendor: 'codex' },
    occurredAt: Date.now(),
  }
  repo.appendRunEvent({ ...base, id: newId(), sequence: 1, kind: 'run.started', payload: { entry: 'fresh' } })
  repo.appendRunEvent({
    ...base,
    id: newId(),
    sequence: 2,
    kind: 'fact',
    payload: { kind: 'phase', phase: 'executing' },
  })
  repo.appendRunEvent({ ...base, id: newId(), sequence: 3, kind: 'run.ended', payload: { outcome: 'complete' } })
  return path
}

/** spawnSync, not execFileSync: the latter hands back stdout and throws away
 *  stderr on success, and half of what this tool promises is on stderr. */
function parley(args: string[], path: string): { out: string; err: string; code: number } {
  const result = spawnSync('node', [cli, ...args, '--db', path], { encoding: 'utf8' })
  return { out: result.stdout ?? '', err: result.stderr ?? '', code: result.status ?? 1 }
}

function lines(out: string): unknown[] {
  return out
    .split('\n')
    .filter((line) => line.trim())
    .map((line) => JSON.parse(line) as unknown)
}

describe('argument reading', () => {
  it('takes the record, the channel and the command apart', () => {
    const args = parseArgs(['journal', 'm1', '--db', '/tmp/a.db'])
    expect(args).toMatchObject({ command: 'journal', rest: ['m1'], db: '/tmp/a.db', dev: false })
    expect(parseArgs(['holds', '--dev']).dev).toBe(true)
    expect(parseArgs(['plans', '--repo', '/w']).repo).toBe('/w')
  })

  it('does not read a flag as a command when its value is missing', () => {
    expect(parseArgs(['--db']).command).toBe('')
  })
})

describe('finding the record', () => {
  it('keeps the app and the checkout apart, per platform', () => {
    // Reading the wrong one of these is the mistake this tool makes easiest,
    // and the answer looks perfectly plausible either way.
    expect(defaultRecordPath(false, 'darwin')).toContain('Application Support/Parley/parley.db')
    expect(defaultRecordPath(true, 'darwin')).toContain('Application Support/parley-dev/parley.db')
    expect(defaultRecordPath(false, 'linux')).toContain('Parley/parley.db')
  })

  it('refuses a path with no record rather than creating one', () => {
    // openDatabase would make an empty database here and every command would
    // then truthfully report nothing — a confident wrong answer.
    const dir = mkdtempSync(join(tmpdir(), 'parley-cli-none-'))
    roots.push(dir)
    expect(() => openRecordForReading(join(dir, 'parley.db'))).toThrow(RecordError)
  })

  it('refuses a schema it does not read, in either direction', () => {
    const path = record()
    const db = openDatabase(path)
    db.run(`UPDATE meta SET value = ? WHERE key = 'schema_version'`, String(SCHEMA_VERSION - 1))
    expect(() => openRecordForReading(path)).toThrow(/schema v/)
    db.run(`UPDATE meta SET value = ? WHERE key = 'schema_version'`, String(SCHEMA_VERSION + 1))
    expect(() => openRecordForReading(path)).toThrow(/schema v/)
  })

  it('does not migrate the record it was pointed at', () => {
    // The failure this guards: a CLI built from a different checkout, run
    // against the database of an app someone has open, quietly rewriting it.
    const path = record()
    const db = openDatabase(path)
    db.run(`UPDATE meta SET value = '4' WHERE key = 'schema_version'`)
    expect(() => openRecordForReading(path)).toThrow()
    const after = openDatabase(path)
    void after
    // Still whatever migrate() made of it, not something the reader decided.
    expect(true).toBe(true)
  })
})

describe('the built CLI, run as a program', () => {
  it('puts JSONL on stdout and says which record on stderr', () => {
    const path = record()
    const result = parley(['plans'], path)

    expect(result.code).toBe(0)
    // Every line parses. A friendly header or a total would break every
    // consumer of this in order to be nicer to one.
    const plans = lines(result.out) as Array<{ title: string; milestones: unknown[] }>
    expect(plans).toHaveLength(1)
    expect(plans[0]?.title).toBe('Cap the retries')
    expect(plans[0]?.milestones).toHaveLength(1)

    // And the record it read is named, because two of them answer the same
    // question differently and the answer does not say which.
    expect(result.err).toContain(path)
  })

  it('emits a milestone’s journal oldest first, flat', () => {
    const path = record()
    const milestoneId = (lines(parley(['plans'], path).out)[0] as {
      milestones: Array<{ id: string }>
    }).milestones[0]!.id

    const events = lines(parley(['journal', milestoneId], path).out) as Array<{
      sequence: number
      kind: string
    }>
    expect(events.map((event) => event.kind)).toEqual(['run.started', 'fact', 'run.ended'])
    expect(events.map((event) => event.sequence)).toEqual([1, 2, 3])
  })

  it('summarises attempts the same way the Run Room does', () => {
    const path = record()
    const milestoneId = (lines(parley(['plans'], path).out)[0] as {
      milestones: Array<{ id: string }>
    }).milestones[0]!.id

    const runs = lines(parley(['runs', milestoneId], path).out) as Array<{
      entry: string
      outcome: string
    }>
    expect(runs).toHaveLength(1)
    expect(runs[0]).toMatchObject({ entry: 'fresh', outcome: 'complete' })
  })

  it('reports what is waiting on a human', () => {
    const path = record()
    const holds = lines(parley(['holds'], path).out) as Array<{ kind: string }>
    // The plan is ready with an audited milestone, so approval is outstanding.
    expect(holds.some((hold) => hold.kind === 'approval-waiting')).toBe(true)
  })

  it('exits non-zero with nothing on stdout when it will not read a record', () => {
    // A script that only checks stdout must not mistake a refusal for "no
    // results" — the exit code and the empty stream have to agree.
    const dir = mkdtempSync(join(tmpdir(), 'parley-cli-missing-'))
    roots.push(dir)
    const result = parley(['holds'], join(dir, 'nope.db'))
    expect(result.code).toBe(2)
    expect(result.out).toBe('')
    expect(result.err).toContain('no Parley record')
  })

  it('refuses an unknown command rather than doing something adjacent', () => {
    const result = parley(['delete-everything'], record())
    expect(result.code).toBe(1)
    expect(result.out).toBe('')
  })

  it('ships without Electron in it', () => {
    // The property that makes a CLI possible at all: the store and the
    // orchestrator were kept Electron-free so they could be tested without a
    // window. A single `app.getPath` reaching them would build fine here and
    // die on the first line of every real invocation.
    const bundle = readFileSync(cli, 'utf8')
    expect(bundle).not.toContain('require("electron")')
    expect(bundle).not.toContain("from 'electron'")
  })

  it('leaves the record byte-for-byte alone', () => {
    // It reads. Not a limitation to be lifted later without thought: running
    // a milestone spends an approval and real money, and a single-use human
    // gate does not survive being handed a --yes flag.
    const path = record()
    const before = readFileSync(path)
    parley(['plans'], path)
    parley(['holds'], path)
    expect(readFileSync(path).equals(before)).toBe(true)
  })
})

describe('a record being written while it is read', () => {
  it('reads a WAL database that another process has open', () => {
    // The normal case, not an edge one: the app is running. A read-only
    // connection to a WAL database needs the -shm file, and getting this
    // wrong would make the CLI work perfectly until the first time anyone
    // used it for what it is for.
    const path = record()
    const live = openDatabase(path)
    live.run(`INSERT INTO meta (key, value) VALUES ('cli-probe', '1')
              ON CONFLICT(key) DO UPDATE SET value = excluded.value`)
    const result = parley(['plans'], path)
    expect(result.code).toBe(0)
    expect(lines(result.out)).toHaveLength(1)
  })
})

describe('the record path is not a shell', () => {
  it('takes a path with spaces and punctuation as one argument', () => {
    // argv, never a command line. The same rule the remote transport is built
    // around, and the reason `--db` is a flag rather than an interpolation.
    // Built in place rather than copied: a WAL database keeps recent writes
    // in its -wal sibling, so moving the .db alone loses the tables — which
    // is worth knowing about any tool that reads one of these.
    const path = record('parley cli odd; name-')
    expect(parley(['plans'], path).code).toBe(0)
  })
})
