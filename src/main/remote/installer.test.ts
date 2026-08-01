import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installRemote, rollbackRemote } from './installer'

/**
 * Installation, with fake sftp and ssh that are real processes.
 *
 * The ordering is the safety property — bytes land, the host hashes them, the
 * STAGED copy answers a handshake, and only then is it activated — so these
 * tests observe the order rather than asserting it. Each fake appends what it
 * was asked to do to a log, and the log is what gets checked.
 */

const root = mkdtempSync(join(tmpdir(), 'parley-installer-'))
afterAll(() => rmSync(root, { recursive: true, force: true }))

const repoRoot = resolve(__dirname, '..', '..', '..')
let bundlePath: string
let buildId: string

beforeAll(() => {
  execFileSync(process.execPath, [join(repoRoot, 'scripts', 'build-remote.mjs')], {
    cwd: repoRoot,
    stdio: 'pipe',
  })
  bundlePath = join(repoRoot, 'out', 'remote', 'parley-remote.mjs')
  buildId = createHash('sha256').update(readFileSync(bundlePath)).digest('hex')
}, 120_000)

const log = (): string => join(root, 'log.txt')

/** A fake binary that records its invocation and answers however it is told. */
function fake(name: string, body: string): string {
  const path = join(root, `${name}.mjs`)
  writeFileSync(
    path,
    `#!/usr/bin/env node
import { appendFileSync } from 'node:fs'
let input = ''
process.stdin.on('data', (c) => { input += c })
process.stdin.on('end', () => {
  const note = (what) => appendFileSync(${JSON.stringify(log())}, what + String.fromCharCode(10))
${body}
})
`,
    'utf8',
  )
  chmodSync(path, 0o755)
  return path
}

const goodSftp = (): string =>
  fake('sftp-ok', `  note('sftp:' + (input.includes('put ') ? 'put' : 'nothing'))\n  process.exit(0)`)

/** An ssh that answers both bootstrap operations the way a healthy host would. */
function goodSsh(hash: () => string): string {
  return fake(
    'ssh-ok',
    `  const request = JSON.parse(input)
  note('ssh:' + request.operation)
  if (request.operation === 'verify-and-handshake') {
    const ready = JSON.stringify({
      protocolVersion: 1, runId: 'install', sequence: 1,
      body: { type: 'ready', capabilities: {
        protocolVersion: 1, buildId: ${JSON.stringify(hash())}, nodeVersion: 'v24.4.1',
        nodeExecutable: '/usr/bin/node', capabilities: [], supportedVendors: [],
        availableVendors: [], vendorDetails: {}, user: 'build', home: '/home/build',
        path: '/usr/bin', git: '2.45.0', runsRoot: '/runs',
      } },
    })
    process.stdout.write(JSON.stringify({ ok: true, hash: request.expectedHash, handshake: ready + String.fromCharCode(10) }) + String.fromCharCode(10))
  } else {
    process.stdout.write(JSON.stringify({ ok: true, active: '/home/build/.local/bin/parley-remote', previous: null }) + String.fromCharCode(10))
  }
  process.exit(0)`,
  )
}

function readLog(): string[] {
  return existsSync(log())
    ? readFileSync(log(), 'utf8').split('\n').filter(Boolean)
    : []
}

const target = { host: 'build-01' }

describe('a healthy install', () => {
  it('uploads, verifies, handshakes the staged copy, then activates — in that order', async () => {
    rmSync(log(), { force: true })
    const outcome = await installRemote(target, {
      bundlePath,
      sftpBinary: goodSftp(),
      sshBinary: goodSsh(() => buildId),
    })
    expect(outcome.ok).toBe(true)
    expect(outcome.buildId).toBe(buildId)
    expect(outcome.nodeVersion).toBe('v24.4.1')
    // The order IS the safety property: a bundle that cannot run must never
    // become the one that runs.
    expect(readLog()).toEqual(['sftp:put', 'ssh:verify-and-handshake', 'ssh:activate'])
  }, 60_000)
})

