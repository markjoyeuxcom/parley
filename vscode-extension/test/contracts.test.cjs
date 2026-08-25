const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const {
  assertLocalDesktopRuntime,
  buildManifest,
  formatDiagnostics,
  parseAttentionSnapshot,
  parleyFocusURL,
  readAttentionSnapshot,
  relativeWorkspaceFile,
  stageManifest,
} = require('../contracts.cjs')

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
  ])
  assert.deepEqual(manifest, {
    version: 1,
    folder: '/tmp/project',
    items: [{ kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 4, text: 'chosen' }],
  })
  assert.throws(() => buildManifest('/tmp/project', []), /at least one/)
  assert.throws(
    () => buildManifest('/tmp/project', [{ kind: 'selection', file: 'x', startLine: 1, endLine: 1, text: 'x'.repeat(200_001) }]),
    /too large/,
  )
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
    const file = stageManifest(
      buildManifest('/tmp/project', [{ kind: 'gitDiff' }]),
      { home, randomUUID: () => '12345678-1234-1234-9234-123456789abc' },
    )
    assert.equal(
      file,
      path.join(home, 'Library/Application Support/Parley Native/external-context-inbox/12345678-1234-1234-9234-123456789abc.parleycontext'),
    )
    assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700)
    assert.equal(fs.statSync(file).mode & 0o777, 0o600)
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).items[0].kind, 'gitDiff')
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
      { id: '@0', name: 'Library', attentionCount: 1 },
      { id: '@1', name: 'Consumer', attentionCount: 1 },
    ],
    panes: [
      { id: '%1', name: 'Reviewer', kind: 'codex', workspaceID: '@0', workspaceName: 'Library' },
    ],
    items: [
      {
        handoffID: '11111111-1111-4111-8111-111111111111',
        workspaceID: '@0',
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
