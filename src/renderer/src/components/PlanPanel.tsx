import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ChevronDown, ChevronRight, FolderOpen, Play, ShieldCheck, Square } from 'lucide-react'
import type {
  AgentConfig,
  BacklogItem,
  Id,
  Milestone,
  Session,
  TestResult,
  WorkPlan,
  WorkPlanKind,
} from '@shared/domain'
import type { LedgerEntry } from '@shared/ipc'
import { api, type PlanDetail } from '../lib/api'
import { formatDuration, shortPath, statusTone, verificationState } from '../lib/format'
import { approvalPermission } from '../lib/ledgerView'
import { shellMetacharsIn } from '@shared/command'
import { executionRefusal } from '@shared/execution'
import { useStore, type Surface } from '../state'
import { AgentPicker } from './AgentPicker'
import { BulkDispositionControl, OccurrenceDispositionControl } from './FindingsLedgerPanel'
import { Chip, Dialog, Field, Label, Panel, Spinner } from './ui'
import { RunActivity } from './RunActivity'
import { PlanProgress } from './PlanProgress'

/**
 * Shows both streams of a failed command.
 *
 * Never pick one over the other. Compilers and test runners routinely put the
 * summary on stdout and the actual cause on stderr — `go test` prints
 * "FAIL [setup failed]" to stdout while the compile error that explains it goes
 * to stderr — so showing either alone can hide the only useful line.
 */
function combineOutput(stdout: string, stderr: string, lines = 24): string {
  const parts: string[] = []
  if (stdout.trim()) parts.push(stdout.trim())
  if (stderr.trim()) parts.push(stderr.trim())
  if (!parts.length) return '(no output)'
  return parts.join('\n').split('\n').slice(-lines).join('\n')
}

const KINDS: Array<{ id: WorkPlanKind; label: string; blurb: string }> = [
  { id: 'implementation', label: 'Implementation', blurb: 'Build what the verdict decided.' },
  { id: 'validation', label: 'Validation', blurb: 'Prove the decision holds, without changing behaviour.' },
  { id: 'remediation', label: 'Remediation', blurb: 'Fix the confirmed findings.' },
  { id: 'migration', label: 'Migration', blurb: 'Move from the old shape to the new one, reversibly.' },
  { id: 'research', label: 'Research', blurb: 'Answer what the session could not settle.' },
]

/**
 * Creates a work plan from a verdict.
 *
 * Roles default to opposing vendors and the dialog explains why: the planner, the
 * auditor, the executor and the reviewer are deliberately not all the same model.
 */
