import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { emptyUsage, type Milestone, type WorkPlan } from '@shared/domain'
import {
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  type RemoteCapabilities,
  type RemoteFrame,
  type RemoteTarget,
} from '@shared/remote'
import type { MilestoneFact, MilestoneReporter } from '@main/orchestrator/reporter'
import { driveRemoteMilestone, type RemoteDriverDeps } from './driver'

/**
 * The local orchestration, with the wire faked and everything else real.
 *
 * The transport is injected because what these tests are about is ORDER and
 * what gets charged for — when the approval is spent, what happens when the
 * link dies at each point, what is refused. Real ssh is exercised in
 * src/remote/bundle.test.ts; putting it here too would make these slow and
 * would not make them stronger.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

function gitRepo(): { path: string; mirror: string } {
  const path = mkdtempSync(join(tmpdir(), 'parley-driver-'))
  roots.push(path)
  const git = (cwd: string, ...args: string[]): string =>
    execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      env: {
        ...process.env,
        GIT_AUTHOR_NAME: 'T',
        GIT_AUTHOR_EMAIL: 't@e.com',
        GIT_COMMITTER_NAME: 'T',
        GIT_COMMITTER_EMAIL: 't@e.com',
      },
    }).trim()
  git(path, 'init', '-q', '-b', 'main')
  writeFileSync(join(path, 'a.txt'), 'one\n')
  git(path, 'add', '-A')
  git(path, 'commit', '-q', '-m', 'seed')

  const mirror = mkdtempSync(join(tmpdir(), 'parley-driver-mirror-'))
  roots.push(mirror)
  git(mirror, 'init', '-q', '--bare')
  return { path, mirror }
}

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

const capabilities: RemoteCapabilities = {
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: 'b'.repeat(64),
  nodeVersion: 'v24.4.1',
  nodeExecutable: '/usr/bin/node',
  capabilities: [...REQUIRED_CAPABILITIES],
  supportedVendors: ['claude', 'codex'],
  availableVendors: ['claude', 'codex'],
  vendorDetails: {},
  user: 'build',
  home: '/home/build',
  path: '/usr/bin',
  git: '2.45.0',
  runsRoot: '/home/build/.local/share/parley/runs',
}

const milestone = {
  id: 'm1',
  planId: 'p1',
  status: 'executing',
  reviewPassed: null,
  completedAt: null,
  testResult: null,
  reviewNote: '',
} as unknown as Milestone

function frame(sequence: number, body: RemoteFrame['body']): RemoteFrame {
  return { protocolVersion: REMOTE_PROTOCOL_VERSION, runId: 'run-1', sequence, body }
}

interface Harness {
  deps: RemoteDriverDeps
  charges: number
  recorded: MilestoneFact[]
}

/** A fake wire: the caller scripts what each conversation sends back. */
function harness(
  mirror: string,
  script: {
    prepare?: RemoteFrame[]
    prepareEnd?: RemoteDriverDeps extends never ? never : Awaited<ReturnType<RemoteDriverDeps['converse']>>
    run?: RemoteFrame[]
    runEnd?: Awaited<ReturnType<RemoteDriverDeps['converse']>>
  },
): Harness {
  const state = { charges: 0, recorded: [] as MilestoneFact[] }
  const reporter: MilestoneReporter = {
    record: (fact) => {
      state.recorded.push(fact)
      return milestone
    },
    activity: () => {},
    milestone,
  }
  let call = 0
  const deps: RemoteDriverDeps = {
    converse: async (_target, request, onFrame) => {
      call += 1
      if (request.operation === 'prepare') {
        for (const f of script.prepare ?? [
          frame(1, { type: 'ready', capabilities }),
          frame(2, { type: 'prepared', mirror }),
        ]) {
          onFrame(f)
        }
        return script.prepareEnd ?? { kind: 'closed', detail: '' }
      }
      for (const f of script.run ?? []) onFrame(f)
      return script.runEnd ?? { kind: 'closed', detail: '' }
    },
    consumeApproval: () => {
      state.charges += 1
    },
    reporter,
    currentMilestone: () => milestone,
    changedPathsIn: async () => [],
    // The "host" here is a bare repository on this disk, so git addresses it
    // by path. Everything else about the sequence is unchanged.
    remoteUrlFor: (_target, at) => at,
  }
  return {
    deps,
    get charges() {
      return state.charges
    },
    get recorded() {
      return state.recorded
    },
  }
}

