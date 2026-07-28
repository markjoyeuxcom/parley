import type { Hold, HoldKind } from '@shared/holds'
import { HOLD_CLASS, holdIdentity, STALL_AFTER_MS } from '@shared/holds'
import type { BacklogItem, Loop, Milestone, WorkPlan, Worktree } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import { EXECUTABLE_PAIRS } from '@shared/execution'
import type { Repo } from '@main/store/repo'
import { unresolvedBlockingOccurrences } from './gate'

/**
 * Derives the open decision holds from state that already exists.
 *
 * This is a pure read: plans, milestones, loops and the finding ledger are the
 * only inputs, and nothing here is persisted. The one write-shaped input is
 * `acked` — the set of hold identities a human has acknowledged — which clears
 * notice-class holds only. Decision-class holds ignore acks even if one is
 * present, so a stray ack row can never hide work that is genuinely parked.
 *
 * Sessions are bounded by the same limit the app's own lists use; an archived
 * session's waiting states are deliberately invisible — archiving is the
 * user's statement that this record no longer needs attention.
 */
const SESSION_LIMIT = 200

export function computeHolds(repo: Repo, acked: ReadonlySet<string>, now = Date.now()): Hold[] {
  const holds: Hold[] = []

  for (const session of repo.listSessions(SESSION_LIMIT, false)) {
    const plans = repo.listPlansForSession(session.id)
    if (!plans.length) continue

    // The gate is session-wide and costs two ledger reads, so compute it once
    // per session, and only for sessions that turn out to need it.
    let gateSize: number | null = null
    const openBlockers = (): number =>
      (gateSize ??= unresolvedBlockingOccurrences(repo, session.id).length)

    for (const plan of plans) {
      if (plan.status === 'awaiting-clarification') {
        holds.push(clarificationHold(session.id, plan))
      } else if (plan.status === 'blocked') {
        holds.push(planBlockedHold(session.id, plan))
      }

      // A complete worktree plan waits on exactly one more human act: landing
      // its branch. Ready when git can fast-forward; blocked (with the branch
      // named, since the commits survive) when a landing attempt was refused
      // or the worktree lost its footing on disk. A *landed* row surfaces only
      // in one case — the post-land smoke verification failed — the single
      // exception to landed rows being done.
      if (plan.status === 'complete' && plan.isolation === 'worktree') {
        const worktree = repo.getWorktreeForPlan(plan.id)
        if (worktree && worktree.landedAt === null) {
          holds.push(mergeHold(session.id, plan, worktree))
        } else if (worktree && worktree.landedAt !== null && worktree.lastError) {
          holds.push(landVerifyFailedHold(session.id, plan, worktree))
        }
      }

      // Stalls are checked before the executable-pair continue below: a
      // running plan is exactly what that line skips, and running is the only
      // status a stall can happen in. The stamp is written by the watchdog on
      // real activity only, so a silent run's stamp freezes naturally — which
      // is what makes the identity stable for the notify-once machinery.
      if (plan.status === 'running') {
        for (const milestone of repo.listMilestones(plan.id)) {
          const inFlight = ['executing', 'testing', 'reviewing'].includes(milestone.status)
          const stamp = milestone.runState?.lastActivityAt ?? null
          if (inFlight && stamp !== null && now - stamp > STALL_AFTER_MS) {
            holds.push(milestoneStallHold(session.id, plan, milestone, stamp))
          }
        }
      }

      // Only these two plan statuses appear in EXECUTABLE_PAIRS, so no other
      // plan can have an approvable or retryable milestone.
      if (plan.status !== 'ready' && plan.status !== 'failed') continue

      const milestones = repo.listMilestones(plan.id)

      // Every retryable failure is its own notice hold. A failed milestone is
      // deliberately never *also* the approval hold — retry and adopt live on
      // the failure, and emitting both would put the same decision in the
      // queue twice.
      for (const milestone of milestones) {
        if (milestone.status === 'failed' && pairExecutable(plan, milestone)) {
          holds.push(milestoneFailedHold(session.id, plan, milestone))
        }
      }

      const approvable = milestones.find(
        (milestone) =>
          (milestone.status === 'audited' || milestone.status === 'approved') &&
          pairExecutable(plan, milestone),
      )
      if (approvable) {
        holds.push(approvalHold(session.id, plan, approvable, openBlockers()))
      }
    }
  }

  for (const loop of repo.listLoops()) {
    if (loop.status === 'exhausted' || loop.status === 'failed' || loop.status === 'killed') {
      holds.push(loopHold(loop))
    } else if (
      loop.status === 'running' &&
      loop.lastActivityAt != null &&
      now - loop.lastActivityAt > STALL_AFTER_MS
    ) {
      holds.push(loopStallHold(loop, loop.lastActivityAt))
    }
  }

  // One hold per repository whose backlog carries proposals — stow drafts
  // waiting to be confirmed or discarded, completions waiting to be closed or
  // reopened. Iterated independently of the session loop above: proposals
  // outlive and cross-cut the sessions that produced them.
  for (const repoPath of repo.distinctBacklogRepos()) {
    const pending = repo.listBacklogItems({
      repoPath,
      states: ['proposed', 'closure-proposed'],
    })
    if (pending.length) holds.push(backlogReviewHold(repoPath, pending))
  }

  const open = holds.filter((hold) => !(HOLD_CLASS[hold.kind] === 'notice' && acked.has(hold.id)))

  // Decisions before notices; within a class, the longest-waiting first. The
  // id tiebreak keeps the order stable across recomputes.
  return open.sort((a, b) => {
    if (a.actionable !== b.actionable) return a.actionable ? -1 : 1
    if (a.sinceAt !== b.sinceAt) return a.sinceAt - b.sinceAt
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  })
}

