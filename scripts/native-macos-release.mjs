#!/usr/bin/env node

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  closeSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, isAbsolute, join, resolve } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import http from 'node:http'

import {
  BUNDLE_IDENTIFIER,
  MINIMUM_SYSTEM_VERSION,
  packageNativeMacOS,
  validateBundleStructure,
} from './native-macos-package.mjs'

export const SOURCE_REPOSITORY = 'https://github.com/markjoyeuxcom/parley'
export const PURGE_CONFIRMATION = 'DELETE PARLEY DATA'

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    stdio: options.capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
    ...options,
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    const detail = options.capture ? `${result.stdout ?? ''}${result.stderr ?? ''}`.trim() : ''
    throw new Error(`${command} exited with status ${result.status}${detail ? `:\n${detail}` : ''}`)
  }
  return options.capture ? result.stdout.trim() : ''
}

export function assertReleaseSource({ version, status, tag }) {
  artifactNames(version)
  if (status.trim()) throw new Error('a release must be produced from a clean Git tree')
  if (tag !== undefined && tag !== `v${version}`) {
    throw new Error(`release tag ${tag} does not match package version ${version}`)
  }
}

export function artifactNames(version) {
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error('release version must be a numeric semantic version')
  }
  const base = `Parley-${version}-mac-arm64`
  return {
    base,
    app: 'Parley.app',
    zip: `${base}.zip`,
    dmg: `${base}.dmg`,
    manifest: `${base}.release.json`,
    checksums: `${base}.SHA256SUMS`,
    installGuide: `${base}-INSTALL.txt`,
  }
}

function plainFilename(value) {
  return typeof value === 'string'
    && value.length > 0
    && basename(value) === value
    && !/[\r\n\0]/.test(value)
}

export function renderChecksumFile(entries) {
  return [...entries]
    .sort((left, right) => left.file.localeCompare(right.file, 'en'))
    .map(({ file, sha256 }) => {
      if (!plainFilename(file)) throw new Error('checksum entries require a plain filename')
      if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`invalid SHA-256 for ${file}`)
      return `${sha256}  ${file}`
    })
    .join('\n') + '\n'
}

export function renderReleaseManifest({
  version,
  build,
  commit,
  sourceRepository = SOURCE_REPOSITORY,
  minimumSystemVersion = MINIMUM_SYSTEM_VERSION,
  signing,
  artifacts,
}) {
  artifactNames(version)
  if (!/^\d+$/.test(build)) throw new Error('release build must contain digits only')
  if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error('release commit must be a full Git commit SHA')
  if (!['ad-hoc', 'developer-id'].includes(signing?.kind)) throw new Error('release signing kind is invalid')
  if (signing.kind === 'ad-hoc' && signing.notarized) {
    throw new Error('an ad-hoc signed build cannot be notarized')
  }
  const safeArtifacts = [...artifacts]
    .map(({ file, bytes, sha256 }) => {
      if (!plainFilename(file)) throw new Error('release artifacts require a plain filename')
      if (!Number.isSafeInteger(bytes) || bytes < 1) throw new Error(`invalid byte size for ${file}`)
      if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`invalid SHA-256 for ${file}`)
      return { file, bytes, sha256 }
    })
    .sort((left, right) => left.file.localeCompare(right.file, 'en'))

  return `${JSON.stringify({
    schemaVersion: 1,
    application: {
      name: 'Parley',
      bundleIdentifier: BUNDLE_IDENTIFIER,
      version,
      build,
    },
    platform: {
      operatingSystem: 'macOS',
      architecture: 'arm64',
      minimumVersion: minimumSystemVersion,
    },
    trust: {
      signing: signing.kind,
      notarized: signing.notarized,
      gatekeeperReady: signing.kind === 'developer-id' && signing.notarized,
    },
    source: {
      repository: sourceRepository,
      commit,
    },
    artifacts: safeArtifacts,
  }, null, 2)}\n`
}

