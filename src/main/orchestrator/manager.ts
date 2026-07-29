import { homedir } from 'node:os'
import { existsSync, statSync } from 'node:fs'
import { isAbsolute } from 'node:path'
import {
  type AgentConfig,
  type BacklogItem,
  type ForemanProposal,
  type InterjectionTarget,
  type Approval,
  emptyUsage,
  type Id,
  type Loop,
  type Milestone,
  type Session,
  type Skill,
  type WorkPlan,
  type Worktree,
} from '@shared/domain'
import type { AppEvent } from '@shared/events'
import type { Hold } from '@shared/holds'
import type { AgentRegistry } from '@main/agents'
import { isShellFree, shellMetacharsIn } from '@shared/command'
import { extractJson, safeString } from '@shared/extract'
import { protocolFor, STOW_CONTRACT } from '@shared/protocol'
import { canonicalRepoPath } from '@main/util/repoPath'
import { newId, type Repo } from '@main/store/repo'
import { HoldsEngine } from './holds'
import {
  proposeBacklogClosures,
  regressPlannedItems,
  renderBacklogBlock,
  renderLearningsBlock,
} from './backlog'
import { LivenessWatchdog } from './liveness'
import { runForeman } from './foreman'
import { runSelfGate, type SelfGateOptions } from './selfupdate'
import { landWorktree, preflightLand, verifyLanding } from './worktrees'
import { LoopRunner, validateExitCommand, type LoopOutcome } from './loop'
import { missingExpectedPaths, Pipeline, readTree } from './pipeline'
import { assertNoUnresolvedBlockingOccurrences } from './gate'
import { SessionRunner } from './session'
import { RunGate, type OrchestratorDeps } from './types'

export class RequestError extends Error {}

/** A stow sweep is one look, not a stage: bounded well under a turn. */
const STOW_TIMEOUT_MS = 5 * 60 * 1000

