import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { validateNewWorkspacePath, WorkspacePathError } from './workspacePath'

/**
 * These refusals are the fence around a genuinely new capability: until the
 * workspace creator, Parley never made a file in a user directory that did
 * not already exist. Each case here is a way that could go wrong.
 */

function tmp(prefix = 'parley-wsp-'): string {
  return mkdtempSync(join(tmpdir(), prefix))
}

describe('where a new workspace may be created', () => {
  it('accepts a not-yet-existing folder inside an existing parent', () => {
    const parent = tmp()
    const target = join(parent, 'new-app')
    expect(validateNewWorkspacePath(target)).toBe(target)
  })

  it('accepts an empty folder — the user very likely just made it in the picker', () => {
    const parent = tmp()
    const target = join(parent, 'made-in-the-picker')
    mkdirSync(target)
    expect(validateNewWorkspacePath(target)).toBe(target)
  })

  it('refuses a folder with anything in it, and says where to go instead', () => {
    const parent = tmp()
    const target = join(parent, 'someones-work')
    mkdirSync(target)
    writeFileSync(join(target, 'notes.md'), 'mine\n')
    expect(() => validateNewWorkspacePath(target)).toThrow(/is not empty/)
    expect(() => validateNewWorkspacePath(target)).toThrow(/New plan instead/)
  })

  it('refuses an existing git repository even when it looks empty', () => {
    const parent = tmp()
    const target = join(parent, 'already-a-repo')
    mkdirSync(target)
    execFileSync('git', ['init', '-q'], { cwd: target, stdio: 'ignore' })
    // .git makes it non-empty, so the message is the not-empty one; either
    // refusal is correct, and both keep Parley out of an existing project.
    expect(() => validateNewWorkspacePath(target)).toThrow(WorkspacePathError)
  })

  it('refuses a file', () => {
    const parent = tmp()
    const target = join(parent, 'a-file.txt')
    writeFileSync(target, 'hello\n')
    expect(() => validateNewWorkspacePath(target)).toThrow(/is a file/)
  })

  it('refuses a parent that does not exist, so a typo cannot grow a tree', () => {
    const parent = tmp()
    const target = join(parent, 'missing', 'deeper', 'app')
    expect(() => validateNewWorkspacePath(target)).toThrow(/does not exist/)
  })

  it('refuses a relative path, an empty one, and the filesystem root', () => {
    expect(() => validateNewWorkspacePath('')).toThrow(/choose where/)
    expect(() => validateNewWorkspacePath('relative/app')).toThrow(/must be absolute/)
    expect(() => validateNewWorkspacePath('/')).toThrow(/filesystem root/)
  })

  it('refuses shell metacharacters, naming the tilde trap by example', () => {
    // An unexpanded ~ would otherwise create a literal folder called "~".
    expect(() => validateNewWorkspacePath('~/Projects/app')).toThrow(/must be absolute/)
    expect(() => validateNewWorkspacePath('/tmp/~/app')).toThrow(/will not pass to a command/)
    expect(() => validateNewWorkspacePath('/tmp/app;rm -rf /')).toThrow(
      /will not pass to a command/,
    )
  })

  it("refuses Parley's own record directory and its own checkout", () => {
    const userDataPath = tmp('parley-userdata-')
    const selfRepoPath = tmp('parley-self-')
    const limits = { userDataPath, selfRepoPath }

    expect(() => validateNewWorkspacePath(join(userDataPath, 'app'), limits)).toThrow(
      /own data directory/,
    )
    expect(() => validateNewWorkspacePath(join(selfRepoPath, 'app'), limits)).toThrow(
      /own checkout/,
    )
    // A sibling of either is fine — the rule is containment, not name-likeness.
    const sibling = join(tmp(), 'app')
    expect(validateNewWorkspacePath(sibling, limits)).toBe(sibling)
  })
})
