const fs = require('node:fs')
const path = require('node:path')

const CONTRACT_VERSION = 2
const MAXIMUM_MANIFEST_BYTES = 200_000
const MAXIMUM_ITEMS = 16
const IMPORT_KINDS = new Set([
  'selection',
  'currentFile',
  'diagnostics',
  'gitDiff',
  'gitWorkingDiff',
  'gitStagedDiff',
])
const BRIDGE_CAPABILITIES_VERSION = 1
const ACKNOWLEDGEMENT_VERSION = 1
const MAXIMUM_CAPABILITIES_BYTES = 16_000
const MAXIMUM_ACKNOWLEDGEMENT_BYTES = 4_096
const MAXIMUM_CAPABILITIES_AGE_MS = 30_000
const REQUEST_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/
const DURABLE_WORKSPACE_ID = /^(?:workspace-[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}|@[0-9]{1,15})$/
const ACKNOWLEDGEMENT_STATES = new Set(['accepted', 'rejected', 'expired'])
const ACKNOWLEDGEMENT_CODES = new Set([
  'invalidRequest',
  'unsupportedVersion',
  'invalidSource',
  'contextUnavailable',
  'noReadyAgent',
  'declinedReplacement',
  'requestExpired',
  'internalError',
])
const ATTENTION_SNAPSHOT_VERSION = 1
const MAXIMUM_ATTENTION_BYTES = 128_000
const MAXIMUM_ATTENTION_AGE_MS = 30_000
const AGENT_KINDS = new Set(['claude', 'codex', 'agy', 'copilot'])
const ATTENTION_REASONS = new Set(['returnedResult', 'humanInputRequired', 'interrupted'])
const PANE_ID = /^(?:%[0-9]{1,15}|pane-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/
const WORKSPACE_ID = DURABLE_WORKSPACE_ID
const HANDOFF_ID = /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/

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
  switch (item.kind) {
  case 'selection': {
    exactObject(item, ['kind', 'file', 'startLine', 'endLine', 'text'], 'editor context selection')
    const startLine = positiveInteger(item.startLine, 'start line')
    const endLine = positiveInteger(item.endLine, 'end line')
    if (endLine < startLine) throw new Error('Invalid editor context line range.')
    return {
      kind: item.kind,
      file: relativeFileString(item.file),
      startLine,
      endLine,
      text: boundedString(item.text, 'text', MAXIMUM_MANIFEST_BYTES),
    }
  }
  case 'currentFile':
    exactObject(item, ['kind', 'file'], 'editor context file')
    return { kind: item.kind, file: relativeFileString(item.file) }
  case 'diagnostics':
    exactObject(item, ['kind', 'file', 'text'], 'editor context diagnostics')
    return {
      kind: item.kind,
      file: relativeFileString(item.file),
      text: boundedString(item.text, 'text', MAXIMUM_MANIFEST_BYTES),
    }
  case 'gitDiff':
    exactObject(item, ['kind'], 'editor context Git diff')
    return { kind: item.kind }
  case 'gitWorkingDiff':
  case 'gitStagedDiff': {
    const keys = item.file === undefined ? ['kind'] : ['kind', 'file']
    exactObject(item, keys, 'editor context scoped Git diff')
    return item.file === undefined
      ? { kind: item.kind }
      : { kind: item.kind, file: relativeFileString(item.file) }
  }
  default:
    throw new Error('Unsupported Parley editor context source.')
  }
}

function relativeFileString(value) {
  const file = boundedString(value, 'file', 4_096)
  if (!file || path.isAbsolute(file) || file.split('/').some((component) => component === '..')) {
    throw new Error('Invalid editor context file.')
  }
  return file
}

