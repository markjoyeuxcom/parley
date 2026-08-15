import { join } from 'node:path'
import { app, BrowserWindow, nativeTheme, Notification, powerSaveBlocker, shell } from 'electron'
import type { AppEvent, PtyChunk } from '@shared/events'
import { CH, type CliHealth } from '@shared/ipc'
import { AgentRegistry } from '@main/agents'
import { openDatabase } from '@main/store/db'
import { Repo } from '@main/store/repo'
import { Manager } from '@main/orchestrator/manager'
import { backfillBacklog } from '@main/orchestrator/backlog'
import { reconcileWorktrees } from '@main/orchestrator/worktrees'
import { PtyManager } from '@main/pty/manager'
import { RoomManager } from '@main/rooms/manager'
import { PreviewManager } from '@main/preview/manager'
import { disposeIpc, registerIpc } from '@main/ipc/register'
import { applyFreshBuildFlag } from '@main/ipc/relaunch'
import { applyResolvedPath, preflightPty } from '@main/util/environment'

const freshBuild = applyFreshBuildFlag(process.argv, process.env)

// Dev and packaged installs must never share a record. The dev checkout
// migrates the schema ahead of any frozen .dmg — whose downgrade guard would
// then refuse to start — and two instances over one database would each mark
// the other's live runs interrupted at boot. Set before ANY userData read:
// databasePath below computes at module load.
if (!app.isPackaged) {
  app.setPath('userData', join(app.getPath('appData'), 'parley-dev'))
}

let mainWindow: BrowserWindow | null = null
let pty: PtyManager | null = null
let rooms: RoomManager | null = null
let preview: PreviewManager | null = null
let manager: Manager | null = null
let health: CliHealth[] = []

const databasePath = join(app.getPath('userData'), 'parley.db')

