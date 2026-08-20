import { join } from 'node:path'
import { app, BrowserWindow, nativeTheme, Notification, powerSaveBlocker, shell } from 'electron'
import type { AppEvent, PtyChunk } from '@shared/events'
import { CH, type CliHealth } from '@shared/ipc'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import { PtyManager } from '@main/pty/manager'
import { PtyOutputBatcher } from '@main/pty/batch'
import { RoomManager } from '@main/rooms/manager'
import { disposeIpc, registerIpc } from '@main/ipc/register'
import { applyResolvedPath, preflightPty } from '@main/util/environment'
import { sendToRenderer } from '@main/util/renderer'
import { startRelayServer, type RelayServer } from '@main/relay/server'
import { prepareIsolatedCodexHome } from '@main/agents/codexHome'
import { installShim } from '@main/relay/shim'
import { relayDepsFor } from '@main/relay/deps'

// Dev and packaged installs must never share a record. The dev checkout
// migrates the schema ahead of any frozen .dmg — whose downgrade guard would
// then refuse to start — and two instances over one database would each mark
// the other's live runs interrupted at boot. Set before ANY userData read:
// databasePath below computes at module load.
if (!app.isPackaged) {
  app.setPath('userData', join(app.getPath('appData'), 'parley-dev'))
}

let mainWindow: BrowserWindow | null = null
let relay: RelayServer | null = null
let ptyOutput: PtyOutputBatcher | null = null
let pty: PtyManager | null = null
let rooms: RoomManager | null = null
let health: CliHealth[] = []

const databasePath = join(app.getPath('userData'), 'parley.db')

function send(channel: string, payload: unknown): void {
  // Guarding the WINDOW is not enough: its render frame can be disposed while
  // the window object is alive, and every PTY chunk then throws. See
  // sendToRenderer, which owns that distinction and the race behind it.
  if (!mainWindow || mainWindow.isDestroyed()) return
  sendToRenderer(mainWindow.webContents, channel, payload)
}

const emit = (event: AppEvent): void => send(CH.event, event)

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 940,
    minWidth: 1040,
    minHeight: 680,
    show: false,
    // Traffic lights inset into the app's own toolbar — the standard shape for
    // a macOS developer tool, and it buys back the height a title bar costs.
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 18, y: 20 },
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#191919' : '#f6f6f7',
    webPreferences: {
      preload: join(import.meta.dirname, '../preload/index.mjs'),
      // The renderer gets no Node, no remote module, and its own process.
      // Everything privileged goes through the validated invoke channel.
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false, // required so the preload can use contextBridge with ESM
      webSecurity: true,
      spellcheck: false,
    },
  })

  mainWindow.once('ready-to-show', () => mainWindow?.show())

  // Any attempt to navigate away, or to open a window, leaves the app entirely
  // and goes to the user's browser. A renderer that can navigate is a renderer
  // that can be steered somewhere unexpected by content it renders.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })
  mainWindow.webContents.on('will-navigate', (event, url) => {
    const isDevServer = process.env['ELECTRON_RENDERER_URL'] && url.startsWith(process.env['ELECTRON_RENDERER_URL'])
    if (!isDevServer) {
      event.preventDefault()
      void shell.openExternal(url)
    }
  })

  /**
   * Why the window went black.
   *
   * Without this, a renderer that Chromium killed left no trace in the app at
   * all — only PTY output failing to reach a frame that no longer existed,
   * which reads as an IPC bug and is not one. Working out that it was an
   * out-of-memory kill took reading macOS crash reports and symbolicating a
   * stripped Electron binary. The reason is one line away and worth having.
   */
  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    // eslint-disable-next-line no-console
    console.error(
      `Parley: the window's renderer died (${details.reason}, exit ${details.exitCode}).`,
      details.reason === 'oom'
        ? 'Out of memory — the terminal panes outgrew the renderer.'
        : 'Reopen the window to carry on; the panes are still running.',
    )
  })

  mainWindow.on('closed', () => {
    mainWindow = null
  })

  const devUrl = process.env['ELECTRON_RENDERER_URL']
  if (devUrl) void mainWindow.loadURL(devUrl)
  else void mainWindow.loadFile(join(import.meta.dirname, '../renderer/index.html'))
}

