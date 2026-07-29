import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { describe, expect, it, vi } from 'vitest'
import type { AppEvent } from '@shared/events'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import type { CaptureResult } from '@main/util/spawn'
import { Manager } from './manager'
import { runSelfGate, type SelfGateOptions } from './selfupdate'

/**
 * The self-update gate against real npm in a fake self repo: package.json
 * scripts mapped to fast `node -e` bodies, so verify and build are genuine
 * child processes with genuine exits — no stubbed spawner — while staying
 * quick enough for the suite.
 */

function fakeSelfRepo(scripts: { verify: string; build: string }): string {
  const path = mkdtempSync(join(tmpdir(), 'parley-selfgate-'))
  writeFileSync(
    join(path, 'package.json'),
    JSON.stringify({ name: 'fake-parley', version: '0.0.0', scripts }, null, 2),
  )
  return path
}

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

async function waitFor(predicate: () => boolean, timeoutMs = 20_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error('timed out waiting for condition')
}

function captured(exitCode = 0): CaptureResult {
  return {
    exitCode,
    signal: null,
    stdout: '',
    stderr: '',
    durationMs: 1,
    timedOut: false,
  }
}

describe('the self-update record', () => {
  it('supersedes the previous green offer at the next attempt, not at its outcome', () => {
    const repo = freshRepo()
    const first = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(first.id, 'green', 'built')
    expect(repo.getPendingSelfUpdate()?.id).toBe(first.id)

    // The moment a new gate can touch out/, the old offer must die — a later
    // failed build would otherwise leave green pointing at half-written bytes.
    const second = repo.fileSelfUpdateAttempt('plan-b')
    expect(second.state).toBe('running')
    expect(repo.getSelfUpdate(first.id)?.state).toBe('superseded')
    expect(repo.getSelfUpdate(first.id)?.decidedAt).not.toBeNull()
    expect(repo.getPendingSelfUpdate()).toBeNull()
  })

  it('can retire one green offer before its queued successor files', () => {
    const repo = freshRepo()
    const first = repo.fileSelfUpdateAttempt('plan-a')
    repo.finalizeSelfUpdate(first.id, 'green', 'built')

    const superseded = repo.supersedeSelfUpdate(first.id)
    expect(superseded.state).toBe('superseded')
    expect(superseded.decidedAt).not.toBeNull()
    expect(repo.getPendingSelfUpdate()).toBeNull()
    expect(() => repo.supersedeSelfUpdate(first.id)).toThrow(/superseded/)
  })

  it('keeps green undecided and stamps decisions when the human makes them', () => {
    const repo = freshRepo()
    const attempt = repo.fileSelfUpdateAttempt('plan-a')
    const green = repo.finalizeSelfUpdate(attempt.id, 'green', 'built')
    expect(green.decidedAt).toBeNull()

    const decided = repo.decideSelfUpdate(attempt.id, 'relaunched')
    expect(decided.state).toBe('relaunched')
    expect(decided.decidedAt).not.toBeNull()
    expect(repo.getPendingSelfUpdate()).toBeNull()
  })

  it('refuses transitions that skip the machine', () => {
    const repo = freshRepo()
    const attempt = repo.fileSelfUpdateAttempt('plan-a')
    // Undecided running rows cannot be decided, only finalized.
    expect(() => repo.decideSelfUpdate(attempt.id, 'declined')).toThrow(/running/)
    const red = repo.finalizeSelfUpdate(attempt.id, 'red', 'broke')
    expect(red.decidedAt).not.toBeNull()
    expect(() => repo.finalizeSelfUpdate(attempt.id, 'green', 'again')).toThrow(/red/)
    expect(() => repo.decideSelfUpdate(attempt.id, 'relaunched')).toThrow(/red/)
  })

  it('reconciles rows a dead process left running', () => {
    const repo = freshRepo()
    const stranded = repo.fileSelfUpdateAttempt('plan-a')
    expect(repo.reconcileSelfUpdates()).toBe(1)
    const row = repo.getSelfUpdate(stranded.id)
    expect(row?.state).toBe('red')
    expect(row?.detail).toContain('Interrupted')
    // Nothing else was touched, and a second sweep is a no-op.
    expect(repo.reconcileSelfUpdates()).toBe(0)
  })
})

