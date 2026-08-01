import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import { REMOTE_PROTOCOL_VERSION, type RemoteBody, type RemoteFrame } from '@shared/remote'
import { handshakeRequest } from './protocol'
import { runSsh } from './ssh'

/**
 * The transport, against a fake ssh.
 *
 * Every case here is a real process: the "ssh binary" is a small node script
 * that behaves the way a particular failure behaves. That matters because the
 * distinctions this module draws — refused, protocol, violation, disconnected —
 * are about process mechanics (exit 255, an empty stdout, a signal, a gap in a
 * byte stream), and a mocked spawn would let us assert those mechanics into
 * existence rather than observe them.
 */

const root = mkdtempSync(join(tmpdir(), 'parley-ssh-'))
afterAll(() => rmSync(root, { recursive: true, force: true }))

const capabilities = JSON.stringify({
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: 'b3f1c0de',
  nodeVersion: 'v24.4.1',
  nodeExecutable: '/usr/bin/node',
  capabilities: ['git-worktree', 'pipeline-v1', 'mutation', 'evidence'],
  supportedVendors: ['claude', 'codex'],
  availableVendors: ['claude'],
  vendorDetails: {},
  user: 'build',
  home: '/home/build',
  path: '/usr/bin:/bin',
  git: '2.45.0',
  runsRoot: '/var/lib/parley/runs',
})

/**
 * The preamble every fake gets, which is also the shape the real bundle must
 * produce: a frame carries the run, a monotonic sequence and a body, and
 * `hello()` is the announcement that has to come first.
 */
const PREAMBLE = `let __seq = 0
const frameText = (body, seq) => JSON.stringify({
  protocolVersion: ${REMOTE_PROTOCOL_VERSION}, runId: '01J', sequence: seq ?? ++__seq, body,
}) + '\\n'
const say = (body) => process.stdout.write(frameText(body))
const hello = () => say({ type: 'ready', capabilities: ${capabilities} })
`

function fakeSsh(name: string, body: string): string {
  const path = join(root, `${name}.mjs`)
  writeFileSync(path, `#!/usr/bin/env node\n${PREAMBLE}${body}\n`, 'utf8')
  chmodSync(path, 0o755)
  return path
}

async function run(binary: string, timeoutMs?: number) {
  const frames: RemoteFrame[] = []
  const result = await runSsh({
    target: { host: 'fake' },
    request: handshakeRequest('01J'),
    onFrame: (frame) => frames.push(frame),
    sshBinary: binary,
    timeoutMs,
  })
  return { ...result, frames, bodies: frames.map((frame) => frame.body) }
}

