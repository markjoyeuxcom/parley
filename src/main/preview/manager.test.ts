import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import type { Preview } from '@shared/domain'
import { detectUrl, PreviewError, PreviewManager } from './manager'

function repoDir(prefix = 'parley-preview-'): string {
  return mkdtempSync(join(tmpdir(), prefix))
}

/**
 * A stand-in for `npm run dev`: a script that spawns a CHILD which outlives a
 * naive kill, prints a vite-shaped banner, and then waits forever. This is
 * the shape the process-group discipline exists for.
 */
function fakeDevServer(dir: string, opts: { url?: string; exitAfter?: boolean } = {}): string {
  const script = join(dir, 'dev-server.sh')
  writeFileSync(
    script,
    `#!/bin/sh
sleep 300 &
echo "  VITE v6.0.0  ready in 120 ms"
echo "  ➜  Local:   ${opts.url ?? 'http://localhost:5173/'}"
${opts.exitAfter ? 'exit 7' : 'wait'}
`,
  )
  chmodSync(script, 0o755)
  return script
}

function waitFor(predicate: () => boolean, timeoutMs = 8000): Promise<void> {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs
    const tick = (): void => {
      if (predicate()) return resolve()
      if (Date.now() > deadline) return reject(new Error('timed out'))
      setTimeout(tick, 20)
    }
    tick()
  })
}

describe('finding the address a dev server announced', () => {
  it('reads the URL out of real dev-server output', () => {
    expect(detectUrl('  ➜  Local:   http://localhost:5173/')).toBe('http://localhost:5173/')
    expect(detectUrl('Server running at http://127.0.0.1:3000')).toBe('http://127.0.0.1:3000')
    // A port it did not ask for is exactly why this is read, not guessed.
    expect(detectUrl('Port 5173 in use, using http://localhost:5174/')).toBe(
      'http://localhost:5174/',
    )
  })

  it('rewrites the every-interface address into one a browser can open', () => {
    expect(detectUrl('listening on http://0.0.0.0:8080/')).toBe('http://localhost:8080/')
  })

  it('offers nothing when nothing was announced', () => {
    expect(detectUrl('compiling…')).toBeNull()
    expect(detectUrl('see https://example.com/docs for help')).toBeNull()
  })
})

describe('running a preview', () => {
  it('reports starting, then running with the address it announced', async () => {
    const dir = repoDir()
    const changes: Preview[] = []
    const manager = new PreviewManager({ onChanged: (preview) => changes.push(preview) })

    const started = manager.start(dir, fakeDevServer(dir))
    expect(started.status).toBe('starting')
    expect(started.url).toBeNull()

    await waitFor(() => manager.get(started.id)?.url !== null)
    const live = manager.get(started.id)
    expect(live?.status).toBe('running')
    expect(live?.url).toBe('http://localhost:5173/')
    expect(manager.logs(started.id)).toContain('VITE')
    // The renderer learns about it by event, not by polling for the change.
    expect(changes.some((preview) => preview.url === 'http://localhost:5173/')).toBe(true)

    manager.disposeAll()
  })

  it('kills the whole process group, so nothing outlives the stop', async () => {
    const dir = repoDir()
    const manager = new PreviewManager({ onChanged: () => {} })
    const preview = manager.start(dir, fakeDevServer(dir))
    await waitFor(() => manager.get(preview.id)?.status === 'running')

    manager.stop(preview.id)
    await waitFor(() => manager.get(preview.id)?.status === 'exited')

    const stopped = manager.get(preview.id)
    expect(stopped?.status).toBe('exited')
    // The address is dropped with the process: a link to a dead server is
    // worse than no link.
    expect(stopped?.url).toBeNull()
    // The log survives the process — a server that died on startup is exactly
    // when its last lines matter.
    expect(manager.logs(preview.id)).toContain('VITE')
  }, 15_000)

  it('records a server that exits on its own, with its code', async () => {
    const dir = repoDir()
    const manager = new PreviewManager({ onChanged: () => {} })
    const preview = manager.start(dir, fakeDevServer(dir, { exitAfter: true }))

    await waitFor(() => manager.get(preview.id)?.status === 'exited')
    expect(manager.get(preview.id)?.exitCode).toBe(7)
  }, 15_000)

  it('refuses a second preview for the same project', async () => {
    const dir = repoDir()
    const manager = new PreviewManager({ onChanged: () => {} })
    const script = fakeDevServer(dir)
    manager.start(dir, script)
    // Two dev servers in one project fight over the port, and the second
    // one's failure would look like the first one's.
    expect(() => manager.start(dir, script)).toThrow(/already running/)
    manager.disposeAll()
  })

  it('refuses shell syntax, an unparseable command, and a missing binary', () => {
    const dir = repoDir()
    const manager = new PreviewManager({ onChanged: () => {} })
    expect(() => manager.start(dir, 'npm run dev | tee log')).toThrow(/shell syntax/)
    expect(() => manager.start(dir, '   ')).toThrow(/required/)
    expect(() => manager.start(dir, 'parley-definitely-missing-binary')).toThrow(/not found on PATH/)
    expect(() => manager.start('/definitely/not/a/dir', 'true')).toThrow(PreviewError)
  })

  it('frees a preview only when asked, and disposeAll takes them all', async () => {
    const dir = repoDir()
    const manager = new PreviewManager({ onChanged: () => {} })
    const preview = manager.start(dir, fakeDevServer(dir))
    await waitFor(() => manager.get(preview.id)?.status === 'running')

    expect(manager.list()).toHaveLength(1)
    manager.forget(preview.id)
    expect(manager.list()).toHaveLength(0)
    expect(manager.get(preview.id)).toBeNull()

    manager.start(dir, fakeDevServer(dir))
    manager.disposeAll()
    expect(manager.list()).toEqual([])
  }, 15_000)
})
