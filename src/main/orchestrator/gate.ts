import type { FindingOccurrence, Id } from '@shared/domain'
import { isBlockingOccurrence, occurrenceState } from '@shared/ledger'
import type { Repo } from '@main/store/repo'

export class FindingGateError extends Error {}

export function unresolvedBlockingOccurrences(
  repo: Repo,
  sessionId: Id,
): FindingOccurrence[] {
  const dispositions = repo.listFindingDispositions(sessionId)
  return repo
    .listFindingOccurrences(sessionId)
    .filter(
      (occurrence) =>
        isBlockingOccurrence(occurrence) &&
        occurrenceState(occurrence, dispositions) === 'open',
    )
}

export function assertNoUnresolvedBlockingOccurrences(repo: Repo, sessionId: Id): void {
  const unresolved = unresolvedBlockingOccurrences(repo, sessionId)
  if (!unresolved.length) return

  throw new FindingGateError(
    `${unresolved.length} blocking finding occurrence${unresolved.length === 1 ? ' is' : 's are'} unresolved. Record a disposition before approving or executing a milestone.`,
  )
}