describe('a healthy conversation', () => {
  it('delivers the request on stdin and reads frames back', async () => {
    // The script echoes what it was given, proving the request reached stdin
    // rather than the command line — the property the whole design rests on.
    const binary = fakeSsh(
      'happy',
      `let input = ''
process.stdin.on('data', (c) => {
  input += c
  // One newline-terminated line, not EOF: stdin stays open for the life of
  // the run so that its closing can mean something. fromCharCode rather than
  // an escape, because this string is source for a generated file and the
  // escape gets one interpretation too many on the way.
  const at = input.indexOf(String.fromCharCode(10))
  if (at < 0) return
  const request = JSON.parse(input.slice(0, at))
  hello()
  say({ type: 'progress', phase: 'received', text: request.operation })
  process.exit(0)
})`,
    )
    const { end, frames, bodies } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(bodies[0]).toMatchObject({ type: 'ready' })
    expect(bodies[1]).toEqual({ type: 'progress', phase: 'received', text: 'handshake' })
    expect(frames.map((frame) => frame.sequence)).toEqual([1, 2])
    expect(frames.every((frame) => frame.runId === '01J')).toBe(true)
  })

  it('reassembles frames split across chunk boundaries', async () => {
    const binary = fakeSsh(
      'chunked',
      `hello()
const line = frameText({ type: 'progress', phase: 'p', text: 'whole' })
process.stdout.write(line.slice(0, 12))
setTimeout(() => { process.stdout.write(line.slice(12)); process.exit(0) }, 20)`,
    )
    const { bodies } = await run(binary)
    expect(bodies[1]).toEqual({ type: 'progress', phase: 'p', text: 'whole' })
  })

  it('drains stdout before interpreting the end', async () => {
    // 'close' not 'exit': a result frame still in the pipe at exit time would
    // otherwise read as a run that produced no result.
    const binary = fakeSsh(
      'burst',
      `hello()
for (let i = 0; i < 200; i++) say({ type: 'progress', phase: 'p', text: String(i) })
process.exit(0)`,
    )
    const { bodies, end, frames } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(bodies).toHaveLength(201)
    expect(frames[200]?.sequence).toBe(201)
  })

  it('keeps a non-zero exit as a closed conversation, not a transport failure', async () => {
    // The pipeline failing is a normal, reportable outcome. Only ssh's own 255
    // means we never got to the far end.
    const binary = fakeSsh(
      'failed-run',
      `hello()
say({ type: 'error', message: 'milestone failed', retryable: false })
process.exit(3)`,
    )
    const { end, bodies } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 3 })
    expect(bodies[1]).toMatchObject({ type: 'error', retryable: false })
  })

  it('carries a child process’s output framed, never raw', async () => {
    // The case that would turn the wire into soup if it were not framed: a
    // test that prints a lone brace.
    const binary = fakeSsh(
      'noisy-child',
      `hello()
say({ type: 'stdout', processId: 'verify-1', data: '{\\n' })
say({ type: 'exit', processId: 'verify-1', code: 0, signal: null })
process.exit(0)`,
    )
    const { bodies, unreadable } = await run(binary)
    expect(bodies[1]).toEqual({ type: 'stdout', processId: 'verify-1', data: '{\n' })
    expect(bodies[2]).toEqual({ type: 'exit', processId: 'verify-1', code: 0, signal: null })
    expect(unreadable).toEqual([])
  })

  it('ignores a repeated frame instead of delivering it twice', async () => {
    // Exactly what a resume will resend. Applying it twice is the corruption;
    // ignoring it is what the sequence number is for.
    const binary = fakeSsh(
      'repeater',
      `hello()
process.stdout.write(frameText({ type: 'progress', phase: 'p', text: 'once' }, 2))
process.stdout.write(frameText({ type: 'progress', phase: 'p', text: 'once' }, 2))
process.exit(0)`,
    )
    const { end, bodies } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(bodies).toHaveLength(2)
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
      `hello()
setTimeout(() => process.kill(process.pid, 'SIGKILL'), 30)`,
    )
    const { end } = await run(binary)
    expect(end.kind).toBe('disconnected')
  })

  it('times out as disconnected rather than failed, for the same reason', async () => {
    const binary = fakeSsh('hang', `hello()\nsetInterval(() => {}, 1000)`)
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

describe('noise is tolerated only before the handshake', () => {
  it('keeps bootstrap noise for diagnosis without ending the run', async () => {
    // ssh sessions emit banners and shell startup files print things. None of
    // that is the helper's fault, and none of it should stop a run.
    const binary = fakeSsh(
      'noisy-boot',
      `process.stdout.write('Welcome to Ubuntu 24.04\\n')
process.stdout.write('{ this is not json\\n')
hello()
say({ type: 'progress', phase: 'p', text: 'still here' })
process.exit(0)`,
    )
    const { end, bodies, unreadable } = await run(binary)
    expect(end).toEqual({ kind: 'closed', exitCode: 0 })
    expect(bodies).toHaveLength(2)
    expect(unreadable).toEqual(['Welcome to Ubuntu 24.04', '{ this is not json'])
  })

  it('treats the same noise AFTER the handshake as fatal', async () => {
    // Once the protocol claims to be alive, a stray console.log or a leaked
    // child write means facts are going missing. A run that continues while
    // silently dropping facts produces a record with a hole in it.
    const binary = fakeSsh(
      'noisy-after',
      `hello()
process.stdout.write('oops I printed something\\n')
say({ type: 'progress', phase: 'p', text: 'never seen' })
setInterval(() => {}, 1000)`,
    )
    const { end, bodies } = await run(binary)
    expect(end.kind).toBe('violation')
    expect(end.kind === 'violation' && end.detail).toContain('oops I printed something')
    expect(bodies).toHaveLength(1)
  })

  it('fails a gap in the sequence rather than carrying on with a hole', async () => {
    const binary = fakeSsh(
      'gappy',
      `hello()
process.stdout.write(frameText({ type: 'progress', phase: 'p', text: 'skipped ahead' }, 4))
setInterval(() => {}, 1000)`,
    )
    const { end, bodies } = await run(binary)
    expect(end.kind).toBe('violation')
    expect(end.kind === 'violation' && end.detail).toContain('2')
    expect(bodies).toHaveLength(1)
  })

  it('refuses a frame that arrives before the helper announces itself', async () => {
    const binary = fakeSsh(
      'no-hello',
      `say({ type: 'progress', phase: 'p', text: 'straight to work' })
setInterval(() => {}, 1000)`,
    )
    const { end, bodies } = await run(binary)
    expect(end.kind).toBe('violation')
    expect(end.kind === 'violation' && end.detail).toContain('announcing')
    expect(bodies).toEqual([])
  })

  it('reads a well-formed body with no frame identity as never having spoken', async () => {
    const binary = fakeSsh(
      'unframed',
      `process.stdout.write(JSON.stringify({ type: 'progress', phase: 'p', text: 'bare' }) + '\\n')
process.exit(0)`,
    )
    const { end, bodies, unreadable } = await run(binary)
    expect(bodies).toEqual([])
    expect(unreadable).toHaveLength(1)
    expect(end.kind).toBe('protocol')
  })

  it('bounds how much bootstrap noise it keeps', async () => {
    const binary = fakeSsh(
      'very-noisy',
      `for (let i = 0; i < 500; i++) process.stdout.write('noise ' + i + '\\n')
hello()
process.exit(0)`,
    )
    const { unreadable } = await run(binary)
    expect(unreadable.length).toBeLessThanOrEqual(20)
  })
})

describe('cancellation', () => {
  it('stops the run and reports it as cancelled, not failed', async () => {
    const binary = fakeSsh('long', `hello()\nsetInterval(() => {}, 1000)`)
    const controller = new AbortController()
    const bodies: RemoteBody[] = []
    const { end } = await runSsh({
      target: { host: 'fake' },
      request: handshakeRequest('01J'),
      onFrame: (frame) => {
        bodies.push(frame.body)
        controller.abort()
      },
      signal: controller.signal,
      sshBinary: binary,
    })
    expect(end).toEqual({ kind: 'cancelled' })
    expect(bodies).toHaveLength(1)
  })
})
