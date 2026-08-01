import { createHash } from 'node:crypto'
import {
  existsSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { isAbsolute, join, relative as relative_ } from 'node:path'
import { extractJson, oneOf, safeString } from '@shared/extract'
import {
  type AgentConfig,
  type Id,
  type Milestone,
  type Mutation,
  type MutationResult,
  type TestResult,
  type Vendor,
  type WorkPlan,
  type Worktree,
} from '@shared/domain'
import { emptyUsage } from '@shared/usage'
import { executionRefusal } from '@shared/execution'
import { proposeBacklogClosures } from './backlog'
import { commitMilestone, ensureWorktree, verifyWorktree } from './worktrees'
import { occurrenceState } from '@shared/ledger'
import {
  adoptReviewPrompt,
  auditPrompt,
  correctionPrompt,
  executePrompt,
  planPrompt,
  remediationPrompt,
  resumeExecutionPrompt,
  mutationRepairPrompt,
  reviewDiffPrompt,
} from '@shared/protocol'
import { capture, isShellFree, splitCommand, type CaptureResult } from '@main/util/spawn'
import { ensureUp, runProjectCommand } from './containers'
import {
  StoreMilestoneReporter,
  type MilestoneFact,
  type MilestoneReporter,
} from './reporter'
import type { RunEntry, RunRoles } from '@shared/journal'
import { ExecutionCore, executeMilestone } from './execution'
import {
  MAX_CHANGED_FILE_CHARS,
  MAX_REMEDIATION_ROUNDS,
  PipelineError,
  STAGE_TIMEOUT_MS,
  STOPPED_NOTE,
  TEST_TIMEOUT_MS,
  emptyTree,
  incrementalDelta,
  isGreenfield,
  judgeMutation,
  milestoneVerdict,
  missingExpectedPaths,
  parseMutationRepairs,
  parseReview,
  preExistingUntouched,
  readTree,
  renderDiffForReview,
  reviewerConfig,
  summariseMutations,
  summariseTests,
  tail,
  treeUnchanged,
  withMutationApplied,
  type ParsedReview,
  type RunState,
  type TreeFileSnapshot,
  type TreeState,
  type VerifyOutcome,
  freshRunState,
  revParseHead,
} from './evidence'
export {
  freshRunState,
  revParseHead,
  MAX_CHANGED_FILE_CHARS,
  MAX_REMEDIATION_ROUNDS,
  PipelineError,
  STAGE_TIMEOUT_MS,
  STOPPED_NOTE,
  TEST_TIMEOUT_MS,
  emptyTree,
  incrementalDelta,
  isGreenfield,
  judgeMutation,
  milestoneVerdict,
  missingExpectedPaths,
  parseMutationRepairs,
  parseReview,
  preExistingUntouched,
  readTree,
  renderDiffForReview,
  reviewerConfig,
  summariseMutations,
  summariseTests,
  tail,
  treeUnchanged,
  withMutationApplied,
  type ParsedReview,
  type RunState,
  type TreeFileSnapshot,
  type TreeState,
  type VerifyOutcome,
} from './evidence'
import type { Repo } from '@main/store/repo'
import { newId } from '@main/util/ids'
import { canonicalRepoPath } from '@main/util/repoPath'
import { assertCapability, type AgentRegistry, type RunResult } from '@main/agents'
import { groupLedgerEntry } from '@main/ipc/ledger'
import type { MilestonePhase } from '@shared/events'
import type { OrchestratorDeps, RunGate } from './types'
import { assertNoUnresolvedBlockingOccurrences } from './gate'

const INSPECT_TIMEOUT_MS = 3 * 60 * 1000
export const PLANNING_CONVERSATION = {
  drafting: { status: 'drafting', actor: 'planner', resumed: true, gate: 'clarification' },
  auditing: { status: 'auditing', actor: 'auditor', resumed: false, gate: 'none' },
  correcting: { status: 'correcting', actor: 'planner', resumed: true, gate: 'clarification' },
} as const

type PlanningStage = (typeof PLANNING_CONVERSATION)[keyof typeof PLANNING_CONVERSATION]

/** What a stage parked on a question needs in order to pick up again. */
type PendingStage =
  | { stage: 'planning'; brief: string; plannerResumeId: string | null }
  | {
      stage: 'correction'
      planText: string
      auditText: string
      auditorVendor: Vendor
      plannerResumeId: string | null
      auditSummary: string
      auditFindingCount: number
    }

export class Pipeline {
  private readonly repo: Repo
  private readonly registry: AgentRegistry
  private readonly emit: OrchestratorDeps['emit']
  private readonly worktreesRoot: string | null
  /** Canonical (the Manager canonicalises before constructing us), or null. */
  private readonly selfRepoPath: string | null
  private readonly devcontainerBinary: string | undefined
  /** Workspaces whose container this pipeline already brought up. */
  private readonly containerUp = new Set<string>()
  // `registry` is read for `.mock` as well as for adapters — see the unchanged-
  // tree branch in runMilestone.

  constructor(deps: OrchestratorDeps) {
    this.repo = deps.repo
    this.registry = deps.registry
    this.emit = deps.emit
    this.worktreesRoot = deps.worktreesRoot ?? null
    this.selfRepoPath = deps.selfRepoPath ?? null
    this.devcontainerBinary = deps.devcontainerBinary
  }

  /**
   * The plan's dev-container snapshot, with the permanent self-repo belt on
   * top of createPlan's: a hand-edited row must not put Parley's own gate in
   * a container that cannot build host bytes.
   */
  private async executionWorktree(
    plan: WorkPlan,
    onActivity?: (text: string) => void,
  ): Promise<Worktree | null> {
    if (plan.isolation !== 'worktree') return null
    if (!this.worktreesRoot) {
      throw new PipelineError('this plan uses worktree isolation, but no worktrees root is configured')
    }
    try {
      return await ensureWorktree(
        this.repo,
        this.worktreesRoot,
        plan,
        onActivity,
        this.devcontainerBinary,
      )
    } catch (err) {
      throw new PipelineError(err instanceof Error ? err.message : String(err))
    }
  }

  /**
   * The already-existing worktree for adoption, verified. Adoption never
   * creates one: it verifies work already present, and for a worktree plan
   * "present" means present in the worktree — origin dirt is invisible to an
   * isolated plan by design.
   */
  private async adoptionWorktree(plan: WorkPlan): Promise<Worktree | null> {
    if (plan.isolation !== 'worktree') return null
    const worktree = this.repo.getWorktreeForPlan(plan.id)
    if (!worktree) {
      throw new PipelineError(
        'there is nothing to adopt — this worktree plan has not executed yet, so no worktree exists',
      )
    }
    if (worktree.landedAt !== null) {
      throw new PipelineError('this plan’s branch has already landed; nothing further can be adopted')
    }
    const health = await verifyWorktree(worktree)
    if (!health.ok) {
      throw new PipelineError(`the worktree for this plan is unhealthy: ${health.detail}`)
    }
    return worktree
  }

  /**
   * The planning conversation: draft, independent audit, then the planner
   * answering that audit — with a way out for a question only the user can
   * settle.
   *
   * The planner is resumed across its two turns, so correcting is a reply rather
   * than a re-explanation. Any stage may park the plan on a question instead of
   * guessing; `resume` picks it back up with the answer.
   */
  async draft(plan: WorkPlan, brief: string, signal?: AbortSignal): Promise<Milestone[]> {
    return this.runPlanning(plan, { brief }, signal)
  }

  /** Continues a plan that was parked on a question. */
  async resume(plan: WorkPlan, answer: string, signal?: AbortSignal): Promise<Milestone[]> {
    const pending = this.repo.takePlanPending<PendingStage>(plan.id)
    if (!pending) throw new PipelineError('that plan is not waiting on an answer')

    if (pending.stage === 'planning') {
      return this.runPlanning(plan, { brief: pending.brief, answer, resumeId: pending.plannerResumeId }, signal)
    }
    return this.runCorrection(
      plan,
      {
        planText: pending.planText,
        auditText: pending.auditText,
        auditorVendor: pending.auditorVendor,
        plannerResumeId: pending.plannerResumeId,
        auditSummary: pending.auditSummary,
        auditFindingCount: pending.auditFindingCount,
        answer,
      },
      signal,
    )
  }

  /**
   * Who a conversation stage speaks as. The auditor is always the planner's
   * counterpart, carrying the executor's model and effort onto the other
   * vendor — never the planner grading its own plan.
   */
  private conversationActor(plan: WorkPlan, stage: PlanningStage): AgentConfig {
    return stage.actor === 'planner'
      ? plan.planner
      : { ...plan.executor, vendor: this.registry.counterpart(plan.planner.vendor) }
  }

  /**
   * One spoken stage of the planning conversation.
   *
   * Owns what every stage shares — actor resolution, the read-only run under
   * the stage timeout, telemetry and usage accounting — so the stage functions
   * hold only their contracts and their consequences. The whole conversation
   * is read-only end to end: write exists only past the human approval.
   */
  private async speak(
    plan: WorkPlan,
    stage: PlanningStage,
    input: { systemPrompt: string; prompt: string; resumeId?: string | null; signal?: AbortSignal },
  ): Promise<RunResult> {
    const cfg = this.conversationActor(plan, stage)
    const result = await this.registry.get(cfg.vendor).run({
      systemPrompt: input.systemPrompt,
      prompt: input.prompt,
      cfg,
      capability: 'read',
      cwd: plan.repoPath,
      resumeId: stage.resumed ? (input.resumeId ?? null) : null,
      signal: input.signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => this.stage(plan.id, stage.status, text),
    })
    this.repo.addPlanUsage(plan.id, result.usage)
    return result
  }

  /** A clarification can park only the stages whose gate declares one. */
  private clarificationOf(stage: PlanningStage, text: string): string {
    return stage.gate === 'clarification' ? parseClarification(text) : ''
  }

  private async runPlanning(
    plan: WorkPlan,
    input: { brief: string; answer?: string; resumeId?: string | null },
    signal?: AbortSignal,
  ): Promise<Milestone[]> {
    const stage = PLANNING_CONVERSATION.drafting
    this.setStatus(plan.id, stage.status)

    const greenfield = await isGreenfield(plan.repoPath, signal)
    const drafted = await this.speak(plan, stage, {
      systemPrompt:
        'You plan changes to real codebases. You are read-only in this turn. A plan naming files that do not exist is worse than no plan.',
      prompt: planPrompt(plan.kind, input.brief, plan.repoPath, input.answer ?? '', greenfield),
      resumeId: input.resumeId,
      signal,
    })

    if (drafted.error) {
      this.setStatus(plan.id, 'failed')
      throw new PipelineError(`planning failed: ${drafted.error}`)
    }

    const question = this.clarificationOf(stage, drafted.text)
    if (question) {
      this.park(plan, question, {
        stage: 'planning',
        brief: input.brief,
        plannerResumeId: drafted.resumeId ?? input.resumeId ?? null,
      })
      return []
    }

    const parsed = parsePlan(drafted.text)
    if (!parsed || parsed.milestones.length === 0) {
      this.setStatus(plan.id, 'failed')
      throw new PipelineError('the planner did not produce a usable milestone list')
    }
    if (parsed.title) this.repo.setPlanTitle(plan.id, parsed.title)
    this.emitPlanUpdated(plan.id)
    this.writeMilestones(plan.id, parsed)

    return this.runAudit(plan, drafted.text, drafted.resumeId ?? input.resumeId ?? null, greenfield, signal)
  }

  /** Cross-vendor audit of the plan, before a line is written. */
  private async runAudit(
    plan: WorkPlan,
    planText: string,
    plannerResumeId: string | null,
    greenfield: boolean,
    signal?: AbortSignal,
  ): Promise<Milestone[]> {
    const stage = PLANNING_CONVERSATION.auditing
    this.setStatus(plan.id, stage.status)

    const auditorVendor = this.conversationActor(plan, stage).vendor
    const result = await this.speak(plan, stage, {
      systemPrompt:
        'You audit other engineers\u2019 plans before any code is written. You did not write this plan; your value is catching what its author assumed without checking. You are read-only.',
      prompt: auditPrompt(planText, plan.repoPath, greenfield),
      signal,
    })

    if (result.error) {
      return this.parkUncertifiedAudit(
        plan,
        `The audit could not be completed: ${result.error}. Execution is blocked until the plan can be audited.`,
      )
    }

    const parsedAudit = parseAudit(result.text)
    if (!parsedAudit) {
      return this.parkUncertifiedAudit(
        plan,
        `The auditor's reply could not be read. Execution is blocked until the plan can be audited.`,
      )
    }
    const { audit, note: alignmentNote } = alignAudit(
      parsedAudit,
      this.repo.listMilestones(plan.id).length,
    )
    this.applyAudit(plan, audit)
    this.ingestAuditFindings(plan, audit)

    // Persisted now rather than after correction. Correction has two paths that
    // overwrite this note, and the auditor's findings must not leave with them.
    const auditSummary = [alignmentNote, summariseAudit(auditorVendor, audit)]
      .filter(Boolean)
      .join('\n\n')
    const auditFindingCount = audit
      ? audit.dispositions.filter((item) => item.disposition !== 'accept').length +
        audit.blockingConcerns.length
      : 0
    this.repo.setPlanCorrectionNote(plan.id, auditSummary)

    return this.runCorrection(
      plan,
      {
        planText,
        auditText: result.text,
        auditorVendor,
        plannerResumeId,
        auditSummary,
        auditFindingCount,
      },
      signal,
    )
  }

  private parkUncertifiedAudit(plan: WorkPlan, auditNote: string): Milestone[] {
    for (const milestone of this.repo.listMilestones(plan.id)) {
      const updated = this.repo.updateMilestone(milestone.id, { auditNote })
      this.emit({ type: 'plan.milestone', milestone: updated })
    }
    this.setStatus(plan.id, 'blocked')
    return this.repo.listMilestones(plan.id)
  }

  /**
   * The planner answers the audit.
   *
   * Without this the auditor's findings reach the human but never the plan, and
   * what gets executed is the original draft with an unread critique attached.
   */
  private async runCorrection(
    plan: WorkPlan,
    input: {
      planText: string
      auditText: string
      auditorVendor: Vendor
      plannerResumeId: string | null
      auditSummary: string
      auditFindingCount: number
      answer?: string
    },
    signal?: AbortSignal,
  ): Promise<Milestone[]> {
    const stage = PLANNING_CONVERSATION.correcting
    this.setStatus(plan.id, stage.status)

    const result = await this.speak(plan, stage, {
      systemPrompt:
        'You are correcting your own plan after an independent audit. Answer every finding; do not let an inconvenient one disappear.',
      prompt: correctionPrompt({
        planText: input.planText,
        auditText: input.auditText,
        auditorVendor: input.auditorVendor,
        repoPath: plan.repoPath,
        answer: input.answer ?? '',
      }),
      resumeId: input.plannerResumeId,
      signal,
    })

    if (result.error) {
      return this.parkUnansweredCorrection(
        plan,
        input.auditSummary,
        `The planner could not answer the audit: ${result.error}. The plan below is the original draft, with the audit findings unaddressed.`,
      )
    }

    const question = this.clarificationOf(stage, result.text)
    if (question) {
      this.park(plan, question, {
        stage: 'correction',
        planText: input.planText,
        auditText: input.auditText,
        auditorVendor: input.auditorVendor,
        plannerResumeId: result.resumeId ?? input.plannerResumeId,
        auditSummary: input.auditSummary,
        auditFindingCount: input.auditFindingCount,
      })
      return []
    }

    const corrected = parseCorrection(result.text)
    if (!corrected || corrected.milestones.length === 0) {
      return this.parkUnansweredCorrection(
        plan,
        input.auditSummary,
        'The planner did not return a usable corrected plan, so the original draft stands with the audit findings unaddressed.',
      )
    }

    if (corrected.dispositions.length === 0 && input.auditFindingCount > 0) {
      return this.parkUnansweredCorrection(
        plan,
        input.auditSummary,
        renderDispositions(corrected.dispositions),
      )
    }

    // Both halves of the exchange, because the corrected milestones replace the
    // draft ones and would otherwise take the auditor's findings with them.
    this.repo.setPlanCorrectionDispositions(plan.id, corrected.dispositions)
    this.repo.setPlanCorrectionNote(
      plan.id,
      [
        input.auditSummary,
        corrected.dispositions.length
          ? renderDispositions(corrected.dispositions)
          : 'The audit raised no findings requiring a disposition.',
      ]
        .filter(Boolean)
        .join('\n\n'),
    )
    if (corrected.title) this.repo.setPlanTitle(plan.id, corrected.title)
    this.emitPlanUpdated(plan.id)

    // The corrected plan supersedes the draft wholesale — milestones may have
    // been split, reordered or dropped, so patching them would be guesswork.
    this.repo.clearMilestones(plan.id)
    this.writeMilestones(plan.id, corrected, 'audited')

    this.setStatus(plan.id, 'ready')
    return this.repo.listMilestones(plan.id)
  }

  private parkUnansweredCorrection(
    plan: WorkPlan,
    auditSummary: string,
    correctionNote: string,
  ): Milestone[] {
    this.repo.setPlanCorrectionNote(
      plan.id,
      [auditSummary, correctionNote].filter(Boolean).join('\n\n'),
    )
    this.setStatus(plan.id, 'blocked')
    return this.repo.listMilestones(plan.id)
  }

  private writeMilestones(
    planId: Id,
    parsed: ParsedPlan,
    status: Milestone['status'] = 'planned',
  ): void {
    const now = Date.now()
    parsed.milestones.forEach((m, index) => {
      const created = this.repo.createMilestone({
        id: newId(),
        planId,
        index,
        title: m.title,
        intent: m.intent,
        expectedPaths: m.expectedPaths,
        status,
        auditNote: '',
        testCommand: m.testCommand,
        testResult: null,
        reviewNote: '',
        reviewPassed: null,
        adopted: false,
        approvalId: null,
        createdAt: now,
        completedAt: null,
        mutations: m.mutations,
        mutationResults: [],
        reviewBlocking: [],
        reviewNotes: [],
      })
      this.emit({ type: 'plan.milestone', milestone: created })
    })
    // The set as a whole, so a client that was watching the previous one drops it
    // rather than merging the two together.
    this.emit({
      type: 'plan.milestones',
      planId,
      milestones: this.repo.listMilestones(planId),
    })
  }

  private applyAudit(plan: WorkPlan, audit: ParsedAudit | null): void {
    for (const m of this.repo.listMilestones(plan.id)) {
      const disposition = audit?.dispositions.find((d) => d.milestone === m.index)
      // Plan-wide concerns deliberately do not go here. They used to be appended
      // to every milestone, which stored one identical paragraph N times and
      // buried the single line that is actually about this milestone. They are
      // written once, to the plan, by the caller.
      const note = disposition
        ? `${disposition.disposition.toUpperCase()} — ${disposition.note}`
        : `The auditor did not record a disposition for this milestone.`

      // Appended after the disposition, and labelled, so it is clear which findings
      // came from the auditor and which the pipeline established for itself.
      const structural = structuralConcerns(m)
      const fullNote = structural.length
        ? `${note}\n\nParley also found:\n${structural.map((c) => `  • ${c}`).join('\n')}`
        : note

      const updated = this.repo.updateMilestone(m.id, {
        auditNote: fullNote,
        status: disposition?.disposition === 'reject' ? 'rejected' : 'audited',
      })
      this.emit({ type: 'plan.milestone', milestone: updated })
    }
  }

  private park(plan: WorkPlan, question: string, pending: PendingStage): void {
    this.repo.askPlanQuestion(plan.id, question, pending)
    this.emit({ type: 'plan.status', planId: plan.id, status: 'awaiting-clarification' })
    this.emit({
      type: 'notice',
      level: 'info',
      message: `The planner needs a decision from you before it can continue.`,
    })
  }

  /**
   * Executes one approved milestone.
   *
   * `approvalId` is spent here, atomically. If it has already been used — say
   * the user double-clicked, or a retry raced — the store refuses and nothing
   * is written.
   */

  /**
   * The execution-entry refusal, combining the shared status legality with
   * the self-repo rule: a checkout-isolation plan targeting the checkout this
   * app runs from must never execute — grandfathered rows included, which is
   * why this lives at the entry and not only in createPlan. Dormant when
   * selfRepoPath is null (packaged, or tests that don't care).
   */
  private entryRefusal(plan: WorkPlan, milestone: Milestone): string | null {
    const refusal = executionRefusal(plan, milestone)
    if (refusal) return refusal
    const self = this.selfRepoPath
    if (self && plan.isolation === 'checkout' && canonicalRepoPath(plan.repoPath) === self) {
      return "this is Parley's own repository — plans here run in a worktree only: an agent writing into the live app's source under it is the one uncontrolled case"
    }
    return null
  }

  async runMilestone(milestoneId: Id, approvalId: Id, gate?: RunGate): Promise<Milestone> {
    // The gate, not a bare signal, so every failure sink can tell a stop the
    // user asked for from a run that died — the two must not share a note.
    const signal = gate?.signal
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new PipelineError('no such milestone')

    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new PipelineError('the plan for this milestone is missing')
    const refusal = this.entryRefusal(plan, milestone)
    if (refusal) throw new PipelineError(refusal)

    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)

    const activity = (phase: MilestonePhase, text: string): void => {
      this.emit({ type: 'plan.activity', milestoneId, phase, text })
    }

    // Resolved — and on the first milestone, created — before the approval is
    // spent, so a broken or unbuildable worktree costs nothing but time.
    const worktree = await this.executionWorktree(plan, (text) => activity('executing', text))
    const root = worktree?.path ?? plan.repoPath
    const agentEnv = worktree ? { GIT_OPTIONAL_LOCKS: '0' } : undefined

    // Re-checked after the await above, in the same synchronous block as the
    // spend: worktree setup can take minutes, and a racing start that entered
    // first has already moved the status. Two starts carry two *different*
    // approvals, so the atomic single-use spend alone cannot catch this race —
    // the status refusal is what does.
    const raced = this.repo.getMilestone(milestoneId)
    if (!raced) throw new PipelineError('no such milestone')
    const racedRefusal = this.entryRefusal(this.repo.getPlan(raced.planId) ?? plan, raced)
    if (racedRefusal) throw new PipelineError(racedRefusal)

    // Spend the approval before anything can write. Throws if already spent.
    this.repo.consumeApproval(approvalId, 'milestone.execute', milestoneId)
    assertCapability('write', true)

    // Clear the previous attempt's artifacts. Without this a retry shows the old
    // test output and the old review note beside the new outcome, and the two
    // get read as if they belonged to the same run. The run state joins the
    // clear: a stale Resume offer surviving a fresh retry would resume into a
    // world the retry has since rewritten.
    this.repo.setMilestoneRunState(milestoneId, null)
    let current = this.repo.updateMilestone(milestoneId, {
      status: 'executing',
      approvalId,
      testResult: null,
      reviewNote: '',
      reviewPassed: null,
    })
    this.emit({ type: 'plan.milestone', milestone: current })
    this.setStatus(plan.id, 'running')

    // Baseline before a single byte is written. Everything downstream compares
    // against this rather than against "clean", because the repository is very
    // often not clean when a milestone starts.
    const before = await readTree(root, signal)

    // Persisted from here on: a crash at any later point leaves everything a
    // resumption needs. Saved through one closure so the blob and its local
    // copy cannot drift.
    let runState: RunState = freshRunState(before, await revParseHead(root, signal))
    this.repo.setMilestoneRunState(milestoneId, runState)

    return this.execute(
      {
        milestoneId,
        plan,
        worktree,
        root,
        agentEnv,
        gate,
        activity,
        runState,
        history: [],
        enterAtVerify: false,
        resumedRound: null,
        seedTestResult: null,
      },
      current,
      activity,
    )
  }
  /**
   * Runs the execution core, then does the record work only this side can.
   *
   * The tail is the whole reason the facade exists. Settling the ledger reads
   * dispositions and occurrences; deriving the plan's status needs the
   * milestone's SIBLINGS. Neither is knowable on a machine that holds no
   * record, and inverting them into callbacks the core could invoke would
   * have disguised the dependency rather than removed it.
   *
   * The order — finish, settle, then move the plan — is pinned by
   * executionorder.integration.test.ts, which was written before any of this
   * moved precisely so the move would have something to be identical to.
   */
  private async execute(
    input: Omit<Parameters<typeof executeMilestone>[0], 'milestone'>,
    milestone: Milestone,
    activity: (phase: MilestonePhase, text: string) => void,
    entry: RunEntry = 'fresh',
  ): Promise<Milestone> {
    const plan = input.plan
    // One run id per ATTEMPT. A resume spends a fresh approval and is a new
    // run against the same milestone; flattening them would lose that the
    // first two tries failed.
    const runId = newId()
    // The executor is the actor for what this loop states — the phases, the
    // spend, the narrative. Findings carry the reviewer where they are named.
    const reporter = this.reporterFor(plan, milestone, activity, runId, {
      executor: plan.executor.vendor,
      reviewer: plan.reviewer.vendor,
    })
    reporter.started(entry)
    const current = await executeMilestone(
      {
        ...input,
        milestone,
        // Through the reporter, not the raw callback: narrative is part of the
        // story now, and the reporter is what keeps it. The remote worker
        // already routed activity this way; locally it went straight to the
        // renderer and was lost.
        activity: (phase, text) => reporter.activity(phase, text),
      },
      {
        reporter,
        agents: this.registry,
        devcontainerBinary: this.devcontainerBinary,
        selfRepoPath: this.selfRepoPath,
      },
    )

    // A parked plan is `failed` at the plan level for want of a fourth word:
    // the plan did stop and does need a human, which is all the plan's own
    // status has ever meant. The distinction that matters — whether anything
    // was learned — lives on the milestone, where it can be acted on.
    this.settleFinishedRun(plan, input.milestoneId, current, reporter)
    const passed = current.status === 'complete'
    // Last, after everything about the run has been recorded — including what
    // it did to the plan. A run.ended with facts after it would make the
    // closing event a lie about where the story stops.
    //
    // The journal keeps `parked` distinct, because a reader scanning attempts
    // needs to see that this one established nothing. Three failed attempts
    // and two failures plus a park are different situations.
    const ending = passed ? 'complete' : current.status === 'parked' ? 'parked' : 'failed'
    reporter.ended(ending, current.reviewNote.slice(0, 400))
    return current
  }


  /**
   * Continues an interrupted milestone from its preserved run state, spending
   * a fresh single-use approval — the crash-recovery stance is unchanged, and
   * what preservation buys is cheapness, not autonomy: the executor gets a
   * continuation instead of a restatement, the reviewer keeps its objections,
   * and finished work is verified rather than redone.
   *
   * The ordering mirrors runMilestone's pinned shape, with two additions in
   * the synchronous block before the spend: the run state is re-read (a retry
   * that started during the worktree await clears it — whoever consumes first
   * wins, the loser refuses here), and the preserved baseline's HEAD anchor
   * must still match the tree. Every signature in a baseline is relative to
   * HEAD; resuming across a moved HEAD would silently misattribute the diff,
   * so it refuses toward plain retry instead.
   */
  async resumeMilestone(milestoneId: Id, approvalId: Id, gate?: RunGate): Promise<Milestone> {
    const signal = gate?.signal
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new PipelineError('no such milestone')
    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new PipelineError('the plan for this milestone is missing')
    const refusal = this.entryRefusal(plan, milestone)
    if (refusal) throw new PipelineError(refusal)

    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)

    const preview = this.repo.getMilestoneRunState<RunState>(milestoneId)
    if (!preview) {
      throw new PipelineError('this milestone has no preserved run state to resume — retry it instead')
    }

    const activity = (phase: MilestonePhase, text: string): void => {
      this.emit({ type: 'plan.activity', milestoneId, phase, text })
    }

    const worktree = await this.executionWorktree(plan, (text) => activity('executing', text))
    const root = worktree?.path ?? plan.repoPath
    const agentEnv = worktree ? { GIT_OPTIONAL_LOCKS: '0' } : undefined
    const headNow = await revParseHead(root, signal)
    const nowTree = await readTree(root, signal)

    // The synchronous block: re-checks and the spend, with no await between.
    const raced = this.repo.getMilestone(milestoneId)
    if (!raced) throw new PipelineError('no such milestone')
    const racedRefusal = this.entryRefusal(this.repo.getPlan(raced.planId) ?? plan, raced)
    if (racedRefusal) throw new PipelineError(racedRefusal)
    const state = this.repo.getMilestoneRunState<RunState>(milestoneId)
    if (!state) {
      throw new PipelineError(
        'the preserved run state was cleared by another attempt — retry the milestone instead',
      )
    }
    if (state.baselineHead !== headNow) {
      throw new PipelineError(
        'the repository has moved since this run was interrupted — the preserved baseline no longer matches HEAD, so resuming would misattribute the diff. Retry the milestone instead.',
      )
    }
    this.repo.consumeApproval(approvalId, 'milestone.execute', milestoneId)
    assertCapability('write', true)

    // The interrupted attempt's verdict fields clear like any retry, but its
    // note becomes the history's first element — publishHistory replaces the
    // whole note, and losing rounds 1..N from the record would let a resumed
    // pass read as a clean first attempt.
    const seedTestResult = raced.testResult
    const history = raced.reviewNote.trim() ? [raced.reviewNote.trim()] : []
    const current = this.repo.updateMilestone(milestoneId, {
      status: 'executing',
      approvalId,
      testResult: null,
      reviewPassed: null,
    })
    this.emit({ type: 'plan.milestone', milestone: current })
    this.setStatus(plan.id, 'running')

    // Entry is decided by the world, not a recorded label: work present means
    // the interrupted executor got somewhere — verify it rather than redo it.
    // An untouched tree means nothing landed, so execution runs (resumed when
    // the vendor session survived, fresh-with-critique when it did not).
    const enterAtVerify = !treeUnchanged(state.before, nowTree)
    activity(
      'executing',
      enterAtVerify
        ? 'resuming: work is present, verifying it instead of re-executing'
        : 'resuming from the preserved run state',
    )

    return this.execute(
        {
        milestoneId,
        plan,
        worktree,
        root,
        agentEnv,
        gate,
        activity,
        runState: state,
        history,
        enterAtVerify,
        resumedRound: state.round,
        seedTestResult,
        },
        current,
        activity,
      )
  }

  /**
   * One read-only cross-vendor look at a silent run: is it progressing or
   * stuck? Invariant 6 applied to liveness — the judgment comes from the
   * vendor that is not doing the work, it reads the execution root without
   * touching it, and it decides nothing: the verdict lands in the run state,
   * the stall hold shows it, and the stopper stays human. Called by the
   * watchdog at most once per stall episode; every failure path is silent
   * because an inspector that cannot answer must not look like a new problem.
   */
  async inspectStalledMilestone(milestoneId: Id): Promise<void> {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) return
    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) return
    const state = this.repo.getMilestoneRunState<RunState>(milestoneId)
    if (!state) return

    const worktree = plan.isolation === 'worktree' ? this.repo.getWorktreeForPlan(plan.id) : null
    const root = worktree && existsSync(worktree.path) ? worktree.path : plan.repoPath
    const inspectorVendor = this.registry.counterpart(plan.executor.vendor)
    const inspector = this.registry.get(inspectorVendor)

    const reply = await inspector.run({
      systemPrompt:
        'You are a read-only inspector judging whether another agent’s in-flight run is progressing or stuck. You cannot and must not modify anything.',
      prompt: [
        `Another agent (${plan.executor.vendor}) is mid-run on a milestone in this repository and has shown no activity for a while. Judge from the working tree whether the run looks like it is progressing or wedged.`,
        `MILESTONE: ${milestone.title}`,
        milestone.intent.trim() ? `INTENT: ${milestone.intent.trim()}` : '',
        milestone.expectedPaths.length
          ? `EXPECTED PATHS: ${milestone.expectedPaths.join(', ')}`
          : '',
        `REMEDIATION ROUND: ${state.round + 1}`,
        state.executionReport
          ? `THE EXECUTOR LAST SAID:\n${state.executionReport}`
          : '',
        `Inspect the tree (git status, the expected paths, partial edits). Then reply with a fenced JSON block and nothing after it:\n\`\`\`json\n{ "verdict": "progressing" | "stuck" | "unclear", "note": "<one plain paragraph a person can act on>" }\n\`\`\``,
      ]
        .filter(Boolean)
        .join('\n\n'),
      cfg: { vendor: inspectorVendor, model: '', effort: 'medium', persona: '' },
      capability: 'read',
      cwd: root,
      env: worktree ? { GIT_OPTIONAL_LOCKS: '0' } : undefined,
      timeoutMs: INSPECT_TIMEOUT_MS,
    })
    this.repo.addPlanUsage(plan.id, reply.usage)

    const parsed = extractJson<Record<string, unknown>>(reply.text).data
    const rawVerdict = typeof parsed?.['verdict'] === 'string' ? parsed['verdict'] : ''
    const verdict = ['progressing', 'stuck', 'unclear'].includes(rawVerdict)
      ? rawVerdict
      : 'unclear'
    const note =
      safeString(parsed?.['note']).trim() ||
      reply.text.trim().slice(0, 400) ||
      'the inspector returned nothing usable'

    // Read-modify-write against the current blob: the run may have progressed
    // (or settled and cleared) while the inspector was reading.
    const fresh = this.repo.getMilestoneRunState<RunState>(milestoneId)
    if (!fresh) return
    this.repo.setMilestoneRunState(milestoneId, {
      ...fresh,
      lastInspection: { at: Date.now(), verdict, note },
    })
  }

  /**
   * The execute → verify → remediate loop and its settle epilogue, seeded.
   *
   * One driver for both entries — a fresh run and a resumption — because a
   * parallel resume implementation would drift from the most load-bearing
   * code in the repo. The seed is exactly the preserved run state plus the
   * entry decision; a fresh run seeds zeros.
   */
  /**
   * The reporter a local run uses: facts become rows in this process's store.
   *
   * A remote run builds a different one that turns the same facts into framed
   * protocol messages, which the local side replays through the same patch
   * function — so both records are written by one definition rather than two
   * that agree until they do not.
   */
  private reporterFor(
    plan: WorkPlan,
    milestone: Milestone,
    activity: (phase: MilestonePhase, text: string) => void,
    runId: Id,
    roles: RunRoles,
  ): StoreMilestoneReporter {
    return new StoreMilestoneReporter(
      {
        updateMilestone: (id, patch) => this.repo.updateMilestone(id, patch),
        setRunState: (id, state) => this.repo.setMilestoneRunState(id, state),
        addPlanUsage: (planId, usage) => this.repo.addPlanUsage(planId, usage),
        setPlanStatus: (planId, status) => this.setStatus(planId, status),
        recordFinding: (finding, id) => this.ingestFinding(plan, finding, id),
        appendEvent: (event) => this.repo.appendRunEvent(event),
        transact: (fn) => this.repo.transaction(fn),
        activityKept: () => this.repo.countRunActivity(runId),
        emitMilestone: (row) => this.emit({ type: 'plan.milestone', milestone: row }),
        emitActivity: (phase, text) => activity(phase as MilestonePhase, text),
      },
      milestone,
      plan.id,
      runId,
      roles,
      newId,
    )
  }

  async adoptMilestone(milestoneId: Id, gate?: RunGate): Promise<Milestone> {
    const signal = gate?.signal
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new PipelineError('no such milestone')

    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new PipelineError('the plan for this milestone is missing')
    const refusal = this.entryRefusal(plan, milestone)
    if (refusal) throw new PipelineError(refusal)

    // Checked once, not twice: execution re-checks at run because a finding can
    // arrive in the human-scale gap between granting and running, but adoption
    // has no approval step and so no gap — this call is its whole entry.
    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)

    // For a worktree plan the work being adopted lives in the worktree —
    // usually leftovers from an interrupted run. Verified, never created here.
    const worktree = await this.adoptionWorktree(plan)
    const root = worktree?.path ?? plan.repoPath
    const agentEnv = worktree ? { GIT_OPTIONAL_LOCKS: '0' } : undefined

    const tree = await readTree(root, signal)
    if (!tree.unknown && tree.paths.length === 0) {
      throw new PipelineError(
        'there is nothing to adopt — the working tree is clean, so no existing work matches this milestone',
      )
    }

    const missing = missingExpectedPaths(root, milestone.expectedPaths)
    if (missing.length === milestone.expectedPaths.length && milestone.expectedPaths.length > 0) {
      throw new PipelineError(
        `there is nothing to adopt — none of the paths this milestone expects exist: ${missing.join(', ')}`,
      )
    }

    const dirtyExpectedPaths = tree.paths.filter(
      (path) => pathsOutsideScope([path], milestone.expectedPaths).length === 0,
    )
    if (dirtyExpectedPaths.length === 0) {
      throw new PipelineError(
        'there is nothing to adopt — none of the dirty paths overlap this milestone\'s expected paths',
      )
    }

    // Adoption reviews everything in the tree, but the verification command is
    // scoped to the milestone's own paths. Anything changed outside that scope
    // gets reviewed without ever being run, and the reader has to be told.
    const unverified = pathsOutsideScope(tree.paths, milestone.expectedPaths)

    const activity = (phase: MilestonePhase, text: string): void => {
      this.emit({ type: 'plan.activity', milestoneId, phase, text })
    }
    // Adoption is a local flow, but the verification and mutation work is the
    // same work — one implementation, borrowed, rather than a second that
    // drifts.
    const adoptionRunId = newId()
    // Adoption is someone deciding work already in the tree counts, but the
    // verification and review inside it are still the agents' — so the roles
    // are the plan's, and the human's act is the run.started event itself.
    const adoptionReporter = this.reporterFor(plan, milestone, activity, adoptionRunId, {
      executor: plan.executor.vendor,
      reviewer: plan.reviewer.vendor,
    })
    adoptionReporter.started('adopted')
    const core = new ExecutionCore({
      reporter: adoptionReporter,
      agents: this.registry,
      devcontainerBinary: this.devcontainerBinary,
      selfRepoPath: this.selfRepoPath,
    })

    // `mutationResults` is cleared with the rest so an earlier attempt's
    // outcomes cannot sit beside this run's verdict; adoption re-runs the
    // declared breaks itself once the suite is green. The run state clears
    // too: adoption supersedes the interrupted attempt it recovers from, and
    // a Resume offer surviving it would resume into an adopted world.
    this.repo.setMilestoneRunState(milestoneId, null)
    let current = this.repo.updateMilestone(milestoneId, {
      status: 'testing',
      testResult: null,
      reviewNote: '',
      reviewPassed: null,
      mutationResults: [],
    })
    this.emit({ type: 'plan.milestone', milestone: current })
    this.setStatus(plan.id, 'running')

    // ── Deterministic verification ───────────────────────────────────────────
    activity('testing', current.testCommand ? `running ${current.testCommand}` : 'no verification command defined')
    const testResult = await core.runTests(current.testCommand, root, { container: core.containerFor(plan), signal })
    if (testResult) {
      activity(
        'testing',
        `${testResult.command} exited ${testResult.exitCode} in ${(testResult.durationMs / 1000).toFixed(1)}s`,
      )
    }
    current = this.repo.updateMilestone(milestoneId, { testResult })
    this.emit({ type: 'plan.milestone', milestone: current })

    // Adoption's entire claim is that Parley verified work it did not write.
    // A verification that never started cannot support it, and adopting on
    // the strength of one would put "verified" in the record for a milestone
    // nothing checked — a worse lie here than on the execute path, because
    // adoption is the path whose only output IS the verification.
    if (testResult?.startError) {
      activity('testing', `the verification command could not run: ${testResult.startError}`)
      current = adoptionReporter.record({
        kind: 'parked',
        reason:
          `\`${testResult.command}\` could not be run here: ${testResult.startError}. ` +
          `Adoption verifies rather than writes, so with the verification unable to start there ` +
          `is nothing to adopt on. Fix what is missing and adopt again.`,
      })
      adoptionReporter.record({ kind: 'planOutcome', status: 'failed' })
      adoptionReporter.ended('parked', current.reviewNote.slice(0, 400))
      this.setStatus(plan.id, 'failed')
      this.emit({ type: 'plan.milestone', milestone: current })
      return current
    }

    // Fixed before the mutation stage because both stages use it: a stale
    // anchor is re-resolved by the reviewer's vendor, the one party with no
    // stake in the outcome.
    const reviewerVendor =
      plan.reviewer.vendor === plan.executor.vendor
        ? this.registry.counterpart(plan.executor.vendor)
        : plan.reviewer.vendor
    const reviewer = this.registry.get(reviewerVendor)

    // ── Mutation checks ──────────────────────────────────────────────────────
    //
    // Adopted code has unknown provenance, so whether its tests would catch a
    // wrong implementation is worth more here, not less. The stage runs only on
    // a real green result — against a red or absent suite every applied break
    // would "fail" and prove nothing, and adoption refuses a missing command at
    // the verdict anyway.
    let mutationResults: MutationResult[] = []
    if (testResult !== null && testResult.exitCode === 0 && current.mutations.length > 0) {
      const staged = await core.runMutationStage({
        milestoneId,
        milestone: current,
        plan,
        // Adoption is a local-only flow, but it records through the same
        // reporter so a mutation result reaches the record by one route
        // whoever asked for it.
        // The same reporter, so one adoption is one run rather than two.
        report: adoptionReporter,
        root,
        agentEnv,
        reviewer,
        reviewerVendor,
        reviewerResumeId: null,
        activity,
        signal,
      })
      current = staged.milestone
      mutationResults = staged.mutationResults
    }

    current = this.repo.updateMilestone(milestoneId, { status: 'reviewing' })
    this.emit({ type: 'plan.milestone', milestone: current })

    // ── Independent review ───────────────────────────────────────────────────
    activity('reviewing', `${reviewerVendor} reviewing work already in the tree`)

    const review = await reviewer.run({
      systemPrompt:
        'You review code that was already present in a repository. Nobody authored it under supervision, so it has to stand on its own. You are read-only.',
      prompt: adoptReviewPrompt(
        current.title,
        current.intent,
        renderDiffForReview(tree, emptyTree()),
        summariseTests(testResult),
        unverified,
        missing,
        summariseMutations(mutationResults),
      ),
      cfg: reviewerConfig(plan.reviewer, reviewerVendor),
      capability: 'read',
      cwd: root,
      env: agentEnv,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => activity('reviewing', text),
    })
    this.repo.addPlanUsage(plan.id, review.usage)

    const parsedReview = parseReview(review.text)
    // The same ingestion an executed milestone's review gets: what the adopt
    // reviewer blocks on must reach the ledger, or the gate cannot hold the
    // next approval or adoption to it. The source says which stage raised it —
    // provenance a consumer should never have to reconstruct from a null
    // round. There is no settle-on-pass here: a pass means the blocking list
    // was empty, and anything older was dispositioned before the gate let this
    // run.
    if (parsedReview) {
      for (const finding of parsedReview.blocking) {
        this.recordFindingOccurrence(plan, finding, {
          milestoneId,
          round: null,
          kind: 'blocking',
          source: 'adoption',
        })
      }
      for (const note of parsedReview.notes) {
        this.recordFindingOccurrence(plan, note, {
          milestoneId,
          round: null,
          kind: 'note',
          source: 'adoption',
        })
      }
    }
    // The deterministic half counts the declared breaks exactly as execution
    // does — a break the milestone said its tests would catch must have been
    // caught, and a check that could not be applied even after re-anchoring is
    // fatal. The one difference stays: `milestoneVerdict` reads a missing
    // command as green and adoption must not, so testResult is required too.
    const {
      testsPassed: deterministicPassed,
      surviving: survivingMutations,
      unverifiable,
    } = milestoneVerdict(testResult, mutationResults)
    const testsPassed = testResult !== null && deterministicPassed
    const reviewPassed = parsedReview?.passed === true
    let passed = missing.length === 0 && testsPassed && reviewPassed

    // An adopted worktree milestone must be committed too, or the landed
    // branch would silently lack its work — the record must match the branch.
    let commitLine = ''
    if (passed && worktree) {
      const commit = await commitMilestone(
        worktree,
        `${plan.title} — milestone ${current.index + 1}: ${current.title} (adopted)`,
      )
      if (commit.committed) {
        commitLine = `Committed in the worktree as ${commit.sha.slice(0, 10)} on ${worktree.branch}.`
      } else {
        passed = false
        commitLine =
          `The verification passed, but committing the adopted work in the worktree failed: ${commit.detail}. ` +
          'The record must match the branch, so the milestone is not adopted.'
      }
    }

    // The opening line states the *mode*, then the outcome. Leading with
    // "Adopted" on a run that was rejected would claim the opposite of what
    // happened.
    const noteParts = [
      passed
        ? `Adopted, not executed: this work was already in the tree when Parley found it, so no agent authored it under supervision. It was verified, not written, and both checks passed.`
        : `Not adopted. This work was already in the tree, so it was verified rather than written — and the verification did not pass.`,
    ]
    if (commitLine) noteParts.push(commitLine)
    if (!passed && gate?.isStopped) noteParts.push(STOPPED_NOTE)

    // The gap an independent reviewer would otherwise have to notice for itself:
    // the verification command is scoped to the milestone, but adoption reviews
    // whatever is in the tree, which can be more.
    if (unverified.length) {
      noteParts.push(
        `The working tree also contains changes outside this milestone's scope, which ` +
          `${current.testCommand ? `\`${current.testCommand}\`` : 'the verification'} did not exercise: ` +
          `${unverified.join(', ')}.`,
      )
    }
    if (missing.length) noteParts.push(`Expected paths still absent: ${missing.join(', ')}.`)
    if (review.error) {
      noteParts.push(
        gate?.isStopped
          ? 'Stopped by you before the review completed.'
          : `The review could not be completed: ${review.error}`,
      )
    }
    if (parsedReview?.note) noteParts.push(parsedReview.note)
    if (parsedReview?.blocking.length) {
      noteParts.push(`Blocking: ${parsedReview.blocking.join('; ')}`)
    }
    // Recorded beside the blocking list rather than merged into it, so an
    // approver can see what was judged worth noting and what was judged worth
    // stopping for.
    if (parsedReview?.notes.length) noteParts.push(`Notes: ${parsedReview.notes.join('; ')}`)
    // Keyed on the exit code rather than the combined verdict: a surviving
    // break also fails `testsPassed`, and reporting that as "exited 0 …
    // failed" would send the reader looking at the wrong thing. The surviving
    // break gets its own line below.
    if (testResult && testResult.exitCode !== 0) {
      noteParts.push(`Verification failed: \`${testResult.command}\` exited ${testResult.exitCode}.`)
    }
    if (survivingMutations.length) {
      noteParts.push(
        `The tests did not catch ${survivingMutations.length} deliberate break${survivingMutations.length === 1 ? '' : 's'} this milestone said they would:\n` +
          survivingMutations
            .map((m) => `  • ${m.file}: ${m.describes} — the suite still passed.`)
            .join('\n'),
      )
    }
    if (unverifiable.length) {
      noteParts.push(
        `${unverifiable.length} verification check${unverifiable.length === 1 ? '' : 's'} could not be applied to the code as written, even after being re-anchored:\n` +
          unverifiable.map((m) => `  • ${m.file}: ${m.describes} — ${m.skipped}.`).join('\n'),
      )
    }
    if (!testResult) {
      noteParts.push(
        'Verification was not performed because this milestone has no verification command.',
      )
    }
    if (!parsedReview && !review.error) noteParts.push('The reviewer did not return a usable judgement.')

    current = this.repo.updateMilestone(milestoneId, {
      status: passed ? 'complete' : 'failed',
      adopted: passed,
      reviewNote: noteParts.join('\n\n'),
      reviewPassed,
      completedAt: passed ? Date.now() : null,
    })
    this.emit({ type: 'plan.milestone', milestone: current })

    const remaining = this.repo
      .listMilestones(plan.id)
      .filter((m) => m.status !== 'complete' && m.status !== 'rejected')
    this.setStatus(plan.id, passed && remaining.length === 0 ? 'complete' : passed ? 'ready' : 'failed')

    return current
  }

  private ingestAuditFindings(plan: WorkPlan, audit: ParsedAudit | null): void {
    if (!audit) return
    const milestones = this.repo.listMilestones(plan.id)
    for (const disposition of audit.dispositions) {
      if (disposition.disposition === 'accept' || !disposition.note.trim()) continue
      // Deliberately plan-level, never a milestone id. The audit judges the
      // draft, and correction deletes the draft milestones and recreates them
      // with new ids moments after this runs — an id recorded here dangled on
      // every normal drafting run, and the panel rendered it as an opaque
      // 'Milestone <shortId>'. Mapping draft indices onto corrected milestones
      // would be a guess wearing precision: correction may split, merge or
      // reorder. The milestone context lives in the finding text instead, where
      // it stays true no matter what happens to the plan.
      const context = milestones.find((milestone) => milestone.index === disposition.milestone)
      const text = context
        ? `Milestone ${disposition.milestone + 1} (${context.title}): ${disposition.note}`
        : disposition.note
      this.recordFindingOccurrence(plan, text, {
        milestoneId: null,
        round: null,
        kind: 'blocking',
        source: 'audit',
      })
    }
    for (const concern of audit.blockingConcerns) {
      if (!concern.trim()) continue
      this.recordFindingOccurrence(plan, concern, {
        milestoneId: null,
        round: null,
        kind: 'blocking',
        source: 'audit',
      })
    }
  }

  /**
   * The ledger consequences of a finished run, wherever it ran.
   *
   * These are exactly the writes the execution core cannot do — it states
   * facts and holds no record — and they were performed only on the local
   * path. A remote run raised findings into a callback that dropped them,
   * settled nothing on success, and never moved the plan's status, so a
   * milestone could complete on another machine and leave the plan looking
   * untouched.
   *
   * Paired in one method on purpose. Recording findings without settling them
   * is worse than dropping them: every remote run would leave open blocking
   * occurrences that gate the next approval, so a host that worked would make
   * the plan unrunnable. Whoever calls one must call the other, and the way to
   * guarantee that is for there to be one thing to call.
   */
  settleFinishedRun(
    plan: WorkPlan,
    milestoneId: Id,
    milestone: Milestone,
    reporter: MilestoneReporter,
  ): void {
    const passed = milestone.status === 'complete'
    if (passed) this.settleMilestoneReviewFindings(plan, milestoneId)

    const remaining = this.repo
      .listMilestones(plan.id)
      .filter((m) => m.status !== 'complete' && m.status !== 'rejected')
    // Computed HERE and not by the core, because it needs the plan's other
    // milestones — knowledge the machine that ran the work does not have.
    reporter.record({
      kind: 'planOutcome',
      status: passed && remaining.length === 0 ? 'complete' : passed ? 'ready' : 'failed',
    })
  }

  /** Ingests one observed finding as a ledger occurrence with its provenance. */
  ingestFinding(
    plan: WorkPlan,
    finding: Extract<MilestoneFact, { kind: 'finding' }>,
    milestoneId: Id,
  ): void {
    this.recordFindingOccurrence(plan, finding.text, {
      milestoneId,
      round: finding.round,
      kind: finding.blocking ? 'blocking' : 'note',
      source: finding.source,
    })
  }

  private recordFindingOccurrence(
    plan: WorkPlan,
    text: string,
    provenance: {
      milestoneId: Id | null
      round: number | null
      kind: 'blocking' | 'note'
      source: 'audit' | 'review' | 'adoption'
    },
  ): void {
    const finding = this.repo.upsertLedgerFinding(plan.sessionId, text)
    this.repo.recordFindingOccurrence({
      findingId: finding.id,
      planId: plan.id,
      ...provenance,
    })
    this.emitLedgerEntry(plan.sessionId, finding.id)
  }

  private settleMilestoneReviewFindings(plan: WorkPlan, milestoneId: Id): void {
    const dispositions = this.repo.listFindingDispositions(plan.sessionId)
    const occurrences = this.repo
      .listFindingOccurrences(plan.sessionId)
      .filter(
        (occurrence) =>
          occurrence.planId === plan.id &&
          occurrence.milestoneId === milestoneId &&
          occurrence.source === 'review' &&
          occurrence.kind === 'blocking' &&
          occurrenceState(occurrence, dispositions) === 'open',
      )

    // A milestone with no verification command can complete on review alone —
    // milestoneVerdict reads a null result as green there. Writing "passed
    // deterministic verification" into an immutable disposition would then
    // overstate what happened, permanently.
    const milestone = this.repo.getMilestone(milestoneId)
    const note = milestone?.testResult
      ? 'The milestone passed deterministic verification and independent review.'
      : 'The milestone passed independent review; it has no verification command, so no deterministic check ran.'
    for (const occurrence of occurrences) {
      this.repo.disposeFinding({
        findingId: occurrence.findingId,
        occurrenceId: occurrence.id,
        state: 'resolved',
        note,
        source: 'pipeline',
      })
      this.emitLedgerEntry(plan.sessionId, occurrence.findingId)
    }
  }

  /** Re-broadcasts the full plan row after a non-status field changed. */
  private emitPlanUpdated(planId: Id): void {
    const plan = this.repo.getPlan(planId)
    if (plan) this.emit({ type: 'plan.updated', plan })
  }

  private emitLedgerEntry(sessionId: Id, findingId: Id): void {
    // Assembled by the same module the IPC surface uses, so the event stream
    // and the panel can never disagree about what an entry contains — and per
    // finding, because rebuilding the session's whole ledger for every event
    // was churn that grew with the ledger itself.
    const entry = groupLedgerEntry(this.repo, sessionId, findingId)
    if (entry) this.emit({ type: 'session.ledger', entry })
  }

  /** Runs the milestone's verification command. Parley runs it, never an agent. */
  private setStatus(planId: Id, status: WorkPlan['status']): void {
    this.repo.setPlanStatus(planId, status)
    this.emit({ type: 'plan.status', planId, status })
    // Completion proposes closure on the backlog items this plan targeted — a
    // proposal, never a close; the human confirms. Worktree plans wait for
    // landing, the moment their work actually reaches the checkout.
    if (status === 'complete') {
      const plan = this.repo.getPlan(planId)
      if (plan && plan.isolation !== 'worktree') {
        proposeBacklogClosures(
          this.repo,
          planId,
          `Plan “${plan.title}” completed: every milestone passed verification and independent review.`,
          (event) => this.emit(event),
        )
      }
    }
  }

  /**
   * Live telemetry for a stage that has no milestone to hang it on.
   *
   * Drafting, auditing and correcting each run a full agent turn — minutes,
   * sometimes tens of them — and until this existed they reported nothing at
   * all. The text is whatever the adapter surfaces as activity: the file being
   * read, the command being run.
   */
  private stage(planId: Id, stage: WorkPlan['status'], text: string): void {
    this.emit({ type: 'plan.stage', planId, stage, text })
  }
}

