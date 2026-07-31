import { describe, expect, it } from 'vitest'
import {
  controlledGitEnv,
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  type RemoteCapabilities,
} from '@shared/remote'
import { runtimeMismatch, statusVerdict, type StatusFacts } from './status'

const HASH = 'a'.repeat(64)
const OTHER = 'b'.repeat(64)

const capabilities: RemoteCapabilities = {
  protocolVersion: REMOTE_PROTOCOL_VERSION,
  buildId: HASH,
  nodeVersion: 'v24.4.1',
  nodeExecutable: '/usr/bin/node',
  capabilities: [...REQUIRED_CAPABILITIES],
  supportedVendors: ['claude', 'codex'],
  availableVendors: ['claude', 'codex'],
  vendorDetails: {
    claude: { executable: '/usr/bin/claude', version: '2.1', configured: true, permissionMode: 'ask' },
    codex: { executable: '/usr/bin/codex', version: '0.1', configured: true, permissionMode: null },
  },
  user: 'build',
  home: '/home/build',
  path: '/usr/bin:/bin',
  git: '2.45.0',
  runsRoot: '/home/build/.local/share/parley/runs',
}

function facts(over: Partial<StatusFacts> = {}): StatusFacts {
  return {
    activeTarget: '/home/build/.local/lib/parley/remote/' + HASH + '/parley-remote.mjs',
    directoryBuildId: HASH,
    calculatedHash: HASH,
    capabilities,
    nodeCommand: 'node',
    nodeUsable: true,
    previousAvailable: true,
    ...over,
  }
}

describe('the verdict', () => {
  it('is healthy when the three identities agree and the host is complete', () => {
    const status = statusVerdict(facts())
    expect(status.health).toBe('healthy')
    expect(status.reasons).toEqual([])
  })

  it('reports not-installed before anything else', () => {
    // Nothing else is worth asking about a host with no runner, and asking
    // would produce a confident answer about a file that is not there.
    const status = statusVerdict(facts({ activeTarget: null, capabilities: null, nodeUsable: false }))
    expect(status.health).toBe('not-installed')
  })

  it('calls it corrupt when the directory name and the bytes disagree', () => {
    const status = statusVerdict(facts({ calculatedHash: OTHER }))
    expect(status.health).toBe('corrupt')
    expect(status.reasons[0]).toContain('bbbbbbbbbbbb')
    expect(status.reasons[0]).toContain('aaaaaaaaaaaa')
  })

  it('calls it corrupt when the runner reports a build its file does not hash to', () => {
    const status = statusVerdict(
      facts({ capabilities: { ...capabilities, buildId: OTHER } }),
    )
    expect(status.health).toBe('corrupt')
    expect(status.reasons.join(' ')).toContain('reports build')
  })

  it('does NOT call an intact bundle corrupt when node cannot run it', () => {
    // Telling someone their install is corrupt would send them to reinstall a
    // file that is exactly right. The runtime is what is wrong.
    const status = statusVerdict(facts({ nodeUsable: false, capabilities: null }))
    expect(status.health).toBe('incompatible')
    expect(status.reasons.join(' ')).toContain('node command')
    expect(status.reasons.join(' ')).toContain('absolute node path')
  })

  it('calls a protocol mismatch incompatible', () => {
    const status = statusVerdict(
      facts({ capabilities: { ...capabilities, protocolVersion: 99 } }),
    )
    expect(status.health).toBe('incompatible')
    expect(status.reasons[0]).toContain('v99')
  })

  it('calls a runner below the node floor incompatible', () => {
    const status = statusVerdict(
      facts({ capabilities: { ...capabilities, nodeVersion: 'v16.20.0' } }),
    )
    expect(status.health).toBe('incompatible')
    expect(status.reasons[0]).toContain('v16.20.0')
  })

  it('calls a valid runner on an incomplete host degraded', () => {
    // The runner is fine; the host cannot do everything. That distinction is
    // the whole reason these are separate states.
    const status = statusVerdict(
      facts({
        capabilities: {
          ...capabilities,
          availableVendors: ['claude'],
          vendorDetails: {
            ...capabilities.vendorDetails,
            codex: { executable: null, version: null, configured: false, permissionMode: null },
          },
        },
      }),
    )
    expect(status.health).toBe('degraded')
    expect(status.reasons.join(' ')).toContain('codex')
  })

  it('degrades on a permissive agent posture rather than staying quiet', () => {
    const status = statusVerdict(
      facts({
        capabilities: {
          ...capabilities,
          supportedVendors: ['claude', 'codex', 'agy'],
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
        },
      }),
    )
    expect(status.health).toBe('degraded')
    expect(status.reasons.join(' ')).toContain('without prompting')
  })

  it('keeps the priority order when several things are wrong at once', () => {
    // Corrupt outranks incompatible outranks degraded: a bundle whose identity
    // is in doubt makes every later question meaningless.
    const status = statusVerdict(
      facts({
        calculatedHash: OTHER,
        capabilities: { ...capabilities, protocolVersion: 99, availableVendors: [] },
      }),
    )
    expect(status.health).toBe('corrupt')
  })
})

