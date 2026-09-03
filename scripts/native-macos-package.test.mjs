import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  BUNDLE_IDENTIFIER,
  GHOSTTY_RESOURCE_BUNDLE,
  MINIMUM_SYSTEM_VERSION,
  copyGhosttyResourceBundle,
  patchGhosttyRuntimeResourcesSource,
  requiredBundlePaths,
  renderInfoPlist,
  validateBundleStructure,
  withGhosttyRuntimeResourcesOverlay,
} from './native-macos-package.mjs'

const packageJSON = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))

test('development entry points always name the isolated Development runtime', () => {
  assert.match(packageJSON.scripts.dev, /--runtime development(?:\s|$)/)
  assert.match(packageJSON.scripts['dev:restart-protocol'], /--runtime development(?:\s|$)/)
  assert.equal(packageJSON.scripts['dev:attach-production'], undefined)
  assert.equal(packageJSON.scripts['test:conformance'], undefined)
  assert.equal(packageJSON.scripts['test:conformance:production'], undefined)
})

test('Info.plist describes the native foreground application', () => {
  const plist = renderInfoPlist({
    version: '1.2.3',
    build: '45',
    sourceCommit: '0123456789abcdef',
    sourceBranch: 'main',
    sourceDirty: false,
  })

  assert.equal(BUNDLE_IDENTIFIER, 'com.markjoyeux.parley')
  assert.equal(MINIMUM_SYSTEM_VERSION, '14.0')
  assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>parley-native<\/string>/)
  assert.match(plist, /<key>CFBundleIdentifier<\/key>\s*<string>com\.markjoyeux\.parley<\/string>/)
  assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>1\.2\.3<\/string>/)
  assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>45<\/string>/)
  assert.match(plist, /<key>ParleySourceCommit<\/key>\s*<string>0123456789abcdef<\/string>/)
  assert.match(plist, /<key>ParleySourceBranch<\/key>\s*<string>main<\/string>/)
  assert.match(plist, /<key>ParleySourceDirty<\/key>\s*<false\/>/)
  assert.match(plist, /<key>LSMinimumSystemVersion<\/key>\s*<string>14\.0<\/string>/)
  assert.match(plist, /<key>LSApplicationCategoryType<\/key>\s*<string>public\.app-category\.developer-tools<\/string>/)
  assert.match(plist, /<key>LSEnvironment<\/key>\s*<dict>\s*<key>LANG<\/key>\s*<string>C\.UTF-8<\/string>\s*<\/dict>/)
  assert.match(plist, /<key>NSHighResolutionCapable<\/key>\s*<true\/>/)
  assert.match(plist, /<key>CFBundleURLSchemes<\/key>\s*<array>\s*<string>parley<\/string>/)
  assert.match(plist, /<key>LSItemContentTypes<\/key>\s*<array>\s*<string>public\.folder<\/string>/)
  assert.match(plist, /<key>NSMessage<\/key>\s*<string>openInParley<\/string>/)
  assert.match(plist, /<key>NSSendTypes<\/key>\s*<array>\s*<string>NSFilenamesPboardType<\/string>/)
  assert.match(plist, /<key>UTTypeIdentifier<\/key>\s*<string>com\.markjoyeux\.parley\.context-import<\/string>/)
  assert.match(plist, /<key>public\.filename-extension<\/key>\s*<array>\s*<string>parleycontext<\/string>/)
})

test('production Info.plist enables only a signed opt-in Sparkle update channel', () => {
  const publicKey = Buffer.alloc(32, 7).toString('base64')
  const plist = renderInfoPlist({
    version: '1.2.3',
    build: '45',
    sparklePublicKey: publicKey,
  })

  assert.match(plist, /<key>SUFeedURL<\/key>\s*<string>https:\/\/github\.com\/markjoyeuxcom\/parley\/releases\/latest\/download\/appcast\.xml<\/string>/)
  assert.match(plist, new RegExp(`<key>SUPublicEDKey<\\/key>\\s*<string>${publicKey}<\\/string>`))
  assert.match(plist, /<key>SURequireSignedFeed<\/key>\s*<true\/>/)
  assert.match(plist, /<key>SUVerifyUpdateBeforeExtraction<\/key>\s*<true\/>/)
  assert.match(plist, /<key>SUAllowsAutomaticUpdates<\/key>\s*<false\/>/)
  assert.match(plist, /<key>SUEnableAutomaticChecks<\/key>\s*<false\/>/)
  assert.match(plist, /<key>SUAutomaticallyUpdate<\/key>\s*<false\/>/)
  assert.match(plist, /<key>SUEnableSystemProfiling<\/key>\s*<false\/>/)

  assert.throws(
    () => renderInfoPlist({ version: '1.2.3', build: '45', sparklePublicKey: 'not-a-key' }),
    /32-byte base64 Ed25519 public key/,
  )
})

