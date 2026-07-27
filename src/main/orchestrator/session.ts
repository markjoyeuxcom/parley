import { homedir } from 'node:os'
import {
  type Capability,
  type Finding,
  type Id,
  type Session,
  type Turn,
  type TurnSide,
} from '@shared/domain'
import {
  debatePrompt,
  debateSystemPrompt,
  reviewPrompt,
  reviewSystemPrompt,
  stagesFor,
  verdictPrompt,
  type StageSpec,
} from '@shared/protocol'
import { newId, type Repo } from '@main/store/repo'
import type { AgentRegistry } from '@main/agents'
import { RunGate, type OrchestratorDeps } from './types'
import {
  mergeVerdicts,
  parseFindings,
  parseSideVerdict,
  renderReport,
  toVerdict,
  type SideVerdict,
} from './verdict'

/** How long a single turn may run before it is abandoned. */
const TURN_TIMEOUT_MS = 25 * 60 * 1000
const NO_USABLE_VERDICT =
  'Neither advisor produced a usable structured verdict; the transcript is still recorded.'

/**
 * Runs one Parley session to a verdict.
 *
 * The cost property that makes this practical: each CLI keeps its own
 * conversation, resumed by vendor session id, so a turn's prompt carries only
 * the opponent's latest message. Token spend grows linearly with turns instead
 * of quadratically the way a replayed transcript would.
 */
export class SessionRunner {
  readonly gate = new RunGate()
  private readonly repo: Repo
  private readonly registry: AgentRegistry
  private readonly emit: OrchestratorDeps['emit']

  constructor(
    private session: Session,
    deps: OrchestratorDeps,
  ) {
    this.repo = deps.repo
    this.registry = deps.registry
    this.emit = deps.emit
  }

  get id(): Id {
    return this.session.id
  }

  /**
   * Capability for this session's turns.
   *
   * A review always reads the repository. A debate reads only if one was
   * attached; otherwise it runs entirely tool-free, which is both cheaper and
   * removes any path to the filesystem for a session that has no business
   * touching it. No session kind ever gets `write` — writing happens only in the
   * audited pipeline, behind an approval.
   */
  private capability(): Capability {
    if (this.session.kind === 'review') return 'read'
    return this.session.repoPath ? 'read' : 'none'
  }

  private cwd(): string {
    return this.session.repoPath ?? homedir()
  }

  private configFor(side: TurnSide) {
    // Seats 0 and 1 are sides a and b — the transitional mapping while turns
    // still speak sides. It dissolves when the runner schedules seats.
    const seat = this.session.participants[side === 'a' ? 0 : 1]
    if (!seat) throw new Error(`this session has no participant seated for side ${side}`)
    return seat
  }

  private systemPromptFor(side: TurnSide): string {
    const cfg = this.configFor(side)
    return this.session.kind === 'review' ? reviewSystemPrompt(side, cfg) : debateSystemPrompt(side, cfg)
  }

  async run(): Promise<void> {
    const stages = stagesFor(this.session.kind, this.session.maxTurns)
    this.setStatus('running')

    try {
      let lastBySide: Partial<Record<TurnSide, string>> = {}

      for (const [index, stage] of stages.entries()) {
        await this.gate.wait()
        if (this.gate.isStopped) return this.setStatus('cancelled')

        const opponent: TurnSide = stage.side === 'a' ? 'b' : 'a'
        const turn = await this.runTurn(stage, index, lastBySide[opponent] ?? null)

        if (turn.error) {
          // A missing turn corrupts the record this tool exists to produce, so
          // the session fails loudly rather than quietly continuing short a
          // stage.
          this.setStatus('failed', turn.error)
          return
        }
        lastBySide = { ...lastBySide, [stage.side]: turn.text }
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

  private async runTurn(stage: StageSpec, index: number, opponentMessage: string | null): Promise<Turn> {
    const side = stage.side
    const cfg = this.configFor(side)
    const adapter = this.registry.get(cfg.vendor)

    const interjections = this.repo.takeInterjections(this.session.id, side).map((i) => i.text)

    const promptInput = {
      stage,
      matter: this.session.matter,
      repoPath: this.session.repoPath,
      opponentMessage,
      interjections,
    }
    const prompt =
      this.session.kind === 'review' ? reviewPrompt(promptInput) : debatePrompt(promptInput)

    const turn: Turn = {
      id: newId(),
      sessionId: this.session.id,
      index,
      side,
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
      systemPrompt: this.systemPromptFor(side),
      prompt,
      cfg,
      capability: this.capability(),
      cwd: this.cwd(),
      resumeId: this.repo.getResumeId(this.session.id, side),
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
    if (result.resumeId) this.repo.saveResumeId(this.session.id, side, result.resumeId)

    const usage = this.repo.addSessionUsage(this.session.id, result.usage)
    this.session = { ...this.session, usage }

    this.emit({ type: 'session.turn.ended', turn })
    this.emit({ type: 'session.usage', sessionId: this.session.id, usage })

    return turn
  }

  /**
   * Asks both sides for a verdict **concurrently and independently**.
   *
   * Concurrency is not an optimisation here. Running them in sequence would let
   * the second verdict be written after the first, and even without relaying it
   * the ordering invites the kind of convergence the whole exercise is designed
   * to avoid. Two independent verdicts that disagree are a real result.
   */
  private async recordVerdict(startIndex: number): Promise<boolean> {
    const prompt = verdictPrompt(this.session.matter, this.session.kind)

    const ask = async (side: TurnSide, index: number): Promise<{ side: TurnSide; text: string }> => {
      const cfg = this.configFor(side)
      const adapter = this.registry.get(cfg.vendor)

      const turn: Turn = {
        id: newId(),
        sessionId: this.session.id,
        index,
        side,
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
        systemPrompt: this.systemPromptFor(side),
        prompt,
        cfg,
        capability: this.capability(),
        cwd: this.cwd(),
        resumeId: this.repo.getResumeId(this.session.id, side),
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
      if (result.resumeId) this.repo.saveResumeId(this.session.id, side, result.resumeId)

      const usage = this.repo.addSessionUsage(this.session.id, result.usage)
      this.session = { ...this.session, usage }
      this.emit({ type: 'session.turn.ended', turn })
      this.emit({ type: 'session.usage', sessionId: this.session.id, usage })

      return { side, text: result.text }
    }

    const [a, b] = await Promise.all([ask('a', startIndex), ask('b', startIndex + 1)])

    const sideA: SideVerdict | null = parseSideVerdict(a.text)
    const sideB: SideVerdict | null = parseSideVerdict(b.text)
    const merged = mergeVerdicts(sideA, sideB)

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
    return true
  }

  /**
   * Findings come from the reconciliation turn, which is the only stage that has
   * seen both the independent audit and the cross-examination. Earlier stages
   * are searched only as a fallback for a session that ended early.
   */
  private collectFindings(): Finding[] {
    if (this.session.kind !== 'review') return []
    const turns = this.repo.listTurns(this.session.id)

    for (const stageName of ['Reconciliation', 'Cross-examination', 'Independent audit']) {
      const turn = [...turns].reverse().find((t) => t.stage === stageName && !t.error)
      if (!turn) continue
      const parsed = parseFindings(turn.text, this.session.id, turn.side)
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
