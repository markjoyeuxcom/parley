const childProcess = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const vscode = require('vscode')

const {
  ContextBasket,
  attentionRows,
  workspaceRows,
} = require('./companion-model.cjs')

const {
  assertCompatibleCapabilities,
  assertLocalDesktopRuntime,
  buildManifest,
  buildSelectionItems,
  consumeAcknowledgement,
  formatDiagnostics,
  parleyFocusURL,
  readAttentionSnapshot,
  readBridgeCapabilities,
  relativeWorkspaceFile,
  stageManifest,
} = require('./contracts.cjs')

const PARLEY_BUNDLE_IDENTIFIER = 'com.markjoyeux.parley'
const OPEN_EXECUTABLE = '/usr/bin/open'
const CAPABILITY_STARTUP_TIMEOUT_MS = 12_000
const POLL_INTERVAL_MS = 150

function activate(context) {
  const output = vscode.window.createOutputChannel('Parley')
  context.subscriptions.push(output)

  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10)
  status.name = 'Parley Attention'
  status.command = 'parley.showAttention'
  status.show()
  context.subscriptions.push(status)

  const basket = new ContextBasket()
  const attentionProvider = new AttentionTreeProvider()
  const workspaceProvider = new WorkspaceTreeProvider()
  const basketProvider = new BasketTreeProvider(basket)
  const attentionView = vscode.window.createTreeView('parley.attention', {
    treeDataProvider: attentionProvider,
  })
  const workspaceView = vscode.window.createTreeView('parley.workspaces', {
    treeDataProvider: workspaceProvider,
    showCollapseAll: true,
  })
  const basketView = vscode.window.createTreeView('parley.contextBasket', {
    treeDataProvider: basketProvider,
    showCollapseAll: true,
  })
  context.subscriptions.push(
    attentionProvider,
    workspaceProvider,
    basketProvider,
    attentionView,
    workspaceView,
    basketView,
  )

  const refreshBasket = () => {
    basketProvider.refresh()
    void vscode.commands.executeCommand('setContext', 'parley.contextBasketHasItems', basket.count > 0)
  }

  const legacy = (preferred) => (...args) => buildContextPack(args[0], args[1], { preferred })
  const commands = {
    'parley.openWorkspace': openWorkspace,
    'parley.showAttention': showAttention,
    'parley.buildContextPack': buildContextPack,
    'parley.buildWorkingTreeContext': (...args) => buildSCMContext('gitWorkingDiff', ...args),
    'parley.buildStagedContext': (...args) => buildSCMContext('gitStagedDiff', ...args),
    'parley.diagnoseCompanion': () => diagnoseCompanion(output),
    'parley.openCollaboration': () => vscode.commands.executeCommand('workbench.view.extension.parley'),
    'parley.openApplication': () => openInParley(),
    'parley.refreshCollaboration': () => refreshCollaboration(),
    'parley.focusPane': (item) => focusPane(item),
    'parley.openHandoff': (item) => openHandoff(item),
    'parley.addSelectionToBasket': () => addSelectionToBasket(basket, refreshBasket),
    'parley.addFilesToBasket': (resource, selectedResources) => addFilesToBasket(
      basket,
      refreshBasket,
      resource,
      selectedResources,
    ),
    'parley.addDiagnosticsToBasket': () => addDiagnosticsToBasket(basket, refreshBasket),
    'parley.addWorkingChangeToBasket': (...args) => addSCMToBasket(
      basket,
      refreshBasket,
      'gitWorkingDiff',
      ...args,
    ),
    'parley.addStagedChangeToBasket': (...args) => addSCMToBasket(
      basket,
      refreshBasket,
      'gitStagedDiff',
      ...args,
    ),
    'parley.reviewContextBasket': () => reviewContextBasket(basket, refreshBasket),
    'parley.clearContextBasket': () => clearContextBasket(basket, refreshBasket),
    'parley.removeContextBasketItem': (item) => removeContextBasketItem(
      basket,
      refreshBasket,
      item,
    ),
    // Existing keybindings remain valid, but every route now opens the same
    // source composer instead of maintaining separate staging workflows.
    'parley.stageSelection': legacy('selections'),
    'parley.stageCurrentFile': legacy('currentFile'),
    'parley.stageDiagnostics': legacy('diagnostics'),
    'parley.stageGitDiff': legacy('gitDiff'),
    'parley.stageSelectionAndGitDiff': legacy('selectionsAndGit'),
  }
  for (const [name, handler] of Object.entries(commands)) {
    context.subscriptions.push(vscode.commands.registerCommand(name, (...args) => reportErrors(() => handler(...args))))
  }

  const refreshCollaboration = () => {
    const state = collaborationState()
    refreshAttentionStatus(status, state)
    attentionProvider.update(state.snapshot)
    workspaceProvider.update(state.snapshot)
    attentionView.message = state.snapshot
      ? (state.snapshot.items.length === 0 ? 'No current attention items.' : undefined)
      : 'Open the installed Production app to publish current attention.'
    workspaceView.message = state.snapshot
      ? (state.snapshot.workspaces.length === 0 ? 'No Production workspaces are currently published.' : undefined)
      : 'Open the installed Production app to publish workspaces and live panes.'
    void vscode.commands.executeCommand('setContext', 'parley.connected', Boolean(state.snapshot))
  }
  refreshBasket()
  refreshCollaboration()
  const timer = setInterval(refreshCollaboration, 5_000)
  timer.unref()
  context.subscriptions.push({ dispose: () => clearInterval(timer) })
}

