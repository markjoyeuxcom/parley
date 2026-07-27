import type { Hold, HoldKind } from '@shared/holds'
import { HOLD_CLASS, holdIdentity } from '@shared/holds'
import type { Loop, Milestone, WorkPlan } from '@shared/domain'
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

export function computeHolds(repo: Repo, acked: ReadonlySet<string>): Hold[] {
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
    }
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
  fields: Omit<Hold, 'id' | 'kind' | 'actionable'>,
): Hold {
  return {
    id: holdIdentity(kind, subjectId, generation),
    kind,
    actionable: HOLD_CLASS[kind] === 'decision',
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
