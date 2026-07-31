import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { AppEvent } from '@shared/events'
import type { Id, Workspace } from '@shared/domain'
import { capture, type CaptureResult } from '@main/util/spawn'
import type { Repo } from '@main/store/repo'
import { renderTemplate, type ProjectTemplate } from './templates'

/**
 * Creating a new project.
 *
 * The order is the point: scaffold, commit, install, and then **prove the
 * harness green before the workspace is recorded ready**. A project whose
 * tests could never have run is the environmental-failure class that eats an
 * agent's hour and produces a milestone nobody can honestly review; here it
 * is designed out rather than remediated, because the one thing a fresh
 * project must guarantee is that `npm run verify` means something.
 *
 * Nothing here is an agent. Every file written is deterministic template
 * content, every command is fixed argv from the template, and the whole
 * thing runs on one recorded `workspace.create` approval.
 */

const INSTALL_TIMEOUT_MS = 15 * 60 * 1000
const VERIFY_TIMEOUT_MS = 10 * 60 * 1000
const GIT_TIMEOUT_MS = 60_000

export interface WorkspaceBuildDeps {
  repo: Repo
  emit: (event: AppEvent) => void
  /**
   * Injected so tests can prove the whole order without a real `npm install`
   * — the `runSelfGate` precedent. Production passes `capture`.
   */
  run?: (
    command: string,
    args: string[],
    cwd: string,
    timeoutMs: number,
    signal?: AbortSignal,
  ) => Promise<CaptureResult>
  signal?: AbortSignal
}

function tail(text: string, limit = 800): string {
  const trimmed = text.trim()
  return trimmed.length > limit ? `…${trimmed.slice(-limit)}` : trimmed
}

/**
 * Writes the template into `root`, returning the top-level entries created.
 *
 * Only ever called against a path the validator already proved absent or
 * empty, so every entry here is one this build made — which is what makes
 * the unwind safe.
 */
export function writeTemplate(
  root: string,
  template: ProjectTemplate,
  projectName: string,
): string[] {
  const files = renderTemplate(template, projectName)
  const created = new Set<string>()
  for (const [relative, contents] of Object.entries(files)) {
    const target = join(root, relative)
    mkdirSync(dirname(target), { recursive: true })
    writeFileSync(target, contents, 'utf8')
    created.add(relative.split('/')[0] ?? relative)
  }
  return [...created]
}

/**
 * Removes what this build made, and only that.
 *
 * `createdRoot` distinguishes the two legal starting states: a directory
 * Parley made (remove it entirely) from an empty one the user made in the
 * picker (keep the folder they chose, empty it of our work).
 */
export function unwindWorkspace(root: string, createdRoot: boolean): void {
  try {
    if (createdRoot) {
      rmSync(root, { recursive: true, force: true })
      return
    }
    if (!existsSync(root)) return
    for (const entry of readdirSync(root)) {
      rmSync(join(root, entry), { recursive: true, force: true })
    }
  } catch {
    // A partially-removed directory is still better than a half-made project
    // wearing a ready badge; the failure detail names the path either way.
  }
}

/**
 * Builds one workspace to its ending and returns the settled record.
 *
 * Never throws: every exit is a recorded state, the same discipline the
 * envelope driver uses, and for the same reason — a row stuck at `building`
 * would be a project the app believes in and the disk does not.
 */
export async function buildWorkspace(
  deps: WorkspaceBuildDeps,
  workspaceId: Id,
  template: ProjectTemplate,
): Promise<Workspace | null> {
  const run = deps.run ?? capture
  const workspace = deps.repo.getWorkspace(workspaceId)
  if (!workspace || workspace.state !== 'building') return workspace ?? null

  const root = workspace.repoPath
  const createdRoot = !existsSync(root)

  const settle = (state: 'ready' | 'failed', detail: string): Workspace | null => {
    deps.repo.settleWorkspace(workspaceId, state, detail)
    const settled = deps.repo.getWorkspace(workspaceId)
    if (settled) deps.emit({ type: 'workspace.changed', workspace: settled })
    return settled
  }

  const fail = (detail: string): Workspace | null => {
    unwindWorkspace(root, createdRoot)
    return settle('failed', detail)
  }

  try {
    mkdirSync(root, { recursive: true })
    writeTemplate(root, template, workspace.name)

    // Committed BEFORE install so the first commit is the project, not its
    // dependency tree — .gitignore is part of the template for exactly this.
    const init = await run('git', ['init', '-q', '-b', 'main'], root, GIT_TIMEOUT_MS, deps.signal)
    if (init.exitCode !== 0) {
      return fail(`git init failed: ${tail(`${init.stderr}\n${init.stdout}`)}`)
    }
    const add = await run('git', ['add', '-A'], root, GIT_TIMEOUT_MS, deps.signal)
    if (add.exitCode !== 0) {
      return fail(`git add failed: ${tail(`${add.stderr}\n${add.stdout}`)}`)
    }
    // Explicit identity: a machine with no global git config must still be
    // able to make this commit. The worktree committer does the same.
    const commit = await run(
      'git',
      [
        '-c',
        'user.name=Parley',
        '-c',
        'user.email=parley@local',
        'commit',
        '-m',
        `Scaffold ${workspace.name} from the ${template.name} template`,
      ],
      root,
      GIT_TIMEOUT_MS,
      deps.signal,
    )
    if (commit.exitCode !== 0) {
      return fail(`the first commit failed: ${tail(`${commit.stderr}\n${commit.stdout}`)}`)
    }

    const [installFile, ...installArgs] = template.installCommand
    if (!installFile) return fail('the template has no install command')
    const install = await run(installFile, installArgs, root, INSTALL_TIMEOUT_MS, deps.signal)
    if (install.exitCode !== 0) {
      return fail(
        `\`${template.installCommand.join(' ')}\` failed${install.timedOut ? ' (timed out)' : ''}: ${tail(`${install.stderr}\n${install.stdout}`)}`,
      )
    }

    const [verifyFile, ...verifyArgs] = template.verifyCommand
    if (!verifyFile) return fail('the template has no verification command')
    const verify = await run(verifyFile, verifyArgs, root, VERIFY_TIMEOUT_MS, deps.signal)
    if (verify.exitCode !== 0) {
      // The whole point of the series: an unproven harness never becomes
      // milestone 1's problem.
      return fail(
        `the project was scaffolded, but \`${template.verifyCommand.join(' ')}\` did not pass${verify.timedOut ? ' (timed out)' : ''}, so it is not safe ground yet: ${tail(`${verify.stderr}\n${verify.stdout}`)}`,
      )
    }

    return settle(
      'ready',
      `\`${template.verifyCommand.join(' ')}\` passed on the first commit — the harness is proven, and a plan here can be verified from milestone one.`,
    )
  } catch (err) {
    return fail(
      `creating the project failed: ${err instanceof Error ? err.message : String(err)}`,
    )
  }
}
