#!/usr/bin/env node

import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'

const cacheRoot = join(tmpdir(), 'parley-native-swift-cache')
mkdirSync(cacheRoot, { recursive: true })

const environment = {
  ...process.env,
  CLANG_MODULE_CACHE_PATH: join(cacheRoot, 'clang'),
  SWIFTPM_MODULECACHE_OVERRIDE: join(cacheRoot, 'swiftpm'),
}

function output(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', env: environment })
  return result.status === 0 ? result.stdout.trim() : ''
}

function compilerAccepts(sdk) {
  const result = spawnSync(
    'swiftc',
    ['-typecheck', '-sdk', sdk, '-module-cache-path', environment.CLANG_MODULE_CACHE_PATH, '-'],
    { input: 'import Foundation\n', stdio: ['pipe', 'ignore', 'ignore'], env: environment },
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
const result = spawnSync('swift', process.argv.slice(2), { stdio: 'inherit', env: environment })
if (result.error) {
  process.stderr.write(`Could not start Swift: ${result.error.message}\n`)
  process.exit(1)
}
process.exit(result.status ?? 1)
