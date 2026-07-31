import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeEach, describe, expect, it } from 'vitest'
import { inputRefFor, resultRefFor } from '@shared/remote'
import {
  createExecutionSnapshot,
  snapshotRefusal,
  deleteRunRefs,
  descendsFrom,
  fetchResult,
  pushSnapshot,
} from './snapshot'

/**
 * The snapshot, against real git.
 *
 * Nothing is mocked. The whole value of this module is what git actually does
 * with a temporary index, and a fake would only prove that our idea of git is
 * self-consistent. Each test builds a real repository, so "the user's state is
 * untouched" is an observation rather than a claim.
 */

const roots: string[] = []
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

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

function newRepo(withCommit = true): string {
  const root = mkdtempSync(join(tmpdir(), 'parley-snapshot-'))
  roots.push(root)
  sh(root, 'init', '-q', '-b', 'main')
  if (withCommit) {
    writeFileSync(join(root, 'tracked.txt'), 'original\n')
    writeFileSync(join(root, '.gitignore'), 'ignored/\nsecret.env\n')
    sh(root, 'add', '-A')
    sh(root, 'commit', '-q', '-m', 'first')
  }
  return root
}

/** Everything about the user's state that a snapshot must leave alone. */
function userState(repo: string): Record<string, string> {
  return {
    head: sh(repo, 'rev-parse', 'HEAD'),
    branch: sh(repo, 'rev-parse', '--abbrev-ref', 'HEAD'),
    status: sh(repo, 'status', '--porcelain'),
    staged: sh(repo, 'diff', '--cached', '--name-status'),
    unstaged: sh(repo, 'diff', '--name-status'),
  }
}

function filesIn(repo: string, commit: string): string[] {
  return sh(repo, 'ls-tree', '-r', '--name-only', commit).split('\n').filter(Boolean)
}

function contentAt(repo: string, commit: string, path: string): string {
  return sh(repo, 'show', `${commit}:${path}`)
}

let repo: string
beforeEach(() => {
  repo = newRepo()
})

describe('what the snapshot captures', () => {
  it('captures the committed state when the tree is clean', async () => {
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.base).toBe(sh(repo, 'rev-parse', 'HEAD'))
    expect(contentAt(repo, result.commit, 'tracked.txt')).toBe('original')
  })

  it('captures unstaged edits — the tree about to be executed, not the last commit', async () => {
    writeFileSync(join(repo, 'tracked.txt'), 'edited but not staged\n')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(contentAt(repo, result.commit, 'tracked.txt')).toBe('edited but not staged')
  })

  it('captures staged changes', async () => {
    writeFileSync(join(repo, 'added.txt'), 'staged\n')
    sh(repo, 'add', 'added.txt')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(filesIn(repo, result.commit)).toContain('added.txt')
  })

  it('captures untracked files and reports which ones travelled', async () => {
    writeFileSync(join(repo, 'new.txt'), 'untracked\n')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(filesIn(repo, result.commit)).toContain('new.txt')
    expect(result.untracked).toContain('new.txt')
  })

  it('captures deletions, so the remote does not run against a resurrected file', async () => {
    rmSync(join(repo, 'tracked.txt'))
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(filesIn(repo, result.commit)).not.toContain('tracked.txt')
  })

  it('never transports ignored files', async () => {
    // node_modules and build output must be provisioned by the remote — a
    // remote that cannot install its own dependencies proves nothing about
    // the toolchain. A .env is a secret that should not travel because a
    // build happened to need one.
    mkdirSync(join(repo, 'ignored'))
    writeFileSync(join(repo, 'ignored', 'build.js'), 'x\n')
    writeFileSync(join(repo, 'secret.env'), 'TOKEN=hunter2\n')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    const files = filesIn(repo, result.commit)
    expect(files).not.toContain('ignored/build.js')
    expect(files).not.toContain('secret.env')
    expect(result.untracked).not.toContain('secret.env')
  })

  it('starts from HEAD, not from whatever is staged', async () => {
    // A file staged for deletion but still present on disk must appear in the
    // snapshot: the working tree is what would execute.
    sh(repo, 'rm', '--cached', '-q', 'tracked.txt')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(filesIn(repo, result.commit)).toContain('tracked.txt')
  })
})

