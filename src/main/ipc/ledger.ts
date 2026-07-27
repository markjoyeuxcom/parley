import type { AppEvent } from '@shared/events'
import type { CommandPayload, LedgerEntry } from '@shared/ipc'
import type { Repo } from '@main/store/repo'

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
    plans: repo.listPlans().filter((plan) => plan.sessionId === sessionId),
  }
}

export function disposeLedgerFinding(
  repo: Repo,
  input: CommandPayload<'ledger.dispose'>,
  emit: (event: AppEvent) => void,
): LedgerEntry {
  if (!repo.getSession(input.sessionId)) throw new Error('no such session')
  const finding = repo
    .listLedgerFindings(input.sessionId)
    .find((item) => item.id === input.findingId)
  if (!finding) throw new Error('no such finding in that session')

  repo.disposeFinding({
    findingId: input.findingId,
    occurrenceId: input.occurrenceId,
    state: input.state,
    note: input.note,
    source: 'human',
  })
  const entry = groupLedgerEntries(repo, input.sessionId).find(
    (item) => item.id === input.findingId,
  )
  if (!entry) throw new Error('failed to reload finding ledger entry')
  emit({ type: 'session.ledger', entry })
  return entry
}