function pairExecutable(plan: WorkPlan, milestone: Milestone): boolean {
  return EXECUTABLE_PAIRS.some(
    ([planStatus, milestoneStatus]) =>
      plan.status === planStatus && milestone.status === milestoneStatus,
  )
}

function hold(
  kind: HoldKind,
  subjectId: string,
  generation: string,
  fields: Omit<Hold, 'id' | 'kind' | 'actionable' | 'repoPath'> & { repoPath?: string | null },
): Hold {
  return {
    id: holdIdentity(kind, subjectId, generation),
    kind,
    actionable: HOLD_CLASS[kind] === 'decision',
    repoPath: null,
    ...fields,
  }
}

function clarificationHold(sessionId: string, plan: WorkPlan): Hold {
  // The question is the generation: a different question after resume is new
  // waiting, not the old hold re-observed.
  return hold('clarification', plan.id, plan.question, {
    sessionId,
    planId: plan.id,
    milestoneId: null,
    loopId: null,
    title: 'Waiting on your answer',
    detail: plan.question,
    sinceAt: plan.createdAt,
    mock: plan.mock,
  })
}

function planBlockedHold(sessionId: string, plan: WorkPlan): Hold {
  // The park reason is appended to the correction note as its own paragraph.
  const reason =
    plan.correctionNote.split('\n\n').filter(Boolean).pop() ??
    'The plan needs attention before it can be approved.'
  return hold('plan-blocked', plan.id, plan.correctionNote, {
    sessionId,
    planId: plan.id,
    milestoneId: null,
    loopId: null,
    title: 'Blocked before approval',
    detail: `${plan.title} — ${reason}`,
    sinceAt: plan.createdAt,
    mock: plan.mock,
  })
}

function approvalHold(
  sessionId: string,
  plan: WorkPlan,
  milestone: Milestone,
  blockers: number,
): Hold {
  const subject = `milestone ${milestone.index + 1}: ${milestone.title}`
  if (blockers > 0) {
    // The blocker count lives in the detail, not the generation: the count
    // moving 3 → 2 is the same waiting, and must not renotify.
    return hold('ledger-gated', plan.id, `${milestone.id}\0${milestone.status}`, {
      sessionId,
      planId: plan.id,
      milestoneId: milestone.id,
      loopId: null,
      title: 'Approval gated by open findings',
      detail: `${blockers} blocking finding${blockers === 1 ? '' : 's'} must be dispositioned before ${subject} can be approved.`,
      sinceAt: milestone.createdAt,
      mock: plan.mock,
    })
  }
  return hold('approval-waiting', plan.id, `${milestone.id}\0${milestone.status}`, {
    sessionId,
    planId: plan.id,
    milestoneId: milestone.id,
    loopId: null,
    title: 'Ready to approve',
    detail: `${plan.title} — ${subject}`,
    sinceAt: milestone.createdAt,
    mock: plan.mock,
  })
}

function milestoneFailedHold(sessionId: string, plan: WorkPlan, milestone: Milestone): Hold {
  // A retry consumes a fresh approval and a re-run rewrites the test result
  // and review note, so folding all three into the generation makes the next
  // failure a fresh hold even after this one was acknowledged.
  const generation = `${milestone.approvalId ?? ''}\0${milestone.testResult?.ranAt ?? ''}\0${milestone.reviewNote}`
  return hold('milestone-failed', milestone.id, generation, {
    sessionId,
    planId: plan.id,
    milestoneId: milestone.id,
    loopId: null,
    title: 'A milestone failed',
    detail: `${plan.title} — milestone ${milestone.index + 1}: ${milestone.title}`,
    sinceAt: milestone.testResult?.ranAt ?? milestone.createdAt,
    mock: plan.mock,
  })
}