function buildSelectionItems(relativeFile, selections) {
  const file = relativeFileString(relativeFile)
  if (!Array.isArray(selections)) throw new Error('Invalid editor selections.')
  return selections
    .filter((selection) => typeof selection?.text === 'string' && selection.text.trim())
    .map((selection) => cleanItem({
      kind: 'selection',
      file,
      startLine: selection.startLine,
      endLine: selection.endLine,
      text: selection.text,
    }))
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
  if (!REQUEST_ID.test(identifier)) {
    throw new Error('Parley could not create a context import identifier.')
  }
  const file = path.join(inbox, `${identifier}.parleycontext`)
  const data = JSON.stringify(manifest)
  if (Buffer.byteLength(data, 'utf8') > MAXIMUM_MANIFEST_BYTES) {
    throw new Error('That editor context is too large for one Parley preview.')
  }
  fs.writeFileSync(file, data, { encoding: 'utf8', flag: 'wx', mode: 0o600 })
  fs.chmodSync(file, 0o600)
  return {
    requestID: identifier,
    file,
    acknowledgementFile: path.join(
      home,
      'Library',
      'Application Support',
      'Parley Native',
      'external-context-outbox',
      `${identifier}.json`,
    ),
  }
}

function parseBridgeCapabilities(value, { now = new Date() } = {}) {
  exactObject(value, ['version', 'generatedAt', 'contextImport'], 'editor bridge capabilities')
  if (value.version !== BRIDGE_CAPABILITIES_VERSION) {
    throw new Error('Unsupported Parley editor bridge capabilities version.')
  }
  const generatedAt = currentTimestamp(value.generatedAt, now, 'editor bridge capabilities')
  exactObject(
    value.contextImport,
    [
      'versions',
      'kinds',
      'maximumManifestBytes',
      'maximumItems',
      'acknowledgementVersion',
      'requestLifetimeSeconds',
    ],
    'editor context capabilities',
  )
  if (!Array.isArray(value.contextImport.versions) || value.contextImport.versions.length === 0 || value.contextImport.versions.length > 8) {
    throw new Error('Invalid Parley editor context contract versions.')
  }
  const versions = value.contextImport.versions.map((version) => positiveInteger(version, 'contract version'))
  if (new Set(versions).size !== versions.length) throw new Error('Invalid Parley editor context contract versions.')
  if (!Array.isArray(value.contextImport.kinds) || value.contextImport.kinds.length === 0 || value.contextImport.kinds.length > 32) {
    throw new Error('Invalid Parley editor context source capabilities.')
  }
  const kinds = value.contextImport.kinds.map((kind) => boundedString(kind, 'source capability', 64))
  if (new Set(kinds).size !== kinds.length) throw new Error('Invalid Parley editor context source capabilities.')
  const maximumManifestBytes = positiveInteger(value.contextImport.maximumManifestBytes, 'maximum manifest bytes')
  const maximumItems = positiveInteger(value.contextImport.maximumItems, 'maximum items')
  const acknowledgementVersion = positiveInteger(value.contextImport.acknowledgementVersion, 'acknowledgement version')
  const requestLifetimeSeconds = positiveInteger(value.contextImport.requestLifetimeSeconds, 'request lifetime')
  if (maximumManifestBytes > MAXIMUM_MANIFEST_BYTES || maximumItems > MAXIMUM_ITEMS || requestLifetimeSeconds > 3_600) {
    throw new Error('Invalid Parley editor context capability bounds.')
  }
  return {
    version: value.version,
    generatedAt,
    contextImport: {
      versions,
      kinds,
      maximumManifestBytes,
      maximumItems,
      acknowledgementVersion,
      requestLifetimeSeconds,
    },
  }
}

function assertCompatibleCapabilities(capabilities, items) {
  if (!capabilities?.contextImport?.versions?.includes(CONTRACT_VERSION)) {
    throw new Error(`The installed Parley app does not support editor context contract version ${CONTRACT_VERSION}. Update Parley and the companion together.`)
  }
  if (capabilities.contextImport.acknowledgementVersion !== ACKNOWLEDGEMENT_VERSION) {
    throw new Error('The installed Parley app uses an incompatible context acknowledgement contract. Update Parley and the companion together.')
  }
  const unsupported = (items || []).find((item) => !capabilities.contextImport.kinds.includes(item.kind))
  if (unsupported) {
    throw new Error(`The installed Parley app does not support the ${unsupported.kind} editor source.`)
  }
  if ((items || []).length > capabilities.contextImport.maximumItems) {
    throw new Error(`The installed Parley app accepts at most ${capabilities.contextImport.maximumItems} editor sources.`)
  }
}