export function NewPlanDialog({
  session,
  onClose,
  onCreated,
  foremanProposalId = null,
  initialRepoPath,
  initialItems,
  initialIsolation,
  initialNote,
}: {
  session: Session
  onClose: () => void
  onCreated: (detail: PlanDetail) => void
  /** A pending foreman proposal this creation accepts, atomically. */
  foremanProposalId?: Id | null
  /** Preferred over session.repoPath: an anchor session's repo can be null
   * or a different repository entirely. */
  initialRepoPath?: string
  initialItems?: Id[]
  initialIsolation?: WorkPlan['isolation']
  initialNote?: string
}): ReactNode {
  const { attempt, state } = useStore()
  const [kind, setKind] = useState<WorkPlanKind>('implementation')
  const [repoPath, setRepoPath] = useState(initialRepoPath ?? session.repoPath ?? '')
  const [backlogChoices, setBacklogChoices] = useState<BacklogItem[]>([])
  const [selectedItems, setSelectedItems] = useState<ReadonlySet<Id>>(new Set())
  // One-shot: the proposal's selection seeds the picker only after the
  // choices arrive (unfetched ids would be invisible-but-submitted), and
  // only once — a later repo edit means the human took over.
  const seededItems = useRef(false)

  // The repo's open backlog, refetched when the target repo changes — and the
  // selection cleared with it, because a selection made against one repo must
  // not survive into another. Mock-matched: mock items are only plannable in
  // mock mode, and offering the others would only ever error. The clear stays
  // synchronous on purpose: a stale selection from the previous repo must
  // never be submittable during the fetch.
  useEffect(() => {
    setSelectedItems(new Set())
    const path = repoPath.trim()
    if (!path) {
      setBacklogChoices([])
      return
    }
    let cancelled = false
    api
      .listBacklogItems(path)
      .then((items) => {
        if (cancelled) return
        const choices = items.filter((item) => item.state === 'open' && item.mock === state.mock)
        setBacklogChoices(choices)
        if (!seededItems.current && initialItems?.length) {
          seededItems.current = true
          setSelectedItems(
            new Set(initialItems.filter((id) => choices.some((choice) => choice.id === id))),
          )
        }
      })
      .catch(() => setBacklogChoices([]))
    return () => {
      cancelled = true
    }
  }, [repoPath, state.mock, initialItems])

  const toggleItem = (id: Id): void => {
    setSelectedItems((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else if (next.size < 12) next.add(id)
      return next
    })
  }
  const [planner, setPlanner] = useState<AgentConfig>({
    vendor: 'claude',
    model: '',
    effort: 'max',
    persona: '',
  })
  const [executor, setExecutor] = useState<AgentConfig>({
    vendor: 'codex',
    model: '',
    effort: 'high',
    persona: '',
  })
  const [busy, setBusy] = useState(false)
  const [note, setNote] = useState(initialNote ?? '')
  const [isolation, setIsolation] = useState<WorkPlan['isolation']>(initialIsolation ?? 'checkout')
  const [setupCommand, setSetupCommand] = useState('')
  // Advisory: the plan will snapshot the repository's dev-container choice at
  // creation, and the person clicking Draft should see that before, not
  // after. Lookup failures stay quiet — the server snapshot is authoritative.
  const [containerOn, setContainerOn] = useState(false)
  useEffect(() => {
    const chosen = repoPath.trim()
    setContainerOn(false)
    if (!chosen) return
    let live = true
    void api
      .repoContainerStatus(chosen)
      .then((status) => {
        if (live) setContainerOn(status.enabled)
      })
      .catch(() => {})
    return () => {
      live = false
    }
  }, [repoPath])

  // Advisory mirror of the main-process rule: plans on Parley's own checkout
  // run in a worktree only. Trailing-slash-trimmed compare, not canonical —
  // the server re-checks canonically at create and again at execute, so a
  // miss here only costs a clearer error later, never a wider allowance.
  const trimSlash = (path: string): string => path.replace(/\/+$/, '')
  const isSelfRepo =
    state.selfRepoPath !== null &&
    repoPath.trim() !== '' &&
    trimSlash(repoPath.trim()) === trimSlash(state.selfRepoPath)

  // Flip rather than block: the moment the self repo is chosen, checkout stops
  // being a valid selection, and leaving the select pointing at a disabled
  // option would make the primary button fail server-side instead.
  useEffect(() => {
    if (isSelfRepo) setIsolation('worktree')
  }, [isSelfRepo])

  const reviewerVendor = planner.vendor === executor.vendor ? 'claude' : planner.vendor
  const create = async (): Promise<void> => {
    setBusy(true)
    const detail = await attempt(() =>
      api.createPlan({
        sessionId: session.id,
        kind,
        repoPath: repoPath.trim(),
        note,
        planner,
        executor,
        // The reviewer must not be the executor. Fixed here rather than offered
        // as an option, because a reviewer that wrote the diff is not a review.
        reviewer: { ...planner, vendor: reviewerVendor },
        isolation,
        setupCommand: isolation === 'worktree' ? setupCommand : '',
        backlogItemIds: [...selectedItems],
        foremanProposalId,
      }),
    )
    setBusy(false)
    if (detail) {
      onCreated(detail)
      onClose()
    }
  }

  const chooseFolder = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Choose the repository to change'))
    if (result?.path) setRepoPath(result.path)
  }

  return (
    <Dialog
      title="Plan the work"
      subtitle="Planning and auditing are read-only. Nothing is written until you approve a specific milestone."
      onClose={onClose}
      wide
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            disabled={busy || !repoPath.trim()}
            onClick={() => void create()}
          >
            {busy ? 'Planning…' : 'Draft and audit plan'}
          </button>
        </>
      }
    >
      <Field label="Workflow">
        <select className="select" value={kind} onChange={(event) => setKind(event.target.value as WorkPlanKind)}>
          {KINDS.map((option) => (
            <option key={option.id} value={option.id}>
              {option.label} — {option.blurb}
            </option>
          ))}
        </select>
      </Field>

      {/* Remediation gathers the recorded reviews from this session by itself —
          the findings live in the database, not the repository, so the planner
          could never have found them on its own. */}
      {kind === 'remediation' ? (
        <div className="audit-note">
          Every review recorded against a milestone in this session will be handed to the planner as
          the worklist. Add anything below that is not already in a review.
        </div>
      ) : null}

      <Field
        label="Notes for the planner (optional)"
        hint="Attributed separately, so the record still shows what the debate decided and what you added."
      >
        <textarea
          className="textarea"
          rows={3}
          placeholder={
            kind === 'remediation'
              ? 'Findings not captured in a review, or which of them to prioritise…'
              : 'Constraints or decisions the verdict does not cover…'
          }
          value={note}
          onChange={(event) => setNote(event.target.value)}
        />
      </Field>

      <Field label="Repository">
        <button className="btn" style={{ justifyContent: 'flex-start' }} onClick={() => void chooseFolder()}>
          <FolderOpen size={12} strokeWidth={2} />
          {repoPath ? shortPath(repoPath) : 'Choose folder'}
        </button>
      </Field>

      <Field
        label="Execution"
        hint={
          isSelfRepo
            ? "This is Parley's own repository — plans here run in a worktree only. An agent writing into the live app's source under it is the one uncontrolled case."
            : isolation === 'worktree'
              ? 'Milestones run on an isolated branch; each pass is committed there. Nothing reaches this checkout until you land the branch, fast-forward only.'
              : 'Milestones write into the checkout above and are left uncommitted, as before.'
        }
      >
        <select
          className="select"
          value={isolation}
          onChange={(event) => setIsolation(event.target.value as WorkPlan['isolation'])}
        >
          <option value="checkout" disabled={isSelfRepo}>
            {isSelfRepo
              ? 'In the checkout — unavailable for Parley itself'
              : 'In the checkout — work appears in your tree'}
          </option>
          <option value="worktree">In a worktree — isolated branch, landed by you</option>
        </select>
      </Field>

      {containerOn ? (
        <p className="dialog__note" style={{ fontSize: 'var(--text-small)', color: 'var(--text-tertiary)', margin: 0 }}>
          Verification commands run in this repository’s dev container — snapshotted onto the
          plan when you draft it.
        </p>
      ) : null}

      {backlogChoices.length ? (
        <Field
          label={`Backlog items (${selectedItems.size} selected, up to 12)`}
          hint="Selected items ride the brief and flip to planned; completing the plan proposes their closure for you to confirm."
        >
          <div className="backlog-pick">
            {backlogChoices.slice(0, 30).map((item) => (
              <label className="backlog-pick__row" key={item.id}>
                <input
                  type="checkbox"
                  checked={selectedItems.has(item.id)}
                  onChange={() => toggleItem(item.id)}
                />
                <span className="backlog-pick__title">{item.title}</span>
                {item.priority ? <Chip tone="chip--mono">{item.priority}</Chip> : null}
              </label>
            ))}
          </div>
        </Field>
      ) : null}

      {isolation === 'worktree' ? (
        <Field
          label="Worktree setup command (optional)"
          hint="Run once when the worktree is created — a fresh worktree has no node_modules, so without this the milestones' own test commands may not run. Shell-free, like a test command."
        >
          <input
            className="input"
            placeholder="npm ci"
            value={setupCommand}
            onChange={(event) => setSetupCommand(event.target.value)}
          />
        </Field>
      ) : null}

      <hr className="divider" />

      <AgentPicker
        label="Planner — reads and plans, never writes"
        value={planner}
        onChange={setPlanner}
        role="planner"
      />
      <AgentPicker
        label="Executor — writes, only after you approve"
        value={executor}
        onChange={setExecutor}
        role="executor"
      />

      <div className="audit-note">
        The plan is audited by <strong>{planner.vendor === 'claude' ? 'Codex' : 'Claude'}</strong> before
        you see it, and each finished milestone is reviewed by{' '}
        <strong>{executor.vendor === 'claude' ? 'Codex' : 'Claude'}</strong> — never by the agent that
        wrote it.
      </div>
    </Dialog>
  )
}

