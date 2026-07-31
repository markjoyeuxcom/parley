import { describe, expect, it } from 'vitest'
import { isShellFree } from '@shared/command'
import {
  FORBIDDEN_ENV,
  inputRefFor,
  REMOTE_HELPER_COMMAND,
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  resultRefFor,
  safeEnvOverlay,
  type RemoteCapabilities,
} from '@shared/remote'
import { decodeMilestoneFact } from '../orchestrator/reporter'
import { decodeFrame, FrameDeduplicator, FrameWriter } from './frames'
import { encodeRequest, handshakeRequest, hostWarnings, sshArgv, targetRefusal } from './protocol'

const capabilities: RemoteCapabilities = {
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: 'b3f1c0de0000deadbeef',
  nodeVersion: 'v24.4.1',
  nodeExecutable: '/usr/bin/node',
  capabilities: [...REQUIRED_CAPABILITIES],
  supportedVendors: ['claude', 'codex', 'agy'],
  availableVendors: ['claude', 'codex'],
  vendorDetails: {
    claude: {
      executable: '/home/build/.local/bin/claude',
      version: '2.1.220',
      configured: true,
      permissionMode: 'ask',
    },
    codex: {
      executable: '/home/build/.local/bin/codex',
      version: '0.145.0',
      configured: true,
      permissionMode: null,
    },
    agy: { executable: null, version: null, configured: false, permissionMode: null },
  },
  user: 'build',
  home: '/home/build',
  path: '/usr/local/bin:/usr/bin:/bin',
  git: '2.45.0',
  runsRoot: '/var/lib/parley/runs',
}

function frame(body: unknown, over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    protocolVersion: REMOTE_PROTOCOL_VERSION,
    runId: '01J',
    sequence: 1,
    body,
    ...over,
  })
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
    const flat = sshArgv({ host: 'build-01' }).join(' ')
    expect(flat).toContain('StrictHostKeyChecking=yes')
    expect(flat).toContain('BatchMode=yes')
  })
})

describe('the request body', () => {
  it('is exactly one newline-terminated line', () => {
    const encoded = encodeRequest(handshakeRequest('01J'))
    expect(encoded.endsWith('\n')).toBe(true)
    expect(encoded.trimEnd().includes('\n')).toBe(false)
  })

  it('namespaces both run states out of branch history', () => {
    expect(inputRefFor('01J')).toBe('refs/parley/runs/01J/input')
    expect(resultRefFor('01J')).toBe('refs/parley/runs/01J/result')
  })
})

describe('the environment overlay', () => {
  it('keeps ordinary variables', () => {
    expect(safeEnvOverlay({ CI: '1', NODE_ENV: 'test' })).toEqual({ CI: '1', NODE_ENV: 'test' })
  })

  it('strips everything that would reach past the protocol', () => {
    // Each of these would let a request relocate the home directory the agent
    // CLIs read credentials from, redirect git, or inject code into every
    // process the runner spawns.
    const hostile: Record<string, string> = { KEEP: 'yes' }
    for (const key of FORBIDDEN_ENV) hostile[key] = '/evil'
    expect(safeEnvOverlay(hostile)).toEqual({ KEEP: 'yes' })
  })

  it('is not fooled by casing', () => {
    expect(safeEnvOverlay({ path: '/evil', Home: '/evil' })).toEqual({})
  })

  it('treats no overlay as an empty one', () => {
    expect(safeEnvOverlay(undefined)).toEqual({})
  })
})

describe('writing frames', () => {
  it('numbers frames monotonically from one, within a run', () => {
    const writer = new FrameWriter('run-a')
    expect(writer.next({ type: 'progress', phase: 'p', text: 'a' }).sequence).toBe(1)
    expect(writer.next({ type: 'progress', phase: 'p', text: 'b' }).sequence).toBe(2)
    expect(writer.lastSequence).toBe(2)
    // Zero is reserved for "nothing yet", which is what a resume would ask to
    // follow before any frame has arrived.
    expect(new FrameWriter('run-b').lastSequence).toBe(0)
  })

  it('writes one terminated line that round-trips', () => {
    const writer = new FrameWriter('run-a')
    const line = writer.line({ type: 'progress', phase: 'executing', text: 'started' })
    expect(line.endsWith('\n')).toBe(true)
    expect(decodeFrame(line)).toEqual({
      protocolVersion: REMOTE_PROTOCOL_VERSION,
      runId: 'run-a',
      sequence: 1,
      body: { type: 'progress', phase: 'executing', text: 'started' },
    })
  })
})

