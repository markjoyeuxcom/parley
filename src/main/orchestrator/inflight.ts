import type { InFlightRow } from '@shared/inflight'
import type { Repo } from '@main/store/repo'

/**
 * Derives everything currently running from durable state.
 *
 * Deliberately NOT read from the Manager's in-memory run registries: those
 * are liveness for refusals, while this is a view, and a view that disagreed
 * with the record would be worse than no view. Startup reconciliation already
 * turns anything a crash stranded into a settled row, so a `running` status
 * here means the record itself says it is live.
 *
 * Sorted longest-running first: the thing that has been going the longest is
 * the thing most likely to be stuck.
 */
export function computeInFlight(repo: Repo, now = Date.now()): InFlightRow[] {
  const rows: InFlightRow[] = []

  for (const envelope of repo.listActiveEnvelopes()) {
    const plan = repo.getPlan(envelope.planId)
    if (!plan) continue
    const elapsed = now - envelope.startedAt
    const spent = Math.max(0, plan.usage.costUsd - envelope.startCostUsd)
    rows.push({
      id: `envelope:${envelope.id}`,
      kind: 'envelope',
      title: `Unattended: ${plan.title}`,
      detail: `${envelope.milestonesRun} of ${envelope.caps.maxMilestones} milestones authorised`,
      startedAt: envelope.startedAt,
      repoPath: plan.repoPath,
      jump: { to: 'plan', planId: plan.id },
      progress: [
        { label: 'milestones', value: envelope.milestonesRun / envelope.caps.maxMilestones },
        { label: 'time', value: elapsed / envelope.caps.maxWallClockMs },
        ...(envelope.caps.maxSpendUsd > 0
          ? [{ label: 'spend', value: spent / envelope.caps.maxSpendUsd }]
          : []),
      ],
      mock: plan.mock,
    })
  }

  for (const plan of repo.listPlans()) {
    if (plan.status === 'drafting' || plan.status === 'auditing' || plan.status === 'correcting') {
      rows.push({
        id: `plan:${plan.id}`,
        kind: 'plan',
        title: plan.title || `${plan.kind} plan`,
        detail: plan.status === 'auditing' ? 'being audited' : plan.status,
        startedAt: plan.createdAt,
        repoPath: plan.repoPath,
        jump: { to: 'plan', planId: plan.id },
        mock: plan.mock,
      })
      continue
    }
    if (plan.status !== 'running') continue
    for (const milestone of repo.listMilestones(plan.id)) {
      if (
        milestone.status !== 'executing' &&
        milestone.status !== 'testing' &&
        milestone.status !== 'reviewing'
      ) {
        continue
      }
      rows.push({
        id: `milestone:${milestone.id}`,
        kind: 'milestone',
        title: `${plan.title} — milestone ${milestone.index + 1}`,
        detail: `${milestone.status}: ${milestone.title}`,
        // The milestone row has no start stamp of its own; the plan's own
        // liveness stamp is what the stall watchdog reads, so use it here too.
        startedAt: milestone.createdAt,
        repoPath: plan.repoPath,
        jump: { to: 'plan', planId: plan.id, milestoneId: milestone.id },
        mock: plan.mock,
      })
    }
  }

  for (const session of repo.listSessions(200)) {
    if (session.status !== 'running') continue
    rows.push({
      id: `session:${session.id}`,
      kind: 'session',
      title: session.matter.replace(/\s+/g, ' ').slice(0, 80),
      detail: session.kind === 'review' ? 'review in progress' : 'debate in progress',
      startedAt: session.createdAt,
      repoPath: session.repoPath,
      jump: { to: 'session', sessionId: session.id },
      mock: session.mock,
    })
  }

  for (const loop of repo.listLoops()) {
    if (loop.status !== 'running') continue
    rows.push({
      id: `loop:${loop.id}`,
      kind: 'loop',
      title: loop.goal.replace(/\s+/g, ' ').slice(0, 80),
      detail: `iteration ${loop.iterationCount} of ${loop.caps.maxIterations}`,
      startedAt: loop.startedAt,
      repoPath: loop.repoPath,
      jump: { to: 'loop', loopId: loop.id },
      progress: [
        { label: 'iterations', value: loop.iterationCount / loop.caps.maxIterations },
        { label: 'time', value: (now - loop.startedAt) / loop.caps.maxWallClockMs },
      ],
      mock: loop.mock,
    })
  }

  return rows.sort((a, b) => a.startedAt - b.startedAt)
}
