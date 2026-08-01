import { useEffect, useState, type ReactNode } from 'react'
import { Compass, Check } from 'lucide-react'
import type { Session } from '@shared/domain'
import type { JourneyView } from '@shared/ipc'
import {
  JOURNEY_STAGES,
  journeyStep,
  STAGE_PROMPT,
  STAGE_TITLE,
  type JourneyStage,
} from '@shared/journey'
import { api } from '../lib/api'
import { useStore } from '../state'
import { NewSessionDialog } from './NewSessionDialog'
import { NewWorkspaceDialog } from './NewWorkspaceDialog'
import { NewPlanDialog } from './PlanPanel'
import { Chip, Dialog, Empty, Field, Label } from './ui'

/**
 * Building a new app, guided.
 *
 * The panel adds no capability. Each stage opens the ordinary control for
 * that step — a debate, the workspace creator, the plan dialog, a review —
 * and records what came back, so the sequence is remembered without any of
 * it becoming automatic. Every gate those controls carry is still the gate.
 *
 * It mounts those dialogs itself rather than knocking on another surface,
 * because it needs what they return: the link is the entire point.
 */

export function NewJourneyDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: () => void
}): ReactNode {
  const { attempt } = useStore()
  const [name, setName] = useState('')
  const [brief, setBrief] = useState('')

  return (
    <Dialog
      title="Build a new app"
      subtitle="Six steps, each one an ordinary Parley action. Nothing here writes on its own."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            disabled={!name.trim()}
            onClick={() => {
              void attempt(() => api.createJourney(name.trim(), brief.trim())).then((made) => {
                if (made) onCreated()
              })
            }}
          >
            Start
          </button>
        </>
      }
    >
      <Field label="What is it called" hint="Used for the project folder later.">
        <input
          className="input"
          autoFocus
          value={name}
          placeholder="Recipe box"
          onChange={(event) => setName(event.target.value)}
        />
      </Field>
      <Field
        label="What do you want to build"
        hint="Your own words. This becomes the matter of the debate that challenges it — you can edit it before that runs."
      >
        <textarea
          className="input"
          rows={5}
          value={brief}
          onChange={(event) => setBrief(event.target.value)}
        />
      </Field>
    </Dialog>
  )
}

export function JourneyPanel(): ReactNode {
  const { state, dispatch, attempt, notify, openSession } = useStore()
  const [views, setViews] = useState<JourneyView[]>([])
  const [starting, setStarting] = useState(false)

  const refresh = (): void => {
    void api
      .listJourneys()
      .then((next) => setViews(Array.isArray(next) ? next : []))
      .catch(() => {})
  }
  // Re-read whenever anything the stages watch could have moved.
  useEffect(refresh, [state.plansVersion, state.repoActivityVersion, state.workspaces])

  return (
    <>
      <section className="panel foreman-panel">
        <header className="panel__header">
          <Label>Building something new</Label>
          <span className="spacer" />
          <button className="btn btn--sm" onClick={() => setStarting(true)}>
            <Compass size={12} strokeWidth={2} />
            Build an app
          </button>
        </header>
        <div className="panel__body panel__body--flush">
          {views.length === 0 ? (
            <Empty
              compact
              title="No app in progress."
              body="A guided build takes you from an idea to a reviewed app, one ordinary step at a time."
            />
          ) : (
            views.map((view) => (
              <JourneyRow
                key={view.journey.id}
                view={view}
                onChanged={refresh}
                onOpenSession={(sessionId) => {
                  dispatch({ type: 'surface', surface: 'parley' })
                  void openSession(sessionId)
                }}
                onOpenRepo={(repoPath) =>
                  dispatch({ type: 'focusBacklogRepo', repoPath, tab: 'overview' })
                }
                onNotify={notify}
                attempt={attempt}
              />
            ))
          )}
        </div>
      </section>

      {starting ? (
        <NewJourneyDialog
          onClose={() => setStarting(false)}
          onCreated={() => {
            setStarting(false)
            refresh()
          }}
        />
      ) : null}
    </>
  )
}

