import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import { Manager } from './manager'
import { resolveOnPath, runSelfGate } from './selfupdate'

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
      build: `node -e "require('fs').writeFileSync('out.txt','built')"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a')
    expect(row.state).toBe('green')
    expect(row.detail).toContain('build completed')
    // Green means the bytes exist, not merely that commands exited 0.
    expect(readFileSync(join(self, 'out.txt'), 'utf8')).toBe('built')
  }, 30_000)

  it('goes red on a failing verify, with the output and the npm that ran', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "console.error('2 tests failed'); process.exit(1)"`,
      build: `node -e "process.exit(0)"`,
    })
    const repo = freshRepo()
    const row = await runSelfGate(repo, self, 'plan-a')
    expect(row.state).toBe('red')
    expect(row.detail).toContain('npm run verify')
    expect(row.detail).toContain('2 tests failed')
    // Honest red details: which npm resolved, and the deps courtesy line.
    expect(row.detail).toContain(resolveOnPath('npm') ?? 'npm')
    expect(row.detail).toContain('npm install')
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

  it('stays dormant when packaged', () => {
    const { manager, repo } = guardHarness(null)
    expect(manager.launchSelfGate('plan-a')).toBe(false)
    expect(repo.listSelfUpdates()).toHaveLength(0)
  })

  it('refuses a second gate while one runs, and disposeAll turns the first red', async () => {
    const self = fakeSelfRepo({
      verify: `node -e "setTimeout(function(){}, 120000)"`,
      build: `node -e "process.exit(0)"`,
    })
    const { manager, repo, events } = guardHarness(self)

    expect(manager.busyWithRuns()).toBeNull()
    expect(manager.launchSelfGate('plan-a')).toBe(true)
    await waitFor(() => repo.listSelfUpdates().length === 1)
    // The gate itself counts as busy — relaunch consults exactly this.
    expect(manager.busyWithRuns()).toContain('gate')

    // Second landing mid-gate: announced and skipped, never queued — the
    // running build already reads an origin that includes it.
    expect(manager.launchSelfGate('plan-b')).toBe(false)
    expect(repo.listSelfUpdates()).toHaveLength(1)
    expect(
      events.some(
        (e) => e.type === 'notice' && e.level === 'warn' && e.message.includes('already running'),
      ),
    ).toBe(true)

    // Quit while the gate runs: the live process finalizes its own record.
    manager.disposeAll()
    await waitFor(() => repo.listSelfUpdates()[0]?.state === 'red')
    expect(repo.listSelfUpdates()[0]?.detail).toContain('Interrupted')

    // The slot was released, so a later landing can gate again.
    await waitFor(() => manager.launchSelfGate('plan-c'))
    await waitFor(() => repo.listSelfUpdates().some((row) => row.planId === 'plan-c'))
    manager.disposeAll()
    await waitFor(() =>
      repo.listSelfUpdates().every((row) => row.state !== 'running'),
    )
  }, 30_000)
})
