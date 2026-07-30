import type { ReactNode } from 'react'
import { Archive, Download } from 'lucide-react'
import type { Finding, Id, ScoreDimension, Verdict } from '@shared/domain'
import { relativeTime, seatLabel, seatSide } from '../lib/format'
import { useStore } from '../state'
import { Chip, Meter, Panel } from './ui'

const DIMENSION_LABEL: Record<ScoreDimension, string> = {
  correctness: 'Correctness',
  robustness: 'Robustness',
  clarity: 'Clarity',
  maintainability: 'Maintainability',
  risk: 'Risk (10 = lowest)',
}

const ORDER: ScoreDimension[] = ['correctness', 'robustness', 'clarity', 'maintainability', 'risk']

export function VerdictPanel({
  verdict,
  onExport,
  onStow,
  sessionId,
}: {
  verdict: Verdict
  onExport: () => void
  /** Present only when the session has a repository to file into. */
  onStow?: (() => void) | null
  /** Lets the Stow button remember: stow-sourced rows with this origin mean
   * the session was already swept, and the label should say so. */
  sessionId?: Id
}): ReactNode {
  const { state } = useStore()
  const confidence = Math.round(verdict.confidence * 100)
  const tone = confidence >= 70 ? 'chip--pass' : confidence >= 40 ? 'chip--caution' : 'chip--fail'

  // Derived, never stored — the same discipline as the holds queue. Any
  // stow-sourced item or learning with this session's origin proves a sweep
  // already ran; the newest stamp gives the label its honesty.
  const stowedAt =
    onStow && sessionId
      ? [...state.backlogItems, ...state.learnings]
          .filter((row) => row.originSessionId === sessionId && row.source === 'stow')
          .reduce<number | null>(
            (last, row) => (last === null || row.createdAt > last ? row.createdAt : last),
            null,
          )
      : null

  return (
    <div className="verdict">
      <div className="verdict__head">
        <div className="row" style={{ marginBottom: 'var(--s4)' }}>
          <span className="label">Verdict</span>
          <Chip tone={tone} title="Both sides' mean credence, scaled by how closely their scores agreed">
            {confidence}% confidence
          </Chip>
          <div className="spacer" />
          {onStow ? (
            <button
              className="btn btn--sm"
              onClick={onStow}
              title={
                stowedAt
                  ? `Last stowed ${relativeTime(stowedAt)}. The sweep is shown what is already tracked, so a re-run proposes only what is genuinely new.`
                  : 'One read-only agent turn drafts backlog items and learnings from this session. Nothing counts until you confirm it.'
              }
            >
              <Archive size={12} strokeWidth={2} />
              {stowedAt ? 'Stow again' : 'Stow'}
            </button>
          ) : null}
          <button className="btn btn--sm" onClick={onExport} title="Export the full report as Markdown">
            <Download size={12} strokeWidth={2} />
            Export
          </button>
        </div>

        <div className="verdict__decision">{verdict.decision}</div>
        {verdict.rationale ? <div className="verdict__rationale">{verdict.rationale}</div> : null}
      </div>

      <div className="verdict__scores">
        {ORDER.map((dimension) => {
          const score = verdict.scores[dimension]
          if (typeof score !== 'number') return null
          return (
            <div className="verdict__score-row" key={dimension}>
              <div className="verdict__score-name">{DIMENSION_LABEL[dimension]}</div>
              <Meter value={score} />
            </div>
          )
        })}
      </div>

      {/*
        Dissent is shown in full and never collapsed. In an adversarial session it
        is the most perishable output — the thing a single agent would have
        smoothed away — so hiding it behind a disclosure would defeat the design.
      */}
      {verdict.dissent.trim() ? (
        <div className="dissent">
          <div className="label" style={{ marginBottom: 'var(--s3)' }}>
            Unresolved
          </div>
          <div className="dissent__body">{verdict.dissent}</div>
        </div>
      ) : null}
    </div>
  )
}

const PRIORITY_TONE: Record<string, string> = {
  P0: 'chip--fail',
  P1: 'chip--caution',
  P2: '',
  P3: '',
}

export function FindingsPanel({ findings }: { findings: Finding[] }): ReactNode {
  if (!findings.length) return null

  const confirmed = findings.filter((f) => f.status === 'confirmed')
  const dismissed = findings.filter((f) => f.status === 'dismissed')
  const unsupported = findings.filter((f) => f.status === 'unsupported')

  const byPriority = ['P0', 'P1', 'P2', 'P3'] as const
  const sorted = byPriority.flatMap((p) => confirmed.filter((f) => f.priority === p))

  return (
    <Panel
      title={`Findings — ${confirmed.length} confirmed`}
      flush
      actions={
        <>
          {dismissed.length ? <Chip>{dismissed.length} dismissed</Chip> : null}
          {unsupported.length ? <Chip tone="chip--caution">{unsupported.length} unsupported</Chip> : null}
        </>
      }
    >
      {sorted.map((finding) => (
        <FindingRow key={finding.id} finding={finding} />
      ))}

      {dismissed.length ? (
        <>
          <div style={{ padding: 'var(--s5) var(--s6) var(--s2)' }}>
            <div className="label">Investigated and dismissed</div>
            <div className="field__hint" style={{ marginTop: 'var(--s2)' }}>
              Raised by one reviewer, checked by the other against the code, and found not to hold.
              Kept as part of the record.
            </div>
          </div>
          {dismissed.map((finding) => (
            <FindingRow key={finding.id} finding={finding} />
          ))}
        </>
      ) : null}

      {unsupported.length ? (
        <>
          <div style={{ padding: 'var(--s5) var(--s6) var(--s2)' }}>
            <div className="label">Raised without sufficient evidence</div>
          </div>
          {unsupported.map((finding) => (
            <FindingRow key={finding.id} finding={finding} />
          ))}
        </>
      ) : null}
    </Panel>
  )
}

function FindingRow({ finding }: { finding: Finding }): ReactNode {
  return (
    <div className={`finding ${finding.status === 'dismissed' ? 'finding--dismissed' : ''}`}>
      <div className="finding__head">
        <Chip tone={PRIORITY_TONE[finding.priority] ?? ''}>{finding.priority}</Chip>
        <div className="finding__title">{finding.title}</div>
        <Chip tone={seatSide(finding.raisedBy) === 'a' ? 'chip--a' : 'chip--b'} title="Which seat raised it">
          {seatLabel(finding.raisedBy)}
        </Chip>
      </div>
      {finding.detail ? <div className="finding__detail">{finding.detail}</div> : null}
      {finding.evidence.length ? (
        <div className="evidence">
          {finding.evidence.map((item, index) => (
            <span className="evidence__item" key={`${item.path}-${index}`}>
              {item.path}
              {item.line ? `:${item.line}` : ''}
              {item.symbol ? ` · ${item.symbol}` : ''}
            </span>
          ))}
        </div>
      ) : null}
    </div>
  )
}
