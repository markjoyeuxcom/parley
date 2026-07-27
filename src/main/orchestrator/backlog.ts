import type { BacklogItem, Id, Learning } from '@shared/domain'
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

// Brief caps: enforced by construction, not hope. The table grows uncapped;
// the *brief* is what stays bounded, and curation is the human lever.
const ITEM_DETAIL_CAP = 500
const ITEMS_BLOCK_CAP = 6000
const LEARNINGS_BLOCK_CAP = 1200

/**
 * The selected backlog items, rendered for a plan brief. Evidence is at most
 * three path:line references and never the excerpts — the planner reads the
 * repository, and a path that survives is worth more than a quote that may
 * not have.
 */
export function renderBacklogBlock(items: BacklogItem[]): string {
  if (!items.length) return ''
  const lines: string[] = []
  let used = 0
  let omitted = 0
  for (const item of items) {
    const evidence = item.evidence
      .slice(0, 3)
      .map(
        (entry) =>
          `${entry.path}${entry.line ? `:${entry.line}` : ''}${entry.symbol ? ` — ${entry.symbol}` : ''}`,
      )
      .join(', ')
    const detail =
      item.detail.length > ITEM_DETAIL_CAP
        ? `${item.detail.slice(0, ITEM_DETAIL_CAP - 1)}…`
        : item.detail
    const entry = [
      `- ${item.title}${item.priority ? ` [${item.priority}]` : ''}`,
      detail ? `  ${detail}` : '',
      evidence ? `  Evidence: ${evidence}` : '',
    ]
      .filter(Boolean)
      .join('\n')
    if (used + entry.length > ITEMS_BLOCK_CAP) {
      omitted += 1
      continue
    }
    used += entry.length
    lines.push(entry)
  }
  if (omitted) {
    // An honest omission line — silent truncation reads as "covered".
    lines.push(`(${omitted} more selected item${omitted === 1 ? '' : 's'} omitted for length.)`)
  }
  return `THE BACKLOG ITEMS TO ADDRESS. Selected from this repository's backlog. Plan the smallest set of milestones that addresses them; one you judge not worth acting on must be named and argued, not silently dropped.\n\n${lines.join('\n\n')}`
}

/**
 * The repo's confirmed learnings, newest-first under a hard character cap,
 * each dated. Capped at render time on purpose: capping at write time would
 * silently discard confirmed knowledge, whereas here the oldest simply stop
 * riding and retirement is the deliberate act.
 */
export function renderLearningsBlock(learnings: Learning[]): string {
  if (!learnings.length) return ''
  const lines: string[] = []
  let used = 0
  for (const learning of learnings) {
    const line = `- ${learning.text} (learned ${new Date(learning.createdAt).toISOString().slice(0, 10)})`
    if (used + line.length > LEARNINGS_BLOCK_CAP) break
    used += line.length
    lines.push(line)
  }
  if (!lines.length) return ''
  return `WHAT THIS REPOSITORY HAS TAUGHT US (curated record — trust it unless the code contradicts it):\n${lines.join('\n')}`
}

/**
 * Completion proposes, a human closes. Idempotent by the state guard: only
 * items still `planned` under this exact plan move, so a re-fired completion
 * (or a landing after a completion) cannot double-propose.
 */
export function proposeBacklogClosures(
  repo: Repo,
  planId: Id,
  note: string,
  emit?: (event: AppEvent) => void,
): number {
  const plan = repo.getPlan(planId)
  if (!plan) return 0
  const items = repo
    .listBacklogItems({ repoPath: plan.repoPath, states: ['planned'] })
    .filter((item) => item.planId === planId)
  for (const item of items) {
    repo.transitionBacklogItem(item.id, 'closure-proposed', { source: 'pipeline', note })
  }
  if (items.length && emit) {
    emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(plan.repoPath) })
  }
  return items.length
}

/**
 * Planning-stage death is unrecoverable (there is no re-draft), so the items
 * it claimed return to the backlog. Execution-stage failure deliberately does
 * NOT regress — a failed plan is retryable to complete, and detaching its
 * items would orphan a plan that then finishes.
 */
export function regressPlannedItems(
  repo: Repo,
  planId: Id,
  note: string,
  emit?: (event: AppEvent) => void,
): number {
  const plan = repo.getPlan(planId)
  if (!plan) return 0
  const items = repo
    .listBacklogItems({ repoPath: plan.repoPath, states: ['planned'] })
    .filter((item) => item.planId === planId)
  for (const item of items) {
    repo.transitionBacklogItem(item.id, 'open', { source: 'pipeline', note })
  }
  if (items.length && emit) {
    emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(plan.repoPath) })
  }
  return items.length
}
