import { useState, type ReactNode } from 'react'
import { FolderOpen, Pause, Play, Plus, ShieldCheck, Square } from 'lucide-react'
import type { AgentConfig, Capability, Loop, LoopExitKind } from '@shared/domain'
import { api } from '../lib/api'
import { compactNumber, firstLine, formatDuration, formatMinutes, formatTokens, relativeTime, shortPath, statusTone } from '../lib/format'
import { useStore } from '../state'
import { AgentPicker } from '../components/AgentPicker'
import { Chip, Dialog, Dot, Empty, Field, Label, Panel, Spinner } from '../components/ui'
import { RunActivity } from '../components/RunActivity'

export function LoopsSurface(): ReactNode {
  const { state, openLoop, refreshLoops } = useStore()
  const [showNew, setShowNew] = useState(false)

  return (
    <div className="workspace">
      <aside className="sidebar">
        <div className="sidebar__header">
          <Label>Loops</Label>
          <button className="btn btn--subtle btn--icon btn--sm" onClick={() => setShowNew(true)} title="New loop">
            <Plus size={13} strokeWidth={2} />
          </button>
        </div>

        <div className="scroll-y">
          {state.loops.length === 0 ? (
            <div style={{ padding: 'var(--s6)' }} className="field__hint">
              No loops yet. A loop runs until a condition Parley can observe is met — or until a cap
              stops it.
            </div>
          ) : (
            <div className="list">
              {state.loops.map((loop) => {
                const tone = statusTone(loop.status)
                return (
                  <button
                    key={loop.id}
                    className={`list-item ${loop.id === state.activeLoopId ? 'is-active' : ''}`}
                    onClick={() => void openLoop(loop.id)}
                  >
                    <div className="list-item__top">
                      {loop.status === 'running' ? (
                        <Dot tone="dot--live" />
                      ) : (
                        <Dot tone={tone.tone.replace('chip--', 'dot--')} />
                      )}
                      <span className="list-item__title">{firstLine(loop.goal, 60)}</span>
                    </div>
                    <div className="list-item__meta">
                      {loop.mock ? <Chip tone="chip--caution">mock</Chip> : null}
                      <span className="tnum">
                        {loop.iterationCount}/{loop.caps.maxIterations}
                      </span>
                      <span>·</span>
                      <span>{relativeTime(loop.startedAt)}</span>
                    </div>
                  </button>
                )
              })}
            </div>
          )}
        </div>
      </aside>

      <div className="pane-column">
        {state.activeLoopId ? (
          <LoopView key={state.activeLoopId} />
        ) : (
          <Empty
            title="Nothing selected"
            body="A loop keeps working toward a goal, but it never decides for itself that it is finished. Either a real command exits zero, or the other vendor's model checks the repository."
            action={
              <button className="btn btn--primary" onClick={() => setShowNew(true)}>
                <Plus size={12} strokeWidth={2} />
                New loop
              </button>
            }
          />
        )}
      </div>

      {showNew ? (
        <NewLoopDialog
          onClose={() => setShowNew(false)}
          onCreated={(loop) => {
            void refreshLoops()
            void openLoop(loop.id)
          }}
        />
      ) : null}
    </div>
  )
}

