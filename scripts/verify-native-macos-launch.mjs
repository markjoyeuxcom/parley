#!/usr/bin/env node

import { existsSync } from 'node:fs'
import { spawn } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const maximumDiagnosticBytes = 32 * 1024

function delay(milliseconds, value) {
  return new Promise((resolveDelay) => setTimeout(() => resolveDelay(value), milliseconds))
}

function appendBounded(current, chunk) {
  const combined = `${current}${chunk}`
  return combined.length <= maximumDiagnosticBytes
    ? combined
    : combined.slice(combined.length - maximumDiagnosticBytes)
}

export async function verifyExecutableLaunch({
  executable,
  arguments: launchArguments = [],
  settleMilliseconds = 3_000,
  shutdownMilliseconds = 3_000,
}) {
  if (!Number.isInteger(settleMilliseconds) || settleMilliseconds < 1) {
    throw new Error('settleMilliseconds must be a positive integer')
  }
  if (!Number.isInteger(shutdownMilliseconds) || shutdownMilliseconds < 1) {
    throw new Error('shutdownMilliseconds must be a positive integer')
  }

  let output = ''
  const child = spawn(executable, launchArguments, {
    cwd: dirname(executable),
    env: process.env,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  child.stdout.on('data', (chunk) => { output = appendBounded(output, chunk) })
  child.stderr.on('data', (chunk) => { output = appendBounded(output, chunk) })

  const exited = new Promise((resolveExit) => {
    child.once('error', (error) => resolveExit({ kind: 'error', error }))
    child.once('exit', (code, signal) => resolveExit({ kind: 'exit', code, signal }))
  })
  const initial = await Promise.race([
    exited,
    delay(settleMilliseconds, { kind: 'running' }),
  ])

  if (initial.kind !== 'running') {
    const detail = output.trim()
    const status = initial.kind === 'error'
      ? initial.error.message
      : `status ${initial.code ?? 'unknown'}${initial.signal ? ` (${initial.signal})` : ''}`
    throw new Error(
      `${executable} exited before the ${settleMilliseconds} ms launch window with ${status}`
      + `${detail ? `:\n${detail}` : ''}`,
    )
  }

  child.kill('SIGTERM')
  const shutdown = await Promise.race([
    exited,
    delay(shutdownMilliseconds, { kind: 'shutdown-timeout' }),
  ])
  if (shutdown.kind === 'shutdown-timeout') {
    child.kill('SIGKILL')
    await exited
    throw new Error(`${executable} did not stop after the packaged-launch check`)
  }
}

async function main() {
  const bundle = resolve(repositoryRoot, process.argv[2] ?? 'dist/Parley.app')
  const executable = join(bundle, 'Contents/MacOS/parley-native')
  if (!existsSync(executable)) {
    throw new Error(`packaged Parley executable is missing: ${executable}`)
  }
  await verifyExecutableLaunch({ executable })
  process.stdout.write(`Packaged launch check passed: ${bundle}\n`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  })
}