async function showAttention() {
  assertSupportedRuntime()
  const snapshot = currentAttentionSnapshot()
  if (!snapshot) {
    throw new Error('The installed Production app is not publishing current status. Open or update Parley, then try again.')
  }
  const choices = []
  if (snapshot.items.length > 0) {
    choices.push({ label: 'Needs attention', kind: vscode.QuickPickItemKind.Separator })
    choices.push(...snapshot.items.map((item) => ({
      label: item.label,
      description: item.workspaceName,
      detail: attentionReason(item.reason),
      route: { handoffID: item.handoffID },
    })))
  }
  if (snapshot.panes.length > 0) {
    choices.push({ label: 'Live agent panes', kind: vscode.QuickPickItemKind.Separator })
    choices.push(...snapshot.panes.map((pane) => ({
      label: pane.name,
      description: pane.kind,
      detail: pane.workspaceName,
      route: { paneID: pane.id },
    })))
  }
  if (choices.every((choice) => choice.kind === vscode.QuickPickItemKind.Separator)) {
    void vscode.window.showInformationMessage('Parley has no attention items or live agent panes to focus.')
    return
  }
  const selected = await vscode.window.showQuickPick(choices, {
    placeHolder: 'Open an authoritative Parley record or focus a live agent pane',
    matchOnDescription: true,
    matchOnDetail: true,
  })
  if (!selected?.route) return
  await openInParley(parleyFocusURL(selected.route))
}

function collaborationState() {
  try {
    assertSupportedRuntime()
    return { snapshot: currentAttentionSnapshot(), error: undefined }
  } catch (error) {
    return { snapshot: null, error }
  }
}

function refreshAttentionStatus(status, state = collaborationState()) {
  const { snapshot, error } = state
  if (!snapshot) {
    status.text = '$(comment-discussion) Parley'
    status.tooltip = error instanceof Error
      ? error.message
      : 'Open the installed Production app to expose current local attention counts.'
    return
  }
  status.text = snapshot.attentionCount > 0
    ? `$(bell-dot) Parley ${snapshot.attentionCount}`
    : '$(pass) Parley'
  const workspaceCounts = snapshot.workspaces
    .filter((workspace) => workspace.attentionCount > 0)
    .map((workspace) => `${workspace.name}: ${workspace.attentionCount}`)
  status.tooltip = workspaceCounts.length > 0
    ? `Parley needs attention — ${workspaceCounts.join(' · ')}`
    : `${snapshot.panes.length} live Parley agent pane${snapshot.panes.length === 1 ? '' : 's'} · no recorded attention`
}

function currentAttentionSnapshot() {
  return readAttentionSnapshot({ home: os.homedir(), now: new Date() })
}

function attentionReason(reason) {
  switch (reason) {
  case 'returnedResult': return 'Returned result — opens the Status Center record'
  case 'humanInputRequired': return 'Human input required — opens the Status Center record'
  case 'interrupted': return 'Interrupted handoff — opens the Status Center record'
  default: return 'Open the Status Center record'
  }
}

async function focusPane(item) {
  const paneID = item?.paneID || item?.id
  await openInParley(parleyFocusURL({ paneID }))
}

async function openHandoff(item) {
  const handoffID = item?.handoffID || item?.id
  await openInParley(parleyFocusURL({ handoffID }))
}

async function openWorkspace(resource) {
  assertSupportedRuntime()
  const folder = await chooseWorkspaceFolder(resource)
  await openInParley(folder.uri.fsPath)
  void vscode.window.showInformationMessage(`Asked Parley to open ${folder.name}. No agent was started.`)
}

async function buildContextPack(resource, selectedResources, options = {}) {
  assertSupportedRuntime()
  const folder = await chooseWorkspaceFolder(resource)
  const candidates = await collectContextCandidates({ folder, resource, selectedResources })
  applyPreferredCandidates(candidates, options.preferred)
  const selected = await chooseContextCandidates(candidates)
  if (!selected) return
  await saveSelectedFiles(selected, folder.uri.fsPath)
  await stageAndOpen(folder.uri.fsPath, selected.flatMap((candidate) => candidate.items))
}

