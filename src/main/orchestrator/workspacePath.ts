import { existsSync, readdirSync, statSync } from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'
import { isShellFree } from '@shared/command'

/**
 * Where a new workspace may be created.
 *
 * This is the deliberate inverse of `validateRepoPath`, which enforces "the
 * directory must already exist" — the load-bearing expression of a rule that
 * held until this feature: **Parley creates no file in a user directory that
 * did not already exist.** Scaffolding inverts it, so the refusals here are
 * the fence, and they are stricter than they strictly need to be:
 *
 *  - absolute, and shell-free (`~` is a metachar, and an unexpanded tilde
 *    would create a literal directory called `~` beside the app);
 *  - the PARENT must exist, so a typo cannot manufacture a tree of
 *    directories nobody asked for;
 *  - the target must not exist, or be an empty directory — never a
 *    populated one, and never a file;
 *  - never inside Parley's own userData, which is the app's record and not
 *    a place for projects;
 *  - never an existing git repository, even an empty-looking one — that is
 *    an existing project, and the flow for those is New plan.
 */

export class WorkspacePathError extends Error {}

export interface WorkspacePathLimits {
  /** Parley's own record directory; nothing may be scaffolded inside it. */
  userDataPath?: string | null
  /** The checkout Parley is running from, when in dev. */
  selfRepoPath?: string | null
}

function within(child: string, parent: string): boolean {
  const a = resolve(child)
  const b = resolve(parent)
  return a === b || a.startsWith(`${b}/`)
}

export function validateNewWorkspacePath(path: string, limits: WorkspacePathLimits = {}): string {
  const trimmed = path.trim()
  if (!trimmed) throw new WorkspacePathError('choose where the project should be created')
  if (!isAbsolute(trimmed)) {
    throw new WorkspacePathError('the project path must be absolute')
  }
  if (!isShellFree(trimmed)) {
    throw new WorkspacePathError(
      'the project path contains characters Parley will not pass to a command (including ~ — write the full path out)',
    )
  }

  const target = resolve(trimmed)
  const parent = resolve(target, '..')
  if (target === parent) {
    throw new WorkspacePathError('a project cannot be created at the filesystem root')
  }

  if (limits.userDataPath && within(target, limits.userDataPath)) {
    throw new WorkspacePathError(
      "that is inside Parley's own data directory, which holds the record rather than your projects",
    )
  }
  if (limits.selfRepoPath && within(target, limits.selfRepoPath)) {
    throw new WorkspacePathError("that is inside Parley's own checkout")
  }

  let parentStat
  try {
    parentStat = statSync(parent)
  } catch {
    throw new WorkspacePathError(`${parent} does not exist — choose a folder that does`)
  }
  if (!parentStat.isDirectory()) {
    throw new WorkspacePathError(`${parent} is not a folder`)
  }

  if (existsSync(target)) {
    let targetStat
    try {
      targetStat = statSync(target)
    } catch {
      throw new WorkspacePathError(`cannot read ${target}`)
    }
    if (!targetStat.isDirectory()) {
      throw new WorkspacePathError(`${target} is a file`)
    }
    // An empty directory is a fine place to start — the user very likely
    // made it in the folder picker a moment ago. Anything else is someone's
    // work, and this flow does not write into someone's work.
    const entries = readdirSync(target)
    if (entries.length > 0) {
      throw new WorkspacePathError(
        `${target} is not empty — a new project needs an empty folder, and an existing project starts from New plan instead`,
      )
    }
    if (existsSync(join(target, '.git'))) {
      throw new WorkspacePathError(`${target} is already a git repository`)
    }
  }

  return target
}
