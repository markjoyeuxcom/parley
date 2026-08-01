import type { Milestone, WorkPlan } from '@shared/domain'
import {
  candidateRefFor,
  inputRefFor,
  REMOTE_PROTOCOL_VERSION,
  type RemoteCapabilities,
  type RemoteEvidenceManifest,
  type RemoteFrame,
  type RemoteRequest,
  type RemoteTarget,
} from '@shared/remote'
import type { MilestoneReporter } from '@main/orchestrator/reporter'
import { targetRefusal } from './protocol'
import { milestoneFingerprint, RemoteReplay, verifyCandidate } from './replay'
import {
  createExecutionSnapshot,
  deleteRunRefs,
  fetchCandidate,
  pushSnapshot,
} from './snapshot'

/**
 * Running one milestone somewhere else, from this side.
 *
 * The sequence is forced by things that cannot be reordered: a snapshot must
 * exist before it can be pushed, it must be pushed before a run can be asked
 * for, and the host must have somewhere to be pushed INTO before either.
 * Hence a `prepare` conversation first — deriving the mirror path locally and
 * hoping would be guessing about someone else's filesystem.
 *
 * The approval is consumed on `ready`, and that placement is the one real
 * judgement here. Locally it is consumed at run entry, before the spend. Out
 * here the spend happens on another machine, and everything before `ready` —
 * building a snapshot, pushing it, reaching the host at all — can fail without
 * anything having been spent. Consuming at entry would burn a single-use
 * approval on a transport failure and make the user grant a fresh one to
 * retry something that never ran. `ready` is the first moment the remote can
 * spend, so it is the honest moment to charge for the attempt.
 */

export type RemoteRunOutcome =
  | { kind: 'accepted'; commit: string; changedPaths: string[]; milestone: Milestone }
  /** The run ended and the record says why. Nothing to import. */
  | { kind: 'ended'; detail: string }
  /** Nothing ran, and nothing was spent. Safe to retry as-is. */
  | { kind: 'unstarted'; detail: string }
  /**
   * The wire died after the run began. The work may have finished, so the
   * recovery is to look for its candidate, never to run it again.
   */
  | { kind: 'disconnected'; detail: string }
  | { kind: 'rejected'; detail: string }

export interface RemoteDriverDeps {
  /** One ssh conversation. Injected so the driver is testable without a host. */
  converse: (
    target: Pick<RemoteTarget, 'host'>,
    request: RemoteRequest,
    onFrame: (frame: RemoteFrame) => void,
  ) => Promise<{ kind: 'closed' | 'refused' | 'protocol' | 'violation' | 'disconnected' | 'cancelled'; detail: string }>
  /** Consumes the single-use approval. Throws if it is already spent. */
  consumeApproval: () => void
  /** Where the run's facts land. */
  reporter: MilestoneReporter
  /** Re-read for the fingerprint check, so a local change is noticed. */
  currentMilestone: () => Milestone | null
  changedPathsIn: (repoPath: string, from: string, to: string) => Promise<string[]>
  onProgress?: (phase: string, text: string) => void
  /**
   * How git should address the host's mirror. One place builds this, so there
   * is one place to look when a push cannot find its way there — and one seam
   * for tests, which have a mirror on the local disk rather than behind ssh.
   */
  remoteUrlFor?: (target: Pick<RemoteTarget, 'host'>, mirror: string) => string
  /**
   * The snapshot is on the host and a run is about to begin.
   *
   * The moment the run becomes RECOVERABLE, and the last moment it is still
   * free: nothing is spent until `ready`. Whoever holds the record writes
   * down enough here to come back for a candidate later, because after this
   * point a dead connection can hide a run that finished, and every value
   * needed to go looking is a local variable that vanishes with the call.
   */
  onSubmitted?: (submitted: { commit: string; mirror: string; url: string }) => void
}

export interface RemoteRunInput {
  runId: string
  target: RemoteTarget
  /** Stable key for this repository's mirror on the host. */
  repoKey: string
  plan: WorkPlan
  milestone: Milestone
}

