import { homedir } from 'node:os'
import { statSync } from 'node:fs'
import { isAbsolute } from 'node:path'
import {
  type AgentConfig,
  type Approval,
  emptyUsage,
  type Id,
  type Loop,
  type Milestone,
  type Session,
  type Skill,
  type WorkPlan,
} from '@shared/domain'
import type { AppEvent } from '@shared/events'
import type { Hold } from '@shared/holds'
import type { AgentRegistry } from '@main/agents'
import { isShellFree, shellMetacharsIn } from '@shared/command'
import { newId, type Repo } from '@main/store/repo'
import { HoldsEngine } from './holds'
import { LoopRunner, validateExitCommand, type LoopOutcome } from './loop'
import { missingExpectedPaths, Pipeline, readTree } from './pipeline'
import { assertNoUnresolvedBlockingOccurrences } from './gate'
import { SessionRunner } from './session'
import type { OrchestratorDeps } from './types'

export class RequestError extends Error {}

/**
 * Validates a repository path coming from the renderer.
 *
 * The renderer is the least-trusted part of the app, and this path becomes a
 * process working directory, so it is checked here rather than assumed.
 */
export function validateRepoPath(path: string): string {
  const trimmed = path.trim()
  if (!trimmed) throw new RequestError('a repository path is required')
  if (!isAbsolute(trimmed)) throw new RequestError('the repository path must be absolute')
  try {
    if (!statSync(trimmed).isDirectory()) throw new RequestError(`${trimmed} is not a directory`)
  } catch (err) {
    if (err instanceof RequestError) throw err
    throw new RequestError(`cannot open ${trimmed}`)
  }
  return trimmed
}

/** Skills seeded on first run. Each is a prompt pack, droppable onto a pane. */
const BUILT_IN_SKILLS: Array<Omit<Skill, 'id'>> = [
  {
    name: 'Security pass',
    description: 'Hunt for exploitable defects, not style.',
    prompt:
      'Audit this repository for security defects that are actually reachable: injection, authentication and authorisation gaps, unsafe deserialisation, secrets in source or history, SSRF, path traversal, and unsafe subprocess or shell use. For each, show the reachable path from untrusted input to the sink. Skip anything you cannot demonstrate is reachable.',
    vendorHint: null,
    builtIn: true,
  },
  {
    name: 'Orient me',
    description: 'A fast, honest map of an unfamiliar codebase.',
    prompt:
      'Give me a working map of this repository: the entry points, the major modules and what each owns, how a request or command flows end to end, where state lives, and where the tests are. Then tell me the three things that would most surprise a new contributor.',
    vendorHint: null,
    builtIn: true,
  },
  {
    name: 'Find the bug',
    description: 'Evidence-led defect hunt with reproduction paths.',
    prompt:
      'Find real defects in this codebase — logic errors, unhandled failure modes, race conditions, off-by-one and boundary errors, resource leaks. For each, give the file and line, the concrete inputs or state that trigger it, and what goes wrong. Do not report style or hypotheticals you cannot ground in the code.',
    vendorHint: null,
    builtIn: true,
  },
  {
    name: 'Cover the gaps',
    description: 'Identify untested behaviour that matters.',
    prompt:
      'Identify the behaviour in this codebase that is most consequential and least tested. Rank by what would break silently in production if it regressed. Then write the highest-value missing tests, matching the conventions of the existing suite.',
    vendorHint: null,
    builtIn: true,
  },
  {
    name: 'Explain this diff',
    description: 'Review the current working tree.',
    prompt:
      'Show me the current working-tree diff and review it: what changed, why it plausibly changed, and anything that looks unintended, out of scope, or likely to break something not covered by the tests.',
    vendorHint: null,
    builtIn: true,
  },
]

/**
 * Owns every running engine and the single database handle.
 *
 * Runners are held in memory only while active; everything durable lives in
 * SQLite, so a crash loses in-flight turns but never the record of what already
 * happened.
 */
export class Manager {
  private readonly sessions = new Map<Id, SessionRunner>()
  /**
   * Planning runs that are still going.
   *
   * `createPlan` returns as soon as the record exists and lets the pipeline run
   * on, so without this the only handle on a live run would be its events. Kept
   * so a caller that genuinely needs to wait — shutdown, tests — can.
   */
  private readonly planRuns = new Map<Id, Promise<void>>()
  private readonly loops = new Map<Id, LoopRunner>()
  private readonly pipeline: Pipeline
  private readonly deps: OrchestratorDeps
  private readonly holds: HoldsEngine
  readonly repo: Repo
  readonly registry: AgentRegistry