/** The audited pipeline for one plan, with a per-milestone approval gate. */
export function PlanPanel({
  detail,
  ledger,
  onRefresh,
  host,
}: {
  detail: PlanDetail
  /** Null means UNKNOWN — the gate fails closed on it, never open. */
  ledger: readonly LedgerEntry[] | null
  onRefresh: () => void
  /**
   * Which surface hosts this instance. Every surface stays mounted
   * permanently, so two PlanPanels can render the same open plan; without
   * this, both consume the approval knock and the hidden one strands an
   * invisible stale dialog whose Approve would spend a fresh approval.
   */
  host: Surface
}): ReactNode {
  const { plan, milestones } = detail
  const worktree = detail.worktree ?? null
  const tone = statusTone(plan.status)
  const [pendingApproval, setPendingApproval] = useState<Milestone | null>(null)
  const [granting, setGranting] = useState(false)
  const [landing, setLanding] = useState(false)
  const { attempt, notify, state, dispatch } = useStore()

  // The holds queue's deep link: a jump that names one of this plan's
  // milestones opens its approval dialog directly. Consumed exactly once —
  // cleared only when this panel actually owns the milestone AND is the
  // visible host, so a knock for another plan (or the other surface's
  // instance) is left standing for its owner to answer.
  useEffect(() => {
    if (state.surface !== host) return
    if (!state.focusMilestoneId) return
    const target = milestones.find((m) => m.id === state.focusMilestoneId)
    if (!target) return
    setPendingApproval(target)
    dispatch({ type: 'focusMilestone', milestoneId: null })
  }, [state.focusMilestoneId, state.surface, host, milestones, dispatch])

  const land = async (): Promise<void> => {
    setLanding(true)
    // Landing is the one moment isolated work reaches the checkout, so it is
    // recorded exactly like a write: a single-use approval, granted here and
    // spent by the act. The preflight runs before the spend, so a routine git
    // refusal never burns the grant.
    const summary =
      `Allow the branch ${worktree?.branch ?? 'parley/…'} to fast-forward ${plan.repoPath}. ` +
      'Single fast-forward only; git refuses if the checkout moved.'
    const approval = await attempt(() => api.grantApproval('plan.land', plan.id, summary))
    if (!approval) {
      setLanding(false)
      return
    }
    const result = await attempt(() => api.landPlan(plan.id, approval.id))
    setLanding(false)
    if (result) {
      notify(
        result.landed ? 'info' : 'warn',
        result.landed
          ? `Landed — ${shortPath(plan.repoPath)} fast-forwarded onto the plan branch. A smoke verification runs in the background.`
          : `Landing refused: ${result.detail}`,
      )
    }
    onRefresh()
  }

  /**
   * Closes an approval dialog whose milestone has ceased to exist.
   *
   * The correction stage does not patch milestones, it deletes them and writes
   * the corrected set — so any id held in component state can go stale while a
   * dialog is open. Approving from that dialog would be refused — milestone
   * grants go through the Manager, which checks the id resolves — but the
   * refusal would read as an opaque "no such milestone" about a row still
   * visible on screen. Closing the dialog and saying the plan was corrected is
   * the version of that refusal a person can act on.
   */
  useEffect(() => {
    if (!pendingApproval) return
    if (!milestones.some((m) => m.id === pendingApproval.id)) {
      setPendingApproval(null)
      notify('info', 'That milestone was rewritten while the plan was being corrected. Re-open it.')
    }
  }, [milestones, pendingApproval, notify])

  /**
   * Grants the approval, starts the run, and closes the dialog immediately.
   *
   * The run itself can take many minutes. Holding a modal open for its duration
   * would block the whole window while the milestone row directly behind it is
   * already reporting executing → testing → reviewing in real time. The await
   * continues after the dialog has gone; it lives here rather than in the dialog
   * so it is not tied to that component's lifetime.
   */
  const approveAndRun = async (milestone: Milestone): Promise<void> => {
    setGranting(true)
    // The persisted record of what was authorised, so it must name the
    // directory actually written: a worktree run never touches the checkout,
    // and an approval claiming it did would be wrong in the durable record.
    const containerNote = plan.container
      ? ' Verification commands run in the repository’s dev container.'
      : ''
    const summary =
      (plan.isolation === 'worktree'
        ? `Allow ${plan.executor.vendor} to write to an isolated worktree of ${plan.repoPath} for milestone ` +
          `${milestone.index + 1}: ${milestone.title}. Landing on the checkout is a separate decision.`
        : `Allow ${plan.executor.vendor} to write to ${plan.repoPath} for milestone ` +
          `${milestone.index + 1}: ${milestone.title}`) + containerNote

    const approval = await attempt(() => api.grantApproval('milestone.execute', milestone.id, summary))
    setGranting(false)
    if (!approval) return

    setPendingApproval(null)
    notify('info', `Milestone ${milestone.index + 1} started. You can keep working while it runs.`)

    const result = await attempt(() => api.runMilestone(milestone.id, approval.id))
    if (result) {
      notify(
        result.status === 'complete' ? 'info' : 'warn',
        result.status === 'complete'
          ? `Milestone ${milestone.index + 1} completed and passed review.`
          : `Milestone ${milestone.index + 1} did not pass. See the note on the milestone.`,
      )
    }
    onRefresh()
  }

  /**
   * Continues an interrupted run from its preserved state.
   *
   * Grants and spends a fresh single-use approval — deliberately identical in
   * ceremony to a run, because the crash-recovery stance is that persistence
   * buys cheapness, never a skipped gate. The summary records the resume
   * framing so the durable authorization says what was actually allowed.
   */
  const resumeAndRun = async (milestone: Milestone): Promise<void> => {
    setGranting(true)
    const summary =
      plan.isolation === 'worktree'
        ? `Allow ${plan.executor.vendor} to resume milestone ${milestone.index + 1} (${milestone.title}) in an isolated worktree of ${plan.repoPath}, continuing from its preserved run state. Landing on the checkout is a separate decision.`
        : `Allow ${plan.executor.vendor} to resume milestone ${milestone.index + 1} (${milestone.title}) in ${plan.repoPath}, continuing from its preserved run state`

    const approval = await attempt(() => api.grantApproval('milestone.execute', milestone.id, summary))
    setGranting(false)
    if (!approval) return

    setPendingApproval(null)
    notify('info', `Milestone ${milestone.index + 1} resuming. You can keep working while it runs.`)

    const result = await attempt(() => api.resumeMilestone(milestone.id, approval.id))
    if (result) {
      notify(
        result.status === 'complete' ? 'info' : 'warn',
        result.status === 'complete'
          ? `Milestone ${milestone.index + 1} completed and passed review.`
          : `Milestone ${milestone.index + 1} did not pass. See the note on the milestone.`,
      )
    }
    onRefresh()
  }

  /**
   * Verifies work that is already in the tree instead of executing.
   *
   * No approval is granted or spent: nothing is written. The deterministic tests
   * and the independent cross-vendor review still run, and the milestone is
   * recorded as adopted rather than authored.
   */
  const adoptExisting = async (milestone: Milestone): Promise<void> => {
    setGranting(true)
    setPendingApproval(null)
    notify('info', `Verifying the existing work for milestone ${milestone.index + 1}…`)

    const result = await attempt(() => api.adoptMilestone(milestone.id))
    setGranting(false)
    if (result) {
      notify(
        result.status === 'complete' ? 'info' : 'warn',
        result.status === 'complete'
          ? `Milestone ${milestone.index + 1} adopted — tests pass and the independent review accepted it.`
          : `The existing work for milestone ${milestone.index + 1} did not pass. See the note.`,
      )
    }
    onRefresh()
  }

  return (
    <>
      <Panel
        title={plan.title || `${plan.kind} plan`}
        flush
        actions={
          <>
            <Chip tone={tone.tone}>{tone.label}</Chip>
            {plan.mock ? (
              <Chip tone="chip--caution" title="Produced by the mock adapters — not real work">
                mock
              </Chip>
            ) : null}
            <Chip tone="chip--mono" title="Repository this plan changes">
              {shortPath(plan.repoPath)}
            </Chip>
          </>
        }
      >
        {/*
          A question the planner could not answer for itself. Shown before the
          milestones because nothing below it is settled until it is answered.
        */}
        {plan.status === 'awaiting-clarification' ? (
          <ClarificationPanel plan={plan} onAnswered={onRefresh} />
        ) : null}

        {/*
          The one moment isolated work reaches the checkout, and it is always a
          human's click. A refusal is shown verbatim: git's own reason is the
          actionable text, and the branch name is what makes the work
          recoverable by hand.
        */}
        {plan.status === 'complete' &&
        plan.isolation === 'worktree' &&
        worktree &&
        worktree.landedAt === null ? (
          <div style={{ padding: 'var(--s5) var(--s6)' }}>
            <div className={worktree.lastError ? 'audit-note audit-note--reject' : 'audit-note'}>
              {worktree.lastError ? (
                <>
                  <strong>Landing was refused.</strong> {worktree.lastError} The work is safe on{' '}
                  <code>{worktree.branch}</code>.
                </>
              ) : (
                <>
                  Every milestone is committed on <code>{worktree.branch}</code>. Landing
                  fast-forwards {shortPath(plan.repoPath)} — nothing else is touched, and git
                  refuses if your checkout moved.
                </>
              )}
              <div style={{ marginTop: 'var(--s3)', display: 'flex', gap: 'var(--s3)' }}>
                <button
                  className="btn btn--primary btn--sm"
                  disabled={landing}
                  onClick={() => void land()}
                >
                  {landing ? 'Landing…' : worktree.lastError ? 'Retry landing' : 'Land the branch'}
                </button>
                <button
                  className="btn btn--sm"
                  title={`Opens a shell pane in ${worktree.path}`}
                  onClick={() => {
                    dispatch({
                      type: 'focusGridSpawn',
                      spawn: { cwd: worktree.path, kind: 'shell' },
                    })
                    dispatch({ type: 'surface', surface: 'grid' })
                  }}
                >
                  Open worktree in Grid
                </button>
              </div>
            </div>
          </div>
        ) : null}

        {/* The worktree door for every other stage: mid-run inspection is a
            legitimate need, and the pane header will say landed or not. */}
        {plan.status !== 'complete' &&
        plan.isolation === 'worktree' &&
        worktree &&
        !worktree.orphaned ? (
          <div style={{ padding: '0 var(--s6) var(--s4)' }}>
            <button
              className="btn btn--subtle btn--sm"
              title={`Opens a shell pane in ${worktree.path}`}
              onClick={() => {
                dispatch({
                  type: 'focusGridSpawn',
                  spawn: { cwd: worktree.path, kind: 'shell' },
                })
                dispatch({ type: 'surface', surface: 'grid' })
              }}
            >
              Open worktree in Grid
            </button>
          </div>
        ) : null}

        {/* The planner's reply to the audit, so an approver can see which
            objections were accepted and which were argued down. */}
        {plan.correctionDispositions.length ? (
          <div style={{ padding: 'var(--s5) var(--s6)' }}>
            <DispositionTable dispositions={plan.correctionDispositions} />
          </div>
        ) : plan.correctionNote ? (
          // Plans answered before dispositions were stored structurally still have
          // only the prose, and it is better read than dropped.
          <div style={{ padding: 'var(--s5) var(--s6)' }}>
            <div className="audit-note">{plan.correctionNote}</div>
          </div>
        ) : null}

        {/*
          Shown whenever the pipeline is mid-sequence, not only before the first
          milestone exists. Auditing and correcting both run with milestones on
          screen, and those are exactly the stages that used to look finished.
        */}
        {['drafting', 'auditing', 'correcting'].includes(plan.status) ? (
          <div style={{ padding: 'var(--s5) var(--s6)' }}>
            <PlanProgress plan={plan} />
          </div>
        ) : null}

        {milestones.map((milestone) => (
          <MilestoneRow
            key={milestone.id}
            plan={plan}
            milestone={milestone}
            onApprove={() => setPendingApproval(milestone)}
            /* Eleven expanded milestones is several thousand words of scroll to
               reach the one row that is live. A settled milestone starts folded
               and keeps its detail one click away. */
            startCollapsed={milestone.status === 'complete'}
          />
        ))}
      </Panel>

      {pendingApproval && state.surface === host ? (
        <ApprovalGateDialog
          plan={plan}
          milestone={pendingApproval}
          ledger={ledger}
          busy={granting}
          onClose={() => setPendingApproval(null)}
          onConfirm={() => void approveAndRun(pendingApproval)}
          onAdopt={() => void adoptExisting(pendingApproval)}
          onResume={() => void resumeAndRun(pendingApproval)}
        />
      ) : null}
    </>
  )
}

