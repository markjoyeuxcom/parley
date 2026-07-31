import { describe, expect, it } from 'vitest'
import { isShellFree } from '@shared/command'
import {
  inputRefFor,
  REMOTE_HELPER_COMMAND,
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  resultRefFor,
  type RemoteCapabilities,
} from '@shared/remote'
import { decodeEvent, encodeRequest, handshakeRequest, sshArgv, targetRefusal } from './protocol'

const capabilities: RemoteCapabilities = {
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: 'b3f1c0de0000deadbeef',
  nodeVersion: 'v24.4.1',
  capabilities: [...REQUIRED_CAPABILITIES],
  vendors: [
    { vendor: 'claude', version: '2.1.220' },
    { vendor: 'codex', version: '0.145.0' },
  ],
  runsRoot: '/var/lib/parley/runs',
  git: '2.45.0',
}

describe('the ssh command line', () => {
  it('puts nothing that varies by run on the command line', () => {
    const argv = sshArgv({ host: 'build-01' })
    // The remote command is the bare constant. This is the property the whole
    // stdin protocol exists to preserve: ssh hands the remote command to a
    // login shell, so anything interpolated here would be shell text.
    expect(argv[argv.length - 1]).toBe(REMOTE_HELPER_COMMAND)
    expect(argv).not.toContain('run')
    for (const element of argv) expect(element).not.toMatch(/\s/)
  })

  it('leaves every element shell-free, so nothing needs quoting', () => {
    for (const element of sshArgv({ host: 'build-01' })) {
      expect(isShellFree(element)).toBe(true)
    }
  })

  it('refuses unknown host keys and never prompts for a password', () => {
    const argv = sshArgv({ host: 'build-01' })
    const flat = argv.join(' ')
    // Both are load-bearing: Parley executes code through this connection, and
    // a prompt against a process with no terminal is indistinguishable from a
    // hang.
    expect(flat).toContain('StrictHostKeyChecking=yes')
    expect(flat).toContain('BatchMode=yes')
  })

  it('carries the host through verbatim, so ~/.ssh/config still owns identity', () => {
    expect(sshArgv({ host: 'deploy@build-01' })).toContain('deploy@build-01')
  })
})

describe('the request body', () => {
  it('is exactly one newline-terminated line', () => {
    const encoded = encodeRequest(handshakeRequest('01J'))
    expect(encoded.endsWith('\n')).toBe(true)
    expect(encoded.trimEnd().includes('\n')).toBe(false)
    expect(JSON.parse(encoded)).toMatchObject({
      version: REMOTE_PROTOCOL_VERSION,
      operation: 'handshake',
      runId: '01J',
    })
  })
})

describe('run refs', () => {
  it('namespaces both states under the run, out of branch history', () => {
    expect(inputRefFor('01J')).toBe('refs/parley/runs/01J/input')
    expect(resultRefFor('01J')).toBe('refs/parley/runs/01J/result')
  })
})

