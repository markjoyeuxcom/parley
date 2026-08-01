import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { occurrenceState } from '@shared/ledger'
import { REMOTE_PROTOCOL_VERSION, REQUIRED_CAPABILITIES } from '@shared/remote'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Manager } from './manager'

/**
 * A milestone run on another machine, driven through the Manager.
 *
 * This is the layer that had no test at all. The driver was covered against a
 * scripted wire, the pieces below it were covered, and the wiring between the
 * Manager and the driver — which approval is spent, which reporter is built,
 * what the ledger is told — was only ever read. A no-op sat visibly in that
 * wiring for an entire arc without a single test running through it.
 *
 * The fake host here is a real program doing real git work in a real bare
 * repository, because the failures worth catching are the ones where the two
 * sides disagree about what happened. A stub that returned a manifest would
 * agree with itself.
 */

const roots: string[] = []
afterAll(() => {
  for (const path of roots) {
    try {
      execFileSync('rm', ['-rf', path])
    } catch {
      // Best effort: a leftover temp directory is not worth failing a suite.
    }
  }
})

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function git(at: string, ...args: string[]): string {
  return execFileSync('git', args, {
    cwd: at,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'T',
      GIT_AUTHOR_EMAIL: 't@e.invalid',
      GIT_COMMITTER_NAME: 'T',
      GIT_COMMITTER_EMAIL: 't@e.invalid',
    },
  }).trim()
}

function workRepo(): string {
  const path = mkdtempSync(join(tmpdir(), 'parley-remote-work-'))
  roots.push(path)
  git(path, 'init', '-q', '-b', 'main')
  writeFileSync(join(path, 'a.txt'), 'one\n')
  git(path, 'add', '-A')
  git(path, 'commit', '-qm', 'seed')
  return path
}

function bareMirror(): string {
  const path = mkdtempSync(join(tmpdir(), 'parley-remote-mirror-'))
  roots.push(path)
  git(path, 'init', '-q', '--bare')
  return path
}

/**
 * A host, as a program.
 *
 * It reads the one request line the transport writes, and answers in frames.
 * On `run` it does what a real helper does: builds a commit on top of the
 * submitted snapshot in its own clone and publishes it at the candidate ref.
 * The local side then fetches that ref and checks its ancestry independently,
 * which is the whole point of the candidate protocol and cannot be exercised
 * by a fake that only claims to have done the work.
 */
function fakeHost(script: {
  mirror: string
  /** Facts to report before the result, as `{kind: ...}` bodies. */
  facts?: unknown[]
  /** Skip publishing, to test a result that promises what it did not do. */
  publish?: boolean
  /** Report these as changed, whatever actually was. */
  claimChanged?: string[]
  outcome?: 'complete' | 'failed'
}): string {
  const path = join(mkdtempSync(join(tmpdir(), 'parley-remote-ssh-')), 'ssh.mjs')
  roots.push(path)
  writeFileSync(
    path,
    `#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const MIRROR = ${JSON.stringify(script.mirror)}
const FACTS = ${JSON.stringify(script.facts ?? [])}
const PUBLISH = ${script.publish === false ? 'false' : 'true'}
const CLAIM = ${JSON.stringify(script.claimChanged ?? ['a.txt'])}
const OUTCOME = ${JSON.stringify(script.outcome ?? 'complete')}

const caps = {
  protocolVersion: ${REMOTE_PROTOCOL_VERSION},
  buildId: 'b'.repeat(64),
  nodeVersion: 'v24.4.1',
  nodeExecutable: '/usr/bin/node',
  capabilities: ${JSON.stringify([...REQUIRED_CAPABILITIES])},
  supportedVendors: ['claude', 'codex'],
  availableVendors: ['claude', 'codex'],
  vendorDetails: {},
  user: 'build', home: '/home/build', path: '/usr/bin', git: '2.45.0',
  runsRoot: '/home/build/.local/share/parley/runs',
}

let input = ''
let handled = false
process.stdin.on('data', (chunk) => {
  input += chunk
  const at = input.indexOf(String.fromCharCode(10))
  if (at < 0 || handled) return
  handled = true
  answer(JSON.parse(input.slice(0, at)))
})

function answer(request) {
  let sequence = 0
  const say = (body) => {
    sequence += 1
    process.stdout.write(
      JSON.stringify({ protocolVersion: ${REMOTE_PROTOCOL_VERSION}, runId: request.runId, sequence, body }) +
        String.fromCharCode(10),
    )
  }

  say({ type: 'ready', capabilities: caps })

  if (request.operation === 'prepare') {
    say({ type: 'prepared', mirror: MIRROR })
    process.exit(0)
  }

  for (const fact of FACTS) say({ type: 'fact', fact })

  const base = request.repository.expectedCommit
  let candidate = null
  if (PUBLISH) {
    const work = mkdtempSync(join(tmpdir(), 'parley-remote-host-'))
    const g = (...args) => execFileSync('git', args, {
      cwd: work, encoding: 'utf8',
      env: { ...process.env, GIT_AUTHOR_NAME: 'R', GIT_AUTHOR_EMAIL: 'r@e.invalid',
             GIT_COMMITTER_NAME: 'R', GIT_COMMITTER_EMAIL: 'r@e.invalid' },
    }).trim()
    execFileSync('git', ['clone', '-q', MIRROR, work])
    g('checkout', '-q', base)
    writeFileSync(join(work, 'a.txt'), 'two\\n')
    g('add', '-A')
    g('commit', '-qm', 'the remote did the work')
    candidate = g('rev-parse', 'HEAD')
    g('push', '-q', MIRROR, 'HEAD:refs/parley/runs/' + request.runId + '/candidate')
  }

  say({
    type: 'result',
    outcome: OUTCOME,
    manifest: { resultCommit: candidate, baseCommit: base, changedPaths: CLAIM, artifactsPath: null },
  })
  process.exit(0)
}
`,
    'utf8',
  )
  chmodSync(path, 0o755)
  return path
}

