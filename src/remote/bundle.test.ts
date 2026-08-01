import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { beforeAll, describe, expect, it } from 'vitest'
import { REMOTE_PROTOCOL_VERSION, type RemoteFrame } from '@shared/remote'
import { decodeFrame } from '@main/remote/frames'

/**
 * The bundle, run where Parley does not exist.
 *
 * This is the test the whole distribution decision rests on, and it is
 * deliberately not an assertion about esbuild's output. The bundle is copied
 * alone into a temporary directory with no node_modules above it and no source
 * tree anywhere, given a PATH containing only what a bare host would have, and
 * executed. That catches what inspecting the file cannot: an import esbuild
 * quietly left external, a dynamic require, a read of a path relative to the
 * checkout, an assumption that a package is installed. All of those work
 * perfectly on the machine that built them.
 */

const repoRoot = resolve(__dirname, '..', '..')
const built = join(repoRoot, 'out', 'remote', 'parley-remote.mjs')

let sandbox: string
let bundle: string
let fakeBin: string

beforeAll(() => {
  // Build from source rather than trusting whatever is lying in out/ — a stale
  // bundle would make every assertion below describe the wrong file.
  execFileSync(process.execPath, [join(repoRoot, 'scripts', 'build-remote.mjs')], {
    cwd: repoRoot,
    stdio: 'pipe',
  })

  sandbox = mkdtempSync(join(tmpdir(), 'parley-remote-sandbox-'))
  bundle = join(sandbox, 'parley-remote.mjs')
  copyFileSync(built, bundle)
  chmodSync(bundle, 0o755)

  fakeBin = join(sandbox, 'bin')
  mkdirSync(fakeBin)
}, 120_000)

/** An executable that is not a shell command — a real file with a shebang. */
function fakeExecutable(name: string, body: string): void {
  const path = join(fakeBin, name)
  writeFileSync(path, `#!/bin/sh\n${body}\n`, 'utf8')
  chmodSync(path, 0o755)
}

interface RunResult {
  frames: RemoteFrame[]
  ready: Extract<RemoteFrame['body'], { type: 'ready' }> | null
  stderr: string
  status: number | null
  unframed: string[]
}

function runBundle(
  request: Record<string, unknown>,
  env: Record<string, string> = {},
  home = sandbox,
): RunResult {
  const result = spawnSync(process.execPath, [bundle], {
    input: `${JSON.stringify(request)}\n`,
    encoding: 'utf8',
    // The sandbox, not the repo: nothing may resolve relative to the checkout.
    cwd: sandbox,
    timeout: 30_000,
    env: {
      PATH: `${fakeBin}:/usr/bin:/bin`,
      HOME: home,
      PARLEY_RUNS_ROOT: join(sandbox, 'runs'),
      ...env,
    },
  })

  const frames: RemoteFrame[] = []
  const unframed: string[] = []
  for (const line of (result.stdout ?? '').split('\n')) {
    if (!line.trim()) continue
    const frame = decodeFrame(line)
    if (frame) frames.push(frame)
    else unframed.push(line)
  }
  const readyFrame = frames.find((frame) => frame.body.type === 'ready')
  return {
    frames,
    ready: readyFrame ? (readyFrame.body as Extract<RemoteFrame['body'], { type: 'ready' }>) : null,
    stderr: result.stderr ?? '',
    status: result.status,
    unframed,
  }
}

