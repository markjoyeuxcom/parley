import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

const repositoryRoot = join(import.meta.dirname, '..')
const workflowsDirectory = join(repositoryRoot, '.github', 'workflows')

test('Dependabot watches Swift, VS Code npm packages and GitHub Actions weekly', () => {
  const configuration = join(repositoryRoot, '.github', 'dependabot.yml')
  assert.equal(existsSync(configuration), true, '.github/dependabot.yml is missing')

  const source = readFileSync(configuration, 'utf8')
  assert.match(source, /package-ecosystem:\s*["']?swift["']?[\s\S]*?directory:\s*["']?\/native["']?[\s\S]*?interval:\s*["']?weekly["']?/)
  assert.match(source, /package-ecosystem:\s*["']?npm["']?[\s\S]*?directory:\s*["']?\/vscode-extension["']?[\s\S]*?interval:\s*["']?weekly["']?/)
  assert.match(source, /package-ecosystem:\s*["']?github-actions["']?[\s\S]*?directory:\s*["']?\/["']?[\s\S]*?interval:\s*["']?weekly["']?/)
})

test('macOS CI verifies pull requests and main', () => {
  const workflow = join(workflowsDirectory, 'ci.yml')
  assert.equal(existsSync(workflow), true, '.github/workflows/ci.yml is missing')

  const source = readFileSync(workflow, 'utf8')
  assert.match(source, /pull_request:/)
  assert.match(source, /push:[\s\S]*?branches:\s*\[main\]/)
  assert.match(source, /runs-on:\s*macos-latest/)
  assert.match(source, /fetch-depth:\s*0/, 'CI must fetch complete history for the publication scan')
  assert.match(source, /run:\s*npm test/)
  assert.match(source, /run:\s*npm run build/)
})

test('macOS releases require versioned notes for the exact requested tag', () => {
  const workflow = join(workflowsDirectory, 'macos-draft-release.yml')
  assert.equal(existsSync(workflow), true, '.github/workflows/macos-draft-release.yml is missing')

  const source = readFileSync(workflow, 'utf8')
  assert.ok(
    source.includes('notes=".github/release-notes/${PARLEY_RELEASE_TAG}.md"'),
    'release notes must be selected by the exact requested tag',
  )
  assert.ok(source.includes('test -f "$notes"'), 'the release must fail when its versioned notes are missing')
  assert.ok(source.includes('--notes-file "$notes"'), 'the GitHub draft must use the versioned release notes')
})

test('macOS release packaging creates the shared artifact directory on a clean checkout', () => {
  const workflow = join(workflowsDirectory, 'macos-draft-release.yml')
  const source = readFileSync(workflow, 'utf8')
  const createDirectory = source.indexOf('mkdir -p dist')
  const packageCompanion = source.indexOf('npm run package:vscode')

  assert.ok(createDirectory >= 0, 'the release workflow must create dist before packaging')
  assert.ok(packageCompanion >= 0, 'the release workflow must package the VS Code companion')
  assert.ok(createDirectory < packageCompanion, 'dist must exist before VS Code packaging writes its VSIX')
})

test('retired GitLab automation cannot become an apparent security gate', () => {
  assert.equal(existsSync(join(repositoryRoot, '.gitlab-ci.yml')), false)
})

test('public repository policy files describe the Apache-2.0 open-source boundary', () => {
  const license = readFileSync(join(repositoryRoot, 'LICENSE'), 'utf8')
  const security = readFileSync(join(repositoryRoot, 'SECURITY.md'), 'utf8')
  const privacy = readFileSync(join(repositoryRoot, 'PRIVACY.md'), 'utf8')
  const contributing = readFileSync(join(repositoryRoot, 'CONTRIBUTING.md'), 'utf8')

  assert.match(license, /Apache License/)
  assert.match(license, /Version 2\.0, January 2004/)
  assert.match(security, /Report a vulnerability/)
  assert.match(security, /Cross-vendor messages.*untrusted/s)
  assert.match(privacy, /does not collect telemetry/)
  assert.match(contributing, /Apache License 2\.0/)
})

test('external GitHub Actions are pinned to immutable full commit SHAs', () => {
  const workflowFiles = readdirSync(workflowsDirectory)
    .filter((name) => name.endsWith('.yml') || name.endsWith('.yaml'))

  const mutableReferences = []
  let externalActionCount = 0
  for (const name of workflowFiles) {
    const lines = readFileSync(join(workflowsDirectory, name), 'utf8').split('\n')
    for (const [index, line] of lines.entries()) {
      const reference = line.match(/^\s*uses:\s*([^\s#]+)(?:\s+#\s*(\S+))?\s*$/)
      if (!reference || reference[1].startsWith('./')) continue
      externalActionCount += 1
      if (!/@[0-9a-f]{40}$/.test(reference[1]) || !reference[2]) {
        mutableReferences.push(`${name}:${index + 1}`)
      }
    }
  }

  assert.ok(externalActionCount > 0, 'no external Actions were inspected')
  assert.deepEqual(mutableReferences, [], `mutable or undocumented Action references: ${mutableReferences.join(', ')}`)
})
