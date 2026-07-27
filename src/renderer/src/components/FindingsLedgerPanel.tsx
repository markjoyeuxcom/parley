import { useMemo, useState, type ReactNode } from 'react'
import type {
  FindingDisposition,
  FindingLedgerState,
  FindingOccurrence,
  Milestone,
  WorkPlan,
} from '@shared/domain'
import type { LedgerEntry } from '@shared/ipc'
import { relativeTime } from '../lib/format'
import { api } from '../lib/api'
import { buildLedgerView } from '../lib/ledgerView'
import { useStore } from '../state'
import { Chip, Panel } from './ui'

const STATE_LABELS: Record<FindingLedgerState, string> = {
  open: 'open',
  resolved: 'resolved',
  dismissed: 'dismissed',
  'accepted-risk': 'risk accepted',
}

const STATE_TONES: Record<FindingLedgerState, string> = {
  open: 'chip--fail',
  resolved: 'chip--pass',
  dismissed: '',
  'accepted-risk': 'chip--caution',
}

// Keyed by the enum so a new source member fails the typecheck here rather
// than silently borrowing another stage's label.
const SOURCE_LABELS: Record<FindingOccurrence['source'], string> = {
  audit: 'Plan audit',
  review: 'Independent review',
  adoption: 'Adoption review',
}

function shortId(id: string): string {
  return id.slice(0, 8)
}

function occurrencePlace(
  occurrence: FindingOccurrence,
  plans: Map<string, WorkPlan>,
  milestones: Map<string, Milestone>,
): ReactNode {
  const plan = plans.get(occurrence.planId)
  const milestone = occurrence.milestoneId
    ? milestones.get(occurrence.milestoneId)
    : null
  const planName = plan?.title || plan?.kind || `Plan ${shortId(occurrence.planId)}`
  const milestoneName = occurrence.milestoneId
    ? milestone
      ? `Milestone ${milestone.index + 1}: ${milestone.title}`
      : `Milestone ${shortId(occurrence.milestoneId)}`
    : 'Plan-wide'
  const round =
    occurrence.round === null
      ? 'No review round'
      : occurrence.round === 0
        ? 'Round 1'
        : `Round ${occurrence.round + 1}`

  return (
    <>
      <span title={occurrence.planId}>{planName}</span>
      <span>·</span>
      <span title={occurrence.milestoneId ?? undefined}>{milestoneName}</span>
      <span>·</span>
      <span>{round}</span>
    </>
  )
}

function OccurrenceEvent({
  occurrence,
  state,
  plans,
  milestones,
}: {
  occurrence: FindingOccurrence
  state: FindingLedgerState
  plans: Map<string, WorkPlan>
  milestones: Map<string, Milestone>
}): ReactNode {
  return (
    <li className="ledger-event ledger-event--occurrence">
      <div className={`ledger-event__marker ledger-event__marker--${state}`} />
      <div className="ledger-event__body">
        <div className="ledger-event__head">
          <strong>{SOURCE_LABELS[occurrence.source]}</strong>
          <Chip tone={occurrence.kind === 'blocking' ? 'chip--fail' : ''}>
            {occurrence.kind}
          </Chip>
          <Chip tone={STATE_TONES[state]}>{STATE_LABELS[state]}</Chip>
          <span className="spacer" />
          <time className="ledger-event__time" dateTime={new Date(occurrence.createdAt).toISOString()}>
            {relativeTime(occurrence.createdAt)}
          </time>
        </div>
        <div className="ledger-event__meta">
          {occurrencePlace(occurrence, plans, milestones)}
        </div>
      </div>
    </li>
  )
}

function DispositionEvent({
  disposition,
  occurrences,
}: {
  disposition: FindingDisposition
  occurrences: Map<string, FindingOccurrence>
}): ReactNode {
  const target = disposition.occurrenceId
    ? occurrences.get(disposition.occurrenceId)
    : null
  const scope = disposition.occurrenceId
    ? target
      ? `Occurrence from sequence ${target.seq}`
      : `Occurrence ${shortId(disposition.occurrenceId)}`
    : 'All occurrences raised before this decision'

  return (
    <li className="ledger-event ledger-event--disposition">
      <div className={`ledger-event__marker ledger-event__marker--${disposition.state}`} />
      <div className="ledger-event__body">
        <div className="ledger-event__head">
          <strong>{disposition.source === 'human' ? 'Human disposition' : 'Pipeline settlement'}</strong>
          <Chip tone={STATE_TONES[disposition.state]}>{STATE_LABELS[disposition.state]}</Chip>
          <span className="spacer" />
          <time className="ledger-event__time" dateTime={new Date(disposition.createdAt).toISOString()}>
            {relativeTime(disposition.createdAt)}
          </time>
        </div>
        <div className="ledger-event__meta">{scope}</div>
        {disposition.note ? <div className="ledger-event__note">{disposition.note}</div> : null}
      </div>
    </li>
  )
}

