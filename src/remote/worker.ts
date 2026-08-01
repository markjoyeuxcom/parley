import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { Milestone, WorkPlan } from '@shared/domain'
import { candidateRefFor, inputRefFor, type RemoteEvidenceManifest } from '@shared/remote'
import { AgentRegistry } from '@main/agents'
import { executeMilestone } from '@main/orchestrator/execution'
import { freshRunState, readTree, revParseHead } from '@main/orchestrator/evidence'
import { FramingMilestoneReporter } from './reporter'
import { git, prepareRunWorktree, removeRunWorktree } from './worktree'

/**
 * The process that actually runs a milestone on this host.
 *
 * It leads its own process group, so the agents and test commands it spawns
 * are descendants the supervisor can signal as one. It writes JSON bodies on
 * stdout; the supervisor numbers and frames them. It removes nothing and
 * publishes nothing on its own authority — cleanup belongs to the supervisor,
 * which outlives it, and the ref it writes is a candidate that carries no
 * weight until the local side has verified it.
 */

/**
 * How a run ended, stated explicitly.
 *
 * A function that returned without throwing is not the same as a milestone
 * that completed, and conflating them is how "the tree that happened to exist
 * when the code stopped" becomes a published result. Only `completed` may
 * reach candidate publication; a refusal that legitimately ends a milestone
 * record — an unchanged tree, a failed review — is an ending, not a success.
 */
export type ExecutionResult =
  | { status: 'completed'; milestone: Milestone }
  | { status: 'refused'; reason: string; milestone: Milestone }
  | { status: 'failed'; error: string }
  | { status: 'cancelled' }

export interface WorkerRequest {
  runId: string
  mirrorDir: string
  runsRoot: string
  expectedCommit: string
  plan: WorkPlan
  milestone: Milestone
}

export interface WorkerOutcome {
  result: ExecutionResult
  manifest: RemoteEvidenceManifest | null
}

/**
 * Runs one milestone and, only if it completed, publishes what it built.
 *
 * The commit is made here rather than left to the caller because the tree only
 * exists here; the ref it lands on is namespaced by run id and called a
 * candidate, because a connection can die between publishing it and the local
 * side learning it exists.
 */
export async function runWorker(
  request: WorkerRequest,
  write: (body: unknown) => void,
  signal?: AbortSignal,
): Promise<WorkerOutcome> {
  const prepared = await prepareRunWorktree({
    mirrorDir: request.mirrorDir,
    runsRoot: request.runsRoot,
    runId: request.runId,
    expectedCommit: request.expectedCommit,
    inputRef: inputRefFor(request.runId),
    signal,
  })
  if (!prepared.ok || !prepared.path) {
    return { result: { status: 'failed', error: prepared.detail }, manifest: null }
  }
  const root = prepared.path

  // The baseline the containment guards compare against, captured here where
  // the tree is — exactly as the local facade captures it before a local run.
  const before = await readTree(root, signal)
  const baselineHead = await revParseHead(root, signal)

  const reporter = new FramingMilestoneReporter(request.milestone, write, {
    executor: request.plan.executor.vendor,
    reviewer: request.plan.reviewer.vendor,
    // Stamped on the config at pick time precisely so this machine, which
    // holds no record of profiles, can still attribute work to one.
    executorProfile: request.plan.executor.profile,
    reviewerProfile: request.plan.reviewer.profile,
  })
  const registry = new AgentRegistry(request.plan.mock)

  let milestone: Milestone
  try {
    milestone = await executeMilestone(
      {
        milestoneId: request.milestone.id,
        milestone: request.milestone,
        // The plan travels with repoPath rewritten to where the tree actually
        // is. Everything downstream resolves paths against it, and a plan that
        // still named the user's machine would send every read somewhere that
        // does not exist here.
        plan: { ...request.plan, repoPath: root },
        worktree: null,
        root,
        activity: (phase, text) => reporter.activity(phase, text),
        runState: freshRunState(before, baselineHead),
        history: [],
        enterAtVerify: false,
        resumedRound: null,
        seedTestResult: null,
      },
      {
        reporter,
        agents: registry,
        devcontainerBinary: undefined,
        selfRepoPath: null,
      },
    )
  } catch (error) {
    return {
      result: { status: 'failed', error: error instanceof Error ? error.message : String(error) },
      manifest: null,
    }
  }

  if (signal?.aborted) return { result: { status: 'cancelled' }, manifest: null }

  if (milestone.status !== 'complete') {
    // An ending, and a real one — the record says so. It is simply not a
    // result, so nothing is published and there is no tree to import.
    return {
      result: {
        status: 'refused',
        reason: milestone.reviewNote.slice(0, 400) || 'the milestone did not complete',
        milestone,
      },
      manifest: null,
    }
  }

  const published = await publishCandidate(request, root, signal)
  if (!published.ok) {
    return { result: { status: 'failed', error: published.detail }, manifest: null }
  }
  return { result: { status: 'completed', milestone }, manifest: published.manifest }
}

/** Commits whatever the milestone left and puts it at the run's candidate ref. */
async function publishCandidate(
  request: WorkerRequest,
  root: string,
  signal?: AbortSignal,
): Promise<{ ok: true; manifest: RemoteEvidenceManifest } | { ok: false; detail: string }> {
  const identity = {
    GIT_AUTHOR_NAME: 'Parley',
    GIT_AUTHOR_EMAIL: 'parley@local',
    GIT_COMMITTER_NAME: 'Parley',
    GIT_COMMITTER_EMAIL: 'parley@local',
  }

  const staged = await git(['add', '-A'], root, identity, signal)
  if (!staged.ok) return { ok: false, detail: staged.stderr || 'could not stage the result' }

  // What changed, taken from git rather than from anything the run reported
  // about itself. The local side re-derives this independently from the
  // fetched commit, and the two must agree.
  const changed = await git(['diff', '--cached', '--name-only'], root, identity, signal)
  const changedPaths = changed.stdout.split('\n').filter((line) => line.length > 0)

  const committed = await git(
    ['commit', '--allow-empty', '-m', `Parley run ${request.runId}`],
    root,
    identity,
    signal,
  )
  if (!committed.ok) return { ok: false, detail: committed.stderr || 'could not commit the result' }

  const head = await git(['rev-parse', 'HEAD'], root, identity, signal)
  if (!head.ok || !head.stdout) return { ok: false, detail: 'the result commit did not resolve' }

  // Into the mirror the local side fetches from, by object id, under the run's
  // own namespace so it can never be mistaken for history.
  const pushed = await git(
    ['update-ref', candidateRefFor(request.runId), head.stdout],
    request.mirrorDir,
    identity,
    signal,
  )
  if (!pushed.ok) return { ok: false, detail: pushed.stderr || 'could not publish the candidate' }

  return {
    ok: true,
    manifest: {
      resultCommit: head.stdout,
      baseCommit: request.expectedCommit,
      changedPaths,
      artifactsPath: existsSync(join(root, '.parley')) ? join(root, '.parley') : null,
    },
  }
}

/** Removes a run's worktree. Called by the SUPERVISOR, never by this process. */
export async function cleanupRun(
  mirrorDir: string,
  runsRoot: string,
  runId: string,
): Promise<void> {
  await removeRunWorktree(mirrorDir, join(runsRoot, runId))
}