async function buildSCMContext(kind, resource, ...additionalResources) {
  assertSupportedRuntime()
  const uris = scmResourceURIs([resource, ...additionalResources])
  if (uris.length === 0) throw new Error('Choose one or more local Git changes first.')
  const folder = await chooseWorkspaceFolder(uris[0])
  const items = uris.map((uri) => ({
    kind,
    file: relativePossiblyMissingFile(folder.uri.fsPath, uri),
  }))
  const label = kind === 'gitStagedDiff' ? 'Selected staged changes' : 'Selected working-tree changes'
  const candidates = await collectContextCandidates({ folder })
  candidates.unshift(contextCandidate({
    id: `${kind}:selection`,
    label,
    description: `${items.length} explicit Git path${items.length === 1 ? '' : 's'}`,
    detail: 'Parley recaptures each diff with a fixed Git pathspec.',
    items,
    picked: true,
    recaptured: true,
  }))
  const selected = await chooseContextCandidates(candidates)
  if (!selected) return
  await saveSelectedFiles(selected, folder.uri.fsPath)
  await stageAndOpen(folder.uri.fsPath, selected.flatMap((candidate) => candidate.items))
}

async function addSelectionToBasket(basket, refreshBasket) {
  assertSupportedRuntime()
  const editor = vscode.window.activeTextEditor
  if (editor?.document.uri.scheme !== 'file') {
    throw new Error('Open a local file and select explicit text first.')
  }
  const folder = await chooseWorkspaceFolder(editor.document.uri)
  const relativeFile = relativeFileInFolder(folder.uri.fsPath, editor.document.uri)
  const items = buildSelectionItems(relativeFile, editor.selections.map((selection) => ({
    startLine: selection.start.line + 1,
    endLine: selection.end.line + 1,
    text: editor.document.getText(selection),
  })))
  if (items.length === 0) throw new Error('Select non-empty editor text first.')
  addBasketItems(basket, refreshBasket, folder.uri.fsPath, items)
}

async function addFilesToBasket(basket, refreshBasket, resource, selectedResources) {
  assertSupportedRuntime()
  const fallback = resource
    ? undefined
    : vscode.window.activeTextEditor?.document.uri
  const uris = explicitFileURIs([resource, selectedResources, fallback])
  if (uris.length === 0) throw new Error('Choose one or more local files first.')
  const folder = await chooseWorkspaceFolder(uris[0])
  const items = uris.map((uri) => {
    if (!uriIsInFolder(folder.uri.fsPath, uri)) {
      throw new Error('Every selected file must be inside the chosen workspace folder.')
    }
    return { kind: 'currentFile', file: relativeFileInFolder(folder.uri.fsPath, uri) }
  })
  addBasketItems(basket, refreshBasket, folder.uri.fsPath, items)
}

async function addDiagnosticsToBasket(basket, refreshBasket) {
  assertSupportedRuntime()
  const editor = vscode.window.activeTextEditor
  if (editor?.document.uri.scheme !== 'file') {
    throw new Error('Open a local file with diagnostics first.')
  }
  const folder = await chooseWorkspaceFolder(editor.document.uri)
  const relativeFile = relativeFileInFolder(folder.uri.fsPath, editor.document.uri)
  const item = diagnosticsItem(editor.document.uri, relativeFile)
  if (!item) throw new Error('There are no diagnostics for the current file.')
  addBasketItems(basket, refreshBasket, folder.uri.fsPath, [item])
}

async function addSCMToBasket(basket, refreshBasket, kind, resource, ...additionalResources) {
  assertSupportedRuntime()
  const uris = scmResourceURIs([resource, ...additionalResources])
  if (uris.length === 0) throw new Error('Choose one or more local Git changes first.')
  const folder = await chooseWorkspaceFolder(uris[0])
  const items = uris.map((uri) => ({
    kind,
    file: relativePossiblyMissingFile(folder.uri.fsPath, uri),
  }))
  addBasketItems(basket, refreshBasket, folder.uri.fsPath, items)
}

function addBasketItems(basket, refreshBasket, folder, items) {
  const result = basket.add(folder, items)
  refreshBasket()
  const changes = []
  if (result.added > 0) changes.push(`${result.added} added`)
  if (result.updated > 0) changes.push(`${result.updated} refreshed`)
  void vscode.window.showInformationMessage(
    `Parley Context Basket: ${changes.join(', ') || 'no changes'}; ${result.total} explicit source${result.total === 1 ? '' : 's'}. Nothing was sent.`,
  )
}

async function reviewContextBasket(basket, refreshBasket) {
  assertSupportedRuntime()
  const folder = await chooseBasketFolder(basket, 'Choose a Context Basket to review in Parley')
  if (!folder) return
  const entries = basket.entries(folder)
  await saveSelectedFiles([{ items: entries.map((entry) => entry.item) }], folder)
  const acknowledgement = await stageAndOpen(folder, entries.map((entry) => entry.item))
  basket.accept(folder, acknowledgement, entries)
  refreshBasket()
}

