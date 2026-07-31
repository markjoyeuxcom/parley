import { useState, type ReactNode } from 'react'
import { FolderOpen, Plus, X } from 'lucide-react'
import type { AgentConfig, Session, SessionKind } from '@shared/domain'
import { api } from '../lib/api'
import { seatLabel, shortPath } from '../lib/format'
import { recentProjects } from '../lib/sessionGroups'
import { useStore } from '../state'
import { AgentPicker, defaultAgentA, defaultAgentB } from './AgentPicker'
import { Dialog, Field } from './ui'

/** The request schema's ceiling: two exchange seats plus at most two assessors. */
const MAX_SEATS = 4

export function NewSessionDialog({
  initialKind = 'debate',
  initialRepoPath,
  initialMatter,
  onClose,
  onStarted,
}: {
  initialKind?: SessionKind
  /** Prefill for callers that already know the repository — the Repos surface. */
  initialRepoPath?: string
  /** Prefill for the matter — the Grid's promoted terminal selection. */
  initialMatter?: string
  onClose: () => void
  onStarted: (session: Session) => void
}): ReactNode {
  const { state, attempt } = useStore()
  const [kind, setKind] = useState<SessionKind>(initialKind)
  const [matter, setMatter] = useState(initialMatter ?? '')
  const [project, setProject] = useState('')
  const [repoPath, setRepoPath] = useState(initialRepoPath ?? '')
  const [maxTurns, setMaxTurns] = useState(6)
  const [participants, setParticipants] = useState<AgentConfig[]>([defaultAgentA, defaultAgentB])
  const [busy, setBusy] = useState(false)

  const repeatedVendor = new Set(participants.map((seat) => seat.vendor)).size < participants.length
  const needsRepo = kind === 'review'
  const canStart = matter.trim().length > 0 && (!needsRepo || repoPath.trim().length > 0) && !busy

  const setSeat = (seat: number, config: AgentConfig): void => {
    setParticipants((current) => current.map((existing, at) => (at === seat ? config : existing)))
  }

  // A new assessor takes the vendor the bench has fewer of, so the added
  // cross-check starts diverse instead of doubling a blind spot.
  const addSeat = (): void => {
    setParticipants((current) => {
      const claudes = current.filter((seat) => seat.vendor === 'claude').length
      const template = claudes * 2 > current.length ? defaultAgentB : defaultAgentA
      return [...current, { ...template, persona: '' }]
    })
  }

  const removeSeat = (seat: number): void => {
    setParticipants((current) => current.filter((_, at) => at !== seat))
  }

  const start = async (): Promise<void> => {
    setBusy(true)
    const session = await attempt(() =>
      api.startSession({
        kind,
        matter: matter.trim(),
        project: project.trim(),
        repoPath: repoPath.trim() || null,
        participants,
        maxTurns,
      }),
    )
    setBusy(false)
    if (session) {
      onStarted(session)
      onClose()
    }
  }

  const chooseFolder = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Choose a repository'))
    if (result?.path) setRepoPath(result.path)
  }

  const exchangeLabel = (seat: number): string =>
    kind === 'review'
      ? seat === 0
        ? 'Side A — Cartographer'
        : 'Side B — Reviewer'
      : seat === 0
        ? 'Side A — affirmative'
        : 'Side B — negative'

  return (
    <Dialog
      title="New session"
      subtitle="CLIs from different model families work the question independently, then every seat records its own verdict."
      onClose={onClose}
      wide
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--primary" disabled={!canStart} onClick={() => void start()}>
            {busy ? 'Starting…' : kind === 'review' ? 'Start review' : 'Start debate'}
          </button>
        </>
      }
    >
      <div className="segmented" style={{ alignSelf: 'flex-start' }}>
        <button
          className={`segmented__item ${kind === 'debate' ? 'is-active' : ''}`}
          onClick={() => setKind('debate')}
        >
          Debate
        </button>
        <button
          className={`segmented__item ${kind === 'review' ? 'is-active' : ''}`}
          onClick={() => setKind('review')}
        >
          Codebase review
        </button>
      </div>

      <Field
        label={kind === 'review' ? 'Review brief' : 'The matter'}
        hint={
          kind === 'review'
            ? 'What should the reviewers focus on? Every seat reads the repository; none can modify it.'
            : 'State the decision to be made. A falsifiable question produces a sharper exchange than an open-ended one.'
        }
      >
        <textarea
          className="textarea"
          rows={4}
          autoFocus
          placeholder={
            kind === 'review'
              ? 'Audit correctness, error handling and test coverage in the sync layer.'
              : 'Should we move the ingest pipeline to a queue, or keep it synchronous?'
          }
          value={matter}
          onChange={(event) => setMatter(event.target.value)}
        />
      </Field>

      <div className="field-row">
        <Field label="Project" hint="Optional label for grouping.">
          {/* Suggestions only — a project is still free text, so a new one
              costs nothing and an old one need not be retyped exactly. */}
          <input
            className="input"
            placeholder="Ledger"
            list="recent-projects"
            value={project}
            onChange={(event) => setProject(event.target.value)}
          />
          <datalist id="recent-projects">
            {recentProjects(state.sessions).map((name) => (
              <option key={name} value={name} />
            ))}
          </datalist>
        </Field>

        <Field
          label={needsRepo ? 'Repository (required)' : 'Repository (optional)'}
          hint={
            needsRepo
              ? 'Read-only through the selected CLI’s governed read capability.'
              : 'Attach one to let every seat cite real code.'
          }
        >
          <button className="btn" style={{ justifyContent: 'flex-start' }} onClick={() => void chooseFolder()}>
            <FolderOpen size={12} strokeWidth={2} />
            {repoPath ? shortPath(repoPath) : 'Choose folder'}
          </button>
        </Field>
      </div>

      {kind === 'debate' ? (
        <Field label={`Exchange length — ${maxTurns} turns`} hint="Plus one independent verdict from every seat.">
          <input
            type="range"
            min={2}
            max={12}
            step={1}
            value={maxTurns}
            onChange={(event) => setMaxTurns(Number(event.target.value))}
          />
        </Field>
      ) : null}

      <hr className="divider" />

      {participants.map((seat, at) => (
        <div key={at} style={{ position: 'relative' }}>
          <AgentPicker
            label={at < 2 ? exchangeLabel(at) : `${seatLabel(at)} — assessor`}
            value={seat}
            onChange={(config) => setSeat(at, config)}
            role={kind === 'debate' ? 'debate-seat' : 'review-seat'}
            toolFree={kind === 'debate' && !repoPath.trim()}
            personaPlaceholder={
              at >= 2
                ? 'e.g. security-first assessor (optional)'
                : kind === 'review'
                  ? at === 0
                    ? 'Cartographer persona (optional)'
                    : 'Reviewer persona (optional)'
                  : at === 0
                    ? 'e.g. pragmatic staff engineer'
                    : 'e.g. risk-first architect'
            }
          />
          {at >= 2 ? (
            <button
              className="btn btn--sm"
              style={{ position: 'absolute', top: 0, right: 0 }}
              title="Remove this assessor"
              onClick={() => removeSeat(at)}
            >
              <X size={12} strokeWidth={2} />
            </button>
          ) : null}
        </div>
      ))}

      {participants.length < MAX_SEATS ? (
        <button className="btn" style={{ alignSelf: 'flex-start' }} onClick={addSeat}>
          <Plus size={12} strokeWidth={2} />
          Add an assessor
        </button>
      ) : null}

      {participants.length > 2 ? (
        <div className="field__hint">
          Assessors do not speak in the exchange. Each one follows it and records its own
          independent verdict at the close — disagreement among the bench lowers the recorded
          confidence, exactly as it does between the two debaters.
        </div>
      ) : null}

      {repeatedVendor ? (
        <div className="gate">
          <div className="gate__title">More than one seat runs the same CLI</div>
          <div className="gate__body">
            Instances of the same model family share the same blind spots, so their agreement is
            weaker evidence than it looks. Mix different CLIs across the seats unless you
            specifically want a same-model comparison.
          </div>
        </div>
      ) : null}

      {!needsRepo && !repoPath ? (
        <div className="field__hint">
          With no repository attached every seat runs entirely tool-free — cheaper, and none of
          them can reach your filesystem at all.
        </div>
      ) : null}

      <div className="field__hint">
        Runs through your local <span className="mono">claude</span>,{' '}
        <span className="mono">codex</span> and <span className="mono">agy</span> CLIs, against the
        subscriptions they are already signed in to. Parley never asks for an API key.
      </div>
    </Dialog>
  )
}
