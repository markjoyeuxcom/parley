import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import type {
  AgentConfig,
  Id,
  Milestone,
  Mutation,
  MutationResult,
  TestResult,
  Vendor,
  WorkPlan,
  Worktree,
} from '@shared/domain'
import type { MilestonePhase } from '@shared/events'
import { capture, isShellFree, splitCommand, type CaptureResult } from '@main/util/spawn'
import { assertCapability, type AgentRegistry, type RunResult } from '@main/agents'
import { canonicalRepoPath } from '@main/util/repoPath'
import {
  executePrompt,
  mutationRepairPrompt,
  remediationPrompt,
  resumeExecutionPrompt,
  reviewDiffPrompt,
} from '@shared/protocol'
import { ensureUp, runProjectCommand } from './containers'
import { commitMilestone } from './worktrees'
import type { MilestoneReporter } from './reporter'
import type { RunGate } from './types'
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
} from './evidence'

/**
 * Executing one milestone, with no record anywhere in sight.
 *
 * This is the half of the pipeline that has to run wherever the repository is
 * — this machine today, an ssh-reachable host tomorrow — and the reason it
 * lives in its own module is enforceable rather than stylistic: nothing here
 * may import the store, and a test bundles this file to prove it. A dependency
 * that cannot be expressed cannot creep back.
 *
 * The division is between observing and recording. This code runs agents,
 * reads and writes the working tree, runs the project's own verification, and
 * breaks the code deliberately to see whether the tests notice. Every one of
 * those produces FACTS, which go to a reporter. What a fact means — a row, a
 * ledger occurrence, a framed message on a wire — is decided by whoever holds
 * the record, and that is never this file.
 *
 * What deliberately stayed behind in the facade: loading the milestone,
 * settling the ledger once it completes, and deriving the plan's status from
 * its siblings. All three need the record, and inverting them into callbacks
 * would have disguised the dependency rather than removed it.
 */

export interface ExecutionCoreDeps {
  reporter: MilestoneReporter
  agents: AgentRegistry
  devcontainerBinary: string | undefined
  selfRepoPath: string | null
}

export interface MilestoneExecutionInput {
  milestoneId: Id
  /** Loaded by the facade; the core never re-reads it. */
  milestone: Milestone
  plan: WorkPlan
  worktree: Worktree | null
  root: string
  agentEnv?: Record<string, string>
  gate?: RunGate
  activity: (phase: MilestonePhase, text: string) => void
  runState: RunState
  history: string[]
  enterAtVerify: boolean
  resumedRound: number | null
  seedTestResult: TestResult | null
}

export class ExecutionCore {
  private readonly containerUp = new Set<string>()

  constructor(private readonly deps: ExecutionCoreDeps) {}

  containerFor(plan: WorkPlan): boolean {
    return (
      plan.container &&
      (this.deps.selfRepoPath === null || canonicalRepoPath(plan.repoPath) !== this.deps.selfRepoPath)
    )
  }

  /**
   * Brings the workspace's container up once per pipeline lifetime — the same
   * folder is the same container, so later milestones and mutation rounds
   * reuse it. Returns null when ready, the failed capture otherwise; callers
   * turn that into their own honest failure. Only ever reached from approved
   * write flows.
   */
  async ensureContainerUp(
    workspace: string,
    signal?: AbortSignal,
  ): Promise<CaptureResult | null> {
    if (this.containerUp.has(workspace)) return null
    const up = await ensureUp(workspace, { binary: this.deps.devcontainerBinary, signal })
    if (up.exitCode !== 0) return up
    this.containerUp.add(workspace)
    return null
  }

