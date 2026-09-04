#!/usr/bin/env node

import {
  accessSync,
  chmodSync,
  constants,
  cpSync,
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'

export const BUNDLE_IDENTIFIER = 'com.markjoyeux.parley'
export const MINIMUM_SYSTEM_VERSION = '14.0'
export const UTF8_FALLBACK_LOCALE = 'C.UTF-8'
export const GHOSTTY_RESOURCE_BUNDLE = 'GhosttyKit_GhosttyTerminal.bundle'
export const SPARKLE_FRAMEWORK = 'Sparkle.framework'
export const SPARKLE_FEED_URL =
  'https://github.com/markjoyeuxcom/parley/releases/latest/download/appcast.xml'
const GHOSTTY_RUNTIME_RESOURCES_SOURCE =
  'Sources/GhosttyTerminal/Configuration/GhosttyRuntimeResources.swift'
export const requiredBundlePaths = [
  'Contents/Info.plist',
  'Contents/MacOS/parley-native',
  `Contents/Frameworks/${SPARKLE_FRAMEWORK}/Versions/B/Sparkle`,
  `Contents/Resources/${GHOSTTY_RESOURCE_BUNDLE}/Ghostty`,
  `Contents/Resources/${GHOSTTY_RESOURCE_BUNDLE}/terminfo`,
  'Contents/Resources/Parley.icns',
  'Contents/Resources/runtime-components.json',
  'Contents/Resources/LICENSE',
  'Contents/Resources/NOTICE',
  'Contents/Resources/THIRD_PARTY_NOTICES.md',
]

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function xml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

export function renderInfoPlist({
  version,
  build,
  sourceCommit = 'unknown',
  sourceBranch = 'unknown',
  sourceDirty = false,
  sparklePublicKey,
}) {
  let sparkleConfiguration = ''
  if (sparklePublicKey !== undefined) {
    let decoded
    try {
      decoded = Buffer.from(sparklePublicKey, 'base64')
    } catch {
      decoded = Buffer.alloc(0)
    }
    if (decoded.length !== 32 || decoded.toString('base64') !== sparklePublicKey) {
      throw new Error('PARLEY_SPARKLE_PUBLIC_ED_KEY must be a canonical 32-byte base64 Ed25519 public key')
    }
    sparkleConfiguration = `  <key>SUFeedURL</key>
  <string>${xml(SPARKLE_FEED_URL)}</string>
  <key>SUPublicEDKey</key>
  <string>${xml(sparklePublicKey)}</string>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUEnableSystemProfiling</key>
  <false/>
`
  }
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Parley</string>
  <key>CFBundleExecutable</key>
  <string>parley-native</string>
  <key>CFBundleIconFile</key>
  <string>Parley</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_IDENTIFIER}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Parley</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>CFBundleURLName</key>
      <string>${BUNDLE_IDENTIFIER}.workspace</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>parley</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Folder</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.folder</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Parley Context Import</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>${BUNDLE_IDENTIFIER}.context-import</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>${BUNDLE_IDENTIFIER}.context-import</string>
      <key>UTTypeDescription</key>
      <string>Parley Context Import</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.json</string>
        <string>public.data</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>parleycontext</string>
        </array>
        <key>public.mime-type</key>
        <string>application/vnd.parley.context+json</string>
      </dict>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>${xml(version)}</string>
  <key>CFBundleVersion</key>
  <string>${xml(build)}</string>
  <key>ParleySourceCommit</key>
  <string>${xml(sourceCommit)}</string>
  <key>ParleySourceBranch</key>
  <string>${xml(sourceBranch)}</string>
  <key>ParleySourceDirty</key>
  ${sourceDirty ? '<true/>' : '<false/>'}
${sparkleConfiguration}  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MINIMUM_SYSTEM_VERSION}</string>
  <key>LSEnvironment</key>
  <dict>
    <key>LANG</key>
    <string>${UTF8_FALLBACK_LOCALE}</string>
  </dict>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Open in Parley</string>
      </dict>
      <key>NSMessage</key>
      <string>openInParley</string>
      <key>NSPortName</key>
      <string>Parley</string>
      <key>NSSendTypes</key>
      <array>
        <string>NSFilenamesPboardType</string>
      </array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Mark Joyeux</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
