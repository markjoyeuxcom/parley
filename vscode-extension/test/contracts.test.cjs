const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const {
  ACKNOWLEDGEMENT_VERSION,
  BRIDGE_CAPABILITIES_VERSION,
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
} = require('../contracts.cjs')

test('companion is distributed under the repository Apache-2.0 licence', () => {
  const repositoryLicense = fs.readFileSync(path.join(__dirname, '../../LICENSE'), 'utf8')
  const companionLicense = fs.readFileSync(path.join(__dirname, '../LICENSE'), 'utf8')
  const repositoryNotice = fs.readFileSync(path.join(__dirname, '../../NOTICE'), 'utf8')
  const companionNotice = fs.readFileSync(path.join(__dirname, '../NOTICE'), 'utf8')
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../package.json'), 'utf8'))

  assert.equal(manifest.license, 'Apache-2.0')
  assert.equal(companionLicense, repositoryLicense)
  assert.equal(companionNotice, repositoryNotice)
})

test('companion contributes one context composer with editor, Explorer and SCM entry points', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../package.json'), 'utf8'))
  const commands = new Set(manifest.contributes.commands.map((command) => command.command))
  assert.equal(commands.has('parley.buildContextPack'), true)
  assert.equal(commands.has('parley.diagnoseCompanion'), true)
  assert.equal(commands.has('parley.stageSelection'), false)
  assert.equal(manifest.contributes.menus['editor/context'][0].command, 'parley.buildContextPack')
  assert.equal(manifest.contributes.menus['explorer/context'][0].command, 'parley.buildContextPack')
  assert.deepEqual(
    manifest.contributes.menus['scm/resourceState/context'].map((item) => item.command),
    [
      'parley.buildWorkingTreeContext',
      'parley.buildStagedContext',
      'parley.addWorkingChangeToBasket',
      'parley.addStagedChangeToBasket',
    ],
  )
})

test('companion contributes the complete collaboration sidebar, context basket and onboarding phases', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, '../package.json'), 'utf8'))
  const commands = new Set(manifest.contributes.commands.map((command) => command.command))
  const requiredCommands = [
    'parley.openCollaboration',
    'parley.openApplication',
    'parley.refreshCollaboration',
    'parley.focusPane',
    'parley.openHandoff',
    'parley.addSelectionToBasket',
    'parley.addFilesToBasket',
    'parley.addDiagnosticsToBasket',
    'parley.addWorkingChangeToBasket',
    'parley.addStagedChangeToBasket',
    'parley.reviewContextBasket',
    'parley.clearContextBasket',
    'parley.removeContextBasketItem',
  ]
  for (const command of requiredCommands) {
    assert.equal(commands.has(command), true, `${command} is missing`)
  }

  const container = manifest.contributes.viewsContainers.activitybar.find((item) => item.id === 'parley')
  assert.equal(container.title, 'Parley')
  assert.equal(container.icon, 'media/parley.svg')
  assert.deepEqual(
    manifest.contributes.views.parley.map((view) => view.id),
    ['parley.attention', 'parley.workspaces', 'parley.contextBasket'],
  )
  assert.equal(
    manifest.contributes.menus['view/title'].some((item) => item.command === 'parley.refreshCollaboration'),
    true,
  )
  assert.equal(
    manifest.contributes.menus['view/item/context'].some((item) => item.command === 'parley.removeContextBasketItem'),
    true,
  )
  assert.equal(
    manifest.contributes.menus['editor/context'].some((item) => item.command === 'parley.addSelectionToBasket'),
    true,
  )
  assert.equal(
    manifest.contributes.menus['scm/resourceState/context'].some((item) => item.command === 'parley.addWorkingChangeToBasket'),
    true,
  )
  assert.equal(manifest.contributes.walkthroughs[0].steps.length >= 3, true)
})

