import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { REMOTE_PROTOCOL_VERSION } from '@shared/remote'
import { BOOTSTRAP_SOURCE, bootstrapArgument, INSTALL_ROOT, isBoringPath } from './bootstrap'
import {
  bootstrapArgv,
  decodeBootstrapReply,
  newNonce,
  sftpArgv,
  sftpBatch,
  stagingFor,
  type BootstrapRequest,
} from './install'

/**
 * Installation, with the bootstrap actually executed.
 *
 * The interesting assertions are of two kinds. First, that no dynamic value
 * ever reaches an ssh command line — that is the invariant the whole design
 * exists to hold, and it is checkable by inspection of the argv we build.
 * Second, that the bootstrap really refuses what it claims to refuse, which is
 * only checkable by running it against real directories, since its whole job
 * is resolving and comparing paths on a filesystem.
 */

const repoRoot = resolve(__dirname, '..', '..', '..')
let home: string
let bundle: string
let bundleHash: string

beforeAll(() => {
  execFileSync(process.execPath, [join(repoRoot, 'scripts', 'build-remote.mjs')], {
    cwd: repoRoot,
    stdio: 'pipe',
  })
  home = mkdtempSync(join(tmpdir(), 'parley-install-home-'))
  bundle = join(repoRoot, 'out', 'remote', 'parley-remote.mjs')
  bundleHash = createHash('sha256').update(readFileSync(bundle)).digest('hex')
}, 120_000)

afterAll(() => rmSync(home, { recursive: true, force: true }))

/** Runs the bootstrap exactly as ssh would: fixed program, request on stdin. */
function runBootstrap(request: BootstrapRequest, at = home) {
  const result = spawnSync(
    process.execPath,
    ['-e', `eval(Buffer.from("${Buffer.from(BOOTSTRAP_SOURCE, 'utf8').toString('base64')}","base64").toString())`],
    {
      input: `${JSON.stringify(request)}\n`,
      encoding: 'utf8',
      timeout: 90_000,
      env: { ...process.env, HOME: at },
    },
  )
  return { reply: decodeBootstrapReply(result.stdout ?? ''), status: result.status, raw: result }
}

/** Stages a file the way SFTP would have, so activation has something to move. */
function stage(contents: Buffer, at = home): { nonce: string; relativePath: string } {
  const nonce = newNonce()
  const paths = stagingFor(nonce)
  mkdirSync(join(at, paths.stagingDir), { recursive: true })
  writeFileSync(join(at, paths.stagedBundle), contents)
  return { nonce, relativePath: paths.stagedBundle }
}

describe('nothing dynamic reaches an ssh command line', () => {
  it('keeps the bootstrap argv entirely constant', () => {
    const argv = bootstrapArgv({ host: 'build-01' })
    // The path just uploaded, the hash, the operation: none of them appear.
    const flat = argv.join(' ')
    expect(flat).not.toContain('.install-')
    expect(flat).not.toContain(bundleHash)
    expect(argv).toEqual(bootstrapArgv({ host: 'build-01' }))
  })

  it('encodes the program so the remote shell has nothing to act on', () => {
    const argument = bootstrapArgument()
    // Single-quoted, and the interior is base64 inside a fixed wrapper — no
    // apostrophe can appear, so no future edit can break the quoting.
    expect(argument.startsWith("'")).toBe(true)
    expect(argument.endsWith("'")).toBe(true)
    expect(argument.slice(1, -1)).not.toContain("'")
    expect(argument).not.toMatch(/\s/)
  })

  it('refuses a node command that is not boring', () => {
    // The one value a target may vary here, and it is user configuration
    // rather than run data — but it still goes through the grammar.
    expect(() => bootstrapArgv({ host: 'h' }, 'node; rm -rf /')).toThrow()
    expect(() => bootstrapArgv({ host: 'h' }, '$(evil)')).toThrow()
    expect(bootstrapArgv({ host: 'h' }, '/opt/node20/bin/node')).toContain('/opt/node20/bin/node')
  })

  it('uses sftp rather than scp, with the batch on stdin', () => {
    const argv = sftpArgv({ host: 'build-01' })
    // scp only speaks SFTP by default from OpenSSH 9.0, and -O puts it back to
    // remote-shell path handling. Saying sftp avoids depending on either.
    expect(argv).toContain('-b')
    expect(argv).toContain('-')
    expect(argv).not.toContain('-O')
    expect(argv.join(' ')).not.toContain('parley-remote.mjs')
  })
})