// ─── Parsing ─────────────────────────────────────────────────────────────────

export interface ParsedPlan {
  title: string
  milestones: Array<{
    title: string
    intent: string
    expectedPaths: string[]
    testCommand: string
    mutations: Mutation[]
  }>
}

/**
 * Reads declared mutations, discarding anything unusable rather than failing the
 * whole plan over them.
 *
 * A mutation with no `find` text cannot be applied, and one whose `replace` is
 * identical to `find` changes nothing and would report a false pass — both are
 * dropped. A malformed mutation is a missing check, which the review will notice;
 * a rejected plan over one bad entry is a worse trade.
 */
export function parseMutations(value: unknown): Mutation[] {
  if (!Array.isArray(value)) return []
  const out: Mutation[] = []
  for (const entry of value.slice(0, 10)) {
    if (typeof entry !== 'object' || entry === null) continue
    const item = entry as Record<string, unknown>
    const file = safeString(item['file'], 300).trim()
    const find = safeString(item['find'], 4000)
    const replace = safeString(item['replace'], 4000)
    if (!file || !find.trim() || find === replace) continue
    out.push({ file, find, replace, describes: safeString(item['describes'], 500) })
  }
  return out
}

/**
 * Parley's own structural findings about a milestone, independent of the auditor.
 *
 * Kept separate from the audit because these are facts rather than opinions: they
 * hold whatever the auditor happened to notice, and an auditor that overlooks one
 * cannot make it untrue. Surfaced before approval, since that is the last point
 * where fixing the plan is cheap.
 */
