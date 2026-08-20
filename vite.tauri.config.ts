import { resolve } from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

/**
 * The renderer, served for Tauri instead of Electron.
 *
 * Same root, same aliases, same React — only the entry differs, because the
 * Grid's surfaces need commands that have no Rust behind them yet. The point of
 * the migration's shape is that this config is nearly empty: the renderer never
 * depended on Electron, only on the one bridge interface.
 */
export default defineConfig({
  root: resolve('src/renderer'),
  plugins: [react()],
  // Tauri drives this; failing loudly beats silently taking another port and
  // leaving the window pointed at nothing.
  server: { port: 5173, strictPort: true },
  build: {
    outDir: resolve('out/renderer'),
    emptyOutDir: true,
    rollupOptions: { input: { index: resolve('src/renderer/tauri.html') } },
  },
  resolve: {
    alias: {
      '@shared': resolve('src/shared'),
      '@renderer': resolve('src/renderer/src'),
    },
  },
})