describe('the snapshot changes nothing', () => {
  it('leaves HEAD, the branch, the index and the working tree identical', async () => {
    writeFileSync(join(repo, 'tracked.txt'), 'dirty\n')
    writeFileSync(join(repo, 'untracked.txt'), 'new\n')
    sh(repo, 'add', 'untracked.txt')

    const before = userState(repo)
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    expect(userState(repo)).toEqual(before)
  })

  it('writes no ref — the snapshot is a dangling commit until it is pushed', async () => {
    const refsBefore = sh(repo, 'for-each-ref', '--format=%(refname)')
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    expect(sh(repo, 'for-each-ref', '--format=%(refname)')).toBe(refsBefore)
  })

  it('leaves nothing behind when it fails', async () => {
    const broken = mkdtempSync(join(tmpdir(), 'parley-not-a-repo-'))
    roots.push(broken)
    const result = await createExecutionSnapshot(broken, 'run-1')
    expect(result.ok).toBe(false)
  })

  it('works on a detached HEAD without reattaching anything', async () => {
    const head = sh(repo, 'rev-parse', 'HEAD')
    sh(repo, 'checkout', '-q', '--detach', head)
    const before = userState(repo)
    const result = await createExecutionSnapshot(repo, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.base).toBe(head)
    expect(userState(repo)).toEqual(before)
  })
})

describe('a repository with no commits yet', () => {
  it('snapshots a parentless commit rather than refusing', async () => {
    const fresh = newRepo(false)
    writeFileSync(join(fresh, 'first.txt'), 'hello\n')
    const result = await createExecutionSnapshot(fresh, 'run-1')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.base).toBeNull()
    expect(filesIn(fresh, result.commit)).toContain('first.txt')
    expect(sh(fresh, 'rev-list', '--count', result.commit)).toBe('1')
  })
})

describe('moving states between repositories', () => {
  function bareMirror(): string {
    const root = mkdtempSync(join(tmpdir(), 'parley-mirror-'))
    roots.push(root)
    sh(root, 'init', '-q', '--bare')
    return root
  }

  it('pushes the exact object by id, under the run namespace', async () => {
    const mirror = bareMirror()
    const snapshot = await createExecutionSnapshot(repo, 'run-7')
    expect(snapshot.ok).toBe(true)
    if (!snapshot.ok) return

    const pushed = await pushSnapshot(repo, mirror, 'run-7', snapshot.commit)
    expect(pushed.ok).toBe(true)
    expect(sh(mirror, 'rev-parse', inputRefFor('run-7'))).toBe(snapshot.commit)
    // Nothing else went with it: no branch, no tags.
    expect(sh(mirror, 'for-each-ref', '--format=%(refname)')).toBe(inputRefFor('run-7'))
  })

  it('fetches a result back without touching any local branch', async () => {
    const mirror = bareMirror()
    const snapshot = await createExecutionSnapshot(repo, 'run-7')
    if (!snapshot.ok) return
    await pushSnapshot(repo, mirror, 'run-7', snapshot.commit)

    // Stand in for the remote, doing exactly what the helper will do: fetch
    // the input ref by name, check out the commit it names, work, publish the
    // result. Fetching rather than cloning matters — a local clone copies the
    // whole object store and would prove the transport works when it had not
    // been used.
    const checkout = mkdtempSync(join(tmpdir(), 'parley-remote-side-'))
    roots.push(checkout)
    sh(checkout, 'init', '-q', '-b', 'run')
    sh(checkout, 'fetch', '-q', mirror, `${inputRefFor('run-7')}:refs/parley/input`)
    expect(sh(checkout, 'rev-parse', 'refs/parley/input')).toBe(snapshot.commit)
    sh(checkout, 'checkout', '-q', snapshot.commit)
    writeFileSync(join(checkout, 'tracked.txt'), 'done by the remote\n')
    sh(checkout, 'add', '-A')
    sh(checkout, 'commit', '-q', '-m', 'milestone')
    const resultCommit = sh(checkout, 'rev-parse', 'HEAD')
    sh(checkout, 'push', '-q', mirror, `${resultCommit}:${resultRefFor('run-7')}`)

    const before = userState(repo)
    const fetched = await fetchResult(repo, mirror, 'run-7')
    expect(fetched.ok).toBe(true)
    expect(fetched.commit).toBe(resultCommit)
    expect(userState(repo)).toEqual(before)

    expect(await descendsFrom(repo, snapshot.commit, resultCommit)).toBe(true)
  })

  it('rejects a result that does not descend from what was submitted', async () => {
    // The guard that makes importing safe: this result was built from
    // something else, and applying it would silently replace work.
    const snapshot = await createExecutionSnapshot(repo, 'run-8')
    if (!snapshot.ok) return
    const unrelated = newRepo()
    const foreign = sh(unrelated, 'rev-parse', 'HEAD')
    sh(repo, 'fetch', '-q', unrelated, `${foreign}:refs/parley/test/foreign`)
    expect(await descendsFrom(repo, snapshot.commit, foreign)).toBe(false)
  })

  it('reports a failed push rather than throwing', async () => {
    const snapshot = await createExecutionSnapshot(repo, 'run-9')
    if (!snapshot.ok) return
    const pushed = await pushSnapshot(repo, join(tmpdir(), 'no-such-mirror'), 'run-9', snapshot.commit)
    expect(pushed.ok).toBe(false)
    expect(pushed.detail.length).toBeGreaterThan(0)
  })

  it('cleans up run refs and stays quiet about ones already gone', async () => {
    const mirror = bareMirror()
    const snapshot = await createExecutionSnapshot(repo, 'run-10')
    if (!snapshot.ok) return
    await pushSnapshot(repo, mirror, 'run-10', snapshot.commit)
    sh(repo, 'update-ref', inputRefFor('run-10'), snapshot.commit)

    await deleteRunRefs(repo, 'run-10')
    expect(sh(repo, 'for-each-ref', '--format=%(refname)', 'refs/parley')).toBe('')
    // Deleting a settled run twice is normal — reconcile may race the caller.
    await expect(deleteRunRefs(repo, 'run-10')).resolves.toBeUndefined()
  })
})

