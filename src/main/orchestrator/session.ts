import { homedir } from 'node:os'
import {
  type Capability,
  type Finding,
  type Id,
  type Session,
  type Turn,
} from '@shared/domain'
import {
  protocolFor,
  resolveActor,
  resolveStageInput,
  verdictPrompt,
  type EngineStage,
  type SessionProtocol,
} from '@shared/protocol'
import { newId, type Repo } from '@main/store/repo'
import type { AgentRegistry } from '@main/agents'
import { RunGate, type OrchestratorDeps } from './types'
import { backfillBacklogFromSession } from './backlog'
import { mergeVerdicts, parseFindings, parseSeatVerdict, renderReport, toVerdict } from './verdict'

/** How long a single turn may run before it is abandoned. */
const TURN_TIMEOUT_MS = 25 * 60 * 1000
const NO_USABLE_VERDICT =
  'No advisor produced a usable structured verdict; the transcript is still recorded.'

/**
 * Runs one Parley session to a verdict.
 *
 * The runner is an interpreter: everything that makes a debate a debate or a
 * review a review — the schedule, the stances, the prompts, what each stage
 * is shown, what a turn may touch — lives in the {@link SessionProtocol} it
 * executes. The runner owns only what every protocol shares: turn mechanics,
 * resume threading, whisper delivery, and the closing merge.
 *
 * The cost property that makes this practical: each CLI keeps its own
 * conversation, resumed by vendor session id, so a turn's prompt carries only
 * the stage's declared input. Token spend grows linearly with turns instead
 * of quadratically the way a replayed transcript would.
 */
export class SessionRunner {
  readonly gate = new RunGate()
  private readonly repo: Repo
  private readonly registry: AgentRegistry
  private readonly emit: OrchestratorDeps['emit']
  /** Selected by kind until protocols are data — the next phase's work. */
  private readonly protocol: SessionProtocol

  constructor(
    private session: Session,
    deps: OrchestratorDeps,
  ) {
    this.repo = deps.repo
    this.registry = deps.registry
    this.emit = deps.emit
    this.protocol = protocolFor(session.kind)
  }

  get id(): Id {
    return this.session.id
  }

  private capability(): Capability {
    return this.protocol.capability(this.session.repoPath !== null)
  }

  private cwd(): string {
    return this.session.repoPath ?? homedir()
  }

  private configFor(seat: number) {
    const participant = this.session.participants[seat]
    if (!participant) throw new Error(`this session has nobody in seat ${seat}`)
    return participant
  }

  private systemPromptFor(seat: number): string {
    return this.protocol.systemPrompt(seat, this.configFor(seat))
  }

  async run(): Promise<void> {
    const stages = this.protocol.stages(this.session.maxTurns)
    this.setStatus('running')

    try {
      const lastBySeat = new Map<number, string>()

      for (const [index, stage] of stages.entries()) {
        await this.gate.wait()
        if (this.gate.isStopped) return this.setStatus('cancelled')

        const message = resolveStageInput(stage.input, stage.seat, lastBySeat)
        const turn = await this.runTurn(stage, index, message)

        if (turn.error) {
          // A missing turn corrupts the record this tool exists to produce, so
          // the session fails loudly rather than quietly continuing short a
          // stage.
          this.setStatus('failed', turn.error)
          return
        }
        lastBySeat.set(stage.seat, turn.text)
      }

      await this.gate.wait()
      if (this.gate.isStopped) return this.setStatus('cancelled')

      const recorded = await this.recordVerdict(stages.length)
      if (!recorded) {
        this.setStatus('failed', NO_USABLE_VERDICT)
        return
      }
      this.setStatus('complete')
    } catch (err) {
      if (this.gate.isStopped) {
        this.setStatus('cancelled')
        return
      }
      this.setStatus('failed', err instanceof Error ? err.message : String(err))
    }
  }

  private async runTurn(stage: EngineStage, index: number, opponentMessage: string | null): Promise<Turn> {
    const seat = stage.seat
    const cfg = this.configFor(seat)
    const adapter = this.registry.get(cfg.vendor)

    const interjections = this.repo.takeInterjections(this.session.id, seat).map((i) => i.text)

    const prompt = this.protocol.stagePrompt({
      stage,
      matter: this.session.matter,
      repoPath: this.session.repoPath,
      opponentMessage,
      interjections,
    })

    const turn: Turn = {
      id: newId(),
      sessionId: this.session.id,
      index,
      seat,
      vendor: cfg.vendor,
      model: cfg.model,
      stage: stage.label,
      text: '',
      usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
      startedAt: Date.now(),
      endedAt: null,
      error: null,
    }
    this.repo.createTurn(turn)
    this.emit({ type: 'session.turn.started', turn })

    const result = await adapter.run({
      systemPrompt: this.systemPromptFor(seat),
      prompt,
      cfg,
      capability: this.capability(),
      cwd: this.cwd(),
      resumeId: this.repo.getResumeId(this.session.id, seat),
      signal: this.gate.signal,
      timeoutMs: TURN_TIMEOUT_MS,
      onDelta: (text) =>
        this.emit({ type: 'session.turn.delta', sessionId: this.session.id, turnId: turn.id, text }),
    })

    turn.text = result.text
    turn.usage = result.usage
    turn.endedAt = Date.now()
    turn.error = result.error

    this.repo.finishTurn(turn)
    if (result.resumeId) this.repo.saveResumeId(this.session.id, seat, result.resumeId)

    const usage = this.repo.addSessionUsage(this.session.id, result.usage)
    this.session = { ...this.session, usage }

    this.emit({ type: 'session.turn.ended', turn })
    this.emit({ type: 'session.usage', sessionId: this.session.id, usage })

    return turn
  }