describe('the gate, end to end', () => {
  it('goes green when verify and build both pass, and the build actually ran', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "require('fs').mkdirSync('out',{recursive:true}); require('fs').writeFileSync('out/app.js','built')"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a')
    expect(row.state).toBe('green')
    expect(row.detail).toContain('build completed')
    // Green means the bytes exist, not merely that commands exited 0.
    expect(readFileSync(join(self, 'out', 'app.js'), 'utf8')).toBe('built')
  }, 30_000)

  it('goes red when a back-to-back build exits zero without changing the previous output', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "const fs=require('fs'); if(!fs.existsSync('built-once')){fs.mkdirSync('out',{recursive:true}); fs.writeFileSync('out/app.js','built'); fs.writeFileSync('built-once','yes')}"`,
    })
    const repo = freshRepo()
    const first = await runSelfGate(repo, self, 'plan-a')
    expect(first.state).toBe('green')

    const second = await runSelfGate(repo, self, 'plan-b')
    expect(second.state).toBe('red')
    expect(second.detail).toContain('did not change any files in out/')
    expect(repo.getPendingSelfUpdate()).toBeNull()
  }, 30_000)

  it('goes green when a back-to-back build changes an existing file fingerprint', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "const fs=require('fs'); const second=fs.existsSync('built-once'); fs.mkdirSync('out',{recursive:true}); fs.writeFileSync('out/app.js',second?'later':'first'); fs.utimesSync('out/app.js',second?2:1,second?2:1); fs.writeFileSync('built-once','yes')"`,
    })
    const repo = freshRepo()
    const first = await runSelfGate(repo, self, 'plan-a')
    expect(first.state).toBe('green')

    const second = await runSelfGate(repo, self, 'plan-b')
    expect(second.state).toBe('green')
    expect(readFileSync(join(self, 'out', 'app.js'), 'utf8')).toBe('later')
  }, 30_000)

  it('goes red when a zero-exit build leaves out missing', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a')
    expect(row.state).toBe('red')
    expect(row.detail).toContain('out/ is missing or contains no files')
  }, 30_000)

  it('inspects an explicit output directory', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "require('fs').mkdirSync('dist',{recursive:true}); require('fs').writeFileSync('dist/app.js','built')"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a', { outputDir: 'dist' })
    expect(row.state).toBe('green')
    expect(row.detail).toContain('dist/ changed')
    expect(readFileSync(join(self, 'dist', 'app.js'), 'utf8')).toBe('built')
  }, 30_000)

  it('goes red on a failing verify, with the output and the npm that ran', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    const bin = mkdtempSync(join(tmpdir(), 'parley-fake-npm-'))
    const fakeNpm = join(bin, 'npm')
    writeFileSync(fakeNpm, '#!/bin/sh\necho "fake npm verify failed" >&2\nexit 1\n', {
      mode: 0o755,
    })
    const originalPath = process.env['PATH']
    try {
      process.env['PATH'] = originalPath ? `${bin}${delimiter}${originalPath}` : bin
      const repo = freshRepo()
      const row = await runSelfGate(repo, self, 'plan-a')
      expect(row.state).toBe('red')
      expect(row.detail).toContain('npm run verify')
      expect(row.detail).toContain('fake npm verify failed')
      // Honest red details: which npm resolved, and the deps courtesy line.
      expect(row.detail).toContain(fakeNpm)
      expect(row.detail).toContain('npm install')
    } finally {
      if (originalPath === undefined) delete process.env['PATH']
      else process.env['PATH'] = originalPath
    }
  }, 30_000)

  it('goes red when verify passes but build exits 2, without a relaunch offer', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "console.error('fixture build failed'); process.exit(2)"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a')
    expect(row.state).toBe('red')
    expect(row.detail).toContain('npm run build')
    expect(row.detail).toContain('exited 2')
    expect(row.detail).toContain('fixture build failed')
    expect(repo.getPendingSelfUpdate()).toBeNull()
  }, 30_000)

  it('times out red and the whole process tree dies with it', async () => {
    const self = fakeSelfRepo({
      // The script records its own pid so the test can prove the grandchild —
      // npm's child, not ours — was killed. That is exactly what killTree adds.
      verify: `node -e "require('fs').writeFileSync('pid.txt', String(process.pid)); setTimeout(function(){}, 120000)"`,
      build: `node -e "process.exit(0)"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a', { timeoutMs: 4000 })
    expect(row.state).toBe('red')
    expect(row.detail).toContain('time limit')

    const pid = Number(readFileSync(join(self, 'pid.txt'), 'utf8'))
    expect(Number.isInteger(pid) && pid > 0).toBe(true)
    await waitFor(() => {
      try {
        process.kill(pid, 0)
        return false
      } catch {
        return true // ESRCH: the sleeper is gone.
      }
    }, 8000)
  }, 30_000)
})

describe('the manager guard', () => {
  function guardHarness(selfRepoPath: string | null): {
    manager: Manager
    repo: Repo
    events: AppEvent[]
  } {
    const repo = freshRepo()
    const events: AppEvent[] = []
    const manager = new Manager({
      repo,
      registry: new AgentRegistry(true),
      emit: (event) => events.push(event),
      selfRepoPath,
    })
    return { manager, repo, events }
  }

  function landedWorktree(repo: Repo, planId: string, orphaned = false): void {
    repo.createWorktree({
      planId,
      originPath: '/origin',
      path: '/worktree',
      branch: `parley/implementation-${planId}`,
      baseBranch: 'main',
      baseCommit: 'base',
      createdAt: Date.now(),
      landedAt: Date.now(),
      lastError: '',
      orphaned,
    })
  }

  it('stays dormant when packaged', () => {
    const { manager, repo } = guardHarness(null)
    expect(manager.launchSelfGate('plan-a')).toBe('dormant')
    expect(repo.listSelfUpdates()).toHaveLength(0)
  })

  it('coalesces queued landings and gates the newest after the active build', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    writeFileSync(join(self, 'landing.txt'), 'plan-a')
    const buildsSaw: string[] = []
    let releaseFirstBuild = (): void => {}
    const firstBuildReleased = new Promise<void>((resolve) => {
      releaseFirstBuild = resolve
    })
    let markFirstBuildStarted = (): void => {}
    const firstBuildStarted = new Promise<void>((resolve) => {
      markFirstBuildStarted = resolve
    })
    let builds = 0
    const capture: NonNullable<SelfGateOptions['capture']> = async (_command, args, cwd) => {
      if (args[1] === 'verify') return captured()
      builds += 1
      const source = readFileSync(join(cwd, 'landing.txt'), 'utf8')
      buildsSaw.push(source)
      if (builds === 1) {
        markFirstBuildStarted()
        await firstBuildReleased
      }
      mkdirSync(join(cwd, 'out'), { recursive: true })
      writeFileSync(join(cwd, 'out', 'app.js'), source)
      return captured()
    }
    const { manager, repo, events } = guardHarness(self)

    expect(manager.launchSelfGate('plan-a', { capture })).toBe('started')
    await firstBuildStarted
    writeFileSync(join(self, 'landing.txt'), 'plan-b')
    expect(manager.launchSelfGate('plan-b', { capture })).toBe('queued')
    writeFileSync(join(self, 'landing.txt'), 'plan-c-newer')
    expect(manager.launchSelfGate('plan-c', { capture })).toBe('queued')

    // A queue entry is not a run and therefore has no durable attempt yet.
    expect(repo.listSelfUpdates()).toHaveLength(1)
    expect(manager.busyWithRuns()).toContain('queued')
    releaseFirstBuild()

    await waitFor(
      () =>
        repo.listSelfUpdates().length === 2 &&
        repo.listSelfUpdates().every((row) => row.state !== 'running'),
    )
    expect(repo.listSelfUpdates().some((row) => row.planId === 'plan-b')).toBe(false)
    expect(repo.listSelfUpdates().find((row) => row.planId === 'plan-a')?.state).toBe(
      'superseded',
    )
    expect(repo.listSelfUpdates().find((row) => row.planId === 'plan-c')?.state).toBe('green')
    expect(buildsSaw).toEqual(['plan-a', 'plan-c-newer'])
    expect(
      events.filter(
        (event) =>
          event.type === 'notice' &&
          event.level === 'info' &&
          event.message.includes('Relaunch'),
      ),
    ).toHaveLength(1)
  })

  it('retires green before a queued follow-up whose filing throws', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    let releaseBuild = (): void => {}
    const buildReleased = new Promise<void>((resolve) => {
      releaseBuild = resolve
    })
    let markBuildStarted = (): void => {}
    const buildStarted = new Promise<void>((resolve) => {
      markBuildStarted = resolve
    })
    const capture: NonNullable<SelfGateOptions['capture']> = async (_command, args, cwd) => {
      if (args[1] === 'verify') return captured()
      markBuildStarted()
      await buildReleased
      mkdirSync(join(cwd, 'out'), { recursive: true })
      writeFileSync(join(cwd, 'out', 'app.js'), 'built')
      return captured()
    }
    const { manager, repo, events } = guardHarness(self)

    expect(manager.launchSelfGate('plan-a', { capture })).toBe('started')
    await buildStarted
    vi.spyOn(repo, 'fileSelfUpdateAttempt').mockImplementationOnce(() => {
      throw new Error('fixture filing failed')
    })
    expect(manager.launchSelfGate('plan-b', { capture })).toBe('queued')
    releaseBuild()

    await waitFor(() =>
      events.some(
        (event) =>
          event.type === 'notice' &&
          event.level === 'warn' &&
          event.message.includes('fixture filing failed'),
      ),
    )
    expect(repo.listSelfUpdates()).toHaveLength(1)
    expect(repo.listSelfUpdates()[0]?.state).toBe('superseded')
    expect(repo.getPendingSelfUpdate()).toBeNull()
    expect(
      events.some(
        (event) =>
          event.type === 'notice' &&
          event.level === 'info' &&
          event.message.includes('Relaunch'),
      ),
    ).toBe(false)
  })

  it('clears a red gate flag when a later gate comes back green', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    const { manager, repo } = guardHarness(self)
    landedWorktree(repo, 'plan-a', true)

    const redCapture: NonNullable<SelfGateOptions['capture']> = async () => captured(1)
    expect(manager.launchSelfGate('plan-a', { capture: redCapture })).toBe('started')
    await waitFor(() => manager.busyWithRuns() === null)
    const gateDetail = repo.listSelfUpdates()[0]?.detail
    expect(repo.getWorktreeForPlan('plan-a')).toMatchObject({
      lastError: gateDetail,
      orphaned: true,
    })

    const greenCapture: NonNullable<SelfGateOptions['capture']> = async (
      _command,
      args,
      cwd,
    ) => {
      if (args[1] === 'build') {
        mkdirSync(join(cwd, 'out'), { recursive: true })
        writeFileSync(join(cwd, 'out', 'app.js'), 'built')
      }
      return captured()
    }
    expect(manager.launchSelfGate('plan-b', { capture: greenCapture })).toBe('started')
    await waitFor(() => manager.busyWithRuns() === null)
    expect(
      repo.listSelfUpdates().some((row) => row.planId === 'plan-b' && row.state === 'green'),
    ).toBe(true)
    expect(repo.getWorktreeForPlan('plan-a')).toMatchObject({
      lastError: '',
      orphaned: true,
    })
  })

  it('leaves an unrelated worktree error when a later gate comes back green', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "process.exit(0)"`,
      build: `node -e "process.exit(0)"`,
    })
    const { manager, repo } = guardHarness(self)
    landedWorktree(repo, 'plan-a')

    const redCapture: NonNullable<SelfGateOptions['capture']> = async () => captured(1)
    expect(manager.launchSelfGate('plan-a', { capture: redCapture })).toBe('started')
    await waitFor(() => manager.busyWithRuns() === null)
    repo.flagWorktree('plan-a', false, 'Landing cleanup left the branch behind.')

    const greenCapture: NonNullable<SelfGateOptions['capture']> = async (
      _command,
      args,
      cwd,
    ) => {
      if (args[1] === 'build') {
        mkdirSync(join(cwd, 'out'), { recursive: true })
        writeFileSync(join(cwd, 'out', 'app.js'), 'built')
      }
      return captured()
    }
    expect(manager.launchSelfGate('plan-b', { capture: greenCapture })).toBe('started')
    await waitFor(() => manager.busyWithRuns() === null)
    expect(
      repo.listSelfUpdates().some((row) => row.planId === 'plan-b' && row.state === 'green'),
    ).toBe(true)
    expect(repo.getWorktreeForPlan('plan-a')?.lastError).toBe(
      'Landing cleanup left the branch behind.',
    )
  })

  it('disposeAll clears a queued gate and turns the active one red', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "setTimeout(function(){}, 120000)"`,
      build: `node -e "process.exit(0)"`,
    })
    const { manager, repo, events } = guardHarness(self)

    expect(manager.busyWithRuns()).toBeNull()
    expect(manager.launchSelfGate('plan-a')).toBe('started')
    await waitFor(() => repo.listSelfUpdates().length === 1)
    // The gate itself counts as busy — relaunch consults exactly this.
    expect(manager.busyWithRuns()).toContain('gate')

    expect(manager.launchSelfGate('plan-b')).toBe('queued')
    expect(repo.listSelfUpdates()).toHaveLength(1)
    expect(
      events.some(
        (e) => e.type === 'notice' && e.level === 'info' && e.message.includes('queued'),
      ),
    ).toBe(true)

    // Quit while the gate runs: the live process finalizes its own record.
    manager.disposeAll()
    await waitFor(() => repo.listSelfUpdates()[0]?.state === 'red')
    expect(repo.listSelfUpdates()[0]?.detail).toContain('Interrupted')
    expect(repo.listSelfUpdates().some((row) => row.planId === 'plan-b')).toBe(false)

    // The slot was released, so a later landing can gate again.
    await waitFor(() => manager.launchSelfGate('plan-c') === 'started')
    await waitFor(() => repo.listSelfUpdates().some((row) => row.planId === 'plan-c'))
    manager.disposeAll()
    await waitFor(() =>
      repo.listSelfUpdates().every((row) => row.state !== 'running'),
    )
  }, 30_000)
})
