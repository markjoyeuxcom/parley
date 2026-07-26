import { useEffect, useState, type ReactNode } from 'react'
import { ChevronDown, ChevronRight, FolderOpen, Play, ShieldCheck } from 'lucide-react'
import type {
  AgentConfig,
  Milestone,
  Session,
  TestResult,
  WorkPlan,
  WorkPlanKind,
} from '@shared/domain'
import { api, type PlanDetail } from '../lib/api'
import { formatDuration, shortPath, statusTone, verificationState } from '../lib/format'
import { shellMetacharsIn } from '@shared/command'
import { useStore } from '../state'
import { AgentPicker } from './AgentPicker'
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
}: {
  session: Session
  onClose: () => void
  onCreated: (detail: PlanDetail) => void
}): ReactNode {
  const { attempt } = useStore()
  const [kind, setKind] = useState<WorkPlanKind>('implementation')
  const [repoPath, setRepoPath] = useState(session.repoPath ?? '')
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
  const [note, setNote] = useState('')

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

      <hr className="divider" />

      <AgentPicker label="Planner — reads and plans, never writes" value={planner} onChange={setPlanner} />
      <AgentPicker
        label="Executor — writes, only after you approve"
        value={executor}
        onChange={setExecutor}
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
export function PlanPanel({ detail, onRefresh }: { detail: PlanDetail; onRefresh: () => void }): ReactNode {
  const { plan, milestones } = detail
  const tone = statusTone(plan.status)
  const [pendingApproval, setPendingApproval] = useState<Milestone | null>(null)
  const [granting, setGranting] = useState(false)
  const { attempt, notify } = useStore()

  /**
   * Closes an approval dialog whose milestone has ceased to exist.
   *
   * The correction stage does not patch milestones, it deletes them and writes
   * the corrected set — so any id held in component state can go stale while a
   * dialog is open. Approving from that dialog would grant a real, recorded
   * approval against a row that is gone, because `grantApproval` takes a subject
   * id without checking it resolves. The run would then refuse, leaving a spent
   * authorisation for nothing in the audit trail.
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
    const summary =
      `Allow ${plan.executor.vendor} to write to ${plan.repoPath} for milestone ` +
      `${milestone.index + 1}: ${milestone.title}`

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

      {pendingApproval ? (
        <ApprovalGateDialog
          plan={plan}
          milestone={pendingApproval}
          busy={granting}
          onClose={() => setPendingApproval(null)}
          onConfirm={() => void approveAndRun(pendingApproval)}
          onAdopt={() => void adoptExisting(pendingApproval)}
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
  const approvable = milestone.status === 'audited' || milestone.status === 'planned' || milestone.status === 'failed'
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
  busy,
  onClose,
  onConfirm,
  onAdopt,
}: {
  plan: WorkPlan
  milestone: Milestone
  busy: boolean
  onClose: () => void
  onConfirm: () => void
  onAdopt: () => void
}): ReactNode {
  const { attempt } = useStore()
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
      subtitle="This is the only point at which Parley writes to your repository."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn btn--primary" onClick={onConfirm} disabled={busy}>
            {busy ? 'Approving…' : 'Approve and run'}
          </button>
        </>
      }
    >
      <div className="gate">
        <div className="gate__title">{milestone.title}</div>
        <div className="gate__body">{milestone.intent}</div>
      </div>

      {/*
        The expensive dead end, caught before it costs anything. An executor
        handed files that already exist will usually decline to overwrite them
        and change nothing — which is only discoverable, otherwise, after the
        whole run has finished.
      */}
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
          <button className="btn btn--primary btn--wide" disabled={busy} onClick={onAdopt}>
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