describe('the bundle stands alone', () => {
  it('runs with no node_modules and no source tree, and speaks the protocol', () => {
    // If anything were left external, node would fail to resolve it here —
    // there is no node_modules above a temp directory.
    expect(existsSync(join(dirname(bundle), 'node_modules'))).toBe(false)

    const { ready, stderr, status, frames } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(stderr).toBe('')
    expect(status).toBe(0)
    expect(ready).not.toBeNull()
    // The announcement is first, and frames are sequenced from one.
    expect(frames[0]?.body.type).toBe('ready')
    expect(frames[0]?.sequence).toBe(1)
    expect(frames.every((frame) => frame.runId === 'run-1')).toBe(true)
  })

  it('writes nothing but frames to stdout', () => {
    const { unframed } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(unframed).toEqual([])
  })

  it('reports a build id that is the hash of its own bytes', () => {
    // The self-hash, not an embedded constant: embedding the hash would change
    // the file being hashed. This asserts the two agree in reality.
    const onDisk = createHash('sha256').update(readFileSync(bundle)).digest('hex')
    const { ready } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(ready?.capabilities.buildId).toBe(onDisk)

    const manifest = JSON.parse(
      readFileSync(join(repoRoot, 'out', 'remote', 'manifest.json'), 'utf8'),
    ) as { buildId: string }
    expect(manifest.buildId).toBe(onDisk)
  })

  it('changes its build id when its bytes change', () => {
    const tampered = join(sandbox, 'tampered.mjs')
    copyFileSync(bundle, tampered)
    writeFileSync(tampered, `${readFileSync(tampered, 'utf8')}\n// changed\n`, 'utf8')
    const result = spawnSync(process.execPath, [tampered], {
      input: `${JSON.stringify({ version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId: 'r' })}\n`,
      encoding: 'utf8',
      cwd: sandbox,
      timeout: 30_000,
      env: { PATH: `${fakeBin}:/usr/bin:/bin`, HOME: sandbox },
    })
    const frame = decodeFrame((result.stdout ?? '').split('\n')[0] ?? '')
    const body = frame?.body as Extract<RemoteFrame['body'], { type: 'ready' }> | undefined
    const original = createHash('sha256').update(readFileSync(bundle)).digest('hex')
    expect(body?.capabilities.buildId).not.toBe(original)
  })
})

describe('what it says about the host', () => {
  it('reports the PATH it was actually given', () => {
    // The single most valuable line in a support conversation: a
    // non-interactive ssh session does not read the shell startup files where
    // nvm, asdf and mise put their shims.
    const { ready } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(ready?.capabilities.path).toContain(fakeBin)
    expect(ready?.capabilities.nodeExecutable).toBe(process.execPath)
    expect(ready?.capabilities.user.length).toBeGreaterThan(0)
  })

  it('separates what the bundle supports from what the host can run', () => {
    fakeExecutable('codex', 'echo "codex-cli 0.145.0"')
    const { ready } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(ready?.capabilities.supportedVendors).toEqual(['claude', 'codex', 'agy'])
    expect(ready?.capabilities.availableVendors).toEqual(['codex'])
    expect(ready?.capabilities.vendorDetails.codex?.executable).toBe(join(fakeBin, 'codex'))
    expect(ready?.capabilities.vendorDetails.codex?.version).toBe('codex-cli 0.145.0')
    expect(ready?.capabilities.vendorDetails.claude?.executable).toBeNull()
  })

  it('does not hang when a CLI will not answer --version', () => {
    // A status command that never returns has failed at its only job.
    fakeExecutable('claude', 'sleep 30')
    const { ready, frames } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(ready?.capabilities.vendorDetails.claude?.executable).toBe(join(fakeBin, 'claude'))
    expect(ready?.capabilities.vendorDetails.claude?.version).toBeNull()
    // Still available — the run will find out whether it works. Refusing the
    // host over an unanswered --version would be stricter than warranted.
    expect(ready?.capabilities.availableVendors).toContain('claude')
    const warnings = frames.filter((frame) => frame.body.type === 'progress')
    expect(JSON.stringify(warnings)).toContain('--version')
  }, 30_000)

  it('finds a configured CLI’s config without claiming the subscription works', () => {
    fakeExecutable('codex', 'echo "codex-cli 0.145.0"')
    const home = mkdtempSync(join(tmpdir(), 'parley-remote-home-'))
    mkdirSync(join(home, '.codex'), { recursive: true })
    writeFileSync(join(home, '.codex', 'config.toml'), 'model = "gpt-5"\n')
    const { ready } = runBundle(
      { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId: 'run-1' },
      { HOME: home },
      home,
    )
    expect(ready?.capabilities.vendorDetails.codex?.configured).toBe(true)
    rmSync(home, { recursive: true, force: true })
  })
})