describe('the sftp batch', () => {
  it('stages beside the final directory, never in /tmp', () => {
    // rename(2) is atomic only within a filesystem. Staging in /tmp would give
    // an activation that looks atomic, reads as atomic, and is not.
    const paths = stagingFor('abc123')
    expect(paths.stagingDir.startsWith(INSTALL_ROOT)).toBe(true)
    expect(paths.stagingDir).not.toContain('tmp')
  })

  it('tolerates existing parents but aborts on a real failure', () => {
    const batch = sftpBatch('/local/parley-remote.mjs', stagingFor('abc123'))
    // Leading '-' means "this one may fail"; the put must not have it.
    expect(batch).toContain('-mkdir .local/lib/parley/remote')
    expect(batch).toMatch(/\nmkdir \.local\/lib\/parley\/remote\/\.install-abc123\n/)
    expect(batch).toMatch(/\nput \/local\/parley-remote\.mjs /)
    expect(batch.trimEnd().endsWith('quit')).toBe(true)
  })

  it('refuses to build a batch for a path that is not boring', () => {
    expect(() => sftpBatch('/local/x.mjs', { ...stagingFor('a'), stagedBundle: '../escape' })).toThrow()
  })
})

describe('the path grammar', () => {
  it('accepts the paths an install actually uses', () => {
    expect(isBoringPath('.local/lib/parley/remote/.install-ab12/parley-remote.mjs')).toBe(true)
  })

  it('rejects everything that could be read as structure', () => {
    for (const path of [
      '/etc/passwd',
      '../../etc/passwd',
      '.local/../../escape',
      '~/parley',
      'with space/x',
      'back\\slash',
      'quote"d',
      "quote'd",
      'semi;colon',
      '$(command)',
      'new\nline',
    ]) {
      expect(isBoringPath(path)).toBe(false)
    }
  })
})

describe('the bootstrap refuses what it claims to', () => {
  it('rejects a traversal, an absolute path and anything outside the root', () => {
    for (const relativePath of ['../escape', '/etc/passwd', '.ssh/authorized_keys']) {
      const { reply } = runBootstrap({
        operation: 'verify-and-handshake',
        relativePath,
        expectedHash: bundleHash,
        protocolVersion: REMOTE_PROTOCOL_VERSION,
      })
      expect(reply?.ok).toBe(false)
    }
  })

  it('refuses to execute a bundle whose hash does not match', () => {
    // The gate that makes the upload trustworthy: bytes that are not what we
    // built never get run, so a truncated transfer or a tampered file cannot
    // reach the handshake.
    const { relativePath } = stage(Buffer.from('console.log("not the bundle")\n'))
    const { reply } = runBootstrap({
      operation: 'verify-and-handshake',
      relativePath,
      expectedHash: bundleHash,
      protocolVersion: REMOTE_PROTOCOL_VERSION,
    })
    expect(reply?.ok).toBe(false)
    expect(reply?.error).toContain('does not match')
  })

  it('refuses an unknown operation rather than doing something adjacent', () => {
    const { reply } = runBootstrap({ operation: 'run-anything' } as never)
    expect(reply?.ok).toBe(false)
    expect(reply?.error).toContain('unknown operation')
  })

  it('refuses to activate a build id that is not a sha256', () => {
    const { relativePath } = stage(readFileSync(bundle))
    const { reply } = runBootstrap({ operation: 'activate', relativePath, buildId: 'latest' })
    expect(reply?.ok).toBe(false)
  })

  it('answers on stdout as one JSON line, with nothing raw', () => {
    const { raw } = runBootstrap({ operation: 'unknown' } as never)
    const lines = (raw.stdout ?? '').split('\n').filter((line) => line.trim().length > 0)
    expect(lines).toHaveLength(1)
    expect(() => JSON.parse(lines[0]!)).not.toThrow()
  })
})

