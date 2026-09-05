#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir, homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

// This is an explicit opt-in, captured before build-child capability cleanup.
const swiftPMCompatibility = process.platform === 'darwin'
  && process.env.PARLEY_PANE === '1'
  && ['claude', 'codex', 'agy', 'copilot'].includes(process.env.PARLEY_PANE_KIND)
  && process.env.PARLEY_SWIFTPM_COMPATIBILITY === '1'
function swiftArguments(args) {
  return swiftPMCompatibility && ['build', 'run', 'test', 'package'].includes(args[0])
    ? [args[0], '--disable-sandbox', ...args.slice(1)]
    : args
}

const cacheRoot = join(tmpdir(), 'parley-native-swift-cache')
mkdirSync(cacheRoot, { recursive: true })

const environment = {
  ...process.env,
  CLANG_MODULE_CACHE_PATH: join(cacheRoot, 'clang'),
  SWIFTPM_MODULECACHE_OVERRIDE: join(cacheRoot, 'swiftpm'),
}

// A development app must never inherit its launching agent's relay capability.
for (const key of Object.keys(environment)) {
  if (key.startsWith('PARLEY_') || key === 'TMUX' || key === 'TMUX_PANE') delete environment[key]
}
const managedBins = new Set(['Parley Native', 'Parley Native Development']
  .flatMap(name => ['bin', 'agent-protocol/swiftpm-bin'].map(directory =>
    join(homedir(), 'Library/Application Support', name, directory))))
if (process.env.PARLEY_SWIFT_COMMAND?.endsWith('/agent-protocol/swiftpm-bin/swift')) {
  managedBins.add(dirname(process.env.PARLEY_SWIFT_COMMAND))
}
environment.PATH = (environment.PATH || '/usr/bin:/bin').split(':')
  .filter(entry => !managedBins.has(entry)).join(':')

function output(command, args, cwd) {
  const result = spawnSync(command, args, { encoding: 'utf8', env: environment, cwd })
  return result.status === 0 ? result.stdout.trim() : ''
}

const repositoryRoot = fileURLToPath(new URL('../', import.meta.url))

function applyDevelopmentBuildMetadata() {
  const packageJSON = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'))
  if (typeof packageJSON.version === 'string') environment.PARLEY_BUILD_VERSION = packageJSON.version

  const commit = output('git', ['rev-parse', '--verify', 'HEAD'], repositoryRoot)
  if (!commit) return
  environment.PARLEY_BUILD_COMMIT = commit
  environment.PARLEY_BUILD_BRANCH = output('git', ['branch', '--show-current'], repositoryRoot) || 'detached'
  environment.PARLEY_BUILD_NUMBER = output('git', ['rev-list', '--count', 'HEAD'], repositoryRoot) || 'development'
  const status = spawnSync('git', ['status', '--porcelain', '--untracked-files=normal'], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    env: environment,
  })
  if (status.status === 0) environment.PARLEY_BUILD_DIRTY = status.stdout.trim() ? '1' : '0'
}

function compilerAccepts(sdk) {
  const result = spawnSync(
    'swiftc',
    ['-typecheck', '-sdk', sdk, '-module-cache-path', environment.CLANG_MODULE_CACHE_PATH, '-'],
    {
      input: 'import Foundation\n#if compiler(>=6.2)\nprotocol ParleySDKProbe: SendableMetatype {}\n#endif\n',
      stdio: ['pipe', 'ignore', 'ignore'],
      env: environment,
    },
  )
  return result.status === 0
}

function installedSDKs() {
  const directory = '/Library/Developer/CommandLineTools/SDKs'
  let names = []
  try {
    names = readdirSync(directory)
      .filter((name) => /^MacOSX\d.*\.sdk$/.test(name))
      // Parley targets macOS 14. Start with the oldest installed SDK: during a
      // partial Command Line Tools update it is usually the stable one, while
      // the newly selected default can be ahead of its own Swift interfaces.
      .sort((left, right) => left.localeCompare(right, undefined, { numeric: true }))
  } catch {
    return []
  }

  const seen = new Set()
  const paths = []
  for (const name of names) {
    try {
      const path = realpathSync(join(directory, name))
      if (!seen.has(path)) {
        seen.add(path)
        paths.push(path)
      }
    } catch {
      // An incomplete Command Line Tools update can leave a broken SDK link.
    }
  }
  return paths
}

function selectSDK() {
  if (process.env.SDKROOT) return process.env.SDKROOT

  const current = output('xcrun', ['--sdk', 'macosx', '--show-sdk-path'])
  const installed = installedSDKs()
  const fingerprint = createHash('sha256')
    .update('sendable-metatype-sdk-probe-v1')
    .update(output('swiftc', ['--version']))
    .update(current)
    .update(
      installed
        .map((sdk) => {
          const settings = join(sdk, 'SDKSettings.json')
          return `${sdk}:${existsSync(settings) ? statSync(settings).mtimeMs : 0}`
        })
        .join('|'),
    )
    .digest('hex')
  const cacheFile = join(cacheRoot, 'selected-sdk.json')
  try {
    const cached = JSON.parse(readFileSync(cacheFile, 'utf8'))
    if (cached.fingerprint === fingerprint && typeof cached.sdk === 'string' && existsSync(cached.sdk)) {
      return cached.sdk
    }
  } catch {
    // A missing or stale probe cache is expected after toolchain updates.
  }

  const candidates = [...installed, current].filter(Boolean)
  for (const sdk of [...new Set(candidates)]) {
    if (compilerAccepts(sdk)) {
      writeFileSync(cacheFile, JSON.stringify({ fingerprint, sdk }))
      return sdk
    }
  }

  process.stderr.write(
    'No installed macOS SDK is compatible with the active Swift compiler. Update Command Line Tools and try again.\n',
  )
  process.exit(1)
}

environment.SDKROOT = selectSDK()
const requested = process.argv.slice(2)
let result
if (requested[0] === 'dev') {
  let packagePath = '.'
  const appArguments = []
  for (let index = 1; index < requested.length; index += 1) {
    if (requested[index] === '--package-path') {
      packagePath = requested[index + 1] ?? packagePath
      index += 1
    } else {
      appArguments.push(requested[index])
    }
  }

  const build = spawnSync('swift', swiftArguments(['build', '--package-path', packagePath]), {
    stdio: 'inherit',
    env: environment,
  })
  if (build.error) {
    process.stderr.write(`Could not start Swift: ${build.error.message}\n`)
    process.exit(1)
  }
  if (build.status !== 0) process.exit(build.status ?? 1)

  const binPath = output('swift', swiftArguments(['build', '--show-bin-path', '--package-path', packagePath]))
  if (!binPath) {
    process.stderr.write('Swift did not report the native build directory.\n')
    process.exit(1)
  }
  const executable = join(binPath, 'parley-native')
  applyDevelopmentBuildMetadata()
  result = spawnSync(executable, appArguments, { stdio: 'inherit', env: environment })
} else {
  result = spawnSync('swift', swiftArguments(requested), { stdio: 'inherit', env: environment })
}
if (result.error) {
  process.stderr.write(`Could not start Swift: ${result.error.message}\n`)
  process.exit(1)
}
process.exit(result.status ?? 1)
