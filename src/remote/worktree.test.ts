import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { ensureMirror, prepareRunWorktree, removeRunWorktree, runDirectory } from './worktree'

/**
 * The run worktree, against real git.
 *
 * Every assertion here is about a way the remote could end up executing
 * against something other than what was submitted, so none of it is mocked —
 * the behaviour under test is git's, and a fake would only confirm our idea
 * of it.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

function temp(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix))
  roots.push(root)
  return root
}

function sh(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: 'Test',
      GIT_AUTHOR_EMAIL: 't@example.com',
      GIT_COMMITTER_NAME: 'Test',
      GIT_COMMITTER_EMAIL: 't@example.com',
    },
  }).trim()
}

/** A mirror holding one input ref, as the local side would have left it. */
async function mirrorWithInput(): Promise<{
  mirror: string
  commit: string
  second: string
  runsRoot: string
}> {
  const source = temp('parley-wt-source-')
  sh(source, 'init', '-q', '-b', 'main')
  writeFileSync(join(source, 'file.txt'), 'first\n')
  sh(source, 'add', '-A')
  sh(source, 'commit', '-q', '-m', 'first')
  const commit = sh(source, 'rev-parse', 'HEAD')

  writeFileSync(join(source, 'file.txt'), 'second\n')
  sh(source, 'add', '-A')
  sh(source, 'commit', '-q', '-m', 'second')
  const second = sh(source, 'rev-parse', 'HEAD')

  const mirrorsRoot = temp('parley-wt-mirrors-')
  const created = await ensureMirror(mirrorsRoot, 'repo-key')
  expect(created.ok).toBe(true)
  sh(source, 'push', '-q', created.path!, `${commit}:refs/parley/runs/run-1/input`)
  // The later commit's objects go over too, so a test can point the ref at it
  // — a ref cannot be moved to an object the repository does not have, which
  // is itself the shape of the real hazard: a mirror that has been pushed to
  // twice.
  sh(source, 'push', '-q', created.path!, `${second}:refs/parley/test/second`)
  return { mirror: created.path!, commit, second, runsRoot: temp('parley-wt-runs-') }
}

describe('where a run may put its worktree', () => {
  it('accepts an ordinary run id', () => {
    expect(runDirectory('/runs', '01JABC')).toBe('/runs/01JABC')
  })

  it('refuses anything that could climb out', () => {
    // Checked by resolution rather than by inspecting the string, so a path
    // that lands outside is refused however it got there.
    for (const runId of ['../escape', 'a/../..', '/absolute', 'has space', 'semi;colon', '']) {
      expect(runDirectory('/runs', runId)).toBeNull()
    }
  })
})

describe('creating the run worktree', () => {
  it('checks out the exact submitted object, detached', async () => {
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(result.ok).toBe(true)
    expect(readFileSync(join(result.path!, 'file.txt'), 'utf8')).toBe('first\n')
    expect(sh(result.path!, 'rev-parse', 'HEAD')).toBe(commit)
    // Detached: the run has no branch and must never look like it is on one.
    expect(sh(result.path!, 'rev-parse', '--abbrev-ref', 'HEAD')).toBe('HEAD')
  })

  it('refuses when the ref has moved to a different commit', async () => {
    // The comparison that makes the input snapshot immutable in practice
    // rather than only in intention: a retry, a second Parley or a stale
    // mirror could all leave the ref pointing somewhere else.
    const { mirror, commit, second, runsRoot } = await mirrorWithInput()
    sh(mirror, 'update-ref', 'refs/parley/runs/run-1/input', second)
    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(result.ok).toBe(false)
    expect(result.detail).toContain('refusing to run against a different tree')
    expect(existsSync(join(runsRoot, 'run-1'))).toBe(false)
  })

  it('refuses a ref that is not in the mirror at all', async () => {
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-2',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-2/input',
    })
    expect(result.ok).toBe(false)
    expect(result.detail).toContain('not in the mirror')
  })

  it('refuses a run id that is not a usable directory name', async () => {
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: '../elsewhere',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(result.ok).toBe(false)
  })

  it('refuses a short or malformed commit rather than resolving it', async () => {
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit.slice(0, 8),
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(result.ok).toBe(false)
    expect(result.detail).toContain('full object id')
  })

  it('reclaims a directory left behind by a run that died', async () => {
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const first = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(first.ok).toBe(true)
    writeFileSync(join(first.path!, 'left-behind.txt'), 'from the dead run\n')

    const again = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(again.ok).toBe(true)
    expect(existsSync(join(again.path!, 'left-behind.txt'))).toBe(false)
  })
})

describe('the repository cannot run code during checkout', () => {
  it('does not run hooks the snapshot brought with it', async () => {
    // The snapshot came from another machine. Checking it out must not be an
    // opportunity for that machine's hooks to execute here.
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const hooks = join(mirror, 'hooks')
    mkdirSync(hooks, { recursive: true })
    const marker = join(runsRoot, 'hook-ran')
    const hook = join(hooks, 'post-checkout')
    writeFileSync(hook, `#!/bin/sh\ntouch ${marker}\n`, 'utf8')
    chmodSync(hook, 0o755)

    const result = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(result.ok).toBe(true)
    expect(existsSync(marker)).toBe(false)
  })
})

describe('removing a run worktree', () => {
  it('removes the directory and the administrative entry', async () => {
    // Pruning matters more than it looks: without it the mirror keeps a record
    // of a directory that is gone, and the NEXT run at that id is refused as
    // already registered — the failure surfaces one run after its cause.
    const { mirror, commit, runsRoot } = await mirrorWithInput()
    const created = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    await removeRunWorktree(mirror, created.path!)
    expect(existsSync(created.path!)).toBe(false)
    expect(sh(mirror, 'worktree', 'list')).not.toContain('run-1')

    const reused = await prepareRunWorktree({
      mirrorDir: mirror,
      runsRoot,
      runId: 'run-1',
      expectedCommit: commit,
      inputRef: 'refs/parley/runs/run-1/input',
    })
    expect(reused.ok).toBe(true)
  })

  it('says nothing when there is nothing to remove', async () => {
    // Runs on the cancellation path: refusing to finish because a directory
    // was already gone would leave the caller unable to report the
    // cancellation it was in the middle of.
    const { mirror, runsRoot } = await mirrorWithInput()
    await expect(
      removeRunWorktree(mirror, join(runsRoot, 'never-existed')),
    ).resolves.toBeUndefined()
  })
})

describe('the mirror', () => {
  it('creates a bare repository once and reuses it', async () => {
    const mirrorsRoot = temp('parley-wt-mirror-reuse-')
    const first = await ensureMirror(mirrorsRoot, 'repo-key')
    expect(first.ok).toBe(true)
    expect(existsSync(join(first.path!, 'HEAD'))).toBe(true)
    writeFileSync(join(first.path!, 'marker'), 'still here\n')

    const second = await ensureMirror(mirrorsRoot, 'repo-key')
    expect(second.path).toBe(first.path)
    expect(existsSync(join(first.path!, 'marker'))).toBe(true)
  })

  it('refuses a key that is not a usable directory name', async () => {
    const mirrorsRoot = temp('parley-wt-mirror-bad-')
    expect((await ensureMirror(mirrorsRoot, '../escape')).ok).toBe(false)
  })
})
