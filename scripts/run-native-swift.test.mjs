import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const repository = fileURLToPath(new URL('../', import.meta.url))
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'"

function fixture(body) {
  const root = mkdtempSync(join(tmpdir(), 'parley-swift-runner-'))
  const bin = join(root, 'toolchain with spaces')
  mkdirSync(bin)
  const log = join(root, 'calls.jsonl')
  const script = join(root, 'fixture.cjs')
  writeFileSync(script, [
    "const fs = require('node:fs');",
    "const args = process.argv.slice(2);",
    "fs.appendFileSync(process.env.SWIFT_FIXTURE_LOG, JSON.stringify({args, path: process.env.PATH, parleyKeys: Object.keys(process.env).filter(key => key.startsWith('PARLEY_'))}) + '\\n');",
    "if (args.includes('--show-bin-path')) process.stdout.write(process.env.SWIFT_FIXTURE_BIN);",
    "process.exit(Number(process.env.SWIFT_FIXTURE_EXIT || 0));",
  ].join('\n'))
  const executable = '#!/bin/sh\nexec ' + quote(process.execPath) + ' ' + quote(script) + ' "$@"\n'
  writeFileSync(join(bin, 'swift'), executable, { mode: 0o700 })
  writeFileSync(join(bin, 'parley-native'), executable, { mode: 0o700 })
  const base = { ...process.env }
  for (const key of Object.keys(base)) if (key.startsWith('PARLEY_')) delete base[key]
  Object.assign(base, { PATH: bin + ':/usr/bin:/bin', SDKROOT: root, TMPDIR: root, SWIFT_FIXTURE_LOG: log, SWIFT_FIXTURE_BIN: bin })
  function run(args, environment = {}) {
    writeFileSync(log, '')
    const result = spawnSync(process.execPath, ['scripts/run-native-swift.mjs', ...args], {
      cwd: repository, env: { ...base, ...environment }, encoding: 'utf8',
    })
    const calls = readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line))
    return { ...result, calls }
  }
  try { body(run, root) } finally { rmSync(root, { recursive: true, force: true }) }
}

test('native runner enables SwiftPM compatibility only for opted-in agent panes', () => {
  fixture(run => {
    for (const kind of ['claude', 'codex', 'agy', 'copilot']) {
      for (const verb of ['build', 'run', 'test', 'package']) {
        const args = [verb, '--package-path', 'a folder', 'literal;$(no)\nnext']
        const result = run(args, { PARLEY_PANE: '1', PARLEY_PANE_KIND: kind, PARLEY_SWIFTPM_COMPATIBILITY: '1' })
        assert.equal(result.status, 0, result.stderr)
        assert.deepEqual(result.calls[0].args, [verb, '--disable-sandbox', ...args.slice(1)])
        assert.deepEqual(result.calls[0].parleyKeys, [])
      }
    }
  })
})

test('native runner preserves ordinary shells, opt-out and non-SwiftPM commands', () => {
  fixture(run => {
    for (const environment of [
      {}, { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'codex' },
      { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'shell', PARLEY_SWIFTPM_COMPATIBILITY: '1' },
      { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'unknown' },
      { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'codex', PARLEY_SWIFTPM_COMPATIBILITY: '0' },
    ]) {
      assert.deepEqual(run(['build'], environment).calls[0].args, ['build'])
    }
    assert.deepEqual(run(['--version'], { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'codex' }).calls[0].args, ['--version'])
    assert.equal(run(['build'], { PARLEY_PANE: '1', PARLEY_PANE_KIND: 'codex', SWIFT_FIXTURE_EXIT: '23' }).status, 23)
  })
})

test('native runner adapts both development build calls and strips the inherited wrapper', () => {
  fixture((run, root) => {
    const inherited = join(root, 'old-runtime/agent-protocol/swiftpm-bin')
    const result = run(['dev', '--package-path', 'native', '--runtime', 'development'], {
      PARLEY_PANE: '1', PARLEY_PANE_KIND: 'codex', PARLEY_SWIFTPM_COMPATIBILITY: '1', PARLEY_SWIFT_COMMAND: join(inherited, 'swift'),
      PATH: inherited + ':' + join(root, 'toolchain with spaces') + ':/usr/bin:/bin',
    })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(result.calls[0].args, ['build', '--disable-sandbox', '--package-path', 'native'])
    assert.deepEqual(result.calls[1].args, ['build', '--disable-sandbox', '--show-bin-path', '--package-path', 'native'])
    assert.deepEqual(result.calls[2].args, ['--runtime', 'development'])
    for (const call of result.calls) {
      assert.ok(!call.path.split(':').includes(inherited))
      assert.ok(!call.parleyKeys.includes('PARLEY_SWIFTPM_COMPATIBILITY'))
      assert.ok(!call.parleyKeys.includes('PARLEY_SWIFT_COMMAND'))
      assert.ok(!call.parleyKeys.includes('PARLEY_RELAY_TOKEN'))
    }
  })
})
