import assert from 'node:assert/strict'
import test from 'node:test'

import {
  scanHistoricalPaths,
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
