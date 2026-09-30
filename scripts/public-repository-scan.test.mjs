import assert from 'node:assert/strict'
import test from 'node:test'

import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Readable } from 'node:stream'

import {
  scanGitHistory,
  scanHistoricalPaths,
  scanHistoryStream,
  scanText,
} from './public-repository-scan.mjs'

test('publication scan detects common credential formats', () => {
  const findings = scanText([
    'token=AKIA1234567890ABCDEF',
    'github_pat_1234567890abcdefghijklmnop',
    '-----BEGIN OPENSSH PRIVATE KEY-----',
  ].join('\n'), 'fixture.txt')

  assert.deepEqual(
    findings.map((finding) => finding.rule),
    ['aws-access-key', 'github-token', 'private-key'],
  )
})

test('publication scan permits the deliberate URL-credential rejection fixture only', () => {
  assert.deepEqual(
    scanText(
      '"https://person:secret@example.com/private"',
      'native/Sources/ParleyCoreChecks/main.swift',
    ),
    [],
  )

  assert.equal(
    scanText('https://real-user:real-secret@example.com', 'README.md')[0]?.rule,
    'url-credential',
  )
})

test('publication scan rejects credential-shaped historical filenames', () => {
  assert.deepEqual(
    scanHistoricalPaths(['README.md', '.env.production', 'certificates/release.p12']),
    ['.env.production', 'certificates/release.p12'],
  )
})

// The history used to be read into one 128 MB buffer and the scan failed
// closed once `git log -p` outgrew it (24.8 MB on 30 September 2026). Every
// rule matches within one line, so it is read line by line from a stream.
// The sample key is built at run time so this file does not hold one.
const sampleKey = 'AKIA' + 'ABCDEFGHIJKLMNOP'

test('history scan finds a credential split across stream chunks', async () => {
  const half = sampleKey.length / 2
  const findings = await scanHistoryStream(Readable.from([
    'commit 1\n+token=' + sampleKey.slice(0, half),
    sampleKey.slice(half) + '\n',
    '+nothing here\n',
  ]))
  assert.deepEqual(findings, [{ rule: 'aws-access-key', source: '<git-history>' }])
})

test('history scan still ignores the deliberate fixtures', async () => {
  const findings = await scanHistoryStream(Readable.from([
    '+"http://localhost:5173' + '@evil.example"\n',
    '+https://person:secret@example.com/private\n',
  ]))
  assert.deepEqual(findings, [])
})

test('the repository scan streams git log -p instead of buffering it', () => {
  const source = readFileSync(new URL('./public-repository-scan.mjs', import.meta.url), 'utf8')
  assert.doesNotMatch(source, /runGit\(\[\s*'log',\s*'-p'/)
  assert.match(source, /scanHistoryStream\(/)
})

// The real reader: git's own output, its failures, and no unhandled
// rejection or leftover process on any of them (Agy's review of MR !130).
function withTemporaryFolder(body) {
  const folder = mkdtempSync(join(tmpdir(), 'parley-scan-'))
  return Promise.resolve(body(folder)).finally(() => rmSync(folder, { recursive: true, force: true }))
}

async function withoutUnhandledRejections(body) {
  const seen = []
  const record = (reason) => seen.push(reason)
  process.on('unhandledRejection', record)
  try {
    await body()
    await new Promise((resolve) => setImmediate(resolve))
  } finally {
    process.off('unhandledRejection', record)
  }
  assert.deepEqual(seen, [], 'a rejection went unhandled')
}

test('history scan reads git and finds a secret only its history holds', async () => {
  await withTemporaryFolder(async (folder) => {
    const git = (...args) => execFileSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args], { cwd: folder })
    git('init', '-q')
    writeFileSync(join(folder, 'a'), 'x\n'); git('add', 'a'); git('commit', '-qm', 'one')
    writeFileSync(join(folder, 'a'), `token=${sampleKey}\n`); git('commit', '-qam', 'two')
    writeFileSync(join(folder, 'a'), 'x\n'); git('commit', '-qam', 'three')
    assert.deepEqual(await scanGitHistory({ cwd: folder }), [{ rule: 'aws-access-key', source: '<git-history>' }])
  })
})

test('history scan fails with git\'s own message outside a repository', async () => {
  await withTemporaryFolder(async (folder) => {
    await withoutUnhandledRejections(async () => {
      await assert.rejects(scanGitHistory({ cwd: folder }), /not a git repository/)
    })
  })
})

test('history scan fails cleanly when git cannot start', async () => {
  await withoutUnhandledRejections(async () => {
    await assert.rejects(scanGitHistory({ command: '/nonexistent/git' }), /ENOENT/)
  })
})

test('history scan names the signal that ended git', async () => {
  await withTemporaryFolder(async (folder) => {
    const fake = join(folder, 'git')
    writeFileSync(fake, '#!/bin/sh\nkill -TERM $$\n')
    chmodSync(fake, 0o755)
    await withoutUnhandledRejections(async () => {
      await assert.rejects(scanGitHistory({ command: fake }), /SIGTERM/)
    })
  })
})