describe('installs that must not activate', () => {
  it('stops when the upload fails, without touching what is installed', async () => {
    rmSync(log(), { force: true })
    const badSftp = fake(
      'sftp-fail',
      `  note('sftp:failed')
  process.stderr.write('Permission denied (publickey).' + String.fromCharCode(10))
  process.exit(1)`,
    )
    const outcome = await installRemote(target, {
      bundlePath,
      sftpBinary: badSftp,
      sshBinary: goodSsh(() => buildId),
    })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('Permission denied')
    expect(readLog()).toEqual(['sftp:failed'])
  }, 60_000)

  it('stops when the host says the bytes are not what we built', async () => {
    rmSync(log(), { force: true })
    const rejecting = fake(
      'ssh-badhash',
      `  const request = JSON.parse(input)
  note('ssh:' + request.operation)
  process.stdout.write(JSON.stringify({ ok: false, error: 'uploaded bundle hash aaa does not match ' + request.expectedHash }) + String.fromCharCode(10))
  process.exit(1)`,
    )
    const outcome = await installRemote(target, {
      bundlePath,
      sftpBinary: goodSftp(),
      sshBinary: rejecting,
    })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('does not match')
    // Never reached activate.
    expect(readLog()).toEqual(['sftp:put', 'ssh:verify-and-handshake'])
  }, 60_000)

  it('stops when the uploaded runner hashes correctly but will not start', async () => {
    // The case activation would be worst for: replacing a working install
    // with one that does not run.
    rmSync(log(), { force: true })
    const mute = fake(
      'ssh-mute',
      `  const request = JSON.parse(input)
  note('ssh:' + request.operation)
  process.stdout.write(JSON.stringify({ ok: true, hash: request.expectedHash, handshake: '', handshakeStderr: 'SyntaxError: Unexpected token' }) + String.fromCharCode(10))
  process.exit(0)`,
    )
    const outcome = await installRemote(target, {
      bundlePath,
      sftpBinary: goodSftp(),
      sshBinary: mute,
    })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('did not answer a handshake')
    expect(outcome.detail).toContain('SyntaxError')
    expect(readLog()).toEqual(['sftp:put', 'ssh:verify-and-handshake'])
  }, 60_000)

  it('refuses a runner that speaks another protocol', async () => {
    rmSync(log(), { force: true })
    const outcome = await installRemote(target, {
      bundlePath,
      sftpBinary: goodSftp(),
      sshBinary: fake(
        'ssh-oldproto',
        `  const request = JSON.parse(input)
  note('ssh:' + request.operation)
  const ready = JSON.stringify({ protocolVersion: 1, runId: 'i', sequence: 1, body: { type: 'ready', capabilities: {
    protocolVersion: 99, buildId: 'x'.repeat(64), nodeVersion: 'v24', nodeExecutable: '/n',
    capabilities: [], supportedVendors: [], availableVendors: [], vendorDetails: {},
    user: 'b', home: '/h', path: '/p', git: '2', runsRoot: '/r' } } })
  process.stdout.write(JSON.stringify({ ok: true, handshake: ready + String.fromCharCode(10) }) + String.fromCharCode(10))
  process.exit(0)`,
      ),
    })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('v99')
    expect(readLog()).not.toContain('ssh:activate')
  }, 60_000)

  it('explains a missing node instead of reporting an exit code', async () => {
    // The failure people actually hit. A host where `node` works perfectly in
    // an interactive terminal answers 127 to a non-interactive session.
    const outcome = await installRemote(
      { ...target, nodeCommand: 'node' },
      {
        bundlePath,
        sftpBinary: goodSftp(),
        sshBinary: fake(
          'ssh-nonode',
          `  process.stderr.write('bash: node: command not found' + String.fromCharCode(10))
  process.exit(127)`,
        ),
      },
    )
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('nvm, asdf and mise')
    expect(outcome.detail).toContain('absolute node path')
  }, 60_000)

  it('says what to do when nothing has been built yet', async () => {
    const outcome = await installRemote(target, { bundlePath: join(root, 'nope.mjs') })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('build:remote')
  })
})

describe('rollback', () => {
  it('asks the host to restore the previous build', async () => {
    rmSync(log(), { force: true })
    const outcome = await rollbackRemote(target, {
      sshBinary: fake(
        'ssh-rollback',
        `  note('ssh:' + JSON.parse(input).operation)
  process.stdout.write(JSON.stringify({ ok: true, restored: '/home/build/.local/lib/parley/remote/aaa/parley-remote.mjs' }) + String.fromCharCode(10))
  process.exit(0)`,
      ),
    })
    expect(outcome.ok).toBe(true)
    expect(readLog()).toEqual(['ssh:rollback'])
  }, 60_000)

  it('reports when there is nothing to roll back to', async () => {
    const outcome = await rollbackRemote(target, {
      sshBinary: fake(
        'ssh-norollback',
        `  process.stdout.write(JSON.stringify({ ok: false, error: 'no previous build to roll back to' }) + String.fromCharCode(10))
  process.exit(1)`,
      ),
    })
    expect(outcome.ok).toBe(false)
    expect(outcome.detail).toContain('no previous build')
  }, 60_000)
})