async function clearContextBasket(basket, refreshBasket) {
  const folder = await chooseBasketFolder(basket, 'Choose a Context Basket to clear')
  if (!folder) return
  const count = basket.entries(folder).length
  const action = await vscode.window.showWarningMessage(
    `Clear ${count} explicit context source${count === 1 ? '' : 's'} from ${path.basename(folder) || folder}?`,
    { modal: true },
    'Clear Basket',
  )
  if (action !== 'Clear Basket') return
  basket.clear(folder)
  refreshBasket()
}

function removeContextBasketItem(basket, refreshBasket, item) {
  if (!item?.entryID || !basket.remove(item.entryID)) {
    throw new Error('That context source is no longer in the basket.')
  }
  refreshBasket()
}

async function chooseBasketFolder(basket, placeHolder) {
  const folders = basket.folders()
  if (folders.length === 0) throw new Error('The Parley Context Basket is empty.')
  if (folders.length === 1) return folders[0]
  const selected = await vscode.window.showQuickPick(
    folders.map((folder) => ({
      label: path.basename(folder) || folder,
      description: folder,
      detail: `${basket.entries(folder).length} explicit source${basket.entries(folder).length === 1 ? '' : 's'}`,
      folder,
    })),
    { placeHolder, matchOnDescription: true },
  )
  return selected?.folder
}

async function collectContextCandidates({ folder, resource, selectedResources }) {
  const candidates = []
  const canonicalFolder = folder.uri.fsPath
  const editor = vscode.window.activeTextEditor
  if (editor?.document.uri.scheme === 'file' && uriIsInFolder(canonicalFolder, editor.document.uri)) {
    const relativeFile = relativeFileInFolder(canonicalFolder, editor.document.uri)
    const selections = buildSelectionItems(relativeFile, editor.selections.map((selection) => ({
      startLine: selection.start.line + 1,
      endLine: selection.end.line + 1,
      text: editor.document.getText(selection),
    })))
    if (selections.length > 0) {
      candidates.push(contextCandidate({
        id: 'selections',
        label: selections.length === 1 ? 'Editor selection' : `All editor selections (${selections.length})`,
        description: relativeFile,
        detail: 'Exact text selected in VS Code; each selection remains separately attributed.',
        items: selections,
        picked: true,
        estimatedBytes: selections.reduce((total, item) => total + Buffer.byteLength(item.text, 'utf8'), 0),
      }))
    }
    candidates.push(fileCandidate(canonicalFolder, editor.document.uri, 'currentFile', selections.length === 0))
    const diagnostics = diagnosticsItem(editor.document.uri, relativeFile)
    if (diagnostics) {
      candidates.push(contextCandidate({
        id: 'diagnostics',
        label: 'Current file diagnostics',
        description: relativeFile,
        detail: 'Messages and locations supplied by VS Code; nothing is inferred from terminal text.',
        items: [diagnostics],
        estimatedBytes: Buffer.byteLength(diagnostics.text, 'utf8'),
      }))
    }
  }

  const explorerURIs = explicitFileURIs([resource, selectedResources])
  for (const uri of explorerURIs) {
    if (!uriIsInFolder(canonicalFolder, uri)) {
      throw new Error('Every selected Explorer file must be inside the chosen workspace folder.')
    }
    const candidate = fileCandidate(canonicalFolder, uri, 'explorer', true)
    if (!candidates.some((existing) => existing.items[0]?.kind === 'currentFile' && existing.items[0]?.file === candidate.items[0].file)) {
      candidates.push(candidate)
    }
  }

  candidates.push(
    contextCandidate({
      id: 'gitDiff',
      label: 'All Git changes',
      description: 'staged + working tree',
      detail: 'Parley recaptures status and both diff surfaces from disk.',
      items: [{ kind: 'gitDiff' }],
      recaptured: true,
    }),
    contextCandidate({
      id: 'gitStagedDiff',
      label: 'Staged Git changes',
      description: 'index only',
      detail: 'Parley recaptures only the staged diff.',
      items: [{ kind: 'gitStagedDiff' }],
      recaptured: true,
    }),
    contextCandidate({
      id: 'gitWorkingDiff',
      label: 'Working-tree Git changes',
      description: 'unstaged + untracked names',
      detail: 'Parley recaptures the working diff; untracked content is not read implicitly.',
      items: [{ kind: 'gitWorkingDiff' }],
      recaptured: true,
    }),
  )
  return candidates
}

function contextCandidate(candidate) {
  return { picked: false, estimatedBytes: 0, recaptured: false, ...candidate }
}

function fileCandidate(folder, uri, source, picked) {
  const relativeFile = relativeFileInFolder(folder, uri)
  const size = fs.statSync(uri.fsPath).size
  return contextCandidate({
    id: source === 'currentFile' ? 'currentFile' : `file:${relativeFile}`,
    label: path.basename(relativeFile),
    description: relativeFile,
    detail: 'Parley recaptures the saved UTF-8 file from disk.',
    items: [{ kind: 'currentFile', file: relativeFile }],
    picked,
    estimatedBytes: size,
    fileURI: uri,
    source,
  })
}

