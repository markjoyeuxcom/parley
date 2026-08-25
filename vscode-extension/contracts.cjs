const fs = require('node:fs')
const path = require('node:path')

const CONTRACT_VERSION = 1
const MAXIMUM_MANIFEST_BYTES = 200_000
const MAXIMUM_ITEMS = 16
const IMPORT_KINDS = new Set(['selection', 'currentFile', 'diagnostics', 'gitDiff'])

function assertLocalDesktopRuntime({ platform, remoteName, web = false }) {
  if (platform !== 'darwin') throw new Error('The Parley companion currently requires macOS.')
  if (web) throw new Error('The Parley companion requires the local VS Code desktop extension host.')
  if (remoteName) {
    throw new Error(`The Parley companion cannot treat the ${remoteName} remote filesystem as local.`)
  }
}

function relativeWorkspaceFile(folder, file) {
  if (!path.isAbsolute(folder) || !path.isAbsolute(file)) {
    throw new Error('Parley requires absolute local workspace and file paths.')
  }
  const relative = path.relative(folder, file)
  if (!relative || relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('The selected file is outside the active workspace folder.')
  }
  return relative.split(path.sep).join('/')
}

function buildManifest(folder, items) {
  if (!path.isAbsolute(folder) || folder.includes('\0') || /[\r\n]/.test(folder)) {
    throw new Error('Parley needs one absolute local workspace folder.')
  }
  if (!Array.isArray(items) || items.length === 0) {
    throw new Error('Choose at least one explicit editor source.')
  }
  if (items.length > MAXIMUM_ITEMS) throw new Error(`A Parley context import accepts at most ${MAXIMUM_ITEMS} sources.`)
  const cleanItems = items.map(cleanItem)
  const manifest = { version: CONTRACT_VERSION, folder, items: cleanItems }
  if (Buffer.byteLength(JSON.stringify(manifest), 'utf8') > MAXIMUM_MANIFEST_BYTES) {
    throw new Error('That editor context is too large for one Parley preview.')
  }
  return manifest
}

function cleanItem(item) {
  if (!item || !IMPORT_KINDS.has(item.kind)) throw new Error('Unsupported Parley editor context source.')
  const clean = { kind: item.kind }
  if (item.file !== undefined) clean.file = boundedString(item.file, 'file', 4_096)
  if (item.startLine !== undefined) clean.startLine = positiveInteger(item.startLine, 'start line')
  if (item.endLine !== undefined) clean.endLine = positiveInteger(item.endLine, 'end line')
  if (item.text !== undefined) clean.text = boundedString(item.text, 'text', MAXIMUM_MANIFEST_BYTES)
  return clean
}

function boundedString(value, label, maximumBytes) {
  if (typeof value !== 'string' || value.includes('\0')) throw new Error(`Invalid editor context ${label}.`)
  if (Buffer.byteLength(value, 'utf8') > maximumBytes) throw new Error('That editor context is too large for one Parley preview.')
  return value
}

function positiveInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`Invalid editor context ${label}.`)
  return value
}

function formatDiagnostics(relativeFile, diagnostics) {
  if (!Array.isArray(diagnostics) || diagnostics.length === 0) {
    throw new Error('There are no diagnostics for the current file.')
  }
  return diagnostics.map((diagnostic) => {
    const line = positiveInteger(diagnostic.line, 'diagnostic line')
    const column = positiveInteger(diagnostic.column, 'diagnostic column')
    const severity = oneLine(diagnostic.severity || 'information').toLowerCase()
    const attribution = [diagnostic.source, diagnostic.code]
      .filter((value) => value !== undefined && value !== null && String(value).length > 0)
      .map((value) => oneLine(String(value)))
      .join(' ')
    const suffix = attribution ? ` [${attribution}]` : ''
    return `${relativeFile}:${line}:${column} ${severity}${suffix}: ${oneLine(diagnostic.message)}`
  }).join('\n')
}

function oneLine(value) {
  return String(value || '').replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim()
}

function stageManifest(manifest, { home, randomUUID }) {
  if (!path.isAbsolute(home)) throw new Error('Parley could not resolve the local home directory.')
  const inbox = path.join(home, 'Library', 'Application Support', 'Parley Native', 'external-context-inbox')
  fs.mkdirSync(inbox, { recursive: true, mode: 0o700 })
  const inboxStatus = fs.lstatSync(inbox)
  if (!inboxStatus.isDirectory() || inboxStatus.isSymbolicLink()) {
    throw new Error('Parley context inbox is not a private local directory.')
  }
  fs.chmodSync(inbox, 0o700)
  const identifier = String(randomUUID()).toLowerCase()
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(identifier)) {
    throw new Error('Parley could not create a context import identifier.')
  }
  const file = path.join(inbox, `${identifier}.parleycontext`)
  const data = JSON.stringify(manifest)
  if (Buffer.byteLength(data, 'utf8') > MAXIMUM_MANIFEST_BYTES) {
    throw new Error('That editor context is too large for one Parley preview.')
  }
  fs.writeFileSync(file, data, { encoding: 'utf8', flag: 'wx', mode: 0o600 })
  fs.chmodSync(file, 0o600)
  return file
}

module.exports = {
  CONTRACT_VERSION,
  MAXIMUM_MANIFEST_BYTES,
  assertLocalDesktopRuntime,
  buildManifest,
  formatDiagnostics,
  relativeWorkspaceFile,
  stageManifest,
}
