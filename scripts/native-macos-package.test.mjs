import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  BUNDLE_IDENTIFIER,
  CORE_LAUNCH_AGENT_LABEL,
  CORE_LAUNCH_AGENT_PLIST,
  MINIMUM_SYSTEM_VERSION,
  requiredBundlePaths,
  renderCoreLaunchAgentPlist,
  renderInfoPlist,
  validateBundleStructure,
} from './native-macos-package.mjs'

const packageJSON = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))

test('development entry points always name an isolated runtime', () => {
  assert.match(packageJSON.scripts.dev, /--runtime development(?:\s|$)/)
  assert.match(packageJSON.scripts['dev:restart-protocol'], /--runtime development(?:\s|$)/)
  assert.match(packageJSON.scripts['dev:attach-production'], /--runtime attached-production(?:\s|$)/)
  assert.match(packageJSON.scripts['test:conformance'], /--runtime development(?:\s|$)/)
  assert.match(packageJSON.scripts['test:conformance:production'], /--runtime production(?:\s|$)/)
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
  assert.match(plist, /<key>NSHighResolutionCapable<\/key>\s*<true\/>/)
  assert.match(plist, /<key>CFBundleURLSchemes<\/key>\s*<array>\s*<string>parley<\/string>/)
  assert.match(plist, /<key>LSItemContentTypes<\/key>\s*<array>\s*<string>public\.folder<\/string>/)
  assert.match(plist, /<key>NSMessage<\/key>\s*<string>openInParley<\/string>/)
  assert.match(plist, /<key>NSSendTypes<\/key>\s*<array>\s*<string>NSFilenamesPboardType<\/string>/)
  assert.match(plist, /<key>UTTypeIdentifier<\/key>\s*<string>com\.markjoyeux\.parley\.context-import<\/string>/)
  assert.match(plist, /<key>public\.filename-extension<\/key>\s*<array>\s*<string>parleycontext<\/string>/)
  assert.match(plist, /<key>CFBundleTypeName<\/key>\s*<string>Parley Context Import<\/string>/)
  assert.match(plist, /<key>LSItemContentTypes<\/key>\s*<array>\s*<string>com\.markjoyeux\.parley\.context-import<\/string>/)
})

test('bundle contract requires the UI, persistent core, conformance runner, launch agent, icon and runtime manifest', () => {
  assert.deepEqual(requiredBundlePaths, [
    'Contents/Info.plist',
    'Contents/MacOS/parley-native',
    'Contents/MacOS/parley-core-service',
    'Contents/MacOS/parley-conformance',
    'Contents/Library/LaunchAgents/com.markjoyeux.parley.core.plist',
    'Contents/Resources/Parley.icns',
    'Contents/Resources/runtime-components.json',
    'Contents/Resources/LICENSE',
    'Contents/Resources/NOTICE',
    'Contents/Resources/THIRD_PARTY_NOTICES.md',
  ])
})

test('repository carries the complete linked SwiftTerm notice', () => {
  const notice = readFileSync(new URL('../THIRD_PARTY_NOTICES.md', import.meta.url), 'utf8')
  assert.match(notice, /Copyright \(c\) 2019-2026 Miguel de Icaza/)
  assert.match(notice, /Copyright \(c\) 2017-2019, The xterm\.js authors/)
  assert.match(notice, /Permission is hereby granted, free of charge/)
  assert.match(notice, /THE SOFTWARE IS PROVIDED "AS IS"/)
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

test('launch agent starts only the relocatable bundled core in login mode', () => {
  const plist = renderCoreLaunchAgentPlist()

  assert.equal(CORE_LAUNCH_AGENT_LABEL, 'com.markjoyeux.parley.core')
  assert.equal(CORE_LAUNCH_AGENT_PLIST, 'com.markjoyeux.parley.core.plist')
  assert.match(plist, /<key>Label<\/key>\s*<string>com\.markjoyeux\.parley\.core<\/string>/)
  assert.match(plist, /<key>BundleProgram<\/key>\s*<string>Contents\/MacOS\/parley-core-service<\/string>/)
  assert.match(plist, /<key>ProgramArguments<\/key>\s*<array>\s*<string>parley-core-service<\/string>\s*<string>--login-agent<\/string>/)
  assert.match(plist, /<key>RunAtLoad<\/key>\s*<true\/>/)
  assert.match(plist, /<key>ProcessType<\/key>\s*<string>Background<\/string>/)
  assert.match(plist, /<key>AssociatedBundleIdentifiers<\/key>\s*<array>\s*<string>com\.markjoyeux\.parley<\/string>/)
  assert.doesNotMatch(plist, /<key>Program<\/key>/)
  assert.doesNotMatch(plist, /parley-native/)
})

test('bundle structure rejects a missing core and non-executable binaries', (context) => {
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
    'Contents/MacOS/parley-core-service is missing',
    'Contents/MacOS/parley-conformance is missing',
    'Contents/Library/LaunchAgents/com.markjoyeux.parley.core.plist is missing',
    'Contents/Resources/LICENSE is missing',
    'Contents/Resources/NOTICE is missing',
    'Contents/Resources/THIRD_PARTY_NOTICES.md is missing',
  ])

  chmodSync(join(bundle, 'Contents/MacOS/parley-native'), 0o755)
  writeFileSync(join(bundle, 'Contents/MacOS/parley-core-service'), 'core', { mode: 0o755 })
  writeFileSync(join(bundle, 'Contents/MacOS/parley-conformance'), 'conformance', { mode: 0o755 })
  mkdirSync(join(bundle, 'Contents/Library/LaunchAgents'), { recursive: true })
  writeFileSync(
    join(bundle, 'Contents/Library/LaunchAgents/com.markjoyeux.parley.core.plist'),
    renderCoreLaunchAgentPlist(),
  )
  writeFileSync(join(bundle, 'Contents/Resources/LICENSE'), 'license')
  writeFileSync(join(bundle, 'Contents/Resources/NOTICE'), 'notice')
  writeFileSync(join(bundle, 'Contents/Resources/THIRD_PARTY_NOTICES.md'), 'notice')
  assert.deepEqual(validateBundleStructure(bundle), [])
})
