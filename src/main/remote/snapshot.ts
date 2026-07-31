import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { capture } from '@main/util/spawn'
import { candidateRefFor, inputRefFor } from '@shared/remote'

/**
 * The immutable input snapshot.
 *
 * A remote run executes against a commit, never against "the branch" — a
 * branch is a name and names move. The snapshot captures what is actually
 * about to be executed: HEAD, plus staged changes, plus unstaged changes to
 * tracked files, plus untracked files that are not ignored. It is the tree the
 * pipeline would have seen if it ran here.
 *
 * The hard requirement is that building it CHANGES NOTHING. The user's HEAD,
 * index, branch and working tree must be byte-identical afterwards, whether
 * the snapshot succeeded or failed. That is why every operation here runs
 * against a temporary index file (`GIT_INDEX_FILE`) and why the commit is made
 * with `commit-tree` rather than `git commit`: no ref is written, no index is
 * touched, and the result is a dangling commit that exists only to be pushed.
 *
 * Ignored files are deliberately NOT transported. They are node_modules,
 * build output, local caches and `.env` — the first two the remote must
 * provision itself for the run to prove anything about the remote's
 * toolchain, and the last is a secret that should not travel to another
 * machine because a run happened to need a build. A remote that cannot
 * install its own dependencies is a remote that is not ready.
 */

const GIT_TIMEOUT_MS = 2 * 60 * 1000

export interface ExecutionSnapshot {
  /** The dangling commit holding the exact tree to execute. */
  commit: string
  /** The commit it descends from, or null in a repository with no commits. */
  base: string | null
  /** Untracked (non-ignored) paths swept in, so the record can say what went. */
  untracked: string[]
}

export interface SnapshotFailure {
  ok: false
  detail: string
}

export type SnapshotResult = ({ ok: true } & ExecutionSnapshot) | SnapshotFailure

interface GitResult {
  ok: boolean
  stdout: string
  stderr: string
}

async function git(
  args: string[],
  cwd: string,
  signal?: AbortSignal,
  env?: Record<string, string>,
): Promise<GitResult> {
  const result = await capture('git', args, cwd, GIT_TIMEOUT_MS, signal, { env })
  return { ok: result.exitCode === 0, stdout: result.stdout.trim(), stderr: result.stderr.trim() }
}

function failure(result: GitResult, what: string): SnapshotFailure {
  const detail = (result.stderr || result.stdout || 'no output').slice(0, 400)
  return { ok: false, detail: `${what}: ${detail}` }
}

/**
 * Builds the snapshot commit for a repository as it stands right now.
 *
 * The sequence is deliberate:
 *  - read-tree seeds a temp index from HEAD, so the snapshot starts from the
 *    committed state rather than from whatever the user has staged.
 *  - `add -A` then applies everything the working tree says: modifications,
 *    deletions, and untracked files, all filtered by .gitignore exactly as a
 *    normal commit would filter them.
 *  - write-tree turns that index into a tree object; commit-tree turns the
 *    tree into a commit whose parent is HEAD.
 *
 * The author identity is Parley's own, and the message says what the commit
 * is for. These commits are never part of user-visible history — they live
 * under refs/parley/runs and are deleted when the run settles — but a stray
 * one found later should explain itself.
 */