export function structuralConcerns(milestone: Pick<Milestone, 'mutations' | 'testCommand'>): string[] {
  const out: string[] = []
  if (milestone.mutations.length > 0 && !milestone.testCommand.trim()) {
    out.push(
      `This milestone declares ${milestone.mutations.length} verification check${milestone.mutations.length === 1 ? '' : 's'} but no command to run, ` +
        `so none of them can be checked. Either give it a verification command or drop the checks — as written they only look like coverage.`,
    )
  }
  return out
}

export function parsePlan(text: string): ParsedPlan | null {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return null
  const raw = data['milestones']
  if (!Array.isArray(raw)) return null

  const milestones: ParsedPlan['milestones'] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const item = entry as Record<string, unknown>
    const title = safeString(item['title'], 300)
    if (!title) continue
    const paths = Array.isArray(item['expectedPaths'])
      ? item['expectedPaths'].filter((p): p is string => typeof p === 'string').slice(0, 60)
      : []
    milestones.push({
      title,
      intent: safeString(item['intent'], 2000),
      expectedPaths: paths,
      testCommand: safeString(item['testCommand'], 500),
      mutations: parseMutations(item['mutations']),
    })
  }
  if (!milestones.length) return null
  return { title: safeString(data['title'], 300), milestones }
}

/**
 * Reads a blocking question, if the agent asked one instead of answering.
 *
 * Returns empty unless `clarification` is the substantive content — an agent
 * that produced a plan *and* mentioned a question has not blocked on it.
 */
