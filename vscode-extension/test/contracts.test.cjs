const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

const {
  assertLocalDesktopRuntime,
  buildManifest,
  formatDiagnostics,
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
