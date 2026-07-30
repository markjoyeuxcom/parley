import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import { emptyUsage, type Milestone, type Session, type WorkPlan } from '@shared/domain'
import { AgentRegistry } from '@main/agents'
import type { MockAdapter } from '@main/agents/mock'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { Pipeline } from './pipeline'
import { worktreeBranch } from './worktrees'

const claude = { vendor: 'claude' as const, model: '', effort: 'high' as const, persona: '' }
const codex = { vendor: 'codex' as const, model: '', effort: 'high' as const, persona: '' }

function harness(devcontainerBinary?: string): {
  pipeline: Pipeline
  repo: Repo
  registry: AgentRegistry
  events: AppEvent[]
  session: Session
  worktreesRoot: string
} {
  const repo = new Repo(openDatabase(':memory:'))
  const registry = new AgentRegistry(true)
  const events: AppEvent[] = []
  const worktreesRoot = mkdtempSync(join(tmpdir(), 'parley-wtroot-'))
  const pipeline = new Pipeline({
    repo,
    registry,
    emit: (event) => events.push(event),
    worktreesRoot,
    devcontainerBinary,
  })
  const session = repo.createSession({
    id: newId(),
    kind: 'debate',
    status: 'complete',
    matter: 'Should milestones execute in isolation?',
    project: '',
    repoPath: null,
    participants: [claude, codex],
    maxTurns: 2,
    mock: true,
    createdAt: Date.now(),
  })
  return { pipeline, repo, registry, events, session, worktreesRoot }
}

function gitRepo(prefix: string): string {
  const repoPath = mkdtempSync(join(tmpdir(), prefix))
  const git = (...args: string[]): void => {
    execFileSync('git', args, { cwd: repoPath, stdio: 'ignore' })
  }
  git('init', '-q')
  git('config', 'user.email', 'test@example.invalid')
  git('config', 'user.name', 'Parley Test')
  writeFileSync(join(repoPath, 'seed.txt'), 'seed\n')
  git('add', '.')
  git('commit', '-qm', 'seed')
  return repoPath
}

function gitOut(cwd: string, ...args: string[]): string {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
}

function makeWorktreePlan(
  repo: Repo,
  sessionId: string,
  repoPath: string,
  overrides: Partial<WorkPlan> = {},
): WorkPlan {
  return repo.createPlan({
    id: newId(),
    sessionId,
    kind: 'implementation',
    title: 'Isolated execution',
    repoPath,
    planner: claude,
    executor: codex,
    reviewer: claude,
    status: 'ready',
    question: '',
    correctionNote: '',
    correctionDispositions: [],
    isolation: 'worktree',
    setupCommand: '',
    container: false,
    usage: emptyUsage(),
    mock: true,
    createdAt: Date.now(),
    ...overrides,
  })
}

function makeMilestone(
  repo: Repo,
  planId: string,
  index: number,
  overrides: Partial<Milestone> = {},
): Milestone {
  return repo.createMilestone({
    id: newId(),
    planId,
    index,
    title: `Milestone ${index + 1}`,
    intent: 'Write the mock work file.',
    expectedPaths: ['parley-mock-work.txt'],
    status: 'audited',
    auditNote: '',
    // A real command that exits 0: adoption refuses a milestone with no
    // verification command at the verdict, deliberately.
    testCommand: 'true',
    testResult: null,
    mutations: [],
    mutationResults: [],
    reviewNote: '',
    reviewBlocking: [],
    reviewNotes: [],
    reviewPassed: null,
    adopted: false,
    approvalId: null,
    createdAt: Date.now(),
    completedAt: null,
    ...overrides,
  })
}

/**
 * A fake devcontainer CLI that logs every routed call and refuses argv shapes
 * the real 0.87.0 would not serve, then runs the inner command for real — so
 * routed verifications produce true exit codes and the log proves the route.
 */
function devcontainerShim(): { binary: string; log: string; failUp: () => void } {
  const dir = mkdtempSync(join(tmpdir(), 'parley-devc-route-'))
  const binary = join(dir, 'devcontainer')
  writeFileSync(
    binary,
    `#!/bin/sh
log="$(dirname "$0")/log"
cmd="$1"; shift
case "$cmd" in
  up)
    [ "$1" = "--workspace-folder" ] && [ -n "$2" ] || exit 64
    echo "up $2" >> "$log"
    if [ -f "$(dirname "$0")/up-fail" ]; then echo "docker daemon unreachable" >&2; exit 1; fi
    echo '{"outcome":"success"}'; exit 0;;
  exec)
    [ "$1" = "--workspace-folder" ] && [ -n "$2" ] || exit 64
    ws="$2"; shift 2
    [ "$1" = "--" ] || exit 64
    shift
    echo "exec $ws $*" >> "$log"
    cd "$ws" && exec "$@";;
  *) exit 64;;
esac
`,
  )
  chmodSync(binary, 0o755)
  return {
    binary,
    log: join(dir, 'log'),
    failUp: () => writeFileSync(join(dir, 'up-fail'), ''),
  }
}