export async function driveRemoteMilestone(
  input: RemoteRunInput,
  deps: RemoteDriverDeps,
): Promise<RemoteRunOutcome> {
  const { runId, target, plan, milestone } = input
  const progress = deps.onProgress ?? ((): void => {})

  // ── Somewhere to push to ─────────────────────────────────────────────────
  let mirror: string | null = null
  let capabilities: RemoteCapabilities | null = null
  const prepare = await deps.converse(
    target,
    {
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'prepare',
      runId,
      repository: { remote: input.repoKey, inputRef: inputRefFor(runId), expectedCommit: '' },
    },
    (frame) => {
      if (frame.body.type === 'ready') capabilities = frame.body.capabilities
      if (frame.body.type === 'prepared') mirror = frame.body.mirror
    },
  )
  if (prepare.kind !== 'closed' || !mirror || !capabilities) {
    return { kind: 'unstarted', detail: prepare.detail || 'the host did not prepare a mirror' }
  }

  // Checked before a snapshot is built and long before anything is spent: a
  // host that cannot run this plan's executor is knowable now.
  const refusal = targetRefusal(capabilities, [plan.executor.vendor, plan.reviewer.vendor])
  if (refusal) return { kind: 'unstarted', detail: refusal }

  // ── The immutable input ──────────────────────────────────────────────────
  progress('executing', `snapshotting ${plan.repoPath}`)
  const snapshot = await createExecutionSnapshot(plan.repoPath, runId)
  if (!snapshot.ok) return { kind: 'unstarted', detail: snapshot.detail }

  const url = deps.remoteUrlFor ?? ((to, at): string => `ssh://${to.host}${at}`)
  const remoteUrl = url(target, mirror)
  const pushed = await pushSnapshot(plan.repoPath, remoteUrl, runId, snapshot.commit)
  if (!pushed.ok) return { kind: 'unstarted', detail: pushed.detail }
  deps.onSubmitted?.({ commit: snapshot.commit, mirror, url: remoteUrl })

  // ── The run ──────────────────────────────────────────────────────────────
  const fingerprint = milestoneFingerprint(milestone)
  const replay = new RemoteReplay(deps.reporter, fingerprint, deps.currentMilestone)
  let manifest: RemoteEvidenceManifest | null = null
  let charged = false
  let replayRefusal: string | null = null
  let remoteError: string | null = null

  const conversation = await deps.converse(
    target,
    {
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'run',
      runId,
      repository: {
        remote: input.repoKey,
        inputRef: inputRefFor(runId),
        expectedCommit: snapshot.commit,
      },
      run: {
        context: {
          milestoneId: milestone.id,
          planId: plan.id,
          status: milestone.status,
          checkpoint: null,
          narrative: milestone.reviewNote,
          verification: milestone.testResult,
          recordVersion: 0,
        },
        plan,
        milestone,
      },
    },
    (frame) => {
      if (frame.body.type === 'ready' && !charged) {
        // The first moment the remote can spend anything. Everything before
        // this could fail without costing the user a granted approval.
        deps.consumeApproval()
        charged = true
      }
      // Through the reporter, so remote narrative is journalled exactly as
      // local narrative is. Routing it straight to the renderer would have
      // left a remote run's story thinner than a local one's for no reason
      // anybody could see afterwards.
      if (frame.body.type === 'progress') {
        deps.reporter.activity(frame.body.phase, frame.body.text)
        progress(frame.body.phase, frame.body.text)
      }
      if (frame.body.type === 'error') remoteError = frame.body.message
      if (frame.body.type === 'result') manifest = frame.body.manifest

      // EVERY frame goes to the replay, including the ones it will not record.
      // Sequence numbers belong to the conversation, so a replay that only saw
      // facts would read the first of them as a gap — which is exactly what
      // happened when this handler returned early for a `ready`.
      const refused = replay.apply(frame)
      if (refused && !replayRefusal) replayRefusal = refused.detail
    },
  )

  if (replayRefusal) return { kind: 'rejected', detail: replayRefusal }
  if (conversation.kind === 'disconnected' || conversation.kind === 'violation') {
    return { kind: 'disconnected', detail: conversation.detail }
  }
  if (!charged) {
    // Never reached ready: nothing over there could have spent anything, and
    // the approval is still good for a retry.
    return { kind: 'unstarted', detail: conversation.detail || 'the host never announced itself' }
  }
  if (!manifest) {
    return { kind: 'ended', detail: remoteError ?? 'the run ended without producing a result' }
  }

  // ── What came back ───────────────────────────────────────────────────────
  const fetched = await fetchCandidate(plan.repoPath, remoteUrl, runId)
  if (!fetched.ok || !fetched.commit) {
    // The remote said it published; we cannot see it. Not a failure of the
    // work, so the run is not re-run on the strength of this.
    return { kind: 'disconnected', detail: fetched.detail || 'the candidate could not be fetched' }
  }

  const verdict = await verifyCandidate(
    plan.repoPath,
    snapshot.commit,
    fetched.commit,
    manifest,
    deps.changedPathsIn,
  )
  if (!verdict.ok) return { kind: 'rejected', detail: verdict.detail }

  await deleteRunRefs(plan.repoPath, runId)
  return {
    kind: 'accepted',
    commit: verdict.commit,
    changedPaths: verdict.changedPaths,
    milestone: deps.reporter.milestone,
  }
}

/** The refs a settled run leaves behind locally. Best effort, never fatal. */
export async function forgetRun(repoPath: string, runId: string): Promise<void> {
  await deleteRunRefs(repoPath, runId)
}

export { candidateRefFor }