export async function createExecutionSnapshot(
  repoPath: string,
  runId: string,
  signal?: AbortSignal,
): Promise<SnapshotResult> {
  const refusal = await snapshotRefusal(repoPath, signal)
  if (refusal) return { ok: false, detail: refusal }

  const head = await git(['rev-parse', 'HEAD'], repoPath, signal)
  // A repository with no commits yet is legitimate — a workspace Parley just
  // scaffolded has one, but a plan can target a repo before its first commit.
  const base = head.ok && head.stdout ? head.stdout : null

  const indexDir = mkdtempSync(join(tmpdir(), 'parley-snap-'))
  const env = { ...process.env, GIT_INDEX_FILE: join(indexDir, 'index') } as Record<string, string>

  try {
    if (base) {
      const seeded = await git(['read-tree', base], repoPath, signal, env)
      if (!seeded.ok) return failure(seeded, 'could not read the current commit')
    }

    // -A stages modifications, additions and deletions; .gitignore still
    // applies, which is exactly the filter we want for transport.
    const staged = await git(['add', '-A'], repoPath, signal, env)
    if (!staged.ok) return failure(staged, 'could not stage the working tree')

    const tree = await git(['write-tree'], repoPath, signal, env)
    if (!tree.ok || !tree.stdout) return failure(tree, 'could not write the snapshot tree')

    const args = ['commit-tree', tree.stdout, '-m', `Parley execution snapshot for run ${runId}`]
    if (base) args.push('-p', base)
    const commit = await git(args, repoPath, signal, {
      ...env,
      GIT_AUTHOR_NAME: 'Parley',
      GIT_AUTHOR_EMAIL: 'parley@local',
      GIT_COMMITTER_NAME: 'Parley',
      GIT_COMMITTER_EMAIL: 'parley@local',
    })
    if (!commit.ok || !commit.stdout) return failure(commit, 'could not create the snapshot commit')

    return { ok: true, commit: commit.stdout, base, untracked: await untrackedIn(repoPath, signal) }
  } finally {
    // The temp index must go whatever happened; leaving it would not corrupt
    // anything (git never looks there again) but it would leak a file per run.
    rmSync(indexDir, { recursive: true, force: true })
  }
}

/**
 * Why this working tree cannot be snapshotted honestly, or null.
 *
 * Both refusals here are cases where the procedure would happily produce a
 * commit that is NOT the tree about to execute — which is worse than failing,
 * because everything downstream would treat it as one.
 */
export async function snapshotRefusal(
  repoPath: string,
  signal?: AbortSignal,
): Promise<string | null> {
  // Sparse checkout, measured rather than assumed: seeding a temp index from
  // HEAD reinstates every tracked path, including the ones sparse rules keep
  // OUT of the working tree, so the snapshot ends up containing files the
  // local run would never have seen. Transporting the sparse specification
  // would fix it properly; until then, refusing is the honest answer, because
  // the alternative is calling something an execution snapshot when it is not.
  const sparse = await git(['config', '--get', 'core.sparseCheckout'], repoPath, signal)
  if (sparse.ok && sparse.stdout.trim().toLowerCase() === 'true') {
    return 'this checkout is sparse, so a snapshot would carry files the local run never had — remote execution needs a full checkout'
  }

  // Submodules travel as the gitlink commit they point at, which is what git
  // records and is correct. What does NOT travel is anything uncommitted
  // inside one, or a gitlink moved to a commit that exists only on this
  // machine — either way the remote would build something this tree does not
  // contain, without anything looking wrong.
  //
  // Detection is deliberately empirical: `git submodule status` reports the
  // gitlink, and stays silent about a dirty working tree inside a submodule.
  // The superproject's own status is what notices that, which is why both are
  // consulted rather than the more obvious one alone.
  const listed = await git(['submodule', 'status', '--recursive'], repoPath, signal)
  if (listed.ok && listed.stdout) {
    const paths = listed.stdout
      .split('\n')
      .map((line) => line.trim().split(/\s+/)[1] ?? '')
      .filter(Boolean)
    if (paths.length > 0) {
      const status = await git(['status', '--porcelain'], repoPath, signal)
      // The status column is stripped by pattern rather than by a fixed
      // offset, because this stdout has been trimmed — which removes the
      // leading space of the first porcelain line and shifts exactly one entry
      // by one character. A slice(3) here silently missed the first modified
      // path and only the first.
      const modified = new Set(
        status.stdout
          .split('\n')
          .map((line) => line.replace(/^\s*[A-Z?! ]{1,2}\s+/, '').trim())
          .filter(Boolean),
      )
      const dirty = paths.filter((path) => modified.has(path))
      if (dirty.length > 0) {
        return `these submodules have changes a snapshot cannot carry: ${dirty.join(', ')} — commit and push inside each one first, so the remote can reach the commit this tree points at`
      }
    }
  }
  return null
}