async function bootstrap(): Promise<void> {
  // Before anything spawns. A GUI-launched macOS app inherits launchd's minimal
  // PATH, not the user's, so `claude` and `codex` would be unfindable even
  // though they work fine in Terminal.
  const pathResolution = await applyResolvedPath()

  const repo = new Repo(openDatabase(databasePath))

  // A room nobody ever spoke in is not a record of anything. One that was
  // used always survives, closed or not.
  repo.reconcileRooms()

  const registry = new AgentRegistry()

  // One message per frame, not one per chunk. Three agent TUIs redrawing put
  // the renderer permanently behind and Chromium killed it at ~15 GB; the
  // black window and the "Render frame was disposed" spam were both downstream
  // of that.
  ptyOutput = new PtyOutputBatcher((paneId, data) => send(CH.ptyData, { paneId, data } satisfies PtyChunk))

  pty = new PtyManager({
    // Terminal output bypasses the validated event channel: a busy pane emits
    // thousands of chunks a second and schema-parsing each one would dominate
    // the frame budget for no safety gain — it is opaque bytes either way.
    onData: (paneId, data) => ptyOutput?.push(paneId, data),
    onCreated: (pane) => emit({ type: 'pane.created', pane }),
    onClosed: (paneId) => {
      ptyOutput?.forget(paneId)
      emit({ type: 'pane.closed', paneId })
    },
    onStatus: (paneId, status, exitCode) => emit({ type: 'pane.status', paneId, status, exitCode }),
  })

  // The door an agent in a pane knocks on to reach a neighbour. Loopback, a
  // token minted this run, and a paste that is never submitted — a person in
  // the target pane still presses Enter. Started after the pty manager because
  // it reads the pane list from it, and its environment reaches panes through
  // setPaneEnv, which is why panes may only open afterwards.
  // A Codex configuration with no MCP servers, for governed seats only. Panes
  // keep the user's own configuration; see codexHome.ts.
  const codexHome = prepareIsolatedCodexHome(join(app.getPath('userData'), 'codex-home'))
  process.env['PARLEY_CODEX_HOME'] = codexHome.path
  if (!codexHome.authLinked) {
    // Not fatal, and not silent. A seat will report that it cannot sign in,
    // and this says why before it does.
    console.warn('parley: no Codex credentials found — codex seats will not authenticate')
  }

  const binDir = installShim(app.getPath('userData'))
  const livePty = pty
  relay = await startRelayServer(relayDepsFor({
    list: () => livePty.list(),
    get: (id) => livePty.get(id),
    // pasteOnly, never paste: a person in the target pane presses Enter.
    pasteOnly: (paneId, text) => livePty.pasteOnly(paneId, text),
  }))
  pty.setPaneEnv({
    PARLEY_RELAY_URL: relay.url,
    PARLEY_RELAY_TOKEN: relay.token,
    PATH: `${binDir}:${process.env['PATH'] ?? ''}`,
  })

  // The manager holds the live half — which seats are mid-turn, which vendor
  // thread each resumes on. Everything durable is written through to the
  // record as it happens.
  rooms = new RoomManager({ registry, repo, emit })

  registerIpc({
    repo,
    registry,
    pty,
    rooms,
    emit,
    window: () => mainWindow,
    health: () => health,
    agyModels: () => registry.agyModels(),
  })

  createWindow()

  // Report a broken pty layer once, at startup, rather than letting the user
  // discover it as three identical failures when they try to open panes.
  const ptyCheck = preflightPty()
  if (!ptyCheck.ok) {
    // Wait for the renderer, or the notice lands before anyone can see it.
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({ type: 'notice', level: 'error', message: ptyCheck.detail })
    })
  }

  if (pathResolution.source === 'inherited' && process.platform === 'darwin') {
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({
        type: 'notice',
        level: 'warn',
        message:
          'Could not read your login shell PATH, so Parley is using the minimal one macOS gives GUI apps. If the CLIs are reported missing, launch Parley from Terminal instead.',
      })
    })
  }

  // Probing spends a few tokens per CLI, so it happens once in the background
  // rather than blocking the window.
  void registry
    .probeAll()
    .then((result) => {
      health = result
      const missing = result.filter((h) => !h.present)
      const unauthenticated = result.filter((h) => h.present && !h.authenticated)
      for (const h of missing) {
        emit({ type: 'notice', level: 'warn', message: `${h.vendor}: ${h.detail}` })
      }
      for (const h of unauthenticated) {
        emit({ type: 'notice', level: 'warn', message: `${h.vendor}: ${h.detail}` })
      }
    })
    .catch(() => {
      /* A failed probe is not fatal; the UI shows unknown status. */
    })
}

app.whenReady().then(bootstrap).catch((err: unknown) => {
  // eslint-disable-next-line no-console
  console.error('failed to start Parley:', err)
  app.quit()
})

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  // Kill every child process explicitly. Orphaned CLI runs would keep consuming
  // the user's subscription quota after the app they belong to has gone.
  relay?.close()
  ptyOutput?.dispose()
  pty?.disposeAll()
  // Abandon every in-flight seat: an orphaned CLI turn keeps consuming the
  // user's subscription quota after the room it belongs to is gone.
  rooms?.disposeAll()
  disposeIpc()
})