export function parseClarification(text: string): string {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return ''
  if (Array.isArray(data['milestones'])) return ''
  const question = safeString(data['clarification'], 4000)
  if (!question) return ''
  const context = safeString(data['context'], 4000)
  return context ? `${question}\n\n${context}` : question
}

export interface ParsedCorrection extends ParsedPlan {
  dispositions: Array<{ finding: string; disposition: string; note: string }>
}

/** A corrected plan plus the planner's answer to each audit finding. */
export function parseCorrection(text: string): ParsedCorrection | null {
  const plan = parsePlan(text)
  if (!plan) return null

  const { data } = extractJson<Record<string, unknown>>(text)
  const raw = Array.isArray(data?.['dispositions']) ? (data?.['dispositions'] as unknown[]) : []
  const dispositions: ParsedCorrection['dispositions'] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const item = entry as Record<string, unknown>
    const finding = safeString(item['finding'], 600)
    if (!finding) continue
    dispositions.push({
      finding,
      disposition: oneOf(
        item['disposition'],
        ['accepted', 'partly-accepted', 'rejected', 'deferred'] as const,
        'accepted',
      ),
      note: safeString(item['note'], 1000),
    })
  }
  return { ...plan, dispositions }
}

/** The auditor's own findings, kept for the record alongside the planner's reply. */
/**
 * Guards the seam between the auditor's reply and the milestones it judges.
 *
 * AUDIT_CONTRACT says "index milestones from 0", but nothing enforced it: an
 * auditor that counted from 1 — the natural prose habit — shifted every
 * disposition one milestone late, the first milestone read "no disposition
 * recorded" (which does not block approval), a REJECT landed on the wrong
 * milestone, and the last disposition matched nothing and vanished. All
 * silently, and the 0-based mock meant no test could ever see it.
 *
 * The shift is applied only on proof, not on suspicion: no index 0, index
 * `count` present, everything inside [1..count]. That signature cannot be
 * produced by a 0-based reply. Anything else out of range is discarded loudly —
 * a disposition that vanishes unheard is the exact silence failure the audit
 * stage exists to prevent.
 */