describe('deduplicating frames', () => {
  it('accepts each frame once and rejects the repeat', () => {
    // The case this exists for: a connection dies between the remote emitting
    // a fact and learning it was received, so it resends. A record written
    // twice from one observation is a corrupted record.
    const seen = new FrameDeduplicator()
    const writer = new FrameWriter('run-a')
    const first = writer.next({ type: 'progress', phase: 'p', text: 'x' })
    expect(seen.accept(first)).toBe(true)
    expect(seen.accept(first)).toBe(false)
    expect(seen.accept(writer.next({ type: 'progress', phase: 'p', text: 'y' }))).toBe(true)
  })

  it('keeps runs separate — sequences only mean anything within one', () => {
    const seen = new FrameDeduplicator()
    const a = new FrameWriter('run-a').next({ type: 'progress', phase: 'p', text: 'x' })
    const b = new FrameWriter('run-b').next({ type: 'progress', phase: 'p', text: 'x' })
    expect(seen.accept(a)).toBe(true)
    expect(seen.accept(b)).toBe(true)
  })

  it('reports the high-water mark a resume would follow', () => {
    const seen = new FrameDeduplicator()
    const writer = new FrameWriter('run-a')
    for (let i = 0; i < 40; i++) seen.accept(writer.next({ type: 'progress', phase: 'p', text: '' }))
    expect(seen.highWater('run-a')).toBe(40)
    expect(seen.highWater('never-seen')).toBe(0)
    seen.forget('run-a')
    expect(seen.highWater('run-a')).toBe(0)
  })
})

describe('reading frames', () => {
  it('reads each body type', () => {
    expect(decodeFrame(frame({ type: 'ready', capabilities }))?.body).toEqual({
      type: 'ready',
      capabilities,
    })
    expect(decodeFrame(frame({ type: 'stdout', processId: 'v', data: 'x' }))?.body).toEqual({
      type: 'stdout',
      processId: 'v',
      data: 'x',
    })
    expect(decodeFrame(frame({ type: 'exit', processId: 'v', code: 0, signal: null }))?.body).toEqual(
      { type: 'exit', processId: 'v', code: 0, signal: null },
    )
  })

  it('returns null for noise rather than throwing', () => {
    // A login banner, a truncated final line, a stray brace — none of these
    // are frames and none may end a run.
    for (const line of ['', '  ', 'Welcome to Ubuntu', '{', '{"type":', 'null', '[]', '42']) {
      expect(decodeFrame(line)).toBeNull()
    }
  })

  it('refuses a frame with no identity', () => {
    // Without a run and a sequence it cannot be deduplicated, and a frame that
    // cannot be deduplicated cannot be safely replayed.
    expect(decodeFrame(JSON.stringify({ body: { type: 'progress', phase: 'p', text: 'x' } }))).toBeNull()
    expect(decodeFrame(frame({ type: 'progress', phase: 'p', text: 'x' }, { runId: 7 }))).toBeNull()
    expect(decodeFrame(frame({ type: 'progress', phase: 'p', text: 'x' }, { sequence: 0 }))).toBeNull()
    expect(
      decodeFrame(frame({ type: 'progress', phase: 'p', text: 'x' }, { sequence: 1.5 })),
    ).toBeNull()
  })

  it('requires build identity in a handshake', () => {
    // A helper that will not say what it is cannot be pinned, upgraded or
    // blamed.
    const { buildId: _drop, ...rest } = capabilities
    expect(decodeFrame(frame({ type: 'ready', capabilities: rest }))).toBeNull()
  })

  it('keeps a fact opaque — what it MEANS belongs to the orchestrator', () => {
    expect(decodeFrame(frame({ type: 'fact', fact: { kind: 'anything' } }))?.body).toEqual({
      type: 'fact',
      fact: { kind: 'anything' },
    })
  })

  it('treats a missing retryable flag as not retryable', () => {
    // Fail closed: retrying a run that is not safe to retry spends real money.
    expect(decodeFrame(frame({ type: 'error', message: 'x' }))?.body).toEqual({
      type: 'error',
      message: 'x',
      retryable: false,
    })
  })
})

