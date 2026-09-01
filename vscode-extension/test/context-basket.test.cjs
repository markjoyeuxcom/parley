const assert = require('node:assert/strict')
const test = require('node:test')

const { ContextBasket, attentionRows, workspaceRows } = require('../companion-model.cjs')

function identifierSequence() {
  let next = 0
  return () => `item-${++next}`
}

test('context basket is memory-only, workspace-scoped and replaces the latest capture of one source slot', () => {
  const basket = new ContextBasket({ randomID: identifierSequence() })
  const project = '/tmp/project'
  const other = '/tmp/other'

  basket.add(project, [
    { kind: 'currentFile', file: 'src/main.ts' },
    { kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 4, text: 'first capture' },
  ])
  const result = basket.add(project, [
    { kind: 'selection', file: 'src/main.ts', startLine: 2, endLine: 4, text: 'latest capture' },
  ])
  basket.add(other, [{ kind: 'gitWorkingDiff', file: 'README.md' }])

  assert.deepEqual(result, { added: 0, updated: 1, total: 2 })
  assert.equal(basket.entries(project).length, 2)
  assert.equal(basket.entries(project)[1].item.text, 'latest capture')
  assert.equal(basket.entries(other).length, 1)
  assert.deepEqual(basket.folders(), [project, other])
  assert.equal(Object.hasOwn(basket.entries(project)[0], 'persisted'), false)
})

test('context basket enforces the same bounded manifest contract before mutation', () => {
  const basket = new ContextBasket({ randomID: identifierSequence() })
  const items = Array.from({ length: 16 }, (_, index) => ({
    kind: 'currentFile',
    file: `src/file-${index}.ts`,
  }))
  basket.add('/tmp/project', items)
  assert.throws(
    () => basket.add('/tmp/project', [{ kind: 'currentFile', file: 'overflow.ts' }]),
    /at most 16/i,
  )
  assert.equal(basket.entries('/tmp/project').length, 16)
})

test('context basket supports exact item removal and clears only the selected workspace', () => {
  const basket = new ContextBasket({ randomID: identifierSequence() })
  basket.add('/tmp/project', [{ kind: 'currentFile', file: 'README.md' }])
  basket.add('/tmp/other', [{ kind: 'gitStagedDiff' }])
  const identifier = basket.entries('/tmp/project')[0].id

  assert.equal(basket.remove(identifier), true)
  assert.equal(basket.remove(identifier), false)
  assert.deepEqual(basket.folders(), ['/tmp/other'])
  assert.equal(basket.clear('/tmp/other'), 1)
  assert.equal(basket.count, 0)
})

test('context basket clears after accepted preview acknowledgement and survives every other outcome', () => {
  const basket = new ContextBasket({ randomID: identifierSequence() })
  basket.add('/tmp/project', [{ kind: 'currentFile', file: 'README.md' }])

  assert.equal(basket.accept('/tmp/project', { state: 'rejected' }), 0)
  assert.equal(basket.entries('/tmp/project').length, 1)
  assert.equal(basket.accept('/tmp/project', { state: 'accepted' }), 1)
  assert.equal(basket.entries('/tmp/project').length, 0)
})

test('content-free collaboration rows group exact panes and attention without inventing state', () => {
  const snapshot = {
    workspaces: [
      { id: 'workspace-a', name: 'Alpha', attentionCount: 1 },
      { id: 'workspace-b', name: 'Beta', attentionCount: 0 },
    ],
    panes: [
      { id: '%2', name: 'Codex', kind: 'codex', workspaceID: 'workspace-a', workspaceName: 'Alpha' },
      { id: '%3', name: 'Claude', kind: 'claude', workspaceID: 'workspace-b', workspaceName: 'Beta' },
    ],
    items: [
      {
        handoffID: '11111111-1111-4111-8111-111111111111',
        workspaceID: 'workspace-a',
        workspaceName: 'Alpha',
        label: 'Codex returned an answer',
        reason: 'returnedResult',
      },
    ],
  }

  assert.deepEqual(attentionRows(snapshot), [{
    type: 'attention',
    id: '11111111-1111-4111-8111-111111111111',
    label: 'Codex returned an answer',
    description: 'Alpha',
    reason: 'returnedResult',
  }])
  assert.deepEqual(workspaceRows(snapshot), [
    {
      type: 'workspace',
      id: 'workspace-a',
      label: 'Alpha',
      attentionCount: 1,
      children: [{ type: 'pane', id: '%2', label: 'Codex', kind: 'codex', workspaceName: 'Alpha' }],
    },
    {
      type: 'workspace',
      id: 'workspace-b',
      label: 'Beta',
      attentionCount: 0,
      children: [{ type: 'pane', id: '%3', label: 'Claude', kind: 'claude', workspaceName: 'Beta' }],
    },
  ])
  assert.equal(JSON.stringify(workspaceRows(snapshot)).includes('working'), false)
  assert.equal(JSON.stringify(workspaceRows(snapshot)).includes('prompt'), false)
})
