import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { workingDiff } from './workingDiff'

/**
 * Against real repositories, because the whole function is git's answers.
 * Mocking `capture` here would test the shape of strings I made up.
 */

const made: string[] = []

function repo(): string {
  const dir = mkdtempSync(join(tmpdir(), 'parley-diff-'))
  made.push(dir)
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: dir, stdio: 'ignore' })
  }
  git('init', '-b', 'main')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test')
  writeFileSync(join(dir, 'tracked.txt'), 'one\n')
  git('add', '.')
  git('commit', '-m', 'first')
  return dir
}

afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

describe('reading uncommitted work', () => {
  it('is null when the folder is not a repository', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'parley-nogit-'))
    made.push(dir)
    // Not an error the user has to dismiss — the caller shows nothing.
    expect(await workingDiff(dir)).toBeNull()
  })

  it('is empty, not null, for a clean repository', async () => {
    const work = await workingDiff(repo())
    expect(work).not.toBeNull()
    expect(work?.diff.trim()).toBe('')
    expect(work?.untracked).toEqual([])
    expect(work?.branch).toBe('main')
  })

  it('reports unstaged edits', async () => {
    const dir = repo()
    writeFileSync(join(dir, 'tracked.txt'), 'two\n')

    const work = await workingDiff(dir)
    expect(work?.diff).toContain('-one')
    expect(work?.diff).toContain('+two')
  })

  it('includes staged work, which is still unreviewed', async () => {
    // `git diff` alone would miss this. An agent that staged its edits has not
    // had them reviewed.
    const dir = repo()
    writeFileSync(join(dir, 'tracked.txt'), 'staged\n')
    execFileSync('git', ['add', '.'], { cwd: dir, stdio: 'ignore' })

    const work = await workingDiff(dir)
    expect(work?.diff).toContain('+staged')
  })

  it('names untracked files rather than including them', async () => {
    const dir = repo()
    writeFileSync(join(dir, 'brand-new.ts'), 'export const x = 1\n')

    const work = await workingDiff(dir)
    expect(work?.untracked).toEqual(['brand-new.ts'])
    // The content stays out; the name is what lets a reviewer ask for it.
    expect(work?.diff).not.toContain('export const x')
  })

  it('respects .gitignore rather than offering build output for review', async () => {
    const dir = repo()
    writeFileSync(join(dir, '.gitignore'), 'noise/\n')
    execFileSync('git', ['add', '.gitignore'], { cwd: dir, stdio: 'ignore' })
    execFileSync('git', ['commit', '-m', 'ignore'], { cwd: dir, stdio: 'ignore' })
    execFileSync('mkdir', [join(dir, 'noise')])
    writeFileSync(join(dir, 'noise', 'out.js'), 'junk\n')

    const work = await workingDiff(dir)
    expect(work?.untracked).toEqual([])
  })

  it('truncates a diff too large to send, and says so', async () => {
    const dir = repo()
    // Comfortably past the 60,000-character limit.
    writeFileSync(join(dir, 'tracked.txt'), Array.from({ length: 9000 }, (_, i) => `line ${i}`).join('\n'))

    const work = await workingDiff(dir)
    expect(work?.truncated).toBe(true)
    expect(work?.diff.length).toBeLessThanOrEqual(60_000)
  })
})