export type SelfGateLaunch = 'started' | 'queued' | 'dormant'
type QueuedSelfGate = {
  planId: Id
  opts: Omit<SelfGateOptions, 'signal'>
}

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
  /**
   * The in-flight milestone runs, by milestone id — execution and adoption
   * share it, since the two are mutually exclusive per milestone. This map is
   * both the stop button's handle and the concurrency guard: the has-check is
   * synchronous and precedes every await, so a second start cannot slip in
   * during worktree setup and cannot, on its refused way out, delete the live
   * run's gate.
   */
  private readonly milestoneRuns = new Map<Id, RunGate>()
  /** In-flight stow sweeps — the same synchronous has-check discipline. */
  private readonly stowRuns = new Set<Id>()
  /**
   * In-flight self-update gates, keyed by the canonical self repo path (so
   * ever at most one entry today, but the key states the invariant: one gate
   * per checkout, because two concurrent builds would interleave writes into
   * the same out/). Same synchronous has-check discipline as milestoneRuns.
   */
  private readonly selfGateRuns = new Map<string, AbortController>()
  /** The newest landing waiting for each checkout's in-flight gate to finish. */
  private readonly selfGateQueue = new Map<string, QueuedSelfGate>()
  /** In-flight foreman reads, keyed by canonical repo path. Same discipline. */
  private readonly foremanRuns = new Set<string>()
  private readonly loops = new Map<Id, LoopRunner>()
  private readonly pipeline: Pipeline
  private readonly deps: OrchestratorDeps
  private readonly holds: HoldsEngine
  private readonly liveness: LivenessWatchdog
  readonly repo: Repo
  readonly registry: AgentRegistry

  constructor(deps: OrchestratorDeps) {
    // The holds engine sits in front of emit: every durable transition already
    // flows through that one function, so instrumenting it here means every
    // runner — pipeline, sessions, loops — keeps the attention queue current
    // without knowing it exists. The liveness watchdog observes the same
    // stream one layer earlier: activity events are its whole signal, and
    // they are exactly what the holds engine deliberately ignores.
    this.holds = new HoldsEngine(deps.repo, deps.emit, deps.notifyUser)
    this.liveness = new LivenessWatchdog({
      repo: deps.repo,
      holdsChanged: () => this.holds.schedule(),
      inspectMilestone: (milestoneId) => {
        // Fire-and-forget by design; the verdict lands in the run state and
        // the recompute surfaces it. An inspector that fails must not look
        // like a new problem.
        void this.pipeline
          .inspectStalledMilestone(milestoneId)
          .then(() => this.holds.schedule())
          .catch(() => {})
      },
    })
    this.deps = {
      ...deps,
      // Canonicalised ONCE here, so every self-repo comparison downstream —
      // createPlan's refusal, the pipeline's execution gate, the landing
      // hook — is canonical-to-canonical. A raw app.getAppPath() and a
      // user-picked spelling of the same checkout must not fork the rule.
      selfRepoPath: deps.selfRepoPath ? canonicalRepoPath(deps.selfRepoPath) : null,
      emit: (event) => {
        this.liveness.observe(event)
        this.holds.emit(event)
      },
    }
    this.repo = deps.repo
    this.registry = deps.registry
    this.pipeline = new Pipeline(this.deps)
    this.seedSkills()
    this.liveness.start()
    // Publish (and notify, once each) whatever was already waiting when the
    // app started — including holds created moments before a quit.
    this.holds.schedule()
  }

  /**
   * The one emit chain. Public because the IPC layer's handlers mutate state
   * too (backlog triage, ledger dispositions), and an event that reaches the
   * window without passing the holds engine leaves the attention queue stale —
   * the badge kept showing a hold whose proposals were already triaged. Every
   * event, whatever its origin, goes through here; there is no side door.
   */
  emit(event: AppEvent): void {
    this.deps.emit(event)
  }

  /** The canonical path of the checkout this app runs from, or null when packaged. */
  get selfRepoPath(): string | null {
    return this.deps.selfRepoPath ?? null
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
    participants: AgentConfig[]
    maxTurns: number
  }): Session {
    const repoPath = input.repoPath ? validateRepoPath(input.repoPath) : null
    if (input.kind === 'review' && !repoPath) {
      throw new RequestError('a codebase review needs a repository')
    }
    // The schema enforces this at the IPC boundary; re-checked here because
    // the Manager is also called directly, and a one-seat parley is not one.
    if (input.participants.length < 2) {
      throw new RequestError('a session needs at least two participants')
    }

    const session = this.repo.createSession({
      id: newId(),
      kind: input.kind,
      status: 'idle',
      matter: input.matter,
      project: input.project,
      repoPath,
      participants: input.participants,
      maxTurns: input.maxTurns,
      mock: this.registry.mock,
      createdAt: Date.now(),
    })

    // A repeated vendor anywhere weakens the cross-check this is built for.
    if (new Set(input.participants.map((seat) => seat.vendor)).size < input.participants.length) {
      this.emit({
        type: 'notice',
        level: 'warn',
        message:
          'More than one seat runs the same vendor. Those seats will share blind spots, which weakens the cross-check this is built for.',
      })
    }

    this.emit({ type: 'session.created', session })

    const runner = new SessionRunner(session, this.deps)
    this.sessions.set(session.id, runner)
    void runner.run().finally(() => this.sessions.delete(session.id))

    return session
  }

  interject(sessionId: Id, target: InterjectionTarget, text: string): void {
    const session = this.repo.getSession(sessionId)
    if (!session) throw new RequestError('no such session')
    // A whisper to an empty chair would sit undeliverable forever, silently.
    if (target !== 'all' && target >= session.participants.length) {
      throw new RequestError(`this session has no seat ${target + 1} to whisper to`)
    }
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

  /**
   * One read-only agent turn that distills a finished session into durable
   * record: backlog items worth acting on later, learnings worth telling
   * every future plan. Everything it drafts files as *proposed* — a human
   * confirms or discards before any of it counts — and the input is composed
   * and bounded (never verdict.report, which embeds the whole exchange).
   * User-initiated, so failures surface; usage lands on the session.
   */
  async stowSession(
    sessionId: Id,
  ): Promise<{ filedItems: number; filedLearnings: number; duplicates: number }> {
    const session = this.repo.getSession(sessionId)
    if (!session) throw new RequestError('no such session')
    if (!session.repoPath) {
      throw new RequestError('this session has no repository, so there is nowhere to file what it learned')
    }
    const verdict = this.repo.getVerdict(sessionId)
    if (!verdict) throw new RequestError('stow needs a saved verdict — let the session finish first')
    if (this.stowRuns.has(sessionId)) {
      throw new RequestError('a stow sweep for this session is already running')
    }
    this.stowRuns.add(sessionId)
    try {
      const findings = this.repo.listFindings(sessionId)
      const protocol = protocolFor(session.kind)
      const turns = this.repo.listTurns(sessionId).filter((turn) => !turn.error)
      const relevant = protocol.findingsFrom.length
        ? turns.filter((turn) => protocol.findingsFrom.includes(turn.stage))
        : turns
      // The bounded-snapshot philosophy: the closing stages' tails, never the
      // whole transcript.
      const exchange = relevant
        .slice(-6)
        .map((turn) => `[${turn.stage} — ${turn.vendor}]\n${turn.text.trim().slice(-4000)}`)

      const seatZero = session.participants[0]
      const vendor = this.registry.counterpart(seatZero?.vendor ?? 'claude')
      const sweeper = this.registry.get(vendor)

      const reply = await sweeper.run({
        systemPrompt:
          'You distill what this session learned into durable record: backlog items worth acting on later, and repository learnings worth telling every future plan. You are read-only. Propose only what the transcript actually supports.',
        prompt: [
          `THE MATTER:\n${session.matter}`,
          `THE DECISION: ${verdict.decision}`,
          verdict.rationale ? `RATIONALE: ${verdict.rationale}` : '',
          verdict.dissent ? `UNRESOLVED DISSENT: ${verdict.dissent}` : '',
          findings.length
            ? `FINDINGS ALREADY RECORDED (do not re-propose these):\n${findings
                .map((finding) => `- [${finding.priority} ${finding.status}] ${finding.title}`)
                .join('\n')}`
            : '',
          exchange.length ? `THE CLOSING EXCHANGE (bounded):\n\n${exchange.join('\n\n———\n\n')}` : '',
          STOW_CONTRACT,
        ]
          .filter(Boolean)
          .join('\n\n'),
        cfg: { vendor, model: '', effort: 'medium', persona: '' },
        capability: 'read',
        cwd: session.repoPath,
        timeoutMs: STOW_TIMEOUT_MS,
      })
      const usage = this.repo.addSessionUsage(sessionId, reply.usage)
      this.emit({ type: 'session.usage', sessionId, usage })
      if (reply.error) throw new RequestError(`the stow sweep failed: ${reply.error}`)

      const parsed = extractJson<{ items?: unknown; learnings?: unknown }>(reply.text).data
      if (!parsed) throw new RequestError('the stow sweep returned nothing parseable')
      const rawItems = Array.isArray(parsed.items) ? parsed.items : []
      const rawLearnings = Array.isArray(parsed.learnings) ? parsed.learnings : []

      let filedItems = 0
      let filedLearnings = 0
      let duplicates = 0
      for (const raw of rawItems.slice(0, 20)) {
        const entry = raw as Record<string, unknown>
        const title = safeString(entry?.['title']).trim()
        if (!title) continue
        const result = this.repo.fileBacklogItem({
          repoPath: session.repoPath,
          title,
          detail: safeString(entry?.['detail']).trim(),
          source: 'stow',
          originSessionId: sessionId,
          mock: session.mock,
          state: 'proposed',
          note: 'Proposed by a stow sweep.',
        })
        if (result.resighted) duplicates += 1
        else filedItems += 1
      }
      for (const raw of rawLearnings.slice(0, 12)) {
        const text = safeString(raw).trim()
        if (!text) continue
        const result = this.repo.fileLearning({
          repoPath: session.repoPath,
          text,
          source: 'stow',
          originSessionId: sessionId,
          mock: session.mock,
        })
        if (result.duplicate) duplicates += 1
        else filedLearnings += 1
      }

      if (filedItems + filedLearnings > 0) {
        this.emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(session.repoPath) })
      }
      return { filedItems, filedLearnings, duplicates }
    } finally {
      this.stowRuns.delete(sessionId)
    }
  }

  // ─── Foreman ───────────────────────────────────────────────────────────────

  /**
   * One gated read of a repository's backlog. The run itself lives in
   * foreman.ts; what belongs here is the in-flight guard — synchronous
   * has/add before the first await, delete in finally — because the guard's
   * whole meaning is per-Manager.
   */
  async runForeman(repoPath: string, cfg: AgentConfig): Promise<ForemanProposal> {
    const canonical = canonicalRepoPath(repoPath)
    if (this.foremanRuns.has(canonical)) {
      throw new RequestError('the foreman is already reading this repository')
    }
    this.foremanRuns.add(canonical)
    try {
      return await runForeman(
        { repo: this.repo, registry: this.registry, emit: (event) => this.emit(event) },
        canonical,
        cfg,
      )
    } finally {
      this.foremanRuns.delete(canonical)
    }
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
    isolation?: WorkPlan['isolation']
    setupCommand?: string
    /** Open backlog items this plan targets; they flip to planned. */
    backlogItemIds?: Id[]
    /** A pending foreman proposal this creation accepts, atomically. */
    foremanProposalId?: Id | null
  }): Promise<{ plan: WorkPlan; milestones: Milestone[] }> {
    const session = this.repo.getSession(input.sessionId)
    if (!session) throw new RequestError('no such session')
    const verdict = this.repo.getVerdict(input.sessionId)
    if (!verdict) throw new RequestError('that session has no verdict to plan from')

    const repoPath = validateRepoPath(input.repoPath)

    // Worktree constraints bite at execution time, half an hour of agent work
    // away — so anything checkable is refused now, at the dialog.
    const isolation = input.isolation ?? 'checkout'
    const setupCommand = (input.setupCommand ?? '').trim()
    if (isolation === 'worktree' && !this.deps.worktreesRoot) {
      throw new RequestError('worktree isolation is unavailable: no worktrees root is configured')
    }
    if (
      isolation === 'checkout' &&
      this.deps.selfRepoPath &&
      canonicalRepoPath(repoPath) === this.deps.selfRepoPath
    ) {
      throw new RequestError(
        "this is Parley's own repository — plans here run in a worktree only: an agent writing into the live app's source under it is the one uncontrolled case",
      )
    }
    if (setupCommand && !isShellFree(setupCommand)) {
      throw new RequestError(
        `the setup command needs shell syntax (${shellMetacharsIn(setupCommand).join(' ')}), which Parley spawns without. Use a single command, or a script in the repository that does the rest.`,
      )
    }

    // Selected backlog items are validated before the plan row exists, so a
    // bad selection costs nothing. The flip to `planned` happens after the
    // row is created, in the same synchronous stretch — no await between
    // validate, create and flip is what makes two racing selections safe:
    // the second sees `planned` and refuses here.
    const backlogItemIds = [...new Set(input.backlogItemIds ?? [])]
    const backlogItems: BacklogItem[] = []
    for (const itemId of backlogItemIds) {
      const item = this.repo.getBacklogItem(itemId)
      if (!item) throw new RequestError(`no such backlog item: ${itemId}`)
      if (item.state !== 'open') {
        throw new RequestError(`backlog item “${item.title}” is ${item.state}, not open`)
      }
      if (item.mock !== this.registry.mock) {
        throw new RequestError(
          `backlog item “${item.title}” is ${item.mock ? 'mock' : 'real'} work; this app is running against ${this.registry.mock ? 'mock adapters' : 'real CLIs'}`,
        )
      }
      if (item.repoPath !== canonicalRepoPath(repoPath)) {
        throw new RequestError(`backlog item “${item.title}” belongs to a different repository`)
      }
      backlogItems.push(item)
    }

    // A foreman proposal accepted by this creation is validated with the same
    // pre-row refusals: nothing exists yet, so a stale or foreign proposal
    // costs exactly nothing. The acceptance itself happens inside
    // bindPlanCreation's transaction below — there is no separate accept
    // endpoint, and so no window where a plan runs while its proposal reads
    // pending.
    let proposal: ForemanProposal | null = null
    if (input.foremanProposalId) {
      proposal = this.repo.getForemanProposal(input.foremanProposalId)
      if (!proposal) throw new RequestError('no such foreman proposal')
      if (proposal.state !== 'proposed') {
        throw new RequestError(
          proposal.state === 'superseded'
            ? 'that foreman proposal was superseded by a newer run — review the fresh one instead'
            : `that foreman proposal is ${proposal.state}, not pending`,
        )
      }
      if (proposal.repoPath !== canonicalRepoPath(repoPath)) {
        throw new RequestError('that foreman proposal belongs to a different repository')
      }
      if (proposal.mock !== this.registry.mock) {
        throw new RequestError(
          `that foreman proposal is ${proposal.mock ? 'mock' : 'real'} work; this app is running against ${this.registry.mock ? 'mock adapters' : 'real CLIs'}`,
        )
      }
      if (proposal.anchorSessionId !== input.sessionId) {
        throw new RequestError(
          'a foreman proposal is accepted from its anchor session — the one whose verdict the plan builds on',
        )
      }
    }

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

    // One durable act, still in the same synchronous stretch as the
    // validation above: the plan row, the selected items' flips, and — when
    // accepting a foreman proposal — the acceptance stamp, in a single
    // transaction. A crash cannot leave any two of those disagreeing.
    const plan: WorkPlan = {
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
      isolation,
      setupCommand,
      usage: emptyUsage(),
      mock: this.registry.mock,
      createdAt: Date.now(),
    }
    this.repo.bindPlanCreation(
      plan,
      backlogItems.map((item) => item.id),
      proposal?.id ?? null,
    )
    this.emit({ type: 'plan.created', plan })
    if (backlogItems.length || proposal) {
      this.emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(repoPath) })
    }

    // A remediation plan's subject is what earlier reviews objected to, not the
    // decision that started the session. Gathered here because the findings live
    // in this database and the planner only reads the repository — without this,
    // "fix the confirmed findings" arrives with no findings attached.
    const findings =
      input.kind === 'remediation' ? this.repo.reviewFindingsForSession(input.sessionId, plan.id) : []

    const operatorNote = (input.note ?? '').trim()

    // Confirmed learnings for this repo ride every brief, mock-matched and
    // capped at render time. Both backlog blocks are baked into the brief
    // string itself so they survive a clarification park-and-resume, which
    // stores and replays the brief verbatim.
    const learnings = this.repo
      .listLearnings({ repoPath, states: ['confirmed'] })
      .filter((learning) => learning.mock === this.registry.mock)

    const brief = [
      renderBacklogBlock(backlogItems),
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
      renderLearningsBlock(learnings),
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
        // Planning-stage death is unrecoverable (no re-draft exists), so the
        // items this plan claimed return to the backlog.
        regressPlannedItems(
          this.repo,
          plan.id,
          'The plan died during planning; its items return to the backlog.',
          (event) => this.emit(event),
        )
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
        // The same planning-death rule as createPlan: no re-draft exists.
        regressPlannedItems(
          this.repo,
          plan.id,
          'The plan died during planning; its items return to the backlog.',
          (event) => this.emit(event),
        )
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
    if (this.milestoneRuns.has(milestoneId)) {
      throw new RequestError('that milestone is already running')
    }
    const gate = new RunGate()
    this.milestoneRuns.set(milestoneId, gate)
    try {
      return await this.pipeline.runMilestone(milestoneId, approvalId, gate)
    } finally {
      this.milestoneRuns.delete(milestoneId)
    }
  }

  /**
   * Resumes an interrupted milestone from its preserved run state, spending a
   * fresh single-use approval — the crash-recovery stance unchanged. Shares
   * the in-flight registry with execution and adoption: one run per milestone,
   * whatever its entry.
   */
  async resumeMilestone(milestoneId: Id, approvalId: Id): Promise<Milestone> {
    if (this.milestoneRuns.has(milestoneId)) {
      throw new RequestError('that milestone is already running')
    }
    const gate = new RunGate()
    this.milestoneRuns.set(milestoneId, gate)
    try {
      return await this.pipeline.resumeMilestone(milestoneId, approvalId, gate)
    } finally {
      this.milestoneRuns.delete(milestoneId)
    }
  }

  /**
   * Stops a running milestone at its next boundary — the in-flight CLI is
   * killed, but a commit or a mutation restore already underway finishes
   * (both are atomic on their own). The run state is kept, so a stopped
   * milestone is resumable exactly like a crashed one.
   */
  stopMilestone(milestoneId: Id): void {
    const gate = this.milestoneRuns.get(milestoneId)
    if (!gate) throw new RequestError('that milestone is not running')
    gate.stop()
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
    if (this.milestoneRuns.has(milestoneId)) {
      throw new RequestError('that milestone is already running')
    }
    const gate = new RunGate()
    this.milestoneRuns.set(milestoneId, gate)
    try {
      return await this.pipeline.adoptMilestone(milestoneId, gate)
    } finally {
      this.milestoneRuns.delete(milestoneId)
    }
  }

  /**
   * The shared refusals for granting a landing and performing one. Kept in one
   * place so the grant and the act cannot drift apart on what qualifies.
   */
  private landablePlan(planId: Id): { plan: WorkPlan; worktree: Worktree } {
    const plan = this.repo.getPlan(planId)
    if (!plan) throw new RequestError('no such plan')
    if (plan.isolation !== 'worktree') {
      throw new RequestError('this plan executed in the checkout; there is nothing to land')
    }
    if (plan.mock) {
      throw new RequestError(
        'mock work never lands: these commits were produced by the mock adapters and must not fast-forward a real branch',
      )
    }
    if (plan.status !== 'complete') {
      throw new RequestError(`the plan is ${plan.status}; only a complete plan lands`)
    }
    const worktree = this.repo.getWorktreeForPlan(planId)
    if (!worktree) throw new RequestError('this plan has no worktree to land')
    return { plan, worktree }
  }

  /**
   * Grants the single-use landing authorisation, behind the same session-wide
   * finding gate as every other grant. On a complete plan the gate's bite is
   * rare — its own blockers were dispositioned or settled on the way here —
   * but landing is the one moment isolated work reaches the checkout, and the
   * chokepoint stays uniform for everything that follows this series.
   */
  grantLandApproval(planId: Id, summary: string): Approval {
    const { plan } = this.landablePlan(planId)
    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)
    return this.repo.grantApproval('plan.land', planId, summary)
  }

  /**
   * Lands a complete worktree plan's branch on the origin, fast-forward only,
   * spending the recorded approval.
   *
   * Human-initiated, always — no pipeline stage may take it. The preflight
   * runs every refusable check *before* the spend: landWorktree refuses
   * routinely (diverged origin, dirt, a vanished branch), each refusal is
   * retryable after the human fixes the world, and burning an approval per
   * git refusal would train people to click through grants. After a
   * successful fast-forward, a smoke verification of the landed work runs in
   * the origin — post-return, bounded — and a red result flags the landed
   * row, which the holds queue surfaces.
   */
  async landPlan(planId: Id, approvalId: Id): Promise<{ landed: boolean; detail: string }> {
    const { plan, worktree } = this.landablePlan(planId)

    const preflight = await preflightLand(worktree)
    if (!preflight.ok) {
      this.repo.flagWorktree(planId, worktree.orphaned, preflight.detail)
      this.holdsChanged()
      return { landed: false, detail: preflight.detail }
    }

    // The gate re-check and the spend sit in one synchronous block, the same
    // human-scale-gap reasoning as execution: a finding can land between the
    // grant and this click.
    assertNoUnresolvedBlockingOccurrences(this.repo, plan.sessionId)
    this.repo.consumeApproval(approvalId, 'plan.land', planId)

    const result = await landWorktree(this.repo, worktree)
    // Landing mutates the registry with no event on the bus; the queue must
    // move either way — ready → gone on success, ready → blocked on refusal.
    this.holdsChanged()

    if (result.landed) {
      // Landing is the moment a worktree plan's work becomes real in the
      // checkout — the completion hook deliberately skipped it, and this is
      // where its backlog items earn their closure proposal.
      proposeBacklogClosures(
        this.repo,
        planId,
        `Plan “${plan.title}” completed and its branch landed on ${plan.repoPath}.`,
        (event) => this.emit(event),
      )
      // Fire-and-forget by design: the renderer awaits landPlan, and holding
      // its invoke open for a test run is the exact wart answerPlan shed.
      //
      // Landing on Parley's own checkout takes the self-update gate INSTEAD
      // OF the generic smoke check — `npm run verify` strictly supersedes the
      // last milestone's command, and two npm runs racing in one origin would
      // fight over the same node_modules and out/.
      if (this.deps.selfRepoPath && canonicalRepoPath(plan.repoPath) === this.deps.selfRepoPath) {
        this.launchSelfGate(planId)
      } else {
        // The last milestone's command is the plan's own definition of verified.
        const lastCommand = this.repo
          .listMilestones(planId)
          .map((m) => m.testCommand.trim())
          .filter(Boolean)
          .at(-1)
        if (lastCommand) {
          void verifyLanding(worktree.originPath, lastCommand)
            .then((verify) => {
              if (verify.ok) return
              this.repo.flagWorktree(planId, false, verify.detail)
              this.holdsChanged()
              this.emit({ type: 'notice', level: 'warn', message: verify.detail })
            })
            .catch(() => {})
        }
      }
    }
    return result
  }

  /**
   * Fires the self-update gate for a plan that just landed on Parley's own
   * checkout. Public so tests exercise the guard directly — in the app the
   * landing hook is the only caller until m3's manual path exists.
   *
   * At most one gate per checkout: a landing that arrives while one runs
   * replaces that checkout's queued follow-up. No attempt row exists until
   * the follow-up starts, because a queued intention is not an observed run.
   */
  launchSelfGate(
    planId: Id,
    opts: Omit<SelfGateOptions, 'signal'> = {},
  ): SelfGateLaunch {
    const self = this.deps.selfRepoPath
    if (!self) return 'dormant'
    if (this.selfGateRuns.has(self)) {
      this.selfGateQueue.set(self, { planId, opts })
      this.emit({
        type: 'notice',
        level: 'info',
        message:
          'A self-update gate is already running; this landing is queued for a fresh gate when it finishes.',
      })
      return 'queued'
    }
    this.startSelfGate(self, planId, opts)
    return 'started'
  }

  private startSelfGate(
    self: string,
    planId: Id,
    opts: Omit<SelfGateOptions, 'signal'>,
  ): void {
    const controller = new AbortController()
    this.selfGateRuns.set(self, controller)
    void runSelfGate(this.repo, self, planId, {
      ...opts,
      signal: controller.signal,
    })
      .then((row) => {
        if (row.state === 'green') {
          if (this.selfGateQueue.has(self)) {
            this.repo.supersedeSelfUpdate(row.id)
          } else {
            this.emit({
              type: 'notice',
              level: 'info',
              message:
                'Parley verified and rebuilt itself from the landed work. Relaunch when ready — the offer is in the holds queue.',
            })
          }
        } else if (row.state === 'red') {
          // The landed-but-broken hold already exists for exactly this shape
          // of news; red rides it rather than inventing a second surface.
          this.repo.flagWorktree(planId, false, row.detail)
          this.emit({ type: 'notice', level: 'warn', message: row.detail })
        }
        this.holdsChanged()
      })
      .catch((error) => {
        // Filing itself failed — there is no row to finalize, so the notice
        // is the record's stand-in. Never swallowed: a silent catch here is
        // how a gate "ran" without a trace.
        const message = error instanceof Error ? error.message : String(error)
        this.emit({
          type: 'notice',
          level: 'warn',
          message: `The self-update gate could not run: ${message}`,
        })
      })
      .finally(() => {
        this.selfGateRuns.delete(self)
        const queued = this.selfGateQueue.get(self)
        if (queued) {
          this.selfGateQueue.delete(self)
          this.startSelfGate(self, queued.planId, queued.opts)
        }
      })
  }

  /**
   * Records a failed or blocked plan as closed out — cancelled on the record,
   * gone from the in-flight and attention counts, its planned backlog items
   * released back to open. The row and every milestone stay; close-out is a
   * disposition, never an erasure.
   */
  closeOutPlan(planId: Id): WorkPlan {
    const { plan, releasedItemIds } = this.repo.cancelPlan(planId)
    this.emit({ type: 'plan.status', planId, status: 'cancelled' })
    if (releasedItemIds.length) {
      this.emit({ type: 'backlog.changed', repoPath: canonicalRepoPath(plan.repoPath) })
    }
    this.holdsChanged()
    return plan
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

    // A worktree plan is inspected where it executes. Before the worktree
    // exists (it is created at first approval) this reads the origin instead —
    // an approximation, since origin dirt will not carry into the worktree,
    // but the honest available answer rather than a refusal.
    const worktree =
      plan.isolation === 'worktree' ? this.repo.getWorktreeForPlan(plan.id) : null
    const root =
      worktree && worktree.landedAt === null && existsSync(worktree.path)
        ? worktree.path
        : plan.repoPath

    const missing = missingExpectedPaths(root, milestone.expectedPaths)
    const missingSet = new Set(missing)
    const tree = await readTree(root)

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

  /**
   * What relaunch would interrupt, or null when nothing runs. Every registry
   * here self-prunes in a finally, so size is liveness, not history. Grid
   * panes are deliberately absent — they are the user's own terminals, named
   * in the confirm text instead of refused on their behalf.
   */
  busyWithRuns(): string | null {
    if (this.milestoneRuns.size) return 'a milestone is executing'
    if (this.planRuns.size) return 'a plan is being drafted or audited'
    if (this.sessions.size) return 'a session is running'
    if (this.loops.size) return 'a loop is running'
    if (this.stowRuns.size) return 'a stow sweep is running'
    if (this.foremanRuns.size) return 'the foreman is reading a backlog'
    if (this.selfGateQueue.size) return 'a self-update gate is queued'
    if (this.selfGateRuns.size) return 'the self-update gate itself is still running'
    return null
  }

  disposeAll(): void {
    for (const runner of this.sessions.values()) runner.gate.stop()
    for (const runner of this.loops.values()) runner.gate.stop()
    for (const gate of this.milestoneRuns.values()) gate.stop()
    // A quitting app interrupts its own gate: the abort turns the row red
    // ('interrupted') from inside the still-live process, so the record never
    // depends on the next boot noticing a stranded `running`.
    this.selfGateQueue.clear()
    for (const controller of this.selfGateRuns.values()) controller.abort()
    this.liveness.dispose()
  }

  defaultRepoPath(): string {
    return homedir()
  }
}
