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
  assert.match(integration, /try WorktreeNaming\.validateBranch\(branch\)/)
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
  const soak = source.indexOf('npm run test:soak')

  assert.ok(createDirectory >= 0, 'the release workflow must create dist before packaging')
  assert.ok(createDirectory < soak, 'dist must exist before the soak writes its report')
  assert.doesNotMatch(source, /vscode|vsix|companion/i, 'the VS Code companion was retired in the September 2026 reduction')
})

// The pipeline runs `npm test` as its four parts so the checks half can carry
// `--skip` for the two checks that need a Docker daemon the CI VM cannot run.
// The skip list is pinned by name here: widening it is a visible decision.
const dockerOnlyChecks = 'container bypass preflight,container follow-up image probe'

function assertRunsDeterministicChecks(job, label) {
  assert.match(job, /-\s*npm run test:checks -- --skip "\$DOCKER_ONLY_CHECKS"/, `${label} must run the native checks with the declared Docker-only skip`)
  assert.match(job, /-\s*npm run test:scripts/, `${label} must run the script tests`)
  assert.match(job, /-\s*npm run scan:public/, `${label} must run the public repository scan`)
  assert.match(job, /-\s*npm run scan:platform/, `${label} must run the platform dependency scan`)
  assert.doesNotMatch(job, /--skip (?!"\$DOCKER_ONLY_CHECKS")/, `${label} may skip only the declared Docker-only checks`)
}

test('GitLab production preparation requires a protected tag, signing and reviewed artifacts', () => {
  const source = readFileSync(join(repositoryRoot, '.gitlab-ci.yml'), 'utf8')
  const job = source.slice(source.indexOf('prepare-production-release:'), source.indexOf('# Cuts an unnotarized test beta'))
  assert.match(job, /CI_COMMIT_REF_PROTECTED == "true"/)
  assert.match(job, /when: manual/)
  assertRunsDeterministicChecks(job, 'production preparation')
  assert.match(job, /npm run test:soak -- --rounds 25/)
  assert.match(job, /trap cleanup_signing EXIT/)
  assert.match(job, /security delete-keychain/)
  assert.match(job, /keychains\.json/)
  assert.match(job, /json\.load\(open\(sys\.argv\[1\]\)\)/)
  assert.ok(job.indexOf('test -f "$notes"') < job.indexOf('npm run release:mac'))
  assert.match(job, /PARLEY_NOTARY_KEY=/)
  assert.match(job, /PARLEY_SPARKLE_PRIVATE_ED_KEY=/)
  assert.match(job, /npm run release:mac\n/)
  assert.match(job, /npm run verify:launch:mac/)
  assert.match(job, /when: on_success/)
  assert.match(job, /dist\/appcast\.xml/)
  assert.match(job, /dist\/parley\.rb/)
  assert.doesNotMatch(job, /release:mac:beta|--unnotarized|(?:glab|gh) release create|git push/)
  const artifacts = job.slice(job.indexOf('  artifacts:'))
  assert.doesNotMatch(artifacts, /signing_dir|\.p12|\.p8|keychain/)
})

test('npm test is composed of the halves the pipeline runs', () => {
  const scripts = JSON.parse(readFileSync(join(repositoryRoot, 'package.json'), 'utf8')).scripts
  assert.equal(scripts.test, 'npm run test:checks && npm run test:scripts && npm run scan:public && npm run scan:platform')
  assert.match(scripts['test:checks'], /parley-native-checks$/, 'test:checks must end with the checks product so a --skip argument reaches it')
  assert.doesNotMatch(scripts['test:checks'], /--skip/, 'npm test itself skips nothing')
  assert.match(scripts['test:scripts'], /^node --test /)
})