function LoopView(): ReactNode {
  const { state, attempt } = useStore()
  const detail = state.loopDetail

  if (!detail) {
    return (
      <div className="empty">
        <Spinner />
      </div>
    )
  }

  const { loop, iterations } = detail
  const tone = statusTone(loop.status)
  const running = loop.status === 'running'
  const paused = loop.status === 'paused'
  const idle = loop.status === 'idle'

  const elapsed = (loop.endedAt ?? Date.now()) - loop.startedAt
  const iterationPct = (loop.iterationCount / loop.caps.maxIterations) * 100
  const timePct = (elapsed / loop.caps.maxWallClockMs) * 100
  const spendPct = loop.caps.maxSpendUsd > 0 ? (loop.usage.costUsd / loop.caps.maxSpendUsd) * 100 : 0

  return (
    <>
      <div className="bar">
        <Chip tone={tone.tone}>{tone.label}</Chip>
        {loop.mock ? (
          <Chip tone="chip--caution" title="Produced by the mock adapters — not real work">
            mock
          </Chip>
        ) : null}
        <span className="truncate" style={{ fontSize: 'var(--text-small)', fontWeight: 530, minWidth: 0 }}>
          {firstLine(loop.goal, 100)}
        </span>
        <div className="spacer" />
        <Chip tone="chip--mono" title={loop.repoPath}>
          {shortPath(loop.repoPath)}
        </Chip>
        <Chip tone={loop.capability === 'write' ? 'chip--caution' : ''}>
          {loop.capability === 'write' ? 'can write' : 'read only'}
        </Chip>
        <span className="dimmer tnum" style={{ fontSize: 'var(--text-tiny)' }}>
          {formatTokens(loop.usage)}
        </span>

        {idle ? <StartButton loop={loop} /> : null}

        {running ? (
          <button className="btn btn--sm" onClick={() => void attempt(() => api.pauseLoop(loop.id))}>
            <Pause size={12} strokeWidth={2} />
            Pause
          </button>
        ) : paused ? (
          <button className="btn btn--sm" onClick={() => void attempt(() => api.resumeLoop(loop.id))}>
            <Play size={12} strokeWidth={2} />
            Resume
          </button>
        ) : null}

        {running || paused ? (
          <button
            className="btn btn--sm btn--danger"
            onClick={() => void attempt(() => api.killLoop(loop.id))}
            title="Kill the loop and the in-flight CLI immediately"
          >
            <Square size={11} strokeWidth={2.5} />
            Kill
          </button>
        ) : null}
      </div>

      <div className="scroll-y">
        <div
          style={{
            padding: 'var(--s7) var(--s8)',
            display: 'flex',
            flexDirection: 'column',
            gap: 'var(--s6)',
            maxWidth: 900,
            margin: '0 auto',
          }}
        >
          {/* Caps are shown as consumption, not configuration: what matters while
              a loop runs is how close it is to being stopped. */}
          <div className="caps">
            <Cap
              label="Iterations"
              value={`${loop.iterationCount} / ${loop.caps.maxIterations}`}
              pct={iterationPct}
            />
            <Cap
              label="Elapsed"
              value={`${formatDuration(elapsed)} / ${formatMinutes(loop.caps.maxWallClockMs)}`}
              pct={timePct}
            />
            <Cap
              label="Reported spend"
              value={
                loop.caps.maxSpendUsd > 0
                  ? `$${loop.usage.costUsd.toFixed(2)} / $${loop.caps.maxSpendUsd.toFixed(2)}`
                  : 'no cap'
              }
              pct={spendPct}
            />
          </div>

          <RunActivity subjectId={loop.id} live={running} />

          <Panel title="Exit condition" >
            {loop.exit.kind === 'command' ? (
              <div className="stack stack--tight">
                <div className="mono selectable">{loop.exit.command}</div>
                <div className="field__hint">
                  Run by Parley after each iteration, without a shell. Exit code zero ends the loop —
                  the agent is never asked whether it is finished.
                </div>
              </div>
            ) : (
              <div className="stack stack--tight">
                <div className="milestone__intent">{loop.exit.criterion}</div>
                <div className="field__hint">
                  Checked by <strong>{loop.verifier.vendor}</strong>, reading the repository. The worker
                  is <strong>{loop.worker.vendor}</strong>, so the check comes from a different model
                  family.
                </div>
              </div>
            )}
          </Panel>

          {loop.stopReason ? (
            <div
              className={`audit-note ${
                loop.status === 'succeeded' ? 'audit-note--accept' : loop.status === 'exhausted' ? 'audit-note--revise' : 'audit-note--reject'
              }`}
            >
              <strong>
                {loop.status === 'succeeded'
                  ? 'Goal met:'
                  : loop.status === 'exhausted'
                    ? 'Stopped by a cap, goal not met:'
                    : 'Stopped:'}
              </strong>{' '}
              {loop.stopReason}
            </div>
          ) : null}

          <Panel title={`Iterations — ${iterations.length}`} flush>
            {iterations.length === 0 ? (
              <div className="row" style={{ padding: 'var(--s6)' }}>
                {running ? <Spinner /> : null}
                <span className="dim" style={{ fontSize: 'var(--text-small)' }}>
                  {running ? 'Working…' : 'Not started.'}
                </span>
              </div>
            ) : (
              <div className="iterations">
                {iterations.map((iteration) => (
                  <div className="iteration" key={iteration.id}>
                    <div className="iteration__index tnum">{iteration.index + 1}</div>
                    <div className="iteration__body">
                      <div className="row row--tight">
                        <Chip tone={iteration.vendor === 'claude' ? 'chip--a' : 'chip--b'}>
                          {iteration.vendor}
                        </Chip>
                        {iteration.endedAt ? (
                          <Chip tone={iteration.exitMet ? 'chip--pass' : ''}>
                            {iteration.exitMet ? 'goal met' : 'not met'}
                          </Chip>
                        ) : (
                          <Spinner />
                        )}
                        {iteration.error ? <Chip tone="chip--fail">failed</Chip> : null}
                        <div className="spacer" />
                        <span className="dimmer tnum" style={{ fontSize: 'var(--text-micro)' }}>
                          {compactNumber(iteration.usage.outputTokens)} out
                        </span>
                      </div>

                      {iteration.summary ? (
                        <div className="iteration__summary">{iteration.summary}</div>
                      ) : null}

                      {iteration.error ? (
                        <div className="iteration__summary" style={{ color: 'var(--fail)' }}>
                          {iteration.error}
                        </div>
                      ) : null}

                      {iteration.exitDetail ? (
                        <div className="iteration__check">{iteration.exitDetail}</div>
                      ) : null}
                    </div>
                  </div>
                ))}
              </div>
            )}
          </Panel>
        </div>
      </div>
    </>
  )
}

