import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

const repositoryRoot = join(import.meta.dirname, '..')
const workflowsDirectory = join(repositoryRoot, '.github', 'workflows')

test('Dependabot watches Swift packages and GitHub Actions weekly', () => {
  const configuration = join(repositoryRoot, '.github', 'dependabot.yml')
  assert.equal(existsSync(configuration), true, '.github/dependabot.yml is missing')

  const source = readFileSync(configuration, 'utf8')
  assert.match(source, /package-ecosystem:\s*["']?swift["']?[\s\S]*?directory:\s*["']?\/native["']?[\s\S]*?interval:\s*["']?weekly["']?/)
  assert.match(source, /package-ecosystem:\s*["']?github-actions["']?[\s\S]*?directory:\s*["']?\/["']?[\s\S]*?interval:\s*["']?weekly["']?/)
})

test('macOS CI verifies pull requests and main', () => {
  const workflow = join(workflowsDirectory, 'ci.yml')
  assert.equal(existsSync(workflow), true, '.github/workflows/ci.yml is missing')

  const source = readFileSync(workflow, 'utf8')
  assert.match(source, /pull_request:/)
  assert.match(source, /push:[\s\S]*?branches:\s*\[main\]/)
  assert.match(source, /runs-on:\s*macos-latest/)
  assert.match(source, /run:\s*npm test/)
  assert.match(source, /run:\s*npm run build/)
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
