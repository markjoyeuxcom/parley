#!/usr/bin/env node

import {
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
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
import { spawnSync } from 'node:child_process'

import {
  BUNDLE_IDENTIFIER,
  MINIMUM_SYSTEM_VERSION,
  createNativeMacOSArchives,
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
    appcast: 'appcast.xml',
    cask: 'parley.rb',
  }
}

function requiredEnvironment(environment, name) {
  const value = environment[name]
  if (typeof value !== 'string' || !value.trim()) {
    throw new Error(`${name} is required for a notarized release`)
  }
  return value.trim()
}

export function assertNotarizationConfiguration(environment) {
  const codesignIdentity = requiredEnvironment(environment, 'PARLEY_CODESIGN_IDENTITY')
  if (!codesignIdentity.startsWith('Developer ID Application:')) {
    throw new Error('PARLEY_CODESIGN_IDENTITY must name a Developer ID Application identity')
  }
  const sparklePublicKey = requiredEnvironment(environment, 'PARLEY_SPARKLE_PUBLIC_ED_KEY')
  const publicKeyBytes = Buffer.from(sparklePublicKey, 'base64')
  if (publicKeyBytes.length !== 32 || publicKeyBytes.toString('base64') !== sparklePublicKey) {
    throw new Error('PARLEY_SPARKLE_PUBLIC_ED_KEY must be a canonical 32-byte base64 Ed25519 public key')
  }
  return {
    codesignIdentity,
    sparklePublicKey,
    sparklePrivateKey: requiredEnvironment(environment, 'PARLEY_SPARKLE_PRIVATE_ED_KEY'),
    notaryKeyID: requiredEnvironment(environment, 'PARLEY_NOTARY_KEY_ID'),
    notaryIssuerID: requiredEnvironment(environment, 'PARLEY_NOTARY_ISSUER_ID'),
    notaryKey: requiredEnvironment(environment, 'PARLEY_NOTARY_KEY'),
  }
}