  constructor(deps: OrchestratorDeps) {
    // The holds engine sits in front of emit: every durable transition already
    // flows through that one function, so instrumenting it here means every
    // runner — pipeline, sessions, loops — keeps the attention queue current
    // without knowing it exists.
    this.holds = new HoldsEngine(deps.repo, deps.emit, deps.notifyUser)
    this.deps = { ...deps, emit: this.holds.emit }
    this.repo = deps.repo
    this.registry = deps.registry
    this.pipeline = new Pipeline(this.deps)
    this.seedSkills()
    // Publish (and notify, once each) whatever was already waiting when the
    // app started — including holds created moments before a quit.
    this.holds.schedule()
  }

  private emit(event: AppEvent): void {
    this.deps.emit(event)
  }

  private seedSkills(): void {
    if (this.repo.listSkills().some((s) => s.builtIn)) return
    for (const skill of BUILT_IN_SKILLS) this.repo.upsertSkill({ ...skill, id: newId() })
  }

  // ─── Sessions ──────────────────────────────────────────────────────────────

  startSession(input: {
    kind: Session['kind']
    matter: string
    project: string
    repoPath: string | null
    agentA: AgentConfig
    agentB: AgentConfig
    maxTurns: number
  }): Session {
    const repoPath = input.repoPath ? validateRepoPath(input.repoPath) : null
    if (input.kind === 'review' && !repoPath) {
      throw new RequestError('a codebase review needs a repository')
    }

    // The wire still speaks two sides; they take seats 0 and 1. The request
    // surface generalises later in this series, once the runner can seat more.
    const participants = [input.agentA, input.agentB]

    const session = this.repo.createSession({
      id: newId(),
      kind: input.kind,
      status: 'idle',
      matter: input.matter,
      project: input.project,
      repoPath,
      participants,
      maxTurns: input.maxTurns,
      mock: this.registry.mock,
      createdAt: Date.now(),
    })

    // Written over the array so it already holds whatever the seat count: a
    // repeated vendor anywhere weakens the cross-check this is built for.
    if (new Set(participants.map((seat) => seat.vendor)).size < participants.length) {
      this.emit({
        type: 'notice',
        level: 'warn',
        message:
          'Both sides are the same vendor. They will share blind spots, which weakens the cross-check this is built for.',
      })
    }

    this.emit({ type: 'session.created', session })

    const runner = new SessionRunner(session, this.deps)
    this.sessions.set(session.id, runner)
    void runner.run().finally(() => this.sessions.delete(session.id))

    return session
  }

  interject(sessionId: Id, target: 'both' | 'a' | 'b', text: string): void {
    const session = this.repo.getSession(sessionId)
    if (!session) throw new RequestError('no such session')
    const turns = this.repo.listTurns(sessionId)
    this.repo.addInterjection({ sessionId, target, text, atTurnIndex: turns.length })
  }

  pauseSession(sessionId: Id): void {
    const runner = this.sessions.get(sessionId)
    if (!runner) throw new RequestError('that session is not running')
    runner.gate.pause()
    this.repo.setSessionStatus(sessionId, 'paused')
    this.emit({ type: 'session.status', sessionId, status: 'paused' })
  }

  resumeSession(sessionId: Id): void {
    const runner = this.sessions.get(sessionId)
    if (!runner) throw new RequestError('that session is not running')
    runner.gate.resume()
    this.repo.setSessionStatus(sessionId, 'running')
    this.emit({ type: 'session.status', sessionId, status: 'running' })
  }

  stopSession(sessionId: Id): void {
    const runner = this.sessions.get(sessionId)
    if (!runner) throw new RequestError('that session is not running')
    this.repo.setSessionStatus(sessionId, 'stopping')
    this.emit({ type: 'session.status', sessionId, status: 'stopping' })
    runner.gate.stop()
  }

  // ─── Plans ─────────────────────────────────────────────────────────────────