describe('worktree execution', () => {
  it('executes and commits in the worktree, adopts there too, and never touches the origin', async () => {
    const { pipeline, repo, registry, session } = harness()
    const origin = gitRepo('parley-wtexec-')
    const baseHead = gitOut(origin, 'rev-parse', 'HEAD')

    // Pre-existing dirt in the origin: a worktree plan must neither see it,
    // commit it, nor disturb it.
    writeFileSync(join(origin, 'dirt.txt'), 'uncommitted user work\n')

    const plan = makeWorktreePlan(repo, session.id, origin)
    const first = makeMilestone(repo, plan.id, 0)
    const second = makeMilestone(repo, plan.id, 1)

    // ── Milestone 1: executed. Mock round 1 writes NEEDS_WORK (reviewer
    // objects), round 2 writes RESOLVED (reviewer passes).
    const approval = repo.grantApproval('milestone.execute', first.id, 'test approval')
    const executed = await pipeline.runMilestone(first.id, approval.id)
    expect(executed.status).toBe('complete')

    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree registry row')
    expect(worktree.branch).toBe(worktreeBranch(plan))
    expect(worktree.baseCommit).toBe(baseHead)

    // Every write-capable agent run happened in the worktree, never the origin.
    const executorRuns = (registry.get('codex') as MockAdapter).requests
    expect(executorRuns.length).toBeGreaterThan(0)
    for (const run of executorRuns.filter((r) => r.capability === 'write')) {
      expect(run.cwd).toBe(worktree.path)
    }

    // Parley committed the milestone on the plan branch; the origin is exactly
    // as the user left it — same HEAD, dirt still uncommitted, no mock file.
    expect(gitOut(worktree.path, 'rev-list', '--count', 'HEAD')).toBe('2')
    expect(gitOut(worktree.path, 'log', '-1', '--format=%an')).toBe('Parley')
    expect(readFileSync(join(worktree.path, 'parley-mock-work.txt'), 'utf8')).toBe('RESOLVED\n')
    expect(executed.reviewNote).toMatch(/Committed in the worktree as [0-9a-f]{10}/)
    expect(gitOut(origin, 'rev-parse', 'HEAD')).toBe(baseHead)
    expect(gitOut(origin, 'status', '--porcelain')).toBe('?? dirt.txt')
    expect(existsSync(join(origin, 'parley-mock-work.txt'))).toBe(false)
    expect(existsSync(join(worktree.path, 'dirt.txt'))).toBe(false)

    // ── Milestone 2: adopted. Interrupted-run leftovers live in the worktree;
    // adoption verifies them there and must commit them there too.
    writeFileSync(join(worktree.path, 'parley-mock-work.txt'), 'MILESTONE_2\n')
    const adopted = await pipeline.adoptMilestone(second.id)
    expect(adopted.status).toBe('complete')
    expect(adopted.adopted).toBe(true)
    expect(adopted.reviewNote).toMatch(/Committed in the worktree as [0-9a-f]{10}/)

    expect(gitOut(worktree.path, 'rev-list', '--count', 'HEAD')).toBe('3')
    // Each milestone is its own commit touching only its work — the adoption
    // commit does not re-carry milestone 1.
    expect(gitOut(worktree.path, 'show', '--name-only', '--format=', 'HEAD')).toBe(
      'parley-mock-work.txt',
    )
    expect(gitOut(worktree.path, 'log', '-1', '--format=%s')).toMatch(/adopted/)
    expect(gitOut(worktree.path, 'status', '--porcelain')).toBe('')
    expect(gitOut(origin, 'rev-parse', 'HEAD')).toBe(baseHead)
    expect(repo.getPlan(plan.id)?.status).toBe('complete')
    expect(repo.getWorktreeForPlan(plan.id)?.landedAt).toBeNull()
  })

  it('a failing setup command refuses the run before the approval is spent', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-wtsetup-')
    const plan = makeWorktreePlan(repo, session.id, origin, { setupCommand: 'false' })
    const milestone = makeMilestone(repo, plan.id, 0)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test approval')

    await expect(pipeline.runMilestone(milestone.id, approval.id)).rejects.toThrow(/setup command failed/)

    // Nothing was spent and nothing half-made survives: the approval is live
    // for the retry, and the registry holds no row for a worktree that never
    // finished setting up.
    const stored = repo.listApprovals().find((a) => a.id === approval.id)
    expect(stored?.consumedAt).toBeNull()
    expect(repo.getWorktreeForPlan(plan.id)).toBeNull()
    expect(repo.getMilestone(milestone.id)?.status).toBe('audited')
  })

  it('a sick worktree refuses the run fail-closed, leaving the approval unspent', async () => {
    const { pipeline, repo, session } = harness()
    const origin = gitRepo('parley-wtsick-')
    const plan = makeWorktreePlan(repo, session.id, origin)
    const first = makeMilestone(repo, plan.id, 0)
    const second = makeMilestone(repo, plan.id, 1)

    const approval = repo.grantApproval('milestone.execute', first.id, 'test approval')
    await pipeline.runMilestone(first.id, approval.id)
    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')

    // Replace the worktree with a plain directory: it exists but is not a git
    // worktree, which is exactly the shape readTree would fail OPEN on.
    rmSync(worktree.path, { recursive: true, force: true })
    mkdirSync(worktree.path, { recursive: true })

    const approval2 = repo.grantApproval('milestone.execute', second.id, 'test approval')
    await expect(pipeline.runMilestone(second.id, approval2.id)).rejects.toThrow(/unhealthy|not a git worktree/)

    // The refusal happened before consumption: the approval survives for the
    // retry after the human repairs or prunes the worktree.
    const stored = repo.listApprovals().find((a) => a.id === approval2.id)
    expect(stored?.consumedAt).toBeNull()
    expect(repo.getMilestone(second.id)?.status).toBe('audited')
  })
})

