import { extractJson, safeString } from '@shared/extract'
import { type Id, type Loop, type LoopIteration } from '@shared/domain'
import { emptyUsage } from '@shared/usage'
import { loopVerifyPrompt, loopWorkPrompt } from '@shared/protocol'
import { isShellFree, splitCommand } from '@main/util/spawn'
import { ensureUp, runProjectCommand } from './containers'
import { newId, type Repo } from '@main/store/repo'
import type { AgentRegistry } from '@main/agents'
import { assertCapability } from '@main/agents'
import { RunGate, type OrchestratorDeps } from './types'

const ITERATION_TIMEOUT_MS = 30 * 60 * 1000
const COMMAND_TIMEOUT_MS = 15 * 60 * 1000

export class LoopConfigError extends Error {}

/**
 * Why a loop stopped. Only `succeeded` means the goal was actually met — hitting
 * a cap is `exhausted`, and the distinction is kept everywhere rather than
 * collapsed into "finished", because a loop that ran out of iterations has told
 * you nothing about whether the work is done.
 */
export interface LoopOutcome {
  status: Loop['status']
  reason: string
}

/**
 * Validates an exit command before a loop is ever created.
 *
 * A command needing pipes, redirection or substitution is refused outright
 * rather than handed to a shell. The exit condition is the one thing in a loop
 * the human is trusting to be honest, so it runs as a bare argv with no shell
 * anywhere in the path.
 */
export function validateExitCommand(command: string): string[] {
  const trimmed = command.trim()
  if (!trimmed) throw new LoopConfigError('a command exit condition needs a command')
  if (!isShellFree(trimmed)) {
    throw new LoopConfigError(
      'the exit command contains shell syntax (pipes, redirection, variables). Parley runs it without a shell, so use a plain command — put anything more complex in a script and call that.',
    )
  }
  const argv = splitCommand(trimmed)
  if (!argv || !argv[0]) throw new LoopConfigError('could not parse the exit command')
  return argv
}

/**
 * Runs an autonomous loop under hard caps.
 *
 * Two design choices distinguish this from "let the agent run until it says it
 * is done":
 *
 *  1. **Caps are checked before dispatch, by Parley.** An agent cannot talk its
 *     way past them and cannot see them.
 *  2. **The exit condition is never self-reported.** Either a real command is
 *     run and its exit code observed, or a *different vendor's* agent checks
 *     the repository. The failure mode this prevents is the one that makes
 *     autonomous loops untrustworthy: an agent declaring success, or making its
 *     own check pass by weakening the check.
 */
export class LoopRunner {
  readonly gate = new RunGate()
  private readonly repo: Repo
  private readonly registry: AgentRegistry
  private readonly emit: OrchestratorDeps['emit']
  private readonly devcontainerBinary: string | undefined
  /** The loop's container came up already; one `up` serves every iteration. */
  private containerReady = false

  constructor(
    private loop: Loop,
    deps: OrchestratorDeps,
  ) {
    this.repo = deps.repo
    this.registry = deps.registry
    this.emit = deps.emit
    this.devcontainerBinary = deps.devcontainerBinary
  }

  get id(): Id {
    return this.loop.id
  }

  /**
   * Checks every cap. Returns a reason string when the loop must stop.
   *
   * A `maxSpendUsd` of 0 disables the spend cap rather than stopping
   * immediately: the CLIs report notional cost on subscription plans (codex
   * reports none at all), so 0 is what a subscription user naturally enters to
   * mean "not billing me per token".
   */
  private capBreached(): string | null {
    const { caps } = this.loop
    if (this.loop.iterationCount >= caps.maxIterations) {
      return `reached the ${caps.maxIterations}-iteration cap`
    }
    if (caps.maxSpendUsd > 0 && this.loop.usage.costUsd >= caps.maxSpendUsd) {
      return `reached the $${caps.maxSpendUsd.toFixed(2)} reported-spend cap`
    }
    const elapsed = Date.now() - this.loop.startedAt
    if (elapsed >= caps.maxWallClockMs) {
      return `reached the ${Math.round(caps.maxWallClockMs / 60000)}-minute time cap`
    }
    return null
  }

  async run(): Promise<LoopOutcome> {
    // Belt and braces alongside the store: a write-capable loop must carry a
    // consumed approval, and the adapter refuses without one.
    try {
      assertCapability(this.loop.capability, this.loop.approvalId !== null)
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err)
      this.setStatus('failed', reason)
      return { status: 'failed', reason }
    }

    let lastFeedback = ''