test('companion refuses non-macOS, web and remote extension hosts', () => {
  assert.doesNotThrow(() => assertLocalDesktopRuntime({ platform: 'darwin' }))
  assert.throws(() => assertLocalDesktopRuntime({ platform: 'linux' }), /macOS/)
  assert.throws(() => assertLocalDesktopRuntime({ platform: 'darwin', remoteName: 'ssh-remote' }), /local/)
  assert.throws(() => assertLocalDesktopRuntime({ platform: 'darwin', web: true }), /desktop/)
})

test('companion admits only files inside one local workspace', () => {
  assert.equal(relativeWorkspaceFile('/tmp/project', '/tmp/project/src/main.ts'), 'src/main.ts')
  assert.throws(() => relativeWorkspaceFile('/tmp/project', '/tmp/other/main.ts'), /outside/)
  assert.throws(() => relativeWorkspaceFile('relative', '/tmp/project/main.ts'), /absolute/)
})

test('manifest contains only the reviewed version, folder and explicit items', () => {
  const manifest = buildManifest('/tmp/project', [
    { kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 4, text: 'chosen' },
    { kind: 'gitWorkingDiff', file: 'src/main.ts' },
    { kind: 'gitStagedDiff' },
  ])
  assert.deepEqual(manifest, {
    version: 2,
    folder: '/tmp/project',
    items: [
      { kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 4, text: 'chosen' },
      { kind: 'gitWorkingDiff', file: 'src/main.ts' },
      { kind: 'gitStagedDiff' },
    ],
  })
  assert.throws(() => buildManifest('/tmp/project', []), /at least one/)
  assert.throws(
    () => buildManifest('/tmp/project', [{ kind: 'currentFile', file: 'x', prompt: 'hidden authority' }]),
    /unsupported fields/i,
  )
  assert.throws(
    () => buildManifest('/tmp/project', [{ kind: 'gitWorkingDiff', file: 'x', text: 'not recaptured' }]),
    /unsupported fields/i,
  )
  assert.throws(
    () => buildManifest('/tmp/project', [{ kind: 'selection', file: 'x', startLine: 1, endLine: 1, text: 'x'.repeat(200_001) }]),
    /too large/,
  )
})

test('all explicit editor selections are preserved as separately attributed sources', () => {
  assert.deepEqual(buildSelectionItems('src/main.ts', [
    { startLine: 2, endLine: 2, text: 'first' },
    { startLine: 8, endLine: 10, text: 'second\nselection' },
    { startLine: 12, endLine: 12, text: '   ' },
  ]), [
    { kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 2, text: 'first' },
    { kind: 'selection', file: 'src/main.ts', startLine: 8, endLine: 10, text: 'second\nselection' },
  ])
})

test('diagnostics are deterministic attributed text', () => {
  assert.equal(
    formatDiagnostics('src/main.ts', [
      { severity: 'warning', line: 3, column: 7, message: 'Unused value', source: 'ts', code: '6133' },
      { severity: 'error', line: 1, column: 2, message: 'Broken\r\nline' },
    ]),
    [
      'src/main.ts:3:7 warning [ts 6133]: Unused value',
      'src/main.ts:1:2 error: Broken line',
    ].join('\n'),
  )
  assert.throws(() => formatDiagnostics('src/main.ts', []), /no diagnostics/i)
})