/**
 * The verification command, correctable in place.
 *
 * Validated against the same shell rule the harness applies, so a command it
 * would refuse is rejected here instead of thirty minutes later.
 */
function TestCommandField({ milestone }: { milestone: Milestone }): ReactNode {
  const { attempt, notify } = useStore()
  const [command, setCommand] = useState(milestone.testCommand)
  const [busy, setBusy] = useState(false)

  const trimmed = command.trim()
  const offending = trimmed ? shellMetacharsIn(trimmed) : []
  const dirty = trimmed !== milestone.testCommand.trim()

  const save = async (): Promise<void> => {
    setBusy(true)
    const updated = await attempt(() => api.setTestCommand(milestone.id, trimmed))
    setBusy(false)
    if (updated) notify('info', 'Verification command updated.')
  }

  return (
    <Field
      label="Verification command"
      hint={
        offending.length
          ? `Parley spawns this without a shell, so ${offending.join(' ')} will be refused and the milestone will go unverified. Use one command, or a script in the repository.`
          : trimmed
            ? 'Run by Parley itself after the executor finishes, never by an agent.'
            : 'No command — nothing will be verified automatically. Weigh the diff on its own.'
      }
    >
      <div className="row">
        <input
          className="input mono"
          value={command}
          placeholder="npm test"
          onChange={(event) => setCommand(event.target.value)}
        />
        {dirty ? (
          <button
            className="btn btn--sm"
            disabled={busy || offending.length > 0}
            onClick={() => void save()}
          >
            {busy ? 'Saving…' : 'Save'}
          </button>
        ) : null}
      </div>
    </Field>
  )
}