describe('which runtime actually answered', () => {
  it('says nothing when the target simply configured "node"', () => {
    // Comparing the string `node` against a resolved execPath would flag every
    // correctly configured host on earth.
    expect(runtimeMismatch('node', '/usr/local/bin/node')).toBeNull()
  })

  it('reports a real difference when an absolute path was configured', () => {
    expect(runtimeMismatch('/opt/node20/bin/node', '/usr/bin/node')).toContain('/opt/node20')
  })

  it('is quiet when the absolute path is the one that ran', () => {
    expect(runtimeMismatch('/opt/node20/bin/node', '/opt/node20/bin/node')).toBeNull()
  })
})

describe('the environment repository commands run in', () => {
  it('drops every inherited GIT_ variable', () => {
    // An ssh session that arrives with GIT_DIR exported — a login script, a CI
    // agent, a wrapper written years ago — would silently redirect every
    // repository command the runner makes, and it would report confidently
    // about the wrong repository.
    const env = controlledGitEnv(
      {
        PATH: '/usr/bin',
        HOME: '/home/build',
        GIT_DIR: '/somewhere/else/.git',
        GIT_WORK_TREE: '/somewhere/else',
        GIT_INDEX_FILE: '/tmp/index',
        GIT_CONFIG_COUNT: '1',
        GIT_CONFIG_KEY_0: 'core.hooksPath',
        GIT_CONFIG_VALUE_0: '/tmp/hooks',
        GIT_SSH_COMMAND: 'ssh -o StrictHostKeyChecking=no',
        GIT_ALTERNATE_OBJECT_DIRECTORIES: '/tmp/objects',
      },
      { GIT_DIR: '/runs/01J/.git' },
    )
    expect(env.GIT_WORK_TREE).toBeUndefined()
    expect(env.GIT_INDEX_FILE).toBeUndefined()
    expect(env.GIT_CONFIG_COUNT).toBeUndefined()
    expect(env.GIT_CONFIG_KEY_0).toBeUndefined()
    expect(env.GIT_SSH_COMMAND).toBeUndefined()
    expect(env.GIT_ALTERNATE_OBJECT_DIRECTORIES).toBeUndefined()
    // What the runner itself set survives — it goes on last.
    expect(env.GIT_DIR).toBe('/runs/01J/.git')
    expect(env.PATH).toBe('/usr/bin')
    expect(env.HOME).toBe('/home/build')
  })

  it('neutralises repository-supplied configuration', () => {
    // A snapshot from another machine must not get to run hooks on this host
    // as a side effect of being checked out.
    const env = controlledGitEnv({ PATH: '/usr/bin' }, {})
    expect(env.GIT_CONFIG_GLOBAL).toBe('/dev/null')
    expect(env.GIT_CONFIG_SYSTEM).toBe('/dev/null')
    expect(env.GIT_TERMINAL_PROMPT).toBe('0')
  })
})
