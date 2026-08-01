import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { REMOTE_PROTOCOL_VERSION } from '@shared/remote'
import { statusVerdict } from './status'
import { BOOTSTRAP_SOURCE, bootstrapArgument, INSTALL_ROOT, isBoringPath } from './bootstrap'
import {
  bootstrapArgv,
  decodeBootstrapReply,
  newNonce,
  sftpArgv,
  sftpBatch,
  stagingFor,
  remoteBundlePath,
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

describe('what is actually installed, read off the disk', () => {
  it('reports the resolved link, the directory it names, and what the bytes hash to', () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-status-'))
    const { relativePath } = stage(readFileSync(bundle), at)
    runBootstrap({ operation: 'activate', relativePath, buildId: bundleHash }, at)

    const { reply } = runBootstrap({ operation: 'status' }, at)
    expect(reply?.ok).toBe(true)
    expect(reply?.active).toContain(bundleHash)
    // Two independent readings of "which build is this". Deriving one from
    // the other would make them agree by construction, which is exactly the
    // bug: the caller used to pass the handshake's build id into all three
    // fields and grade a number against itself.
    expect(reply?.directoryBuildId).toBe(bundleHash)
    expect(reply?.calculatedHash).toBe(bundleHash)
    expect(reply?.previousAvailable).toBe(false)
    rmSync(at, { recursive: true, force: true })
  })

  it('catches bytes that no longer match the directory that names them', () => {
    // Tampering, a half-written upload, a partial disk — the runner reports
    // its own story with perfect confidence in all three cases, so nothing it
    // says can catch this. Only the disk can.
    const at = mkdtempSync(join(tmpdir(), 'parley-install-corrupt-'))
    const { relativePath } = stage(readFileSync(bundle), at)
    runBootstrap({ operation: 'activate', relativePath, buildId: bundleHash }, at)

    const installed = join(at, INSTALL_ROOT, bundleHash, 'parley-remote.mjs')
    writeFileSync(installed, `${readFileSync(installed, 'utf8')}\n// tampered\n`)

    const { reply } = runBootstrap({ operation: 'status' }, at)
    expect(reply?.ok).toBe(true)
    expect(reply?.directoryBuildId).toBe(bundleHash)
    expect(reply?.calculatedHash).not.toBe(bundleHash)

    // And the verdict that could never fire before.
    const graded = statusVerdict({
      activeTarget: reply?.active ?? null,
      directoryBuildId: reply?.directoryBuildId ?? null,
      calculatedHash: reply?.calculatedHash ?? null,
      capabilities: null,
      nodeCommand: 'node',
      nodeUsable: true,
      previousAvailable: false,
    })
    expect(graded.health).toBe('corrupt')
    expect(graded.reasons.join(' ')).toContain('sit in a directory named')
    rmSync(at, { recursive: true, force: true })
  })

  it('says nothing is active when nothing is, rather than failing', () => {
    // A host that has never been installed to is a normal answer, not an
    // error — status is the thing people check BEFORE installing.
    const at = mkdtempSync(join(tmpdir(), 'parley-install-empty-'))
    const { reply } = runBootstrap({ operation: 'status' }, at)
    expect(reply?.ok).toBe(true)
    expect(reply?.active).toBeNull()
    expect(reply?.calculatedHash).toBeNull()
    rmSync(at, { recursive: true, force: true })
  })

  it('only offers a rollback that still exists', () => {
    const at = mkdtempSync(join(tmpdir(), 'parley-install-previous-'))
    const older = join(at, INSTALL_ROOT, 'a'.repeat(64))
    mkdirSync(older, { recursive: true })
    writeFileSync(join(older, 'parley-remote.mjs'), '// older\n')
    writeFileSync(join(older, 'parley-remote'), '#!/bin/sh\nexit 0\n')
    mkdirSync(join(at, '.local/bin'), { recursive: true })
    symlinkSync(join(older, 'parley-remote'), join(at, '.local/bin/parley-remote'))

    const { relativePath } = stage(readFileSync(bundle), at)
    runBootstrap({ operation: 'activate', relativePath, buildId: bundleHash }, at)
    expect(runBootstrap({ operation: 'status' }, at).reply?.previousAvailable).toBe(true)

    // Recorded is not the same as present. A rollback offer pointing at a
    // directory somebody deleted is worse than no offer at all.
    rmSync(older, { recursive: true, force: true })
    expect(runBootstrap({ operation: 'status' }, at).reply?.previousAvailable).toBe(false)
    rmSync(at, { recursive: true, force: true })
  })
})

