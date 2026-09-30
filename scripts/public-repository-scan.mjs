import { spawn, spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath, pathToFileURL } from 'node:url'

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')

const rules = [
  { rule: 'aws-access-key', pattern: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { rule: 'github-token', pattern: /\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b/ },
  { rule: 'anthropic-token', pattern: /\bsk-ant-[A-Za-z0-9_-]{16,}\b/ },
  { rule: 'openai-token', pattern: /\bsk-[A-Za-z0-9_-]{24,}\b/ },
  { rule: 'slack-token', pattern: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/ },
  { rule: 'private-key', pattern: /-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/ },
  { rule: 'url-credential', pattern: /https?:\/\/[^\s/:@]+:[^\s/@]+@[^\s/]+/ },
]

const deliberateFixtures = new Map([
  ['native/Sources/ParleyCoreChecks/main.swift', [
    'https://person:secret@example.com/private',
  ]],
  ['scripts/public-repository-scan.test.mjs', [
    'AKIA1234567890ABCDEF',
    'github_pat_1234567890abcdefghijklmnop',
    '-----BEGIN OPENSSH PRIVATE KEY-----',
    'https://person:secret@example.com/private',
    'https://real-user:real-secret@example.com',
  ]],
  ['scripts/public-repository-scan.mjs', [
    // Exact fixtures named by this scanner's own narrow allowlist.
    'AKIA1234567890ABCDEF',
    'github_pat_1234567890abcdefghijklmnop',
    '-----BEGIN OPENSSH PRIVATE KEY-----',
    'https://person:secret@example.com/private',
    'https://real-user:real-secret@example.com',
    'http://localhost:5173@evil.example',
  ]],
  ['<git-history>', [
    // Historical URL-parser rejection fixture from the retired Electron app.
    'http://localhost:5173@evil.example',
  ]],
])

const sensitiveHistoricalPath = /(?:^|\/)(?:\.env(?:\.[^/]+)?|\.npmrc|\.pypirc|\.netrc|id_(?:rsa|ed25519)|[^/]+\.(?:pem|p12|pfx|key|mobileprovision))$/i

function withoutDeliberateFixtures(text, source) {
  let inspected = text
  for (const fixture of deliberateFixtures.get(source) ?? []) {
    inspected = inspected.replaceAll(fixture, '')
  }
  return inspected
}

export function scanText(text, source) {
  const inspected = withoutDeliberateFixtures(text, source)
  return rules
    .filter(({ pattern }) => pattern.test(inspected))
    .map(({ rule }) => ({ rule, source }))
}

// Every rule matches within one line, so history is scanned line by line from
// a stream with no size limit. It used to be read into one 128 MB buffer, and
// the scan failed closed once `git log -p` outgrew it (24.8 MB on 30 September
// 2026, growing about 3 MB a month). The deliberate fixtures are single lines
// too, so removing them per line is the same as removing them from the whole.
export async function scanHistoryStream(input, source = '<git-history>') {
  const found = new Map()
  const allFixtures = [...deliberateFixtures.values()].flat()
  for await (const line of createInterface({ input, crlfDelay: Infinity })) {
    let inspected = line
    for (const fixture of allFixtures) inspected = inspected.replaceAll(fixture, '')
    for (const finding of scanText(inspected, source)) found.set(finding.rule, finding)
  }
  return rules.filter(({ rule }) => found.has(rule)).map(({ rule }) => found.get(rule))
}

// `git log -p` as a stream, with its exit status checked once it has been read.
async function scanGitHistory() {
  const child = spawn('git', ['log', '-p', '--all', '--full-history', '--no-color', '--no-ext-diff'], {
    cwd: repositoryRoot,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let stderr = ''
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const exited = new Promise((resolveExit, rejectExit) => {
    child.on('error', rejectExit)
    child.on('close', (status) => resolveExit(status))
  })
  const findings = await scanHistoryStream(child.stdout)
  const status = await exited
  if (status !== 0) throw new Error(stderr.trim() || 'git log -p failed')
  return findings
}

export function scanHistoricalPaths(paths) {
  return paths.filter((path) => sensitiveHistoricalPath.test(path))
}

function runGit(arguments_) {
  const result = spawnSync('git', arguments_, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    maxBuffer: 128 * 1024 * 1024,
  })
  if (result.status !== 0) {
    throw new Error(result.stderr.trim() || `git ${arguments_.join(' ')} failed`)
  }
  return result.stdout
}

async function scanRepository() {
  const findings = []
  const trackedPaths = runGit([
    'ls-files', '--cached', '--others', '--exclude-standard', '-z',
  ]).split('\0').filter(Boolean).filter((path) => existsSync(resolve(repositoryRoot, path)))
  for (const path of trackedPaths) {
    const data = readFileSync(resolve(repositoryRoot, path))
    if (data.includes(0)) continue
    findings.push(...scanText(data.toString('utf8'), path))
  }

  const historyPaths = runGit(['log', '--all', '--name-only', '--format='])
    .split('\n')
    .map((path) => path.trim())
    .filter(Boolean)
  for (const path of scanHistoricalPaths(historyPaths)) {
    findings.push({ rule: 'sensitive-historical-path', source: path })
  }

  findings.push(...await scanGitHistory())

  const unique = [...new Map(findings.map((finding) => [
    `${finding.rule}\0${finding.source}`,
    finding,
  ])).values()]

  if (unique.length > 0) {
    process.stderr.write('Public repository scan found material that requires review:\n')
    for (const finding of unique) {
      process.stderr.write(`- ${finding.rule}: ${finding.source}\n`)
    }
    process.exitCode = 1
    return
  }

  process.stdout.write(
    `Public repository scan passed: ${trackedPaths.length} publishable files and complete reachable Git history checked.\n`,
  )
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  scanRepository().catch((error) => {
    process.stderr.write(`Public repository scan could not run: ${error.message}\n`)
    process.exitCode = 1
  })
}
