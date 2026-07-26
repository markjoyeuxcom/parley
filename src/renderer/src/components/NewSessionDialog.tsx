import { useState, type ReactNode } from 'react'
import { FolderOpen } from 'lucide-react'
import type { AgentConfig, Session, SessionKind } from '@shared/domain'
import { api } from '../lib/api'
import { shortPath } from '../lib/format'
import { useStore } from '../state'
import { AgentPicker, defaultAgentA, defaultAgentB } from './AgentPicker'
import { Dialog, Field } from './ui'

export function NewSessionDialog({
  initialKind = 'debate',
  onClose,
  onStarted,
}: {
  initialKind?: SessionKind
  onClose: () => void
  onStarted: (session: Session) => void
}): ReactNode {
  const { attempt } = useStore()
  const [kind, setKind] = useState<SessionKind>(initialKind)
  const [matter, setMatter] = useState('')
  const [project, setProject] = useState('')
  const [repoPath, setRepoPath] = useState('')
  const [maxTurns, setMaxTurns] = useState(6)
  const [agentA, setAgentA] = useState<AgentConfig>(defaultAgentA)
  const [agentB, setAgentB] = useState<AgentConfig>(defaultAgentB)
  const [busy, setBusy] = useState(false)

  const sameVendor = agentA.vendor === agentB.vendor
  const needsRepo = kind === 'review'
  const canStart = matter.trim().length > 0 && (!needsRepo || repoPath.trim().length > 0) && !busy

  const start = async (): Promise<void> => {
    setBusy(true)
    const session = await attempt(() =>
      api.startSession({
        kind,
        matter: matter.trim(),
        project: project.trim(),
        repoPath: repoPath.trim() || null,
        agentA,
        agentB,
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

  return (
    <Dialog
      title="New session"
      subtitle="Two CLIs from different model families work the question independently, then each records its own verdict."
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
            ? 'What should the reviewers focus on? Both read the repository; neither can modify it.'
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
          <input
            className="input"
            placeholder="Ledger"
            value={project}
            onChange={(event) => setProject(event.target.value)}
          />
        </Field>

        <Field
          label={needsRepo ? 'Repository (required)' : 'Repository (optional)'}
          hint={
            needsRepo
              ? 'Read-only. Claude gets Read, Glob and Grep; Codex runs in its read-only sandbox.'
              : 'Attach one to let both sides cite real code.'
          }
        >
          <button className="btn" style={{ justifyContent: 'flex-start' }} onClick={() => void chooseFolder()}>
            <FolderOpen size={12} strokeWidth={2} />
            {repoPath ? shortPath(repoPath) : 'Choose folder'}
          </button>
        </Field>
      </div>

      {kind === 'debate' ? (
        <Field label={`Exchange length — ${maxTurns} turns`} hint="Plus one independent verdict from each side.">
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

      <AgentPicker
        label="Side A"
        value={agentA}
        onChange={setAgentA}
        personaPlaceholder={kind === 'review' ? 'Cartographer persona (optional)' : 'e.g. pragmatic staff engineer'}
      />
      <AgentPicker
        label="Side B"
        value={agentB}
        onChange={setAgentB}
        personaPlaceholder={kind === 'review' ? 'Reviewer persona (optional)' : 'e.g. risk-first architect'}
      />

      {sameVendor ? (
        <div className="gate">
          <div className="gate__title">Both sides are the same CLI</div>
          <div className="gate__body">
            Two instances of the same model family share the same blind spots, so the cross-check is
            much weaker. Pair Claude against Codex unless you specifically want a same-model
            comparison.
          </div>
        </div>
      ) : null}

      {!needsRepo && !repoPath ? (
        <div className="field__hint">
          With no repository attached both sides run entirely tool-free — cheaper, and they cannot
          reach your filesystem at all.
        </div>
      ) : null}

      <div className="field__hint">
        Runs through your local <span className="mono">claude</span> and{' '}
        <span className="mono">codex</span> CLIs, against the subscriptions they are already signed
        in to. Parley never asks for an API key.
      </div>
    </Dialog>
  )
}