test('staging uses the Production private inbox and owner-only permissions', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-vscode-test-'))
  try {
    const staged = stageManifest(
      buildManifest('/tmp/project', [{ kind: 'gitDiff' }]),
      { home, randomUUID: () => '12345678-1234-1234-9234-123456789abc' },
    )
    assert.equal(
      staged.file,
      path.join(home, 'Library/Application Support/Parley Native/external-context-inbox/12345678-1234-1234-9234-123456789abc.parleycontext'),
    )
    assert.equal(staged.requestID, '12345678-1234-1234-9234-123456789abc')
    assert.equal(
      staged.acknowledgementFile,
      path.join(home, 'Library/Application Support/Parley Native/external-context-outbox/12345678-1234-1234-9234-123456789abc.json'),
    )
    assert.equal(fs.statSync(path.dirname(staged.file)).mode & 0o777, 0o700)
    assert.equal(fs.statSync(staged.file).mode & 0o777, 0o600)
    assert.equal(JSON.parse(fs.readFileSync(staged.file, 'utf8')).items[0].kind, 'gitDiff')
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('bridge capability negotiation is strict, current and contract-aware', () => {
  const now = new Date('2026-09-01T10:00:20.000Z')
  const capabilities = parseBridgeCapabilities({
    version: BRIDGE_CAPABILITIES_VERSION,
    generatedAt: '2026-09-01T10:00:10.000Z',
    contextImport: {
      versions: [1, 2],
      kinds: ['selection', 'currentFile', 'diagnostics', 'gitDiff', 'gitWorkingDiff', 'gitStagedDiff'],
      maximumManifestBytes: 200_000,
      maximumItems: 16,
      acknowledgementVersion: ACKNOWLEDGEMENT_VERSION,
      requestLifetimeSeconds: 300,
    },
  }, { now })
  assert.doesNotThrow(() => assertCompatibleCapabilities(capabilities, [
    { kind: 'currentFile', file: 'src/main.ts' },
    { kind: 'gitStagedDiff', file: 'src/main.ts' },
  ]))
  assert.throws(
    () => assertCompatibleCapabilities({ ...capabilities, contextImport: { ...capabilities.contextImport, versions: [1] } }, []),
    /contract version/i,
  )
  assert.throws(
    () => parseBridgeCapabilities({ ...capabilities, generatedAt: '2026-09-01T09:59:00.000Z' }, { now }),
    /stale/i,
  )
  assert.throws(
    () => parseBridgeCapabilities({ ...capabilities, prompt: 'hidden authority' }, { now }),
    /unsupported fields/i,
  )
})

test('bridge capabilities are read only from the private Production application directory', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-vscode-capabilities-'))
  const application = path.join(home, 'Library/Application Support/Parley Native')
  const file = path.join(application, 'external-editor-capabilities.json')
  const now = new Date('2026-09-01T10:00:20.000Z')
  try {
    fs.mkdirSync(application, { recursive: true, mode: 0o700 })
    fs.writeFileSync(file, JSON.stringify({
      version: 1,
      generatedAt: '2026-09-01T10:00:10.000Z',
      contextImport: {
        versions: [1, 2],
        kinds: ['selection', 'currentFile', 'diagnostics', 'gitDiff', 'gitWorkingDiff', 'gitStagedDiff'],
        maximumManifestBytes: 200_000,
        maximumItems: 16,
        acknowledgementVersion: 1,
        requestLifetimeSeconds: 300,
      },
    }), { mode: 0o600 })
    assert.equal(readBridgeCapabilities({ home, now }).contextImport.maximumItems, 16)
    fs.chmodSync(file, 0o644)
    assert.throws(() => readBridgeCapabilities({ home, now }), /private/i)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('acknowledgements are correlated, bounded and consumed once', () => {
  const requestID = '12345678-1234-1234-9234-123456789abc'
  const accepted = parseAcknowledgement({
    version: ACKNOWLEDGEMENT_VERSION,
    requestID,
    state: 'accepted',
    acknowledgedAt: '2026-09-01T10:00:10.000Z',
    workspaceID: 'workspace-11111111-1111-4111-8111-111111111111',
    sourceCount: 3,
  }, { requestID })
  assert.equal(accepted.state, 'accepted')
  assert.throws(
    () => parseAcknowledgement({ ...accepted, requestID: '11111111-1111-4111-8111-111111111111' }, { requestID }),
    /request/i,
  )
  assert.deepEqual(parseAcknowledgement({
    version: 1,
    requestID,
    state: 'rejected',
    acknowledgedAt: '2026-09-01T10:00:10.000Z',
    code: 'noReadyAgent',
    message: 'Start a ready agent pane in that workspace, then try again.',
  }, { requestID }).state, 'rejected')

  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-vscode-ack-'))
  const application = path.join(home, 'Library/Application Support/Parley Native')
  const outbox = path.join(application, 'external-context-outbox')
  const file = path.join(outbox, `${requestID}.json`)
  try {
    fs.mkdirSync(outbox, { recursive: true, mode: 0o700 })
    fs.chmodSync(application, 0o700)
    fs.writeFileSync(file, JSON.stringify(accepted), { mode: 0o600 })
    assert.equal(consumeAcknowledgement({ home, requestID }).sourceCount, 3)
    assert.equal(fs.existsSync(file), false)
    assert.equal(consumeAcknowledgement({ home, requestID }), null)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('attention snapshot accepts bounded content-free status and rejects hidden authority', () => {
  const now = new Date('2026-08-25T10:00:20.000Z')
  const snapshot = parseAttentionSnapshot({
    version: 1,
    generatedAt: '2026-08-25T10:00:10.000Z',
    attentionCount: 2,
    workspaces: [
      { id: 'workspace-22222222-2222-4222-8222-222222222222', name: 'Library', attentionCount: 1 },
      { id: '@1', name: 'Consumer', attentionCount: 1 },
    ],
    panes: [
      { id: '%1', name: 'Reviewer', kind: 'codex', workspaceID: 'workspace-22222222-2222-4222-8222-222222222222', workspaceName: 'Library' },
    ],
    items: [
      {
        handoffID: '11111111-1111-4111-8111-111111111111',
        workspaceID: 'workspace-22222222-2222-4222-8222-222222222222',
        workspaceName: 'Library',
        label: 'Builder returned a result',
        reason: 'returnedResult',
      },
    ],
  }, { now })
  assert.equal(snapshot.attentionCount, 2)
  assert.equal(snapshot.panes[0].id, '%1')
  assert.throws(() => parseAttentionSnapshot({ ...snapshot, prompt: 'run tests' }, { now }), /unsupported/i)
  assert.throws(() => parseAttentionSnapshot({ ...snapshot, generatedAt: '2026-08-25T09:59:00.000Z' }, { now }), /stale/i)
  assert.throws(() => parseAttentionSnapshot({ ...snapshot, panes: [{ ...snapshot.panes[0], id: 'codex' }] }, { now }), /pane/i)
})

test('attention discovery reads only the private Production snapshot', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-vscode-attention-'))
  const application = path.join(home, 'Library/Application Support/Parley Native')
  const file = path.join(application, 'external-attention.json')
  const now = new Date('2026-08-25T10:00:20.000Z')
  try {
    fs.mkdirSync(application, { recursive: true, mode: 0o700 })
    fs.writeFileSync(file, JSON.stringify({
      version: 1,
      generatedAt: '2026-08-25T10:00:10.000Z',
      attentionCount: 0,
      workspaces: [],
      panes: [],
      items: [],
    }), { mode: 0o600 })
    assert.equal(readAttentionSnapshot({ home, now }).attentionCount, 0)
    fs.chmodSync(file, 0o644)
    assert.throws(() => readAttentionSnapshot({ home, now }), /private/i)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('focus links can carry only an opaque pane or handoff id', () => {
  assert.equal(parleyFocusURL({ paneID: '%12' }), 'parley://focus?pane=%2512')
  assert.equal(
    parleyFocusURL({ handoffID: '11111111-1111-4111-8111-111111111111' }),
    'parley://status?handoff=11111111-1111-4111-8111-111111111111',
  )
  assert.throws(() => parleyFocusURL({ paneID: 'codex' }), /pane/i)
  assert.throws(() => parleyFocusURL({ handoffID: 'current' }), /handoff/i)
  assert.throws(() => parleyFocusURL({ paneID: '%1', handoffID: '11111111-1111-4111-8111-111111111111' }), /one/i)
})

test('current native pane identifiers round-trip through external focus URLs', () => {
  const { parleyFocusURL } = require('../contracts.cjs')
  const paneID = 'pane-11111111-1111-4111-8111-111111111111'
  assert.equal(new URL(parleyFocusURL({ paneID })).searchParams.get('pane'), paneID)
  assert.throws(() => parleyFocusURL({ paneID: paneID + '/escape' }))
})