  /**
   * Asks every seat for a verdict **concurrently and independently**.
   *
   * Concurrency is not an optimisation here. Any ordering would let a later
   * verdict be written after an earlier one, and even without relaying it the
   * ordering invites the kind of convergence the whole exercise is designed to
   * avoid. Independent verdicts that disagree are a real result.
   */
  private async recordVerdict(startIndex: number): Promise<boolean> {
    const ask = async (seat: number, index: number): Promise<{ seat: number; text: string }> => {
      const cfg = this.configFor(seat)
      const adapter = this.registry.get(cfg.vendor)

      // A verdict turn is a speaking turn, so it drains the seat's direction
      // queue like any other. For a seat that only speaks at the closing this
      // is the one turn a whisper can reach; before this, such a whisper sat
      // queued forever, silently.
      const interjections = this.repo.takeInterjections(this.session.id, seat).map((i) => i.text)
      const prompt = verdictPrompt(this.session.matter, this.session.kind, interjections)

      const turn: Turn = {
        id: newId(),
        sessionId: this.session.id,
        index,
        seat,
        vendor: cfg.vendor,
        model: cfg.model,
        stage: 'Verdict',
        text: '',
        usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
        startedAt: Date.now(),
        endedAt: null,
        error: null,
      }
      this.repo.createTurn(turn)
      this.emit({ type: 'session.turn.started', turn })

      const result = await adapter.run({
        systemPrompt: this.systemPromptFor(seat),
        prompt,
        cfg,
        capability: this.capability(),
        cwd: this.cwd(),
        resumeId: this.repo.getResumeId(this.session.id, seat),
        signal: this.gate.signal,
        timeoutMs: TURN_TIMEOUT_MS,
        onDelta: (text) =>
          this.emit({ type: 'session.turn.delta', sessionId: this.session.id, turnId: turn.id, text }),
      })

      turn.text = result.text
      turn.usage = result.usage
      turn.endedAt = Date.now()
      turn.error = result.error
      this.repo.finishTurn(turn)
      if (result.resumeId) this.repo.saveResumeId(this.session.id, seat, result.resumeId)

      const usage = this.repo.addSessionUsage(this.session.id, result.usage)
      this.session = { ...this.session, usage }
      this.emit({ type: 'session.turn.ended', turn })
      this.emit({ type: 'session.usage', sessionId: this.session.id, usage })

      return { seat, text: result.text }
    }

    // The closing sequence is data with a role selector, not a pair of named
    // asks: every seat records its own verdict. The concurrency is still not
    // an optimisation — any ordering would invite convergence between however
    // many advisors there are, so they all answer at once, each blind to the
    // rest.
    const seats = resolveActor(this.protocol.closing.actor, this.session.participants.length)
    const replies = await Promise.all(seats.map((seat, at) => ask(seat, startIndex + at)))
    // Slotted by seat, not by reply order: the merge labels dissent by array
    // index, and that must stay true under any selector, not only the dense
    // one in use today.
    const verdicts = this.session.participants.map(() => null as ReturnType<typeof parseSeatVerdict>)
    for (const reply of replies) verdicts[reply.seat] = parseSeatVerdict(reply.text)
    const merged = mergeVerdicts(verdicts)

    if (!merged) {
      this.emit({
        type: 'notice',
        level: 'warn',
        message: NO_USABLE_VERDICT,
      })
      return false
    }

    const findings = this.collectFindings()
    if (findings.length) this.repo.replaceFindings(this.session.id, findings)
    for (const finding of findings) this.emit({ type: 'session.finding', finding })

    const turns = this.repo.listTurns(this.session.id)
    const current = this.repo.getSession(this.session.id) ?? this.session
    const report = renderReport(current, turns, merged, findings)
    const verdict = toVerdict(this.session.id, merged, report)

    this.repo.saveVerdict(verdict)
    this.emit({ type: 'session.verdict', verdict })
    // Deterministic, replayable, and dedupe-safe — see orchestrator/backlog.
    backfillBacklogFromSession(this.repo, this.session.id, (event) => this.emit(event))
    return true
  }

  /**
   * Harvests findings from the stages the protocol names, in its preference
   * order — for a review, the reconciliation first, since it is the only stage
   * that has seen both the audit and the cross-examination, with earlier
   * stages as fallbacks for a session that ended early. A protocol that names
   * no stages records its outcome in the verdict alone.
   */
  private collectFindings(): Finding[] {
    if (this.protocol.findingsFrom.length === 0) return []
    const turns = this.repo.listTurns(this.session.id)

    for (const stageName of this.protocol.findingsFrom) {
      const turn = [...turns].reverse().find((t) => t.stage === stageName && !t.error)
      if (!turn) continue
      const parsed = parseFindings(turn.text, this.session.id, turn.seat)
      if (parsed.length) return parsed
    }
    return []
  }

  private setStatus(status: Session['status'], error?: string): void {
    this.session = { ...this.session, status, error: error ?? null }
    this.repo.setSessionStatus(this.session.id, status, error ?? null)
    this.emit({ type: 'session.status', sessionId: this.session.id, status, ...(error ? { error } : {}) })
  }
}
