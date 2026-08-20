import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import './styles/tokens.css'
import './styles/base.css'
import './styles/components.css'
import './styles/surfaces.css'
import { installTauriBridge } from './lib/bridge.tauri'

/**
 * Parley's first window on Tauri.
 *
 * Deliberately not the real Grid. Five of about a hundred commands exist in
 * Rust so far, and mounting the full surface would produce a wall of loud
 * failures from the ninety-five that do not — true, but useless. This mounts
 * the one path that matters right now: a real CLI in a real PTY, drawn by
 * xterm inside WKWebView.
 *
 * That is also the measurement this migration was chosen for. The Electron
 * renderer died about every ten minutes with three busy panes; whether this
 * one does is the question, and it cannot be asked without a terminal on
 * screen.
 *
 * The bridge is installed BEFORE anything else is imported. `ptyBuffer`
 * subscribes to pane output at module load — that is what stops a shell's
 * first prompt being lost between spawn and mount — so a later install would
 * leave it silently unsubscribed.
 */
installTauriBridge()

const host = document.getElementById('root')
if (!host) throw new Error('missing #root')

const { TauriShell } = await import('./TauriShell')
createRoot(host).render(<TauriShell />)