function readBridgeCapabilities({ home, now = new Date() }) {
  const application = applicationDirectory(home)
  const file = path.join(application, 'external-editor-capabilities.json')
  if (!fs.existsSync(file)) return null
  const value = readPrivateJSON({ application, file, maximumBytes: MAXIMUM_CAPABILITIES_BYTES, label: 'editor bridge capabilities' })
  return parseBridgeCapabilities(value, { now })
}

function parseAcknowledgement(value, { requestID }) {
  const expectedID = matchingString(String(requestID).toLowerCase(), REQUEST_ID, 'context request id')
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('Invalid Parley context acknowledgement.')
  }
  const state = boundedString(value.state, 'acknowledgement state', 32)
  if (!ACKNOWLEDGEMENT_STATES.has(state)) throw new Error('Invalid Parley context acknowledgement state.')
  const accepted = state === 'accepted'
  exactObject(
    value,
    accepted
      ? ['version', 'requestID', 'state', 'acknowledgedAt', 'workspaceID', 'sourceCount']
      : ['version', 'requestID', 'state', 'acknowledgedAt', 'code', 'message'],
    'context acknowledgement',
  )
  if (value.version !== ACKNOWLEDGEMENT_VERSION) throw new Error('Unsupported Parley context acknowledgement version.')
  const actualID = matchingString(value.requestID, REQUEST_ID, 'context request id')
  if (actualID !== expectedID) throw new Error('Parley returned an acknowledgement for a different request.')
  const acknowledgedAt = validTimestamp(value.acknowledgedAt, 'context acknowledgement')
  if (accepted) {
    return {
      version: value.version,
      requestID: actualID,
      state,
      acknowledgedAt,
      workspaceID: matchingString(value.workspaceID, DURABLE_WORKSPACE_ID, 'workspace id'),
      sourceCount: boundedCount(value.sourceCount, 'source count', MAXIMUM_ITEMS),
    }
  }
  const code = boundedString(value.code, 'acknowledgement code', 64)
  if (!ACKNOWLEDGEMENT_CODES.has(code)) throw new Error('Invalid Parley context acknowledgement code.')
  return {
    version: value.version,
    requestID: actualID,
    state,
    acknowledgedAt,
    code,
    message: singleLine(value.message, 'acknowledgement message', 512),
  }
}

function consumeAcknowledgement({ home, requestID }) {
  const identifier = matchingString(String(requestID).toLowerCase(), REQUEST_ID, 'context request id')
  const application = applicationDirectory(home)
  const outbox = path.join(application, 'external-context-outbox')
  const file = path.join(outbox, `${identifier}.json`)
  if (!fs.existsSync(file)) return null
  requirePrivatePath(application, true, 'Parley application directory')
  requirePrivatePath(outbox, true, 'Parley context outbox')
  const value = readPrivateJSON({ application, file, maximumBytes: MAXIMUM_ACKNOWLEDGEMENT_BYTES, label: 'context acknowledgement' })
  const acknowledgement = parseAcknowledgement(value, { requestID: identifier })
  fs.rmSync(file, { force: true })
  return acknowledgement
}

function applicationDirectory(home) {
  if (!path.isAbsolute(home)) throw new Error('Parley could not resolve the local home directory.')
  return path.join(home, 'Library', 'Application Support', 'Parley Native')
}