  /**
   * Resolves where a milestone executes: the plan's worktree, or null for
   * checkout isolation. Creating and health-checking happen here, before any
   * approval is consumed — setup can take minutes and can fail, and a failure
   * must not burn a single-use approval. Health is fail-closed on purpose:
   * readTree fails *open* on a broken directory, which would silently disable
   * the changed-tree guard and blind the reviewer.
   */
  async driveMilestone(input: MilestoneExecutionInput): Promise<Milestone> {
    const { milestoneId, plan, worktree, root, agentEnv, gate, activity } = input
    const signal = gate?.signal
    const before = input.runState.before
    let runState = input.runState

    const entry = input.milestone
    // Everything this loop records goes through the reporter from here on. The
    // core states facts; the reporter decides they are rows. That indirection
    // is what lets the identical loop run on a machine with no database.
    const report = this.deps.reporter
    const saveRunState = (patch: Partial<RunState>): void => {
      runState = { ...runState, ...patch }
      report.record({ kind: 'checkpoint', runState })
    }
    let current = entry

    const executor = this.deps.agents.get(plan.executor.vendor)

    const reviewerVendor =
      plan.reviewer.vendor === plan.executor.vendor
        ? this.deps.agents.counterpart(plan.executor.vendor)
        : plan.reviewer.vendor
    const reviewer = this.deps.agents.get(reviewerVendor)

    // Both sides are resumed across rounds. The executor keeps everything it
    // already did, so remediation costs a critique rather than a restatement of
    // the milestone; the reviewer keeps its own objections, so it can check
    // whether they were actually met instead of forming a fresh opinion. All
    // of it seeds from the run state: zeros for a fresh run, the preserved
    // values for a resumption — the same loop either way.
    let executorResumeId = runState.executorResumeId
    let reviewerResumeId = runState.reviewerResumeId

    let round = runState.round
    let previousConcerns = [...runState.previousConcerns]
    let lastReviewNote = runState.reviewerNote
    let lastTestResult: TestResult | null = input.seedTestResult
    // Tracked explicitly rather than re-derived at the end from `reviewPassed`:
    // that would let a milestone whose tests failed complete on the strength of
    // a satisfied reviewer, which is the exact weak signal this pipeline exists
    // to strengthen.
    let lastPassed = false
    const history = [...input.history]

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
      current = report.record({
        kind: 'narrative',
        note: history.join('\n\n'),
        blocking: lastBlocking,
        notes: lastNotes,
      })
    }

    // ── Execute → verify → review, remediating a bounded number of times ─────
    let firstIteration = true
    for (;;) {
      const remediating = round > 0
      const resumedEntry = firstIteration && input.resumedRound !== null
      let executionText = runState.executionReport

      if (firstIteration && input.enterAtVerify) {
        // The interrupted run's work is already in the tree; re-executing
        // would at best waste the spend and at worst clobber it. Verify what
        // exists — if the review wants changes, the loop remediates normally.
        activity('testing', 'verifying the work the interrupted run left behind')
      } else {
        if (remediating) current = report.record({ kind: 'phase', phase: 'executing' })
        activity(
          'executing',
          remediating
            ? `${plan.executor.vendor} addressing ${previousConcerns.length} objection${previousConcerns.length === 1 ? '' : 's'} — round ${round} of ${MAX_REMEDIATION_ROUNDS}`
            : resumedEntry
              ? `${plan.executor.vendor} resuming on ${root}`
              : `${plan.executor.vendor} started on ${root}`,
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
            : resumedEntry && executorResumeId
              ? // The vendor session survived the interruption: a continuation,
                // not a restatement — the executor still holds its own context.
                resumeExecutionPrompt(
                  current.title,
                  current.intent,
                  current.expectedPaths,
                  root,
                  current.testCommand,
                )
              : executePrompt(
                  current.title,
                  current.intent,
                  current.expectedPaths,
                  root,
                  plan.correctionNote,
                  current.testCommand,
                ),
          cfg: plan.executor,
          capability: 'write',
          cwd: root,
          env: agentEnv,
          resumeId: executorResumeId,
          signal,
          timeoutMs: STAGE_TIMEOUT_MS,
          // The adapters already report every tool use, file edit and command. This
          // is the only thing standing between the user and a half-hour spinner.
          onActivity: (text) => activity('executing', text),
        })
        report.record({ kind: 'spend', usage: execution.usage })
        if (execution.resumeId) executorResumeId = execution.resumeId
        // Persisted before the error check on purpose: an errored turn still
        // learned a resume id and still said something worth keeping.
        saveRunState({
          executorResumeId,
          executionReport: execution.text.trim().slice(-600),
        })

        if (execution.error) {
          current = report.record({
            kind: 'finished',
            passed: false,
            note: [...history, gate?.isStopped ? STOPPED_NOTE : execution.error].join('\n\n'),
            completedAt: null,
          })
          report.record({ kind: 'planOutcome', status: 'failed' })
          return current
        }
        executionText = execution.text
      }

      const outcome = await this.verifyAndReview({
        milestoneId,
        plan,
        root,
        worktree,
        agentEnv,
        gate,
        before,
        round,
        resumed: resumedEntry,
        previousConcerns,
        reviewer,
        reviewerVendor,
        reviewerResumeId,
        activity,
        signal,
        firstExecutionText: executionText,
        report,
      })
      firstIteration = false