describe('facts that arrived from somewhere else', () => {
  it('preserves the difference between an omitted field and a null one', () => {
    // The distinction the whole record depends on: omitting completedAt leaves
    // the stamp alone, sending null clears it. Testing for undefined instead
    // of presence would merge two opposite instructions.
    const omitted = decodeMilestoneFact({ kind: 'finished', passed: false, note: 'n' })
    expect(omitted).not.toBeNull()
    expect(omitted && 'completedAt' in omitted).toBe(false)

    const cleared = decodeMilestoneFact({
      kind: 'finished',
      passed: false,
      note: 'n',
      completedAt: null,
    })
    expect(cleared && 'completedAt' in cleared).toBe(true)
    expect(cleared).toMatchObject({ completedAt: null })
  })

  it('survives a JSON round trip with that distinction intact', () => {
    // The real path: JSON.stringify drops undefined, so a fact built with an
    // absent field arrives absent — which is only useful if the reader asks
    // about presence.
    const wire = JSON.parse(JSON.stringify({ kind: 'finished', passed: true, note: 'ok' }))
    const decoded = decodeMilestoneFact(wire)
    expect(decoded && 'completedAt' in decoded).toBe(false)
  })

  it('refuses fields of the wrong type instead of writing them', () => {
    expect(decodeMilestoneFact({ kind: 'finished', passed: 'yes', note: 'n' })).toBeNull()
    expect(
      decodeMilestoneFact({ kind: 'finished', passed: true, note: 'n', completedAt: 'soon' }),
    ).toBeNull()
    expect(decodeMilestoneFact({ kind: 'phase', phase: 'napping' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'judgement', passed: 'maybe' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'planOutcome', status: 'vibes' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'invented' })).toBeNull()
    expect(decodeMilestoneFact(null)).toBeNull()
  })

  it('requires presence for the fields where absence would be a lie', () => {
    // A checkpoint with no runState key says nothing about resumability; a
    // verification with no result key says nothing about the suite. Both must
    // be sent explicitly, even when the value is null.
    expect(decodeMilestoneFact({ kind: 'checkpoint' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'checkpoint', runState: null })).toEqual({
      kind: 'checkpoint',
      runState: null,
    })
    expect(decodeMilestoneFact({ kind: 'verification' })).toBeNull()
    expect(decodeMilestoneFact({ kind: 'verification', result: null })).toEqual({
      kind: 'verification',
      result: null,
    })
    expect(decodeMilestoneFact({ kind: 'judgement' })).toBeNull()
  })

  it('drops non-string entries from a narrative rather than trusting the array', () => {
    expect(
      decodeMilestoneFact({ kind: 'narrative', note: 'n', blocking: ['a', 3], notes: null }),
    ).toEqual({ kind: 'narrative', note: 'n', blocking: ['a'], notes: [] })
  })
})

describe('whether a target can run this plan', () => {
  it('passes a host that speaks our version and has the vendors', () => {
    expect(targetRefusal(capabilities, ['claude', 'codex'])).toBeNull()
  })

  it('refuses a protocol mismatch before anything is pushed or spent', () => {
    const refusal = targetRefusal({ ...capabilities, protocolVersion: 99 }, ['claude'])
    expect(refusal).toContain('v99')
    expect(refusal).toContain('upgrade')
  })

  it('refuses a helper that speaks our protocol but cannot do the work', () => {
    const refusal = targetRefusal(
      { ...capabilities, capabilities: ['git-worktree', 'pipeline-v1', 'evidence'] },
      ['claude'],
    )
    expect(refusal).toContain('mutation')
    expect(refusal).toContain('b3f1c0de0000')
  })

  it('tells an out-of-date bundle apart from an unprovisioned host', () => {
    // The two look identical from the outside and have opposite fixes:
    // upgrade the helper, or install the CLI over there. Collapsing them
    // sends people to fix the wrong machine.
    const outdated = targetRefusal({ ...capabilities, supportedVendors: ['claude'] }, ['codex'])
    expect(outdated).toContain('no adapter')
    expect(outdated).toContain('upgrade')

    const unprovisioned = targetRefusal(capabilities, ['agy'])
    expect(unprovisioned).not.toContain('adapter')
    expect(unprovisioned).toContain('not found on the remote PATH')
  })

  it('names the remote PATH, because that is nearly always the real cause', () => {
    // Non-interactive ssh gets a different PATH from a login shell, so
    // nvm/asdf/mise-managed CLIs are simply absent. "It works in my ssh
    // terminal" is the support question this line answers.
    expect(targetRefusal(capabilities, ['agy'])).toContain('/usr/local/bin:/usr/bin:/bin')
  })

  it('distinguishes installed-but-unconfigured from missing', () => {
    const refusal = targetRefusal(
      {
        ...capabilities,
        availableVendors: ['claude'],
        vendorDetails: {
          ...capabilities.vendorDetails,
          codex: {
            executable: '/usr/bin/codex',
            version: '0.145.0',
            configured: false,
            permissionMode: null,
          },
        },
      },
      ['codex'],
    )
    expect(refusal).toContain('/usr/bin/codex')
    expect(refusal).toContain('sign in')
  })
})

describe('what is worth saying about a host on its own', () => {
  it('warns when git is missing, because no run could fetch its snapshot', () => {
    expect(hostWarnings({ ...capabilities, git: null }).join(' ')).toContain('git')
  })

  it('surfaces a permissive agent posture rather than leaving it in the adapter', () => {
    // A host whose agy executes allow-listed tools without asking is a
    // materially different host to run on, and that belongs in preflight.
    const warnings = hostWarnings({
      ...capabilities,
      availableVendors: ['claude', 'codex', 'agy'],
      vendorDetails: {
        ...capabilities.vendorDetails,
        agy: {
          executable: '/usr/bin/agy',
          version: '1.1.8',
          configured: true,
          permissionMode: 'allow',
        },
      },
    })
    expect(warnings.join(' ')).toContain('agy')
    expect(warnings.join(' ')).toContain('without prompting')
  })

  it('says nothing alarming about a healthy host', () => {
    expect(
      hostWarnings({ ...capabilities, supportedVendors: ['claude', 'codex'] }),
    ).toEqual([])
  })
})
