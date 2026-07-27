import type { Id } from '@shared/domain'
import type { AppEvent } from '@shared/events'
import type { Repo } from '@main/store/repo'
import { canonicalRepoPath } from '@main/util/repoPath'

/**
 * Deterministic backlog ingestion.
 *
 * The structured record already says what is worth remembering — a review's
 * confirmed findings, a risk a human explicitly accepted — and none of it
 * needs a model's paraphrase to file. Everything here is replayable by
 * construction: filing dedupes against live items by content, so calling any
 * of these twice is free, which is what makes the startup sweep safe and the
 * crash window (verdict committed, ingestion missed) self-healing.
 *
 * This module exists so the hooks in session closing, the ledger IPC and the
 * entrypoint stay one-line delegations — the parallel Engine arc owns those
 * files' wholesale-staging territory, and the seam belongs here.
 */

/**
 * Files a completed review's confirmed findings as open backlog items.
 *
 * Confirmed only: dismissed and unsupported findings are records, not work.
 * Evidence and priority are copied — Finding rows are wholesale-replaced per
 * closing, so their ids are unstable by design and must never be referenced.
 * The session's mock flag travels with every item; fabricated findings must
 * never read as real work in a real repository's backlog.
 */
export function backfillBacklogFromSession(
  repo: Repo,
  sessionId: Id,
  emit?: (event: AppEvent) => void,
): { filed: number; resighted: number } {
  const session = repo.getSession(sessionId)
  if (!session || session.kind !== 'review' || !session.repoPath) {
    return { filed: 0, resighted: 0 }
  }
  if (!repo.getVerdict(sessionId)) return { filed: 0, resighted: 0 }

  let filed = 0
  let resighted = 0
  for (const finding of repo.listFindings(sessionId)) {
    if (finding.status !== 'confirmed') continue
    const result = repo.fileBacklogItem({
      repoPath: session.repoPath,
      title: finding.title,
      detail: finding.detail,
      priority: finding.priority,
      source: 'review-finding',
      originSessionId: sessionId,
      evidence: finding.evidence,
      mock: session.mock,
      note: `Confirmed ${finding.priority} finding from a codebase review.`,
    })
    if (result.resighted) resighted += 1
    else filed += 1
  }

  if (filed + resighted > 0 && emit) {
    emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(session.repoPath) })
  }
  return { filed, resighted }
}

/**
 * The startup sweep: replays ingestion over every completed, unarchived
 * review session. Two jobs in one pass — heals the crash window between a
 * verdict committing and its ingestion committing, and deliberately
 * back-ingests reviews completed before the backlog existed, so the surface
 * opens populated from record rather than empty. Archived sessions are
 * respected as put-away; items are droppable and mock-flagged either way.
 */
export function backfillBacklog(
  repo: Repo,
  emit?: (event: AppEvent) => void,
): { filed: number; resighted: number } {
  let filed = 0
  let resighted = 0
  for (const session of repo.listSessions(500, false)) {
    if (session.kind !== 'review' || session.status !== 'complete') continue
    const result = backfillBacklogFromSession(repo, session.id, emit)
    filed += result.filed
    resighted += result.resighted
  }
  return { filed, resighted }
}

/**
 * Carries an accepted risk into the backlog of every repository it was
 * accepted against. The repo comes from the covered occurrences' plans —
 * never the session, whose repoPath is nullable and whose plans can span
 * repositories. Accepting a risk is a human act on the record; carrying it
 * here is what keeps "accepted" from quietly becoming "forgotten".
 */
export function ingestAcceptedRisk(
  repo: Repo,
  input: { findingId: Id; occurrenceId: Id | null },
  emit?: (event: AppEvent) => void,
): void {
  const finding = repo.getLedgerFinding(input.findingId)
  if (!finding) return
  const session = repo.getSession(finding.sessionId)

  const occurrences = repo.listOccurrencesForFinding(input.findingId)
  const covered = input.occurrenceId
    ? occurrences.filter((occurrence) => occurrence.id === input.occurrenceId)
    : occurrences

  const repos = new Set<string>()
  for (const occurrence of covered) {
    const plan = repo.getPlan(occurrence.planId)
    if (plan) repos.add(plan.repoPath)
  }

  for (const repoPath of repos) {
    repo.fileBacklogItem({
      repoPath,
      title: firstLineOf(finding.text),
      detail: finding.text,
      source: 'accepted-risk',
      originSessionId: finding.sessionId,
      mock: session?.mock ?? false,
      note: 'Accepted as a risk in the finding ledger; carried so accepted never becomes forgotten.',
    })
    emit?.({ type: 'backlog.changed', repoPath: canonicalRepoPath(repoPath) })
  }
}

function firstLineOf(text: string): string {
  const line = (text.split('\n').find((candidate) => candidate.trim()) ?? text).trim()
  return line.length > 120 ? `${line.slice(0, 119)}…` : line
}