function JourneyRow({
  view,
  onChanged,
  onOpenSession,
  onOpenRepo,
  onNotify,
  attempt,
}: {
  view: JourneyView
  onChanged: () => void
  onOpenSession: (sessionId: string) => void
  onOpenRepo: (repoPath: string) => void
  onNotify: (level: 'info' | 'warn' | 'error', message: string) => void
  attempt: <T>(run: () => Promise<T>) => Promise<T | null>
}): ReactNode {
  const { journey, stage, progress, repoPath } = view
  const [editingBrief, setEditingBrief] = useState(false)
  const [brief, setBrief] = useState(journey.brief)
  const [dialog, setDialog] = useState<'challenge' | 'foundation' | 'build' | 'harden' | null>(null)
  const step = journeyStep(stage)

  const link = (patch: Parameters<typeof api.updateJourney>[1]): void => {
    void attempt(() => api.updateJourney(journey.id, patch)).then((done) => {
      if (done) onChanged()
    })
  }

  return (
    <div className="list-item" style={{ cursor: 'default', display: 'block' }}>
      <div className="row row--tight">
        <span className="list-item__title">{journey.name}</span>
        <span className="spacer" />
        {stage === 'done' ? (
          <Chip tone="chip--pass">done</Chip>
        ) : (
          <Chip tone="chip--accent">
            step {step.index + 1} of {step.total} · {STAGE_TITLE[stage]}
          </Chip>
        )}
      </div>

      {/* The whole path, so the shape of the work is visible from the start. */}
      <div className="row row--tight" style={{ gap: 'var(--s2)', marginTop: 'var(--s2)' }}>
        {JOURNEY_STAGES.filter((entry) => entry !== 'done').map((entry) => {
          const done = journeyStep(entry).index < step.index
          const here = entry === stage
          return (
            <span
              key={entry}
              className={here ? 'chip chip--accent' : 'chip'}
              style={{ opacity: done || here ? 1 : 0.45 }}
              title={STAGE_PROMPT[entry]}
            >
              {done ? <Check size={10} strokeWidth={2.5} /> : null}
              {STAGE_TITLE[entry]}
            </span>
          )
        })}
      </div>

      <div className="list-item__meta" style={{ marginTop: 'var(--s3)' }}>
        {STAGE_PROMPT[stage]}
      </div>

      <div className="row" style={{ marginTop: 'var(--s3)', gap: 'var(--s3)' }}>
        {stage === 'brief' ? (
          <button className="btn btn--sm" onClick={() => setEditingBrief(true)}>
            Write the brief
          </button>
        ) : null}
        {stage === 'challenge' ? (
          journey.sessionId ? (
            <button className="btn btn--sm" onClick={() => onOpenSession(journey.sessionId!)}>
              Open the debate
            </button>
          ) : (
            <button className="btn btn--sm" onClick={() => setDialog('challenge')}>
              Challenge the brief
            </button>
          )
        ) : null}
        {stage === 'foundation' ? (
          <button className="btn btn--sm" onClick={() => setDialog('foundation')}>
            Create the project
          </button>
        ) : null}
        {stage === 'build' ? (
          journey.planId ? (
            <button
              className="btn btn--sm"
              onClick={() => repoPath && onOpenRepo(repoPath)}
              disabled={!repoPath}
            >
              Open the plan
            </button>
          ) : (
            <button className="btn btn--sm" onClick={() => setDialog('build')}>
              Plan the build
            </button>
          )
        ) : null}
        {stage === 'preview' || stage === 'done' ? (
          <button
            className="btn btn--sm"
            onClick={() => repoPath && onOpenRepo(repoPath)}
            disabled={!repoPath}
          >
            Open the project
          </button>
        ) : null}
        {stage === 'harden' ? (
          journey.hardenSessionId ? (
            <button className="btn btn--sm" onClick={() => onOpenSession(journey.hardenSessionId!)}>
              Open the review
            </button>
          ) : (
            <button className="btn btn--sm" onClick={() => setDialog('harden')}>
              Review what exists
            </button>
          )
        ) : null}

        <span className="spacer" />
        <button
          className="btn btn--subtle btn--sm"
          title="Removes the guide. Everything it linked — the debate, the project, the plan — stays."
          onClick={() => {
            void attempt(() => api.deleteJourney(journey.id)).then((done) => {
              if (done) {
                onNotify('info', 'Guide removed. Everything it linked is still here.')
                onChanged()
              }
            })
          }}
        >
          Remove guide
        </button>
      </div>

      {editingBrief ? (
        <Dialog
          title="The brief"
          subtitle="Your own words. The challenge debate argues about exactly this."
          onClose={() => setEditingBrief(false)}
          footer={
            <>
              <button className="btn" onClick={() => setEditingBrief(false)}>
                Cancel
              </button>
              <button
                className="btn btn--primary"
                disabled={!brief.trim()}
                onClick={() => {
                  setEditingBrief(false)
                  link({ brief: brief.trim() })
                }}
              >
                Save
              </button>
            </>
          }
        >
          <Field label="What do you want to build">
            <textarea
              className="input"
              rows={6}
              autoFocus
              value={brief}
              onChange={(event) => setBrief(event.target.value)}
            />
          </Field>
        </Dialog>
      ) : null}

      {dialog === 'challenge' ? (
        <NewSessionDialog
          initialKind="debate"
          initialMatter={journey.brief}
          onClose={() => setDialog(null)}
          onStarted={(session: Session) => {
            setDialog(null)
            link({ sessionId: session.id })
          }}
        />
      ) : null}

      {dialog === 'foundation' ? (
        <NewWorkspaceDialog
          onClose={() => setDialog(null)}
          onCreated={(workspace) => {
            setDialog(null)
            link({ workspaceId: workspace.id })
          }}
        />
      ) : null}

      {dialog === 'harden' && repoPath ? (
        <NewSessionDialog
          initialKind="review"
          initialRepoPath={repoPath}
          initialMatter={`Review what was built for: ${journey.brief}`}
          onClose={() => setDialog(null)}
          onStarted={(session: Session) => {
            setDialog(null)
            link({ hardenSessionId: session.id })
          }}
        />
      ) : null}

      {dialog === 'build' ? (
        <BuildPlanDialog
          view={view}
          onClose={() => setDialog(null)}
          onPlanned={(planId) => {
            setDialog(null)
            link({ planId })
          }}
        />
      ) : null}

      {progress.hasBrief && stage !== 'brief' ? (
        <details style={{ marginTop: 'var(--s3)' }}>
          <summary className="field__hint" style={{ cursor: 'pointer' }}>
            The brief
          </summary>
          <div className="list-item__meta" style={{ whiteSpace: 'pre-wrap' }}>
            {journey.brief}
          </div>
        </details>
      ) : null}
    </div>
  )
}

/**
 * The build stage's plan dialog.
 *
 * A plan is drafted from a verdict, so this needs the challenge session the
 * journey already holds — the debate that argued the brief is exactly the
 * decision the build should implement.
 */
function BuildPlanDialog({
  view,
  onClose,
  onPlanned,
}: {
  view: JourneyView
  onClose: () => void
  onPlanned: (planId: string) => void
}): ReactNode {
  const { attempt } = useStore()
  const [session, setSession] = useState<Session | null>(null)

  useEffect(() => {
    const sessionId = view.journey.sessionId
    if (!sessionId) return
    void attempt(() => api.getSession(sessionId)).then((detail) => {
      if (detail) setSession(detail.session)
    })
  }, [attempt, view.journey.sessionId])

  if (!session) return null
  return (
    <NewPlanDialog
      session={session}
      initialRepoPath={view.repoPath ?? undefined}
      initialIsolation="worktree"
      initialNote={`Build this in vertical slices — each milestone should leave the app runnable and previewable. The brief: ${view.journey.brief}`}
      onClose={onClose}
      onCreated={(detail) => onPlanned(detail.plan.id)}
    />
  )
}