export function FindingsLedgerPanel({
  entries,
  plans = [],
  milestones = [],
}: {
  entries: readonly LedgerEntry[]
  plans?: readonly WorkPlan[]
  milestones?: readonly Milestone[]
}): ReactNode {
  const views = useMemo(() => buildLedgerView(entries), [entries])
  const planLookup = useMemo(
    () => new Map(plans.map((plan) => [plan.id, plan])),
    [plans],
  )
  const milestoneLookup = useMemo(
    () => new Map(milestones.map((milestone) => [milestone.id, milestone])),
    [milestones],
  )
  const openCount = views.reduce(
    (sum, view) => sum + view.openBlockingOccurrences.length,
    0,
  )

  if (!views.length) return null

  return (
    <Panel
      title="Findings ledger"
      flush
      actions={
        openCount ? (
          <Chip tone="chip--fail">{openCount} unresolved</Chip>
        ) : (
          <Chip tone="chip--pass">settled</Chip>
        )
      }
    >
      <div className="ledger">
        {views.map((view) => {
          const occurrenceLookup = new Map(
            view.entry.occurrences.map((occurrence) => [occurrence.id, occurrence]),
          )
          return (
            <section className="ledger-finding" key={view.entry.id}>
              <div className="ledger-finding__head">
                <div className="ledger-finding__text">{view.entry.text}</div>
                <Chip tone={STATE_TONES[view.state]}>{STATE_LABELS[view.state]}</Chip>
              </div>
              <ol className="ledger-timeline">
                {view.timeline.map((item) =>
                  item.type === 'occurrence' ? (
                    <OccurrenceEvent
                      key={`occurrence:${item.occurrence.id}`}
                      occurrence={item.occurrence}
                      state={item.state}
                      plans={planLookup}
                      milestones={milestoneLookup}
                    />
                  ) : (
                    <DispositionEvent
                      key={`disposition:${item.disposition.id}`}
                      disposition={item.disposition}
                      occurrences={occurrenceLookup}
                    />
                  ),
                )}
              </ol>
            </section>
          )
        })}
      </div>
    </Panel>
  )
}

export function OccurrenceDispositionControl({
  entry,
  occurrence,
  plan,
  milestone,
}: {
  entry: LedgerEntry
  occurrence: FindingOccurrence
  plan?: WorkPlan
  milestone?: Milestone
}): ReactNode {
  const { attempt, dispatch, notify } = useStore()
  const [state, setState] = useState<FindingDisposition['state']>('resolved')
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)

  const record = async (): Promise<void> => {
    const explanation = note.trim()
    if (!explanation) return
    setBusy(true)
    const updated = await attempt(() =>
      api.disposeLedgerFinding(
        entry.sessionId,
        entry.id,
        occurrence.id,
        state,
        explanation,
      ),
    )
    setBusy(false)
    if (!updated) return
    dispatch({
      type: 'appEvent',
      event: { type: 'session.ledger', entry: updated },
    })
    notify('info', 'Disposition recorded in the findings ledger.')
  }

  return (
    <div className="ledger-dispose">
      <div className="ledger-dispose__finding">{entry.text}</div>
      <div className="ledger-dispose__meta">
        {SOURCE_LABELS[occurrence.source]} ·{' '}
        <span title={occurrence.planId}>
          {plan?.id === occurrence.planId
            ? plan.title || plan.kind
            : `plan ${shortId(occurrence.planId)}`}
        </span>{' '}
        ·{' '}
        <span title={occurrence.milestoneId ?? undefined}>
          {occurrence.milestoneId
            ? milestone?.id === occurrence.milestoneId
              ? `milestone ${milestone.index + 1}: ${milestone.title}`
              : `milestone ${shortId(occurrence.milestoneId)}`
            : 'plan-wide'}
        </span>{' '}
        ·{' '}
        {occurrence.round === null ? 'no review round' : `round ${occurrence.round + 1}`}
      </div>
      <div className="ledger-dispose__controls">
        <select
          className="select"
          aria-label="Disposition"
          value={state}
          disabled={busy}
          onChange={(event) => setState(event.target.value as FindingDisposition['state'])}
        >
          <option value="resolved">Resolved by the planned work</option>
          <option value="dismissed">Dismissed with explanation</option>
          <option value="accepted-risk">Accept the risk</option>
        </select>
        <textarea
          className="textarea"
          rows={2}
          aria-label="Disposition explanation"
          placeholder="Why this occurrence no longer blocks approval…"
          value={note}
          disabled={busy}
          onChange={(event) => setNote(event.target.value)}
        />
        <button
          className="btn btn--sm"
          disabled={busy || !note.trim()}
          onClick={() => void record()}
        >
          {busy ? 'Recording…' : 'Record disposition'}
        </button>
      </div>
    </div>
  )
}
