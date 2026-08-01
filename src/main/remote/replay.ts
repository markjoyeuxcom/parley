import { createHash } from 'node:crypto'
import type { Milestone } from '@shared/domain'
import type { RemoteEvidenceManifest, RemoteFrame } from '@shared/remote'
import type { RunActor } from '@shared/journal'
import { decodeMilestoneFact, type MilestoneReporter } from '@main/orchestrator/reporter'
import { descendsFrom } from './snapshot'
import { FrameSequencer } from './frames'

/**
 * Turning what a remote run reported into what this machine records.
 *
 * Nothing a remote says is applied on its say-so. A fact is decoded and
 * validated before it can touch a row, frames are applied in order and once
 * each, and the milestone it claims to describe has to still be the milestone
 * that was submitted. The remote is trusted to do the work; it is not trusted
 * to be the only thing that happened here while it was working.
 */

/**
 * A fingerprint of the milestone as it was submitted.
 *
 * Cheaper and more honest than a version column: it is derived from the fields
 * a run is entitled to change, so it answers exactly the question that matters
 * — has anything else moved this row since we handed it out? A human who
 * stopped the run, an adopt that landed, a re-draft: all of them change this,
 * and all of them mean the remote is reporting truthfully about a state that
 * no longer exists.
 */
export function milestoneFingerprint(milestone: Milestone): string {
  return createHash('sha256')
    .update(
      JSON.stringify({
        id: milestone.id,
        status: milestone.status,
        reviewPassed: milestone.reviewPassed,
        completedAt: milestone.completedAt,
        testResult: milestone.testResult,
        reviewNote: milestone.reviewNote,
      }),
    )
    .digest('hex')
}

export type ReplayRefusal =
  | { kind: 'moved'; detail: string }
  | { kind: 'gap'; detail: string }
  | { kind: 'unreadable'; detail: string }

export interface ReplayResult {
  applied: number
  /** Frames that were already applied — expected, and not an error. */
  duplicates: number
  refusal: ReplayRefusal | null
}

/**
 * Applies a run's frames to the local record.
 *
 * The fingerprint is checked ONCE, before the first fact lands. After that
 * this replay is itself what moves the row, so re-checking would compare
 * against our own writes and refuse everything.
 */
export class RemoteReplay {
  private readonly sequencer = new FrameSequencer()
  private started = false
  private applied = 0
  private duplicates = 0

  constructor(
    private readonly reporter: MilestoneReporter,
    private readonly submittedFingerprint: string,
    private readonly currentMilestone: () => Milestone | null,
  ) {}

  apply(frame: RemoteFrame): ReplayRefusal | null {
    // EVERY frame is admitted, not just the ones carrying facts. Sequence
    // numbers belong to the conversation — a `ready` or a progress line uses
    // one too — so a sequencer that only saw facts would read the first of
    // them as a gap and refuse a perfectly ordered run.
    const admission = this.sequencer.admit(frame)
    if (admission.kind === 'duplicate') {
      if (frame.body.type === 'fact') this.duplicates += 1
      return null
    }
    if (admission.kind === 'gap') {
      return {
        kind: 'gap',
        detail: `the remote skipped frame ${admission.expected}, so the record would have a hole in it`,
      }
    }

    if (frame.body.type !== 'fact') return null

    if (!this.started) {
      const now = this.currentMilestone()
      if (!now) {
        return { kind: 'moved', detail: 'the milestone this run reported on no longer exists' }
      }
      if (milestoneFingerprint(now) !== this.submittedFingerprint) {
        // Truthful about a state that is gone. Writing it anyway would put a
        // remote's honest report onto a row somebody else has since changed.
        return {
          kind: 'moved',
          detail:
            'this milestone changed locally while the remote run was in flight — its report describes a state that no longer exists, so nothing was applied',
        }
      }
      this.started = true
    }

    const fact = decodeMilestoneFact(frame.body.fact)
    if (!fact) {
      return { kind: 'unreadable', detail: 'the remote reported a fact this Parley cannot read' }
    }
    // The remote's attribution, when it sent one. It knows which agent
    // actually ran; deriving it here would put this side's idea of the roles
    // onto work it did not watch.
    const actor = frame.body.actor
    this.reporter.record(
      fact,
      actor
        ? {
            kind: actor.kind as RunActor['kind'],
            vendor: actor.vendor,
            profile: actor.profile,
            targetId: actor.targetId,
          }
        : undefined,
    )
    this.applied += 1
    return null
  }

  get result(): ReplayResult {
    return { applied: this.applied, duplicates: this.duplicates, refusal: null }
  }
}

/* ------------------------------------------------------------------ */
/* Accepting what came back                                            */
/* ------------------------------------------------------------------ */

export type CandidateVerdict =
  | { ok: true; commit: string; changedPaths: string[] }
  | { ok: false; detail: string }

/**
 * Whether a fetched candidate may be applied.
 *
 * Both checks run here, against objects this machine now holds, because the
 * whole point of a candidate is that the remote's word for it is not enough.
 *
 * Ancestry is the load-bearing one: a commit that does not descend from the
 * snapshot we submitted was built from something else, and applying it would
 * silently replace work rather than add to it.
 *
 * The changed-path reconciliation is the cheap second opinion. The remote
 * reported what it believed it changed; git is asked independently, and a
 * disagreement means one of them is wrong about what is in the commit — which
 * is worth refusing over even though neither answer is obviously the liar.
 */
export async function verifyCandidate(
  repoPath: string,
  submittedCommit: string,
  candidateCommit: string,
  manifest: RemoteEvidenceManifest,
  changedPathsIn: (repoPath: string, from: string, to: string) => Promise<string[]>,
): Promise<CandidateVerdict> {
  if (manifest.baseCommit !== submittedCommit) {
    return {
      ok: false,
      detail: `the result says it was built on ${manifest.baseCommit.slice(0, 12)}, but ${submittedCommit.slice(0, 12)} was submitted`,
    }
  }

  if (!(await descendsFrom(repoPath, submittedCommit, candidateCommit))) {
    return {
      ok: false,
      detail: `${candidateCommit.slice(0, 12)} does not descend from the submitted snapshot — it was built from something else`,
    }
  }

  const observed = await changedPathsIn(repoPath, submittedCommit, candidateCommit)
  const claimed = new Set(manifest.changedPaths)
  const unexpected = observed.filter((path) => !claimed.has(path))
  const missing = manifest.changedPaths.filter((path) => !observed.includes(path))
  if (unexpected.length > 0 || missing.length > 0) {
    const parts: string[] = []
    if (unexpected.length > 0) parts.push(`changed but not reported: ${unexpected.join(', ')}`)
    if (missing.length > 0) parts.push(`reported but not changed: ${missing.join(', ')}`)
    return {
      ok: false,
      detail: `the result and its evidence disagree about what changed (${parts.join('; ')})`,
    }
  }

  return { ok: true, commit: candidateCommit, changedPaths: observed }
}