      // Both endings leave the loop, and neither is a failure the next round
      // could address: one has nothing to review, the other nothing to trust.
      if (outcome.kind === 'unchanged' || outcome.kind === 'parked') return outcome.milestone
      current = outcome.milestone
      reviewerResumeId = outcome.reviewerResumeId
      lastTestResult = outcome.testResult
      lastReviewNote = outcome.reviewerNote
      lastPassed = outcome.passed
      lastBlocking = outcome.concerns
      lastNotes = outcome.reviewNotes
      lastMutationResults = current.mutationResults
      saveRunState({ reviewerResumeId, reviewerNote: outcome.reviewerNote })
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
      // The persisted round is the one the next execution runs — exactly what
      // a resumed remediation needs to rebuild its critique prompt.
      saveRunState({ round, previousConcerns })
    }

    let finalPassed = lastPassed
    // A run the user stopped must say so, or the record narrates the stop as
    // an unexplained failure and sends the reader hunting for a crash.
    if (!finalPassed && gate?.isStopped) {
      history.push(STOPPED_NOTE)
      publishHistory()
    }
    // A passing worktree milestone is committed by Parley — never per
    // remediation round (one baseline spans the rounds), and never by the
    // agent. If the commit fails, the milestone fails with it: a record that
    // says complete while the branch lacks the work would corrupt landing.
    if (finalPassed && worktree) {
      activity('reviewing', 'committing the milestone in the worktree')
      const commit = await commitMilestone(
        worktree,
        `${plan.title} — milestone ${current.index + 1}: ${current.title}`,
      )
      if (commit.committed) {
        history.push(
          `Committed in the worktree as ${commit.sha.slice(0, 10)} on ${worktree.branch}. ` +
            `Nothing reaches ${plan.repoPath} until the branch is landed.`,
        )
      } else {
        finalPassed = false
        history.push(
          `The milestone passed verification and review, but committing it in the worktree failed: ${commit.detail}. ` +
            'The record must match the branch, so it is marked failed.',
        )
      }
    }
    // A completed milestone has nothing to resume; a failed one keeps its run
    // state — that preservation is the whole difference between "start over"
    // and "continue from the critique".
    if (finalPassed) report.record({ kind: 'checkpoint', runState: null })
    current = report.record({
      kind: 'finished',
      passed: finalPassed,
      note: history.join('\n\n'),
      completedAt: finalPassed ? Date.now() : null,
    })
    // Settling the ledger reads dispositions and occurrences and writes
    // settlements — record work, and the facade's job. The loop reports that
    // the milestone finished; what that means for the ledger is decided by
    // whoever holds one.
    

    return current
  }

  /**
   * One verify-and-review pass over whatever the executor just did.
   *
   * Split out of {@link runMilestone} so the remediation loop reads as a loop
   * rather than three hundred lines of nesting.
   */
  async verifyAndReview(input: {
    milestoneId: Id
    plan: WorkPlan
    /** Where this milestone executes: the worktree path, or plan.repoPath. */
    root: string
    worktree: Worktree | null
    agentEnv?: Record<string, string>
    /** Present so failure sinks can tell a requested stop from a crash. */
    gate?: RunGate
    before: TreeState
    round: number
    /** This round continues an interrupted run; its note must say so. */
    resumed?: boolean
    previousConcerns: string[]
    reviewer: ReturnType<AgentRegistry['get']>
    reviewerVendor: Vendor
    reviewerResumeId: string | null
    activity: (phase: MilestonePhase, text: string) => void
    signal?: AbortSignal
    firstExecutionText: string
    /** The same reporter the driving loop uses; this pass states facts too. */
    report: MilestoneReporter
  }): Promise<VerifyOutcome> {
    const { milestoneId, plan, root, before, round, activity, signal, report } = input
    // The definition — expectedPaths, testCommand, mutations, title, intent —
    // is read once at run entry and carried, never re-read here.
    //
    // It is not merely that a remote machine has no database to re-read. The
    // approval was granted against the milestone AS IT WAS: picking up an edit
    // that landed mid-run would verify something a human never approved. That
    // race was reachable today, because setMilestoneTestCommand had no guard
    // against a running milestone, and it now refuses instead.
    let current = report.milestone

    // ── Confirm something actually changed ───────────────────────────────────
    //
    // Checked before the tests and before the review, both of which would
    // otherwise sail through: an unchanged tree usually still passes its tests,
    // and a reviewer handed a diff containing none of the milestone's work has
    // nothing to object to. An executor that reports success while writing
    // nothing is a failure, not a pass.
    const after = await readTree(root, signal)
    const missing = missingExpectedPaths(root, current.expectedPaths)

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
            (input.worktree
              ? 'They live in this plan’s worktree, so Adopt & verify can complete the milestone from them.'
              : 'Either commit or delete that work before retrying, so the executor has a clean slate.')
          : missing.length === current.expectedPaths.length
            ? ` The plan expected it to create or modify ${current.expectedPaths.join(', ')}; none of those exist.`
            : ` The plan expected ${current.expectedPaths.join(', ')}; these do not exist: ${missing.join(', ')}.`
      // Under the mocks this is worth calling out, but not as it once was: the mock
      // executor does write a placeholder, so an unchanged tree here is no longer
      // explained by mock mode itself and usually means the path is not writable.
      const cause = this.deps.agents.mock
        ? ` Parley is running with PARLEY_MOCK=1. The mock executor writes one placeholder file, so an unchanged tree usually means ${input.worktree ? 'the worktree' : 'the repository path'} is not writable rather than that mock mode cannot work.`
        : ` What it said: ${input.firstExecutionText.trim().slice(0, 600) || '(no report)'}`
      // If the work already exists, whether it *passes* is the thing the user
      // needs in order to decide between committing it and starting over. The
      // milestone still fails — it did nothing — but failing without answering
      // that question just sends them to a terminal to ask it themselves.
      let existingWorkNote = ''
      if (missing.length === 0 && current.expectedPaths.length > 0 && current.testCommand) {
        activity('testing', `checking whether the existing work passes ${current.testCommand}`)
        const existingResult = await this.runTests(current.testCommand, root, { container: this.containerFor(plan), signal })
        if (existingResult) {
          current = report.record({ kind: 'verification', result: existingResult })
          existingWorkNote =
            existingResult.exitCode === 0
              ? ` The work already present does pass \`${existingResult.command}\`, so committing it may be all this milestone needed.`
              : ` The work already present does not pass \`${existingResult.command}\` (exit ${existingResult.exitCode}), so it is unfinished rather than done.`
        }
      }

      // One fact, so one write and one event: the refusal and its verdict are
      // the same moment, and splitting them would put a milestone through a
      // transient state the surfaces would render.
      current = report.record({
        kind: 'finished',
        passed: false,
        judgement: false,
        note:
          `${plan.executor.vendor} reported finishing this milestone, but the working tree is byte-for-byte unchanged — ` +
          `no tracked edits, nothing staged, no new files.${detail}${existingWorkNote}` +
          cause,
      })
      report.record({ kind: 'planOutcome', status: 'failed' })
      return { kind: 'unchanged', milestone: current }
    }

    // ── Verify deterministically ─────────────────────────────────────────────
    current = report.record({ kind: 'phase', phase: 'testing' })

    activity(
      'testing',
      current.testCommand ? `running ${current.testCommand}` : 'no verification command defined',
    )
    const testResult = await this.runTests(current.testCommand, root, { container: this.containerFor(plan), signal })
    if (testResult) {
      activity(
        'testing',
        `${testResult.command} exited ${testResult.exitCode} in ${(testResult.durationMs / 1000).toFixed(1)}s`,
      )
    }
    current = report.record({ kind: 'verification', result: testResult })

    // ── Did it run at all? ───────────────────────────────────────────────────
    //
    // Before anything is judged, because everything downstream treats the
    // result as evidence. A command that never started is not weak evidence,
    // it is none: the mutation stage would "prove" the tests catch nothing,
    // the reviewer would read a red suite and object, and the executor would
    // spend a paid round rewriting code that was never wrong — which is
    // precisely the sequence a host with no node on its PATH produced.
    //
    // So it parks. Retrying changes nothing until a human changes something,
    // and saying "the tests failed" about tests that did not run is the one
    // thing Parley must never do: its whole claim is that a green result is
    // observed rather than asserted, and that claim is worth exactly as much
    // as its willingness to admit when it observed nothing.
    if (testResult?.startError) {
      activity('testing', `the verification command could not run: ${testResult.startError}`)
      current = report.record({
        kind: 'parked',
        reason:
          `\`${testResult.command}\` could not be run here: ${testResult.startError}. ` +
          `Nothing was learned about this milestone's work — the command never started, so its ` +
          `exit code is not a verdict on the code. Fix what is missing and resume; ` +
          `re-running unchanged would produce the same non-answer.`,
      })
      return { kind: 'parked', milestone: current }
    }

    // ── Mutation checks ──────────────────────────────────────────────────────
    //
    // Only worth running against a green suite: with a red one every mutation
    // "fails" and proves nothing. This is where a milestone earns the claim that
    // its tests would catch a wrong implementation, rather than merely that this
    // implementation happens to pass.
    let mutationResults: MutationResult[] = []
    const testsGreen = testResult === null || testResult.exitCode === 0
    if (testsGreen && current.mutations.length > 0) {
      const staged = await this.runMutationStage({
        milestoneId,
        milestone: current,
        plan,
        report,
        root,
        agentEnv: input.agentEnv,
        reviewer: input.reviewer,
        reviewerVendor: input.reviewerVendor,
        reviewerResumeId: input.reviewerResumeId,
        activity,
        signal,
      })
      current = staged.milestone
      mutationResults = staged.mutationResults
    }

    // ── Independent review ───────────────────────────────────────────────────
    current = report.record({ kind: 'phase', phase: 'reviewing' })

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
      cwd: root,
      env: input.agentEnv,
      resumeId: input.reviewerResumeId,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
    })
    report.record({ kind: 'spend', usage: review.usage })

    const parsedReview = parseReview(review.text)
    if (parsedReview) {
      for (const finding of parsedReview.blocking) {
        report.record({ kind: 'finding', text: finding, round, blocking: true, source: 'review' })
      }
      for (const note of parsedReview.notes) {
        report.record({ kind: 'finding', text: note, round, blocking: false, source: 'review' })
      }
    }
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
    // The resumed marker is the round-provenance rule at work: a pass after an
    // interruption must never read as a clean uninterrupted attempt.
    const resumedMark = input.resumed ? ' (resumed after interruption)' : ''
    noteParts.push(
      round === 0
        ? `Round 1${resumedMark} — ${plan.executor.vendor} executed, ${input.reviewerVendor} reviewed.`
        : `Round ${round + 1}${resumedMark} — ${plan.executor.vendor} remediated, ${input.reviewerVendor} re-reviewed.`,
    )
    if (missing.length) {
      // A frequent and otherwise invisible failure: the executor wrote
      // *something*, but not the files the plan named, so the test command that
      // targets those paths cannot possibly pass.
      noteParts.push(
        `The plan expected these paths, and they do not exist: ${missing.join(', ')}.`,
      )
    }
    if (review.error) {
      noteParts.push(
        input.gate?.isStopped
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

    current = report.record({ kind: 'judgement', passed: reviewPassed })

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
   * So: skip execution, keep the checks that actually establish anything — the
   * deterministic tests, the declared break checks, and the independent
   * cross-vendor review — and record `adopted: true` so the trail says plainly
   * that Parley did not write this.
   *
   * Needs no approval: no agent gets write capability on this path. The only
   * writes are the harness's own break checks, applied and restored exactly as
   * execution applies them — held in memory, reverted in a `finally`, loud on
   * a failure to restore. It is still gated on the findings ledger: adoption
   * completes a milestone through review, so an open blocker that stops
   * "Approve and run" must stop "Adopt & verify" too, or adoption is a side
   * door around the ledger.
   */
  async runTests(
    command: string,
    cwd: string,
    opts: { container: boolean; signal?: AbortSignal },
  ): Promise<TestResult | null> {
    const trimmed = command.trim()
    if (!trimmed) return null

    if (!isShellFree(trimmed)) {
      return {
        command: trimmed,
        exitCode: -1,
        signal: null,
        timedOut: false,
        startError: 'the verification command needs shell syntax, which Parley will not run',
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
        startError: 'the verification command could not be parsed',
        stdout: '',
        stderr: 'Could not parse this verification command.',
        durationMs: 0,
        ranAt: Date.now(),
      }
    }

    // A container that will not start is a verification that never ran —
    // fail closed with the reason, in explicit contrast to verifyLanding's
    // fail-open smoke check.
    if (opts.container) {
      const up = await this.ensureContainerUp(cwd, opts.signal)
      if (up) {
        return {
          command: trimmed,
          exitCode: up.exitCode,
          signal: up.signal,
          timedOut: up.timedOut,
          // The comment above already called this "a verification that never
          // ran". It said so in prose and reported an exit code anyway.
          startError: 'the dev container would not start',
          stdout: '',
          stderr: `the dev container failed to start: ${tail(`${up.stderr}\n${up.stdout}`.trim(), 8000)}`,
          durationMs: up.durationMs,
          ranAt: Date.now(),
        }
      }
    }

    const result = await runProjectCommand(argv, cwd, {
      container: opts.container,
      binary: this.deps.devcontainerBinary,
      timeoutMs: TEST_TIMEOUT_MS,
      signal: opts.signal,
    })
    return {
      command: trimmed,
      exitCode: result.exitCode,
      signal: result.signal,
      timedOut: result.timedOut,
      startError: result.startError,
      stdout: tail(result.stdout, 8000),
      stderr: tail(result.stderr, 8000),
      durationMs: result.durationMs,
      ranAt: Date.now(),
    }
  }

  /**
   * Runs the milestone's declared break checks and persists their outcomes.
   *
   * Shared by execution and adoption so the two paths cannot drift: the same
   * checks, the same single repair round for stale anchors (always the
   * reviewer's vendor — the party with no stake in the outcome), the same
   * record on the milestone row. Callers decide when the stage runs, because
   * their idea of a green suite differs: execution treats a missing command as
   * green here and lets the verdict report the un-runnable checks, while
   * adoption refuses to adopt without a command at all.
   */
  async runMutationStage(input: {
    milestoneId: Id
    milestone: Milestone
    plan: WorkPlan
    /** Where the milestone executes: the worktree path, or plan.repoPath. */
    root: string
    agentEnv?: Record<string, string>
    reviewer: ReturnType<AgentRegistry['get']>
    reviewerVendor: Vendor
    reviewerResumeId: string | null
    activity: (phase: MilestonePhase, text: string) => void
    signal?: AbortSignal
    report: MilestoneReporter
  }): Promise<{ milestone: Milestone; mutationResults: MutationResult[] }> {
    const { milestone, plan, root, activity, signal } = input
    activity(
      'testing',
      `checking that the tests catch ${milestone.mutations.length} deliberate break${milestone.mutations.length === 1 ? '' : 's'}`,
    )
    let mutationResults = await this.runMutations(milestone, root, this.containerFor(plan), signal)
    // A stale anchor is expected — the planner wrote it before this code
    // existed — so it gets one chance to be re-resolved against the file rather
    // than being shrugged off as unchecked or blocking the milestone on a
    // guess.
    if (mutationResults.some((m) => m.skipKind === 'unapplied')) {
      mutationResults = await this.repairMutations(
        milestone,
        mutationResults,
        {
          reviewer: input.reviewer,
          reviewerVendor: input.reviewerVendor,
          reviewerResumeId: input.reviewerResumeId,
          root,
          agentEnv: input.agentEnv,
        },
        plan,
        activity,
        input.report,
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
    const updated = input.report.record({ kind: 'mutations', results: mutationResults })
    return { milestone: updated, mutationResults }
  }

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
  async repairMutations(
    milestone: Milestone,
    results: MutationResult[],
    input: {
      reviewer: ReturnType<AgentRegistry['get']>
      reviewerVendor: Vendor
      reviewerResumeId: string | null
      /** Where the milestone executes: the worktree path, or plan.repoPath. */
      root: string
      agentEnv?: Record<string, string>
    },
    plan: WorkPlan,
    activity: (phase: MilestonePhase, text: string) => void,
    report: MilestoneReporter,
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
      const target = join(input.root, mutation.file)
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
      cwd: input.root,
      env: input.agentEnv,
      resumeId: input.reviewerResumeId,
      signal,
      timeoutMs: STAGE_TIMEOUT_MS,
    })
    report.record({ kind: 'spend', usage: reply.usage })
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
        input.root,
        { ...original, ...repair },
        () => this.runTests(milestone.testCommand, input.root, { container: this.containerFor(plan), signal }),
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
  async runMutations(
    milestone: Milestone,
    repoPath: string,
    container: boolean,
    signal?: AbortSignal,
  ): Promise<MutationResult[]> {
    const results: MutationResult[] = []
    for (const mutation of milestone.mutations) {
      const outcome = await withMutationApplied(repoPath, mutation, () =>
        this.runTests(milestone.testCommand, repoPath, { container, signal }),
      )
      results.push(judgeMutation(mutation, outcome))
    }
    return results
  }

}

/**
 * Runs one milestone to its ending and reports what happened.
 *
 * The single entry point, and a function rather than a class so a caller
 * cannot hold onto anything between runs. Returns the milestone as the facts
 * left it; whether that ending settles a ledger or moves a plan is the
 * caller's business.
 */
export async function executeMilestone(
  input: MilestoneExecutionInput,
  deps: ExecutionCoreDeps,
): Promise<Milestone> {
  return new ExecutionCore(deps).driveMilestone(input)
}
