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
    include: ['src/**/*.test.ts'],
    // node-pty and electron are only loadable inside the Electron runtime.
    exclude: ['**/node_modules/**', 'out/**', 'dist/**'],
  },
})