/**
 * A blocking question from the planner, and the box to answer it.
 *
 * Deliberately prominent: the plan is stopped, and an unanswered question that
 * looks like a status line will simply sit there.
 */
function ClarificationPanel({
  plan,
  onAnswered,
}: {
  plan: WorkPlan
  onAnswered: () => void
}): ReactNode {
  const { attempt, notify } = useStore()
  const [answer, setAnswer] = useState('')
  const [busy, setBusy] = useState(false)

  const send = async (): Promise<void> => {
    const text = answer.trim()
    if (!text) return
    setBusy(true)
    const result = await attempt(() => api.answerPlan(plan.id, text))
    setBusy(false)
    if (result) {
      setAnswer('')
      notify('info', 'Answered. The planner is continuing.')
      onAnswered()
    }
  }

  return (
    <div style={{ padding: 'var(--s5) var(--s6)' }}>
      <div className="gate">
        <div className="gate__title">The planner needs a decision from you</div>
        <div className="gate__body" style={{ whiteSpace: 'pre-wrap' }}>
          {plan.question}
        </div>
        <textarea
          className="textarea"
          rows={3}
          autoFocus
          placeholder="Your answer…"
          value={answer}
          disabled={busy}
          onChange={(event) => setAnswer(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) void send()
          }}
        />
        <div className="row">
          <button className="btn btn--primary btn--sm" disabled={busy || !answer.trim()} onClick={() => void send()}>
            {busy ? 'Continuing…' : 'Answer and continue'}
          </button>
          <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
            ⌘↵ · the planner keeps its draft, so this is a reply rather than a restart
          </span>
        </div>
      </div>
    </div>
  )
}

/**
 * Stops a running milestone at its next boundary.
 *
 * "Next boundary" is precise: the in-flight CLI is killed immediately, but a
 * git commit or a mutation restore already underway finishes — both are
 * atomic on their own, and interrupting either would tear state. The run
 * state survives a stop exactly as it survives a crash, so this never costs
 * more than the time already spent.
 */
function StopMilestoneControl({ milestone }: { milestone: Milestone }): ReactNode {
  const { attempt, notify } = useStore()
  const [stopping, setStopping] = useState(false)

  return (
    <div style={{ padding: 'var(--s2) var(--s6) 0' }}>
      <button
        className="btn btn--subtle btn--sm"
        disabled={stopping}
        title="Takes effect at the next boundary — an in-flight commit finishes first. The run state is kept, so this milestone stays resumable."
        onClick={() => {
          setStopping(true)
          void attempt(() => api.stopMilestone(milestone.id)).then((result) => {
            if (result) {
              notify('info', `Stopping milestone ${milestone.index + 1} at the next boundary.`)
            }
          })
        }}
      >
        <Square size={11} strokeWidth={2} />
        {stopping ? 'Stopping…' : 'Stop this run'}
      </button>
    </div>
  )
}

