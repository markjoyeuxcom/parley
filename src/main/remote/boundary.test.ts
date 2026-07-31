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

/** Bundles a module in isolation and reports what npm code it dragged in. */
function npmInputsFor(entry: string): string[] {
  const script = `
    const path = require('path')
    import('esbuild').then(async (esbuild) => {
      const r = await esbuild.build({
        entryPoints: [${JSON.stringify(entry)}],
        bundle: true, platform: 'node', format: 'esm', target: 'node20',
        packages: 'bundle', write: false, metafile: true, logLevel: 'silent',
        alias: { '@shared': path.resolve('src/shared'), '@main': path.resolve('src/main') },
      })
      const npm = Object.keys(r.metafile.inputs).filter((i) => i.includes('node_modules'))
      process.stdout.write(JSON.stringify(npm))
    })
  `
  const out = execFileSync(process.execPath, ['-e', script], {
    cwd: repoRoot,
    encoding: 'utf8',
    timeout: 120_000,
  })
  return JSON.parse(out) as string[]
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

  it('still shows the schema library where it legitimately belongs', () => {
    // Not a purity crusade: domain.ts SHOULD import zod. This asserts the
    // library is still there rather than having been removed by accident,
    // which would mean validation had quietly stopped happening.
    expect(npmInputsFor('src/shared/domain.ts').some((path) => path.includes('zod'))).toBe(true)
  }, 120_000)
})