/** Untracked, non-ignored paths — reported so the record can say what travelled. */
async function untrackedIn(repoPath: string, signal?: AbortSignal): Promise<string[]> {
  const result = await git(
    ['ls-files', '--others', '--exclude-standard'],
    repoPath,
    signal,
  )
  if (!result.ok || !result.stdout) return []
  return result.stdout.split('\n').filter((line) => line.length > 0)
}

/* ------------------------------------------------------------------ */
/* Moving states between machines                                      */
/* ------------------------------------------------------------------ */

/**
 * Pushes the snapshot to the target's bare mirror.
 *
 * The commit is pushed by object id, not by branch: `<sha>:<ref>` publishes
 * exactly the object we built and nothing that happens to be nearby. The
 * destination ref lives under refs/parley/runs so it can never be mistaken
 * for user history, and `--force` is safe here for the same reason it would
 * be alarming anywhere else — the ref is namespaced by a run id that has
 * never been used before.
 */
export async function pushSnapshot(
  repoPath: string,
  mirror: string,
  runId: string,
  commit: string,
  signal?: AbortSignal,
): Promise<{ ok: boolean; detail: string }> {
  const result = await git(
    ['push', '--force', mirror, `${commit}:${inputRefFor(runId)}`],
    repoPath,
    signal,
  )
  return { ok: result.ok, detail: result.ok ? '' : (result.stderr || result.stdout).slice(0, 400) }
}

/**
 * Brings a run's candidate commit back, without touching any local branch.
 *
 * Fetching a candidate is not accepting it. It is how the local side gets the
 * objects it needs in order to judge — ancestry, changed paths, evidence — and
 * every one of those checks runs after this, against objects we now hold.
 */
export async function fetchCandidate(
  repoPath: string,
  mirror: string,
  runId: string,
  signal?: AbortSignal,
): Promise<{ ok: boolean; commit: string | null; detail: string }> {
  const ref = candidateRefFor(runId)
  const fetched = await git(['fetch', '--force', mirror, `${ref}:${ref}`], repoPath, signal)
  if (!fetched.ok) {
    return { ok: false, commit: null, detail: (fetched.stderr || fetched.stdout).slice(0, 400) }
  }
  const resolved = await git(['rev-parse', ref], repoPath, signal)
  if (!resolved.ok || !resolved.stdout) {
    return { ok: false, commit: null, detail: 'the candidate ref did not resolve after fetching' }
  }
  return { ok: true, commit: resolved.stdout, detail: '' }
}

/**
 * Whether the result actually descends from what we submitted.
 *
 * The guard that makes importing safe: a result commit that is not a
 * descendant of the snapshot was built from something other than the tree we
 * sent, and applying it would silently replace work. Checked locally, against
 * objects we hold, so a helper cannot talk its way past it.
 */
export async function descendsFrom(
  repoPath: string,
  ancestor: string,
  descendant: string,
  signal?: AbortSignal,
): Promise<boolean> {
  const result = await git(
    ['merge-base', '--is-ancestor', ancestor, descendant],
    repoPath,
    signal,
  )
  return result.ok
}

/**
 * Removes a settled run's refs from the local repository.
 *
 * Deliberately best-effort and never fatal: a leftover ref under
 * refs/parley/runs costs nothing, is invisible in normal git use, and is not
 * worth failing a completed run over. The remote mirror's refs are the
 * helper's to clean.
 */
export async function deleteRunRefs(
  repoPath: string,
  runId: string,
  signal?: AbortSignal,
): Promise<void> {
  for (const ref of [inputRefFor(runId), candidateRefFor(runId)]) {
    await git(['update-ref', '-d', ref], repoPath, signal)
  }
}