function MilestoneRow({
  plan,
  milestone,
  onApprove,
  startCollapsed = false,
}: {
  plan: WorkPlan
  milestone: Milestone
  onApprove: () => void
  startCollapsed?: boolean
}): ReactNode {
  const tone = statusTone(milestone.status)
  const inFlight = ['executing', 'testing', 'reviewing'].includes(milestone.status)
  const approvable = executionRefusal(plan, milestone) === ''
  const [open, setOpen] = useState(!startCollapsed)
  // A milestone that starts running after it was folded away must not stay hidden.
  const expanded = open || inFlight

  const auditTone = milestone.auditNote.startsWith('REJECT')
    ? 'audit-note--reject'
    : milestone.auditNote.startsWith('REVISE')
      ? 'audit-note--revise'
      : milestone.auditNote.startsWith('ACCEPT')
        ? 'audit-note--accept'
        : ''

  const duration =
    milestone.completedAt && milestone.testResult
      ? formatDuration(milestone.testResult.durationMs)
      : ''

  return (
    <div className="milestone">
      <button
        type="button"
        className="milestone__head milestone__head--toggle"
        aria-expanded={expanded}
        onClick={() => setOpen((v) => !v)}
      >
        {expanded ? <ChevronDown size={12} strokeWidth={2} /> : <ChevronRight size={12} strokeWidth={2} />}
        <div className="milestone__index tnum">{milestone.index + 1}</div>
        <div className="milestone__title">{milestone.title}</div>
        {inFlight ? <Spinner /> : null}
        {/* A failed milestone whose run state survived can continue from its
            critique instead of starting over — worth a chip, because nothing
            else distinguishes it from a dead loss. */}
        {milestone.status === 'failed' && milestone.runState ? (
          <Chip
            tone="chip--accent"
            title="The run state was preserved — this milestone can be resumed with a fresh approval"
          >
            resumable
          </Chip>
        ) : null}
        {/* Folded rows still have to answer "did anything go wrong here?", so the
            blocking count travels with the summary rather than the detail. */}
        {!expanded && milestone.reviewBlocking.length ? (
          <Chip tone="chip--fail">
            {milestone.reviewBlocking.length} blocking
          </Chip>
        ) : null}
        {!expanded && duration ? (
          <span className="dimmer tnum" style={{ fontSize: 'var(--text-micro)' }}>
            {duration}
          </span>
        ) : null}
        {milestone.adopted ? (
          <Chip tone="chip--caution" title="Verified by Parley, but written outside it">
            adopted
          </Chip>
        ) : null}
        <Chip tone={tone.tone}>{tone.label}</Chip>
      </button>

      {!expanded ? null : (
        <>
      {milestone.intent ? <div className="milestone__intent">{milestone.intent}</div> : null}

      {/* The stop sits beside the feed the user is watching when they want it.
          It takes effect at the next boundary — an in-flight commit or mutation
          restore finishes — and the run state survives, so stopping never
          costs more than the time already spent. */}
      {inFlight ? <StopMilestoneControl milestone={milestone} /> : null}

      {/* Live telemetry while the milestone runs, and its record immediately
          after, so a failure can be read against what actually happened. */}
      <RunActivity subjectId={milestone.id} live={inFlight} />

      {milestone.expectedPaths.length ? (
        <div className="evidence">
          {milestone.expectedPaths.map((path) => (
            <span className="evidence__item" key={path}>
              {path}
            </span>
          ))}
        </div>
      ) : null}

      {milestone.auditNote ? (
        <div className={`audit-note ${auditTone}`}>
          <strong>Audit by {plan.planner.vendor === 'claude' ? 'Codex' : 'Claude'}:</strong>{' '}
          {milestone.auditNote}
        </div>
      ) : null}

      {milestone.testResult ? <VerificationResult result={milestone.testResult} /> : null}

      {milestone.reviewNote || milestone.reviewBlocking.length ? (
        <ReviewOutcome
          reviewer={plan.executor.vendor === 'claude' ? 'Codex' : 'Claude'}
          blocking={milestone.reviewBlocking}
          notes={milestone.reviewNotes}
          passed={milestone.reviewPassed}
          note={milestone.reviewNote}
        />
      ) : null}

      {milestone.status === 'rejected' ? (
        <div className="field__hint">
          The auditor rejected this milestone. Revise the plan rather than forcing it through.
        </div>
      ) : approvable && !inFlight ? (
        <div className="row">
          <button className="btn btn--sm" onClick={onApprove}>
            <ShieldCheck size={12} strokeWidth={2} />
            {milestone.status === 'failed' ? 'Approve and retry' : 'Approve and run'}
          </button>
          <span className="dimmer" style={{ fontSize: 'var(--text-tiny)' }}>
            Writes to the repository
          </span>
        </div>
      ) : null}
        </>
      )}
    </div>
  )
}

/**
 * The verification outcome, as four distinct states rather than one line of text.
 *
 * Passed, failed, crashed and timed out call for different responses — a crash
 * means nothing was verified and the command itself is suspect, a failure means
 * the suite ran and disagreed — and they used to be a single sentence a reader had
 * to parse. A timeout is delivered as a SIGTERM, so it must be tested before the
 * signal case or it reads as a crash.
 */
function VerificationResult({ result }: { result: TestResult }): ReactNode {
  const state = verificationState(result)

  return (
    <div className="verification">
      <div className="verification__head">
        <Chip tone={state.tone}>{state.label}</Chip>
        <code className="verification__command">{result.command}</code>
        <div className="spacer" />
        <span className="dimmer tnum" style={{ fontSize: 'var(--text-micro)' }}>
          {formatDuration(result.durationMs)}
        </span>
      </div>
      {state.detail ? <div className="field__hint">{state.detail}</div> : null}
      <div className="iteration__check">{combineOutput(result.stdout, result.stderr)}</div>
    </div>
  )
}

/**
 * The review, with blocking findings separated from remarks.
 *
 * `reviewPassed` is derived from the blocking list being empty, so showing the two
 * as one undifferentiated blob hid the only distinction the review contract turns
 * on: the most consequential sentence in a review looked exactly like a note about
 * naming. Blocking findings are a stop; notes collapse.
 */
