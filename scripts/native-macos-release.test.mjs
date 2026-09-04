import assert from 'node:assert/strict'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readlinkSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  assertNotarizationConfiguration,
  assertReleaseSource,
  assertSafeApplicationDestination,
  artifactNames,
  installApplicationBundle,
  parseReleaseCLI,
  renderChecksumFile,
  renderInstallGuide,
  renderHomebrewCask,
  renderReleaseManifest,
  uninstallApplicationBundle,
} from './native-macos-release.mjs'
import { verifyExecutableLaunch } from './verify-native-macos-launch.mjs'

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

test('GitHub release automation is manual and can create only a draft', () => {
  const workflow = readFileSync(join(repositoryRoot, '.github/workflows/macos-draft-release.yml'), 'utf8')
  assert.match(workflow, /workflow_dispatch:/)
  assert.doesNotMatch(workflow, /^\s+push:/m)
  assert.match(
    workflow,
    /actions\/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\.0\.1/,
  )
  assert.match(workflow, /gh release create[\s\S]*--draft/)
  assert.match(workflow, /PARLEY_CODESIGN_IDENTITY/)
  assert.match(workflow, /PARLEY_SPARKLE_PUBLIC_ED_KEY/)
  assert.match(workflow, /PARLEY_SPARKLE_PRIVATE_ED_KEY/)
  assert.match(workflow, /PARLEY_NOTARY_KEY_ID/)
  assert.match(workflow, /PARLEY_NOTARY_ISSUER_ID/)
  assert.match(workflow, /PARLEY_NOTARY_KEY/)
  assert.match(workflow, /security create-keychain/)
  assert.match(workflow, /appcast\.xml/)
  assert.match(workflow, /parley\.rb/)
  assert.match(workflow, /PARLEY_RELEASE_TAG/)
  assert.match(workflow, /npm ci --prefix vscode-extension/)
  assert.match(workflow, /npm run package:vscode/)
  const companion = JSON.parse(readFileSync(new URL('../vscode-extension/package.json', import.meta.url), 'utf8'))
  const companionAsset = `Parley-Companion-${companion.version}.vsix`
  assert.ok(workflow.includes(companionAsset))
  assert.ok(companion.scripts.package.endsWith(companionAsset))
  assert.match(
    workflow,
    /npm run test:soak -- --rounds 25 --output dist\/Parley-Ghostty-soak\.json/,
  )
  assert.equal(workflow.match(/Parley-Ghostty-soak\.json/g)?.length, 3)
  assert.match(workflow, /npm run verify:launch:mac/)
})

test('unnotarized test beta is explicit and cannot weaken the signed release path', () => {
  assert.deepEqual(parseReleaseCLI([]), {
    tag: undefined,
    lifecycleOnly: false,
    unnotarizedBeta: false,
  })
  assert.deepEqual(parseReleaseCLI(['--unnotarized-beta'], { PARLEY_RELEASE_TAG: 'v1.2.3' }), {
    tag: 'v1.2.3',
    lifecycleOnly: false,
    unnotarizedBeta: true,
  })
  assert.throws(
    () => parseReleaseCLI(['--lifecycle-only', '--unnotarized-beta']),
    /cannot be combined/,
  )

  const workflow = readFileSync(join(repositoryRoot, '.github/workflows/macos-test-beta-release.yml'), 'utf8')
  assert.match(workflow, /name: Prepare unnotarized macOS test beta/)
  assert.match(workflow, /workflow_dispatch:/)
  assert.doesNotMatch(workflow, /^\s+push:/m)
  assert.match(workflow, /npm run release:mac:beta/)
  assert.match(workflow, /npm run verify:launch:mac/)
  assert.match(workflow, /npm run test:soak -- --rounds 25 --output dist\/Parley-Ghostty-soak\.json/)
  assert.match(workflow, /gh release create[\s\S]*--draft[\s\S]*--prerelease/)
  assert.doesNotMatch(workflow, /PARLEY_CODESIGN_IDENTITY/)
  assert.doesNotMatch(workflow, /SPARKLE_PRIVATE/)
  assert.doesNotMatch(workflow, /appcast\.xml/)
  assert.doesNotMatch(workflow, /parley\.rb/)
})