export function renderHomebrewCask({ version, sha256 }) {
  artifactNames(version)
  if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error('Homebrew cask requires a lowercase SHA-256')
  return `cask "parley" do
  version "${version}"
  sha256 "${sha256}"

  url "${SOURCE_REPOSITORY}/releases/download/v#{version}/Parley-#{version}-mac-arm64.dmg"
  name "Parley"
  desc "Native workbench for supervised cross-vendor AI CLI collaboration"
  homepage "${SOURCE_REPOSITORY}"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Parley.app"

  zap trash: [
    "~/Library/Application Support/Parley Native",
    "~/Library/Preferences/${BUNDLE_IDENTIFIER}.plist",
  ]
end
`
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
  const updateInstructions = notarized
    ? `Automatic updates
- In Parley, open Tools → Compatibility & Releases → Updates.
- Stable update checks are off until you opt in. Sparkle verifies the signed feed, the Ed25519 archive signature and the Developer ID signature before replacement.
- Installing an update asks Parley to quit; the normal quit confirmation remains authoritative and active panes are never ended silently.

Homebrew cask
- The release includes parley.rb for a Parley-maintained tap. The cask installs the same notarized DMG and verifies its SHA-256.`
    : 'Automatic replacement and a Homebrew cask are intentionally unavailable for this unnotarized local beta.'
  return `PARLEY ${version} — ${trustHeading}

Install
1. Open the DMG and drag Parley.app to Applications. This copies the application to /Applications/Parley.app; the DMG runs no installer script.
2. ${firstLaunch}
3. Parley's first-run check reports embedded terminal, coordination and supported CLI readiness without spending model quota.

Installed footprint
- The app, embedded Ghostty terminal, app-resident coordination core and icon live inside /Applications/Parley.app.
- Runtime state, private relay files, saved layouts and local collaboration history live under ~/Library/Application Support/Parley Native.
- Parley installs its managed pane command at ~/.local/bin/parley without overwriting a foreign command.
- Presentation settings use the normal macOS domain at ~/Library/Preferences/com.markjoyeux.parley.plist.
- Agent-issued relay exchanges use an owner-only transient directory named /private/tmp/parley-native-<uid>-<runtime-hash>/.
- Closing Parley's window keeps its Ghostty panes alive while the application remains running. Quitting Parley ends every pane and the coordination core.
- Parley does not install a background service or modify shell startup files, vendor credentials or repositories.

Verify
Compare every downloaded artifact with its matching entry in SHA256SUMS before opening or installing it.

${updateInstructions}

Optional VS Code companion
The GitHub release also carries a matching Parley-Companion VSIX. In VS Code,
open Extensions, choose Install from VSIX, and select that file. It is a thin
local remote control for the installed Production app and cannot replace it.

Upgrade
1. Finish or stop active Ask and delegated work, then quit Parley. Quitting ends the app-resident panes and coordination core.
2. Replace Parley.app in Applications and reopen it. Workspace definitions and local handoff history remain under ~/Library/Application Support/Parley Native.

Uninstall
Choose Parley → Prepare to Uninstall…. It refuses active Ask or delegated work, ends every pane and the coordination core, and quits without deleting local records. Then move /Applications/Parley.app to Trash. No Mac restart is required. The Application Support tree, preferences and managed ~/.local/bin/parley command remain for a safe reinstall; remove them separately only when you deliberately want to erase all Parley state.

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

export function parseReleaseCLI(arguments_, environment = process.env) {
  let tag = environment.PARLEY_RELEASE_TAG
  let lifecycleOnly = false
  let unnotarizedBeta = false
  for (let index = 0; index < arguments_.length; index += 1) {
    if (arguments_[index] === '--tag' && arguments_[index + 1]) {
      tag = arguments_[index + 1]
      index += 1
    } else if (arguments_[index] === '--lifecycle-only') {
      lifecycleOnly = true
    } else if (arguments_[index] === '--unnotarized-beta') {
      unnotarizedBeta = true
    } else {
      throw new Error(`unknown release argument: ${arguments_[index]}`)
    }
  }
  if (lifecycleOnly && tag) throw new Error('--lifecycle-only cannot publish tag provenance')
  if (lifecycleOnly && unnotarizedBeta) throw new Error('--lifecycle-only and --unnotarized-beta cannot be combined')
  return { tag, lifecycleOnly, unnotarizedBeta }
}

function verifyReleaseTag(tag, commit) {
  if (!tag) return
  const taggedCommit = run('git', ['rev-parse', `${tag}^{commit}`], { capture: true })
  if (taggedCommit !== commit) throw new Error(`release tag ${tag} does not point at HEAD`)
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
  process.stdout.write('Development package gate: ZIP, DMG, isolated install, upgrade, uninstall and explicit data purge passed\n')
}

function verifyZip(zip, root) {
  const expanded = join(root, 'zip')
  mkdirSync(expanded)
  run('ditto', ['-x', '-k', zip, expanded])
  verifyInstallableBundle(join(expanded, 'Parley.app'))
}

async function verifyDMGAndLifecycle({ dmg, installGuide }) {
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
  const signing = assertNotarizationConfiguration(process.env)

  const notarized = true
  const installGuide = renderInstallGuide({ version, notarized })
  const packaged = packageNativeMacOS({ distributionReadme: installGuide })
  if (packaged.signing.kind !== 'developer-id'
      || packaged.signing.identity !== signing.codesignIdentity) {
    throw new Error('release packaging did not use the configured Developer ID identity')
  }
  const names = artifactNames(version)
  const dist = join(repositoryRoot, 'dist')
  notarizeAndStaple({ packaged, signing, installGuide })
  const appcastPath = generateSignedAppcast({
    version,
    archive: packaged.zip,
    privateKey: signing.sparklePrivateKey,
    output: join(dist, names.appcast),
  })
  const caskPath = join(dist, names.cask)
  writeFileSync(caskPath, renderHomebrewCask({ version, sha256: sha256(packaged.dmg) }))
  const artifacts = [packaged.dmg, packaged.zip, appcastPath, caskPath].map((path) => ({
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
  process.stdout.write('Trust: Developer ID signed, Apple notarized and Sparkle Ed25519 signed\n')
  for (const path of [
    packaged.dmg,
    packaged.zip,
    appcastPath,
    caskPath,
    manifestPath,
    checksumsPath,
    guidePath,
  ]) {
    process.stdout.write(`${path}\n`)
  }
  process.stdout.write('Release gate: ZIP, DMG, isolated install, upgrade, uninstall and explicit data purge passed\n')
}

function notarizeAndStaple({ packaged, signing, installGuide }) {
  const notaryArguments = (path) => [
    'notarytool',
    'submit',
    path,
    '--key',
    signing.notaryKey,
    '--key-id',
    signing.notaryKeyID,
    '--issuer',
    signing.notaryIssuerID,
    '--wait',
  ]
  run('xcrun', notaryArguments(packaged.zip))
  run('xcrun', ['stapler', 'staple', packaged.bundle])
  run('xcrun', ['stapler', 'validate', packaged.bundle])
  createNativeMacOSArchives({
    bundle: packaged.bundle,
    zip: packaged.zip,
    dmg: packaged.dmg,
    distributionReadme: installGuide,
  })
  run('xcrun', notaryArguments(packaged.dmg))
  run('xcrun', ['stapler', 'staple', packaged.dmg])
  run('xcrun', ['stapler', 'validate', packaged.dmg])
  run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', packaged.bundle])
  run('spctl', ['--assess', '--type', 'execute', '--verbose=2', packaged.bundle])
  run('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', packaged.dmg])
}

function generateSignedAppcast({ version, archive, privateKey, output }) {
  const tool = join(
    repositoryRoot,
    'native/.build/artifacts/sparkle/Sparkle/bin/generate_appcast',
  )
  if (!existsSync(tool)) throw new Error('resolved Sparkle generate_appcast tool is missing')
  const root = mkdtempSync(join(tmpdir(), 'parley-appcast-'))
  const key = join(root, 'sparkle-private-key')
  const archives = join(root, 'archives')
  mkdirSync(archives)
  try {
    writeFileSync(key, privateKey, { mode: 0o600 })
    cpSync(archive, join(archives, basename(archive)))
    rmSync(output, { force: true })
    run(tool, [
      '--ed-key-file',
      key,
      '--download-url-prefix',
      `${SOURCE_REPOSITORY}/releases/download/v${version}/`,
      '--maximum-versions',
      '1',
      '--maximum-deltas',
      '0',
      '-o',
      output,
      archives,
    ])
    const appcast = readFileSync(output, 'utf8')
    if (!/sparkle:edSignature="[A-Za-z0-9+/=]+"/.test(appcast)
        || !/<!-- sparkle-signatures:\s*edSignature: [A-Za-z0-9+/=]+/.test(appcast)) {
      throw new Error('Sparkle did not produce both a signed enclosure and a signed feed')
    }
    return output
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
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
    cpSync(source, stagedBundle, {
      recursive: true,
      force: false,
      preserveTimestamps: true,
      verbatimSymlinks: true,
    })
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

async function prepareUnnotarizedBeta({ tag }) {
  if (process.platform !== 'darwin') throw new Error('macOS releases must be prepared on macOS')
  const version = packageVersion()
  const status = run('git', ['status', '--porcelain=v1', '--untracked-files=all'], { capture: true })
  assertReleaseSource({ version, status, tag })
  const commit = run('git', ['rev-parse', 'HEAD'], { capture: true })
  verifyReleaseTag(tag, commit)

  const notarized = false
  const installGuide = renderInstallGuide({ version, notarized })
  const packaged = packageNativeMacOS({ distributionReadme: installGuide })
  if (packaged.signing.kind !== 'ad-hoc') {
    throw new Error('an unnotarized test beta must use ad-hoc signing')
  }
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

  const verificationRoot = mkdtempSync(join(tmpdir(), 'parley-beta-archives-'))
  try {
    verifyZip(packaged.zip, verificationRoot)
  } finally {
    rmSync(verificationRoot, { recursive: true, force: true })
  }
  await verifyDMGAndLifecycle({ dmg: packaged.dmg, installGuide })

  process.stdout.write(`Prepared Parley ${version} (${packaged.build}) from ${commit}\n`)
  process.stdout.write('Trust: ad-hoc signed, unnotarized test beta\n')
  for (const path of [packaged.dmg, packaged.zip, manifestPath, checksumsPath, guidePath]) {
    process.stdout.write(`${path}\n`)
  }
  process.stdout.write('Test-beta gate: ZIP, DMG, isolated install, upgrade, uninstall and explicit data purge passed\n')
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : ''
if (invokedPath === import.meta.url) {
  try {
    const options = parseReleaseCLI(process.argv.slice(2))
    if (options.lifecycleOnly) await verifyDevelopmentPackage()
    else if (options.unnotarizedBeta) await prepareUnnotarizedBeta(options)
    else await prepareRelease(options)
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`)
    process.exit(1)
  }
}