function harness(sshBinary: string) {
  const repo = new Repo(openDatabase(':memory:'))
  const events: AppEvent[] = []
  const manager = new Manager({
    repo,
    registry: new AgentRegistry(true),
    emit: (event) => events.push(event),
    sshBinary,
    // git addresses the "host" as a path on this disk. Everything else about
    // the sequence — push, fetch, ancestry — is the real thing.
    remoteMirrorUrl: (_host, at) => at,
  })
  return { repo, manager, events }
}

function seed(repo: Repo, repoPath: string): { plan: WorkPlan; milestone: Milestone } {
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
    title: 'Remote plan',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    // Remote runs are worktree-only and never mock; both are refused earlier.
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
    title: 'Change a.txt',
    intent: 'Make it say two.',
    expectedPaths: ['a.txt'],
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
  return { plan, milestone }
}

function target(repo: Repo) {
  return repo.createRemoteTarget({
    id: newId(),
    label: 'build box',
    host: 'build-01',
    nodeCommand: 'node',
    runsRoot: '/home/build/.local/share/parley/runs',
    createdAt: Date.now(),
  })
}

describe('a milestone run on another machine, through the Manager', () => {
  it('accepts a candidate, spends the approval once, and settles the record here', async () => {
    const mirror = bareMirror()
    const { repo, manager } = harness(fakeHost({ mirror, facts: [
      { kind: 'phase', phase: 'executing' },
      {
        kind: 'finding',
        text: 'the retry ceiling is not surfaced',
        evidence: [{ path: 'src/retry.ts', line: 42, symbol: 'retry', excerpt: '' }],
        round: 1,
        blocking: true,
        source: 'review',
      },
      { kind: 'judgement', passed: true },
      { kind: 'finished', passed: true, note: 'done', judgement: true, completedAt: Date.now() },
    ] }))
    const repoPath = workRepo()
    const { plan, milestone } = seed(repo, repoPath)
    const host = target(repo)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')

    const outcome = await manager.runMilestoneRemotely(milestone.id, approval.id, host.id)

    expect(outcome.kind).toBe('accepted')
    if (outcome.kind !== 'accepted') return
    expect(outcome.changedPaths).toEqual(['a.txt'])

    // The approval was single-use and is now spent, so a retry needs a fresh
    // one — the same rule a local run follows.
    expect(() => repo.consumeApproval(approval.id, 'milestone.execute', milestone.id)).toThrow()

    // The milestone moved here, from facts observed there.
    expect(repo.getMilestone(milestone.id)?.status).toBe('complete')

    // The finding the remote reviewer raised is in THIS ledger, with the
    // provenance a local one would have had. It used to be dropped.
    const occurrences = repo.listFindingOccurrences(plan.sessionId)
    expect(occurrences).toHaveLength(1)
    expect(occurrences[0]).toMatchObject({
      planId: plan.id,
      milestoneId: milestone.id,
      round: 1,
      kind: 'blocking',
      source: 'review',
    })
    // And where it is, carried across the wire with it. A finding that
    // reaches this side as a bare sentence cannot be opened.
    expect(occurrences[0]?.evidence).toEqual([
      { path: 'src/retry.ts', line: 42, symbol: 'retry', excerpt: '' },
    ])
    // And settled, because the milestone passed. Recording without settling
    // would leave this gating every future approval on the plan.
    const dispositions = repo.listFindingDispositions(plan.sessionId)
    expect(occurrenceState(occurrences[0]!, dispositions)).not.toBe('open')

    // The plan advanced on knowledge only this side has — that nothing else
    // remains — which the machine that ran the work could not know.
    expect(repo.getPlan(plan.id)?.status).toBe('complete')

    // The story is here too, attributed to the host it happened on.
    const runs = repo.listMilestoneRuns(milestone.id)
    expect(runs).toHaveLength(1)
    // "codex on build-01" is a different fact from "codex", and the journal
    // has to carry which — every actor from this run names the host.
    const actors = repo.listRunEvents(runs[0]!.runId).map((event) => event.actor)
    const events = repo.listRunEvents(runs[0]!.runId)
    const kindOf = (event: (typeof events)[number]): string =>
      String((event.payload as { kind?: string }).kind ?? event.kind)

    // Everything the far end did names the host: "codex on build-01" is a
    // different fact from "codex", and a journal that lost the difference
    // could not answer where a finding came from.
    const remote = events.filter((event) => kindOf(event) !== 'planOutcome')
    expect(remote.length).toBeGreaterThan(0)
    expect(remote.every((event) => event.actor.targetId === host.id)).toBe(true)

    // The reviewer's objection is attributed to the reviewer, not to whoever
    // was driving the loop.
    const raised = events.find((event) => kindOf(event) === 'finding')
    expect(raised?.actor).toMatchObject({ kind: 'reviewer', vendor: 'claude' })

    // And the one thing this side concluded carries no host, because no host
    // concluded it — the plan's other milestones are knowledge only here.
    const concluded = events.find((event) => kindOf(event) === 'planOutcome')
    expect(concluded?.actor).toEqual({ kind: 'system' })
  }, 60_000)

  it('refuses a result whose evidence disagrees with the tree it published', async () => {
    // The candidate protocol's reason to exist. The host says it changed one
    // thing; git says it changed another. Authority is local, so the local
    // reconciliation wins and nothing is imported.
    const mirror = bareMirror()
    const { repo, manager } = harness(
      fakeHost({ mirror, claimChanged: ['somewhere-else.txt'], facts: [{ kind: 'phase', phase: 'executing' }] }),
    )
    const { plan, milestone } = seed(repo, workRepo())
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')

    const outcome = await manager.runMilestoneRemotely(milestone.id, approval.id, target(repo).id)

    expect(outcome.kind).toBe('rejected')
    expect(outcome.kind === 'rejected' && outcome.detail).toContain('disagree about what changed')
    // Nothing was imported, and the plan was not advanced on a report that
    // could not be trusted.
    expect(repo.getPlan(plan.id)?.status).not.toBe('complete')
  }, 60_000)

  it('spends nothing when the host never answers', async () => {
    // A transport failure must leave the approval good: making someone grant a
    // fresh one to retry something that never ran is the whole reason the
    // charge waits for `ready`.
    const mirror = bareMirror()
    const missing = join(mkdtempSync(join(tmpdir(), 'parley-remote-none-')), 'no-such-ssh')
    roots.push(missing)
    const { repo, manager } = harness(missing)
    const { milestone } = seed(repo, workRepo())
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'allow')

    const outcome = await manager.runMilestoneRemotely(milestone.id, approval.id, target(repo).id)

    expect(outcome.kind).toBe('unstarted')
    // Still good.
    expect(() =>
      repo.consumeApproval(approval.id, 'milestone.execute', milestone.id),
    ).not.toThrow()
  }, 60_000)
})