function ReviewOutcome({
  reviewer,
  blocking,
  notes,
  passed,
  note,
}: {
  reviewer: string
  blocking: string[]
  notes: string[]
  passed: boolean | null
  note: string
}): ReactNode {
  const [showNotes, setShowNotes] = useState(false)
  return (
    <div className="review">
      <div className="review__head">
        <Chip tone={passed ? 'chip--pass' : 'chip--fail'}>
          {passed ? 'review passed' : 'review blocked'}
        </Chip>
        <span className="dimmer" style={{ fontSize: 'var(--text-micro)' }}>
          independently by {reviewer}
        </span>
      </div>

      {blocking.length ? (
        <ul className="review__blocking">
          {blocking.map((item, i) => (
            <li key={i}>{item}</li>
          ))}
        </ul>
      ) : null}

      {notes.length ? (
        <>
          <button
            type="button"
            className="review__notes-toggle"
            aria-expanded={showNotes}
            onClick={() => setShowNotes((v) => !v)}
          >
            {showNotes ? <ChevronDown size={11} strokeWidth={2} /> : <ChevronRight size={11} strokeWidth={2} />}
            {notes.length} note{notes.length === 1 ? '' : 's'}, not blocking
          </button>
          {showNotes ? (
            <ul className="review__notes">
              {notes.map((item, i) => (
                <li key={i}>{item}</li>
              ))}
            </ul>
          ) : null}
        </>
      ) : null}

      {/* The full round-by-round record. Kept because it is the only place a
          remediation's history is readable, and folded because it is long. */}
      {note ? <details className="review__record"><summary>Full record</summary>{note}</details> : null}
    </div>
  )
}

/**
 * The planner's dispositions on the audit, as a table.
 *
 * This is the most useful artifact a run produces — where the planner concedes a
 * finding or overrules the auditor and says why — and as 8,000 characters of prose
 * it was read by querying the database instead of the app.
 */