test('packaged launch check rejects an early dyld-style exit and stops a live app', async () => {
  await assert.rejects(
    verifyExecutableLaunch({
      executable: process.execPath,
      arguments: ['-e', 'process.stderr.write("Library not loaded: Sparkle\\n"); process.exit(134)'],
      settleMilliseconds: 1_000,
      shutdownMilliseconds: 500,
    }),
    /exited before the 1000 ms launch window.*Library not loaded: Sparkle/s,
  )

  await assert.doesNotReject(
    verifyExecutableLaunch({
      executable: process.execPath,
      arguments: [
        '-e',
        'process.on("SIGTERM", () => process.exit(0)); setInterval(() => {}, 1000)',
      ],
      settleMilliseconds: 100,
      shutdownMilliseconds: 500,
    }),
  )
})

test('published releases open a reviewed cask update pull request', () => {
  const workflow = readFileSync(join(repositoryRoot, '.github/workflows/update-homebrew-cask.yml'), 'utf8')
  assert.match(workflow, /release:\s*\n\s*types: \[published\]/)
  assert.match(workflow, /if: github\.event\.release\.prerelease == false/)
  assert.match(workflow, /gh release download/)
  assert.match(workflow, /Casks\/parley\.rb/)
  assert.match(workflow, /brew style --cask Casks\/parley\.rb/)
  assert.match(workflow, /npm run scan:public/)
  assert.match(workflow, /gh pr create/)
  assert.doesNotMatch(workflow, /git push origin main/)
})

test('release source must be clean and an optional tag must match package version', () => {
  assert.doesNotThrow(() => assertReleaseSource({ version: '1.2.3', status: '', tag: undefined }))
  assert.doesNotThrow(() => assertReleaseSource({ version: '1.2.3', status: '', tag: 'v1.2.3' }))
  assert.throws(
    () => assertReleaseSource({ version: '1.2.3', status: ' M README.md', tag: undefined }),
    /clean Git tree/,
  )
  assert.throws(
    () => assertReleaseSource({ version: '1.2.3', status: '', tag: 'v1.2.4' }),
    /does not match package version/,
  )
})

test('release assets have stable GitHub-safe names', () => {
  assert.deepEqual(artifactNames('1.2.3'), {
    base: 'Parley-1.2.3-mac-arm64',
    app: 'Parley.app',
    zip: 'Parley-1.2.3-mac-arm64.zip',
    dmg: 'Parley-1.2.3-mac-arm64.dmg',
    manifest: 'Parley-1.2.3-mac-arm64.release.json',
    checksums: 'Parley-1.2.3-mac-arm64.SHA256SUMS',
    installGuide: 'Parley-1.2.3-mac-arm64-INSTALL.txt',
    appcast: 'appcast.xml',
    cask: 'parley.rb',
  })
  assert.throws(() => artifactNames('../bad'), /numeric semantic version/)
})

test('notarized release configuration fails closed before packaging', () => {
  const valid = {
    PARLEY_CODESIGN_IDENTITY: 'Developer ID Application: Parley Example (ABCDE12345)',
    PARLEY_SPARKLE_PUBLIC_ED_KEY: Buffer.alloc(32, 9).toString('base64'),
    PARLEY_SPARKLE_PRIVATE_ED_KEY: 'sparkle-private-key',
    PARLEY_NOTARY_KEY_ID: 'AB12CD34EF',
    PARLEY_NOTARY_ISSUER_ID: '00000000-1111-2222-3333-444444444444',
    PARLEY_NOTARY_KEY: '/private/tmp/AuthKey_AB12CD34EF.p8',
  }
  assert.deepEqual(assertNotarizationConfiguration(valid), {
    codesignIdentity: valid.PARLEY_CODESIGN_IDENTITY,
    sparklePublicKey: valid.PARLEY_SPARKLE_PUBLIC_ED_KEY,
    sparklePrivateKey: valid.PARLEY_SPARKLE_PRIVATE_ED_KEY,
    notaryKeyID: valid.PARLEY_NOTARY_KEY_ID,
    notaryIssuerID: valid.PARLEY_NOTARY_ISSUER_ID,
    notaryKey: valid.PARLEY_NOTARY_KEY,
  })
  for (const key of Object.keys(valid)) {
    const missing = { ...valid }
    delete missing[key]
    assert.throws(() => assertNotarizationConfiguration(missing), new RegExp(key))
  }
  assert.throws(
    () => assertNotarizationConfiguration({ ...valid, PARLEY_CODESIGN_IDENTITY: '-' }),
    /Developer ID Application/,
  )
})

