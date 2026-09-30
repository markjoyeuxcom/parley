import assert from 'node:assert/strict'
import test from 'node:test'

import { readFileSync } from 'node:fs'
import { Readable } from 'node:stream'

import {
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
