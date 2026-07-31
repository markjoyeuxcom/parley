#!/usr/bin/env node
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

/**
 * Builds parley-remote.mjs: one file, no runtime npm dependencies.
 *
 * The bundle is the unit of distribution and the unit of identity. Everything
 * this script enforces exists to keep it that way:
 *
 *  - **Nothing may be external.** esbuild will happily leave an import
 *    unbundled and produce a file that works on this machine — where
 *    node_modules is one directory up — and fails on a host where it is not.
 *    Anything outside node: is a build failure, not a warning.
 *  - **The hash is computed after the build, from the finished bytes.** It is
 *    never embedded: putting the hash inside the file changes the file, so an
 *    embedded value cannot be the hash of what contains it. The runner hashes
 *    its own bytes at startup instead, and this manifest is what an installer
 *    compares that against.
 */

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const outDir = join(root, 'out', 'remote')
const outFile = join(outDir, 'parley-remote.mjs')

mkdirSync(outDir, { recursive: true })

const result = await build({
  entryPoints: [join(root, 'src', 'remote', 'main.ts')],
  outfile: outFile,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  // Bundle everything. The only things the runner reaches outside itself are
  // node builtins and the agent CLIs, and those are processes, not modules.
  packages: 'bundle',
  banner: { js: '#!/usr/bin/env node' },
  metafile: true,
  alias: {
    '@shared': join(root, 'src', 'shared'),
    '@main': join(root, 'src', 'main'),
  },
  logLevel: 'warning',
})

// With packages:'bundle' nothing is left unresolved, so an npm import does
// not fail the build — it silently makes the artifact bigger and drags in code
// that was never meant to run on someone else's host. The rule is that there
// must be none at all.
//
// The guard prints the PATH that pulled the package in, because "npm code
// appeared" is not actionable and "domain.ts imports zod, and pipeline.ts
// imports domain.ts" is. Finding that by hand costs an afternoon.
const fromNpm = Object.keys(result.metafile.inputs).filter((input) =>
  input.includes('node_modules'),
)
if (fromNpm.length > 0) {
  console.error('parley-remote must contain no npm code, but these were bundled:')
  for (const input of fromNpm.slice(0, 8)) console.error(`  ${input}`)
  const entryEdges = []
  for (const [file, info] of Object.entries(result.metafile.inputs)) {
    if (file.includes('node_modules')) continue
    for (const imported of info.imports ?? []) {
      if (imported.path.includes('node_modules')) {
        entryEdges.push(`  ${file}  ->  ${imported.original ?? imported.path}`)
      }
    }
  }
  if (entryEdges.length > 0) {
    console.error('\nthe edges that brought them in:')
    for (const edge of entryEdges.slice(0, 8)) console.error(edge)
    console.error(
      '\nmove the runtime value into a dependency leaf (see src/shared/usage.ts)',
    )
  }
  writeFileSync(join(outDir, 'metafile.json'), JSON.stringify(result.metafile, null, 2), 'utf8')
  console.error(`\nfull dependency graph written to ${join(outDir, 'metafile.json')}`)
  process.exit(1)
}

// Kept on success too: when someone asks why the bundle grew, this answers it.
writeFileSync(join(outDir, 'metafile.json'), JSON.stringify(result.metafile, null, 2), 'utf8')

const bytes = readFileSync(outFile)
const buildId = createHash('sha256').update(bytes).digest('hex')

writeFileSync(
  join(outDir, 'manifest.json'),
  `${JSON.stringify({ buildId, bytes: bytes.length, builtFrom: 'src/remote/main.ts' }, null, 2)}\n`,
  'utf8',
)

console.log(`parley-remote.mjs  ${(bytes.length / 1024).toFixed(1)} kB  ${buildId.slice(0, 12)}`)
