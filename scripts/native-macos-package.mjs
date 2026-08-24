#!/usr/bin/env node

import {
  accessSync,
  chmodSync,
  constants,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
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
export const CORE_LAUNCH_AGENT_LABEL = `${BUNDLE_IDENTIFIER}.core`
export const CORE_LAUNCH_AGENT_PLIST = `${CORE_LAUNCH_AGENT_LABEL}.plist`
export const MINIMUM_SYSTEM_VERSION = '14.0'
export const requiredBundlePaths = [
  'Contents/Info.plist',
  'Contents/MacOS/parley-native',
  'Contents/MacOS/parley-core-service',
  `Contents/Library/LaunchAgents/${CORE_LAUNCH_AGENT_PLIST}`,
  'Contents/Resources/Parley.icns',
  'Contents/Resources/runtime-components.json',
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
}) {
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
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MINIMUM_SYSTEM_VERSION}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Mark Joyeux</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
`
}

export function renderCoreLaunchAgentPlist() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CORE_LAUNCH_AGENT_LABEL}</string>
  <key>BundleProgram</key>
  <string>Contents/MacOS/parley-core-service</string>
  <key>ProgramArguments</key>
  <array>
    <string>parley-core-service</string>
    <string>--login-agent</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>${BUNDLE_IDENTIFIER}</string>
  </array>
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
  for (const product of ['parley-native', 'parley-core-service']) {
    run('node', [
      'scripts/run-native-swift.mjs',
      'build',
      '--configuration',
      'release',
      '--product',
      product,
      '--package-path',
      'native',
    ])
  }
  return run('node', [
    'scripts/run-native-swift.mjs',
    'build',
    '--configuration',
    'release',
    '--show-bin-path',
    '--package-path',
    'native',
  ], { capture: true })
}

function sign(path, identity) {
  const args = ['--force', '--sign', identity, '--options', 'runtime']
  if (identity !== '-') args.push('--timestamp')
  args.push(path)
  run('codesign', args)
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
      implementation: 'SwiftTerm',
      linkage: 'linked into parley-native',
    },
    core: {
      implementation: 'parley-core-service',
      location: 'Contents/MacOS/parley-core-service',
      optionalLaunchAtLogin: {
        mechanism: 'SMAppService LaunchAgent',
        plist: `Contents/Library/LaunchAgents/${CORE_LAUNCH_AGENT_PLIST}`,
        foregroundApplication: false,
      },
    },
    relay: {
      implementation: 'ParleyCore.RelayShim',
      delivery: 'generated from the bundled implementation at application launch',
      applicationInstall: '~/Library/Application Support/Parley Native/bin/parley',
      stableInstall: '~/.local/bin/parley',
      transport: 'owner-only local filesystem relay',
    },
    tmux: {
      integration: 'dedicated socket and configuration',
      delivery: 'detected external executable; never uses the user tmux server',
    },
  }, null, 2)}\n`
}

function replacePath(stagedPath, finalPath) {
  rmSync(finalPath, { recursive: true, force: true })
  renameSync(stagedPath, finalPath)
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
  const launchAgents = join(contents, 'Library', 'LaunchAgents')
  const resources = join(contents, 'Resources')
  mkdirSync(macOS, { recursive: true })
  mkdirSync(launchAgents, { recursive: true })
  mkdirSync(resources, { recursive: true })

  const appExecutable = join(macOS, 'parley-native')
  const coreExecutable = join(macOS, 'parley-core-service')
  copyFileSync(join(bin, 'parley-native'), appExecutable)
  copyFileSync(join(bin, 'parley-core-service'), coreExecutable)
  chmodSync(appExecutable, 0o755)
  chmodSync(coreExecutable, 0o755)
  copyFileSync(join(repositoryRoot, 'resources/icon.icns'), join(resources, 'Parley.icns'))
  writeFileSync(join(resources, 'runtime-components.json'), runtimeComponentsManifest(), { mode: 0o644 })
  writeFileSync(join(launchAgents, CORE_LAUNCH_AGENT_PLIST), renderCoreLaunchAgentPlist(), { mode: 0o644 })
  writeFileSync(
    join(contents, 'Info.plist'),
    renderInfoPlist({
      version,
      build,
      sourceCommit: source.commit,
      sourceBranch: source.branch,
      sourceDirty: source.dirty,
    }),
    { mode: 0o644 },
  )
  writeFileSync(join(contents, 'PkgInfo'), 'APPL????\n', { mode: 0o644 })

  const structureErrors = validateBundleStructure(bundle)
  if (structureErrors.length > 0) throw new Error(structureErrors.join('\n'))
  verifyArchitecture(appExecutable)
  verifyArchitecture(coreExecutable)

  run('xattr', ['-cr', bundle])
  const identity = process.env.PARLEY_CODESIGN_IDENTITY || '-'
  sign(coreExecutable, identity)
  sign(appExecutable, identity)
  sign(bundle, identity)
  run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', bundle])

  replacePath(bundle, finalBundle)
  rmSync(finalZip, { force: true })
  run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', finalBundle, finalZip])

  const dmgRoot = join(stagingRoot, 'dmg')
  mkdirSync(dmgRoot)
  run('ditto', [finalBundle, join(dmgRoot, 'Parley.app')])
  symlinkSync('/Applications', join(dmgRoot, 'Applications'))
  if (distributionReadme) {
    writeFileSync(join(dmgRoot, 'READ ME FIRST.txt'), distributionReadme, { mode: 0o644 })
  }
  rmSync(finalDMG, { force: true })
  run('hdiutil', [
    'create',
    '-volname',
    'Parley',
    '-srcfolder',
    dmgRoot,
    '-ov',
    '-format',
    'UDZO',
    finalDMG,
  ])

  rmSync(stagingRoot, { recursive: true, force: true })
  process.stdout.write(`Packaged ${basename(finalBundle)} ${version} (${build})\n`)
  process.stdout.write(`${finalBundle}\n${finalZip}\n${finalDMG}\n`)
  if (identity === '-') {
    process.stdout.write('Signing: local ad hoc hardened runtime (not notarized)\n')
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