export function alignAudit(
  audit: ParsedAudit | null,
  milestoneCount: number,
): { audit: ParsedAudit | null; note: string } {
  if (!audit || audit.dispositions.length === 0 || milestoneCount === 0) {
    return { audit, note: '' }
  }
  const indices = audit.dispositions.map((d) => d.milestone)
  const provablyOneBased =
    !indices.includes(0) &&
    indices.includes(milestoneCount) &&
    indices.every((i) => i >= 1 && i <= milestoneCount)
  if (provablyOneBased) {
    return {
      audit: {
        ...audit,
        dispositions: audit.dispositions.map((d) => ({ ...d, milestone: d.milestone - 1 })),
      },
      note: 'The auditor numbered milestones from 1 rather than 0; its dispositions were realigned before being applied.',
    }
  }
  const outOfRange = audit.dispositions.filter((d) => d.milestone >= milestoneCount)
  if (!outOfRange.length) return { audit, note: '' }
  return {
    audit: {
      ...audit,
      dispositions: audit.dispositions.filter((d) => d.milestone < milestoneCount),
    },
    note:
      `The audit referenced milestone${outOfRange.length === 1 ? '' : 's'} ` +
      `${outOfRange.map((d) => d.milestone + 1).join(', ')} which do${outOfRange.length === 1 ? 'es' : ''} not exist; ` +
      `${outOfRange.length === 1 ? 'that disposition was' : 'those dispositions were'} discarded rather than silently misapplied.`,
  }
}

