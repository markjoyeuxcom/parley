import { mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { REMOTE_PROTOCOL_VERSION, type RemoteEvent } from '@shared/remote'
import { handshakeRequest } from './protocol'
import { runSsh } from './ssh'

/**
 * The transport, against a fake ssh.
 *
 * Every case here is a real process: the "ssh binary" is a small node script
 * that behaves the way a particular failure behaves. That matters because the
 * distinctions this module draws — refused vs protocol vs disconnected — are
 * about process mechanics (exit 255, an empty stdout, a signal), and a mocked
 * spawn would let us assert those mechanics into existence rather than observe
 * them.
 */

const root = mkdtempSync(join(tmpdir(), 'parley-ssh-'))
afterAll(() => rmSync(root, { recursive: true, force: true }))

/** Writes an executable node script and returns its path. */
function fakeSsh(name: string, body: string): string {
  const path = join(root, `${name}.mjs`)
  writeFileSync(path, `#!/usr/bin/env node\n${body}\n`, 'utf8')
  chmodSync(path, 0o755)
  return path
}

const capabilities = JSON.stringify({
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: 'b3f1c0de',
  nodeVersion: 'v24.4.1',
  capabilities: ['git-worktree', 'pipeline-v1', 'mutation', 'evidence'],
  vendors: [{ vendor: 'claude', version: '2.1.220' }],
  runsRoot: '/var/lib/parley/runs',
  git: '2.45.0',
})

async function run(binary: string, timeoutMs?: number) {
  const events: RemoteEvent[] = []
  const result = await runSsh({
    target: { host: 'fake' },
    request: handshakeRequest('01J'),
    onEvent: (event) => events.push(event),
    sshBinary: binary,
    timeoutMs,
  })
  return { ...result, events }
}

describe('a healthy conversation', () => {
  it('delivers the request on stdin and reads framed events back', async () => {
    // The script echoes what it was given, proving the request reached stdin
    // rather than the command line — the property the whole design rests on.
    const binary = fakeSsh(
      'happy',
      `let input = ''
process.stdin.on('data', (c) => { input += c })
process.stdin.on('end', () => {
  const request = JSON.parse(input)
  process.stdout.write(JSON.stringify({ type: 'ready', capabilities: ${capabilities} }) + '\\n')
  process.stdout.write(JSON.stringify({ type: 'progress', phase: 'received', text: request.operation }) + '\\n')
  process.exit(0)
})`,
    )
    const { end, events } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(events[0]).toMatchObject({ type: 'ready' })
    expect(events[1]).toEqual({ type: 'progress', phase: 'received', text: 'handshake' })
  })

  it('reassembles events split across chunk boundaries', async () => {
    const binary = fakeSsh(
      'chunked',
      `const line = JSON.stringify({ type: 'progress', phase: 'p', text: 'whole' }) + '\\n'
process.stdout.write(line.slice(0, 12))
setTimeout(() => { process.stdout.write(line.slice(12)); process.exit(0) }, 20)`,
    )
    const { events } = await run(binary)
    expect(events).toEqual([{ type: 'progress', phase: 'p', text: 'whole' }])
  })

  it('drains stdout before interpreting the end', async () => {
    // 'close' not 'exit': a result event still in the pipe at exit time would
    // otherwise read as a run that produced no result.
    const binary = fakeSsh(
      'burst',
      `for (let i = 0; i < 200; i++) {
  process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: String(i) }) + '\\n')
}
process.exit(0)`,
    )
    const { events, end } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(events).toHaveLength(200)
    expect(events[199]).toMatchObject({ text: '199' })
  })

  it('keeps a non-zero exit as a closed conversation, not a transport failure', async () => {
    // The pipeline failing is a normal, reportable outcome. Only ssh's own 255
    // means we never got to the far end.
    const binary = fakeSsh(
      'failed-run',
      `process.stdout.write(JSON.stringify({ type: 'error', message: 'milestone failed', retryable: false }) + '\\n')
process.exit(3)`,
    )
    const { end, events } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 3 })
    expect(events[0]).toMatchObject({ type: 'error', retryable: false })
  })
})