describe('the permission posture is surfaced, not buried', () => {
  function agyHome(settings: string | null): string {
    const home = mkdtempSync(join(tmpdir(), 'parley-remote-agy-'))
    if (settings !== null) {
      mkdirSync(join(home, '.gemini', 'antigravity-cli'), { recursive: true })
      writeFileSync(join(home, '.gemini', 'antigravity-cli', 'settings.json'), settings)
    }
    return home
  }

  it('reports a permissions.allow rule as a permissive host', () => {
    // A non-empty allow list means a headless run EXECUTES those tools without
    // asking. The adapter already fails such a turn closed, but a human
    // choosing a host should be told first, not learn it from a refusal.
    fakeExecutable('agy', 'echo "1.1.8"')
    const home = agyHome(JSON.stringify({ permissions: { allow: ['run_shell_command'] } }))
    const { ready } = runBundle(
      { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId: 'run-1' },
      { HOME: home },
      home,
    )
    expect(ready?.capabilities.vendorDetails.agy?.permissionMode).toBe('allow')
    rmSync(home, { recursive: true, force: true })
  })

  it('reads an empty allow list as asking', () => {
    fakeExecutable('agy', 'echo "1.1.8"')
    const home = agyHome(JSON.stringify({ permissions: { allow: [] } }))
    const { ready } = runBundle(
      { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId: 'run-1' },
      { HOME: home },
      home,
    )
    expect(ready?.capabilities.vendorDetails.agy?.permissionMode).toBe('ask')
    rmSync(home, { recursive: true, force: true })
  })

  it('treats unreadable settings as unknown, and warns', () => {
    // Not being able to tell is closer to permissive than to safe. Silence
    // would be the wrong default for a safety property.
    fakeExecutable('agy', 'echo "1.1.8"')
    const home = agyHome('{ not json')
    const { ready, frames } = runBundle(
      { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId: 'run-1' },
      { HOME: home },
      home,
    )
    expect(ready?.capabilities.vendorDetails.agy?.permissionMode).toBe('unknown')
    expect(JSON.stringify(frames)).toContain('permissive')
    rmSync(home, { recursive: true, force: true })
  })
})

