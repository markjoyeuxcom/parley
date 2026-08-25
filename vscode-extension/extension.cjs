const childProcess = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const vscode = require('vscode')

const {
  assertLocalDesktopRuntime,
  buildManifest,
  formatDiagnostics,
  relativeWorkspaceFile,
  stageManifest,
} = require('./contracts.cjs')

const PARLEY_BUNDLE_IDENTIFIER = 'com.markjoyeux.parley'
const OPEN_EXECUTABLE = '/usr/bin/open'

function activate(context) {
  const commands = {
    'parley.openWorkspace': openWorkspace,
    'parley.stageSelection': stageSelection,
    'parley.stageCurrentFile': stageCurrentFile,
    'parley.stageDiagnostics': stageDiagnostics,
    'parley.stageGitDiff': stageGitDiff,
    'parley.stageSelectionAndGitDiff': stageSelectionAndGitDiff,
  }
  for (const [name, handler] of Object.entries(commands)) {
    context.subscriptions.push(vscode.commands.registerCommand(name, (...args) => reportErrors(() => handler(...args))))
  }
}

async function openWorkspace(resource) {
  assertSupportedRuntime()
  const folder = await chooseWorkspaceFolder(resource)
  await openInParley(folder.uri.fsPath)
  void vscode.window.showInformationMessage(`Asked Parley to open ${folder.name}. No agent was started.`)
}

async function stageSelection() {
  assertSupportedRuntime()
  const editor = vscode.window.activeTextEditor
  if (!editor || editor.document.uri.scheme !== 'file') {
    throw new Error('Open a local workspace file and select text first.')
  }
  const selected = editor.document.getText(editor.selection)
  if (!selected.trim()) throw new Error('Select the exact text you want to place in Parley.')
  const source = localDocumentSource(editor.document.uri)
  await stageAndOpen(source.folder, [{
    kind: 'selection',
    file: source.relativeFile,
    startLine: editor.selection.start.line + 1,
    endLine: editor.selection.end.line + 1,
    text: selected,
  }])
}

async function stageCurrentFile(resource) {
  assertSupportedRuntime()
  const source = await localDocumentSourceFrom(resource)
  if (source.document.isDirty) {
    const action = await vscode.window.showWarningMessage(
      'Parley recaptures the current file from disk. Save it before opening the context preview?',
      { modal: true },
      'Save and Continue',
    )
    if (action !== 'Save and Continue' || !(await source.document.save())) return
  }
  await stageAndOpen(source.folder, [{ kind: 'currentFile', file: source.relativeFile }])
}

async function stageDiagnostics(resource) {
  assertSupportedRuntime()
  const source = await localDocumentSourceFrom(resource)
  const diagnostics = vscode.languages.getDiagnostics(source.document.uri).map((diagnostic) => ({
    severity: severityName(diagnostic.severity),
    line: diagnostic.range.start.line + 1,
    column: diagnostic.range.start.character + 1,
    message: diagnostic.message,
    source: diagnostic.source,
    code: typeof diagnostic.code === 'object' ? diagnostic.code?.value : diagnostic.code,
  }))
  const text = formatDiagnostics(source.relativeFile, diagnostics)
  await stageAndOpen(source.folder, [{ kind: 'diagnostics', file: source.relativeFile, text }])
}

async function stageGitDiff(resource) {
  assertSupportedRuntime()
  const folder = await chooseWorkspaceFolder(resource)
  await stageAndOpen(folder.uri.fsPath, [{ kind: 'gitDiff' }])
}

async function stageSelectionAndGitDiff() {
  assertSupportedRuntime()
  const editor = vscode.window.activeTextEditor
  if (!editor || editor.document.uri.scheme !== 'file') {
    throw new Error('Open a local workspace file and select text first.')
  }
  const selected = editor.document.getText(editor.selection)
  if (!selected.trim()) throw new Error('Select the exact text you want to place in Parley.')
  const source = localDocumentSource(editor.document.uri)
  await stageAndOpen(source.folder, [
    {
      kind: 'selection',
      file: source.relativeFile,
      startLine: editor.selection.start.line + 1,
      endLine: editor.selection.end.line + 1,
      text: selected,
    },
    { kind: 'gitDiff' },
  ])
}

async function stageAndOpen(folder, items) {
  const manifest = buildManifest(folder, items)
  const file = stageManifest(manifest, { home: os.homedir(), randomUUID: crypto.randomUUID })
  try {
    await openInParley(file)
  } catch (error) {
    try { fs.rmSync(file, { force: true }) } catch {}
    throw error
  }
  const cleanup = setTimeout(() => {
    try { fs.rmSync(file, { force: true }) } catch {}
  }, 5 * 60 * 1_000)
  cleanup.unref()
  void vscode.window.showInformationMessage(
    `Opened ${items.length} explicit source${items.length === 1 ? '' : 's'} in Parley's editable context preview. Nothing was sent.`,
  )
}

function assertSupportedRuntime() {
  assertLocalDesktopRuntime({
    platform: process.platform,
    remoteName: vscode.env.remoteName,
    web: vscode.env.uiKind === vscode.UIKind.Web,
  })
}

async function chooseWorkspaceFolder(resource) {
  const candidate = resource?.scheme === 'file'
    ? vscode.workspace.getWorkspaceFolder(resource)
    : vscode.window.activeTextEditor?.document.uri.scheme === 'file'
      ? vscode.workspace.getWorkspaceFolder(vscode.window.activeTextEditor.document.uri)
      : undefined
  if (candidate) return requireLocalFolder(candidate)
  const folders = vscode.workspace.workspaceFolders || []
  if (folders.length === 0) throw new Error('Open a local folder in VS Code first.')
  if (folders.length === 1) return requireLocalFolder(folders[0])
  const selected = await vscode.window.showQuickPick(
    folders.map((folder) => ({ label: folder.name, description: folder.uri.fsPath, folder })),
    { placeHolder: 'Choose the local workspace folder to open in Parley' },
  )
  if (!selected) throw new Error('No workspace folder was selected.')
  return requireLocalFolder(selected.folder)
}

function requireLocalFolder(folder) {
  if (folder.uri.scheme !== 'file') throw new Error('Parley accepts local filesystem workspaces only.')
  const resolved = fs.realpathSync(folder.uri.fsPath)
  if (!fs.statSync(resolved).isDirectory()) throw new Error('The VS Code workspace folder is unavailable.')
  return { name: folder.name, index: folder.index, uri: vscode.Uri.file(resolved) }
}

async function localDocumentSourceFrom(resource) {
  const uri = resource?.scheme === 'file' ? resource : vscode.window.activeTextEditor?.document.uri
  if (!uri || uri.scheme !== 'file') throw new Error('Open a local workspace file first.')
  const document = await vscode.workspace.openTextDocument(uri)
  return { ...localDocumentSource(uri), document }
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

function severityName(severity) {
  switch (severity) {
  case vscode.DiagnosticSeverity.Error: return 'error'
  case vscode.DiagnosticSeverity.Warning: return 'warning'
  case vscode.DiagnosticSeverity.Information: return 'information'
  case vscode.DiagnosticSeverity.Hint: return 'hint'
  default: return 'unknown'
  }
}

function openInParley(target) {
  return new Promise((resolve, reject) => {
    childProcess.execFile(
      OPEN_EXECUTABLE,
      ['-b', PARLEY_BUNDLE_IDENTIFIER, target],
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

async function reportErrors(operation) {
  try {
    await operation()
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    void vscode.window.showErrorMessage(`Parley: ${message}`)
  }
}

module.exports = { activate }
