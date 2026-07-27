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
  emptyUsage,
  type AgentConfig,
  type Id,
  type Milestone,
  type Mutation,
  type MutationResult,
  type TestResult,
  type Vendor,
  type WorkPlan,
} from '@shared/domain'
import { executionRefusal } from '@shared/execution'
import {
  adoptReviewPrompt,
  auditPrompt,
  correctionPrompt,
  executePrompt,
  planPrompt,
  remediationPrompt,
  mutationRepairPrompt,
  reviewDiffPrompt,
} from '@shared/protocol'
import { capture, isShellFree, splitCommand } from '@main/util/spawn'
import { newId, type Repo } from '@main/store/repo'
import { assertCapability, type AgentRegistry } from '@main/agents'
import type { MilestonePhase } from '@shared/events'
import type { OrchestratorDeps } from './types'

/**
 * How many times a rejected milestone may be handed back to its executor.
 *
 * Bounded deliberately. Each round costs a full execute-and-review cycle, and a
 * disagreement that survives two attempts is one a human should look at rather
 * than one more prompt.
 */
const MAX_REMEDIATION_ROUNDS = 2

const STAGE_TIMEOUT_MS = 30 * 60 * 1000
const TEST_TIMEOUT_MS = 20 * 60 * 1000
const MAX_DIFF_CHARS = 120_000

export class PipelineError extends Error {}

/** What a stage parked on a question needs in order to pick up again. */
type PendingStage =
  | { stage: 'planning'; brief: string; plannerResumeId: string | null }
  | {
      stage: 'correction'
      planText: string
      auditText: string
      auditorVendor: Vendor
      plannerResumeId: string | null
    }

/** Result of one verify-and-review pass. */
type VerifyOutcome =
  | { kind: 'unchanged'; milestone: Milestone }
  | {
      kind: 'reviewed'
      milestone: Milestone
      passed: boolean
      /** The reviewer's objections, which become the next round's brief. */
      concerns: string[]
      /** Its non-blocking remarks, kept apart so the surface can mute them. */
      reviewNotes: string[]
      reviewerNote: string
      reviewerResumeId: string | null
      testResult: TestResult | null
      testsPassed: boolean
      note: string
    }

/**
 * The audited execution pipeline.
 *
 * The separation of powers is the product:
 *
 *   plan (read-only)  →  audit by a different vendor (read-only)
 *                     →  human approval, single-use
 *                     →  execute one milestone (write)
 *                     →  deterministic tests, run by Parley
 *                     →  independent review of the diff by the vendor that did
 *                        not execute it
 *
 * No agent both writes code and certifies its own work, and no repository write
 * happens without a recorded approval that is spent in the act of starting.
 */
export class Pipeline {
  private readonly repo: Repo
  private readonly registry: AgentRegistry
  private readonly emit: OrchestratorDeps['emit']
  // `registry` is read for `.mock` as well as for adapters — see the unchanged-
  // tree branch in runMilestone.

