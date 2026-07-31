import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { addUsage, emptyUsage } from './usage'
import * as domain from './domain'

/**
 * The dependency leaf, and the boundary it exists to protect.
 *
 * The remote execution bundle must contain Parley's own code, Node built-ins,
 * and nothing from node_modules. That rule is only worth having if it is
 * absolute — an allow-list that starts with one harmless package does not stay
 * one long — so these tests check the boundary itself, not just the values.
 */

const repoRoot = resolve(__dirname, '..', '..')

/** Bundles a module in isolation and reports what it dragged in. */
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

describe('the values themselves', () => {
  it('starts every counter at zero', () => {
    expect(emptyUsage()).toEqual({
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      reasoningTokens: 0,
      costUsd: 0,
    })
  })

  it('returns a fresh object each time, so accumulating cannot alias', () => {
    const a = emptyUsage()
    a.inputTokens = 5
    expect(emptyUsage().inputTokens).toBe(0)
  })

  it('adds every field', () => {
    expect(
      addUsage(
        { inputTokens: 1, cachedInputTokens: 2, outputTokens: 3, reasoningTokens: 4, costUsd: 0.5 },
        { inputTokens: 10, cachedInputTokens: 20, outputTokens: 30, reasoningTokens: 40, costUsd: 1.5 },
      ),
    ).toEqual({
      inputTokens: 11,
      cachedInputTokens: 22,
      outputTokens: 33,
      reasoningTokens: 44,
      costUsd: 2,
    })
  })
})

describe('existing callers are unaffected', () => {
  it('still reaches the same values through domain', () => {
    // The re-export is what makes this a narrow extraction rather than a
    // repository-wide import rewrite. One definition, two doors.
    expect(domain.emptyUsage).toBe(emptyUsage)
    expect(domain.addUsage).toBe(addUsage)
  })

  it('still validates a usage object against the schema', () => {
    // The schema stays where it was. Splitting the VALUE out must not have
    // changed what the boundary accepts.
    expect(domain.Usage.parse(emptyUsage())).toEqual(emptyUsage())
    expect(() => domain.Usage.parse({ inputTokens: -1 })).toThrow()
  })
})

describe('the dependency boundary', () => {
  it('loads the leaf without loading the schema library', () => {
    expect(npmInputsFor('src/shared/usage.ts')).toEqual([])
  }, 120_000)

  it('keeps the whole execution core free of npm code', () => {
    // The assertion the remote bundle depends on: pipeline.ts is the entry
    // point the remote runner will eventually host, and it reaches the agents,
    // the worktree helpers and the containers seam. If any of them acquires an
    // npm import, this fails here rather than at install time on a host.
    expect(npmInputsFor('src/main/orchestrator/pipeline.ts')).toEqual([])
  }, 120_000)

  it('still shows the schema library where it legitimately belongs', () => {
    // Not a purity crusade: domain.ts SHOULD import zod. The point is that the
    // execution core no longer inherits it, so this asserts the library is
    // still there rather than having been removed by accident.
    expect(npmInputsFor('src/shared/domain.ts').some((path) => path.includes('zod'))).toBe(true)
  }, 120_000)
})
