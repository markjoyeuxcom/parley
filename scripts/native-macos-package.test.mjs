import assert from 'node:assert/strict'
import { chmodSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  BUNDLE_IDENTIFIER,
  MINIMUM_SYSTEM_VERSION,
  requiredBundlePaths,
  renderInfoPlist,
  validateBundleStructure,
} from './native-macos-package.mjs'

test('Info.plist describes the native foreground application', () => {
  const plist = renderInfoPlist({ version: '1.2.3', build: '45' })

  assert.equal(BUNDLE_IDENTIFIER, 'com.markjoyeux.parley')
  assert.equal(MINIMUM_SYSTEM_VERSION, '14.0')
  assert.match(plist, /<key>CFBundleExecutable<\/key>\s*<string>parley-native<\/string>/)
  assert.match(plist, /<key>CFBundleIdentifier<\/key>\s*<string>com\.markjoyeux\.parley<\/string>/)
  assert.match(plist, /<key>CFBundleShortVersionString<\/key>\s*<string>1\.2\.3<\/string>/)
  assert.match(plist, /<key>CFBundleVersion<\/key>\s*<string>45<\/string>/)
  assert.match(plist, /<key>LSMinimumSystemVersion<\/key>\s*<string>14\.0<\/string>/)
  assert.match(plist, /<key>LSApplicationCategoryType<\/key>\s*<string>public\.app-category\.developer-tools<\/string>/)
  assert.match(plist, /<key>NSHighResolutionCapable<\/key>\s*<true\/>/)
})

test('bundle contract requires the UI, persistent core, icon and runtime manifest', () => {
  assert.deepEqual(requiredBundlePaths, [
    'Contents/Info.plist',
    'Contents/MacOS/parley-native',
    'Contents/MacOS/parley-core-service',
    'Contents/Resources/Parley.icns',
    'Contents/Resources/runtime-components.json',
  ])
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
  ])

  chmodSync(join(bundle, 'Contents/MacOS/parley-native'), 0o755)
  writeFileSync(join(bundle, 'Contents/MacOS/parley-core-service'), 'core', { mode: 0o755 })
  assert.deepEqual(validateBundleStructure(bundle), [])
})