export function summariseAudit(auditorVendor: string, audit: ParsedAudit | null): string {
  if (!audit) return `${auditorVendor} audited the plan but returned no usable findings.`
  const lines = [`${auditorVendor} audited the plan and judged it ${audit.verdict}.`]
  for (const d of audit.dispositions) {
    lines.push(`• milestone ${d.milestone + 1}: ${d.disposition.toUpperCase()} — ${d.note}`)
  }
  for (const concern of audit.blockingConcerns) lines.push(`• blocking: ${concern}`)
  return lines.join('\n')
}

/** Renders the dispositions for the record, flagging silence on any finding. */
export function renderDispositions(
  dispositions: ParsedCorrection['dispositions'],
): string {
  if (!dispositions.length) {
    return 'The planner reissued the plan but recorded no disposition against any audit finding, so it is not clear which objections were addressed.'
  }
  const lines = dispositions.map(
    (d) => `• ${d.disposition.toUpperCase()} — ${d.finding}${d.note ? `: ${d.note}` : ''}`,
  )
  return [`The planner answered the audit:`, ...lines].join('\n')
}

export interface ParsedAudit {
  verdict: 'sound' | 'needs-changes' | 'unsound'
  dispositions: Array<{ milestone: number; disposition: 'accept' | 'revise' | 'reject'; note: string }>
  blockingConcerns: string[]
}

export function parseAudit(text: string): ParsedAudit | null {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return null

  const raw = Array.isArray(data['dispositions']) ? data['dispositions'] : []
  const dispositions: ParsedAudit['dispositions'] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const item = entry as Record<string, unknown>
    const index = item['milestone']
    if (typeof index !== 'number' || !Number.isInteger(index) || index < 0) continue
    dispositions.push({
      milestone: index,
      disposition: oneOf(item['disposition'], ['accept', 'revise', 'reject'] as const, 'revise'),
      note: safeString(item['note'], 1000),
    })
  }

  const concerns = Array.isArray(data['blockingConcerns'])
    ? data['blockingConcerns'].filter((c): c is string => typeof c === 'string').slice(0, 20)
    : []

  return {
    verdict: oneOf(data['verdict'], ['sound', 'needs-changes', 'unsound'] as const, 'needs-changes'),
    dispositions,
    blockingConcerns: concerns,
  }
}

export function pathsOutsideScope(changed: string[], expected: string[]): string[] {
  if (!expected.length) return changed
  return changed.filter(
    (path) => !expected.some((e) => e === path || e.startsWith(path) || path.startsWith(e)),
  )
}
