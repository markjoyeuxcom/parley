import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { Milestone } from '@shared/domain'
import { REMOTE_PROTOCOL_VERSION, type RemoteEvidenceManifest, type RemoteFrame } from '@shared/remote'
import type { MilestoneFact, MilestoneReporter } from '@main/orchestrator/reporter'
import { milestoneFingerprint, RemoteReplay, verifyCandidate } from './replay'

/**
 * What this machine does with what a remote said.
 *
 * The remote is trusted to have done the work. It is not trusted to be the
 * only thing that happened here while it was working, and it is not trusted
 * about what it built — both of those are checked locally, against state and
 * objects this side holds.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

const milestone = {
  id: 'm1',
  planId: 'p1',
  status: 'executing',
  reviewPassed: null,
  completedAt: null,
  testResult: null,
  reviewNote: '',
} as unknown as Milestone

function reporterSpy(): { reporter: MilestoneReporter; recorded: MilestoneFact[] } {
  const recorded: MilestoneFact[] = []
  const reporter: MilestoneReporter = {
    record: (fact) => {
      recorded.push(fact)
      return milestone
    },
    activity: () => {},
    milestone,
  }
  return { reporter, recorded }
}

function frame(sequence: number, fact: unknown): RemoteFrame {
  return {
    protocolVersion: REMOTE_PROTOCOL_VERSION,
    runId: 'run-1',
    sequence,
    body: { type: 'fact', fact },
  }
}

describe('the milestone must still be the one that was submitted', () => {
  it('applies facts when nothing else moved the row', () => {
    const { reporter, recorded } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => milestone)
    expect(replay.apply(frame(1, { kind: 'phase', phase: 'testing' }))).toBeNull()
    expect(recorded).toEqual([{ kind: 'phase', phase: 'testing' }])
  })

  it('refuses everything when the row changed while the run was in flight', () => {
    // A human stopped it, an adopt landed, the plan was re-drafted. The
    // remote's report is truthful about a state that no longer exists, and
    // writing it would put an honest report onto somebody else's row.
    const { reporter, recorded } = reporterSpy()
    const moved = { ...milestone, status: 'failed' } as Milestone
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => moved)
    const refusal = replay.apply(frame(1, { kind: 'phase', phase: 'testing' }))
    expect(refusal?.kind).toBe('moved')
    expect(refusal?.detail).toContain('no longer exists')
    expect(recorded).toEqual([])
  })

  it('refuses when the milestone is gone entirely', () => {
    const { reporter } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => null)
    expect(replay.apply(frame(1, { kind: 'phase', phase: 'testing' }))?.kind).toBe('moved')
  })

  it('checks the fingerprint once, not on every fact', () => {
    // After the first fact this replay is itself what moves the row, so
    // re-checking would compare against our own writes and refuse everything
    // from the second frame onwards.
    const { reporter, recorded } = reporterSpy()
    let current = milestone
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => current)
    replay.apply(frame(1, { kind: 'phase', phase: 'testing' }))
    current = { ...milestone, status: 'reviewing' } as Milestone
    expect(replay.apply(frame(2, { kind: 'judgement', passed: true }))).toBeNull()
    expect(recorded).toHaveLength(2)
  })
})

describe('frames arrive in order, once each', () => {
  it('ignores a repeat without recording it twice', () => {
    // What a resume resends. Recording it twice would double a milestone's
    // spend or append a narrative to itself.
    const { reporter, recorded } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => milestone)
    const first = frame(1, { kind: 'phase', phase: 'testing' })
    replay.apply(first)
    replay.apply(first)
    expect(recorded).toHaveLength(1)
    expect(replay.result.duplicates).toBe(1)
  })

  it('refuses a gap rather than recording a hole', () => {
    const { reporter, recorded } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => milestone)
    replay.apply(frame(1, { kind: 'phase', phase: 'testing' }))
    const refusal = replay.apply(frame(3, { kind: 'judgement', passed: true }))
    expect(refusal?.kind).toBe('gap')
    expect(recorded).toHaveLength(1)
  })

  it('refuses a fact it cannot read rather than guessing', () => {
    const { reporter, recorded } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => milestone)
    expect(replay.apply(frame(1, { kind: 'invented' }))?.kind).toBe('unreadable')
    expect(recorded).toEqual([])
  })

  it('ignores frames that are not facts', () => {
    const { reporter, recorded } = reporterSpy()
    const replay = new RemoteReplay(reporter, milestoneFingerprint(milestone), () => milestone)
    expect(
      replay.apply({
        protocolVersion: REMOTE_PROTOCOL_VERSION,
        runId: 'run-1',
        sequence: 1,
        body: { type: 'progress', phase: 'executing', text: 'working' },
      }),
    ).toBeNull()
    expect(recorded).toEqual([])
  })
})

describe('accepting a candidate', () => {
  function repo(): { path: string; base: string; child: string; foreign: string } {
    const path = mkdtempSync(join(tmpdir(), 'parley-candidate-'))
    roots.push(path)
    const git = (...args: string[]): string =>
      execFileSync('git', args, {
        cwd: path,
        encoding: 'utf8',
        env: {
          ...process.env,
          GIT_AUTHOR_NAME: 'T',
          GIT_AUTHOR_EMAIL: 't@e.com',
          GIT_COMMITTER_NAME: 'T',
          GIT_COMMITTER_EMAIL: 't@e.com',
        },
      }).trim()
    git('init', '-q', '-b', 'main')
    writeFileSync(join(path, 'a.txt'), 'one\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'base')
    const base = git('rev-parse', 'HEAD')
    writeFileSync(join(path, 'a.txt'), 'two\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'child')
    const child = git('rev-parse', 'HEAD')
    git('checkout', '-q', '--orphan', 'other')
    writeFileSync(join(path, 'b.txt'), 'elsewhere\n')
    git('add', '-A')
    git('commit', '-q', '-m', 'unrelated')
    const foreign = git('rev-parse', 'HEAD')
    git('checkout', '-q', 'main')
    return { path, base, child, foreign }
  }

  const changedPathsIn = async (path: string, from: string, to: string): Promise<string[]> =>
    execFileSync('git', ['diff', '--name-only', from, to], { cwd: path, encoding: 'utf8' })
      .split('\n')
      .filter(Boolean)

  function manifest(over: Partial<RemoteEvidenceManifest> = {}): RemoteEvidenceManifest {
    return { resultCommit: null, baseCommit: '', changedPaths: ['a.txt'], artifactsPath: null, ...over }
  }

  it('accepts a descendant whose evidence matches', async () => {
    const { path, base, child } = repo()
    const verdict = await verifyCandidate(
      path,
      base,
      child,
      manifest({ baseCommit: base }),
      changedPathsIn,
    )
    expect(verdict.ok).toBe(true)
    expect(verdict.ok && verdict.changedPaths).toEqual(['a.txt'])
  })

  it('refuses a commit that does not descend from what was submitted', async () => {
    // The load-bearing check. Applying this would silently replace work rather
    // than add to it.
    const { path, base, foreign } = repo()
    const verdict = await verifyCandidate(
      path,
      base,
      foreign,
      manifest({ baseCommit: base, changedPaths: [] }),
      changedPathsIn,
    )
    expect(verdict.ok).toBe(false)
    expect(verdict.ok === false && verdict.detail).toContain('does not descend')
  })

  it('refuses when the result names a different base than was submitted', async () => {
    const { path, base, child, foreign } = repo()
    const verdict = await verifyCandidate(path, base, child, manifest({ baseCommit: foreign }), changedPathsIn)
    expect(verdict.ok).toBe(false)
    expect(verdict.ok === false && verdict.detail).toContain('was submitted')
  })

  it('refuses when git and the evidence disagree about what changed', async () => {
    // Neither answer is obviously the liar, which is exactly why this refuses:
    // one of them is wrong about what is in the commit.
    const { path, base, child } = repo()
    const extra = await verifyCandidate(
      path,
      base,
      child,
      manifest({ baseCommit: base, changedPaths: ['a.txt', 'never-touched.txt'] }),
      changedPathsIn,
    )
    expect(extra.ok).toBe(false)
    expect(extra.ok === false && extra.detail).toContain('never-touched.txt')

    const short = await verifyCandidate(
      path,
      base,
      child,
      manifest({ baseCommit: base, changedPaths: [] }),
      changedPathsIn,
    )
    expect(short.ok).toBe(false)
    expect(short.ok === false && short.detail).toContain('a.txt')
  })
})
