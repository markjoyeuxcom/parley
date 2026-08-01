#!/usr/bin/env node
import { chmodSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

/**
 * Builds parley: the record, readable from a terminal.
 *
 * Unlike parley-remote this one MAY contain npm code — it runs on this
 * machine, beside the app, and zod is how the record is read. What it may not
 * contain is Electron, and that is the guard below.
 *
 * The reason is the same one that makes the CLI possible at all: everything
 * that knows about plans, milestones and journals was kept free of Electron
 * so it could be tested without a window. An `app.getPath` reaching the store
 * would end that quietly — the bundle would still build here, where Electron
 * is installed, and fail the moment anyone ran it from a shell.
 */

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const outDir = join(root, 'out', 'cli')
const outFile = join(outDir, 'parley.mjs')

mkdirSync(outDir, { recursive: true })

const result = await build({
  entryPoints: [join(root, 'src', 'cli', 'main.ts')],
  outfile: outFile,
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  packages: 'bundle',
  banner: { js: '#!/usr/bin/env node' },
  metafile: true,
  alias: {
    '@shared': join(root, 'src', 'shared'),
    '@main': join(root, 'src', 'main'),
  },
  logLevel: 'warning',
})

// Electron is the one thing that cannot be here. It is not a library the CLI
// could carry: it is a runtime that only exists inside the app process, so an
// import of it produces a bundle that builds cleanly and dies on the first
// line of every real invocation.
const electron = Object.entries(result.metafile.inputs).flatMap(([file, info]) =>
  file.includes('node_modules')
    ? []
    : (info.imports ?? [])
        .filter((imported) => (imported.original ?? imported.path) === 'electron')
        .map((imported) => `  ${file}  ->  ${imported.original ?? imported.path}`),
)
if (electron.length > 0) {
  console.error('parley (cli) must not import electron, but these do:')
  for (const edge of electron) console.error(edge)
  console.error(
    '\nthe record and the orchestrator stay Electron-free on purpose; inject the value ' +
      'through OrchestratorDeps the way selfRepoPath and appPath are.',
  )
  process.exit(1)
}

chmodSync(outFile, 0o755)

const bytes = Object.values(result.metafile.outputs)[0]?.bytes ?? 0
console.log(`parley.mjs  ${(bytes / 1000).toFixed(1)} kB`)