  async createPlan(input: {
    sessionId: Id
    kind: WorkPlan['kind']
    repoPath: string
    planner: WorkPlan['planner']
    executor: WorkPlan['executor']
    reviewer: WorkPlan['reviewer']
    /** Optional operator brief, attributed separately in the plan's brief. */
    note?: string
  }): Promise<{ plan: WorkPlan; milestones: Milestone[] }> {
    const session = this.repo.getSession(input.sessionId)
    if (!session) throw new RequestError('no such session')
    const verdict = this.repo.getVerdict(input.sessionId)
    if (!verdict) throw new RequestError('that session has no verdict to plan from')

    const repoPath = validateRepoPath(input.repoPath)

    // Deliberately a warning, not a block. Planner and executor are both on the
    // produce side — the audit and the review still come from the counterpart, so
    // nobody grades their own work. What this configuration costs is check
    // *diversity*, and the message says exactly that rather than gesturing at
    // "weaker separation".
    if (input.planner.vendor === input.executor.vendor) {
      const counterpart = this.registry.counterpart(input.planner.vendor)
      this.emit({
        type: 'notice',
        level: 'warn',
        message:
          `The planner and executor are both ${input.planner.vendor}, so every independent check on this plan — the audit and the review — will come from ${counterpart}. Any blind spot ${counterpart} has now covers both gates.`,
      })
    }

    const plan = this.repo.createPlan({
      id: newId(),
      sessionId: input.sessionId,
      kind: input.kind,
      title: `${input.kind} plan`,
      repoPath,
      planner: input.planner,
      executor: input.executor,
      reviewer: input.reviewer,
      status: 'drafting',
      question: '',
      correctionNote: '',
      correctionDispositions: [],
      isolation: 'checkout' as const,
      setupCommand: '',
      usage: emptyUsage(),
      mock: this.registry.mock,
      createdAt: Date.now(),
    })
    this.emit({ type: 'plan.created', plan })

    // A remediation plan's subject is what earlier reviews objected to, not the
    // decision that started the session. Gathered here because the findings live
    // in this database and the planner only reads the repository — without this,
    // "fix the confirmed findings" arrives with no findings attached.
    const findings =
      input.kind === 'remediation' ? this.repo.reviewFindingsForSession(input.sessionId, plan.id) : []

    const operatorNote = (input.note ?? '').trim()

    const brief = [
      findings.length
        ? `THE FINDINGS TO FIX. These are the recorded reviews of work already executed in this session. Plan the smallest set of milestones that resolves the substantive ones. A finding you judge not worth acting on must be named and argued, not silently dropped.\n\n${findings.join('\n\n———\n\n')}`
        : '',
      // Attributed rather than blended in, so the record still distinguishes
      // what two agents decided from what the operator added afterwards.
      operatorNote ? `ADDED BY THE OPERATOR, who is the authority here:\n${operatorNote}` : '',
      `Decision this session reached: ${verdict.decision}`,
      verdict.rationale ? `Rationale: ${verdict.rationale}` : '',
      verdict.dissent ? `Unresolved objections to keep in mind: ${verdict.dissent}` : '',
      `Original matter: ${session.matter}`,
    ]
      .filter(Boolean)
      .join('\n\n')

    // Deliberately not awaited. Drafting, auditing and correcting are three full
    // agent turns with a 30-minute timeout each; awaiting them here would hold
    // the caller's dialog open for the entire run. Everything the UI needs after
    // this point arrives as plan.status / plan.milestone / plan.stage events, so
    // the record is enough to return. Validation failures above still throw
    // synchronously, which is what the dialog should surface.
    const run = this.pipeline
      .draft(plan, brief)
      .then(() => undefined)
      .catch((err: unknown) => {
        const detail = err instanceof Error ? err.message : String(err)
        if ((this.repo.getPlan(plan.id)?.status ?? 'failed') !== 'failed') {
          this.repo.setPlanStatus(plan.id, 'failed')
          this.emit({ type: 'plan.status', planId: plan.id, status: 'failed' })
        }
        this.emit({ type: 'notice', level: 'error', message: `Planning failed: ${detail}` })
      })
      .finally(() => this.planRuns.delete(plan.id))
    this.planRuns.set(plan.id, run)

    return { plan, milestones: [] }
  }

  /**
   * Resolves once the planning pipeline for this plan has settled.
   *
   * Returns immediately for a plan that is not running, so it is safe to await
   * unconditionally. Never rejects — a failed run reports through events.
   */
  async whenPlanSettled(planId: Id): Promise<void> {
    await this.planRuns.get(planId)
  }