describe('dev-container routing', () => {
  it('a container plan brings the worktree container up and verifies through it', async () => {
    const shim = devcontainerShim()
    const { pipeline, repo, session } = harness(shim.binary)
    const origin = gitRepo('parley-wtdevc-')

    const plan = makeWorktreePlan(repo, session.id, origin, { container: true })
    const milestone = makeMilestone(repo, plan.id, 0)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test approval')

    const executed = await pipeline.runMilestone(milestone.id, approval.id)
    expect(executed.status).toBe('complete')
    expect(executed.testResult?.exitCode).toBe(0)

    const worktree = repo.getWorktreeForPlan(plan.id)
    if (!worktree) throw new Error('expected a worktree')
    const log = readFileSync(shim.log, 'utf8')
    // The container came up for the worktree — never the origin — and the
    // milestone's own command ran through exec in that same workspace.
    expect(log).toContain(`up ${worktree.path}`)
    expect(log).toContain(`exec ${worktree.path} true`)
    expect(log).not.toContain(origin)
  })

  it('a container that will not start refuses the run with nothing half-made', async () => {
    const shim = devcontainerShim()
    shim.failUp()
    const { pipeline, repo, session } = harness(shim.binary)
    const origin = gitRepo('parley-wtdevcfail-')

    const plan = makeWorktreePlan(repo, session.id, origin, { container: true })
    const milestone = makeMilestone(repo, plan.id, 0)
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test approval')

    await expect(pipeline.runMilestone(milestone.id, approval.id)).rejects.toThrow(
      /dev container failed to start/,
    )
    // Same contract as a failing setup command: the worktree is unwound and
    // the approval survives for the retry after the daemon is fixed.
    expect(repo.getWorktreeForPlan(plan.id)).toBeNull()
    const stored = repo.listApprovals().find((a) => a.id === approval.id)
    expect(stored?.consumedAt).toBeNull()
  })

  it('a mutation applied on the host is caught by the suite running through the container', async () => {
    const shim = devcontainerShim()
    const { pipeline, repo, session } = harness(shim.binary)
    const origin = gitRepo('parley-wtdevcmut-')
    writeFileSync(join(origin, 'guard.txt'), 'sentinel-A\n')
    execFileSync('git', ['add', '.'], { cwd: origin, stdio: 'ignore' })
    execFileSync('git', ['commit', '-qm', 'guard'], { cwd: origin, stdio: 'ignore' })

    const plan = makeWorktreePlan(repo, session.id, origin, { container: true })
    const milestone = makeMilestone(repo, plan.id, 0, {
      testCommand: 'grep -q sentinel-A guard.txt',
      mutations: [
        {
          file: 'guard.txt',
          find: 'sentinel-A',
          replace: 'sentinel-B',
          describes: 'flips the guard the suite exists to pin',
        },
      ],
    })
    const approval = repo.grantApproval('milestone.execute', milestone.id, 'test approval')

    const executed = await pipeline.runMilestone(milestone.id, approval.id)
    expect(executed.status).toBe('complete')
    // The mutation stage edits the file on the HOST; the verification ran
    // inside the (shimmed) container and still saw the break — the plumbing
    // the real bind mount depends on, proven end to end.
    expect(executed.mutationResults).toEqual([
      expect.objectContaining({ file: 'guard.txt', caught: true }),
    ])
  })
})