describe('reading the far end', () => {
  it('reads each event type', () => {
    expect(decodeEvent(JSON.stringify({ type: 'ready', capabilities }))).toEqual({
      type: 'ready',
      capabilities,
    })
    // Build identity is required: a helper that will not say what it is
    // cannot be pinned, upgraded, or blamed.
    expect(
      decodeEvent(JSON.stringify({ type: 'ready', capabilities: { ...capabilities, buildId: 7 } })),
    ).toBeNull()
    expect(
      decodeEvent(JSON.stringify({ type: 'stdout', processId: 'verify-1', data: 'ok\n' })),
    ).toEqual({ type: 'stdout', processId: 'verify-1', data: 'ok\n' })
    expect(
      decodeEvent(JSON.stringify({ type: 'exit', processId: 'verify-1', code: 0, signal: null })),
    ).toEqual({ type: 'exit', processId: 'verify-1', code: 0, signal: null })
    expect(decodeEvent(JSON.stringify({ type: 'progress', phase: 'executing', text: 'x' }))).toEqual(
      { type: 'progress', phase: 'executing', text: 'x' },
    )
  })

  it('returns null for noise rather than throwing', () => {
    // A login banner, a truncated final line, a stray brace from a test — none
    // of these are protocol events and none may end a run.
    for (const line of ['', '  ', 'Welcome to Ubuntu', '{', '{"type":', 'null', '[]', '42']) {
      expect(decodeEvent(line)).toBeNull()
    }
  })

  it('refuses events whose required fields are the wrong shape', () => {
    expect(decodeEvent(JSON.stringify({ type: 'exit', processId: 'p', code: 'zero' }))).toBeNull()
    expect(decodeEvent(JSON.stringify({ type: 'stdout', processId: 'p' }))).toBeNull()
    expect(decodeEvent(JSON.stringify({ type: 'invented', field: 1 }))).toBeNull()
    expect(decodeEvent(JSON.stringify({ type: 'result', outcome: 'maybe' }))).toBeNull()
  })

  it('keeps a report event opaque — the local side owns that vocabulary', () => {
    const event = decodeEvent(JSON.stringify({ type: 'report', report: { kind: 'anything' } }))
    expect(event).toEqual({ type: 'report', report: { kind: 'anything' } })
  })

  it('requires a base commit on a result, because ancestry is checked against it', () => {
    const withBase = decodeEvent(
      JSON.stringify({
        type: 'result',
        outcome: 'complete',
        manifest: { resultCommit: 'aaa', baseCommit: 'bbb', changedPaths: ['a.ts'] },
      }),
    )
    expect(withBase).toMatchObject({ type: 'result', outcome: 'complete' })

    expect(
      decodeEvent(
        JSON.stringify({ type: 'result', outcome: 'complete', manifest: { resultCommit: 'aaa' } }),
      ),
    ).toBeNull()
  })

  it('drops non-string paths from a manifest instead of trusting the array', () => {
    const event = decodeEvent(
      JSON.stringify({
        type: 'result',
        outcome: 'failed',
        manifest: { resultCommit: null, baseCommit: 'b', changedPaths: ['a.ts', 7, null] },
      }),
    )
    expect(event).toMatchObject({ manifest: { changedPaths: ['a.ts'] } })
  })

  it('treats a missing retryable flag as not retryable', () => {
    // Fail closed: retrying a run that is not safe to retry spends real money
    // and can duplicate work on the remote.
    expect(decodeEvent(JSON.stringify({ type: 'error', message: 'x' }))).toEqual({
      type: 'error',
      message: 'x',
      retryable: false,
    })
  })
})

describe('whether a target can run this plan', () => {
  it('passes a target that speaks our version and has the vendors', () => {
    expect(targetRefusal(capabilities, ['claude', 'codex'])).toBeNull()
    expect(targetRefusal(capabilities, ['claude', 'claude'])).toBeNull()
  })

  it('refuses a protocol mismatch before anything is pushed or spent', () => {
    const refusal = targetRefusal({ ...capabilities, protocolVersion: 99 }, ['claude'])
    expect(refusal).toContain('v99')
    expect(refusal).toContain('upgrade')
  })

  it('refuses a helper that speaks our protocol but cannot do the work', () => {
    // Build identity and protocol compatibility are separate questions: two
    // builds may implement v1 correctly and still differ in what they can do.
    // A helper that cannot mutate must be refused here, not halfway through a
    // mutation stage.
    const refusal = targetRefusal(
      { ...capabilities, capabilities: ['git-worktree', 'pipeline-v1', 'evidence'] },
      ['claude'],
    )
    expect(refusal).toContain('mutation')
    expect(refusal).toContain('b3f1c0de0000')
  })

  it('names every missing vendor, so one trip fixes the host', () => {
    const refusal = targetRefusal(capabilities, ['claude', 'agy'])
    expect(refusal).toContain('agy')
    expect(refusal).not.toContain('claude')
  })

  it('refuses a target that reports no vendors at all', () => {
    expect(targetRefusal({ ...capabilities, vendors: [] }, ['claude'])).toContain('claude')
  })
})
