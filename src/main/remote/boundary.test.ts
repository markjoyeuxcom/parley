import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The dependency boundary the remote bundle rests on.
 *
 * The rule is that the bundle contains Parley's own code, Node built-ins, and
 * nothing from node_modules — and it is only worth having if it stays
 * absolute, because an allow-list that starts with one harmless package does
 * not stay one package long.
 *
 * These assertions bundle for real rather than reading import statements. A
 * grep would miss a transitive edge, which is exactly how zod got in: not
 * through the execution core's own imports, but through one value it took
 * from a module that had schemas in it.
 */

const repoRoot = resolve(__dirname, '..', '..', '..')

/** Bundles a module in isolation and reports every module it dragged in. */
function graphOf(entry: string): string[] {
  const script = `
    const path = require('path')
    import('esbuild').then(async (esbuild) => {
      const r = await esbuild.build({
        entryPoints: [${JSON.stringify(entry)}],
        bundle: true, platform: 'node', format: 'esm', target: 'node20',
        packages: 'bundle', write: false, metafile: true, logLevel: 'silent',
        alias: { '@shared': path.resolve('src/shared'), '@main': path.resolve('src/main') },
      })
      process.stdout.write(JSON.stringify(Object.keys(r.metafile.inputs)))
    })
  `
  const out = execFileSync(process.execPath, ['-e', script], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: 120_000,
  })
  return JSON.parse(out) as string[]
}

function npmInputsFor(entry: string): string[] {
  return graphOf(entry).filter((input) => input.includes('node_modules'))
}

describe('the dependency boundary', () => {
  it('loads the usage leaf without loading the schema library', () => {
    expect(npmInputsFor('src/shared/usage.ts')).toEqual([])
  }, 120_000)

  it('loads the id leaf without loading the persistence layer', () => {
    expect(npmInputsFor('src/main/util/ids.ts')).toEqual([])
  }, 120_000)

  it('keeps the whole execution core free of npm code', () => {
    // pipeline.ts is the entry the remote runner will host, and it reaches the
    // agents, the worktree helpers and the containers seam. If any of them
    // acquires an npm import this fails here, rather than at install time on
    // somebody else's host.
    expect(npmInputsFor('src/main/orchestrator/pipeline.ts')).toEqual([])
  }, 120_000)

  it('keeps the shipped remote entry free of npm code', () => {
    expect(npmInputsFor('src/remote/main.ts')).toEqual([])
  }, 120_000)

  it('keeps the execution core unable to reach the record', () => {
    // The architectural assertion m3b2a exists for, and it is checked by
    // BUNDLING rather than by reading imports: the first version of the core
    // pulled in ipc/ledger transitively — through helpers that still lived in
    // the facade — while every import statement in the file looked innocent.
    //
    // A dependency that cannot be expressed cannot creep back, and this is
    // what makes it inexpressible: add a store import to the core and the
    // build of parley-remote fails, rather than the failure waiting to be
    // discovered on somebody else's host.
    const core = graphOf('src/main/orchestrator/execution.ts')
    expect(core.filter((input) => input.includes('/store/'))).toEqual([])
    expect(core.filter((input) => input.includes('/ipc/'))).toEqual([])
    expect(core.filter((input) => input.includes('node_modules'))).toEqual([])
    expect(core).not.toContain('src/main/orchestrator/pipeline.ts')
  }, 120_000)

  it('keeps the remote worker free of the record too', () => {
    // The worker is what the bundle actually runs. It hosts the execution
    // core, so it inherits the core's boundary — and asserting it here means a
    // regression fails at the boundary rather than at install time.
    const worker = graphOf('src/remote/worker.ts')
    expect(worker.filter((input) => input.includes('/store/'))).toEqual([])
    expect(worker.filter((input) => input.includes('/ipc/'))).toEqual([])
    expect(worker.filter((input) => input.includes('node_modules'))).toEqual([])
  }, 120_000)

  it('keeps the evidence leaf a leaf', () => {
    const evidence = graphOf('src/main/orchestrator/evidence.ts')
    expect(evidence.filter((input) => input.includes('/store/'))).toEqual([])
    expect(evidence.filter((input) => input.includes('node_modules'))).toEqual([])
    expect(evidence).not.toContain('src/main/orchestrator/execution.ts')
  }, 120_000)

  it('still shows the schema library where it legitimately belongs', () => {
    // Not a purity crusade: domain.ts SHOULD import zod. This asserts the
    // library is still there rather than having been removed by accident,
    // which would mean validation had quietly stopped happening.
    expect(npmInputsFor('src/shared/domain.ts').some((path) => path.includes('zod'))).toBe(true)
  }, 120_000)
})