`
}

export function validateBundleStructure(bundle) {
  const errors = []
  for (const relativePath of requiredBundlePaths) {
    const path = join(bundle, relativePath)
    if (!existsSync(path)) {
      errors.push(`${relativePath} is missing`)
      continue
    }
    if (relativePath.startsWith('Contents/MacOS/')) {
      try {
        accessSync(path, constants.X_OK)
      } catch {
        errors.push(`${relativePath} is not executable`)
      }
    }
  }
  return errors
}

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

function packageVersion() {
  const packageJSON = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8'))
  if (typeof packageJSON.version !== 'string' || !/^\d+\.\d+\.\d+/.test(packageJSON.version)) {
    throw new Error('package.json must contain a numeric application version')
  }
  return packageJSON.version
}

function buildNumber() {
  if (process.env.PARLEY_BUILD_NUMBER) {
    if (!/^\d+$/.test(process.env.PARLEY_BUILD_NUMBER)) {
      throw new Error('PARLEY_BUILD_NUMBER must contain digits only')
    }
    return process.env.PARLEY_BUILD_NUMBER
  }
  return run('git', ['rev-list', '--count', 'HEAD'], { capture: true }) || '1'
}

function sourceMetadata() {
  return {
    commit: run('git', ['rev-parse', '--verify', 'HEAD'], { capture: true }),
    branch: run('git', ['branch', '--show-current'], { capture: true }) || 'detached',
    dirty: Boolean(run('git', ['status', '--porcelain', '--untracked-files=normal'], { capture: true })),
  }
}

function swiftReleaseBinPath() {
  const buildArguments = [
    'scripts/run-native-swift.mjs',
    'build',
    '--configuration',
    'release',
    '--product',
    'parley-native',
    '--package-path',
    'native',
    '--disable-sandbox',
  ]
  run('node', buildArguments)
  const bin = run('node', [
    'scripts/run-native-swift.mjs',
    'build',
    '--configuration',
    'release',
    '--show-bin-path',
    '--package-path',
    'native',
    '--disable-sandbox',
  ], { capture: true })
  const runtimeResources = join(
    repositoryRoot,
    'native/.build/checkouts/libghostty-spm',
    GHOSTTY_RUNTIME_RESOURCES_SOURCE,
  )
  if (!existsSync(runtimeResources)) {
    throw new Error(`SwiftPM checkout is missing libghostty-spm/${GHOSTTY_RUNTIME_RESOURCES_SOURCE}`)
  }
  withGhosttyRuntimeResourcesOverlay({
    sourceFile: runtimeResources,
    build: () => run('node', buildArguments),
  })
  return bin
}

export function codesignArguments(path, identity, { preserveEntitlements = false } = {}) {
  const args = ['--force', '--sign', identity]
  // Ad-hoc signatures do not carry a Team ID. Enabling hardened-runtime
  // library validation on that host makes dyld reject the likewise ad-hoc
  // Sparkle framework even though codesign --verify succeeds. Test betas are
  // explicitly unnotarized; production Developer ID builds remain hardened.
  if (identity !== '-') args.push('--options', 'runtime', '--timestamp')
  if (preserveEntitlements) args.push('--preserve-metadata=entitlements')
  args.push(path)
  return args
}

function sign(path, identity, options = {}) {
  const args = codesignArguments(path, identity, options)
  run('codesign', args)
}

function signSparkleFramework(framework, identity) {
  const nested = [
    { path: 'Versions/B/XPCServices/Installer.xpc' },
    { path: 'Versions/B/XPCServices/Downloader.xpc', preserveEntitlements: true },
    { path: 'Versions/B/Autoupdate' },
    { path: 'Versions/B/Updater.app' },
  ]
  for (const item of nested) {
    const path = join(framework, item.path)
    if (existsSync(path)) {
      sign(path, identity, { preserveEntitlements: item.preserveEntitlements ?? false })
    }
  }
  sign(framework, identity)
}

function verifyArchitecture(executable) {
  const architectures = run('lipo', ['-archs', executable], { capture: true }).split(/\s+/)
  if (!architectures.includes('arm64')) {
    throw new Error(`${executable} does not contain an arm64 executable`)
  }
}

function runtimeComponentsManifest() {
  return `${JSON.stringify({
    schemaVersion: 1,
    terminal: {
      implementation: 'GhosttyKit',
      linkage: 'embedded in parley-native through GhosttyTerminal',
      lifetime: 'window close keeps panes; application quit ends pane processes',
    },
    core: {
      implementation: 'ParleyNative.AppResidentCoordinationCore',
      location: 'parley-native process',
      lifetime: 'same as the application and retained Ghostty panes',
    },
    relay: {
      implementation: 'ParleyCore.RelayShim',
      delivery: 'generated from the bundled implementation at application launch',
      applicationInstall: '~/Library/Application Support/Parley Native/bin/parley',
      stableInstall: '~/.local/bin/parley',
      transport: 'owner-only local filesystem relay',
    },
  }, null, 2)}\n`
}

function replacePath(stagedPath, finalPath) {
  rmSync(finalPath, { recursive: true, force: true })
  renameSync(stagedPath, finalPath)
}

function makeTreeOwnerWritable(path) {
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink()) {
    throw new Error(`${GHOSTTY_RESOURCE_BUNDLE} must not contain symbolic links`)
  }
  chmodSync(path, metadata.mode | 0o200)
  if (!metadata.isDirectory()) return
  for (const child of readdirSync(path)) {
    makeTreeOwnerWritable(join(path, child))
  }
}

export function patchGhosttyRuntimeResourcesSource(source) {
  const declaration = 'public enum GhosttyRuntimeResources {\n'
  const moduleLookup = 'Bundle.module.url(forResource:'
  const declarationCount = source.split(declaration).length - 1
  const lookupCount = source.split(moduleLookup).length - 1
  if (declarationCount !== 1 || lookupCount !== 2 || source.includes('private static let resourceBundle')) {
    throw new Error('Ghostty runtime resource source has an unexpected shape')
  }
  const resolver = `${declaration}    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL {
            let packagedBundleURL = resourceURL
                .appendingPathComponent("${GHOSTTY_RESOURCE_BUNDLE}", isDirectory: true)
            if let packagedBundle = Bundle(url: packagedBundleURL) {
                return packagedBundle
            }
        }
        return Bundle.module
    }()

