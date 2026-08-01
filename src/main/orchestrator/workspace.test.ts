import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { AppEvent } from '@shared/events'
import type { CaptureResult } from '@main/util/spawn'
import { openDatabase } from '@main/store/db'
import { newId, Repo } from '@main/store/repo'
import { templateById, type ProjectTemplate } from './templates'
import { buildWorkspace, unwindWorkspace, writeTemplate } from './workspace'

const WEB_APP = templateById('web-app')!

function freshRepo(): Repo {
  return new Repo(openDatabase(':memory:'))
}

function seed(repo: Repo, root: string) {
  return repo.createWorkspace({
    id: newId(),
    repoPath: root,
    name: 'New App',
    templateId: 'web-app',
    state: 'building',
    detail: '',
    createdAt: Date.now(),
    readyAt: null,
    mock: false,
  })
}

const ok = (): CaptureResult => ({
  exitCode: 0,
  signal: null,
  startError: null,
  stdout: '',
  stderr: '',
  durationMs: 1,
  timedOut: false,
})

/**
 * A runner that runs git for real (cheap, and the commit is load-bearing)
 * while standing in for install and verify, whose outcomes each test sets.
 * The `runSelfGate` injection precedent — the order under test is the whole
 * point, and a real `npm install` would make that untestable.
 */
function runner(outcomes: { install?: Partial<CaptureResult>; verify?: Partial<CaptureResult> } = {}) {
  const calls: string[] = []
  const run = async (
    command: string,
    args: string[],
    cwd: string,
  ): Promise<CaptureResult> => {
    calls.push([command, ...args].join(' '))
    if (command === 'git') {
      try {
        const stdout = execFileSync(command, args, { cwd, encoding: 'utf8', stdio: 'pipe' })
        return { ...ok(), stdout }
      } catch (err) {
        return { ...ok(), exitCode: 1, stderr: err instanceof Error ? err.message : String(err) }
      }
    }
    const key = args.includes('verify') ? 'verify' : 'install'
    return { ...ok(), ...(outcomes[key] ?? {}) }
  }
  return { run, calls }
}

describe('writing a template', () => {
  it('creates nested files and reports the top-level entries it made', () => {
    const root = mkdtempSync(join(tmpdir(), 'parley-ws-write-'))
    const created = writeTemplate(root, WEB_APP, 'My App')
    expect(created.sort()).toEqual(
      ['.gitignore', 'README.md', 'index.html', 'package.json', 'src', 'tsconfig.json'].sort(),
    )
    expect(existsSync(join(root, 'src', 'greeting.test.ts'))).toBe(true)
    expect(readFileSync(join(root, 'package.json'), 'utf8')).toContain('"name": "my-app"')
  })
})

describe('unwinding', () => {
  it('removes a directory Parley made, and only empties one the user made', () => {
    const parent = mkdtempSync(join(tmpdir(), 'parley-ws-unwind-'))
    const ours = join(parent, 'ours')
    mkdirSync(ours)
    writeFileSync(join(ours, 'file.txt'), 'x')
    unwindWorkspace(ours, true)
    expect(existsSync(ours)).toBe(false)

    const theirs = join(parent, 'theirs')
    mkdirSync(theirs)
    writeFileSync(join(theirs, 'file.txt'), 'x')
    unwindWorkspace(theirs, false)
    // The folder they chose survives; our work inside it does not.
    expect(existsSync(theirs)).toBe(true)
    expect(readdirSync(theirs)).toEqual([])
  })
})