test('GitLab CI is the deterministic macOS gate for merge requests and main', () => {
  // The repository moved to gitlab.com/markjoyeuxcom/apps/parley on
  // 2026-09-07. GitLab.com's hosted macOS runners are a paid-tier feature,
  // so the pipeline targets the self-hosted runner tagged `macos`, which since
  // 2026-09-19 runs every job in a throwaway Tart VM: each job needs an
  // `image:`, pinned by digest, and names its own toolchain paths.
  const pipeline = join(repositoryRoot, '.gitlab-ci.yml')
  assert.equal(existsSync(pipeline), true, '.gitlab-ci.yml is missing')
  const source = readFileSync(pipeline, 'utf8')
  assert.match(source, /tags:\s*\n\s*-\s*macos/, 'the job must target a macOS runner')
  assert.match(source, /MACOS_IMAGE:\s*ghcr\.io\/cirruslabs\/macos-[a-z]+-base@sha256:[0-9a-f]{64}/, 'the Tart image must be pinned by digest')
  assert.match(source, /default:\s*\n\s*image:\s*\$MACOS_IMAGE/, 'every job must name the pinned image or the Tart executor refuses to prepare it')
  assert.match(source, /NODE_SHA256:\s*"[0-9a-f]{64}"/, 'the nodejs.org build must be checksummed')
  assert.match(source, /shasum -a 256 -c -/, 'the Node download must be verified before it is unpacked')
  assert.match(source, new RegExp(`DOCKER_ONLY_CHECKS:\\s*"${dockerOnlyChecks}"`), 'only the two Docker-only checks may be skipped in the VM')
  const verify = source.slice(source.indexOf('test-and-build:'), source.indexOf('release-beta:'))
  assertRunsDeterministicChecks(verify, 'the verify job')
  assert.match(verify, /-\s*npm run build/, 'the job must build the native application')
  assert.match(source, /GIT_DEPTH:\s*0/, 'the public scan needs the complete reachable history')
  assert.match(source, /merge_request_event/, 'merge requests must be verified')
  assert.match(source, /CI_COMMIT_BRANCH == \$CI_DEFAULT_BRANCH/, 'pushes to main must be verified')
})

test('the GitLab release job is manual, tag-only, and publishes a GitLab release with its job token', () => {
  // GitHub Actions minutes are exhausted, so the test-beta release runs on the
  // macOS runner and publishes a release of the GitLab project itself, with
  // the files in the project's generic package registry. The job signs in with
  // its own CI job token; no personal GitLab or GitHub login on the runner
  // takes part, and nothing is pushed to or published on GitHub.
  const source = readFileSync(join(repositoryRoot, '.gitlab-ci.yml'), 'utf8')
  const job = source.slice(source.indexOf('release-beta:'))
  assert.ok(job.length > 0, 'the release-beta job is missing')
  assert.match(job, /when:\s*manual/, 'a release must be started by a person')
  assert.match(job, /CI_COMMIT_TAG =~/, 'a release must come from a version tag')
  assertRunsDeterministicChecks(job, 'the release job')
  assert.match(job, /-\s*brew install glab/, 'the throwaway VM has no glab; the job installs it')
  assert.match(job, /test:soak -- --rounds 25/, 'a release must pass the 25-round Ghostty soak')
  assert.match(job, /release:mac:beta/, 'a test beta must use the unnotarized release path')
  assert.match(job, /verify:launch:mac/, 'a release must prove the packaged app reaches its event loop')
  assert.match(job, /GLAB_ENABLE_CI_AUTOLOGIN=true glab release create "\$CI_COMMIT_TAG"/, 'the release must be created for the pipeline tag with the job token')
  assert.match(job, /--repo "\$CI_PROJECT_PATH"/, 'the release must target the project the pipeline runs in')
  assert.match(job, /--use-package-registry/, 'release files must live in the generic package registry')
  assert.match(job, /--package-name parley/, 'release files must live under the parley package')
  assert.match(job, /--no-update/, 'an existing release must fail the job instead of being overwritten')
  assert.match(job, /--notes-file/, 'the release must carry the version notes')
  assert.doesNotMatch(job, /gh release|github\.com|GITHUB_/, 'the job must neither publish on nor push to GitHub')
  assert.doesNotMatch(job, /GITLAB_TOKEN|PRIVATE-TOKEN|glab auth login/, 'no personal token may take part in the release')
  assert.doesNotMatch(job, /--dangerously|danger-full-access/, 'no approval bypass')
  // The release CLI reads PARLEY_RELEASE_TAG from the environment and the
  // deterministic checks assert it is not preset, so it must not be a job
  // variable; only the release step may set it.
  assert.doesNotMatch(job, /^\s+PARLEY_RELEASE_TAG:/m, 'PARLEY_RELEASE_TAG must not be a job-level variable')
  assert.match(job, /PARLEY_RELEASE_TAG="\$CI_COMMIT_TAG" npm run release:mac:beta/, 'the release step must receive the tag explicitly')
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