describe('failures that must not be confused', () => {
  it('reads ssh exit 255 as refused, and passes ssh its own words', async () => {
    const binary = fakeSsh(
      'refused',
      `process.stderr.write('Host key verification failed.\\n')
process.exit(255)`,
    )
    const { end } = await run(binary)
    expect(end.kind).toBe('refused')
    expect(end.kind === 'refused' && end.detail).toContain('Host key verification failed')
  })

  it('reads a connection with no protocol output as a missing helper', async () => {
    const binary = fakeSsh(
      'no-helper',
      `process.stderr.write('bash: parley-remote: command not found\\n')
process.exit(127)`,
    )
    const { end } = await run(binary)
    expect(end.kind).toBe('protocol')
    expect(end.kind === 'protocol' && end.detail).toContain('command not found')
  })

  it('says so plainly when the far end is silent', async () => {
    const binary = fakeSsh('silent', `process.exit(0)`)
    const { end } = await run(binary)
    expect(end.kind).toBe('protocol')
    expect(end.kind === 'protocol' && end.detail).toContain('parley-remote')
  })

  it('reads a killed ssh as disconnected — the work may have finished', async () => {
    // The dangerous case. Reporting this as failure would send the caller to
    // re-run work that may already be committed at the result ref.
    const binary = fakeSsh(
      'killed',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'started' }) + '\\n')
setTimeout(() => process.kill(process.pid, 'SIGKILL'), 30)`,
    )
    const { end } = await run(binary)
    expect(end.kind).toBe('disconnected')
  })

  it('times out as disconnected rather than failed, for the same reason', async () => {
    const binary = fakeSsh(
      'hang',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'x' }) + '\\n')
setInterval(() => {}, 1000)`,
    )
    const { end } = await run(binary, 150)
    expect(end.kind).toBe('disconnected')
    expect(end.kind === 'disconnected' && end.detail).toContain('time limit')
  })

  it('reports a missing ssh binary as refused', async () => {
    const { end } = await run(join(root, 'does-not-exist'))
    expect(end.kind).toBe('refused')
  })

  it('survives a helper that exits before reading stdin', async () => {
    // Closes the stdin pipe under our write; must not throw EPIPE.
    const binary = fakeSsh('early-exit', `process.exit(1)`)
    const { end } = await run(binary)
    expect(end.kind).toBe('protocol')
  })
})

describe('noise on the wire', () => {
  it('keeps unreadable lines for diagnosis without ending the run', async () => {
    const binary = fakeSsh(
      'noisy',
      `process.stdout.write('Welcome to Ubuntu 24.04\\n')
process.stdout.write('{ this is not json\\n')
process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'still here' }) + '\\n')
process.exit(0)`,
    )
    const { end, events, unreadable } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(events).toHaveLength(1)
    expect(unreadable).toEqual(['Welcome to Ubuntu 24.04', '{ this is not json'])
  })

  it('bounds how much noise it keeps', async () => {
    const binary = fakeSsh(
      'very-noisy',
      `for (let i = 0; i < 500; i++) process.stdout.write('noise ' + i + '\\n')
process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'x' }) + '\\n')
process.exit(0)`,
    )
    const { unreadable } = await run(binary)
    expect(unreadable.length).toBeLessThanOrEqual(20)
  })
})

describe('cancellation', () => {
  it('stops the run and reports it as cancelled, not failed', async () => {
    const binary = fakeSsh(
      'long',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'working' }) + '\\n')
setInterval(() => {}, 1000)`,
    )
    const controller = new AbortController()
    const events: RemoteEvent[] = []
    const promise = runSsh({
      target: { host: 'fake' },
      request: handshakeRequest('01J'),
      onEvent: (event) => {
        events.push(event)
        controller.abort()
      },
      signal: controller.signal,
      sshBinary: binary,
    })
    const { end } = await promise
    expect(end).toEqual({ kind: 'cancelled' })
    expect(events).toHaveLength(1)
  })
})