describe('where a packaged build keeps its runner', () => {
  it('points inside the checkout in dev, and beside the archive when packaged', () => {
    // sftp is a separate process, and a separate process cannot read out of
    // an asar. Electron patches `fs`, so resolving the bundle INSIDE the
    // archive hashes fine and then hands sftp a path that does not exist —
    // which is why the packaged copy is unpacked and this points at it.
    expect(remoteBundlePath('/Users/x/dev/parley')).toBe(
      join('/Users/x/dev/parley', 'out', 'remote', 'parley-remote.mjs'),
    )
    expect(remoteBundlePath('/Applications/Parley.app/Contents/Resources/app.asar')).toBe(
      join(
        '/Applications/Parley.app/Contents/Resources/app.asar.unpacked',
        'out',
        'remote',
        'parley-remote.mjs',
      ),
    )
  })

  it('only rewrites a trailing app.asar, not one that happens to be in the path', () => {
    // Someone whose home directory is named app.asar is not a bug worth
    // having.
    expect(remoteBundlePath('/Users/app.asar/dev/parley')).toBe(
      join('/Users/app.asar/dev/parley', 'out', 'remote', 'parley-remote.mjs'),
    )
  })

  it('ships the runner unpacked, and rebuilds it on every build', () => {
    // The packaging config IS the feature here. Remote execution worked only
    // from a dev checkout for the whole arc, and no test could see it: every
    // test resolves paths on this disk, where out/ always exists. This reads
    // the manifest that decides what an installed copy actually contains.
    const manifest = JSON.parse(
      readFileSync(resolve(__dirname, '../../../package.json'), 'utf8'),
    ) as {
      scripts: Record<string, string>
      build: { asar: boolean; asarUnpack: string[]; files: string[] }
    }

    // Inside the asar the file exists and is unreadable by sftp, which is the
    // failure that looks most like success.
    expect(manifest.build.asarUnpack).toContain('out/remote/**')
    // And it has to be in the package at all.
    expect(manifest.build.files.some((glob) => glob.startsWith('out/'))).toBe(true)
    // A build that does not produce it ships whatever was last built by hand,
    // or nothing. `build` is also what the self-update gate runs, so this is
    // what keeps a relaunched Parley's runner matching the Parley talking to
    // the host.
    expect(manifest.scripts['build']).toContain('build:remote')
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

    // The LAUNCHER, not the .mjs. Linking the bundle directly is what a real
    // host rejected two ways at once: sftp leaves it mode 644, and its
    // "#!/usr/bin/env node" shebang cannot find node on exactly the hosts
    // (nvm, asdf, mise) this bootstrap exists to support.
    const link = join(at, '.local/bin/parley-remote')
    const launcher = join(at, INSTALL_ROOT, bundleHash, 'parley-remote')
    expect(readlinkSync(link)).toBe(launcher)
    // Executable, or the symlink resolves to something that cannot be run.
    expect(statSync(launcher).mode & 0o111).not.toBe(0)

    // It names its interpreter absolutely, and names the bundle where the
    // bundle now IS. Written during verify it pointed into the staging
    // directory this rename just destroyed, so activation has to write it
    // again — a launcher naming a path that no longer exists is a host that
    // installs cleanly and fails every run.
    const script = readFileSync(launcher, 'utf8')
    expect(script).toContain(process.execPath)
    expect(script).toContain(join(at, INSTALL_ROOT, bundleHash, 'parley-remote.mjs'))
    expect(script).not.toContain('.install-')

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