export function renderInstallGuide({ version, notarized }) {
  const trustHeading = notarized ? 'NOTARIZED RELEASE' : 'UNNOTARIZED LOCAL BETA'
  const firstLaunch = notarized
    ? 'Open Parley normally from Applications.'
    : `macOS will identify this as software from an unidentified developer. After trying to open Parley once, open System Settings → Privacy & Security and choose Open Anyway only if you obtained the files from the expected Parley release.`
  return `PARLEY ${version} — ${trustHeading}

Install
1. Open the DMG and drag Parley.app to Applications.
2. ${firstLaunch}
3. Parley's first-run check reports tmux and supported CLI readiness without spending model quota.

Verify
Compare the downloaded DMG or ZIP with the matching entry in SHA256SUMS before opening it.

Upgrade
1. Quit Parley and replace Parley.app in Applications.
2. Reopen Parley. It replaces an idle older coordination core automatically without restarting tmux, workspaces or agent panes.
3. If Ask or delegated work is active, Status Center reports Core upgrade: pending and Parley completes the handover when that work finishes. Workspace layouts and local handoff history remain under ~/Library/Application Support/Parley Native.

Uninstall
Choose Parley → Prepare to Uninstall…. It refuses active Ask or delegated work, disables launch at login, stops the coordination core, and quits without deleting tmux panes or local records. Then move Parley.app from Applications to Trash. No Mac restart is required. Remove ~/Library/Application Support/Parley Native separately only when you deliberately want to erase that record.

Never disable Gatekeeper globally to install Parley.
`
}

export function assertSafeApplicationDestination(destination) {
  if (!isAbsolute(destination) || basename(destination) !== 'Parley.app' || dirname(destination) === '/') {
    throw new Error('application destination must be an absolute path ending in Parley.app below a directory')
  }
  if (existsSync(destination) && lstatSync(destination).isSymbolicLink()) {
    throw new Error('application destination must not be a symbolic link')
  }
}

function verifyInstallableBundle(bundle) {
  const errors = validateBundleStructure(bundle)
  if (errors.length > 0) throw new Error(errors.join('\n'))
  if (process.platform === 'darwin') {
    const result = spawnSync('codesign', ['--verify', '--deep', '--strict', bundle], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    if (result.error) throw result.error
    if (result.status !== 0) {
      throw new Error(`bundle signature verification failed: ${(result.stderr || result.stdout).trim()}`)
    }
  }
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function packageVersion() {
  const value = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8')).version
  artifactNames(value)
  return value
}

function parseCLI(arguments_) {
  let tag = process.env.PARLEY_RELEASE_TAG
  let lifecycleOnly = false
  for (let index = 0; index < arguments_.length; index += 1) {
    if (arguments_[index] === '--tag' && arguments_[index + 1]) {
      tag = arguments_[index + 1]
      index += 1
    } else if (arguments_[index] === '--lifecycle-only') {
      lifecycleOnly = true
    } else {
      throw new Error(`unknown release argument: ${arguments_[index]}`)
    }
  }
  if (lifecycleOnly && tag) throw new Error('--lifecycle-only cannot publish tag provenance')
  return { tag, lifecycleOnly }
}

function verifyReleaseTag(tag, commit) {
  if (!tag) return
  const taggedCommit = run('git', ['rev-parse', `${tag}^{commit}`], { capture: true })
  if (taggedCommit !== commit) throw new Error(`release tag ${tag} does not point at HEAD`)
}

function findTmux() {
  const candidates = [
    process.env.PARLEY_TMUX,
    ...(process.env.PATH ?? '').split(':').filter(Boolean).map((directory) => join(directory, 'tmux')),
    '/opt/homebrew/bin/tmux',
    '/usr/local/bin/tmux',
    '/usr/bin/tmux',
  ].filter(Boolean)
  return candidates.find((candidate) => {
    try {
      return !lstatSync(candidate).isDirectory() && (statSync(candidate).mode & 0o111) !== 0
    } catch {
      return false
    }
  })
}

function unixHealth(socketPath) {
  return new Promise((resolvePromise, reject) => {
    const request = http.request({
      socketPath,
      path: '/health',
      method: 'GET',
      headers: { 'Content-Length': '0' },
    }, (response) => {
      const chunks = []
      response.on('data', (chunk) => chunks.push(chunk))
      response.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8')
        if (response.statusCode === 200 && body === 'ok') resolvePromise()
        else reject(new Error(`packaged core health returned ${response.statusCode}: ${body}`))
      })
    })
    request.on('error', reject)
    request.end()
  })
}

