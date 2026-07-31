import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import type { RemoteBody } from '@shared/remote'
import { superviseRun } from './supervisor'

/**
 * The supervisor, with real processes and real process groups.
 *
 * Nothing here is mocked, because everything under test is operating-system
 * behaviour: whether a signal reaches a grandchild, whether a detached group
 * outlives its parent, whether cleanup still runs after the group is killed.
 * A stubbed spawn would let every one of those be asserted into existence.
 */

const root = mkdtempSync(join(tmpdir(), 'parley-supervisor-'))
afterAll(() => rmSync(root, { recursive: true, force: true }))

function script(name: string, body: string): string {
  const path = join(root, `${name}.mjs`)
  writeFileSync(path, `#!/usr/bin/env node\n${body}\n`, 'utf8')
  chmodSync(path, 0o755)
  return path
}

function run(
  worker: string,
  opts: { cancelAfterMs?: number; cleanup?: () => Promise<void> } = {},
) {
  const bodies: RemoteBody[] = []
  let resolveCancel: () => void = () => {}
  const cancelled = new Promise<void>((resolve) => {
    resolveCancel = resolve
  })
  if (opts.cancelAfterMs !== undefined) setTimeout(resolveCancel, opts.cancelAfterMs)

  const cleanupCalls: number[] = []
  const promise = superviseRun({
    command: process.execPath,
    args: [worker],
    request: { operation: 'run', runId: 'run-1' },
    hooks: {
      emit: (body) => bodies.push(body),
      cleanup: async () => {
        cleanupCalls.push(Date.now())
        if (opts.cleanup) await opts.cleanup()
      },
    },
    cancelled,
    graceMs: 300,
  })
  return { promise, bodies, cleanupCalls, cancel: resolveCancel }
}

describe('a worker that finishes', () => {
  it('relays its bodies and reports the exit', async () => {
    const worker = script(
      'happy',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'executing', text: 'started' }) + '\\n')
process.stdout.write(JSON.stringify({ type: 'progress', phase: 'testing', text: 'verified' }) + '\\n')
process.exit(0)`,
    )
    const { promise, bodies, cleanupCalls } = run(worker)
    const end = await promise
    expect(end).toEqual({ kind: 'finished', exitCode: 0 })
    expect(bodies).toEqual([
      { type: 'progress', phase: 'executing', text: 'started' },
      { type: 'progress', phase: 'testing', text: 'verified' },
    ])
    expect(cleanupCalls).toHaveLength(1)
  })

  it('delivers the request on the worker’s stdin', async () => {
    const seen = join(root, 'request.json')
    const worker = script(
      'echo-request',
      `import { writeFileSync } from 'node:fs'
let input = ''
process.stdin.on('data', (c) => { input += c })
process.stdin.on('end', () => {
  writeFileSync(${JSON.stringify(seen)}, input)
  process.exit(0)
})`,
    )
    await run(worker).promise
    expect(JSON.parse(readFileSync(seen, 'utf8'))).toMatchObject({ runId: 'run-1' })
  })

  it('reports a non-zero exit as failure, with the worker’s stderr', async () => {
    const worker = script(
      'angry',
      `process.stderr.write('the milestone could not start\\n')
process.exit(4)`,
    )
    const end = await run(worker).promise
    expect(end.kind).toBe('failed')
    expect(end.kind === 'failed' && end.detail).toContain('could not start')
  })

  it('surfaces unreadable worker output rather than dropping it', async () => {
    // The worker is our own code. Garbage from it is a bug, and a stream that
    // silently swallowed it would lose facts without anything looking wrong.
    const worker = script(
      'garbled',
      `process.stdout.write('{ not json\\n')
process.exit(0)`,
    )
    const { promise, bodies } = run(worker)
    await promise
    expect(bodies[0]).toMatchObject({ type: 'error' })
    expect(JSON.stringify(bodies[0])).toContain('unreadable')
  })
})

describe('cancellation reaches the whole group', () => {
  it('kills a grandchild the worker spawned, not just the worker', async () => {
    // The case the split exists for. The worker's children are the agent and
    // test commands; if only the worker died they would keep running, keep
    // writing to the worktree, and keep spending.
    const marker = join(root, 'grandchild-alive')
    const worker = script(
      'spawns-grandchild',
      `import { spawn } from 'node:child_process'
// -e runs CommonJS, so require is available inside the grandchild.
const child = spawn(process.execPath, ['-e',
  'const fs = require("node:fs"); setInterval(() => fs.writeFileSync(' +
  ${JSON.stringify(JSON.stringify(marker))} + ', String(Date.now())), 30)',
], { stdio: 'ignore' })
process.stdout.write(JSON.stringify({ type: 'progress', phase: 'executing', text: 'spawned' }) + '\\n')
setInterval(() => {}, 1000)`,
    )
    const { promise } = run(worker, { cancelAfterMs: 250 })
    const end = await promise
    expect(end).toEqual({ kind: 'cancelled' })

    // Give anything that survived a chance to prove it: if the grandchild is
    // still ticking it will keep rewriting the marker.
    const at = existsSync(marker) ? readFileSync(marker, 'utf8') : ''
    await new Promise((resolve) => setTimeout(resolve, 250))
    const after = existsSync(marker) ? readFileSync(marker, 'utf8') : ''
    expect(after).toBe(at)
  }, 20_000)

  it('still runs cleanup after killing the group', async () => {
    // The whole reason the pipeline does not execute in the supervisor: if it
    // did, killing the group would kill the code that removes the worktree,
    // and the only symptom would be directories piling up on the host.
    const worker = script('stubborn', `setInterval(() => {}, 1000)`)
    const { promise, cleanupCalls } = run(worker, { cancelAfterMs: 150 })
    const end = await promise
    expect(end).toEqual({ kind: 'cancelled' })
    expect(cleanupCalls).toHaveLength(1)
  }, 20_000)

  it('escalates to SIGKILL when a worker ignores SIGTERM', async () => {
    const worker = script(
      'ignores-term',
      `process.on('SIGTERM', () => {})
process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'ignoring' }) + '\\n')
setInterval(() => {}, 1000)`,
    )
    const started = Date.now()
    const { promise, cleanupCalls } = run(worker, { cancelAfterMs: 100 })
    const end = await promise
    expect(end).toEqual({ kind: 'cancelled' })
    // It took the grace period, and it did finish — a supervisor that gave up
    // here would leave the run alive with nobody watching it.
    expect(Date.now() - started).toBeGreaterThanOrEqual(300)
    expect(cleanupCalls).toHaveLength(1)
  }, 20_000)

  it('reports cancellation rather than a successful completion', async () => {
    // A worker killed mid-flight may have emitted anything; what it must not
    // produce is an ending that reads as work finished.
    const worker = script(
      'almost-done',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'nearly' }) + '\\n')
setInterval(() => {}, 1000)`,
    )
    const { promise, bodies } = run(worker, { cancelAfterMs: 120 })
    const end = await promise
    expect(end).toEqual({ kind: 'cancelled' })
    expect(bodies.some((body) => body.type === 'result')).toBe(false)
  }, 20_000)
})

describe('a worker that cannot start', () => {
  it('fails without pretending anything ran', async () => {
    const bodies: RemoteBody[] = []
    const end = await superviseRun({
      command: join(root, 'does-not-exist'),
      args: [],
      request: {},
      hooks: { emit: (body) => bodies.push(body), cleanup: async () => {} },
      cancelled: new Promise(() => {}),
      graceMs: 100,
    })
    expect(end.kind).toBe('failed')
    expect(bodies.some((body) => body.type === 'result')).toBe(false)
  })
})