function readPrivateJSON({ application, file, maximumBytes, label }) {
  requirePrivatePath(application, true, 'Parley application directory')
  requirePrivatePath(file, false, `Parley ${label}`)
  const size = fs.statSync(file).size
  if (size <= 0 || size > maximumBytes) throw new Error(`The Parley ${label} is too large.`)
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    throw new Error(`The Parley ${label} is malformed.`)
  }
}

function currentTimestamp(value, now, label) {
  const timestamp = validTimestamp(value, label)
  const generatedTime = Date.parse(timestamp)
  const nowTime = now instanceof Date ? now.getTime() : NaN
  if (!Number.isFinite(nowTime)) throw new Error(`Invalid Parley ${label} timestamp.`)
  const age = nowTime - generatedTime
  if (age > MAXIMUM_CAPABILITIES_AGE_MS) throw new Error(`The Parley ${label} is stale.`)
  if (age < -5_000) throw new Error(`The Parley ${label} timestamp is in the future.`)
  return timestamp
}

function validTimestamp(value, label) {
  const timestamp = boundedString(value, `${label} timestamp`, 64)
  if (!Number.isFinite(Date.parse(timestamp))) throw new Error(`Invalid Parley ${label} timestamp.`)
  return timestamp
}

function parseAttentionSnapshot(value, { now = new Date() } = {}) {
  exactObject(value, ['version', 'generatedAt', 'attentionCount', 'workspaces', 'panes', 'items'], 'attention snapshot')
  if (value.version !== ATTENTION_SNAPSHOT_VERSION) throw new Error('Unsupported Parley attention snapshot version.')
  const generatedAt = boundedString(value.generatedAt, 'attention timestamp', 64)
  const generatedTime = Date.parse(generatedAt)
  const nowTime = now instanceof Date ? now.getTime() : NaN
  if (!Number.isFinite(generatedTime) || !Number.isFinite(nowTime)) throw new Error('Invalid Parley attention timestamp.')
  const age = nowTime - generatedTime
  if (age > MAXIMUM_ATTENTION_AGE_MS) throw new Error('The Parley attention snapshot is stale.')
  if (age < -5_000) throw new Error('The Parley attention snapshot timestamp is in the future.')
  const attentionCount = boundedCount(value.attentionCount, 'attention count', 100_000)
  if (!Array.isArray(value.workspaces) || value.workspaces.length > 256) throw new Error('Invalid Parley attention workspaces.')
  if (!Array.isArray(value.panes) || value.panes.length > 512) throw new Error('Invalid Parley attention panes.')
  if (!Array.isArray(value.items) || value.items.length > 512) throw new Error('Invalid Parley attention items.')

  const workspaces = value.workspaces.map((workspace) => {
    exactObject(workspace, ['id', 'name', 'attentionCount'], 'attention workspace')
    return {
      id: matchingString(workspace.id, WORKSPACE_ID, 'workspace id'),
      name: singleLine(workspace.name, 'workspace name'),
      attentionCount: boundedCount(workspace.attentionCount, 'workspace attention count', 100_000),
    }
  })
  const panes = value.panes.map((pane) => {
    exactObject(pane, ['id', 'name', 'kind', 'workspaceID', 'workspaceName'], 'attention pane')
    const kind = boundedString(pane.kind, 'pane kind', 32)
    if (!AGENT_KINDS.has(kind)) throw new Error('Invalid Parley attention pane kind.')
    return {
      id: matchingString(pane.id, PANE_ID, 'pane id'),
      name: singleLine(pane.name, 'pane name'),
      kind,
      workspaceID: matchingString(pane.workspaceID, WORKSPACE_ID, 'workspace id'),
      workspaceName: singleLine(pane.workspaceName, 'workspace name'),
    }
  })
  const items = value.items.map((item) => {
    exactObject(item, ['handoffID', 'workspaceID', 'workspaceName', 'label', 'reason'], 'attention item')
    const reason = boundedString(item.reason, 'attention reason', 32)
    if (!ATTENTION_REASONS.has(reason)) throw new Error('Invalid Parley attention reason.')
    return {
      handoffID: matchingString(item.handoffID, HANDOFF_ID, 'handoff id'),
      workspaceID: matchingString(item.workspaceID, WORKSPACE_ID, 'workspace id'),
      workspaceName: singleLine(item.workspaceName, 'workspace name'),
      label: singleLine(item.label, 'attention label'),
      reason,
    }
  })
  return { version: value.version, generatedAt, attentionCount, workspaces, panes, items }
}