test('Homebrew cask installs the notarized arm64 app and declares real auto-updates', () => {
  const cask = renderHomebrewCask({
    version: '1.2.3',
    sha256: 'a'.repeat(64),
  })
  assert.match(cask, /cask "parley" do/)
  assert.match(cask, /version "1\.2\.3"/)
  assert.match(cask, new RegExp(`sha256 "${'a'.repeat(64)}"`))
  assert.match(cask, /url "https:\/\/github\.com\/markjoyeuxcom\/parley\/releases\/download\/v#\{version\}\/Parley-#\{version\}-mac-arm64\.dmg"/)
  assert.match(cask, /auto_updates true/)
  assert.match(cask, /depends_on macos: ">= :sonoma"/)
  assert.match(cask, /depends_on arch: :arm64/)
  assert.match(cask, /app "Parley\.app"/)
})

test('checksum output is deterministic and rejects unsafe filenames', () => {
  const output = renderChecksumFile([
    { file: 'z.zip', sha256: 'b'.repeat(64) },
    { file: 'a.dmg', sha256: 'a'.repeat(64) },
  ])
  assert.equal(output, `${'a'.repeat(64)}  a.dmg\n${'b'.repeat(64)}  z.zip\n`)
  assert.throws(
    () => renderChecksumFile([{ file: '../escape.zip', sha256: 'a'.repeat(64) }]),
    /plain filename/,
  )
})

test('release manifest records source, platform and honest trust state', () => {
  const manifest = JSON.parse(renderReleaseManifest({
    version: '1.2.3',
    build: '45',
    commit: 'a'.repeat(40),
    sourceRepository: 'https://github.com/markjoyeuxcom/parley',
    minimumSystemVersion: '14.0',
    signing: { kind: 'ad-hoc', notarized: false },
    artifacts: [
      { file: 'Parley-1.2.3-mac-arm64.zip', bytes: 20, sha256: 'b'.repeat(64) },
      { file: 'Parley-1.2.3-mac-arm64.dmg', bytes: 10, sha256: 'a'.repeat(64) },
    ],
  }))

  assert.equal(manifest.schemaVersion, 1)
  assert.equal(manifest.application.bundleIdentifier, 'com.markjoyeux.parley')
  assert.equal(manifest.application.version, '1.2.3')
  assert.equal(manifest.application.build, '45')
  assert.deepEqual(manifest.platform, { operatingSystem: 'macOS', architecture: 'arm64', minimumVersion: '14.0' })
  assert.deepEqual(manifest.trust, {
    signing: 'ad-hoc',
    notarized: false,
    gatekeeperReady: false,
  })
  assert.equal(manifest.source.commit, 'a'.repeat(40))
  assert.deepEqual(manifest.artifacts.map((artifact) => artifact.file), [
    'Parley-1.2.3-mac-arm64.dmg',
    'Parley-1.2.3-mac-arm64.zip',
  ])
  assert.equal(JSON.stringify(manifest).includes('generatedAt'), false)
})

