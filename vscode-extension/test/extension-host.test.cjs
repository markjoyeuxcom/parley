const assert = require('node:assert/strict')
const fs = require('node:fs')
const Module = require('node:module')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')

test('extension host activation registers the unified bridge and privacy-safe diagnostics', async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-vscode-host-'))
  const registered = new Map()
  const executed = []
  const treeViews = new Map()
  const outputLines = []
  const project = path.join(home, 'project')
  const sourceFile = path.join(project, 'src', 'main.ts')
  fs.mkdirSync(path.dirname(sourceFile), { recursive: true })
  fs.writeFileSync(sourceFile, 'const first = 1\nconst second = 2\n')
  const application = path.join(home, 'Library/Application Support/Parley Native')
  fs.mkdirSync(application, { recursive: true, mode: 0o700 })
  fs.chmodSync(application, 0o700)
  fs.writeFileSync(path.join(application, 'external-attention.json'), JSON.stringify({
    version: 1,
    generatedAt: new Date().toISOString(),
    attentionCount: 1,
    workspaces: [{ id: 'workspace-11111111-1111-4111-8111-111111111111', name: 'Project', attentionCount: 1 }],
    panes: [{
      id: 'pane-11111111-1111-4111-8111-111111111111',
      name: 'Codex',
      kind: 'codex',
      workspaceID: 'workspace-11111111-1111-4111-8111-111111111111',
      workspaceName: 'Project',
    }],
    items: [{
      handoffID: '22222222-2222-4222-8222-222222222222',
      workspaceID: 'workspace-11111111-1111-4111-8111-111111111111',
      workspaceName: 'Project',
      label: 'Codex returned an answer',
      reason: 'returnedResult',
    }],
  }), { mode: 0o600 })
  const fileURI = { scheme: 'file', fsPath: fs.realpathSync(sourceFile) }
  const folder = {
    name: 'project',
    index: 0,
    uri: { scheme: 'file', fsPath: fs.realpathSync(project) },
  }
  const disposable = () => ({ dispose() {} })
  const output = {
    clear() { outputLines.length = 0 },
    appendLine(line) { outputLines.push(line) },
    show() {},
    dispose() {},
  }
  const status = {
    show() {},
    dispose() {},
    text: '',
    tooltip: '',
  }
  class EventEmitter {
    constructor() {
      this.listeners = []
      this.event = (listener) => {
        this.listeners.push(listener)
        return disposable()
      }
    }
    fire(value) {
      for (const listener of this.listeners) listener(value)
    }
    dispose() { this.listeners.length = 0 }
  }
  const vscode = {
    StatusBarAlignment: { Left: 1 },
    UIKind: { Desktop: 1, Web: 2 },
    QuickPickItemKind: { Separator: -1 },
    DiagnosticSeverity: { Error: 0, Warning: 1, Information: 2, Hint: 3 },
    ProgressLocation: { Notification: 15 },
    TreeItemCollapsibleState: { None: 0, Collapsed: 1, Expanded: 2 },
    EventEmitter,
    ThemeIcon: class ThemeIcon { constructor(id) { this.id = id } },
    env: { remoteName: undefined, uiKind: 1 },
    Uri: { file: (fsPath) => ({ scheme: 'file', fsPath }) },
    commands: {
      registerCommand(name, handler) {
        registered.set(name, handler)
        return disposable()
      },
      async executeCommand(name, ...args) {
        executed.push([name, ...args])
      },
    },
    languages: {
      getDiagnostics: () => [{
        severity: 1,
        range: { start: { line: 1, character: 6 } },
        message: 'Example warning',
        source: 'test',
        code: 'P1',
      }],
    },
    workspace: {
      workspaceFolders: [folder],
      textDocuments: [],
      getWorkspaceFolder: () => folder,
    },
    window: {
      activeTextEditor: {
        document: {
          uri: fileURI,
          getText: (selection) => selection.text,
        },
        selections: [
          { start: { line: 0 }, end: { line: 0 }, text: 'first' },
          { start: { line: 1 }, end: { line: 1 }, text: 'second' },
        ],
      },
      createOutputChannel: () => output,
      createStatusBarItem: () => status,
      createTreeView(id, options) {
        const view = { id, ...options, message: undefined, dispose() {} }
        treeViews.set(id, view)
        return view
      },
      showErrorMessage() {},
      showInformationMessage() {},
    },
  }

  const originalLoad = Module._load
  const extensionPath = require.resolve('../extension.cjs')
  Module._load = function(request, parent, isMain) {
    if (request === 'vscode') return vscode
    if (request === 'node:os') return { ...os, homedir: () => home }
    return originalLoad.call(this, request, parent, isMain)
  }
  const context = { subscriptions: [] }
  try {
    delete require.cache[extensionPath]
    const extension = require(extensionPath)
    extension.activate(context)

    for (const command of [
      'parley.openWorkspace',
      'parley.showAttention',
      'parley.buildContextPack',
      'parley.buildWorkingTreeContext',
      'parley.buildStagedContext',
      'parley.diagnoseCompanion',
      'parley.openCollaboration',
      'parley.openApplication',
      'parley.refreshCollaboration',
      'parley.focusPane',
      'parley.openHandoff',
      'parley.addSelectionToBasket',
      'parley.addFilesToBasket',
      'parley.addDiagnosticsToBasket',
      'parley.addWorkingChangeToBasket',
      'parley.addStagedChangeToBasket',
      'parley.reviewContextBasket',
      'parley.clearContextBasket',
      'parley.removeContextBasketItem',
    ]) {
      assert.equal(registered.has(command), true, `${command} was not registered`)
    }
    assert.equal(registered.has('parley.stageSelection'), true, 'legacy keybindings lost their safe composer route')

    const candidates = await extension._test.collectContextCandidates({ folder })
    assert.equal(candidates.find((candidate) => candidate.id === 'selections').items.length, 2)
    assert.equal(candidates.some((candidate) => candidate.id === 'currentFile'), true)
    assert.equal(candidates.some((candidate) => candidate.id === 'diagnostics'), true)
    assert.equal(candidates.some((candidate) => candidate.id === 'gitStagedDiff'), true)

    assert.deepEqual([...treeViews.keys()], [
      'parley.attention',
      'parley.workspaces',
      'parley.contextBasket',
    ])
    const attentionProvider = treeViews.get('parley.attention').treeDataProvider
    assert.equal(attentionProvider.getChildren()[0].label, 'Codex returned an answer')
    const workspaceProvider = treeViews.get('parley.workspaces').treeDataProvider
    const workspaceRows = workspaceProvider.getChildren()
    assert.equal(workspaceRows[0].label, 'Project')
    assert.equal(workspaceProvider.getChildren(workspaceRows[0])[0].label, 'Codex')
    assert.deepEqual(treeViews.get('parley.contextBasket').treeDataProvider.getChildren(), [])

    await registered.get('parley.addSelectionToBasket')()
    const basketProvider = treeViews.get('parley.contextBasket').treeDataProvider
    const basketFolders = basketProvider.getChildren()
    assert.equal(basketFolders.length, 1)
    const basketItems = basketProvider.getChildren(basketFolders[0])
    assert.equal(basketItems.length, 2)
    assert.equal(JSON.stringify(basketItems).includes('first'), false, 'tree leaked selected source text')
    await registered.get('parley.removeContextBasketItem')(basketProvider.getTreeItem(basketItems[0]))
    assert.equal(basketProvider.getChildren(basketProvider.getChildren()[0]).length, 1)
    assert.equal(
      executed.some(([name, key, value]) => name === 'setContext' && key === 'parley.contextBasketHasItems' && value === true),
      true,
    )

    await registered.get('parley.openCollaboration')()
    assert.equal(executed.some(([name]) => name === 'workbench.view.extension.parley'), true)

    await registered.get('parley.diagnoseCompanion')()
    const diagnostics = outputLines.join('\n')
    assert.match(diagnostics, /Editor bridge: unavailable/)
    assert.match(diagnostics, /diagnostics omit workspace paths/)
    assert.equal(diagnostics.includes(home), false)
  } finally {
    for (const subscription of context.subscriptions) subscription.dispose?.()
    delete require.cache[extensionPath]
    Module._load = originalLoad
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test('saving selected files stays inside the selected canonical workspace', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'parley-save-roots-'))
  const saved = []
  const folders = ['a', 'b'].map(name => {
    const folder = path.join(root, name)
    fs.mkdirSync(folder)
    fs.writeFileSync(path.join(folder, 'same.txt'), 'fixture')
    return fs.realpathSync(folder)
  })
  const documents = folders.map(folder => ({
    isDirty: true, uri: { scheme: 'file', fsPath: path.join(folder, 'same.txt') },
    save: async () => { saved.push(folder); return true },
  }))
  const vscode = {
    workspace: { textDocuments: documents, getWorkspaceFolder: uri => ({ uri: { scheme: 'file', fsPath: path.dirname(uri.fsPath) } }) },
    window: { showWarningMessage: async () => 'Save and Continue' },
  }
  const filename = require.resolve('../extension.cjs')
  const fixture = new Module(filename, module)
  fixture.filename = filename
  fixture.paths = module.paths
  const originalLoad = Module._load
  try {
    Module._load = function(request, parent, isMain) {
      return request === 'vscode' ? vscode : originalLoad.call(this, request, parent, isMain)
    }
    fixture._compile(fs.readFileSync(filename, 'utf8') + '\nmodule.exports.saveSelectedFiles = saveSelectedFiles\n', filename)
    await fixture.exports.saveSelectedFiles([{ items: [{ kind: 'currentFile', file: 'same.txt' }] }], folders[0])
    assert.deepEqual(saved, [folders[0]])
  } finally {
    Module._load = originalLoad
    fs.rmSync(root, { recursive: true, force: true })
  }
})
