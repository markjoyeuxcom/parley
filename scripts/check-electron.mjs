#!/usr/bin/env node
/**
 * Verifies the installed Electron binary matches this machine.
 *
 * `electron/install.js` skips downloading when `dist/` already exists, so a tree
 * that has been shared between platforms — a Linux container mounting a macOS
 * checkout, a synced folder, a committed node_modules — keeps whichever binary
 * landed first. The failure that produces is `spawn ENOEXEC` from deep inside
 * electron-vite, which says nothing about the actual cause.
 *
 * Runs before `dev` and `build`. Never blocks on its own uncertainty: if
 * anything here cannot be determined, it stays quiet and lets the real tooling
 * run.
 */
import { existsSync, openSync, readSync, closeSync, readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const electronDir = join(root, 'node_modules', 'electron')
const pathFile = join(electronDir, 'path.txt')

const EXPECTED_ENTRY = {
  darwin: 'Electron.app/Contents/MacOS/Electron',
  linux: 'electron',
  win32: 'electron.exe',
}

const MAGIC = {
  '7f454c46': 'linux',
  cffaedfe: 'darwin',
  cefaedfe: 'darwin',
  cafebabe: 'darwin',
  bebafeca: 'darwin',
  '4d5a9000': 'win32',
}

function fail(message) {
  process.stderr.write(`\n  Electron install is wrong for this machine.\n\n  ${message}\n\n  Fix:\n    rm -rf node_modules/electron/dist node_modules/electron/path.txt\n    node node_modules/electron/install.js\n\n`)
  process.exit(1)
}

if (!existsSync(electronDir)) process.exit(0)

if (!existsSync(pathFile)) {
  fail('The Electron binary has not been downloaded yet.')
}

let entry
try {
  entry = readFileSync(pathFile, 'utf8').trim()
} catch {
  process.exit(0)
}

const expected = EXPECTED_ENTRY[process.platform]
if (expected && entry !== expected) {
  fail(
    `node_modules/electron holds a ${entry === 'electron' ? 'Linux' : entry.endsWith('.exe') ? 'Windows' : 'foreign'} build ` +
      `(path.txt says "${entry}"), but this is ${process.platform}.`,
  )
}

const binary = join(electronDir, 'dist', entry)
if (!existsSync(binary)) {
  fail(`path.txt points at "${entry}", which is not present under dist/.`)
}

// Confirm by magic bytes too — path.txt can be right while dist/ is stale.
try {
  const fd = openSync(binary, 'r')
  const head = Buffer.alloc(4)
  readSync(fd, head, 0, 4, 0)
  closeSync(fd)
  const detected = MAGIC[head.toString('hex')]
  if (detected && detected !== process.platform) {
    fail(`The binary at dist/${entry} is a ${detected} executable, but this is ${process.platform}.`)
  }
} catch {
  // Unreadable for some other reason; let the real tooling report it.
}