test('unnotarized install guide is explicit without telling users to disable Gatekeeper', () => {
  const guide = renderInstallGuide({ version: '1.2.3', notarized: false })

  assert.match(guide, /UNNOTARIZED LOCAL BETA/)
  assert.match(guide, /Privacy & Security/)
  assert.match(guide, /Open Anyway/)
  assert.match(guide, /SHA256SUMS/)
  assert.match(guide, /Install from VSIX/)
  assert.match(guide, /embedded Ghostty terminal/)
  assert.match(guide, /Closing Parley's window keeps its Ghostty panes alive/)
  assert.match(guide, /Quitting Parley ends every pane and the coordination core/)
  assert.match(guide, /Prepare to Uninstall/)
  assert.match(guide, /No Mac restart is required/)
  assert.match(guide, /\/Applications\/Parley\.app/)
  assert.match(guide, /~\/Library\/Application Support\/Parley Native/)
  assert.match(guide, /~\/Library\/Preferences\/com\.markjoyeux\.parley\.plist/)
  assert.match(guide, /~\/\.local\/bin\/parley/)
  assert.match(guide, /\/private\/tmp\/parley-native-/)
  assert.match(guide, /does not install a background service/)
  assert.doesNotMatch(guide, /LaunchAgent/)
  assert.doesNotMatch(guide, /tmux/)
  assert.doesNotMatch(guide, /restart the Mac before reopening Parley/)
  assert.doesNotMatch(guide, /spctl --master-disable/)
  assert.doesNotMatch(guide, /xattr -d/)
})

test('install, upgrade and uninstall are atomic and preserve user data by default', (context) => {
  const root = mkdtempSync(join(tmpdir(), 'parley-release-lifecycle-'))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const applications = join(root, 'Applications')
  const source = join(root, 'source', 'Parley.app')
  const destination = join(applications, 'Parley.app')
  const dataDirectory = join(root, 'Library', 'Application Support', 'Parley Native')
  mkdirSync(join(source, 'Contents'), { recursive: true })
  mkdirSync(dataDirectory, { recursive: true })
  writeFileSync(join(source, 'Contents', 'build.txt'), 'first')
  writeFileSync(join(dataDirectory, 'workspace-layouts.json'), 'keep me')

  installApplicationBundle({ source, destination, verifyBundle: () => {} })
  assert.equal(readFileSync(join(destination, 'Contents', 'build.txt'), 'utf8'), 'first')
  assert.throws(
    () => installApplicationBundle({ source, destination, verifyBundle: () => {} }),
    /already exists/,
  )

  writeFileSync(join(source, 'Contents', 'build.txt'), 'second')
  writeFileSync(join(destination, 'Contents', 'obsolete.txt'), 'remove me')
  installApplicationBundle({ source, destination, allowUpgrade: true, verifyBundle: () => {} })
  assert.equal(readFileSync(join(destination, 'Contents', 'build.txt'), 'utf8'), 'second')
  assert.equal(existsSync(join(destination, 'Contents', 'obsolete.txt')), false)
  assert.equal(readFileSync(join(dataDirectory, 'workspace-layouts.json'), 'utf8'), 'keep me')

  uninstallApplicationBundle({ destination, dataDirectory })
  assert.equal(existsSync(destination), false)
  assert.equal(readFileSync(join(dataDirectory, 'workspace-layouts.json'), 'utf8'), 'keep me')

  assert.throws(
    () => uninstallApplicationBundle({
      destination,
      dataDirectory,
      purgeData: true,
      confirmPurge: 'wrong',
    }),
    /DELETE PARLEY DATA/,
  )
  uninstallApplicationBundle({
    destination,
    dataDirectory,
    purgeData: true,
    confirmPurge: 'DELETE PARLEY DATA',
  })
  assert.equal(existsSync(dataDirectory), false)
})

test('application installation preserves relative framework symlinks exactly', (context) => {
  const root = mkdtempSync(join(tmpdir(), 'parley-framework-install-'))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const source = join(root, 'source/Parley.app')
  const destination = join(root, 'Applications/Parley.app')
  const framework = join(source, 'Contents/Frameworks/Sparkle.framework')
  mkdirSync(join(framework, 'Versions/B'), { recursive: true })
  writeFileSync(join(framework, 'Versions/B/Sparkle'), 'framework')
  symlinkSync('B', join(framework, 'Versions/Current'))
  symlinkSync('Versions/Current/Sparkle', join(framework, 'Sparkle'))

  installApplicationBundle({ source, destination, verifyBundle: () => {} })

  const installedFramework = join(destination, 'Contents/Frameworks/Sparkle.framework')
  assert.equal(readlinkSync(join(installedFramework, 'Versions/Current')), 'B')
  assert.equal(readlinkSync(join(installedFramework, 'Sparkle')), 'Versions/Current/Sparkle')
})

test('application destinations are narrowly scoped', () => {
  assert.throws(() => assertSafeApplicationDestination('/'), /Parley\.app/)
  assert.throws(() => assertSafeApplicationDestination('/Applications/Other.app'), /Parley\.app/)
  assert.doesNotThrow(() => assertSafeApplicationDestination('/Applications/Parley.app'))
})
