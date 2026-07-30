import { chmodSync, mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  containerExecArgv,
  containerUpArgv,
  devcontainerProbe,
  ensureUp,
  hasDevcontainerConfig,
  locateDevcontainer,
  runProjectCommand,
} from './containers'

/**
 * The shim is the contract, executable: a fake `devcontainer` that REFUSES
 * argv shapes the real CLI (0.87.0, probed live) would not serve — exec
 * without --workspace-folder or without the `--` separator exits 64 — and
 * otherwise behaves like the real one: `--version` prints a version, `up`
 * prints the JSON outcome line, `exec` runs the inner argv in the workspace
 * with its exit code flowing back unchanged. A regression in the arg
 * builders turns these tests red at the shim, the same place the real CLI
 * would break.
 */
function shimDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'parley-devc-shim-'))
  const shim = join(dir, 'devcontainer')
  writeFileSync(
    shim,
    `#!/bin/sh
cmd="$1"; shift
case "$cmd" in
  --version) echo "0.87.0-shim"; exit 0;;
  up)
    [ "$1" = "--workspace-folder" ] && [ -n "$2" ] || { echo "up: missing --workspace-folder" >&2; exit 64; }
    if [ -f "$(dirname "$0")/up-fail" ]; then echo "docker daemon unreachable" >&2; exit 1; fi
    echo '{"outcome":"success","containerId":"shim"}'; exit 0;;
  exec)
    [ "$1" = "--workspace-folder" ] && [ -n "$2" ] || { echo "exec: missing --workspace-folder" >&2; exit 64; }
    ws="$2"; shift 2
    [ "$1" = "--" ] || { echo "exec: missing -- separator" >&2; exit 64; }
    shift
    cd "$ws" && exec "$@";;
  *) echo "unknown subcommand: $cmd" >&2; exit 64;;
esac
`,
  )
  chmodSync(shim, 0o755)
  return dir
}

const dirs: string[] = []
function tmp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}
afterAll(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true })
})

describe('argv builders', () => {
  it('wraps the inner argv verbatim behind the -- separator', () => {
    const argv = containerExecArgv(['npm', 'test', '--', '--grep', 'a b'], '/ws')
    expect(argv).toEqual([
      'exec',
      '--workspace-folder',
      '/ws',
      '--',
      'npm',
      'test',
      '--',
      '--grep',
      'a b',
    ])
    expect(containerUpArgv('/ws')).toEqual(['up', '--workspace-folder', '/ws'])
  })

  it('finds either documented config location and nothing else', () => {
    const nested = tmp('parley-devc-config-')
    mkdirSync(join(nested, '.devcontainer'))
    writeFileSync(join(nested, '.devcontainer', 'devcontainer.json'), '{}')
    expect(hasDevcontainerConfig(nested)).toBe(true)

    const flat = tmp('parley-devc-config-')
    writeFileSync(join(flat, '.devcontainer.json'), '{}')
    expect(hasDevcontainerConfig(flat)).toBe(true)

    expect(hasDevcontainerConfig(tmp('parley-devc-config-'))).toBe(false)
  })
})

describe('runProjectCommand', () => {
  it('runs directly on the host when the container choice is off', async () => {
    const cwd = tmp('parley-devc-host-')
    const ok = await runProjectCommand(['node', '-e', 'process.exit(0)'], cwd, {
      container: false,
    })
    expect(ok.exitCode).toBe(0)

    const failing = await runProjectCommand(['node', '-e', 'process.exit(3)'], cwd, {
      container: false,
    })
    expect(failing.exitCode).toBe(3)
  })

  it('routes through the shim container, cwd and exit code intact', async () => {
    const shim = join(shimDir(), 'devcontainer')
    const ws = realpathSync(tmp('parley-devc-ws-'))

    const run = await runProjectCommand(
      ['node', '-e', 'console.log(process.cwd())'],
      ws,
      { container: true, binary: shim },
    )
    expect(run.exitCode).toBe(0)
    expect(run.stdout.trim()).toBe(ws)

    const failing = await runProjectCommand(['sh', '-c', 'exit 3'], ws, {
      container: true,
      binary: shim,
    })
    expect(failing.exitCode).toBe(3)
  })

  it('sees a host-side file edit through the workspace, as mutation testing must', async () => {
    const shim = join(shimDir(), 'devcontainer')
    const ws = realpathSync(tmp('parley-devc-mutate-'))
    writeFileSync(join(ws, 'mutated.txt'), 'host-truth')

    const run = await runProjectCommand(['cat', 'mutated.txt'], ws, {
      container: true,
      binary: shim,
    })
    expect(run.exitCode).toBe(0)
    expect(run.stdout.trim()).toBe('host-truth')
  })

  it('fails closed with a PATH hint when the CLI is missing', async () => {
    const run = await runProjectCommand(['node', '-e', ''], tmp('parley-devc-miss-'), {
      container: true,
      binary: 'parley-definitely-missing-devcontainer',
    })
    expect(run.exitCode).toBe(-1)
    expect(run.stderr).toContain('not found on PATH')
    expect(run.stderr).toContain('@devcontainers/cli')
  })

  it('reports an empty argv rather than spawning nothing', async () => {
    const run = await runProjectCommand([], tmpdir(), { container: false })
    expect(run.exitCode).toBe(-1)
    expect(run.stderr).toContain('no command')
  })

  it('honours the timeout by cutting the host-side client', async () => {
    const shim = join(shimDir(), 'devcontainer')
    const run = await runProjectCommand(['sleep', '30'], realpathSync(tmp('parley-devc-slow-')), {
      container: true,
      binary: shim,
      timeoutMs: 300,
    })
    expect(run.timedOut).toBe(true)
    expect(run.exitCode).not.toBe(0)
  }, 15_000)
})

describe('ensureUp', () => {
  it('reports the outcome line on success and stderr on failure', async () => {
    const dir = shimDir()
    const shim = join(dir, 'devcontainer')
    const ws = realpathSync(tmp('parley-devc-up-'))

    const ok = await ensureUp(ws, { binary: shim })
    expect(ok.exitCode).toBe(0)
    expect(ok.stdout).toContain('"outcome":"success"')

    writeFileSync(join(dir, 'up-fail'), '')
    const failed = await ensureUp(ws, { binary: shim })
    expect(failed.exitCode).toBe(1)
    expect(failed.stderr).toContain('docker daemon unreachable')
  })

  it('fails closed when the CLI is missing', async () => {
    const failed = await ensureUp(tmpdir(), {
      binary: 'parley-definitely-missing-devcontainer',
    })
    expect(failed.exitCode).toBe(-1)
    expect(failed.stderr).toContain('not found on PATH')
  })
})

describe('devcontainerProbe', () => {
  it('reports version and location when the CLI answers', async () => {
    const shim = join(shimDir(), 'devcontainer')
    const health = await devcontainerProbe(shim)
    expect(health.present).toBe(true)
    expect(health.version).toBe('0.87.0-shim')
    expect(health.detail).toBe(shim)
  })

  it('explains absence with the install and PATH hints', async () => {
    const health = await devcontainerProbe('parley-definitely-missing-devcontainer')
    expect(health.present).toBe(false)
    expect(health.version).toBe('')
    expect(health.detail).toContain('@devcontainers/cli')
    expect(health.detail).toContain('shell PATH')
    expect(locateDevcontainer('parley-definitely-missing-devcontainer')).toBeNull()
  })
})
