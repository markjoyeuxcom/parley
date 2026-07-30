import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { gitIdentity } from './gitIdentity'

function run(cwd: string, ...args: string[]): void {
  execFileSync('git', args, { cwd, stdio: 'ignore' })
}

function seedRepo(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  run(dir, 'init', '-q', '-b', 'main')
  run(dir, 'config', 'user.email', 'test@example.invalid')
  run(dir, 'config', 'user.name', 'Parley Test')
  writeFileSync(join(dir, 'seed.txt'), 'seed\n')
  run(dir, 'add', '.')
  run(dir, 'commit', '-qm', 'seed')
  return dir
}

describe('gitIdentity', () => {
  it('reports branch, cleanliness and no-upstream for a plain repository', async () => {
    const repo = seedRepo('parley-gitid-clean-')
    const identity = await gitIdentity(repo)
    expect(identity).not.toBeNull()
    expect(identity?.branch).toBe('main')
    expect(identity?.dirty).toBe(false)
    expect(identity?.hasUpstream).toBe(false)
    expect(identity?.ahead).toBe(0)
    expect(identity?.behind).toBe(0)
  })

  it('sees dirt, and resolves the root through a subdirectory', async () => {
    const repo = seedRepo('parley-gitid-dirty-')
    writeFileSync(join(repo, 'uncommitted.txt'), 'wip\n')
    const identity = await gitIdentity(repo)
    expect(identity?.dirty).toBe(true)

    // From a subdirectory the identity is the repository's, not the folder's.
    run(repo, 'checkout', '-qb', 'feature/x')
    execFileSync('mkdir', ['-p', join(repo, 'src')])
    const fromChild = await gitIdentity(join(repo, 'src'))
    expect(fromChild?.branch).toBe('feature/x')
    expect(fromChild?.root).toBe(identity?.root)
  })

  it('counts drift from the upstream in both directions', async () => {
    const origin = seedRepo('parley-gitid-origin-')
    const clone = mkdtempSync(join(tmpdir(), 'parley-gitid-clone-'))
    execFileSync('git', ['clone', '-q', origin, clone], { stdio: 'ignore' })
    run(clone, 'config', 'user.email', 'test@example.invalid')
    run(clone, 'config', 'user.name', 'Parley Test')

    // One commit ahead locally, one behind after the origin moves on.
    writeFileSync(join(clone, 'local.txt'), 'ahead\n')
    run(clone, 'add', '.')
    run(clone, 'commit', '-qm', 'local work')
    writeFileSync(join(origin, 'remote.txt'), 'behind\n')
    run(origin, 'add', '.')
    run(origin, 'commit', '-qm', 'remote work')
    run(clone, 'fetch', '-q')

    const identity = await gitIdentity(clone)
    expect(identity?.hasUpstream).toBe(true)
    expect(identity?.ahead).toBe(1)
    expect(identity?.behind).toBe(1)
  })

  it('answers null for a folder that is not a repository', async () => {
    expect(await gitIdentity(mkdtempSync(join(tmpdir(), 'parley-gitid-none-')))).toBeNull()
  })
})
