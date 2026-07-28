import { resolve } from 'node:path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve('src/shared'),
      '@main': resolve('src/main'),
    },
  },
  test: {
    environment: 'node',
    // .tsx carries the mounted-surface smoke tests; they opt into jsdom with
    // a per-file @vitest-environment pragma, so main-process suites stay node.
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
    // node-pty and electron are only loadable inside the Electron runtime.
    exclude: ['**/node_modules/**', 'out/**', 'dist/**'],
  },
})