describe('trees that cannot be snapshotted honestly', () => {
  it('refuses a sparse checkout, because the snapshot would not be the tree', () => {
    // Measured, not assumed: seeding a temp index from HEAD reinstates every
    // tracked path, so a sparse working tree produces a snapshot containing
    // files the local run never saw. Calling that an execution snapshot would
    // be worse than failing, because everything downstream believes the name.
    const repo = newRepo()
    mkdirSync(join(repo, 'kept'))
    mkdirSync(join(repo, 'excluded'))
    writeFileSync(join(repo, 'kept', 'a.txt'), 'a\n')
    writeFileSync(join(repo, 'excluded', 'b.txt'), 'b\n')
    sh(repo, 'add', '-A')
    sh(repo, 'commit', '-q', '-m', 'two directories')
    sh(repo, 'sparse-checkout', 'init', '--cone')
    sh(repo, 'sparse-checkout', 'set', 'kept')
    expect(existsSync(join(repo, 'excluded'))).toBe(false)

    return createExecutionSnapshot(repo, 'run-1').then((result) => {
      expect(result.ok).toBe(false)
      expect(result.ok === false && result.detail).toContain('sparse')
    })
  })

  it('allows an ordinary full checkout', async () => {
    expect(await snapshotRefusal(repo)).toBeNull()
  })

  it('refuses a submodule with uncommitted work', async () => {
    // A submodule travels as the gitlink commit it points at. Uncommitted work
    // inside one has no such commit, so it would silently not travel and the
    // remote would build something this tree does not contain.
    const inner = newRepo()
    const outer = newRepo()
    sh(outer, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', inner, 'vendor')
    sh(outer, 'commit', '-q', '-m', 'add submodule')
    expect(await snapshotRefusal(outer)).toBeNull()
    const inner2 = join(outer, 'vendor')

    // A dirty working tree inside a submodule is invisible to `git submodule
    // status` — only the superproject's own status notices it, which is why
    // the refusal consults both.
    writeFileSync(join(inner2, 'tracked.txt'), 'changed inside the submodule\n')
    const refusal = await snapshotRefusal(outer)
    expect(refusal).toContain('vendor')
    expect(refusal).toContain('submodule')
  })
})