function diagnosticsItem(uri, relativeFile) {
  const diagnostics = vscode.languages.getDiagnostics(uri).map((diagnostic) => ({
    severity: severityName(diagnostic.severity),
    line: diagnostic.range.start.line + 1,
    column: diagnostic.range.start.character + 1,
    message: diagnostic.message,
    source: diagnostic.source,
    code: typeof diagnostic.code === 'object' ? diagnostic.code?.value : diagnostic.code,
  }))
  if (diagnostics.length === 0) return null
  return { kind: 'diagnostics', file: relativeFile, text: formatDiagnostics(relativeFile, diagnostics) }
}

function applyPreferredCandidates(candidates, preferred) {
  if (!preferred) return
  for (const candidate of candidates) candidate.picked = false
  const ids = preferredCandidateIDs(preferred)
  for (const candidate of candidates) candidate.picked = ids.has(candidate.id)
}

function preferredCandidateIDs(preferred) {
  switch (preferred) {
  case 'selections': return new Set(['selections'])
  case 'currentFile': return new Set(['currentFile'])
  case 'diagnostics': return new Set(['diagnostics'])
  case 'gitDiff': return new Set(['gitDiff'])
  case 'selectionsAndGit': return new Set(['selections', 'gitDiff'])
  default: return new Set()
  }
}

function chooseContextCandidates(candidates) {
  return new Promise((resolve) => {
    const quickPick = vscode.window.createQuickPick()
    quickPick.title = 'Build Context Pack'
    quickPick.placeholder = 'Choose explicit sources; Parley opens an editable preview and sends nothing.'
    quickPick.canSelectMany = true
    quickPick.matchOnDescription = true
    quickPick.matchOnDetail = true
    quickPick.items = candidates
    quickPick.selectedItems = candidates.filter((candidate) => candidate.picked)

    const updateSummary = (selection) => {
      const sourceCount = selection.reduce((total, candidate) => total + candidate.items.length, 0)
      const estimatedBytes = selection.reduce((total, candidate) => total + candidate.estimatedBytes, 0)
      const recaptured = selection.some((candidate) => candidate.recaptured)
      quickPick.title = `Build Context Pack — ${sourceCount} source${sourceCount === 1 ? '' : 's'} · ${formatBytes(estimatedBytes)}${recaptured ? ' + Git recapture' : ''}`
    }
    updateSummary(quickPick.selectedItems)
    const selectionSubscription = quickPick.onDidChangeSelection(updateSummary)
    const acceptSubscription = quickPick.onDidAccept(() => {
      const selected = [...quickPick.selectedItems]
      if (selected.reduce((total, candidate) => total + candidate.items.length, 0) === 0) {
        void vscode.window.showWarningMessage('Choose at least one explicit source for the Parley preview.')
        return
      }
      resolve(selected)
      quickPick.hide()
    })
    const hideSubscription = quickPick.onDidHide(() => {
      selectionSubscription.dispose()
      acceptSubscription.dispose()
      hideSubscription.dispose()
      quickPick.dispose()
      resolve(undefined)
    })
    quickPick.show()
  })
}

async function saveSelectedFiles(selected, folder) {
  const canonicalFolder = fs.realpathSync(folder)
  const selectedFiles = new Set(
    selected.flatMap((candidate) => candidate.items)
      .filter((item) => item.kind === 'currentFile')
      .map((item) => item.file),
  )
  const dirty = vscode.workspace.textDocuments.filter((document) => {
    if (!document.isDirty || document.uri.scheme !== 'file') return false
    try {
      const source = localDocumentSource(document.uri)
      return source.folder === canonicalFolder && selectedFiles.has(source.relativeFile)
    } catch {
      return false
    }
  })
  if (dirty.length === 0) return
  const action = await vscode.window.showWarningMessage(
    `Parley recaptures saved files from disk. ${dirty.length} selected file${dirty.length === 1 ? ' has' : 's have'} unsaved changes.`,
    { modal: true },
    'Save and Continue',
    'Use Saved Versions',
  )
  if (!action) throw new CompanionCancellation()
  if (action === 'Save and Continue') {
    const saved = await Promise.all(dirty.map((document) => document.save()))
    if (saved.some((result) => !result)) throw new Error('One selected file could not be saved.')
  }
}