  /**
   * Answers a plan parked on a question and lets it continue.
   *
   * The stage picks up from where it stopped with the answer in hand, rather
   * than restarting — the planner is resumed, so it still holds its own draft.
   *
   * Deliberately not awaited, exactly like createPlan and for the same reason:
   * the resumed run is up to three agent stages with a 30-minute timeout each,
   * and holding the caller's invoke open for the duration parked the renderer
   * on "Continuing…" for real runs. Registered in planRuns so shutdown and
   * tests can still wait on it; the outcome arrives as plan events.
   */
  answerPlan(planId: Id, answer: string): { plan: WorkPlan; milestones: Milestone[] } {
    const plan = this.repo.getPlan(planId)
    if (!plan) throw new RequestError('no such plan')
    if (plan.status !== 'awaiting-clarification') {
      throw new RequestError('that plan is not waiting on an answer')
    }
    const trimmed = answer.trim()
    if (!trimmed) throw new RequestError('an answer is required')

    const run = this.pipeline
      .resume(plan, trimmed)
      .then(() => undefined)
      .catch((err: unknown) => {
        const detail = err instanceof Error ? err.message : String(err)
        if ((this.repo.getPlan(plan.id)?.status ?? 'failed') !== 'failed') {
          this.repo.setPlanStatus(plan.id, 'failed')
          this.emit({ type: 'plan.status', planId: plan.id, status: 'failed' })
        }
        this.emit({ type: 'notice', level: 'error', message: `Planning failed: ${detail}` })
      })
      .finally(() => this.planRuns.delete(plan.id))
    this.planRuns.set(plan.id, run)

    return { plan: this.repo.getPlan(planId) ?? plan, milestones: [] }
  }

  // ─── Decision holds ────────────────────────────────────────────────────────

  listHolds(): Hold[] {
    return this.holds.list()
  }

  /** Acknowledges a notice-class hold; decision-class holds refuse (see engine). */
  ackHold(holdId: string): Hold[] {
    return this.holds.ack(holdId)
  }

  /**
   * Explicit recompute for the two mutations that reach the database without
   * emitting any event: archiving a session, and the ack itself.
   */
  holdsChanged(): void {
    this.holds.schedule()
  }

  /**
   * Corrects a milestone's verification command.
   *
   * The planner can get this wrong — and did, emitting shell syntax the harness
   * refuses, which left a milestone silently unverified. The human gate is
   * pointless if you can see the mistake and cannot fix it.
   */
  setMilestoneTestCommand(milestoneId: Id, command: string): Milestone {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new RequestError('no such milestone')

    const trimmed = command.trim()
    if (trimmed && !isShellFree(trimmed)) {
      throw new RequestError(
        `that command needs shell syntax (${shellMetacharsIn(trimmed).join(' ')}), which Parley spawns without. Use a single command, or a script in the repository that does the rest.`,
      )
    }

    const updated = this.repo.updateMilestone(milestoneId, { testCommand: trimmed })
    this.emit({ type: 'plan.milestone', milestone: updated })
    return updated
  }

  async runMilestone(milestoneId: Id, approvalId: Id): Promise<Milestone> {
    return this.pipeline.runMilestone(milestoneId, approvalId)
  }