`
  return source
    .replace(declaration, resolver)
    .replaceAll(moduleLookup, 'resourceBundle.url(forResource:')
}

export function withGhosttyRuntimeResourcesOverlay({ sourceFile, build }) {
  const originalSource = readFileSync(sourceFile, 'utf8')
  const patchedSource = patchGhosttyRuntimeResourcesSource(originalSource)
  const originalMode = lstatSync(sourceFile).mode & 0o7777
  chmodSync(sourceFile, originalMode | 0o200)
  try {
    writeFileSync(sourceFile, patchedSource)
    return build()
  } finally {
    writeFileSync(sourceFile, originalSource)
    chmodSync(sourceFile, originalMode)
  }
}

export function copyGhosttyResourceBundle({ bin, resources }) {
  const source = join(bin, GHOSTTY_RESOURCE_BUNDLE)
  if (!existsSync(source)) {
    throw new Error(`SwiftPM output is missing ${GHOSTTY_RESOURCE_BUNDLE}`)
  }
  const destination = join(resources, GHOSTTY_RESOURCE_BUNDLE)
  cpSync(source, destination, { recursive: true, errorOnExist: true })
  makeTreeOwnerWritable(destination)
}

export function copySparkleFramework({ bin, frameworks }) {
  const source = join(bin, SPARKLE_FRAMEWORK)
  if (!existsSync(source)) throw new Error(`SwiftPM output is missing ${SPARKLE_FRAMEWORK}`)
  cpSync(source, join(frameworks, SPARKLE_FRAMEWORK), {
    recursive: true,
    errorOnExist: true,
    verbatimSymlinks: true,
  })
}

export function createNativeMacOSArchives({ bundle, zip, dmg, distributionReadme }) {
  const archiveRoot = mkdtempSync(join(tmpdir(), 'parley-archives-'))
  try {
    rmSync(zip, { force: true })
    run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', bundle, zip])

    const dmgRoot = join(archiveRoot, 'dmg')
    mkdirSync(dmgRoot)
    run('ditto', [bundle, join(dmgRoot, 'Parley.app')])
    symlinkSync('/Applications', join(dmgRoot, 'Applications'))
    if (distributionReadme) {
      writeFileSync(join(dmgRoot, 'READ ME FIRST.txt'), distributionReadme, { mode: 0o644 })
    }
    rmSync(dmg, { force: true })
    run('hdiutil', [
      'create',
      '-volname',
      'Parley',
      '-srcfolder',
      dmgRoot,
      '-ov',
      '-format',
      'UDZO',
      dmg,
    ])
  } finally {
    rmSync(archiveRoot, { recursive: true, force: true })
  }
}

export function packageNativeMacOS({ distributionReadme } = {}) {
  if (process.platform !== 'darwin') {
    throw new Error('Native macOS packaging must run on macOS')
  }

  const version = packageVersion()
  const build = buildNumber()
  const source = sourceMetadata()
  const bin = swiftReleaseBinPath()
  const outputDirectory = join(repositoryRoot, 'dist')
  const finalBundle = join(outputDirectory, 'Parley.app')
  const archiveBase = `Parley-${version}-mac-arm64`
  const finalZip = join(outputDirectory, `${archiveBase}.zip`)
  const finalDMG = join(outputDirectory, `${archiveBase}.dmg`)
  mkdirSync(outputDirectory, { recursive: true })

  const stagingRoot = mkdtempSync(join(tmpdir(), 'parley-package-'))
  const bundle = join(stagingRoot, 'Parley.app')
  const contents = join(bundle, 'Contents')
  const macOS = join(contents, 'MacOS')
  const frameworks = join(contents, 'Frameworks')
  const resources = join(contents, 'Resources')
  mkdirSync(macOS, { recursive: true })
  mkdirSync(frameworks, { recursive: true })
  mkdirSync(resources, { recursive: true })

  const appExecutable = join(macOS, 'parley-native')
  copyFileSync(join(bin, 'parley-native'), appExecutable)
  chmodSync(appExecutable, 0o755)
  run('install_name_tool', ['-add_rpath', '@executable_path/../Frameworks', appExecutable])
  copySparkleFramework({ bin, frameworks })
  copyGhosttyResourceBundle({ bin, resources })
  copyFileSync(join(repositoryRoot, 'resources/icon.icns'), join(resources, 'Parley.icns'))
  copyFileSync(join(repositoryRoot, 'LICENSE'), join(resources, 'LICENSE'))
  copyFileSync(join(repositoryRoot, 'NOTICE'), join(resources, 'NOTICE'))
  copyFileSync(
    join(repositoryRoot, 'THIRD_PARTY_NOTICES.md'),
    join(resources, 'THIRD_PARTY_NOTICES.md'),
  )
  writeFileSync(join(resources, 'runtime-components.json'), runtimeComponentsManifest(), { mode: 0o644 })
  writeFileSync(
    join(contents, 'Info.plist'),
    renderInfoPlist({
      version,
      build,
      sourceCommit: source.commit,
      sourceBranch: source.branch,
      sourceDirty: source.dirty,
      sparklePublicKey: process.env.PARLEY_SPARKLE_PUBLIC_ED_KEY,
    }),
    { mode: 0o644 },
  )
  writeFileSync(join(contents, 'PkgInfo'), 'APPL????\n', { mode: 0o644 })

  const structureErrors = validateBundleStructure(bundle)
  if (structureErrors.length > 0) throw new Error(structureErrors.join('\n'))
  verifyArchitecture(appExecutable)

  run('xattr', ['-cr', bundle])
  const identity = process.env.PARLEY_CODESIGN_IDENTITY || '-'
  signSparkleFramework(join(frameworks, SPARKLE_FRAMEWORK), identity)
  sign(appExecutable, identity)
  sign(bundle, identity)
  run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle])

  replacePath(bundle, finalBundle)
  createNativeMacOSArchives({
    bundle: finalBundle,
    zip: finalZip,
    dmg: finalDMG,
    distributionReadme,
  })

  rmSync(stagingRoot, { recursive: true, force: true })
  process.stdout.write(`Packaged ${basename(finalBundle)} ${version} (${build})\n`)
  process.stdout.write(`${finalBundle}\n${finalZip}\n${finalDMG}\n`)
  if (identity === '-') {
    process.stdout.write('Signing: local ad hoc test beta (not hardened or notarized)\n')
  } else {
    process.stdout.write(`Signing: ${identity} (notarization is a separate release step)\n`)
  }
  return {
    version,
    build,
    bundle: finalBundle,
    zip: finalZip,
    dmg: finalDMG,
    signing: identity === '-' ? { kind: 'ad-hoc', identity: null } : { kind: 'developer-id', identity },
  }
}

const invokedPath = process.argv[1] ? pathToFileURL(resolve(process.argv[1])).href : ''
if (invokedPath === import.meta.url) {
  try {
    packageNativeMacOS()
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : error}\n`)
    process.exit(1)
  }
}