async function stageAndOpen(folder, items) {
  const capabilities = await ensureBridgeCapabilities()
  assertCompatibleCapabilities(capabilities, items)
  const manifest = buildManifest(folder, items)
  const staged = stageManifest(manifest, { home: os.homedir(), randomUUID: crypto.randomUUID })
  scheduleRequestCleanup(staged, capabilities.contextImport.requestLifetimeSeconds)
  try {
    await openInParley(staged.file)
  } catch (error) {
    removeIfPresent(staged.file)
    throw error
  }

  const acknowledgement = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: 'Waiting for Parley to open the editable context preview…',
      cancellable: false,
    },
    () => waitForAcknowledgement(
      staged.requestID,
      capabilities.contextImport.requestLifetimeSeconds * 1_000,
    ),
  )
  removeIfPresent(staged.file)
  if (acknowledgement.state === 'accepted') {
    void vscode.window.showInformationMessage(
      `Parley accepted ${acknowledgement.sourceCount} explicit source${acknowledgement.sourceCount === 1 ? '' : 's'} into its editable preview. Nothing was sent.`,
    )
    return acknowledgement
  }
  if (acknowledgement.code === 'declinedReplacement') {
    throw new CompanionNotice(acknowledgement.message)
  }
  throw new Error(acknowledgement.message)
}

async function ensureBridgeCapabilities() {
  const existing = currentBridgeCapabilities()
  if (existing) return existing
  await openInParley()
  const deadline = Date.now() + CAPABILITY_STARTUP_TIMEOUT_MS
  let lastError
  while (Date.now() < deadline) {
    try {
      const capabilities = readBridgeCapabilities({ home: os.homedir(), now: new Date() })
      if (capabilities) return capabilities
    } catch (error) {
      lastError = error
    }
    await delay(POLL_INTERVAL_MS)
  }
  const detail = lastError instanceof Error ? ` ${lastError.message}` : ''
  throw new Error(`The installed Parley app did not publish a current compatible editor bridge.${detail} Update Parley and try again.`)
}

function currentBridgeCapabilities() {
  try {
    return readBridgeCapabilities({ home: os.homedir(), now: new Date() })
  } catch {
    return null
  }
}

async function waitForAcknowledgement(requestID, timeoutMs) {
  const deadline = Date.now() + Math.max(1_000, Math.min(timeoutMs, 300_000))
  while (Date.now() < deadline) {
    const acknowledgement = consumeAcknowledgement({ home: os.homedir(), requestID })
    if (acknowledgement) return acknowledgement
    await delay(POLL_INTERVAL_MS)
  }
  throw new Error('Parley did not confirm the context preview before the one-shot request expired. Check Parley for an open alert, then build the context pack again if needed.')
}

function scheduleRequestCleanup(staged, lifetimeSeconds) {
  const cleanup = setTimeout(() => {
    removeIfPresent(staged.file)
    removeIfPresent(staged.acknowledgementFile)
  }, Math.max(1, lifetimeSeconds + 10) * 1_000)
  cleanup.unref()
}

function removeIfPresent(file) {
  try { fs.rmSync(file, { force: true }) } catch {}
}

async function diagnoseCompanion(output) {
  output.clear()
  output.appendLine('Parley Companion Diagnostics')
  output.appendLine('')
  try {
    assertSupportedRuntime()
    output.appendLine('Runtime: local macOS desktop extension host')
  } catch (error) {
    output.appendLine(`Runtime: unavailable — ${error.message}`)
  }
  output.appendLine(`Installed app: ${fs.existsSync('/Applications/Parley.app') ? 'found in Applications' : 'not found in Applications'}`)
  try {
    const capabilities = readBridgeCapabilities({ home: os.homedir(), now: new Date() })
    if (!capabilities) {
      output.appendLine('Editor bridge: unavailable — open the Production app')
    } else {
      assertCompatibleCapabilities(capabilities, [])
      output.appendLine(`Editor bridge: compatible — import v${capabilities.contextImport.versions.join(', v')}, acknowledgement v${capabilities.contextImport.acknowledgementVersion}`)
      output.appendLine(`Context limits: ${capabilities.contextImport.maximumItems} sources, ${formatBytes(capabilities.contextImport.maximumManifestBytes)} manifest`)
    }
  } catch (error) {
    output.appendLine(`Editor bridge: unavailable — ${error.message}`)
  }
  try {
    const snapshot = currentAttentionSnapshot()
    output.appendLine(snapshot ? 'Attention heartbeat: current' : 'Attention heartbeat: unavailable')
  } catch (error) {
    output.appendLine(`Attention heartbeat: unavailable — ${error.message}`)
  }
  output.appendLine('Privacy: diagnostics omit workspace paths, source text, prompts, results, terminal output and credentials')
  output.show(true)
}

function assertSupportedRuntime() {
  assertLocalDesktopRuntime({
    platform: process.platform,
    remoteName: vscode.env.remoteName,
    web: vscode.env.uiKind === vscode.UIKind.Web,
  })
}