function inputFor(path: string, target: RemoteTarget) {
  const plan = {
    id: 'p1',
    repoPath: path,
    executor: codex,
    reviewer: claude,
    mock: true,
    usage: emptyUsage(),
  } as unknown as WorkPlan
  return { runId: 'run-1', target, repoKey: 'repo-key', plan, milestone }
}

const target: RemoteTarget = {
  id: 't1',
  label: 'build-01',
  host: 'build-01',
  runsRoot: '/home/build/.local/share/parley/runs',
  createdAt: 1,
}

describe('what gets charged for', () => {
  it('spends nothing when the host cannot be prepared', async () => {
    // Nothing ran over there, so the approval is still good and the user
    // should not have to grant a fresh one to retry.
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      prepare: [],
      prepareEnd: { kind: 'refused', detail: 'ssh refused the connection' },
    })
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('unstarted')
    expect(h.charges).toBe(0)
  })

  it('spends nothing when the host lacks the plan’s CLI', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      prepare: [
        frame(1, { type: 'ready', capabilities: { ...capabilities, availableVendors: ['claude'] } }),
        frame(2, { type: 'prepared', mirror }),
      ],
    })
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('unstarted')
    expect(outcome.kind === 'unstarted' && outcome.detail).toContain('codex')
    expect(h.charges).toBe(0)
  })

  it('spends nothing when the run conversation never reaches ready', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [],
      runEnd: { kind: 'protocol', detail: 'parley-remote is not installed' },
    })
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('unstarted')
    expect(h.charges).toBe(0)
  })

  it('spends exactly once, on ready', async () => {
    // The first moment anything over there can cost money. Charging earlier
    // would burn a single-use approval on a transport failure.
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [
        frame(1, { type: 'ready', capabilities }),
        frame(2, { type: 'ready', capabilities }),
        frame(3, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
      ],
    })
    await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(h.charges).toBe(1)
  })
})

describe('endings', () => {
  it('reports a run that ended without a result, and imports nothing', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [
        frame(1, { type: 'ready', capabilities }),
        frame(2, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
        frame(3, { type: 'error', message: 'the reviewer blocked it', retryable: false }),
      ],
    })
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('ended')
    expect(outcome.kind === 'ended' && outcome.detail).toContain('reviewer')
    // The facts still landed: the record should say what happened.
    expect(h.recorded).toHaveLength(1)
  })

  it('calls a mid-run disconnect disconnected, never failed', async () => {
    // The work may have finished. The recovery is to go and look for its
    // candidate, not to run it again.
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [frame(1, { type: 'ready', capabilities })],
      runEnd: { kind: 'disconnected', detail: 'ssh was killed by SIGKILL' },
    })
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('disconnected')
    expect(h.charges).toBe(1)
  })

  it('treats a protocol violation as a disconnect for the same reason', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [frame(1, { type: 'ready', capabilities })],
      runEnd: { kind: 'violation', detail: 'unreadable output after the handshake' },
    })
    expect((await driveRemoteMilestone(inputFor(path, target), h.deps)).kind).toBe('disconnected')
  })
})

describe('what the record gets', () => {
  it('replays the remote’s facts through the reporter, in order', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [
        frame(1, { type: 'ready', capabilities }),
        frame(2, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
        frame(3, { type: 'fact', fact: { kind: 'judgement', passed: true } }),
      ],
    })
    await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(h.recorded).toEqual([
      { kind: 'phase', phase: 'testing' },
      { kind: 'judgement', passed: true },
    ])
  })

  it('rejects the whole run when the milestone moved locally', async () => {
    const { path, mirror } = gitRepo()
    const h = harness(mirror, {
      run: [
        frame(1, { type: 'ready', capabilities }),
        frame(2, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
      ],
    })
    // Someone stopped it here while the remote was working.
    h.deps.currentMilestone = () => ({ ...milestone, status: 'failed' }) as Milestone
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('rejected')
    expect(outcome.kind === 'rejected' && outcome.detail).toContain('no longer exists')
    expect(h.recorded).toEqual([])
  })
})