describe('verify, then activate', () => {
  it('hashes the upload and runs its handshake before anything is activated', () => {
    const { relativePath } = stage(readFileSync(bundle))
    const { reply } = runBootstrap({
      operation: 'verify-and-handshake',
      relativePath,
      expectedHash: bundleHash,
      protocolVersion: REMOTE_PROTOCOL_VERSION,
    })
    expect(reply?.ok).toBe(true)
    expect(reply?.hash).toBe(bundleHash)
    // The handshake came from the STAGED bundle, before it became active.
    expect(reply?.handshake).toContain('"type":"ready"')
    expect(reply?.handshake).toContain(bundleHash)
    expect(existsSync(join(home, '.local/bin/parley-remote'))).toBe(false)
  }, 90_000)

  it('activates by renaming inside the root and swapping the symlink', () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-activate-'))
    const { relativePath } = stage(readFileSync(bundle), at)
    const { reply } = runBootstrap({ operation: 'activate', relativePath, buildId: bundleHash }, at)
    expect(reply?.ok).toBe(true)

    const link = join(at, '.local/bin/parley-remote')
    expect(readlinkSync(link)).toBe(join(at, INSTALL_ROOT, bundleHash, 'parley-remote.mjs'))
    // The staging directory became the versioned one; nothing was copied.
    expect(existsSync(join(at, relativePath))).toBe(false)
    rmSync(at, { recursive: true, force: true })
  })

  it('keeps the previous build and can roll back to it', () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-rollback-'))
    // An older install, as if it had been there all along.
    const older = join(at, INSTALL_ROOT, 'a'.repeat(64))
    mkdirSync(older, { recursive: true })
    writeFileSync(join(older, 'parley-remote.mjs'), '// older\n')
    mkdirSync(join(at, '.local/bin'), { recursive: true })
    symlinkSync(join(older, 'parley-remote.mjs'), join(at, '.local/bin/parley-remote'))

    const { relativePath } = stage(readFileSync(bundle), at)
    const activated = runBootstrap({ operation: 'activate', relativePath, buildId: bundleHash }, at)
    expect(activated.reply?.previous).toBe(join(older, 'parley-remote.mjs'))

    const rolled = runBootstrap({ operation: 'rollback' }, at)
    expect(rolled.reply?.ok).toBe(true)
    expect(readlinkSync(join(at, '.local/bin/parley-remote'))).toBe(
      join(older, 'parley-remote.mjs'),
    )
    // The build rolled away from is still on disk: rollback is reversible too.
    expect(existsSync(join(at, INSTALL_ROOT, bundleHash))).toBe(true)
    rmSync(at, { recursive: true, force: true })
  })

  it('refuses to roll back when there is nothing to roll back to', () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-norollback-'))
    mkdirSync(join(at, INSTALL_ROOT), { recursive: true })
    const { reply } = runBootstrap({ operation: 'rollback' }, at)
    expect(reply?.ok).toBe(false)
    expect(reply?.error).toContain('no previous build')
    rmSync(at, { recursive: true, force: true })
  })

  it('leaves an existing installation untouched when the upload never lands', () => {
    // The SFTP-failed case: nothing was staged, so activation finds nothing
    // and must not disturb what is already active.
    const at = mkdtempSync(join(tmpdir(), 'parley-install-untouched-'))
    const older = join(at, INSTALL_ROOT, 'b'.repeat(64))
    mkdirSync(older, { recursive: true })
    writeFileSync(join(older, 'parley-remote.mjs'), '// older\n')
    mkdirSync(join(at, '.local/bin'), { recursive: true })
    symlinkSync(join(older, 'parley-remote.mjs'), join(at, '.local/bin/parley-remote'))

    const { reply } = runBootstrap(
      { operation: 'activate', relativePath: stagingFor('missing').stagedBundle, buildId: bundleHash },
      at,
    )
    expect(reply?.ok).toBe(false)
    expect(readlinkSync(join(at, '.local/bin/parley-remote'))).toBe(
      join(older, 'parley-remote.mjs'),
    )
    rmSync(at, { recursive: true, force: true })
  })
})

describe('concurrent installs', () => {
  it('leaves exactly one valid active link', async () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-race-'))
    const staged = [1, 2, 3].map(() => stage(readFileSync(bundle), at))
    // Three activations of the same build racing for the lock. Whatever the
    // interleaving, the link must end up pointing at something real.
    await Promise.all(
      staged.map(
        (entry) =>
          new Promise<void>((done) => {
            runBootstrap(
              { operation: 'activate', relativePath: entry.relativePath, buildId: bundleHash },
              at,
            )
            done()
          }),
      ),
    )
    const link = join(at, '.local/bin/parley-remote')
    expect(existsSync(link)).toBe(true)
    expect(existsSync(readlinkSync(link))).toBe(true)
    rmSync(at, { recursive: true, force: true })
  }, 60_000)
})