async function chooseWorkspaceFolder(resource) {
  const resourceURI = asFileURI(resource)
  const candidate = resourceURI
    ? vscode.workspace.getWorkspaceFolder(resourceURI)
    : vscode.window.activeTextEditor?.document.uri.scheme === 'file'
      ? vscode.workspace.getWorkspaceFolder(vscode.window.activeTextEditor.document.uri)
      : undefined
  if (candidate) return requireLocalFolder(candidate)
  const folders = vscode.workspace.workspaceFolders || []
  if (folders.length === 0) throw new Error('Open a local folder in VS Code first.')
  if (folders.length === 1) return requireLocalFolder(folders[0])
  const selected = await vscode.window.showQuickPick(
    folders.map((folder) => ({ label: folder.name, description: folder.uri.fsPath, folder })),
    { placeHolder: 'Choose the local workspace folder for this Parley context pack' },
  )
  if (!selected) throw new CompanionCancellation()
  return requireLocalFolder(selected.folder)
}

function requireLocalFolder(folder) {
  if (folder.uri.scheme !== 'file') throw new Error('Parley accepts local filesystem workspaces only.')
  const resolved = fs.realpathSync(folder.uri.fsPath)
  if (!fs.statSync(resolved).isDirectory()) throw new Error('The VS Code workspace folder is unavailable.')
  return { name: folder.name, index: folder.index, uri: vscode.Uri.file(resolved) }
}

function localDocumentSource(uri) {
  const folder = vscode.workspace.getWorkspaceFolder(uri)
  if (!folder || folder.uri.scheme !== 'file') throw new Error('The current file is not inside a local VS Code workspace.')
  const canonicalFolder = fs.realpathSync(folder.uri.fsPath)
  const canonicalFile = fs.realpathSync(uri.fsPath)
  return {
    folder: canonicalFolder,
    relativeFile: relativeWorkspaceFile(canonicalFolder, canonicalFile),
  }
}

function relativeFileInFolder(folder, uri) {
  if (uri?.scheme !== 'file') throw new Error('Parley accepts local files only.')
  const canonicalFile = fs.realpathSync(uri.fsPath)
  return relativeWorkspaceFile(folder, canonicalFile)
}

function relativePossiblyMissingFile(folder, uri) {
  if (uri?.scheme !== 'file') throw new Error('Parley accepts local files only.')
  const absolute = path.resolve(uri.fsPath)
  return relativeWorkspaceFile(folder, absolute)
}

function uriIsInFolder(folder, uri) {
  try {
    relativeFileInFolder(folder, uri)
    return true
  } catch {
    return false
  }
}

function explicitFileURIs(values) {
  const flattened = values.flat(Infinity)
  const seen = new Set()
  const uris = []
  for (const value of flattened) {
    const uri = asFileURI(value)
    if (!uri || seen.has(uri.fsPath)) continue
    let status
    try { status = fs.statSync(uri.fsPath) } catch { continue }
    if (!status.isFile()) continue
    seen.add(uri.fsPath)
    uris.push(uri)
  }
  return uris
}

function scmResourceURIs(values) {
  const flattened = values.flat(Infinity)
  const seen = new Set()
  const uris = []
  for (const value of flattened) {
    const uri = asFileURI(value?.resourceUri || value)
    if (!uri || seen.has(uri.fsPath)) continue
    seen.add(uri.fsPath)
    uris.push(uri)
  }
  return uris
}

function asFileURI(value) {
  if (value?.scheme === 'file' && typeof value.fsPath === 'string') return value
  if (value?.resourceUri?.scheme === 'file') return value.resourceUri
  return undefined
}

function severityName(severity) {
  switch (severity) {
  case vscode.DiagnosticSeverity.Error: return 'error'
  case vscode.DiagnosticSeverity.Warning: return 'warning'
  case vscode.DiagnosticSeverity.Information: return 'information'
  case vscode.DiagnosticSeverity.Hint: return 'hint'
  default: return 'unknown'
  }
}

function formatBytes(bytes) {
  if (bytes < 1_024) return `${bytes} B`
  if (bytes < 1_024 * 1_024) return `${Math.ceil(bytes / 1_024)} KB`
  return `${(bytes / (1_024 * 1_024)).toFixed(1)} MB`
}

