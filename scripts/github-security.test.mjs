import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

const repositoryRoot = join(import.meta.dirname, '..')
const workflowsDirectory = join(repositoryRoot, '.github', 'workflows')

test('low review saved layouts preserve the reviewed agent folder', () => {
  const source = readFileSync(join(repositoryRoot, 'native/Sources/ParleyNative/AppModel.swift'), 'utf8')
  const builder = source.slice(source.indexOf('func saved(_ node:'), source.indexOf('func saveActiveWorkspaceLayout'))
  assert.match(builder, /folder: pane\.launchWorkingDirectory/)
  assert.doesNotMatch(builder, /\.cwd/)
})

test('low review worktree actions validate integration and predict without attaching', () => {
  const source = readFileSync(join(repositoryRoot, 'native/Sources/ParleyNative/AppModel.swift'), 'utf8')
  const prediction = source.slice(source.indexOf('func predictWorktreeMerge('), source.indexOf('func predictWorktreeMerge(') + 1600)
  assert.match(prediction, /service\.mergePreview\(path: tree\.path/)
  assert.doesNotMatch(prediction, /ensureWorktreeRecord/)
  const integration = source.slice(source.indexOf('func proposeWorktreeIntegration('), source.indexOf('func integrateWorktreeFromManager('))
  // The branch is validated and named by its full ref inside mergeArgv
  // (checked in Swift by the worktree low-finding checks).
  assert.match(integration, /try WorktreeIntegration\.mergeArgv\(branch: branch\)/)
  const worktrees = readFileSync(join(repositoryRoot, 'native/Sources/ParleyCore/ManagedWorktrees.swift'), 'utf8')
  const mergeArgv = worktrees.slice(worktrees.indexOf('public static func mergeArgv('), worktrees.indexOf('public static func mergeArgv(') + 400)
  assert.match(mergeArgv, /try WorktreeNaming\.validateBranch\(branch\)/)
  assert.match(mergeArgv, /"refs\/heads\/\\\(branch\)"/)
})

test('the native permission review uses the selected vendor bypass disclosure', () => {
  const source = readFileSync(join(repositoryRoot, 'native/Sources/ParleyNative/PermissionProfilePickerView.swift'), 'utf8')
  assert.match(source, /detail:\s*ContainerLaunchProjection\.bypassDisclosure\(for: kind\)/,
    'the permission review must show the selected vendor flags, not a fixed vendor string')
  assert.match(source, /_kind = State\(initialValue: request\.kind\)/)
})

test('Dependabot watches Swift packages and GitHub Actions weekly', () => {
  const configuration = join(repositoryRoot, '.github', 'dependabot.yml')
  assert.equal(existsSync(configuration), true, '.github/dependabot.yml is missing')

  const source = readFileSync(configuration, 'utf8')
  assert.match(source, /package-ecosystem:\s*["']?swift["']?[\s\S]*?directory:\s*["']?\/native["']?[\s\S]*?interval:\s*["']?weekly["']?/)
  assert.match(source, /package-ecosystem:\s*["']?github-actions["']?[\s\S]*?directory:\s*["']?\/["']?[\s\S]*?interval:\s*["']?weekly["']?/)
})

// Every macOS workflow runs `npm test` as its four parts so the checks half
// can carry `--skip` for the two checks that need a Docker daemon the hosted
// runner has none of. The skip list is pinned by name here: widening it is a
// visible decision.
const dockerOnlyChecks = 'container bypass preflight,container follow-up image probe'

const workflow = (name) => {
  const path = join(workflowsDirectory, name)
  assert.equal(existsSync(path), true, `.github/workflows/${name} is missing`)
  return readFileSync(path, 'utf8')
}

const pin = (source, key) => {
  const match = source.match(new RegExp(`^\\s*${key}:\\s*"?([^"\\n]+?)"?\\s*$`, 'm'))
  assert.ok(match, `${key} is not pinned`)
  return match[1]
}

function assertRunsDeterministicChecks(source, label) {
  assert.match(source, /run:\s*npm run test:checks -- --skip "\$DOCKER_ONLY_CHECKS"/, `${label} must run the native checks with the declared Docker-only skip`)
  assert.match(source, /run:\s*npm run test:scripts/, `${label} must run the script tests`)
  assert.match(source, /run:\s*npm run scan:public/, `${label} must run the public repository scan`)
  assert.match(source, /run:\s*npm run scan:platform/, `${label} must run the platform dependency scan`)
  assert.doesNotMatch(source, /--skip (?!"\$DOCKER_ONLY_CHECKS")/, `${label} may skip only the declared Docker-only checks`)
  assert.doesNotMatch(source, /run:\s*npm test\s*$/m, `${label} must run the four parts, not npm test, so the skip reaches the checks`)
  assert.equal(pin(source, 'DOCKER_ONLY_CHECKS'), dockerOnlyChecks, `${label} may skip only the two Docker-only checks`)
  assert.match(source, /NODE_SHA256:\s*"[0-9a-f]{64}"/, `${label} must checksum the nodejs.org build`)
  assert.match(source, /shasum -a 256 -c -/, `${label} must verify the Node download before unpacking it`)
  assert.match(source, /runs-on:\s*macos-latest/, `${label} must run on the hosted macOS runner`)
  assert.match(source, /fetch-depth:\s*0/, `${label} must fetch complete history for the publication scan`)
  // The hosted image selects a full Xcode, whose /usr/bin/git shim forks
  // xcodebuild on a cold cache; GitReadBoundary forbids Git any fork, so the
  // guarded reads fail (run 38047165730, 10 October 2026). The Command Line
  // Tools shim execs the real Git, and must be selected before the checks.
  const select = source.indexOf('sudo xcode-select -s /Library/Developer/CommandLineTools')
  const checks = source.indexOf('npm run test:checks')
  assert.ok(select >= 0, `${label} must select the Command Line Tools toolchain`)
  assert.ok(select < checks, `${label} must select the Command Line Tools before the native checks run`)
}

test('macOS CI verifies pull requests and main with the four parts of npm test', () => {
  // The repository returned to github.com/markjoyeuxcom/parley on
  // 2026-10-10. It is public, so GitHub's hosted Apple silicon runners cost
  // nothing, and the self-hosted Tart runner on GitLab is retired.
  const source = workflow('ci.yml')
  assert.match(source, /pull_request:/)
  assert.match(source, /push:[\s\S]*?branches:\s*\[main\]/)
  assert.match(source, /permissions:\s*\n\s*contents:\s*read/, 'CI needs no write access')
  assertRunsDeterministicChecks(source, 'CI')
  assert.match(source, /run:\s*npm run build/)
  assert.match(source, /MACOS_IMAGE:\s*ghcr\.io\/cirruslabs\/macos-[a-z]+-base@sha256:[0-9a-f]{64}/, 'the local test VM image must be pinned by digest')
})

test('the three macOS workflows pin the same Node build and skip list', () => {
  const names = ['ci.yml', 'macos-test-beta-release.yml', 'macos-draft-release.yml']
  const pins = names.map((name) => {
    const source = workflow(name)
    return { name, version: pin(source, 'NODE_VERSION'), sha256: pin(source, 'NODE_SHA256'), skip: pin(source, 'DOCKER_ONLY_CHECKS') }
  })
  for (const entry of pins.slice(1)) {
    assert.equal(entry.version, pins[0].version, `${entry.name} pins a different Node version from ci.yml`)
    assert.equal(entry.sha256, pins[0].sha256, `${entry.name} pins a different Node digest from ci.yml`)
    assert.equal(entry.skip, pins[0].skip, `${entry.name} skips a different list from ci.yml`)
  }
})

test('macOS releases require versioned notes for the exact requested tag', () => {
  for (const name of ['macos-draft-release.yml', 'macos-test-beta-release.yml']) {
    const source = workflow(name)
    assert.ok(
      source.includes('notes=".github/release-notes/${PARLEY_RELEASE_TAG}.md"'),
      `${name}: release notes must be selected by the exact requested tag`,
    )
    assert.ok(source.includes('test -f "$notes"'), `${name}: the release must fail when its versioned notes are missing`)
    assert.ok(source.includes('--notes-file "$notes"'), `${name}: the GitHub release must use the versioned release notes`)
    assert.match(source, /workflow_dispatch:[\s\S]*?inputs:[\s\S]*?tag:/, `${name}: a person starts it with an explicit tag`)
    assert.match(source, /ref:\s*\$\{\{ inputs\.tag \}\}/, `${name}: the exact tag is checked out`)
    assert.match(source, /--verify-tag/, `${name}: the release must be created on the existing tag`)
    assert.doesNotMatch(source, /--dangerously|danger-full-access/, `${name}: no approval bypass`)
    assert.doesNotMatch(source, /vscode|vsix|companion/i, `${name}: the VS Code companion was retired in the September 2026 reduction`)
  }
})

test('macOS release packaging creates the shared artifact directory on a clean checkout', () => {
  for (const name of ['macos-draft-release.yml', 'macos-test-beta-release.yml']) {
    const source = workflow(name)
    const createDirectory = source.indexOf('mkdir -p dist')
    const soak = source.indexOf('npm run test:soak -- --rounds 25')
    assert.ok(createDirectory >= 0, `${name}: the release workflow must create dist before packaging`)
    assert.ok(createDirectory < soak, `${name}: dist must exist before the soak writes its report`)
    assert.ok(soak >= 0, `${name}: a release must pass the 25-round Ghostty soak`)
    assertRunsDeterministicChecks(source, name)
    assert.match(source, /npm run verify:launch:mac/, `${name}: a release must prove the packaged app reaches its event loop`)
  }
})

test('the notarized draft workflow signs in an ephemeral keychain and retains an unpublished draft', () => {
  const source = workflow('macos-draft-release.yml')
  assert.match(source, /security create-keychain/)
  assert.match(source, /security delete-keychain/)
  assert.match(source, /if: always\(\)/, 'signing material must be removed whether or not the release succeeded')
  assert.match(source, /PARLEY_NOTARY_KEY=/)
  assert.match(source, /PARLEY_SPARKLE_PRIVATE_ED_KEY:\s*\$\{\{ secrets\./)
  assert.match(source, /run:\s*npm run release:mac\s*$/m)
  assert.match(source, /--draft/, 'production assets are retained for review, never published by the workflow')
  assert.match(source, /"dist\/appcast\.xml"/)
  assert.match(source, /"dist\/parley\.rb"/)
  assert.doesNotMatch(source, /release:mac:beta|--unnotarized|--prerelease|git push/)
})

test('the test-beta workflow publishes an unnotarized prerelease with its own token and never overwrites one', () => {
  const source = workflow('macos-test-beta-release.yml')
  assert.match(source, /release:mac:beta/, 'a test beta must use the unnotarized release path')
  assert.match(source, /gh release create "\$PARLEY_RELEASE_TAG"/, 'the release must be created for the requested tag')
  assert.match(source, /--prerelease/, 'a test beta is a prerelease')
  assert.match(source, /gh release view "\$PARLEY_RELEASE_TAG"[\s\S]*?exit 1/, 'an existing release must fail the run instead of being overwritten')
  assert.match(source, /GH_TOKEN:\s*\$\{\{ github\.token \}\}/, 'the workflow signs in with its own token')
  assert.doesNotMatch(source, /secrets\.|GITLAB|glab /, 'no personal token or GitLab login takes part')
  assert.doesNotMatch(source, /appcast|parley\.rb|--draft/, 'a beta never emits a feed or cask and is published, not drafted')
  // The release CLI reads PARLEY_RELEASE_TAG from the environment and the
  // deterministic checks assert it is not preset, so it must be set on the
  // release step only, never at workflow or job level.
  const beforeJobs = source.slice(0, source.indexOf('jobs:'))
  assert.doesNotMatch(beforeJobs, /PARLEY_RELEASE_TAG/, 'PARLEY_RELEASE_TAG must not be a workflow-level variable')
  const releaseStep = source.slice(source.indexOf('Prepare and verify unnotarized test-beta assets'))
  assert.match(releaseStep, /env:\s*\n\s*PARLEY_RELEASE_TAG:\s*\$\{\{ inputs\.tag \}\}\s*\n\s*run:\s*npm run release:mac:beta/)
})

test('npm test is composed of the halves CI runs', () => {
  const scripts = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8')).scripts
  assert.equal(scripts.test, 'npm run test:checks && npm run test:scripts && npm run scan:public && npm run scan:platform')
  assert.match(scripts['test:checks'], /parley-native-checks$/, 'test:checks must end with the checks product so a --skip argument reaches it')
  assert.doesNotMatch(scripts['test:checks'], /--skip/, 'npm test itself skips nothing')
  assert.match(scripts['test:scripts'], /^node --test /)
})

test('no GitLab pipeline remains beside the GitHub workflows', () => {
  assert.equal(existsSync(join(repositoryRoot, '.gitlab-ci.yml')), false, '.gitlab-ci.yml must not come back: GitHub Actions is the one CI')
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