/**
 * The event types whose underlying writes can change the derived hold set.
 *
 * A positive list, because the bus also carries per-token deltas and activity
 * telemetry that fire constantly and can never move a hold. Two mutations
 * reach the database without any event at all — archiving a session, and the
 * ack itself — so the Manager exposes an explicit recompute for those paths.
 */
const RECOMPUTES_ON: ReadonlySet<AppEvent['type']> = new Set([
  'session.created',
  'session.status',
  'session.ledger',
  'plan.created',
  // Hold details embed the plan title; the rename mid-draft must reach them.
  'plan.updated',
  'plan.status',
  'plan.milestone',
  'plan.milestones',
  'loop.created',
  'loop.status',
  'backlog.changed',
])

/**
 * Keeps the derived hold set current, published, and notified — once.
 *
 * Sits in front of the orchestrator's emit: every durable transition already
 * flows through that function, so wrapping it is the one place that observes
 * them all. Recomputation is coalesced per microtask because a single
 * correction emits a burst of milestone events, and publishing is skipped when
 * the snapshot is unchanged, so listeners only ever see real movement. The
 * event bus is fire-and-forget with no outbox — a closed window drops events —
 * which is why the renderer hydrates from holds.list and this event only keeps
 * a live window current.
 */
export class HoldsEngine {
  private lastPublished = ''
  private scheduled = false

  constructor(
    private readonly repo: Repo,
    private readonly forward: (event: AppEvent) => void,
    private readonly notifyUser?: (title: string, body: string) => void,
  ) {}

  /** The instrumented emit the orchestrator runs on. */
  readonly emit = (event: AppEvent): void => {
    this.forward(event)
    if (RECOMPUTES_ON.has(event.type)) this.schedule()
  }

  list(): Hold[] {
    return computeHolds(this.repo, this.repo.listHoldAcks())
  }

  /**
   * Acknowledges a notice-class hold. Refused for decision-class holds here,
   * in the main process rather than the UI: an ack-able "waiting on your
   * answer" would clear the badge while the plan stays parked, which is the
   * exact silent stall holds exist to kill.
   */
  ack(holdId: string): Hold[] {
    const hold = this.list().find((entry) => entry.id === holdId)
    if (!hold) throw new Error('no such hold — it may already have cleared')
    if (hold.actionable) {
      throw new Error(
        'this hold clears by acting on it — answer, approve, or land — not by acknowledgement',
      )
    }
    this.repo.ackHold(holdId)
    const after = this.list()
    this.publish(after)
    return after
  }

  /** Coalesces to one recompute per microtask, however many events arrive. */
  schedule(): void {
    if (this.scheduled) return
    this.scheduled = true
    queueMicrotask(() => {
      this.scheduled = false
      this.publish(this.list())
    })
  }

  private publish(holds: Hold[]): void {
    const snapshot = JSON.stringify(holds)
    if (snapshot === this.lastPublished) return
    this.lastPublished = snapshot
    this.forward({ type: 'holds.changed', holds })

    for (const hold of holds) {
      // The stamp is written whether or not a notifier is attached, and before
      // any display attempt: a hold notifies at most once, ever, including
      // across restarts and regardless of what the OS does with the banner.
      if (this.repo.stampNotified(hold.id)) {
        this.notifyUser?.(hold.mock ? `Mock — ${hold.title}` : hold.title, hold.detail)
      }
    }
  }
}

function mergeHold(sessionId: string, plan: WorkPlan, worktree: Worktree): Hold {
  const blocked = worktree.orphaned || worktree.lastError !== ''
  if (blocked) {
    const reason = worktree.lastError || 'the worktree directory or origin is missing'
    // The error text is the generation: a different refusal is new waiting.
    return hold('merge-blocked', plan.id, `${worktree.branch}\0${reason}`, {
      sessionId,
      planId: plan.id,
      milestoneId: null,
      loopId: null,
      title: 'Landing was refused',
      detail: `${plan.title} — branch ${worktree.branch} still carries the work: ${reason}`,
      sinceAt: worktree.createdAt,
      mock: plan.mock,
    })
  }
  return hold('merge-ready', plan.id, worktree.branch, {
    sessionId,
    planId: plan.id,
    milestoneId: null,
    loopId: null,
    title: 'Ready to land',
    detail: `${plan.title} — branch ${worktree.branch} fast-forwards ${plan.repoPath} when you land it.`,
    sinceAt: worktree.createdAt,
    mock: plan.mock,
  })
}