    for (;;) {
      await this.gate.wait()
      if (this.gate.isStopped) {
        this.setStatus('killed', 'stopped by the operator')
        return { status: 'killed', reason: 'stopped by the operator' }
      }

      const breach = this.capBreached()
      if (breach) {
        this.setStatus('exhausted', breach)
        return { status: 'exhausted', reason: breach }
      }

      const outcome = await this.iterate(lastFeedback)
      if (outcome.stop) return outcome.result

      lastFeedback = outcome.feedback
    }
  }

  private async iterate(
    lastFeedback: string,
  ): Promise<{ stop: true; result: LoopOutcome } | { stop: false; feedback: string }> {
    const index = this.loop.iterationCount
    const worker = this.registry.get(this.loop.worker.vendor)

    const iteration: LoopIteration = {
      id: newId(),
      loopId: this.loop.id,
      index,
      vendor: this.loop.worker.vendor,
      summary: '',
      usage: emptyUsage(),
      exitMet: false,
      exitDetail: '',
      startedAt: Date.now(),
      endedAt: null,
      error: null,
    }
    this.repo.createIteration(iteration)
    this.emit({ type: 'loop.iteration.started', iteration })

    const work = await worker.run({
      systemPrompt:
        'You are working autonomously toward a goal, under supervision. Make real progress each iteration and report honestly, including what did not work.',
      prompt: loopWorkPrompt(this.loop.goal, index, lastFeedback, this.loop.repoPath),
      cfg: this.loop.worker,
      capability: this.loop.capability,
      cwd: this.loop.repoPath,
      signal: this.gate.signal,
      timeoutMs: ITERATION_TIMEOUT_MS,
      onActivity: (text) => this.emit({ type: 'loop.activity', loopId: this.loop.id, text }),
    })

    iteration.summary = work.text
    iteration.usage = work.usage
    iteration.error = work.error

    this.loop = this.repo.bumpLoop(this.loop.id, work.usage)

    if (work.error) {
      iteration.endedAt = Date.now()
      this.repo.finishIteration(iteration)
      this.emit({ type: 'loop.iteration.ended', iteration })

      if (this.gate.isStopped) {
        this.setStatus('killed', 'stopped by the operator')
        return { stop: true, result: { status: 'killed', reason: 'stopped by the operator' } }
      }
      this.setStatus('failed', work.error)
      return { stop: true, result: { status: 'failed', reason: work.error } }
    }

    const check = await this.checkExit(work.text)
    iteration.exitMet = check.met
    iteration.exitDetail = check.detail
    iteration.endedAt = Date.now()
    this.repo.finishIteration(iteration)
    this.emit({ type: 'loop.iteration.ended', iteration })

    if (check.met) {
      this.setStatus('succeeded', check.detail)
      return { stop: true, result: { status: 'succeeded', reason: check.detail } }
    }

    return { stop: false, feedback: check.detail }
  }

  /** Observes the exit condition. Never asks the worker whether it is finished. */
  private async checkExit(workerReport: string): Promise<{ met: boolean; detail: string }> {
    if (this.loop.exit.kind === 'command') {
      const argv = validateExitCommand(this.loop.exit.command)
      // A container that will not start reads as exit-not-met with the cause
      // in front of the human — the caps bound how long a broken daemon can
      // burn iterations, and the detail names what to fix.
      if (this.loop.container && !this.containerReady) {
        const up = await ensureUp(this.loop.repoPath, {
          binary: this.devcontainerBinary,
          signal: this.gate.signal,
        })
        if (up.exitCode !== 0) {
          return {
            met: false,
            detail: `the dev container failed to start: ${`${up.stderr}\n${up.stdout}`.trim().slice(0, 600)}`,
          }
        }
        this.containerReady = true
      }
      const result = await runProjectCommand(argv, this.loop.repoPath, {
        container: this.loop.container,
        binary: this.devcontainerBinary,
        timeoutMs: COMMAND_TIMEOUT_MS,
        signal: this.gate.signal,
      })
      if (result.timedOut) {
        return { met: false, detail: `the exit command timed out after ${Math.round(COMMAND_TIMEOUT_MS / 60000)} minutes` }
      }
      if (result.exitCode === 0) {
        return { met: true, detail: `\`${this.loop.exit.command}\` exited 0` }
      }
      // Both streams, never one or the other: a build failure usually puts its
      // summary on stdout and the cause on stderr, and this text is what the
      // next iteration is told to act on.
      const combined = [result.stdout.trim(), result.stderr.trim()].filter(Boolean).join('\n')
      const tail = combined.split('\n').slice(-25).join('\n') || '(no output)'
      return {
        met: false,
        detail: `\`${this.loop.exit.command}\` exited ${result.exitCode}:\n${tail}`,
      }
    }

    // Review-based exit. The verifier is a different vendor from the worker
    // wherever the user allowed it, so the check does not share the worker's
    // blind spots.
    const verifier = this.registry.get(this.loop.verifier.vendor)
    const result = await verifier.run({
      systemPrompt:
        'You are an independent verifier. You did not do this work. Judge only whether the stated goal is genuinely met.',
      prompt: loopVerifyPrompt(
        this.loop.goal,
        this.loop.exit.criterion,
        workerReport,
        this.loop.repoPath,
      ),
      cfg: this.loop.verifier,
      // The verifier only ever reads, whatever the worker was allowed.
      capability: 'read',
      cwd: this.loop.repoPath,
      signal: this.gate.signal,
      timeoutMs: ITERATION_TIMEOUT_MS,
    })

    this.loop = this.repo.addLoopUsage(this.loop.id, result.usage)

    if (result.error) return { met: false, detail: `the verifier failed: ${result.error}` }

    const { data } = extractJson<Record<string, unknown>>(result.text)
    if (!data) {
      // An unparseable verdict is treated as "not met". Defaulting the other way
      // would let a malformed reply end the loop as a success.
      return { met: false, detail: 'the verifier did not return a usable judgement' }
    }
    return {
      met: data['met'] === true,
      detail: safeString(data['reason'], 1000) || (data['met'] === true ? 'the verifier judged the goal met' : 'not yet met'),
    }
  }

  private setStatus(status: Loop['status'], stopReason = ''): void {
    this.loop = { ...this.loop, status, stopReason }
    this.repo.setLoopStatus(this.loop.id, status, stopReason)
    this.emit({ type: 'loop.status', loopId: this.loop.id, status, stopReason })
  }
}