function DispositionTable({
  dispositions,
}: {
  dispositions: WorkPlan['correctionDispositions']
}): ReactNode {
  const tone = (d: string): string => {
    const v = d.toLowerCase()
    if (v.includes('accept')) return 'chip--pass'
    if (v.includes('reject')) return 'chip--caution'
    return ''
  }
  return (
    <div className="dispositions">
      <Label>The planner's answer to the audit</Label>
      <table className="dispositions__table">
        <tbody>
          {dispositions.map((d, i) => (
            <tr key={i}>
              <td className="dispositions__finding">{d.finding}</td>
              <td className="dispositions__verdict">
                <Chip tone={tone(d.disposition)}>{d.disposition}</Chip>
              </td>
              <td className="dispositions__note">{d.note}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/**
 * The approval gate.
 *
 * Deliberately the heaviest interaction in the app. It names the exact agent, the
 * exact repository, and the exact files, and it states that the approval is spent
 * on use — because it is: re-running the milestone needs a fresh one.
 */
function ApprovalGateDialog({
  plan,
  milestone,
  ledger,
  busy,
  onClose,
  onConfirm,
  onAdopt,
  onResume,
}: {
  plan: WorkPlan
  milestone: Milestone
  ledger: readonly LedgerEntry[] | null
  busy: boolean
  onClose: () => void
  onConfirm: () => void
  onAdopt: () => void
  onResume: () => void
}): ReactNode {
  const { attempt } = useStore()
  // Null ledger = the gate's inputs are unknown. Unknown fails CLOSED: an
  // empty permission would silently enable approval, and while main would
  // refuse the run, the grant itself writes an approval row that is never
  // consumed — an authorisation record for nothing.
  const ledgerUnknown = ledger === null
  const permission = ledgerUnknown
    ? { allowed: false, unresolved: [] as ReturnType<typeof approvalPermission>['unresolved'] }
    : approvalPermission(ledger)
  const [preflight, setPreflight] = useState<{
    existing: string[]
    missing: string[]
    dirtyPaths: string[]
  } | null>(null)

  // Everything needed to predict the commonest dead end is knowable before a
  // single token is spent, so ask for it as the dialog opens.
  //
  // Deliberately not routed through `attempt`, which raises a notice on failure.
  // This lookup can legitimately fail: the correction stage replaces a plan's
  // milestones wholesale, so a dialog opened moments earlier can be holding a
  // row that no longer exists. Preflight is advisory — losing it should quietly
  // leave the dialog without its hint, not tell the user something is wrong
  // about a race they neither caused nor can act on.
  useEffect(() => {
    let live = true
    void api
      .inspectMilestone(milestone.id)
      .then((result) => {
        if (live) setPreflight(result)
      })
      .catch(() => {
        // Nothing to say. The approve button is guarded separately.
      })
    return () => {
      live = false
    }
  }, [milestone.id])

  /**
   * Whether "every file already exists" is evidence of anything.
   *
   * For an implementation milestone it usually means a previous attempt got
   * there first, and adopting the existing work is the cheaper move. For a
   * remediation or migration milestone it means nothing at all: changing files
   * that already exist is the entire job, so every path existing is the normal
   * case and adopting would be actively wrong — it skips execution and asks the
   * reviewer to judge the *unfixed* code against an intent describing fixes.
   *
   * Suggesting adoption there was a real miscue: the recommendation appeared as
   * the primary action on the first remediation milestone that touched three
   * files created by an earlier plan.
   */
  const modifiesExistingByDesign = plan.kind === 'remediation' || plan.kind === 'migration'

  // A failed milestone whose work is already in the tree can be adopted instead
  // of re-executed: verification and independent review run against the tree as
  // it stands. This exists for exactly one observed shape — a milestone the
  // reviewer passed three times that failed only on a provably inert mutation,
  // where a retry deterministically hits the same wall and a fresh execution
  // would rebuild thrice-reviewed work from scratch. It deliberately ignores
  // modifiesExistingByDesign: that flag suppresses the adopt *recommendation*
  // for work that predates the plan, while this offers adoption of the failed
  // attempt's own output.
  const adoptableRetry = Boolean(
    milestone.status === 'failed' &&
      preflight &&
      milestone.expectedPaths.length > 0 &&
      preflight.missing.length === 0,
  )

  const allExist = Boolean(
    preflight &&
      !modifiesExistingByDesign &&
      milestone.expectedPaths.length > 0 &&
      preflight.missing.length === 0,
  )
  const someExist = Boolean(
    preflight && !modifiesExistingByDesign && preflight.existing.length > 0 && !allExist,
  )

  return (
    <Dialog
      title={`Approve milestone ${milestone.index + 1}`}
      subtitle={
        plan.container
          ? 'This is the only point at which Parley writes to your repository. Verification runs in the repository’s dev container.'
          : 'This is the only point at which Parley writes to your repository.'
      }
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            onClick={onConfirm}
            disabled={busy || !permission.allowed}
          >
            {busy ? 'Approving…' : 'Approve and run'}
          </button>
        </>
      }
    >
      <div className="gate">
        <div className="gate__title">{milestone.title}</div>
        <div className="gate__body">{milestone.intent}</div>
      </div>

      {ledgerUnknown ? (
        <div className="gate gate--blocking">
          <div className="gate__title">The findings ledger could not be loaded</div>
          <div className="gate__body">
            Approval stays disabled until the gate can see it. Reopen the plan to re-check —
            an unknown ledger is treated as blocking, never as clear.
          </div>
        </div>
      ) : null}

      {!permission.allowed && !ledgerUnknown ? (
        <div className="gate gate--blocking">
          <div className="gate__title">
            {permission.unresolved.length}{' '}
            {permission.unresolved.length === 1 ? 'finding needs' : 'findings need'} a disposition
          </div>
          <div className="gate__body">
            Approval and adoption stay disabled until every blocking occurrence has a recorded
            human decision. Each control below settles only the occurrence it names.
          </div>
          <div className="ledger-dispose-list">
            {permission.unresolved.length > 1 ? (
              <BulkDispositionControl unresolved={permission.unresolved} />
            ) : null}
            {permission.unresolved.map(({ entry, occurrence }) => (
              <OccurrenceDispositionControl
                key={occurrence.id}
                entry={entry}
                occurrence={occurrence}
                plan={plan}
                milestone={milestone}
              />
            ))}
          </div>
        </div>
      ) : null}

      {/*
        The expensive dead end, caught before it costs anything. An executor
        handed files that already exist will usually decline to overwrite them
        and change nothing — which is only discoverable, otherwise, after the
        whole run has finished.
      */}
      {milestone.status === 'failed' && milestone.runState ? (
        <div className="gate">
          <div className="gate__title">The interrupted run's state survived</div>
          <div className="gate__body">
            Round {milestone.runState.round + 1} was in flight when this run stopped. Resuming
            continues from the preserved state: the executor picks its own session back up, work
            already present is verified instead of redone, and the note will say the round was
            resumed. A resume spends a fresh approval, exactly like a run — that stance is
            deliberate.
          </div>
          <button
            className="btn btn--primary btn--wide"
            disabled={busy || !permission.allowed}
            onClick={onResume}
          >
            <Play size={12} strokeWidth={2} />
            {busy ? 'Working…' : 'Resume from where it stopped'}
          </button>
        </div>
      ) : null}

      {allExist ? (
        <div className="gate">
          <div className="gate__title">Every file this milestone would create already exists</div>
          <div className="gate__body">
            All {preflight?.existing.length} of the paths below are already present, most likely from
            an earlier attempt. An executor handed finished files usually declines to overwrite them
            and changes nothing, so running this is likely to spend a long time and fail.
          </div>
          <div className="gate__paths">
            {preflight?.existing.map((path) => (
              <span className="evidence__item" key={path}>
                {path}
              </span>
            ))}
          </div>
          <div className="gate__body">
            <strong>Adopt &amp; verify</strong> is usually what you want instead: it skips execution
            but still runs {milestone.testCommand ? <span className="mono">{milestone.testCommand}</span> : 'the verification step'}{' '}
            and has {plan.executor.vendor === 'claude' ? 'Codex' : 'Claude'} review the existing work
            independently. It writes nothing, so it needs no approval — and the record will say the
            work was verified rather than authored here.
          </div>
          {/* Gated exactly like "Approve and run": adoption completes a
              milestone through review, so an open blocker disables both. */}
          <button
            className="btn btn--primary btn--wide"
            disabled={busy || !permission.allowed}
            onClick={onAdopt}
          >
            <ShieldCheck size={12} strokeWidth={2} />
            {busy ? 'Working…' : 'Adopt & verify the existing work'}
          </button>
        </div>
      ) : adoptableRetry ? (
        <div className="gate">
          <div className="gate__title">The failed attempt's work is still in the tree</div>
          <div className="gate__body">
            Every path this milestone names exists. <strong>Adopt &amp; verify</strong> runs{' '}
            {milestone.testCommand ? <span className="mono">{milestone.testCommand}</span> : 'the verification step'}{' '}
            and an independent review against the tree as it stands, without executing again — use it
            when the work is sound and the failure was in the checking, not the code. Approve and
            retry instead if the work itself needs another attempt.
          </div>
          <button
            className="btn btn--wide"
            disabled={busy || !permission.allowed}
            onClick={onAdopt}
          >
            <ShieldCheck size={12} strokeWidth={2} />
            {busy ? 'Working…' : 'Adopt & verify the existing work'}
          </button>
        </div>
      ) : someExist ? (
        <div className="gate">
          <div className="gate__title">
            {preflight?.existing.length} of {milestone.expectedPaths.length} paths already exist
          </div>
          <div className="gate__body">
            The executor may leave these as they are rather than overwriting them:{' '}
            {preflight?.existing.join(', ')}.
          </div>
        </div>
      ) : null}

      <Field label="What will happen">
        <div className="milestone__intent">
          <strong>{plan.executor.vendor}</strong> gets write access to{' '}
          <span className="mono">{plan.repoPath}</span> and implements this milestone only. Parley then
          runs the command below itself, and{' '}
          <strong>{plan.executor.vendor === 'claude' ? 'Codex' : 'Claude'}</strong> reviews the
          resulting diff independently.
        </div>
      </Field>

      {/* Editable, because the planner can get it wrong — and did, emitting
          shell syntax the harness refuses, which left a milestone silently
          unverified. A gate you cannot correct at is not much of a gate. */}
      <TestCommandField milestone={milestone} />

      {milestone.expectedPaths.length ? (
        <Field label="Files the plan expects to touch">
          <div className="gate__paths">
            {milestone.expectedPaths.map((path) => (
              <span className="evidence__item" key={path}>
                {path}
              </span>
            ))}
          </div>
        </Field>
      ) : null}

      {milestone.auditNote ? (
        <Field label="The auditor said">
          <div className="audit-note">{milestone.auditNote}</div>
        </Field>
      ) : null}

      <div className="field__hint">
        Nothing is committed — the change is left in the working tree for you to inspect. This approval
        is single-use and is spent the moment the run starts, so running this milestone again will ask
        you afresh.
      </div>
    </Dialog>
  )
}