describe('the snapshot has to be real', () => {
  it('does not start a run it could not snapshot for', async () => {
    const notARepo = mkdtempSync(join(tmpdir(), 'parley-driver-bare-'))
    roots.push(notARepo)
    const { mirror } = gitRepo()
    const h = harness(mirror, {})
    const outcome = await driveRemoteMilestone(inputFor(notARepo, target), h.deps)
    expect(outcome.kind).toBe('unstarted')
    expect(h.charges).toBe(0)
  })
})

describe('a remote run leaves the same kind of story', () => {
  function journalling(mirror: string, frames: RemoteFrame[]) {
    const journal: Array<{ kind: string; actor: { kind: string; vendor?: string; targetId?: string } }> = []
    const h = harness(mirror, { run: frames })
    h.deps.reporter = {
      record: (fact, actor) => {
        journal.push({ kind: `fact:${fact.kind}`, actor: actor ?? { kind: 'derived-here' } })
        return milestone
      },
      activity: (phase) => journal.push({ kind: `activity:${phase}`, actor: { kind: 'n/a' } }),
      milestone,
    }
    return { h, journal }
  }

  it('records the remote’s own attribution rather than re-deriving it', async () => {
    // The far end knows which agent actually ran. Deriving it here would put
    // this machine's idea of the roles onto work it never watched.
    const { path, mirror } = gitRepo()
    const { h, journal } = journalling(mirror, [
      frame(1, { type: 'ready', capabilities }),
      frame(2, {
        type: 'fact',
        fact: { kind: 'finding', text: 'unsafe cast', round: 0, blocking: true, source: 'review' },
        actor: { kind: 'reviewer', vendor: 'claude', targetId: 'build-01' },
      }),
    ])
    await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(journal).toContainEqual({
      kind: 'fact:finding',
      actor: { kind: 'reviewer', vendor: 'claude', targetId: 'build-01' },
    })
  })

  it('journals the remote’s narrative, not only its facts', async () => {
    // Routing progress straight to the renderer would leave a remote run's
    // story thinner than a local one's, for no reason visible afterwards.
    const { path, mirror } = gitRepo()
    const { h, journal } = journalling(mirror, [
      frame(1, { type: 'ready', capabilities }),
      frame(2, { type: 'progress', phase: 'executing', text: 'codex started' }),
    ])
    await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(journal.some((entry) => entry.kind === 'activity:executing')).toBe(true)
  })

  it('writes nothing when the milestone moved under the run', async () => {
    // The refusal must leave the journal untouched rather than half-written: a
    // partial story about a state that no longer exists is worse than none.
    const { path, mirror } = gitRepo()
    const { h, journal } = journalling(mirror, [
      frame(1, { type: 'ready', capabilities }),
      frame(2, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
    ])
    h.deps.currentMilestone = () => ({ ...milestone, status: 'failed' }) as Milestone
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('rejected')
    expect(journal.filter((entry) => entry.kind.startsWith('fact:'))).toEqual([])
  })

  it('writes nothing after a gap', async () => {
    const { path, mirror } = gitRepo()
    const { h, journal } = journalling(mirror, [
      frame(1, { type: 'ready', capabilities }),
      frame(2, { type: 'fact', fact: { kind: 'phase', phase: 'testing' } }),
      frame(4, { type: 'fact', fact: { kind: 'judgement', passed: true } }),
    ])
    const outcome = await driveRemoteMilestone(inputFor(path, target), h.deps)
    expect(outcome.kind).toBe('rejected')
    // The one before the gap stands; nothing past it does.
    expect(journal.filter((entry) => entry.kind.startsWith('fact:'))).toEqual([
      { kind: 'fact:phase', actor: { kind: 'derived-here' } },
    ])
  })
})