describe('a run driven through the built bundle', () => {
  it('supervises a worker, frames its facts, and publishes a candidate', async () => {
    // The assembly test. Every part below has its own unit coverage; what this
    // proves is that the bundle wires them together — supervisor mode picks
    // worker mode out of the same file, the request reaches it on stdin, its
    // bodies come back as numbered frames, and a candidate lands in the mirror.
    const home = mkdtempSync(join(tmpdir(), 'parley-e2e-home-'))
    const source = mkdtempSync(join(tmpdir(), 'parley-e2e-src-'))
    const git = (cwd: string, ...args: string[]): string =>
      execFileSync('git', args, {
        cwd,
        encoding: 'utf8',
        env: {
          ...process.env,
          GIT_AUTHOR_NAME: 'T',
          GIT_AUTHOR_EMAIL: 't@e.com',
          GIT_COMMITTER_NAME: 'T',
          GIT_COMMITTER_EMAIL: 't@e.com',
        },
      }).trim()

    git(source, 'init', '-q', '-b', 'main')
    writeFileSync(join(source, 'seed.txt'), 'seed\n')
    git(source, 'add', '-A')
    git(source, 'commit', '-q', '-m', 'seed')
    const commit = git(source, 'rev-parse', 'HEAD')

    const runsRoot = join(home, 'runs')
    const mirror = join(runsRoot, 'mirrors', 'repo-key')
    mkdirSync(mirror, { recursive: true })
    git(mirror, 'init', '-q', '--bare')
    git(source, 'push', '-q', mirror, `${commit}:refs/parley/runs/e2e/input`)

    const request = {
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'run',
      runId: 'e2e',
      repository: { remote: 'repo-key', inputRef: 'refs/parley/runs/e2e/input', expectedCommit: commit },
      run: {
        plan: {
          id: 'p', sessionId: 's', kind: 'implementation', title: 'e2e', repoPath: source,
          planner: { vendor: 'claude', model: '', effort: 'high', persona: '' },
          executor: { vendor: 'codex', model: '', effort: 'high', persona: '' },
          reviewer: { vendor: 'claude', model: '', effort: 'high', persona: '' },
          status: 'ready', question: '', correctionNote: '', correctionDispositions: [],
          isolation: 'checkout', setupCommand: '', container: false,
          usage: { inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0, costUsd: 0 },
          mock: true, createdAt: 1,
        },
        milestone: {
          id: 'm', planId: 'p', index: 0, title: 'e2e milestone',
          intent: 'Something the mock adapter finishes.',
          expectedPaths: ['parley-mock-work.txt'], status: 'audited', auditNote: '',
          testCommand: 'node --version', testResult: null, mutations: [], mutationResults: [],
          reviewNote: '', reviewBlocking: [], reviewNotes: [], reviewPassed: null,
          adopted: false, approvalId: null, createdAt: 1, completedAt: null,
        },
      },
    }

    // spawn, not spawnSync — and stdin stays OPEN for the life of the run.
    // spawnSync closes it after writing, which the remote correctly reads as
    // the connection going away, so the run would cancel itself immediately.
    // The real client holds it open for exactly this reason; a test that did
    // not would be testing a different protocol.
    const frames = await new Promise<RemoteFrame[]>((resolve, reject) => {
      const child = spawn(process.execPath, [bundle], {
        cwd: sandbox,
        // node's own directory is on the PATH here, unlike the handshake
        // tests: the milestone's verification command has to actually run, and
        // a host that can start parley-remote necessarily has node available.
        env: {
          PATH: `${fakeBin}:${dirname(process.execPath)}:/usr/bin:/bin`,
          HOME: home,
          PARLEY_RUNS_ROOT: runsRoot,
        },
      })
      const collected: RemoteFrame[] = []
      let pending = ''
      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        reject(new Error('the run did not finish'))
      }, 150_000)
      child.stdout.setEncoding('utf8')
      child.stdout.on('data', (chunk: string) => {
        pending += chunk
        let at = pending.indexOf('\n')
        while (at >= 0) {
          const frame = decodeFrame(pending.slice(0, at))
          if (frame) collected.push(frame)
          pending = pending.slice(at + 1)
          at = pending.indexOf('\n')
        }
      })
      child.on('close', () => {
        clearTimeout(timer)
        resolve(collected)
      })
      child.stdin.write(`${JSON.stringify(request)}\n`)
    })

    // Every line was a frame, numbered from one without a gap: the supervisor
    // owns the sequence across its own frames and everything the worker sent.
    expect(frames.map((frame) => frame.sequence)).toEqual(
      frames.map((_, index) => index + 1),
    )
    expect(frames[0]?.body.type).toBe('ready')
    expect(frames.some((frame) => frame.body.type === 'fact')).toBe(true)

    const published = frames.find((frame) => frame.body.type === 'result')
    expect(published).toBeTruthy()
    const at = git(mirror, 'rev-parse', 'refs/parley/runs/e2e/candidate')
    expect(at.length).toBe(40)
    // It descends from exactly what was submitted.
    expect(() => git(mirror, 'merge-base', '--is-ancestor', commit, at)).not.toThrow()
    // And the worktree is gone: the supervisor cleaned up after the worker.
    expect(existsSync(join(runsRoot, 'e2e'))).toBe(false)

    rmSync(home, { recursive: true, force: true })
    rmSync(source, { recursive: true, force: true })
  }, 180_000)
})

describe('failures that have no in-band representation', () => {
  it('refuses a protocol mismatch on stderr, with no frames at all', () => {
    // If the versions disagree we cannot assume the far end would read our
    // frames either, so this cannot be said in-band.
    const { stderr, frames, status } = runBundle({
      version: 99,
      operation: 'handshake',
      runId: 'run-1',
    })
    expect(frames).toEqual([])
    expect(status).not.toBe(0)
    expect(stderr).toContain('protocol')
  })

  it('refuses input that is not a request', () => {
    const result = spawnSync(process.execPath, [bundle], {
      input: 'this is not json\n',
      encoding: 'utf8',
      cwd: sandbox,
      timeout: 30_000,
      env: { PATH: `${fakeBin}:/usr/bin:/bin`, HOME: sandbox },
    })
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain('JSON')
    expect(result.stdout).toBe('')
  })

  it('says plainly that it cannot do an operation it has not implemented', () => {
    // In-band, because the protocol IS alive by then — and honest, because a
    // helper that pretended to accept the work would fail somewhere less
    // legible.
    const { frames, status } = runBundle({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'run',
      runId: 'run-1',
    })
    expect(frames[0]?.body.type).toBe('ready')
    const error = frames.find((frame) => frame.body.type === 'error')
    expect(error).toBeTruthy()
    expect(JSON.stringify(error)).toContain('run')
    expect(status).not.toBe(0)
  })
})
