import type { AppEvent } from '@shared/events'
import type { CommandPayload, LedgerEntry } from '@shared/ipc'
import type { Repo } from '@main/store/repo'
import { ingestAcceptedRisk } from '@main/orchestrator/backlog'

/**
 * The one place a LedgerEntry is assembled from its three tables.
 *
 * Exported because the pipeline's ledger events need the same shape: a second
 * assembly drifted once already, and two definitions of "the entry" is how the
 * panel and the event stream end up disagreeing about what a finding contains.
 */
export function groupLedgerEntries(repo: Repo, sessionId: string): LedgerEntry[] {
  const occurrences = repo.listFindingOccurrences(sessionId)
  const dispositions = repo.listFindingDispositions(sessionId)
  return repo.listLedgerFindings(sessionId).map((finding) => ({
    ...finding,
    occurrences: occurrences.filter((occurrence) => occurrence.findingId === finding.id),
    dispositions: dispositions.filter((disposition) => disposition.findingId === finding.id),
  }))
}

/**
 * Assembles one finding's entry, without loading the session's whole ledger.
 *
 * The single-finding twin of {@link groupLedgerEntries}, kept in the same
 * module for the same reason that one exists at all: the pipeline emits an
 * event per touched finding, and rebuilding every entry in the session for
 * each event was churn that grew with the ledger itself. Returns null for a
 * finding that does not exist or belongs to a different session — the caller
 * must not be able to lift an entry across a session boundary.
 */
export function groupLedgerEntry(
  repo: Repo,
  sessionId: string,
  findingId: string,
): LedgerEntry | null {
  const finding = repo.getLedgerFinding(findingId)
  if (!finding || finding.sessionId !== sessionId) return null
  return {
    ...finding,
    occurrences: repo.listOccurrencesForFinding(findingId),
    dispositions: repo.listDispositionsForFinding(findingId),
  }
}

export function listSessionLedger(repo: Repo, sessionId: string): LedgerEntry[] {
  if (!repo.getSession(sessionId)) throw new Error('no such session')
  return groupLedgerEntries(repo, sessionId)
}

export function getSessionDetail(repo: Repo, sessionId: string) {
  const session = repo.getSession(sessionId)
  if (!session) throw new Error('no such session')
  return {
    session,
    turns: repo.listTurns(sessionId),
    interjections: repo.listInterjections(sessionId),
    verdict: repo.getVerdict(sessionId),
    findings: repo.listFindings(sessionId),
    ledger: groupLedgerEntries(repo, sessionId),
    // listPlansForSession, not a filter over the capped global list: a
    // session older than the newest 200 plans would show a partial (or
    // empty) plan list while its plans still exist.
    plans: repo.listPlansForSession(sessionId),
  }
}

export function disposeLedgerFinding(
  repo: Repo,
  input: CommandPayload<'ledger.dispose'>,
  emit: (event: AppEvent) => void,
): LedgerEntry {
  if (!repo.getSession(input.sessionId)) throw new Error('no such session')
  if (!groupLedgerEntry(repo, input.sessionId, input.findingId)) {
    throw new Error('no such finding in that session')
  }

  repo.disposeFinding({
    findingId: input.findingId,
    occurrenceId: input.occurrenceId,
    state: input.state,
    note: input.note,
    source: 'human',
  })
  // An accepted risk is carried into the backlog of the repos it was accepted
  // against — accepting must never quietly become forgetting.
  if (input.state === 'accepted-risk') {
    ingestAcceptedRisk(repo, { findingId: input.findingId, occurrenceId: input.occurrenceId }, emit)
  }
  const entry = groupLedgerEntry(repo, input.sessionId, input.findingId)
  if (!entry) throw new Error('failed to reload finding ledger entry')
  emit({ type: 'session.ledger', entry })
  return entry
}