  constructor(deps: OrchestratorDeps) {
    this.repo = deps.repo
    this.registry = deps.registry
    this.emit = deps.emit
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
        answer,
      },
      signal,
    )
  }

  private async runPlanning(
    plan: WorkPlan,
    input: { brief: string; answer?: string; resumeId?: string | null },
    signal?: AbortSignal,
  ): Promise<Milestone[]> {
    this.setStatus(plan.id, 'drafting')

    const greenfield = await isGreenfield(plan.repoPath, signal)
    const planner = this.registry.get(plan.planner.vendor)
    const drafted = await planner.run({
      systemPrompt:
        'You plan changes to real codebases. You are read-only in this turn. A plan naming files that do not exist is worse than no plan.',
      prompt: planPrompt(plan.kind, input.brief, plan.repoPath, input.answer ?? '', greenfield),
      cfg: plan.planner,
      capability: 'read',
      cwd: plan.repoPath,
      resumeId: input.resumeId ?? null,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => this.stage(plan.id, 'drafting', text),
    })
    this.repo.addPlanUsage(plan.id, drafted.usage)

    if (drafted.error) {
      this.setStatus(plan.id, 'failed')
      throw new PipelineError(`planning failed: ${drafted.error}`)
    }

    const question = parseClarification(drafted.text)
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
    this.setStatus(plan.id, 'auditing')

    const auditorVendor = this.registry.counterpart(plan.planner.vendor)
    const result = await this.registry.get(auditorVendor).run({
      systemPrompt:
        'You audit other engineers\u2019 plans before any code is written. You did not write this plan; your value is catching what its author assumed without checking. You are read-only.',
      prompt: auditPrompt(planText, plan.repoPath, greenfield),
      cfg: { ...plan.executor, vendor: auditorVendor },
      capability: 'read',
      cwd: plan.repoPath,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => this.stage(plan.id, 'auditing', text),
    })
    this.repo.addPlanUsage(plan.id, result.usage)

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

    // Persisted now rather than after correction. Correction has two paths that
    // overwrite this note, and the auditor's findings must not leave with them.
    const auditSummary = [alignmentNote, summariseAudit(auditorVendor, audit)]
      .filter(Boolean)
      .join('\n\n')
    this.repo.setPlanCorrectionNote(plan.id, auditSummary)

    return this.runCorrection(
      plan,
      { planText, auditText: result.text, auditorVendor, plannerResumeId, auditSummary },
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
      auditSummary?: string
      answer?: string
    },
    signal?: AbortSignal,
  ): Promise<Milestone[]> {
    this.setStatus(plan.id, 'correcting')

    const result = await this.registry.get(plan.planner.vendor).run({
      systemPrompt:
        'You are correcting your own plan after an independent audit. Answer every finding; do not let an inconvenient one disappear.',
      prompt: correctionPrompt({
        planText: input.planText,
        auditText: input.auditText,
        auditorVendor: input.auditorVendor,
        repoPath: plan.repoPath,
        answer: input.answer ?? '',
      }),
      cfg: plan.planner,
      capability: 'read',
      cwd: plan.repoPath,
      resumeId: input.plannerResumeId,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => this.stage(plan.id, 'correcting', text),
    })
    this.repo.addPlanUsage(plan.id, result.usage)

    if (result.error) {
      // The audited plan still stands; it simply was not amended.
      this.repo.setPlanCorrectionNote(
        plan.id,
        [
          input.auditSummary,
          `The planner could not answer the audit: ${result.error}. The plan below is the original draft, with the audit findings unaddressed.`,
        ]
          .filter(Boolean)
          .join('\n\n'),
      )
      this.setStatus(plan.id, 'ready')
      return this.repo.listMilestones(plan.id)
    }

    const question = parseClarification(result.text)
    if (question) {
      this.park(plan, question, {
        stage: 'correction',
        planText: input.planText,
        auditText: input.auditText,
        auditorVendor: input.auditorVendor,
        plannerResumeId: result.resumeId ?? input.plannerResumeId,
      })
      return []
    }

    const corrected = parseCorrection(result.text)
    if (!corrected || corrected.milestones.length === 0) {
      this.repo.setPlanCorrectionNote(
        plan.id,
        [
          input.auditSummary,
          'The planner did not return a usable corrected plan, so the original draft stands with the audit findings unaddressed.',
        ]
          .filter(Boolean)
          .join('\n\n'),
      )
      this.setStatus(plan.id, 'ready')
      return this.repo.listMilestones(plan.id)
    }

    // Both halves of the exchange, because the corrected milestones replace the
    // draft ones and would otherwise take the auditor's findings with them.
    this.repo.setPlanCorrectionDispositions(plan.id, corrected.dispositions)
    this.repo.setPlanCorrectionNote(
      plan.id,
      [input.auditSummary, renderDispositions(corrected.dispositions)].filter(Boolean).join('\n\n'),
    )
    if (corrected.title) this.repo.setPlanTitle(plan.id, corrected.title)

    // The corrected plan supersedes the draft wholesale — milestones may have
    // been split, reordered or dropped, so patching them would be guesswork.
    this.repo.clearMilestones(plan.id)
    this.writeMilestones(plan.id, corrected, 'audited')

    this.setStatus(plan.id, 'ready')
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
  async runMilestone(milestoneId: Id, approvalId: Id, signal?: AbortSignal): Promise<Milestone> {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new PipelineError('no such milestone')

    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new PipelineError('the plan for this milestone is missing')
    const refusal = executionRefusal(plan, milestone)
    if (refusal) throw new PipelineError(refusal)

    // Spend the approval before anything can write. Throws if already spent.
    this.repo.consumeApproval(approvalId, 'milestone.execute', milestoneId)
    assertCapability('write', true)

    // Clear the previous attempt's artifacts. Without this a retry shows the old
    // test output and the old review note beside the new outcome, and the two
    // get read as if they belonged to the same run.
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
    const before = await readTree(plan.repoPath, signal)

    const executor = this.registry.get(plan.executor.vendor)
    const activity = (phase: MilestonePhase, text: string): void => {
      this.emit({ type: 'plan.activity', milestoneId, phase, text })
    }

    const reviewerVendor =
      plan.reviewer.vendor === plan.executor.vendor
        ? this.registry.counterpart(plan.executor.vendor)
        : plan.reviewer.vendor
    const reviewer = this.registry.get(reviewerVendor)

    // Both sides are resumed across rounds. The executor keeps everything it
    // already did, so remediation costs a critique rather than a restatement of
    // the milestone; the reviewer keeps its own objections, so it can check
    // whether they were actually met instead of forming a fresh opinion.
    let executorResumeId: string | null = null
    let reviewerResumeId: string | null = null

    let round = 0
    let previousConcerns: string[] = []
    let lastReviewNote = ''
    let lastTestResult: TestResult | null = null
    // Tracked explicitly rather than re-derived at the end from `reviewPassed`:
    // that would let a milestone whose tests failed complete on the strength of
    // a satisfied reviewer, which is the exact weak signal this pipeline exists
    // to strengthen.
    let lastPassed = false
    const history: string[] = []

    /**
     * Persists the review history as it accumulates, rather than at the end.
     *
     * `reviewPassed` is written the moment a review concludes, but the note used
     * to be assembled only after this loop exited — so throughout a remediation
     * round the record said a review had failed and nothing about why. That is
     * precisely the window in which the objection is worth reading, and it was
     * withheld: watching a real plan run, the reviewer's reasoning had to be
     * inferred from which files the executor touched next.
     */
    // The prose assembly and the structured lists are written together so the
    // record cannot show a blocking finding the note does not mention, or vice
    // versa. Only the latest round's lists are kept: they are what is outstanding,
    // while `reviewNote` carries the whole history.
    let lastBlocking: string[] = []
    let lastNotes: string[] = []
    let lastMutationResults: MutationResult[] = []
    const publishHistory = (): void => {
      current = this.repo.updateMilestone(milestoneId, {
        reviewNote: history.join('\n\n'),
        reviewBlocking: lastBlocking,
        reviewNotes: lastNotes,
      })
      this.emit({ type: 'plan.milestone', milestone: current })
    }

    // ── Execute → verify → review, remediating a bounded number of times ─────
    for (;;) {
      const remediating = round > 0
      if (remediating) {
        current = this.repo.updateMilestone(milestoneId, { status: 'executing' })
        this.emit({ type: 'plan.milestone', milestone: current })
      }
      activity(
        'executing',
        remediating
          ? `${plan.executor.vendor} addressing ${previousConcerns.length} objection${previousConcerns.length === 1 ? '' : 's'} — round ${round} of ${MAX_REMEDIATION_ROUNDS}`
          : `${plan.executor.vendor} started on ${plan.repoPath}`,
      )

      const execution = await executor.run({
        systemPrompt:
          'You implement exactly one approved milestone in a real repository. Stay inside its scope. Do not commit.',
        prompt: remediating
          ? remediationPrompt({
              round,
              maxRounds: MAX_REMEDIATION_ROUNDS,
              concerns: previousConcerns,
              reviewerNote: lastReviewNote,
              testSummary: summariseTests(lastTestResult),
              // Without this, a mutation-only failure remediates blind: the
              // reviewer had no objections, the test summary reads green, and the
              // one actionable fact — which declared break survived — never
              // reaches the agent being asked to fix it.
              mutationSummary: summariseMutations(lastMutationResults),
              reviewerVendor,
            })
          : executePrompt(
              current.title,
              current.intent,
              current.expectedPaths,
              plan.repoPath,
              plan.correctionNote,
              current.testCommand,
            ),
        cfg: plan.executor,
        capability: 'write',
        cwd: plan.repoPath,
        resumeId: executorResumeId,
        signal,
        timeoutMs: STAGE_TIMEOUT_MS,
        // The adapters already report every tool use, file edit and command. This
        // is the only thing standing between the user and a half-hour spinner.
        onActivity: (text) => activity('executing', text),
      })
      this.repo.addPlanUsage(plan.id, execution.usage)
      if (execution.resumeId) executorResumeId = execution.resumeId

      if (execution.error) {
        current = this.repo.updateMilestone(milestoneId, {
          status: 'failed',
          reviewNote: [...history, execution.error].join('\n\n'),
        })
        this.emit({ type: 'plan.milestone', milestone: current })
        this.setStatus(plan.id, 'failed')
        return current
      }

      const outcome = await this.verifyAndReview({
        milestoneId,
        plan,
        before,
        round,
        previousConcerns,
        reviewer,
        reviewerVendor,
        reviewerResumeId,
        activity,
        signal,
        firstExecutionText: execution.text,
      })

      if (outcome.kind === 'unchanged') return outcome.milestone
      current = outcome.milestone
      reviewerResumeId = outcome.reviewerResumeId
      lastTestResult = outcome.testResult
      lastReviewNote = outcome.reviewerNote
      lastPassed = outcome.passed
      lastBlocking = outcome.concerns
      lastNotes = outcome.reviewNotes
      lastMutationResults = current.mutationResults
      history.push(outcome.note)
      publishHistory()

      if (outcome.passed) break

      // Another round is only worth spending if the reviewer said something the
      // executor can act on, and if we have not already used our budget.
      if (round >= MAX_REMEDIATION_ROUNDS) {
        history.push(
          `Stopped after the ${MAX_REMEDIATION_ROUNDS}-round remediation budget. The objections above are unresolved and need a person.`,
        )
        publishHistory()
        break
      }
      // A failing verification is actionable even when the reviewer raised
      // nothing: the executor can read the test output and fix it. Only stop
      // when there is genuinely nothing to hand back.
      if (!outcome.concerns.length && outcome.testsPassed) {
        history.push('No remediation was attempted: there was no specific objection to act on.')
        publishHistory()
        break
      }

      previousConcerns = outcome.concerns
      round += 1
    }

    const finalPassed = lastPassed
    current = this.repo.updateMilestone(milestoneId, {
      status: finalPassed ? 'complete' : 'failed',
      reviewNote: history.join('\n\n'),
      completedAt: finalPassed ? Date.now() : null,
    })
    this.emit({ type: 'plan.milestone', milestone: current })

    const remaining = this.repo
      .listMilestones(plan.id)
      .filter((m) => m.status !== 'complete' && m.status !== 'rejected')
    this.setStatus(
      plan.id,
      finalPassed && remaining.length === 0 ? 'complete' : finalPassed ? 'ready' : 'failed',
    )
    return current
  }

  /**
   * One verify-and-review pass over whatever the executor just did.
   *
   * Split out of {@link runMilestone} so the remediation loop reads as a loop
   * rather than three hundred lines of nesting.
   */
  private async verifyAndReview(input: {
    milestoneId: Id
    plan: WorkPlan
    before: TreeState
    round: number
    previousConcerns: string[]
    reviewer: ReturnType<AgentRegistry['get']>
    reviewerVendor: Vendor
    reviewerResumeId: string | null
    activity: (phase: MilestonePhase, text: string) => void
    signal?: AbortSignal
    firstExecutionText: string
  }): Promise<VerifyOutcome> {
    const { milestoneId, plan, before, round, activity, signal } = input
    let current = this.repo.getMilestone(milestoneId)
    if (!current) throw new PipelineError('milestone disappeared mid-run')

    // ── Confirm something actually changed ───────────────────────────────────
    //
    // Checked before the tests and before the review, both of which would
    // otherwise sail through: an unchanged tree usually still passes its tests,
    // and a reviewer handed a diff containing none of the milestone's work has
    // nothing to object to. An executor that reports success while writing
    // nothing is a failure, not a pass.
    const after = await readTree(plan.repoPath, signal)
    const missing = missingExpectedPaths(plan.repoPath, current.expectedPaths)

    if (treeUnchanged(before, after)) {
      // Three genuinely different situations, which need three different
      // explanations. The middle one is the trap: every expected file already
      // exists, usually left behind by an earlier attempt, and the executor
      // sensibly declined to overwrite work it did not recognise.
      const detail = !current.expectedPaths.length
        ? ''
        : missing.length === 0
          ? ` Every path the plan named already exists (${current.expectedPaths.join(', ')}). ` +
            'They were most likely left by an earlier attempt, and the executor declined to overwrite them. ' +
            'Either commit or delete that work before retrying, so the executor has a clean slate.'
          : missing.length === current.expectedPaths.length
            ? ` The plan expected it to create or modify ${current.expectedPaths.join(', ')}; none of those exist.`
            : ` The plan expected ${current.expectedPaths.join(', ')}; these do not exist: ${missing.join(', ')}.`
      // Under the mocks this is worth calling out, but not as it once was: the mock
      // executor does write a placeholder, so an unchanged tree here is no longer
      // explained by mock mode itself and usually means the path is not writable.
      const cause = this.registry.mock
        ? ' Parley is running with PARLEY_MOCK=1. The mock executor writes one placeholder file, so an unchanged tree usually means the repository path is not writable rather than that mock mode cannot work.'
        : ` What it said: ${input.firstExecutionText.trim().slice(0, 600) || '(no report)'}`
      // If the work already exists, whether it *passes* is the thing the user
      // needs in order to decide between committing it and starting over. The
      // milestone still fails — it did nothing — but failing without answering
      // that question just sends them to a terminal to ask it themselves.
      let existingWorkNote = ''
      if (missing.length === 0 && current.expectedPaths.length > 0 && current.testCommand) {
        activity('testing', `checking whether the existing work passes ${current.testCommand}`)
        const existingResult = await this.runTests(current.testCommand, plan.repoPath, signal)
        if (existingResult) {
          current = this.repo.updateMilestone(milestoneId, { testResult: existingResult })
          existingWorkNote =
            existingResult.exitCode === 0
              ? ` The work already present does pass \`${existingResult.command}\`, so committing it may be all this milestone needed.`
              : ` The work already present does not pass \`${existingResult.command}\` (exit ${existingResult.exitCode}), so it is unfinished rather than done.`
        }
      }

      current = this.repo.updateMilestone(milestoneId, {
        status: 'failed',
        reviewPassed: false,
        reviewNote:
          `${plan.executor.vendor} reported finishing this milestone, but the working tree is byte-for-byte unchanged — ` +
          `no tracked edits, nothing staged, no new files.${detail}${existingWorkNote}` +
          cause,
      })
      this.emit({ type: 'plan.milestone', milestone: current })
      this.setStatus(plan.id, 'failed')
      return { kind: 'unchanged', milestone: current }
    }

    // ── Verify deterministically ─────────────────────────────────────────────
    current = this.repo.updateMilestone(milestoneId, { status: 'testing' })
    this.emit({ type: 'plan.milestone', milestone: current })

    activity(
      'testing',
      current.testCommand ? `running ${current.testCommand}` : 'no verification command defined',
    )
    const testResult = await this.runTests(current.testCommand, plan.repoPath, signal)
    if (testResult) {
      activity(
        'testing',
        `${testResult.command} exited ${testResult.exitCode} in ${(testResult.durationMs / 1000).toFixed(1)}s`,
      )
    }
    current = this.repo.updateMilestone(milestoneId, { testResult })
    this.emit({ type: 'plan.milestone', milestone: current })

    // ── Mutation checks ──────────────────────────────────────────────────────
    //
    // Only worth running against a green suite: with a red one every mutation
    // "fails" and proves nothing. This is where a milestone earns the claim that
    // its tests would catch a wrong implementation, rather than merely that this
    // implementation happens to pass.
    let mutationResults: MutationResult[] = []
    const testsGreen = testResult === null || testResult.exitCode === 0
    if (testsGreen && current.mutations.length > 0) {
      activity(
        'testing',
        `checking that the tests catch ${current.mutations.length} deliberate break${current.mutations.length === 1 ? '' : 's'}`,
      )
      mutationResults = await this.runMutations(current, plan.repoPath, signal)
      // A stale anchor is expected — the planner wrote it before this code existed —
      // so it gets one chance to be re-resolved against the file rather than being
      // shrugged off as unchecked or blocking the milestone on a guess.
      if (mutationResults.some((m) => m.skipKind === 'unapplied')) {
        mutationResults = await this.repairMutations(
          current,
          mutationResults,
          input,
          plan,
          activity,
          signal,
        )
      }
      const survived = mutationResults.filter((m) => !m.caught && !m.skipped)
      activity(
        'testing',
        survived.length === 0
          ? 'every deliberate break was caught'
          : `${survived.length} deliberate break${survived.length === 1 ? '' : 's'} went undetected`,
      )
      current = this.repo.updateMilestone(milestoneId, { mutationResults })
      this.emit({ type: 'plan.milestone', milestone: current })
    }

    // ── Independent review ───────────────────────────────────────────────────
    current = this.repo.updateMilestone(milestoneId, { status: 'reviewing' })
    this.emit({ type: 'plan.milestone', milestone: current })

    const reviewerVendor =
      plan.reviewer.vendor === plan.executor.vendor
        ? this.registry.counterpart(plan.executor.vendor)
        : plan.reviewer.vendor
    const reviewer = this.registry.get(reviewerVendor)

    activity(
      'reviewing',
      round > 0
        ? `${input.reviewerVendor} re-reviewing after remediation`
        : `${input.reviewerVendor} reviewing the diff`,
    )
    const review = await input.reviewer.run({
      onActivity: (text) => activity('reviewing', text),
      systemPrompt:
        'You review a diff written by a different agent. Passing tests are necessary, not sufficient. You are read-only.',
      prompt: reviewDiffPrompt(
        current.title,
        current.intent,
        renderDiffForReview(after, before),
        summariseTests(testResult),
        input.previousConcerns,
        summariseMutations(mutationResults),
        missing,
      ),
      cfg: reviewerConfig(plan.reviewer, input.reviewerVendor),
      capability: 'read',
      cwd: plan.repoPath,
      resumeId: input.reviewerResumeId,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
    })
    this.repo.addPlanUsage(plan.id, review.usage)

    const parsedReview = parseReview(review.text)
    // Tests must be green *and* every declared break must have been caught *and*
    // the independent reviewer must pass it. Any one alone is exactly the weak
    // signal this pipeline exists to strengthen. A surviving mutation is counted
    // with the tests rather than left to the reviewer's judgement, because it is
    // the same kind of fact: deterministic, reproducible, and not a matter of
    // opinion. The milestone said its tests would catch this, and they did not.
    const {
      testsPassed,
      surviving: survivingMutations,
      unverifiable,
      notRunnable,
    } = milestoneVerdict(testResult, mutationResults)
    const reviewPassed = parsedReview?.passed === true
    const passed = missing.length === 0 && testsPassed && reviewPassed
    const missingConcern =
      missing.length > 0
        ? `Create or restore every declared output before this milestone can pass. Missing: ${missing.join(', ')}.`
        : null

    const noteParts: string[] = []
    noteParts.push(
      round === 0
        ? `Round 1 — ${plan.executor.vendor} executed, ${input.reviewerVendor} reviewed.`
        : `Round ${round + 1} — ${plan.executor.vendor} remediated, ${input.reviewerVendor} re-reviewed.`,
    )
    if (missing.length) {
      // A frequent and otherwise invisible failure: the executor wrote
      // *something*, but not the files the plan named, so the test command that
      // targets those paths cannot possibly pass.
      noteParts.push(
        `The plan expected these paths, and they do not exist: ${missing.join(', ')}.`,
      )
    }
    if (review.error) noteParts.push(`The review could not be completed: ${review.error}`)
    if (parsedReview?.note) noteParts.push(parsedReview.note)
    if (parsedReview?.blocking.length) {
      noteParts.push(`Blocking: ${parsedReview.blocking.join('; ')}`)
    }
    // Recorded beside the blocking list rather than merged into it, so an
    // approver can see what was judged worth noting and what was judged worth
    // stopping for.
    if (parsedReview?.notes.length) noteParts.push(`Notes: ${parsedReview.notes.join('; ')}`)
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
    if (notRunnable.length) {
      noteParts.push(
        `${notRunnable.length} check${notRunnable.length === 1 ? '' : 's'} could not run because this milestone has no verification command.`,
      )
    }
    if (!parsedReview && !review.error) noteParts.push('The reviewer did not return a usable judgement.')

    current = this.repo.updateMilestone(milestoneId, { reviewPassed })
    this.emit({ type: 'plan.milestone', milestone: current })

    return {
      kind: 'reviewed',
      milestone: current,
      passed,
      // Blocking only. Remediation is told to fix what was named and nothing
      // else; feeding it taste would contradict that in the same breath.
      concerns: [...(missingConcern ? [missingConcern] : []), ...(parsedReview?.blocking ?? [])],
      reviewNotes: parsedReview?.notes ?? [],
      reviewerNote: parsedReview?.note ?? '',
      reviewerResumeId: review.resumeId ?? input.reviewerResumeId,
      testResult,
      testsPassed,
      note: noteParts.join('\n\n'),
    }
  }

  /**
   * Verifies work that is already in the tree, without executing anything.
   *
   * The situation this exists for: an interrupted run leaves a milestone's files
   * behind, so every retry finds them already present, the executor declines to
   * overwrite them, and the milestone can never succeed — while the work itself
   * sits there finished. Deleting it to make the pipeline happy would throw away
   * good code; marking it done by hand would put a lie in the audit trail.
   *
   * So: skip execution, keep both checks that actually establish anything — the
   * deterministic tests and the independent cross-vendor review — and record
   * `adopted: true` so the trail says plainly that Parley did not write this.
   *
   * Needs no approval, because it writes nothing.
   */
  async adoptMilestone(milestoneId: Id, signal?: AbortSignal): Promise<Milestone> {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new PipelineError('no such milestone')

    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new PipelineError('the plan for this milestone is missing')
    const refusal = executionRefusal(plan, milestone)
    if (refusal) throw new PipelineError(refusal)

    const tree = await readTree(plan.repoPath, signal)
    if (!tree.unknown && tree.paths.length === 0) {
      throw new PipelineError(
        'there is nothing to adopt — the working tree is clean, so no existing work matches this milestone',
      )
    }

    const missing = missingExpectedPaths(plan.repoPath, milestone.expectedPaths)
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

    let current = this.repo.updateMilestone(milestoneId, {
      status: 'testing',
      testResult: null,
      reviewNote: '',
      reviewPassed: null,
    })
    this.emit({ type: 'plan.milestone', milestone: current })
    this.setStatus(plan.id, 'running')

    // ── Deterministic verification ───────────────────────────────────────────
    activity('testing', current.testCommand ? `running ${current.testCommand}` : 'no verification command defined')
    const testResult = await this.runTests(current.testCommand, plan.repoPath, signal)
    if (testResult) {
      activity(
        'testing',
        `${testResult.command} exited ${testResult.exitCode} in ${(testResult.durationMs / 1000).toFixed(1)}s`,
      )
    }
    current = this.repo.updateMilestone(milestoneId, { testResult, status: 'reviewing' })
    this.emit({ type: 'plan.milestone', milestone: current })

    // ── Independent review ───────────────────────────────────────────────────
    const reviewerVendor =
      plan.reviewer.vendor === plan.executor.vendor
        ? this.registry.counterpart(plan.executor.vendor)
        : plan.reviewer.vendor
    activity('reviewing', `${reviewerVendor} reviewing work already in the tree`)

    const review = await this.registry.get(reviewerVendor).run({
      systemPrompt:
        'You review code that was already present in a repository. Nobody authored it under supervision, so it has to stand on its own. You are read-only.',
      prompt: adoptReviewPrompt(
        current.title,
        current.intent,
        renderDiffForReview(tree, emptyTree()),
        summariseTests(testResult),
        unverified,
        missing,
      ),
      cfg: reviewerConfig(plan.reviewer, reviewerVendor),
      capability: 'read',
      cwd: plan.repoPath,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
      onActivity: (text) => activity('reviewing', text),
    })
    this.repo.addPlanUsage(plan.id, review.usage)

    const parsedReview = parseReview(review.text)
    const testsPassed = testResult !== null && testResult.exitCode === 0
    const reviewPassed = parsedReview?.passed === true
    const passed = missing.length === 0 && testsPassed && reviewPassed

    // The opening line states the *mode*, then the outcome. Leading with
    // "Adopted" on a run that was rejected would claim the opposite of what
    // happened.
    const noteParts = [
      passed
        ? `Adopted, not executed: this work was already in the tree when Parley found it, so no agent authored it under supervision. It was verified, not written, and both checks passed.`
        : `Not adopted. This work was already in the tree, so it was verified rather than written — and the verification did not pass.`,
    ]

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
    if (review.error) noteParts.push(`The review could not be completed: ${review.error}`)
    if (parsedReview?.note) noteParts.push(parsedReview.note)
    if (parsedReview?.blocking.length) {
      noteParts.push(`Blocking: ${parsedReview.blocking.join('; ')}`)
    }
    // Recorded beside the blocking list rather than merged into it, so an
    // approver can see what was judged worth noting and what was judged worth
    // stopping for.
    if (parsedReview?.notes.length) noteParts.push(`Notes: ${parsedReview.notes.join('; ')}`)
    if (!testsPassed && testResult) {
      noteParts.push(`Verification failed: \`${testResult.command}\` exited ${testResult.exitCode}.`)
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

  /** Runs the milestone's verification command. Parley runs it, never an agent. */
  private async runTests(
    command: string,
    cwd: string,
    signal?: AbortSignal,
  ): Promise<TestResult | null> {
    const trimmed = command.trim()
    if (!trimmed) return null

    if (!isShellFree(trimmed)) {
      return {
        command: trimmed,
        exitCode: -1,
        signal: null,
        timedOut: false,
        stdout: '',
        stderr:
          'This verification command needs shell syntax, which Parley will not run. Put it in a script and name the script instead.',
        durationMs: 0,
        ranAt: Date.now(),
      }
    }
    const argv = splitCommand(trimmed)
    if (!argv || !argv[0]) {
      return {
        command: trimmed,
        exitCode: -1,
        signal: null,
        timedOut: false,
        stdout: '',
        stderr: 'Could not parse this verification command.',
        durationMs: 0,
        ranAt: Date.now(),
      }
    }

    const [file, ...args] = argv
    const result = await capture(file as string, args, cwd, TEST_TIMEOUT_MS, signal)
    return {
      command: trimmed,
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
      stdout: tail(result.stdout, 8000),
      stderr: tail(result.stderr, 8000),
      durationMs: result.durationMs,
      ranAt: Date.now(),
    }
  }

  /**
   * Applies each declared mutation and requires the verification command to fail.
   *
   * The point is to test the tests. A green suite says the code works on the
   * paths someone thought to exercise; it says nothing about whether a plausible
   * wrong implementation would have been caught, and that is where every serious
   * defect in this pipeline's first real use actually lived.
   *
   * Files are edited in place and restored in a `finally`, deliberately rather
   * than working on a copy: the verification command is only known to work in the
   * real tree, where its relative paths, installed dependencies and engine
   * project files all resolve. The window is one test run, the original content
   * is held in memory throughout, and a failure to restore is reported loudly
   * rather than swallowed — leaving a mutated file behind would be far worse than
   * skipping the check.
   *
   * Only ever called once the tests have already passed. Running mutations
   * against a red suite proves nothing, since every mutation would "fail".
   */
  /**
   * Re-resolves mutation anchors that did not match the code as written.
   *
   * Runs before the review, using the reviewer's vendor — never the executor's.
   * The executor is the party graded by the outcome of these checks, so letting it
   * choose where they point would be self-verification by another name.
   *
   * Returns the merged results. A mutation that still cannot be applied after this
   * is left with `skipKind: 'unapplied'`, and the caller fails the milestone on it:
   * one stale guess is expected, but a check that cannot be expressed against the
   * finished code twice over is not a guess any more.
   */
  private async repairMutations(
    milestone: Milestone,
    results: MutationResult[],
    input: {
      reviewer: ReturnType<AgentRegistry['get']>
      reviewerVendor: Vendor
      reviewerResumeId: string | null
    },
    plan: WorkPlan,
    activity: (phase: MilestonePhase, text: string) => void,
    signal?: AbortSignal,
  ): Promise<MutationResult[]> {
    // Position in `milestone.mutations` is the identity used with the model, so the
    // original index has to survive the filter.
    const stale = results
      .map((result, at) => ({ result, at }))
      .filter(({ result }) => result.skipKind === 'unapplied')
    if (!stale.length) return results

    // One record per asked-about mutation, carrying its own position in
    // `milestone.mutations`. Deliberately not two parallel arrays: the model is given
    // 1-based indices into this list and the answer has to map back to the right
    // mutation, and a pair of arrays kept aligned only by adjacent pushes would let a
    // later edit send check B's repair to check A — which re-runs green and reports a
    // check as caught that was never relocated at all.
    const asked: {
      at: number
      mutation: Mutation
      item: { describes: string; file: string; find: string; reason: string; contents: string }
    }[] = []
    for (const { result, at } of stale) {
      const mutation = milestone.mutations[at]
      if (!mutation) continue
      const target = join(plan.repoPath, mutation.file)
      // Nothing to re-anchor against if the file is not there; that is a different
      // failure and the existing skip reason already says so.
      if (!existsSync(target)) continue
      let contents: string
      try {
        contents = readFileSync(target, 'utf8')
      } catch {
        continue
      }
      asked.push({
        at,
        mutation,
        item: {
          describes: mutation.describes,
          file: mutation.file,
          find: mutation.find,
          reason: result.skipped,
          contents: contents.length > 20000 ? `${contents.slice(0, 20000)}\n… truncated …` : contents,
        },
      })
    }
    if (!asked.length) return results
    const items = asked.map((a) => a.item)

    activity(
      'testing',
      `re-anchoring ${items.length} verification check${items.length === 1 ? '' : 's'} against the code as written`,
    )
    const reply = await input.reviewer.run({
      onActivity: (text) => activity('testing', text),
      systemPrompt:
        'You relocate a verification check to match code written by a different agent. You may not weaken what it checks. You are read-only.',
      prompt: mutationRepairPrompt(items),
      cfg: reviewerConfig(plan.reviewer, input.reviewerVendor),
      capability: 'read',
      cwd: plan.repoPath,
      resumeId: input.reviewerResumeId,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
    })
    this.repo.addPlanUsage(plan.id, reply.usage)
    if (reply.error) {
      activity('testing', `the re-anchoring could not be completed: ${reply.error}`)
      return results
    }

    const { repairs, impossible } = parseMutationRepairs(reply.text)
    const merged = [...results]
    for (const [position, { at, mutation: original }] of asked.entries()) {
      const slot = position + 1 // the model is given 1-based indices

      const why = impossible.get(slot)
      if (why) {
        merged[at] = { ...merged[at]!, skipped: `${merged[at]!.skipped}; cannot be checked here: ${why}` }
        continue
      }
      const repair = repairs.get(slot)
      if (!repair) continue

      const outcome = await withMutationApplied(
        plan.repoPath,
        { ...original, ...repair },
        () => this.runTests(milestone.testCommand, plan.repoPath, signal),
      )
      const judged = judgeMutation(original, outcome)
      merged[at] = judged.skipKind === 'unapplied'
        ? { ...judged, skipped: `the re-anchored edit also failed: ${judged.skipped}` }
        : judged
    }

    const fixed = merged.filter((m, at) => results[at]?.skipKind === 'unapplied' && m.skipKind !== 'unapplied')
    activity(
      'testing',
      fixed.length
        ? `re-anchored ${fixed.length} of ${items.length} check${items.length === 1 ? '' : 's'}`
        : 'none of the checks could be re-anchored',
    )
    return merged
  }

  private async runMutations(
    milestone: Milestone,
    repoPath: string,
    signal?: AbortSignal,
  ): Promise<MutationResult[]> {
    const results: MutationResult[] = []
    for (const mutation of milestone.mutations) {
      const outcome = await withMutationApplied(repoPath, mutation, () =>
        this.runTests(milestone.testCommand, repoPath, signal),
      )
      results.push(judgeMutation(mutation, outcome))
    }
    return results
  }

  private setStatus(planId: Id, status: WorkPlan['status']): void {
    this.repo.setPlanStatus(planId, status)
    this.emit({ type: 'plan.status', planId, status })
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
 * Reads the reply to {@link mutationRepairPrompt}.
 *
 * `impossible` is treated as a real answer rather than a failure. A reviewer that
 * says an intent cannot be checked against this file is telling us something worth
 * recording, and it is a far more useful reply than a fabricated anchor that would
 * pass by accident.
 */
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

export function parseMutationRepairs(text: string): {
  repairs: Map<number, { find: string; replace: string }>
  impossible: Map<number, string>
} {
  const repairs = new Map<number, { find: string; replace: string }>()
  const impossible = new Map<number, string>()
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return { repairs, impossible }

  const index = (item: Record<string, unknown>): number | null => {
    const raw = item['index']
    const n = typeof raw === 'number' ? raw : Number.parseInt(String(raw ?? ''), 10)
    return Number.isInteger(n) && n >= 1 && n <= 10 ? n : null
  }

  if (Array.isArray(data['repairs'])) {
    for (const entry of data['repairs'].slice(0, 10)) {
      if (typeof entry !== 'object' || entry === null) continue
      const item = entry as Record<string, unknown>
      const i = index(item)
      const find = safeString(item['find'], 4000)
      const replace = safeString(item['replace'], 4000)
      // A no-op edit is not a check, so it is dropped rather than run.
      if (i === null || !find.trim() || find === replace) continue
      repairs.set(i, { find, replace })
    }
  }
  if (Array.isArray(data['impossible'])) {
    for (const entry of data['impossible'].slice(0, 10)) {
      if (typeof entry !== 'object' || entry === null) continue
      const item = entry as Record<string, unknown>
      const i = index(item)
      if (i === null || repairs.has(i)) continue
      impossible.set(i, safeString(item['why'], 500) || 'no reason given')
    }
  }
  return { repairs, impossible }
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

/**
 * The config an agent actually runs with when its vendor was coerced.
 *
 * The pipeline overrides a same-vendor reviewer to the counterpart, but it used
 * to spread the configured record and swap only the vendor field — carrying a
 * vendor-specific model name across the boundary, so the codex CLI could be
 * invoked with a Claude model string. Effort and persona are vendor-neutral and
 * survive; the model does not, so a swap blanks it and the CLI falls back to its
 * own default.
 */
export function reviewerConfig(configured: AgentConfig, vendor: Vendor): AgentConfig {
  if (configured.vendor === vendor) return configured
  return { ...configured, vendor, model: '' }
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

export interface ParsedReview {
  passed: boolean
  /** Problems that must be fixed. Non-empty means the milestone did not pass. */
  blocking: string[]
  /** Recorded, not acted on. Never sent to remediation. */
  notes: string[]
  note: string
}

function stringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((v): v is string => typeof v === 'string' && v.trim().length > 0).slice(0, 30)
    : []
}

export function parseReview(text: string): ParsedReview | null {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return null
  if (typeof data['passed'] !== 'boolean') return null

  // `concerns` is the old single-list key. A model still using it has ignored
  // the schema, and the safe reading of an unclassified problem is that it
  // blocks — erring toward a milestone being handed back rather than shipped.
  const blocking = stringList(data['blocking'] ?? data['concerns'])

  return {
    // Derived, not read. The reviewer's own flag is not trusted against its own
    // findings: on three consecutive milestones a real defect was written down
    // and passed anyway, so a listed blocking problem now fails the milestone
    // whether or not the box was ticked. This is the whole point of the split —
    // it makes "acknowledged but shipped" impossible to express.
    passed: data['passed'] === true && blocking.length === 0,
    blocking,
    notes: stringList(data['notes']),
    note: safeString(data['note'], 2000),
  }
}

// ─── Repository inspection ───────────────────────────────────────────────────

/**
 * Collects the working-tree diff for review.
 *
 * Untracked files are listed separately because `git diff` does not show them,
 * and a milestone that adds a new file would otherwise be reviewed as an empty
 * diff — which would sail through.
 */
/**
 * A snapshot of the working tree.
 *
 * Captured before *and* after execution. Comparing the two is the only sound way
 * to answer "did this milestone change anything": comparing against a clean tree
 * assumes the repository started clean, and a single stray file — an exported
 * report, a leftover from an earlier attempt — silently defeats that assumption
 * and lets a milestone that wrote nothing proceed to tests and review.
 */
export interface TreeState {
  /** True when the directory is not a git repository, so nothing can be judged. */
  unknown: boolean
  /** Content-sensitive fingerprint of the whole working tree state. */
  signature: string
  /** Paths that differ from HEAD, tracked or not. */
  paths: string[]
  diffText: string
  stagedText: string
  statText: string
  untracked: string[]
  /**
   * Contents of paths that differ from HEAD.
   *
   * The HEAD content distinguishes a path that became clean from one that was
   * removed. Both sides are bounded, because a dirty `node_modules` would
   * otherwise be read into memory.
   */
  files: TreeFileSnapshot[]
}

export interface TreeFileSnapshot {
  path: string
  text: string | null
  truncated: boolean
  exists: boolean
  digest: string | null
  /** False when the digest could not be established (a failed git spawn), which
   * is different from the file being absent — unknown must not read as same. */
  digestKnown: boolean
  headText: string | null
  headTruncated: boolean
  headExists: boolean
  headDigest: string | null
  headDigestKnown: boolean
}

export async function readTree(repoPath: string, signal?: AbortSignal): Promise<TreeState> {
  const stat = await capture('git', ['--no-pager', 'diff', '--stat'], repoPath, 60_000, signal)
  if (stat.exitCode !== 0) {
    return {
      unknown: true,
      signature: '',
      paths: [],
      diffText: '',
      stagedText: '',
      statText: '',
      untracked: [],
      files: [],
    }
  }

  const [full, staged, stagedStat, others, unstagedNames, stagedNames] = await Promise.all([
    // --no-renames on the content diffs as well as the name lists: a rename must
    // reach the reviewer as a removal plus an addition with full content, not as
    // two lines of content-free metadata.
    capture('git', ['--no-pager', 'diff', '--no-renames'], repoPath, 120_000, signal),
    capture('git', ['--no-pager', 'diff', '--no-renames', '--cached'], repoPath, 120_000, signal),
    capture('git', ['--no-pager', 'diff', '--cached', '--stat'], repoPath, 60_000, signal),
    capture('git', ['ls-files', '--others', '--exclude-standard'], repoPath, 60_000, signal),
    capture('git', ['diff', '--no-renames', '--name-only', '-z'], repoPath, 60_000, signal),
    capture('git', ['diff', '--cached', '--no-renames', '--name-only', '-z'], repoPath, 60_000, signal),
  ])

  const untracked = others.stdout.split('\n').map((l) => l.trim()).filter(Boolean)

  // Untracked content is not in git, so fingerprint it from the filesystem.
  // Size and mtime together move on any write, which is all this needs to do.
  const untrackedStamps = untracked.map((rel) => {
    try {
      const info = statSync(join(repoPath, rel))
      return `${rel}:${info.size}:${info.mtimeMs}`
    } catch {
      return `${rel}:missing`
    }
  })

  const trackedPaths = new Set(
    `${unstagedNames.stdout}\0${stagedNames.stdout}`.split('\0').filter(Boolean),
  )

  const signature = createHash('sha256')
    .update(full.stdout)
    .update('\0')
    .update(staged.stdout)
    .update('\0')
    .update(untrackedStamps.join('\n'))
    .digest('hex')

  const paths = [...trackedPaths, ...untracked].sort()

  return {
    unknown: false,
    signature,
    paths,
    diffText: full.stdout,
    stagedText: staged.stdout,
    statText: [stat.stdout.trim(), stagedStat.stdout.trim()].filter(Boolean).join('\n'),
    untracked,
    files: await readChangedFiles(repoPath, paths, signal),
  }
}

const MAX_CHANGED_FILES = 40
const MAX_CHANGED_FILE_CHARS = 6000

/** Reads dirty working-tree and HEAD content so their incremental delta can reach the reviewer. */
async function readChangedFiles(
  repoPath: string,
  paths: string[],
  signal?: AbortSignal,
): Promise<TreeFileSnapshot[]> {
  // Bounded fan-out. This used to Promise.all the whole path list with two git
  // spawns each — a dirty node_modules meant tens of thousands of concurrent
  // processes, and a spawn that failed under that load made the file read as
  // absent on both sides, which sameContent then called unchanged.
  const CONCURRENT = 8
  const out: TreeFileSnapshot[] = []
  for (let start = 0; start < paths.length; start += CONCURRENT) {
    const batch = paths.slice(start, start + CONCURRENT)
    const settled = await Promise.all(
      batch.map((rel, offset) => readOneChangedFile(repoPath, rel, start + offset, signal)),
    )
    out.push(...settled)
  }
  return out
}

async function readOneChangedFile(
  repoPath: string,
  rel: string,
  index: number,
  signal?: AbortSignal,
): Promise<TreeFileSnapshot> {
  const object = `HEAD:${rel}`
  // Absence is a filesystem fact, not a git exit code: hash-object fails the
  // same way for a missing file and for a spawn that died, and those must land
  // differently — absent is a real state, unhashable is unknown.
  const exists = existsSync(join(repoPath, rel))
  const [currentHash, headHash] = await Promise.all([
    exists
      ? capture('git', ['hash-object', `--path=${rel}`, '--', rel], repoPath, 60_000, signal)
      : Promise.resolve(null),
    capture('git', ['rev-parse', '--verify', object], repoPath, 60_000, signal),
  ])
  const digest = currentHash && currentHash.exitCode === 0 ? currentHash.stdout.trim() : null
  const digestKnown = !exists || digest !== null
  const headExists = headHash.exitCode === 0
  let current = { text: null as string | null, truncated: false }
  let head = { text: null as string | null, truncated: false }

  if (index < MAX_CHANGED_FILES) {
    current = readBoundedFile(join(repoPath, rel))
    if (headExists) {
      const size = await capture(
        'git',
        ['cat-file', '-s', headHash.stdout.trim()],
        repoPath,
        60_000,
        signal,
      )
      const bytes = Number.parseInt(size.stdout.trim(), 10)
      if (size.exitCode === 0 && Number.isFinite(bytes) && bytes <= 2 * MAX_CHANGED_FILE_CHARS * 4) {
        const shown = await capture('git', ['show', object], repoPath, 60_000, signal)
        if (shown.exitCode === 0) {
          head = {
            text: shown.stdout.slice(0, MAX_CHANGED_FILE_CHARS),
            truncated: shown.stdout.length > MAX_CHANGED_FILE_CHARS,
          }
        }
      } else {
        head.truncated = true
      }
    }
  } else {
    current.truncated = exists
    head.truncated = headExists
  }

  return {
    path: rel,
    text: current.text,
    truncated: current.truncated,
    exists,
    digest,
    digestKnown,
    headText: head.text,
    headTruncated: head.truncated,
    headExists,
    headDigest: headExists ? headHash.stdout.trim() : null,
    // rev-parse failing for a path legitimately absent from HEAD and failing
    // because the spawn died are indistinguishable; the conservative reading —
    // treat it as a new file — over-attributes to the milestone rather than
    // silently excusing it.
    headDigestKnown: true,
  }
}

function readBoundedFile(full: string): { text: string | null; truncated: boolean } {
  try {
    if (!existsSync(full)) return { text: null, truncated: false }
    // Skip anything too large to be source, rather than reading it to throw
    // most of it away.
    if (statSync(full).size > 2 * MAX_CHANGED_FILE_CHARS * 4) {
      return { text: null, truncated: true }
    }
    const text = readFileSync(full, 'utf8')
    return {
      text: text.slice(0, MAX_CHANGED_FILE_CHARS),
      truncated: text.length > MAX_CHANGED_FILE_CHARS,
    }
  } catch {
    // Binary, unreadable, or vanished between the listing and now.
    return { text: '(unreadable)', truncated: false }
  }
}

/**
 * Whether this is a new project rather than an existing codebase.
 *
 * Tracked files, not commits: a repository someone has `git init`-ed and left
 * empty is greenfield, and so is one holding only the untracked debris of an
 * interrupted attempt. A directory that is not a repository at all counts as
 * greenfield when it holds nothing but dotfiles.
 *
 * The distinction matters because the planner and auditor prompts are otherwise
 * built on an assumption that does not hold — that there is prior work to read
 * and existing paths to check against.
 */
export async function isGreenfield(repoPath: string, signal?: AbortSignal): Promise<boolean> {
  const tracked = await capture('git', ['ls-files'], repoPath, 60_000, signal)
  if (tracked.exitCode === 0) return tracked.stdout.trim() === ''

  try {
    return readdirSync(repoPath).filter((name) => !name.startsWith('.')).length === 0
  } catch {
    return false
  }
}

/** A baseline meaning "nothing was here before", for adoption reviews. */
export function emptyTree(): TreeState {
  return {
    unknown: true,
    signature: '',
    paths: [],
    diffText: '',
    stagedText: '',
    statText: '',
    untracked: [],
    files: [],
  }
}

/** True when the milestone provably changed nothing. Unknown trees never qualify. */
export function treeUnchanged(before: TreeState, after: TreeState): boolean {
  if (before.unknown || after.unknown) return false
  return before.signature === after.signature
}

interface FileContent {
  text: string | null
  truncated: boolean
  exists: boolean
  digest: string | null
  digestKnown: boolean
}

function contentAt(state: TreeState, other: TreeState, path: string): FileContent | undefined {
  const own = state.files.find((file) => file.path === path)
  if (own) {
    return {
      text: own.text,
      truncated: own.truncated,
      exists: own.exists,
      digest: own.digest,
      digestKnown: own.digestKnown,
    }
  }

  if (state.paths.includes(path)) return undefined

  const counterpart = other.files.find((file) => file.path === path)
  if (!counterpart) return undefined
  return {
    text: counterpart.headText,
    truncated: counterpart.headTruncated,
    exists: counterpart.headExists,
    digest: counterpart.headDigest,
    digestKnown: counterpart.headDigestKnown,
  }
}

function sameContent(left: FileContent, right: FileContent): boolean {
  // Two genuinely absent sides are the one same-without-a-digest case. Anything
  // else without both digests is UNKNOWN, and unknown must never read as
  // unchanged: the failure mode this guards against is a git spawn failing under
  // load, both sides reporting not-exists, and a file the milestone edited being
  // filed under "NOT part of this milestone" because two failures compared equal.
  if (!left.exists && !right.exists) return left.digestKnown && right.digestKnown
  if (!left.exists || !right.exists) return false
  return left.digest !== null && right.digest !== null && left.digest === right.digest
}

function contentPatch(path: string, before: FileContent, after: FileContent): string {
  const oldLines = before.text?.split('\n') ?? []
  const newLines = after.text?.split('\n') ?? []
  if (oldLines.at(-1) === '') oldLines.pop()
  if (newLines.at(-1) === '') newLines.pop()

  // A real per-line diff, not a single prefix/suffix hunk. The collapse version
  // rendered an edit at line 5 plus an edit at line 145 as one hunk that removed
  // and re-added every line between them — attributing ~140 untouched lines to
  // the milestone, which is the exact misattribution this renderer exists to end.
  // Inputs are bounded snapshots (≤ MAX_CHANGED_FILE_CHARS), so quadratic LCS is
  // a few hundred lines square at worst.
  const ops = diffLines(oldLines, newLines)

  const CONTEXT = 3
  const hunks: string[][] = []
  let current: string[] | null = null
  let oldLine = 0
  let newLine = 0
  let hunkOldStart = 0
  let hunkNewStart = 0
  let hunkOldCount = 0
  let hunkNewCount = 0
  let trailingContext = 0

  const flush = (): void => {
    if (!current) return
    // Trim context beyond CONTEXT lines at the hunk's tail.
    while (trailingContext > CONTEXT) {
      current.pop()
      trailingContext -= 1
      hunkOldCount -= 1
      hunkNewCount -= 1
    }
    hunks.push([
      `@@ -${hunkOldStart + 1},${hunkOldCount} +${hunkNewStart + 1},${hunkNewCount} @@`,
      ...current,
    ])
    current = null
  }

  for (const op of ops) {
    if (op.kind === 'same') {
      if (current) {
        current.push(` ${op.line}`)
        trailingContext += 1
        hunkOldCount += 1
        hunkNewCount += 1
        // Once enough context has accumulated after a change, the hunk can close;
        // a later change opens a fresh one instead of dragging this one along.
        if (trailingContext >= CONTEXT * 2) flush()
      }
      oldLine += 1
      newLine += 1
      continue
    }
    if (!current) {
      const lead = Math.min(CONTEXT, oldLine, newLine)
      hunkOldStart = oldLine - lead
      hunkNewStart = newLine - lead
      hunkOldCount = lead
      hunkNewCount = lead
      current = oldLines.slice(oldLine - lead, oldLine).map((line) => ` ${line}`)
    }
    trailingContext = 0
    if (op.kind === 'del') {
      current.push(`-${op.line}`)
      hunkOldCount += 1
      oldLine += 1
    } else {
      current.push(`+${op.line}`)
      hunkNewCount += 1
      newLine += 1
    }
  }
  flush()

  const body = hunks.flat()
  if (before.truncated || after.truncated) body.push('[snapshot truncated]')
  return [`--- a/${path}`, `+++ b/${path}`, ...body].join('\n')
}

/** Line-level LCS diff. Bounded inputs only — this is quadratic by design. */
function diffLines(
  oldLines: string[],
  newLines: string[],
): Array<{ kind: 'same' | 'del' | 'add'; line: string }> {
  const n = oldLines.length
  const m = newLines.length
  // lcs[i][j] = longest common subsequence length of old[i..] and new[j..]
  const lcs: Int32Array[] = Array.from({ length: n + 1 }, () => new Int32Array(m + 1))
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      lcs[i]![j] =
        oldLines[i] === newLines[j]
          ? lcs[i + 1]![j + 1]! + 1
          : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
    }
  }
  const ops: Array<{ kind: 'same' | 'del' | 'add'; line: string }> = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (oldLines[i] === newLines[j]) {
      ops.push({ kind: 'same', line: oldLines[i]! })
      i += 1
      j += 1
    } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!) {
      ops.push({ kind: 'del', line: oldLines[i]! })
      i += 1
    } else {
      ops.push({ kind: 'add', line: newLines[j]! })
      j += 1
    }
  }
  while (i < n) ops.push({ kind: 'del', line: oldLines[i++]! })
  while (j < m) ops.push({ kind: 'add', line: newLines[j++]! })
  return ops
}

/** The paths dirty before execution whose observed contents did not change. */
export function preExistingUntouched(before: TreeState, after: TreeState): string[] {
  if (before.unknown || after.unknown) return []
  return before.paths.filter((path) => {
    const oldContent = contentAt(before, after, path)
    const newContent = contentAt(after, before, path)
    return oldContent !== undefined && newContent !== undefined && sameContent(oldContent, newContent)
  })
}

/** A pure rendering of only the changes observed between two tree snapshots. */
export function incrementalDelta(
  before: TreeState,
  after: TreeState,
  scope?: ReadonlySet<string>,
): string {
  if (after.unknown) return ''

  const sections: string[] = []
  const paths = [...new Set([...before.paths, ...after.paths])]
    .filter((path) => !scope || scope.has(path))
    .sort()
  for (const path of paths) {
    const oldContent = contentAt(before, after, path)
    const newContent = contentAt(after, before, path)
    if (!oldContent || !newContent) {
      if (!after.paths.includes(path)) {
        sections.push(`--- removed file: ${path} ---\n(contents not shown)`)
      } else if (!before.paths.includes(path)) {
        sections.push(`--- new file: ${path} ---\n(contents not shown)`)
      }
      continue
    }
    if (sameContent(oldContent, newContent)) continue

    if (!oldContent.exists) {
      const detail = newContent.text === null
        ? '(contents not shown — bounded snapshot unavailable)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- new file: ${path} ---\n${detail}`)
    } else if (!newContent.exists) {
      const detail = oldContent.text === null
        ? '(contents not shown — bounded snapshot unavailable)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- removed file: ${path} ---\n${detail}`)
    } else {
      const detail = oldContent.text === null ||
        newContent.text === null ||
        (oldContent.text === newContent.text && (oldContent.truncated || newContent.truncated))
        ? '(contents differ beyond the bounded snapshot)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- changed file: ${path} ---\n${detail}`)
    }
  }
  return sections.join('\n\n')
}

/**
 * Renders the diff for review, naming anything that predates the milestone.
 *
 * A reviewer told to judge "the diff" against a milestone's scope will otherwise
 * count unrelated pre-existing changes against it, or credit them to it.
 */
/**
 * The reviewer's evidence, in three layers that each do the one thing they are
 * good at.
 *
 * Git's own diff is the primary channel: full hunks, up to the overall budget,
 * for every tracked change — an edit deep in a 2,000-line file arrives as real
 * code, which the first version of this renderer lost by replacing git's output
 * with 6KB snapshots (a milestone editing this repo's own pipeline.ts reached
 * its reviewer as "(contents differ beyond the bounded snapshot)" and nothing
 * else). Untracked files, which git diff omits entirely, come from the bounded
 * snapshots. The digest layer then does what git cannot: separate this
 * milestone's work from dirt that predates it — the untouched list only ever
 * names digest-verified paths, and pre-existing dirty paths the milestone DID
 * touch get their own bounded incremental delta so the reviewer can tell which
 * part of the combined diff is the milestone's.
 */
export function renderDiffForReview(after: TreeState, before: TreeState): string {
  if (after.unknown) {
    return '(no diff available — this directory is not a git repository, so the change could not be shown for review)'
  }

  const preExisting = preExistingUntouched(before, after)
  const sections: string[] = []

  if (preExisting.length) {
    sections.push(
      `--- NOT part of this milestone ---\nThese paths were already modified before this milestone ran, and their content is byte-identical to before it ran. ` +
        `Do not attribute them to it:\n${preExisting.map((p) => `  ${p}`).join('\n')}`,
    )
  }

  const statText = [after.statText].filter(Boolean).join('\n')
  sections.push(`--- diffstat ---\n${statText || '(no tracked changes)'}`)

  const trackedDiff = [after.diffText.trim(), after.stagedText.trim()].filter(Boolean).join('\n')
  const preExistingDirty = new Set(
    before.unknown ? [] : before.paths.filter((path) => !preExisting.includes(path)),
  )
  sections.push(
    `--- combined diff vs HEAD (tracked files; includes pre-existing edits on any dirty paths listed above or below) ---\n${trackedDiff || '(empty)'}`,
  )

  // Untracked files never appear in git diff, so their content has to come from
  // the snapshots. Only the milestone's own new files belong here — untracked
  // paths that predate the milestone are covered by the delta section below.
  const newFileSections: string[] = []
  for (const file of after.files) {
    if (!after.untracked.includes(file.path)) continue
    if (preExistingDirty.has(file.path) || preExisting.includes(file.path)) continue
    newFileSections.push(
      `--- new file: ${file.path} ---\n${
        file.text ?? '(contents not shown — too large or unreadable)'
      }${file.truncated ? '\n[truncated]' : ''}`,
    )
  }
  sections.push(...newFileSections)

  if (preExistingDirty.size) {
    sections.push(
      `--- this milestone's own changes to already-dirty paths ---\n${
        incrementalDelta(before, after, preExistingDirty) || '(none — every already-dirty path is byte-identical)'
      }`,
    )
  }

  const joined = sections.join('\n\n')
  return joined.length > MAX_DIFF_CHARS
    ? `${joined.slice(0, MAX_DIFF_CHARS)}\n\n[diff truncated at ${MAX_DIFF_CHARS} characters]`
    : joined
}

/** Which of the plan's expected paths the executor actually produced. */
export function missingExpectedPaths(repoPath: string, expected: string[]): string[] {
  return expected.filter((rel) => !existsSync(join(repoPath, rel)))
}

/**
 * Changed paths that fall outside a milestone's declared scope.
 *
 * A milestone's verification command is written against its own paths, so
 * anything here was included in the review but never exercised by the tests.
 * Matching is prefix-wise in both directions because git reports an untracked
 * directory as `pkg/` while a plan names `pkg/file.go`.
 */
export function pathsOutsideScope(changed: string[], expected: string[]): string[] {
  if (!expected.length) return changed
  return changed.filter(
    (path) => !expected.some((e) => e === path || e.startsWith(path) || path.startsWith(e)),
  )
}

export function summariseTests(result: TestResult | null): string {
  if (!result) {
    return 'No verification command was defined for this milestone, so nothing was run. Weigh the diff on its own.'
  }
  // Three outcomes that all arrive as "non-zero" and call for three different
  // responses. Told "FAILED", an executor changes the code — right for a real
  // failure, wrong for a crash, and worse than useless for a hang, where the
  // code may be perfectly correct and simply never returns.
  //
  // The timeout is checked before the signal because a timeout *is* a signal
  // death: Parley kills with SIGTERM. Reported as "killed by SIGTERM" it looks
  // like something external intervened, when in fact nothing did — the command
  // never finished and the deadline ran out.
  const verdict = result.timedOut
    ? `DID NOT FINISH — the command was still running after ${(TEST_TIMEOUT_MS / 60000).toFixed(0)} minutes and Parley stopped it, so nothing was verified. Treat this as a hang: something waits for what never arrives. The code may be correct and simply never returns.`
    : result.signal
      ? `DID NOT COMPLETE — the runner was killed by ${result.signal}, so nothing was verified. This is a crash in the verification command itself, not a failing test.`
      : result.exitCode === 0
        ? 'PASSED'
        : `FAILED (exit ${result.exitCode})`
  const output = tail(`${result.stdout}\n${result.stderr}`.trim(), 4000)
  return `\`${result.command}\` ${verdict} in ${(result.durationMs / 1000).toFixed(1)}s\n\n${output || '(no output)'}`
}

/**
 * Renders mutation outcomes for the reviewer and the record.
 *
 * Deliberately states the survivors first and plainly. A surviving mutation is
 * the strongest possible evidence that a milestone's tests do not pin its claim
 * — stronger than any reading of the diff, because it was tried.
 */
/**
 * Decides whether one applied mutation was caught.
 *
 * Pulled out as its own function because the tempting shorthand — treating
 * anything that did not obviously pass as caught — turns an unapplied mutation
 * into a free pass, which is the exact false-green the mutation stage exists to
 * catch. `caught` is therefore only ever true on real evidence: the tests ran,
 * and they failed. Everything else is a skip, reported as not checked rather
 * than counted either way.
 */
export function judgeMutation(
  mutation: Pick<Mutation, 'describes' | 'file'>,
  outcome: { applied: true; result: TestResult | null } | { applied: false; reason: string },
): MutationResult {
  const base = { describes: mutation.describes, file: mutation.file }
  if (!outcome.applied) {
    return { ...base, caught: false, skipped: outcome.reason, skipKind: 'unapplied', exitCode: null }
  }
  const test = outcome.result
  if (test === null) {
    return {
      ...base,
      caught: false,
      skipped: 'this milestone has no verification command',
      skipKind: 'no-test-command',
      exitCode: null,
    }
  }
  // A crash or a timeout is not the suite noticing the break. A suite that dies on
  // any malformed input would "catch" every mutation while checking nothing, which
  // is the precise false green this stage exists to detect — so an abnormal run is
  // recorded as having proved nothing rather than as a pass. Timeout first: it is
  // delivered as a SIGTERM and would otherwise read as a crash.
  if (test.timedOut) {
    return {
      ...base,
      caught: false,
      skipped: 'the suite timed out under this mutation, so it proved nothing',
      skipKind: 'crashed',
      exitCode: test.exitCode,
    }
  }
  if (test.signal) {
    return {
      ...base,
      caught: false,
      skipped: `the suite was killed by ${test.signal} under this mutation, so it proved nothing`,
      skipKind: 'crashed',
      exitCode: test.exitCode,
    }
  }
  return { ...base, caught: test.exitCode !== 0, skipped: '', skipKind: '', exitCode: test.exitCode }
}

/**
 * Applies one mutation, runs something, and restores the file whatever happens.
 *
 * Split out of the pipeline because this is the only part of Parley that
 * deliberately corrupts a file in the user's repository, and it must be provable
 * in isolation that it always puts it back. The original content is held in
 * memory for the duration and rewritten in a `finally`; a failure to restore
 * throws loudly rather than being swallowed, because a silently mutated file
 * would poison every subsequent run and every review after it.
 *
 * Edited in place rather than on a copy on purpose: the verification command is
 * only known to work in the real tree, where relative paths, installed
 * dependencies and engine project files resolve. A mutation check that ran
 * somewhere else would be measuring a different thing.
 */
export async function withMutationApplied<T>(
  repoPath: string,
  mutation: Mutation,
  run: () => Promise<T>,
): Promise<{ applied: true; result: T } | { applied: false; reason: string }> {
  const target = join(repoPath, mutation.file)

  // `file` comes from a model, so it is checked rather than trusted.
  const lexicalRelative = relative_(repoPath, target)
  if (lexicalRelative.startsWith('..') || isAbsolute(lexicalRelative) || lexicalRelative === '') {
    return { applied: false, reason: 'that path resolves outside the repository' }
  }
  if (!existsSync(target)) return { applied: false, reason: 'that file does not exist' }

  // Resolved, not lexical. `relative()` compares strings, so a symlink that lives
  // inside the repository but points outside it passes the check — and writeFileSync
  // follows the link. The path comes from a model, so the containment has to hold
  // against the real filesystem rather than against how the path is spelled.
  let realTarget: string
  let realRoot: string
  try {
    realTarget = realpathSync(target)
    realRoot = realpathSync(repoPath)
  } catch (err) {
    return { applied: false, reason: `could not resolve it: ${err instanceof Error ? err.message : String(err)}` }
  }
  const relative = relative_(realRoot, realTarget)
  if (relative.startsWith('..') || isAbsolute(relative) || relative === '') {
    return { applied: false, reason: 'that path resolves outside the repository' }
  }

  let original: string
  try {
    original = readFileSync(target, 'utf8')
  } catch (err) {
    return { applied: false, reason: `could not read it: ${err instanceof Error ? err.message : String(err)}` }
  }

  // Exactly once, or the edit is ambiguous and so is any conclusion from it.
  const occurrences = original.split(mutation.find).length - 1
  if (occurrences !== 1) {
    return {
      applied: false,
      reason:
        occurrences === 0
          ? 'the text to replace was not found'
          : `the text to replace appears ${occurrences} times, so the edit is ambiguous`,
    }
  }

  try {
    writeFileSync(target, original.replace(mutation.find, mutation.replace), 'utf8')
    return { applied: true, result: await run() }
  } finally {
    try {
      writeFileSync(target, original, 'utf8')
    } catch (err) {
      throw new PipelineError(
        `A mutation check could not restore ${mutation.file}: ${err instanceof Error ? err.message : String(err)}. ` +
          `That file is left modified and must be reverted by hand before trusting anything else.`,
      )
    }
  }
}

/**
 * Decides whether the deterministic half of a milestone passed.
 *
 * Separate from the reviewer's judgement, and pure, because these are the facts:
 * a command exited non-zero, a declared break went unnoticed, a declared break
 * could not be applied at all. None of them is a matter of opinion, so none of
 * them is left to one.
 *
 * The three failing conditions are deliberately all fatal. Earlier only the first
 * two were, and the third — a check that could not be applied — passed silently on
 * the assumption the reviewer would notice the gap. That is the same soft signal
 * this pipeline keeps having to remove: it works exactly until the one time it
 * matters.
 */
export function milestoneVerdict(
  testResult: TestResult | null,
  mutationResults: MutationResult[],
): {
  testsPassed: boolean
  surviving: MutationResult[]
  unverifiable: MutationResult[]
  notRunnable: MutationResult[]
} {
  const surviving = mutationResults.filter((m) => !m.caught && !m.skipped)
  const unverifiable = mutationResults.filter(
    (m) => m.skipKind === 'unapplied' || m.skipKind === 'crashed',
  )
  const notRunnable = mutationResults.filter((m) => m.skipKind === 'no-test-command')
  const testsPassed =
    (testResult === null || testResult.exitCode === 0) &&
    surviving.length === 0 &&
    unverifiable.length === 0
  return { testsPassed, surviving, unverifiable, notRunnable }
}

export function summariseMutations(results: MutationResult[]): string {
  if (!results.length) return ''
  const lines: string[] = []
  for (const r of results) {
    if (r.skipKind === 'unapplied') {
      // Named as blocking here because it is: the reviewer should not read this as a
      // harmless gap it may wave through, having already had a repair round.
      lines.push(
        `  COULD NOT BE CHECKED (blocking) — ${r.file}: ${r.describes}. ${r.skipped}.`,
      )
    } else if (r.skipped) {
      lines.push(`  NOT CHECKED — ${r.file}: ${r.describes}. ${r.skipped}.`)
    } else if (r.caught) {
      lines.push(`  CAUGHT — ${r.file}: ${r.describes}. The suite failed as it should.`)
    } else {
      lines.push(
        `  SURVIVED — ${r.file}: ${r.describes}. The suite still passed, so nothing in it pins this.`,
      )
    }
  }
  return lines.join('\n')
}

function tail(text: string, max: number): string {
  if (text.length <= max) return text
  return `…${text.slice(-max)}`
}
