import assert from 'node:assert/strict'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  assertReleaseSource,
  assertSafeApplicationDestination,
  artifactNames,
  installApplicationBundle,
  renderChecksumFile,
  renderInstallGuide,
  renderReleaseManifest,
  uninstallApplicationBundle,
} from './native-macos-release.mjs'

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
  assert.match(workflow, /PARLEY_RELEASE_TAG/)
  assert.match(workflow, /npm ci --prefix vscode-extension/)
  assert.match(workflow, /npm run package:vscode/)
  assert.match(workflow, /Parley-Companion-0\.1\.0\.vsix/)
  assert.match(
    workflow,
    /npm run test:soak -- --rounds 25 --output dist\/Parley-Ghostty-soak\.json/,
  )
  assert.equal(workflow.match(/Parley-Ghostty-soak\.json/g)?.length, 3)
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
  })
  assert.throws(() => artifactNames('../bad'), /numeric semantic version/)
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

test('application destinations are narrowly scoped', () => {
  assert.throws(() => assertSafeApplicationDestination('/'), /Parley\.app/)
  assert.throws(() => assertSafeApplicationDestination('/Applications/Other.app'), /Parley\.app/)
  assert.doesNotThrow(() => assertSafeApplicationDestination('/Applications/Parley.app'))
})