function readAttentionSnapshot({ home, now = new Date() }) {
  if (!path.isAbsolute(home)) throw new Error('Parley could not resolve the local home directory.')
  const application = path.join(home, 'Library', 'Application Support', 'Parley Native')
  const file = path.join(application, 'external-attention.json')
  if (!fs.existsSync(file)) return null
  requirePrivatePath(application, true, 'Parley application directory')
  requirePrivatePath(file, false, 'Parley attention snapshot')
  const size = fs.statSync(file).size
  if (size <= 0 || size > MAXIMUM_ATTENTION_BYTES) throw new Error('The Parley attention snapshot is too large.')
  let value
  try {
    value = JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    throw new Error('The Parley attention snapshot is malformed.')
  }
  return parseAttentionSnapshot(value, { now })
}

function parleyFocusURL({ paneID, handoffID }) {
  if ((paneID ? 1 : 0) + (handoffID ? 1 : 0) !== 1) {
    throw new Error('Choose exactly one Parley pane or handoff to focus.')
  }
  if (paneID) {
    const id = matchingString(paneID, PANE_ID, 'pane id')
    return `parley://focus?pane=${encodeURIComponent(id)}`
  }
  const id = matchingString(handoffID, HANDOFF_ID, 'handoff id')
  return `parley://status?handoff=${encodeURIComponent(id)}`
}

function exactObject(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`Invalid Parley ${label}.`)
  const actual = Object.keys(value).sort()
  const expected = [...keys].sort()
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`Unsupported fields in Parley ${label}.`)
  }
}

function requirePrivatePath(value, directory, label) {
  const status = fs.lstatSync(value)
  if (status.isSymbolicLink() || (directory ? !status.isDirectory() : !status.isFile())) {
    throw new Error(`${label} is not a private local ${directory ? 'directory' : 'file'}.`)
  }
  if (typeof process.getuid === 'function' && status.uid !== process.getuid()) {
    throw new Error(`${label} is not owned by the current user.`)
  }
  if ((status.mode & 0o077) !== 0) throw new Error(`${label} is not private to the current user.`)
}

function boundedCount(value, label, maximum) {
  if (!Number.isSafeInteger(value) || value < 0 || value > maximum) throw new Error(`Invalid Parley ${label}.`)
  return value
}

function matchingString(value, pattern, label) {
  const bounded = boundedString(value, label, 256)
  if (!pattern.test(bounded)) throw new Error(`Invalid Parley ${label}.`)
  return bounded
}

function singleLine(value, label, maximumBytes = 256) {
  const bounded = boundedString(value, label, maximumBytes)
  if (!bounded.trim() || /[\r\n\t]/.test(bounded)) throw new Error(`Invalid Parley ${label}.`)
  return bounded
}

module.exports = {
  ACKNOWLEDGEMENT_VERSION,
  ATTENTION_SNAPSHOT_VERSION,
  BRIDGE_CAPABILITIES_VERSION,
  CONTRACT_VERSION,
  MAXIMUM_MANIFEST_BYTES,
  assertLocalDesktopRuntime,
  assertCompatibleCapabilities,
  buildSelectionItems,
  buildManifest,
  consumeAcknowledgement,
  formatDiagnostics,
  parseAcknowledgement,
  parseAttentionSnapshot,
  parseBridgeCapabilities,
  parleyFocusURL,
  readAttentionSnapshot,
  readBridgeCapabilities,
  relativeWorkspaceFile,
  stageManifest,
}
