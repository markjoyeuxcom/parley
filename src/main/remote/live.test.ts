import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { handshakeRequest } from './protocol'
import { runSsh } from './ssh'
import { installRemote, rollbackRemote } from './installer'
import { createExecutionSnapshot, deleteRunRefs, pushSnapshot } from './snapshot'
import { statusVerdict } from './status'
import { driveRemoteMilestone } from './driver'
import { sshConverse } from './converse'
import { milestonePatch, type MilestoneFact, type MilestoneReporter } from '@main/orchestrator/reporter'
import type { Milestone, WorkPlan } from '@shared/domain'
import type { RemoteCapabilities } from '@shared/remote'

/**
 * The remote arc against a real host.
 *
 * Fifteen milestones of transport, snapshot, bootstrap and replay were green
 * against fakes — a fake `ssh` that is really a small node script, a mirror on
 * the local disk. Fakes prove the wiring and cannot prove the environment, and
 * every interesting failure here was environmental: what is on a
 * non-interactive PATH, what permissions sftp leaves behind, how git parses a
 * URL it was handed.
 *
 * Skipped unless a host is named, because it really uploads a bundle, really
 * writes under the host's home directory and really pushes git refs:
 *
 *   PARLEY_LIVE_REMOTE=mjoyeux@claudedev2@orb \
 *   PARLEY_LIVE_REMOTE_NODE=/home/mjoyeux/.nvm/versions/node/v24.18.0/bin/node \
 *   npx vitest run src/main/remote/live.test.ts
 *
 * `npm run build:remote` first — the bundle it uploads is the built one.
 */
const host = process.env['PARLEY_LIVE_REMOTE'] ?? ''
const nodeCommand = process.env['PARLEY_LIVE_REMOTE_NODE'] || 'node'
const live = host !== ''
const target = { host }
const bundlePath = resolve('out/remote/parley-remote.mjs')

describe.skipIf(!live)('installing on a real host', () => {
  it('uploads, hashes, proves the staged bundle runs, and activates it', async () => {
    const outcome = await installRemote({ ...target, nodeCommand }, { bundlePath })
    expect(outcome.detail).toBeTruthy()
    expect(outcome.ok).toBe(true)
    // The handshake the staged copy answered before activation — proof the
    // bytes that became the installation are bytes that run.
    expect(outcome.nodeVersion).toMatch(/^v\d+\./)
  }, 120_000)

  it('answers a handshake as the installed helper, invoked by name', async () => {
    // The install proved the bundle runs when a known-good node is named. This
    // proves the thing a run actually does: `ssh host parley-remote`, resolved
    // off the host's own PATH, with nothing but the symlink to find it by.
    let capabilities: RemoteCapabilities | null = null
    const result = await runSsh({
      target,
      request: handshakeRequest('live-handshake'),
      onFrame: (frame) => {
        if (frame.body.type === 'ready') capabilities = frame.body.capabilities
      },
    })

    expect(result.end.kind).toBe('closed')
    expect(capabilities).not.toBeNull()
    const caps = capabilities as unknown as RemoteCapabilities
    expect(caps.protocolVersion).toBe(1)
    // What it says it can do here is what the driver refuses runs against, so
    // an empty list is a finding rather than a detail.
    expect(caps.availableVendors.length).toBeGreaterThan(0)
  }, 120_000)

  it('grades itself healthy from what the handshake actually reported', async () => {
    let capabilities: RemoteCapabilities | null = null
    await runSsh({
      target,
      request: handshakeRequest('live-status'),
      onFrame: (frame) => {
        if (frame.body.type === 'ready') capabilities = frame.body.capabilities
      },
    })
    expect(capabilities).not.toBeNull()
    const answered = capabilities as unknown as RemoteCapabilities
    // The same facts manager.remoteStatus grades — the handshake answered, so
    // the bundle exists and node started it.
    const verdict = statusVerdict({
      activeTarget: answered.buildId,
      directoryBuildId: answered.buildId,
      calculatedHash: answered.buildId,
      capabilities: answered,
      nodeCommand,
      nodeUsable: true,
      previousAvailable: false,
    })
    expect(verdict.health).toBe('healthy')
  }, 120_000)
})

describe.skipIf(!live)('the snapshot transport against a real host', () => {
  it('pushes an exact tree over ssh and finds it there', async () => {
    // A throwaway repository with a dirty tree, because the snapshot's whole
    // job is to transport what is on disk without committing it locally.
    const repo = mkdtempSync(join(tmpdir(), 'parley-live-'))
    const git = (...args: string[]): string =>
      execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim()
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 'live@parley.test')
    git('config', 'user.name', 'Parley Live')
    writeFileSync(join(repo, 'kept.txt'), 'committed\n')
    git('add', '-A')
    git('commit', '-qm', 'base')
    // Uncommitted, and it must arrive anyway.
    writeFileSync(join(repo, 'dirty.txt'), 'uncommitted\n')

    const runId = `live-${Date.now().toString(36)}`
    const snapshot = await createExecutionSnapshot(repo, runId)
    expect(snapshot.ok).toBe(true)
    if (!snapshot.ok) return
    // Local HEAD is untouched: the snapshot is a commit-tree, not a commit.
    expect(git('rev-parse', 'HEAD')).not.toBe(snapshot.commit)
    expect(git('status', '--porcelain')).toContain('dirty.txt')

    const mirror = `/home/mjoyeux/.local/share/parley/live-mirror.git`
    execFileSync('ssh', [host, 'git', 'init', '--bare', '-q', mirror])
    try {
      const url = `ssh://${host}${mirror}`
      const pushed = await pushSnapshot(repo, url, runId, snapshot.commit)
      expect(pushed.ok).toBe(true)

      // The tree that arrived is the tree that left, dirty file and all.
      const there = execFileSync(
        'ssh',
        [host, 'git', '--git-dir', mirror, 'ls-tree', '-r', '--name-only', snapshot.commit],
        { encoding: 'utf8' },
      )
      expect(there.split('\n').filter(Boolean).sort()).toEqual(['dirty.txt', 'kept.txt'])

      await deleteRunRefs(repo, runId)
    } finally {
      execFileSync('ssh', [host, 'rm', '-rf', mirror])
    }
  }, 180_000)
})