function openInParley(target) {
  return new Promise((resolve, reject) => {
    const arguments = ['-b', PARLEY_BUNDLE_IDENTIFIER]
    if (target) arguments.push(target)
    childProcess.execFile(
      OPEN_EXECUTABLE,
      arguments,
      { timeout: 10_000, windowsHide: true },
      (error) => {
        if (error) {
          reject(new Error('The installed Parley app could not be opened. Install or update the Production app, then try again.'))
        } else {
          resolve()
        }
      },
    )
  })
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

async function reportErrors(operation) {
  try {
    await operation()
  } catch (error) {
    if (error instanceof CompanionCancellation) return
    const message = error instanceof Error ? error.message : String(error)
    if (error instanceof CompanionNotice) {
      void vscode.window.showInformationMessage(`Parley: ${message}`)
    } else {
      void vscode.window.showErrorMessage(`Parley: ${message}`)
    }
  }
}

class AttentionTreeProvider {
  constructor() {
    this.snapshot = null
    this.emitter = new vscode.EventEmitter()
    this.onDidChangeTreeData = this.emitter.event
  }

  update(snapshot) {
    this.snapshot = snapshot
    this.emitter.fire(undefined)
  }

  getChildren(element) {
    return element ? [] : attentionRows(this.snapshot)
  }

  getTreeItem(item) {
    const icon = item.reason === 'returnedResult'
      ? 'check'
      : item.reason === 'humanInputRequired' ? 'person' : 'warning'
    return {
      label: item.label,
      description: item.description,
      tooltip: attentionReason(item.reason),
      iconPath: new vscode.ThemeIcon(icon),
      collapsibleState: vscode.TreeItemCollapsibleState.None,
      contextValue: 'parleyAttention',
      command: {
        command: 'parley.openHandoff',
        title: 'Open Handoff in Parley',
        arguments: [{ handoffID: item.id }],
      },
      handoffID: item.id,
    }
  }

  dispose() { this.emitter.dispose() }
}

class WorkspaceTreeProvider {
  constructor() {
    this.snapshot = null
    this.emitter = new vscode.EventEmitter()
    this.onDidChangeTreeData = this.emitter.event
  }

  update(snapshot) {
    this.snapshot = snapshot
    this.emitter.fire(undefined)
  }

  getChildren(element) {
    if (element?.type === 'workspace') return element.children
    if (element) return []
    return workspaceRows(this.snapshot)
  }

  getTreeItem(item) {
    if (item.type === 'workspace') {
      const paneCount = item.children.length
      const descriptions = [`${paneCount} live pane${paneCount === 1 ? '' : 's'}`]
      if (item.attentionCount > 0) descriptions.push(`${item.attentionCount} attention`)
      return {
        label: item.label,
        description: descriptions.join(' · '),
        tooltip: `${item.label} · content-free Production snapshot`,
        iconPath: new vscode.ThemeIcon('layers'),
        collapsibleState: paneCount > 0
          ? vscode.TreeItemCollapsibleState.Expanded
          : vscode.TreeItemCollapsibleState.None,
        contextValue: 'parleyWorkspace',
      }
    }
    return {
      label: item.label,
      description: item.kind,
      tooltip: `${item.label} · ${item.kind} · ${item.workspaceName}`,
      iconPath: new vscode.ThemeIcon('terminal'),
      collapsibleState: vscode.TreeItemCollapsibleState.None,
      contextValue: 'parleyPane',
      command: {
        command: 'parley.focusPane',
        title: 'Focus Pane in Parley',
        arguments: [{ paneID: item.id }],
      },
      paneID: item.id,
    }
  }

  dispose() { this.emitter.dispose() }
}

class BasketTreeProvider {
  constructor(basket) {
    this.basket = basket
    this.emitter = new vscode.EventEmitter()
    this.onDidChangeTreeData = this.emitter.event
  }

  refresh() { this.emitter.fire(undefined) }

  getChildren(element) {
    if (!element) {
      return this.basket.folders().map((folder) => {
        const children = this.basket.entries(folder).map((entry) => ({
          type: 'basketItem',
          entryID: entry.id,
          folder,
          label: entry.label,
          description: entry.description,
          kind: entry.item.kind,
        }))
        return {
          type: 'basketFolder',
          folder,
          label: path.basename(folder) || folder,
          children,
        }
      })
    }
    return element.type === 'basketFolder' ? element.children : []
  }

  getTreeItem(item) {
    if (item.type === 'basketFolder') {
      const count = item.children.length
      return {
        label: item.label,
        description: `${count} source${count === 1 ? '' : 's'}`,
        tooltip: item.folder,
        iconPath: new vscode.ThemeIcon('folder'),
        collapsibleState: vscode.TreeItemCollapsibleState.Expanded,
        contextValue: 'parleyBasketFolder',
      }
    }
    return {
      label: item.label,
      description: item.description,
      tooltip: item.description,
      iconPath: new vscode.ThemeIcon(basketIcon(item.kind)),
      collapsibleState: vscode.TreeItemCollapsibleState.None,
      contextValue: 'parleyBasketItem',
      entryID: item.entryID,
    }
  }

  dispose() { this.emitter.dispose() }
}

function basketIcon(kind) {
  switch (kind) {
  case 'selection': return 'selection'
  case 'currentFile': return 'file-code'
  case 'diagnostics': return 'warning'
  case 'gitDiff':
  case 'gitWorkingDiff':
  case 'gitStagedDiff': return 'git-compare'
  default: return 'file'
  }
}

class CompanionCancellation extends Error {}
class CompanionNotice extends Error {}

module.exports = {
  activate,
  _test: {
    applyPreferredCandidates,
    collectContextCandidates,
    formatBytes,
    scmResourceURIs,
  },
}