function delay(milliseconds) {
  return new Promise((resolvePromise) => setTimeout(resolvePromise, milliseconds))
}

async function waitForPackagedCore({ child, infoFile, logFile }) {
  const deadline = Date.now() + 10_000
  let lastError
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`packaged core exited during smoke test:\n${readFileSync(logFile, 'utf8')}`)
    }
    if (existsSync(infoFile)) {
      const locator = readFileSync(infoFile, 'utf8').trim()
      if (locator.startsWith('unix:')) {
        try {
          await unixHealth(locator.slice('unix:'.length))
          return
        } catch (error) {
          lastError = error
        }
      }
    }
    await delay(50)
  }
  throw new Error(`packaged core did not become healthy${lastError ? `: ${lastError.message}` : ''}`)
}

async function terminateChild(child) {
  if (child.exitCode !== null) return
  child.kill('SIGTERM')
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline && child.exitCode === null) await delay(50)
  if (child.exitCode === null) {
    child.kill('SIGKILL')
    throw new Error('packaged core did not stop after SIGTERM')
  }
}

async function smokeTestPackagedCore(bundle, root) {
  const tmux = findTmux()
  if (!tmux) throw new Error('tmux is required for the isolated packaged-core release check')
  const applicationDirectory = join(root, 'Library', 'Application Support', 'Parley Native')
  const project = join(root, 'project')
  const logFile = join(root, 'packaged-core.log')
  mkdirSync(applicationDirectory, { recursive: true })
  mkdirSync(project, { recursive: true })
  writeFileSync(logFile, '')
  const output = openSync(logFile, 'a')
  const child = spawn(join(bundle, 'Contents', 'MacOS', 'parley-core-service'), [
    '--application-directory', applicationDirectory,
    '--cwd', project,
  ], {
    cwd: project,
    env: { ...process.env, PARLEY_TMUX: tmux },
    stdio: ['ignore', output, output],
  })
  let failure
  try {
    await waitForPackagedCore({
      child,
      infoFile: join(applicationDirectory, 'relay-url'),
      logFile,
    })
  } catch (error) {
    failure = error
  }
  try {
    await terminateChild(child)
  } catch (error) {
    failure ??= error
  } finally {
    closeSync(output)
  }
  const tmuxSocket = join(applicationDirectory, 'tmux.sock')
  if (existsSync(tmuxSocket)) {
    const stopped = spawnSync(tmux, ['-S', tmuxSocket, 'kill-server'], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    if (stopped.error) failure ??= stopped.error
    else if (stopped.status !== 0) {
      failure ??= new Error(`isolated tmux did not stop: ${(stopped.stderr || stopped.stdout).trim()}`)
    }
  }
  if (failure) throw failure
}

async function verifyDevelopmentPackage() {
  if (process.platform !== 'darwin') throw new Error('macOS packages must be verified on macOS')
  const version = packageVersion()
  const installGuide = renderInstallGuide({ version, notarized: false })
  const packaged = packageNativeMacOS({ distributionReadme: installGuide })
  const verificationRoot = mkdtempSync(join(tmpdir(), 'parley-package-archives-'))
  try {
    verifyZip(packaged.zip, verificationRoot)
  } finally {
    rmSync(verificationRoot, { recursive: true, force: true })
  }
  await verifyDMGAndLifecycle({ dmg: packaged.dmg, installGuide })
  process.stdout.write('Development package gate: ZIP, DMG, isolated install, upgrade, core launch, uninstall and explicit data purge passed\n')
}

function verifyZip(zip, root) {
  const expanded = join(root, 'zip')
  mkdirSync(expanded)
  run('ditto', ['-x', '-k', zip, expanded])
  verifyInstallableBundle(join(expanded, 'Parley.app'))
}

async function verifyDMGAndLifecycle({ dmg, installGuide }) {
  // tmux passes its socket path through sockaddr_un, whose macOS ceiling is
  // 104 bytes. $TMPDIR is already long enough to make a realistic nested
  // Application Support path overflow, so the isolated gate needs /tmp.
  const root = mkdtempSync('/tmp/parley-release-')
  const mount = join(root, 'mount')
  mkdirSync(mount)
  let attached = false
  try {
    run('hdiutil', ['verify', dmg])
    run('hdiutil', ['attach', dmg, '-readonly', '-nobrowse', '-mountpoint', mount])
    attached = true
    const mountedBundle = join(mount, 'Parley.app')
    verifyInstallableBundle(mountedBundle)
    if (!lstatSync(join(mount, 'Applications')).isSymbolicLink()) {
      throw new Error('release DMG is missing its Applications link')
    }
    if (readFileSync(join(mount, 'READ ME FIRST.txt'), 'utf8') !== installGuide) {
      throw new Error('release DMG install guide does not match the published guide')
    }

    const destination = join(root, 'Applications', 'Parley.app')
    const dataDirectory = join(root, 'Library', 'Application Support', 'Parley Native')
    installApplicationBundle({ source: mountedBundle, destination })
    mkdirSync(dataDirectory, { recursive: true })
    writeFileSync(join(dataDirectory, 'workspace-layouts.json'), 'release-gate-preserve')
    writeFileSync(join(destination, 'Contents', 'obsolete-release-check.txt'), 'replace me')
    installApplicationBundle({ source: mountedBundle, destination, allowUpgrade: true })
    if (existsSync(join(destination, 'Contents', 'obsolete-release-check.txt'))) {
      throw new Error('upgrade did not replace the complete application bundle')
    }
    if (readFileSync(join(dataDirectory, 'workspace-layouts.json'), 'utf8') !== 'release-gate-preserve') {
      throw new Error('upgrade did not preserve local application data')
    }
    await smokeTestPackagedCore(destination, root)
    uninstallApplicationBundle({ destination, dataDirectory })
    if (existsSync(destination) || !existsSync(dataDirectory)) {
      throw new Error('default uninstall did not remove only the application')
    }
    uninstallApplicationBundle({
      destination,
      dataDirectory,
      purgeData: true,
      confirmPurge: PURGE_CONFIRMATION,
    })
    if (existsSync(dataDirectory)) throw new Error('explicit purge did not remove isolated application data')
  } finally {
    if (attached) run('hdiutil', ['detach', mount])
    rmSync(root, { recursive: true, force: true })
  }
}

async function prepareRelease({ tag }) {
  if (process.platform !== 'darwin') throw new Error('macOS releases must be prepared on macOS')
  const version = packageVersion()
  const status = run('git', ['status', '--porcelain=v1', '--untracked-files=all'], { capture: true })
  assertReleaseSource({ version, status, tag })
  const commit = run('git', ['rev-parse', 'HEAD'], { capture: true })
  verifyReleaseTag(tag, commit)

  const notarized = false
  const installGuide = renderInstallGuide({ version, notarized })
  const packaged = packageNativeMacOS({ distributionReadme: installGuide })
  const names = artifactNames(version)
  const dist = join(repositoryRoot, 'dist')
  const artifacts = [packaged.dmg, packaged.zip].map((path) => ({
    file: basename(path),
    bytes: statSync(path).size,
    sha256: sha256(path),
  }))
  const manifestPath = join(dist, names.manifest)
  const guidePath = join(dist, names.installGuide)
  writeFileSync(guidePath, installGuide)
  writeFileSync(manifestPath, renderReleaseManifest({
    version,
    build: packaged.build,
    commit,
    signing: { kind: packaged.signing.kind, notarized },
    artifacts,
  }))
  const checksumEntries = [...artifacts, manifestPath, guidePath].map((entry) => {
    const path = typeof entry === 'string' ? entry : join(dist, entry.file)
    return { file: basename(path), sha256: sha256(path) }
  })
  const checksumsPath = join(dist, names.checksums)
  writeFileSync(checksumsPath, renderChecksumFile(checksumEntries))
  run('shasum', ['-a', '256', '-c', names.checksums], { cwd: dist })

  const verificationRoot = mkdtempSync(join(tmpdir(), 'parley-release-archives-'))
  try {
    verifyZip(packaged.zip, verificationRoot)
  } finally {
    rmSync(verificationRoot, { recursive: true, force: true })
  }
  await verifyDMGAndLifecycle({ dmg: packaged.dmg, installGuide })

  process.stdout.write(`Prepared Parley ${version} (${packaged.build}) from ${commit}\n`)
  process.stdout.write(`Trust: ${packaged.signing.kind} signed, unnotarized local beta\n`)
  for (const path of [packaged.dmg, packaged.zip, manifestPath, checksumsPath, guidePath]) {
    process.stdout.write(`${path}\n`)
  }
  process.stdout.write('Release gate: ZIP, DMG, isolated install, upgrade, core launch, uninstall and explicit data purge passed\n')
}

export function installApplicationBundle({
  source,
  destination,
  allowUpgrade = false,
  verifyBundle = verifyInstallableBundle,
}) {
  assertSafeApplicationDestination(destination)
  if (!isAbsolute(source) || resolve(source) === resolve(destination)) {
    throw new Error('application source must be a different absolute path')
  }
  if (!existsSync(source) || lstatSync(source).isSymbolicLink()) {
    throw new Error('application source must be an existing non-symbolic-link bundle')
  }
  verifyBundle(source)
  if (existsSync(destination) && !allowUpgrade) {
    throw new Error(`${destination} already exists; an upgrade must be explicit`)
  }

  const parent = dirname(destination)
  mkdirSync(parent, { recursive: true })
  const stagingRoot = mkdtempSync(join(parent, '.parley-install-'))
  const stagedBundle = join(stagingRoot, 'Parley.app')
  let backup
  try {
    cpSync(source, stagedBundle, { recursive: true, force: false, preserveTimestamps: true })
    verifyBundle(stagedBundle)
    if (existsSync(destination)) {
      backup = join(parent, `.Parley.backup-${randomUUID()}.app`)
      renameSync(destination, backup)
    }
    try {
      renameSync(stagedBundle, destination)
    } catch (error) {
      if (backup && !existsSync(destination)) renameSync(backup, destination)
      throw error
    }
    if (backup) rmSync(backup, { recursive: true, force: true })
  } finally {
    rmSync(stagingRoot, { recursive: true, force: true })
  }
}

function assertSafeDataDirectory(dataDirectory) {
  if (!isAbsolute(dataDirectory)
      || basename(dataDirectory) !== 'Parley Native'
      || basename(dirname(dataDirectory)) !== 'Application Support') {
    throw new Error('data directory must be an absolute Application Support/Parley Native path')
  }
}

export function uninstallApplicationBundle({
  destination,
  dataDirectory,
  purgeData = false,
  confirmPurge,
}) {
  assertSafeApplicationDestination(destination)
  if (existsSync(destination)) rmSync(destination, { recursive: true, force: false })
  if (!purgeData) return
  assertSafeDataDirectory(dataDirectory)
  if (confirmPurge !== PURGE_CONFIRMATION) {
    throw new Error(`purging local records requires the exact confirmation: ${PURGE_CONFIRMATION}`)
  }
  if (existsSync(dataDirectory)) rmSync(dataDirectory, { recursive: true, force: false })
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : ''
if (invokedPath === import.meta.url) {
  try {
    const options = parseCLI(process.argv.slice(2))
    if (options.lifecycleOnly) await verifyDevelopmentPackage()
    else await prepareRelease(options)
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`)
    process.exit(1)
  }
}