describe.skipIf(!live)('a real milestone, executed over there', () => {
  it('snapshots, runs a real agent on the host, and brings back a candidate', async () => {
    // The whole arc in one pass, with a task small enough to be unambiguous
    // and real enough that the agent must read the tree, edit a file and leave
    // the verification passing.
    const repo = mkdtempSync(join(tmpdir(), 'parley-live-run-'))
    const git = (...args: string[]): string =>
      execFileSync('git', args, { cwd: repo, encoding: 'utf8' }).trim()
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 'live@parley.test')
    git('config', 'user.name', 'Parley Live')
    writeFileSync(
      join(repo, 'greet.js'),
      ['function greet(name) {', "  return 'Hello, ' + name", '}', 'module.exports = { greet }', ''].join('\n'),
    )
    writeFileSync(
      join(repo, 'test.js'),
      [
        "const assert = require('node:assert')",
        "const { greet } = require('./greet')",
        "assert.strictEqual(greet('world'), 'Hello, world')",
        "assert.strictEqual(greet(''), 'Hello, there')",
        "console.log('ok')",
        '',
      ].join('\n'),
    )
    git('add', '-A')
    git('commit', '-qm', 'base')
    const before = git('rev-parse', 'HEAD')

    const plan = {
      id: 'live-plan',
      repoPath: repo,
      isolation: 'worktree',
      executor: { vendor: 'claude', model: 'sonnet', effort: 'low', persona: '' },
      reviewer: { vendor: 'claude', model: 'sonnet', effort: 'low', persona: '' },
      mock: false,
      usage: { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0 },
    } as unknown as WorkPlan

    const milestone = {
      id: 'live-milestone',
      planId: 'live-plan',
      index: 0,
      title: 'Handle the empty name',
      intent:
        "greet('') must return 'Hello, there' instead of 'Hello, '. test.js already asserts it and currently fails. Change greet.js only.",
      expectedPaths: ['greet.js'],
      status: 'executing',
      auditNote: '',
      testCommand: 'node test.js',
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
    } as unknown as Milestone

    // The verification really does fail before the run, or the test proves
    // nothing about whether the agent did the work.
    expect(() => execFileSync('node', ['test.js'], { cwd: repo })).toThrow()

    const facts: MilestoneFact[] = []
    let current = milestone
    const reporter: MilestoneReporter = {
      record: (fact) => {
        facts.push(fact)
        const patch = milestonePatch(fact)
        if (patch) current = { ...current, ...patch }
        return current
      },
      activity: () => {},
      get milestone() {
        return current
      },
    }

    let charged = 0
    const outcome = await driveRemoteMilestone(
      {
        runId: `live${Date.now().toString(36)}`,
        target: { id: 'live', label: 'live', host, runsRoot: '', createdAt: 1 },
        repoKey: 'parley-live-acceptance',
        plan,
        milestone,
      },
      {
        converse: sshConverse(() => nodeCommand),
        consumeApproval: () => {
          charged += 1
        },
        reporter,
        currentMilestone: () => current,
        changedPathsIn: async (at, from, to) =>
          execFileSync('git', ['diff', '--name-only', from, to], { cwd: at, encoding: 'utf8' })
            .split('\n')
            .filter(Boolean),
        // A live failure is only useful if it arrives with the host's own
        // account of it. Printed rather than collected: when this fails it is
        // usually the narrative, not the assertion, that says why.
        onProgress: (phase, text) => console.log(`[${phase}] ${text}`),
      },
    )

    expect(`${outcome.kind}: ${'detail' in outcome ? outcome.detail : ''}`).toContain('accepted')
    if (outcome.kind !== 'accepted') return
    // Exactly one approval, spent at `ready` and never again.
    expect(charged).toBe(1)

    // Only the file the milestone said it would touch.
    expect(outcome.changedPaths).toEqual(['greet.js'])

    // The candidate is real, it descends from the snapshot, and local HEAD
    // never moved — the whole point of an execution appliance.
    expect(git('rev-parse', 'HEAD')).toBe(before)
    const applied = execFileSync('git', ['show', `${outcome.commit}:greet.js`], {
      cwd: repo,
      encoding: 'utf8',
    })
    expect(applied).toContain('there')

    // And Parley observed the verification rather than believing a claim about it.
    const verification = facts.find((fact) => fact.kind === 'verification')
    expect(verification).toBeTruthy()
    expect((verification as { result: { exitCode: number } }).result.exitCode).toBe(0)
  }, 900_000)
})

describe.skipIf(!live)('undoing it', () => {
  it('rolls back to a helper that still answers, then puts the current one back', async () => {
    // Rollback's promise is not "an older build" — it is "a working host".
    // A rollback that restores something unreachable is the failure this
    // guards, and it is precisely what the first install here left behind.
    const rolled = await rollbackRemote({ ...target, nodeCommand }, {})
    expect(rolled.detail).toBeTruthy()
    if (rolled.ok) {
      const after = await runSsh({ target, request: handshakeRequest('live-rollback'), onFrame: () => {} })
      expect(after.end.kind).toBe('closed')
    }

    // Left as we found it: the build this checkout produced.
    const back = await installRemote({ ...target, nodeCommand }, { bundlePath })
    expect(back.ok).toBe(true)
  }, 240_000)
})