  grantMilestoneApproval(milestoneId: Id, summary: string): Approval {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new RequestError('no such milestone')
    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new RequestError('the plan for this milestone is missing')
    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)
    return this.repo.grantApproval('milestone.execute', milestoneId, summary)
  }

  /**
   * Verifies work already present in the tree instead of executing.
   *
   * Takes no approval on purpose: nothing is written. The tests and the
   * independent cross-vendor review still run.
   */
  async adoptMilestone(milestoneId: Id): Promise<Milestone> {
    return this.pipeline.adoptMilestone(milestoneId)
  }

  /**
   * Cheap look at the repository before a milestone is approved.
   *
   * Everything needed to predict the commonest dead end is already knowable up
   * front: if the files a milestone is meant to create already exist as
   * uncommitted work, the executor will very likely decline to overwrite them
   * and change nothing. Discovering that after forty minutes of agent time is
   * the worst possible moment.
   */
  async inspectMilestone(
    milestoneId: Id,
  ): Promise<{ existing: string[]; missing: string[]; dirtyPaths: string[] }> {
    const milestone = this.repo.getMilestone(milestoneId)
    if (!milestone) throw new RequestError('no such milestone')
    const plan = this.repo.getPlan(milestone.planId)
    if (!plan) throw new RequestError('the plan for this milestone is missing')

    const missing = missingExpectedPaths(plan.repoPath, milestone.expectedPaths)
    const missingSet = new Set(missing)
    const tree = await readTree(plan.repoPath)

    return {
      existing: milestone.expectedPaths.filter((path) => !missingSet.has(path)),
      missing,
      dirtyPaths: tree.unknown ? [] : tree.paths,
    }
  }

  // ─── Loops ─────────────────────────────────────────────────────────────────

  /**
   * Creates a loop but does not start it.
   *
   * Creation and starting are separate so that a write-capable loop can be
   * approved *against its own id*. Granting the approval first is impossible —
   * the loop does not exist yet — and keying it to anything else would mean an
   * approval that authorises "some loop" rather than this one.
   */
  createLoop(input: {
    goal: string
    repoPath: string
    worker: Loop['worker']
    verifier: Loop['verifier']
    exit: Loop['exit']
    caps: Loop['caps']
    capability: Loop['capability']
  }): Loop {
    const repoPath = validateRepoPath(input.repoPath)

    // Fail on an unusable exit command now rather than after the first
    // iteration has already spent tokens.
    if (input.exit.kind === 'command') validateExitCommand(input.exit.command)
    if (input.exit.kind === 'review' && !input.exit.criterion.trim()) {
      throw new RequestError('a review exit condition needs a completion criterion')
    }

    // A hard refusal where the plan pipeline only warns, because the situations
    // differ in kind: a milestone has a human approval gate and two cross-vendor
    // checks, while a review-exit loop runs autonomously with exactly one check —
    // the verifier. loopVerifyPrompt promises the worker "another agent, from a
    // different model family" is checking it; the config must not be able to make
    // that a lie.
    if (input.exit.kind === 'review' && input.verifier.vendor === input.worker.vendor) {
      throw new RequestError(
        "a review-exit loop's only check is its verifier, which cannot come from the model whose work it is checking — use the other vendor, or a command exit",
      )
    }

    const loop = this.repo.createLoop({
      id: newId(),
      goal: input.goal,
      repoPath,
      worker: input.worker,
      verifier: input.verifier,
      exit: input.exit,
      caps: input.caps,
      capability: input.capability,
      approvalId: null,
      status: 'idle',
      usage: emptyUsage(),
      iterationCount: 0,
      mock: this.registry.mock,
      startedAt: Date.now(),
      endedAt: null,
      stopReason: '',
    })
    this.emit({ type: 'loop.created', loop })
    return loop
  }

  /**
   * Starts a created loop, spending an approval if it may write.
   *
   * The approval is consumed before the first iteration is dispatched, and it is
   * single-use: restarting a write-capable loop requires the human to approve
   * again, deliberately.
   */
  startLoop(loopId: Id, approvalId: Id | null): Loop {
    const existing = this.repo.getLoop(loopId)
    if (!existing) throw new RequestError('no such loop')
    if (this.loops.has(loopId)) throw new RequestError('that loop is already running')
    if (existing.status !== 'idle') {
      throw new RequestError(`that loop has already run (${existing.status})`)
    }

    const loopApprovalId = existing.capability === 'write' ? approvalId : null
    if (existing.capability === 'write') {
      if (!approvalId) throw new RequestError('a write-capable loop needs an approval before it can start')
      this.repo.consumeApproval(approvalId, 'loop.write', loopId)
    }

    const loop = this.repo.startLoop(loopId, loopApprovalId)
    const runner = new LoopRunner(loop, this.deps)
    this.loops.set(loop.id, runner)
    this.emit({ type: 'loop.status', loopId: loop.id, status: 'running' })
    void runner
      .run()
      .catch((err: unknown): LoopOutcome => {
        const reason = err instanceof Error ? err.message : String(err)
        this.repo.setLoopStatus(loop.id, 'failed', reason)
        this.emit({ type: 'loop.status', loopId: loop.id, status: 'failed', stopReason: reason })
        return { status: 'failed', reason }
      })
      .finally(() => this.loops.delete(loop.id))

    return loop
  }

  pauseLoop(loopId: Id): void {
    const runner = this.loops.get(loopId)
    if (!runner) throw new RequestError('that loop is not running')
    runner.gate.pause()
    this.repo.setLoopStatus(loopId, 'paused')
    this.emit({ type: 'loop.status', loopId, status: 'paused' })
  }

  resumeLoop(loopId: Id): void {
    const runner = this.loops.get(loopId)
    if (!runner) throw new RequestError('that loop is not running')
    runner.gate.resume()
    this.repo.setLoopStatus(loopId, 'running')
    this.emit({ type: 'loop.status', loopId, status: 'running' })
  }

  /** The kill switch. Aborts the in-flight CLI immediately. */
  killLoop(loopId: Id): void {
    const runner = this.loops.get(loopId)
    if (!runner) throw new RequestError('that loop is not running')
    runner.gate.stop()
  }

  // ─── Shutdown ──────────────────────────────────────────────────────────────

  disposeAll(): void {
    for (const runner of this.sessions.values()) runner.gate.stop()
    for (const runner of this.loops.values()) runner.gate.stop()
  }

  defaultRepoPath(): string {
    return homedir()
  }
}