function send(channel: string, payload: unknown): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload)
  }
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

  // Resolve anything the last shutdown left mid-flight, before the UI can show
  // it as still running. Runners live only in memory, so a row claiming to be
  // "executing" after a restart has nothing behind it.
  const stranded = repo.reconcileInterrupted()
  const strandedTotal =
    stranded.sessions + stranded.loops + stranded.plans + stranded.milestones
  // Foreman attempts the last shutdown left `running` become recorded
  // failures; the pending proposal they never superseded stays as it was.
  repo.reconcileForemanAttempts()
  repo.reconcileSelfUpdates()
  repo.reconcileEnvelopes()
  // A run marked in-flight belongs to a process that is gone. Unlike an
  // interrupted local run, the work may be sitting finished on a host.
  repo.reconcileRemoteRuns()
  repo.reconcileWorkspaces()

  const registry = new AgentRegistry()

  manager = new Manager({
    repo,
    registry,
    emit,
    worktreesRoot: join(app.getPath('userData'), 'worktrees'),
    // Dev only: the checkout this process was built from is the repository
    // Parley must treat as itself (worktree-only plans, the self-update gate).
    // Packaged, getAppPath is inside the asar — not a repo — so null keeps
    // every self rule dormant.
    selfRepoPath: app.isPackaged ? null : app.getAppPath(),
    // The same call, kept apart on purpose: packaged, this is inside the
    // asar and is still exactly where the shipped remote runner is found
    // (beside it, in app.asar.unpacked). selfRepoPath must stay null there;
    // this must not.
    appPath: app.getAppPath(),
    userDataPath: app.getPath('userData'),
    // One native banner per newly-appearing hold — the push half of the
    // attention queue. Supplementary by design: the stamp is written either
    // way, and the durable surface is the holds list itself, so a denied
    // notification permission degrades to the in-app badge, silently.
    notifyUser: (title, body) => {
      if (Notification.isSupported()) new Notification({ title, body }).show()
    },
    // 'prevent-app-suspension' defers IDLE sleep so an overnight run is not
    // stranded mid-milestone. It cannot defeat a closed lid — the docs say so
    // and so do we, everywhere the user is offered an unattended run.
    keepAwake: () => {
      const id = powerSaveBlocker.start('prevent-app-suspension')
      return () => {
        if (powerSaveBlocker.isStarted(id)) powerSaveBlocker.stop(id)
      }
    },
  })

  pty = new PtyManager({
    // Terminal output bypasses the validated event channel: a busy pane emits
    // thousands of chunks a second and schema-parsing each one would dominate
    // the frame budget for no safety gain — it is opaque bytes either way.
    onData: (paneId, data) => send(CH.ptyData, { paneId, data } satisfies PtyChunk),
    onCreated: (pane) => emit({ type: 'pane.created', pane }),
    onClosed: (paneId) => emit({ type: 'pane.closed', paneId }),
    onStatus: (paneId, status, exitCode) => emit({ type: 'pane.status', paneId, status, exitCode }),
  })

  preview = new PreviewManager({
    onChanged: (changed) => emit({ type: 'preview.changed', preview: changed }),
  })

  // Rooms hold no record yet (m4), so they are pure process state like the
  // pane registry — and like it, they die with the app rather than surviving
  // as rows claiming a conversation that has nothing behind it.
  rooms = new RoomManager({ registry, emit })

  registerIpc({
    manager,
    pty,
    rooms,
    preview,
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

  // The self-relaunch announces itself: without this line, a successful
  // update is indistinguishable from an ordinary restart, and the user has
  // no confirmation the bytes actually changed generation.
  if (freshBuild) {
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({
        type: 'notice',
        level: 'info',
        message: 'Running the freshly landed build from out/.',
      })
    })
  }

  // Replayable by construction (content-hash dedupe), so this both heals the
  // crash window between a verdict committing and its ingestion committing,
  // and deliberately back-ingests reviews completed before the backlog
  // existed — the surface opens populated from record. The count is only
  // announced when something genuinely new was filed.
  const backfilled = backfillBacklog(repo)
  if (backfilled.filed > 0) {
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({
        type: 'notice',
        level: 'info',
        message: `${backfilled.filed} backlog item${backfilled.filed > 1 ? 's were' : ' was'} filed from past review sessions.`,
      })
    })
  }

  // Same honesty pass for execution worktrees: a directory or origin that
  // vanished while the app was closed is flagged now, not discovered as a
  // silently disabled diff guard mid-run. Never deletes anything.
  void reconcileWorktrees(repo).then(({ orphaned }) => {
    if (orphaned === 0) return
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({
        type: 'notice',
        level: 'warn',
        message: `${orphaned} execution worktree${orphaned > 1 ? 's' : ''} lost ${orphaned > 1 ? 'their' : 'its'} directory or origin and ${orphaned > 1 ? 'were' : 'was'} marked orphaned. The branches survive.`,
      })
    })
  })

  if (strandedTotal > 0) {
    const parts: string[] = []
    if (stranded.milestones) parts.push(`${stranded.milestones} milestone${stranded.milestones > 1 ? 's' : ''}`)
    if (stranded.sessions) parts.push(`${stranded.sessions} session${stranded.sessions > 1 ? 's' : ''}`)
    if (stranded.loops) parts.push(`${stranded.loops} loop${stranded.loops > 1 ? 's' : ''}`)
    mainWindow?.webContents.once('did-finish-load', () => {
      emit({
        type: 'notice',
        level: 'warn',
        message: `${parts.join(', ')} were still running when Parley last quit and have been marked interrupted. They can be retried.`,
      })
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
  pty?.disposeAll()
  // Abandon every in-flight seat: an orphaned CLI turn keeps consuming the
  // user's subscription quota after the room it belongs to is gone.
  rooms?.disposeAll()
  // Before the manager: an orphaned dev server holds its port and cannot be
  // stopped from anywhere the user can see.
  preview?.disposeAll()
  manager?.disposeAll()
  disposeIpc()
})