/**
 * The generation is the frozen stamp itself: stable while the run stays
 * silent (no activity means no writes), fresh per episode (activity resumed,
 * then stalled again), so notify-once holds without a tick ever re-minting
 * the identity. The detail stays static — no live-rendered age — because the
 * engine dedupes publishes on snapshot equality; the inspection verdict joins
 * it when one lands, changing the detail under the same identity.
 */
function milestoneStallHold(
  sessionId: string,
  plan: WorkPlan,
  milestone: Milestone,
  stalledSince: number,
): Hold {
  const inspection = milestone.runState?.lastInspection ?? null
  const inspectionLine = inspection
    ? ` The ${plan.executor.vendor === 'claude' ? 'Codex' : 'Claude'} inspection judged it ${inspection.verdict}: ${inspection.note}`
    : ' A read-only inspection by the other vendor runs once per stall.'
  return hold('run-stalled', milestone.id, String(stalledSince), {
    sessionId,
    planId: plan.id,
    milestoneId: milestone.id,
    loopId: null,
    title: 'A run looks stalled',
    detail: `${plan.title} — milestone ${milestone.index + 1}: ${milestone.title} has shown no activity past the stall threshold.${inspectionLine}`,
    sinceAt: stalledSince,
    mock: plan.mock,
  })
}

/**
 * The landing succeeded but the smoke verification in the origin did not — a
 * fact worth exactly one acknowledgeable notice, because the fast-forward is
 * done and the branch is gone: what remains is a human reading the failure.
 */
function landVerifyFailedHold(sessionId: string, plan: WorkPlan, worktree: Worktree): Hold {
  return hold('merge-blocked', plan.id, `landed\0${worktree.lastError}`, {
    sessionId,
    planId: plan.id,
    milestoneId: null,
    loopId: null,
    title: 'Landed, but verification failed',
    detail: `${plan.title} — the branch fast-forwarded, then the smoke check failed in ${plan.repoPath}: ${worktree.lastError}`,
    sinceAt: worktree.landedAt ?? worktree.createdAt,
    mock: plan.mock,
  })
}

function loopStallHold(loop: Loop, stalledSince: number): Hold {
  return hold('run-stalled', loop.id, String(stalledSince), {
    sessionId: null,
    planId: null,
    milestoneId: null,
    loopId: loop.id,
    title: 'A loop looks stalled',
    detail: `${loop.goal} — no activity past the stall threshold. The kill switch remains yours; nothing stops automatically.`,
    sinceAt: stalledSince,
    mock: loop.mock,
  })
}

/**
 * The generation is the newest pending item's timestamp, not the count: a new
 * batch arriving mints a fresh identity (one notification), while discarding
 * or confirming part of a batch only ever falls back to an older timestamp —
 * an identity that has already been stamped, so triage never renotifies.
 * Count-based generations are the documented anti-pattern: 3 → 2 → 3 would
 * re-mint an identity for the same waiting.
 */
function backlogReviewHold(repoPath: string, pending: BacklogItem[]): Hold {
  const proposed = pending.filter((item) => item.state === 'proposed').length
  const closures = pending.length - proposed
  const parts: string[] = []
  if (proposed) parts.push(`${proposed} proposed item${proposed === 1 ? '' : 's'}`)
  if (closures) parts.push(`${closures} closure proposal${closures === 1 ? '' : 's'}`)
  const newest = Math.max(...pending.map((item) => item.createdAt))
  const oldest = Math.min(...pending.map((item) => item.createdAt))
  return hold('backlog-review', repoPath, String(newest), {
    sessionId: null,
    planId: null,
    milestoneId: null,
    loopId: null,
    repoPath,
    title: 'Backlog proposals to review',
    detail: `${repoPath} — ${parts.join(' and ')} waiting on your triage.`,
    sinceAt: oldest,
    // A single real item makes the waiting real; the chip must not launder it.
    mock: pending.every((item) => item.mock),
  })
}

function loopHold(loop: Loop): Hold {
  const title =
    loop.status === 'exhausted'
      ? 'A loop hit its cap'
      : loop.status === 'killed'
        ? 'A loop was killed'
        : 'A loop failed'
  return hold('loop-exhausted', loop.id, `${loop.status}\0${loop.endedAt ?? ''}\0${loop.stopReason}`, {
    sessionId: null,
    planId: null,
    milestoneId: null,
    loopId: loop.id,
    title,
    detail: loop.stopReason ? `${loop.goal} — ${loop.stopReason}` : loop.goal,
    sinceAt: loop.endedAt ?? loop.startedAt,
    mock: loop.mock,
  })
}