test('development Info.plist contains no inert or unsigned Sparkle configuration', () => {
  const plist = renderInfoPlist({ version: '1.2.3', build: '45' })
  assert.doesNotMatch(plist, /SUFeedURL|SUPublicEDKey|SUEnableAutomaticChecks/)
})

test('bundle contract contains the Parley executable, Sparkle and runtime/legal resources', () => {
  assert.deepEqual(requiredBundlePaths, [
    'Contents/Info.plist',
    'Contents/MacOS/parley-native',
    'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle',
    'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Ghostty',
    'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/terminfo',
    'Contents/Resources/Parley.icns',
    'Contents/Resources/runtime-components.json',
    'Contents/Resources/LICENSE',
    'Contents/Resources/NOTICE',
    'Contents/Resources/THIRD_PARTY_NOTICES.md',
  ])
})

test('Ghostty resource staging keeps the source immutable and makes the copy signable', (context) => {
  const root = mkdtempSync(join(tmpdir(), 'parley-ghostty-resource-check-'))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const bin = join(root, 'bin')
  const resources = join(root, 'Parley.app/Contents/Resources')
  const source = join(bin, GHOSTTY_RESOURCE_BUNDLE)
  const sourceGhostty = join(source, 'Ghostty/shell-integration/zsh/ghostty-integration')
  const sourceTerminfo = join(source, 'terminfo/67/ghostty')
  mkdirSync(join(source, 'Ghostty/shell-integration/zsh'), { recursive: true })
  mkdirSync(join(source, 'terminfo/67'), { recursive: true })
  mkdirSync(resources, { recursive: true })
  writeFileSync(sourceGhostty, 'integration')
  writeFileSync(sourceTerminfo, 'terminfo')
  chmodSync(sourceGhostty, 0o444)
  chmodSync(sourceTerminfo, 0o444)

  copyGhosttyResourceBundle({ bin, resources })

  assert.equal(statSync(sourceGhostty).mode & 0o200, 0)
  assert.equal(statSync(sourceTerminfo).mode & 0o200, 0)
  assert.notEqual(
    statSync(join(resources, GHOSTTY_RESOURCE_BUNDLE, 'Ghostty/shell-integration/zsh/ghostty-integration')).mode & 0o200,
    0,
  )
  assert.notEqual(
    statSync(join(resources, GHOSTTY_RESOURCE_BUNDLE, 'terminfo/67/ghostty')).mode & 0o200,
    0,
  )
})