describe('building a workspace', () => {
  it('scaffolds, commits, installs, verifies — and only then is it ready', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-build-')), 'new-app')
    const workspace = seed(repo, root)
    const events: AppEvent[] = []
    const { run, calls } = runner()

    const settled = await buildWorkspace(
      { repo, emit: (event) => events.push(event), run },
      workspace.id,
      WEB_APP,
    )

    expect(settled?.state).toBe('ready')
    expect(settled?.detail).toMatch(/npm run verify` passed/)
    expect(settled?.readyAt).not.toBeNull()

    // The order is the contract: commit before install, verify last.
    expect(calls[0]).toContain('git init')
    expect(calls.findIndex((c) => c.startsWith('git commit') || c.includes('commit -m'))).toBeLessThan(
      calls.findIndex((c) => c === 'npm install'),
    )
    expect(calls.at(-1)).toBe('npm run verify')

    // The first commit is the project, not its dependency tree.
    const tracked = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
    expect(tracked).toContain('package.json')
    expect(tracked).toContain('src/greeting.test.ts')
    expect(tracked).not.toContain('node_modules')
    expect(events.filter((e) => e.type === 'workspace.changed')).toHaveLength(1)
  })

  it('refuses to call a project ready when its harness is red, and leaves nothing behind', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-red-')), 'doomed')
    const workspace = seed(repo, root)
    const { run } = runner({ verify: { exitCode: 1, stdout: '1 test failed' } })

    const settled = await buildWorkspace({ repo, emit: () => {}, run }, workspace.id, WEB_APP)

    expect(settled?.state).toBe('failed')
    // The message has to say what this series exists for.
    expect(settled?.detail).toMatch(/not safe ground yet/)
    expect(settled?.detail).toContain('1 test failed')
    // Parley made the directory, so unwinding removes it entirely.
    expect(existsSync(root)).toBe(false)
  })

  it('fails on a broken install without pretending the project exists', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-install-')), 'app')
    const workspace = seed(repo, root)
    const { run } = runner({ install: { exitCode: 1, stderr: 'ENOTFOUND registry' } })

    const settled = await buildWorkspace({ repo, emit: () => {}, run }, workspace.id, WEB_APP)
    expect(settled?.state).toBe('failed')
    expect(settled?.detail).toContain('npm install')
    expect(settled?.detail).toContain('ENOTFOUND')
    expect(existsSync(root)).toBe(false)
  })

  it('keeps a folder the user chose, emptied, when the build fails inside it', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-keep-')), 'chosen')
    mkdirSync(root) // as the folder picker's "New Folder" would leave it
    const workspace = seed(repo, root)
    const { run } = runner({ verify: { exitCode: 1 } })

    await buildWorkspace({ repo, emit: () => {}, run }, workspace.id, WEB_APP)
    expect(existsSync(root)).toBe(true)
    expect(readdirSync(root)).toEqual([])
  })

  it('never throws, and settles a workspace exactly once', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-once-')), 'app')
    const workspace = seed(repo, root)
    const broken: ProjectTemplate = { ...WEB_APP, installCommand: [] }

    const settled = await buildWorkspace({ repo, emit: () => {}, run: runner().run }, workspace.id, broken)
    expect(settled?.state).toBe('failed')
    expect(settled?.detail).toMatch(/no install command/)
    // A settled row cannot be re-settled by a late reconcile.
    expect(repo.settleWorkspace(workspace.id, 'ready', 'late')).toBe(false)
  })

  /**
   * Operator-run: PARLEY_LIVE_TEMPLATE=1 npx vitest run <this file>.
   *
   * The shipped template names real dependency versions and a real toolchain.
   * Only a real install proves those resolve and that the starting test
   * genuinely passes — everything above stands in for install and verify, so
   * without this arm the template's central promise would be untested.
   */
  it.skipIf(process.env['PARLEY_LIVE_TEMPLATE'] !== '1')(
    'installs and verifies for real, on the template as shipped',
    async () => {
      const repo = freshRepo()
      const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-real-')), 'real-app')
      const workspace = seed(repo, root)

      const settled = await buildWorkspace({ repo, emit: () => {} }, workspace.id, WEB_APP)

      expect(settled?.state).toBe('ready')
      expect(existsSync(join(root, 'node_modules'))).toBe(true)
      const tracked = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
      expect(tracked).not.toContain('node_modules')
    },
    600_000,
  )

  it('declines to build a workspace that is no longer building', async () => {
    const repo = freshRepo()
    const root = join(mkdtempSync(join(tmpdir(), 'parley-ws-settled-')), 'app')
    const workspace = seed(repo, root)
    repo.settleWorkspace(workspace.id, 'failed', 'already dealt with')
    const { run, calls } = runner()

    await buildWorkspace({ repo, emit: () => {}, run }, workspace.id, WEB_APP)
    expect(calls).toEqual([])
    expect(existsSync(root)).toBe(false)
  })
})