function Cap({ label, value, pct }: { label: string; value: string; pct: number }): ReactNode {
  const clamped = Math.max(0, Math.min(100, pct))
  const state = clamped >= 100 ? 'is-spent' : clamped >= 75 ? 'is-near' : ''
  return (
    <div className="cap">
      <div className="stat__label">{label}</div>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className="tnum" style={{ fontSize: 'var(--text-small)', fontWeight: 550 }}>
          {value}
        </span>
      </div>
      <div className="cap__bar">
        <div className={`cap__fill ${state}`} style={{ width: `${clamped}%` }} />
      </div>
    </div>
  )
}

/** Starting a write-capable loop grants and immediately spends an approval. */
function StartButton({ loop }: { loop: Loop }): ReactNode {
  const { attempt, openLoop } = useStore()
  const [busy, setBusy] = useState(false)

  const start = async (): Promise<void> => {
    setBusy(true)
    let approvalId: string | null = null
    if (loop.capability === 'write') {
      const approval = await attempt(() =>
        api.grantApproval('loop.write', loop.id, `Allow an autonomous loop to write to ${loop.repoPath}`),
      )
      if (!approval) {
        setBusy(false)
        return
      }
      approvalId = approval.id
    }
    const started = await attempt(() => api.startLoop(loop.id, approvalId))
    setBusy(false)
    if (started) void openLoop(loop.id)
  }

  return (
    <button className="btn btn--primary btn--sm" disabled={busy} onClick={() => void start()}>
      {loop.capability === 'write' ? <ShieldCheck size={12} strokeWidth={2} /> : <Play size={12} strokeWidth={2} />}
      {busy ? 'Starting…' : loop.capability === 'write' ? 'Approve and start' : 'Start'}
    </button>
  )
}

function NewLoopDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (loop: Loop) => void
}): ReactNode {
  const { attempt } = useStore()
  const [goal, setGoal] = useState('')
  const [repoPath, setRepoPath] = useState('')
  const [worker, setWorker] = useState<AgentConfig>({ vendor: 'codex', model: '', effort: 'high', persona: '' })
  const [verifier, setVerifier] = useState<AgentConfig>({ vendor: 'claude', model: '', effort: 'high', persona: '' })
  const [exitKind, setExitKind] = useState<LoopExitKind>('command')
  const [command, setCommand] = useState('npm test')
  const [criterion, setCriterion] = useState('')
  const [capability, setCapability] = useState<Capability>('read')
  const [maxIterations, setMaxIterations] = useState(8)
  const [maxMinutes, setMaxMinutes] = useState(45)
  const [maxSpend, setMaxSpend] = useState(0)
  const [busy, setBusy] = useState(false)

  const canCreate =
    goal.trim().length > 0 &&
    repoPath.trim().length > 0 &&
    (exitKind === 'command' ? command.trim().length > 0 : criterion.trim().length > 0) &&
    !busy

  const create = async (): Promise<void> => {
    setBusy(true)
    const loop = await attempt(() =>
      api.createLoop({
        goal: goal.trim(),
        repoPath: repoPath.trim(),
        worker,
        verifier,
        exit: { kind: exitKind, command: command.trim(), criterion: criterion.trim() },
        caps: {
          maxIterations,
          maxSpendUsd: maxSpend,
          maxWallClockMs: maxMinutes * 60_000,
        },
        capability,
      }),
    )
    setBusy(false)
    if (loop) {
      onCreated(loop)
      onClose()
    }
  }

  const chooseFolder = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Choose the repository'))
    if (result?.path) setRepoPath(result.path)
  }

  return (
    <Dialog
      title="New loop"
      subtitle="An autonomous loop under caps Parley enforces. Creating it does not start it."
      onClose={onClose}
      wide
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--primary" disabled={!canCreate} onClick={() => void create()}>
            {busy ? 'Creating…' : 'Create loop'}
          </button>
        </>
      }
    >
      <Field label="Goal" hint="What the loop is working toward. Be specific about what 'done' means.">
        <textarea
          className="textarea"
          rows={3}
          autoFocus
          placeholder="Get the integration suite green without weakening any assertion."
          value={goal}
          onChange={(event) => setGoal(event.target.value)}
        />
      </Field>

      <Field label="Repository">
        <button className="btn" style={{ justifyContent: 'flex-start' }} onClick={() => void chooseFolder()}>
          <FolderOpen size={12} strokeWidth={2} />
          {repoPath ? shortPath(repoPath) : 'Choose folder'}
        </button>
      </Field>

      <hr className="divider" />

      <div className="stack stack--tight">
        <div className="label">How the loop ends</div>
        <div className="segmented" style={{ alignSelf: 'flex-start' }}>
          <button
            className={`segmented__item ${exitKind === 'command' ? 'is-active' : ''}`}
            onClick={() => setExitKind('command')}
          >
            A command exits 0
          </button>
          <button
            className={`segmented__item ${exitKind === 'review' ? 'is-active' : ''}`}
            onClick={() => setExitKind('review')}
          >
            The other model agrees
          </button>
        </div>

        {exitKind === 'command' ? (
          <Field
            hint="Run by Parley without a shell, so no pipes, redirection or variables. Put anything more complex in a script."
          >
            <input
              className="input mono"
              placeholder="npm test"
              value={command}
              onChange={(event) => setCommand(event.target.value)}
            />
          </Field>
        ) : (
          <Field hint={`Checked by ${verifier.vendor} against the repository — never by the worker itself.`}>
            <textarea
              className="textarea"
              rows={2}
              placeholder="Every public function in src/api has a test covering its error path."
              value={criterion}
              onChange={(event) => setCriterion(event.target.value)}
            />
          </Field>
        )}
      </div>

      <hr className="divider" />

      <div className="stack stack--tight">
        <div className="label">Caps — enforced by Parley, before each iteration</div>
        <div className="field-row field-row--3">
          <Field label="Max iterations">
            <input
              className="input tnum"
              type="number"
              min={1}
              max={100}
              value={maxIterations}
              onChange={(event) => setMaxIterations(Math.max(1, Number(event.target.value) || 1))}
            />
          </Field>
          <Field label="Max minutes">
            <input
              className="input tnum"
              type="number"
              min={1}
              value={maxMinutes}
              onChange={(event) => setMaxMinutes(Math.max(1, Number(event.target.value) || 1))}
            />
          </Field>
          <Field label="Max spend (USD)" hint="0 = no cap">
            <input
              className="input tnum"
              type="number"
              min={0}
              step={0.5}
              value={maxSpend}
              onChange={(event) => setMaxSpend(Math.max(0, Number(event.target.value) || 0))}
            />
          </Field>
        </div>
        <div className="field__hint">
          Subscription plans report only a notional cost, and Codex reports none — so the iteration and
          time caps are the ones that will actually stop a runaway loop.
        </div>
      </div>

      <hr className="divider" />

      <AgentPicker
        label="Worker — does the work"
        value={worker}
        onChange={setWorker}
        role="loop-worker"
      />
      <AgentPicker
        label="Verifier — decides whether the goal is met"
        value={verifier}
        onChange={setVerifier}
        role="loop-verifier"
      />

      {worker.vendor === verifier.vendor && exitKind === 'review' ? (
        <div className="gate">
          <div className="gate__title">The verifier shares the worker's model family</div>
          <div className="gate__body">
            It will be judging work produced by a model with the same blind spots. Pair Claude against
            Codex, or use a command-based exit condition instead.
          </div>
        </div>
      ) : null}

      <hr className="divider" />

      <Field label="Repository access">
        <select
          className="select"
          value={capability}
          onChange={(event) => setCapability(event.target.value as Capability)}
        >
          <option value="read">Read only — the loop can inspect but not modify</option>
          <option value="write">Write — the loop can change the repository</option>
        </select>
      </Field>

      {capability === 'write' ? (
        <div className="gate">
          <div className="gate__title">This loop will be able to write to your repository</div>
          <div className="gate__body">
            You will be asked to approve once, when you start it. That approval is single-use, so
            restarting the loop asks again. Nothing is committed — changes are left in the working tree.
          </div>
        </div>
      ) : null}
    </Dialog>
  )
}