test('Ghostty wrapper overlay prefers the signed app resources and keeps Bundle.module as development fallback', () => {
  const source = `import Foundation

public enum GhosttyRuntimeResources {
    public static var directoryURL: URL? {
        Bundle.module.url(forResource: "Ghostty", withExtension: nil)
    }

    public static var terminfoDirectoryURL: URL? {
        Bundle.module.url(forResource: "terminfo", withExtension: nil)
    }
}
`

  const patched = patchGhosttyRuntimeResourcesSource(source)
  assert.match(patched, /Bundle\.main\.resourceURL/)
  assert.match(patched, /Bundle\(url: packagedBundleURL\)/)
  assert.match(patched, /return Bundle\.module/)
  assert.equal(patched.match(/resourceBundle\.url\(forResource:/g)?.length, 2)
  assert.doesNotMatch(patched, /Bundle\.module\.url\(forResource:/)

  assert.throws(
    () => patchGhosttyRuntimeResourcesSource('unexpected wrapper source'),
    /Ghostty runtime resource source has an unexpected shape/,
  )
})

test('Ghostty wrapper overlay restores immutable checkout bytes and permissions after build', (context) => {
  const root = mkdtempSync(join(tmpdir(), 'parley-ghostty-overlay-check-'))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const sourceFile = join(root, 'GhosttyRuntimeResources.swift')
  const original = `public enum GhosttyRuntimeResources {
    public static var directoryURL: URL? {
        Bundle.module.url(forResource: "Ghostty", withExtension: nil)
    }
    public static var terminfoDirectoryURL: URL? {
        Bundle.module.url(forResource: "terminfo", withExtension: nil)
    }
}
`
  writeFileSync(sourceFile, original)
  chmodSync(sourceFile, 0o444)

  const result = withGhosttyRuntimeResourcesOverlay({
    sourceFile,
    build: () => {
      assert.match(readFileSync(sourceFile, 'utf8'), /private static let resourceBundle/)
      assert.notEqual(statSync(sourceFile).mode & 0o200, 0)
      return 'built'
    },
  })

  assert.equal(result, 'built')
  assert.equal(readFileSync(sourceFile, 'utf8'), original)
  assert.equal(statSync(sourceFile).mode & 0o200, 0)
  assert.throws(
    () => withGhosttyRuntimeResourcesOverlay({
      sourceFile,
      build: () => { throw new Error('build failed') },
    }),
    /build failed/,
  )
  assert.equal(readFileSync(sourceFile, 'utf8'), original)
  assert.equal(statSync(sourceFile).mode & 0o200, 0)
})

test('repository carries notices for Ghostty, its Swift wrapper, theme data and display link', () => {
  const notice = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8')
  assert.match(notice, /Ghostty/)
  assert.match(notice, /libghostty-spm/)
  assert.match(notice, /MSDisplayLink/)
  assert.match(notice, /Sparkle/)
  assert.match(notice, /Color scheme data sourced from iTerm2-Color-Schemes/)
  assert.match(notice, /Permission is hereby granted, free of charge/)
  assert.match(notice, /THE SOFTWARE IS PROVIDED "AS IS"/)
  assert.doesNotMatch(notice, /SwiftTerm/)
})

test('native package pins the registry-verified Sparkle release exactly', () => {
  const manifest = readFileSync(new URL('../native/Package.swift', import.meta.url), 'utf8')
  assert.match(
    manifest,
    /\.package\(url: "https:\/\/github\.com\/sparkle-project\/Sparkle", exact: "2\.9\.6"\)/,
  )
  assert.match(manifest, /\.product\(name: "Sparkle", package: "Sparkle"\)/)
})

test('repository and VS Code companion carry the same Apache-2.0 licence', () => {
  const license = readFileSync(new URL('../LICENSE', import.meta.url), 'utf8')
  const companionLicense = readFileSync(new URL('../vscode-extension/LICENSE', import.meta.url), 'utf8')
  const notice = readFileSync(new URL('../NOTICE', import.meta.url), 'utf8')

  assert.match(license, /Apache License/)
  assert.match(license, /Version 2\.0, January 2004/)
  assert.equal(companionLicense, license)
  assert.match(notice, /Parley/)
  assert.match(notice, /Copyright 2026 Mark Joyeux/)
})

test('bundle structure rejects a non-executable app and missing legal resources', (context) => {
  const root = mkdtempSync(join(tmpdir(), 'parley-bundle-check-'))
  context.after(() => rmSync(root, { recursive: true, force: true }))
  const bundle = join(root, 'Parley.app')
  mkdirSync(join(bundle, 'Contents/MacOS'), { recursive: true })
  mkdirSync(join(bundle, 'Contents/Resources'), { recursive: true })
  writeFileSync(join(bundle, 'Contents/Info.plist'), renderInfoPlist({ version: '1.0.0', build: '1' }))
  writeFileSync(join(bundle, 'Contents/MacOS/parley-native'), 'app')
  writeFileSync(join(bundle, 'Contents/Resources/Parley.icns'), 'icon')
  writeFileSync(join(bundle, 'Contents/Resources/runtime-components.json'), '{}')

  assert.deepEqual(validateBundleStructure(bundle), [
    'Contents/MacOS/parley-native is not executable',
    'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle is missing',
    'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Ghostty is missing',
    'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/terminfo is missing',
    'Contents/Resources/LICENSE is missing',
    'Contents/Resources/NOTICE is missing',
    'Contents/Resources/THIRD_PARTY_NOTICES.md is missing',
  ])

  chmodSync(join(bundle, 'Contents/MacOS/parley-native'), 0o755)
  writeFileSync(join(bundle, 'Contents/Resources/LICENSE'), 'license')
  writeFileSync(join(bundle, 'Contents/Resources/NOTICE'), 'notice')
  writeFileSync(join(bundle, 'Contents/Resources/THIRD_PARTY_NOTICES.md'), 'notice')
  mkdirSync(join(bundle, 'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/Ghostty'), { recursive: true })
  mkdirSync(join(bundle, 'Contents/Resources/GhosttyKit_GhosttyTerminal.bundle/terminfo'), { recursive: true })
  mkdirSync(join(bundle, 'Contents/Frameworks/Sparkle.framework/Versions/B'), { recursive: true })
  writeFileSync(join(bundle, 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'), 'framework')
  assert.deepEqual(validateBundleStructure(bundle), [])
})
