const path = require('node:path')

const { buildManifest } = require('./contracts.cjs')

class ContextBasket {
  constructor({ randomID = () => require('node:crypto').randomUUID() } = {}) {
    this.randomID = randomID
    this.entriesByFolder = new Map()
  }

  get count() {
    let total = 0
    for (const entries of this.entriesByFolder.values()) total += entries.length
    return total
  }

  folders() {
    return [...this.entriesByFolder.keys()]
  }

  entries(folder) {
    return [...(this.entriesByFolder.get(folder) || [])]
  }

  add(folder, items) {
    const cleaned = buildManifest(folder, items).items
    const prospective = this.entries(folder)
    let added = 0
    let updated = 0

    for (const item of cleaned) {
      const sourceKey = contextSourceKey(item)
      const existingIndex = prospective.findIndex((entry) => entry.sourceKey === sourceKey)
      if (existingIndex >= 0) {
        prospective[existingIndex] = makeBasketEntry(
          prospective[existingIndex].id,
          folder,
          sourceKey,
          item,
        )
        updated += 1
      } else {
        prospective.push(makeBasketEntry(this.randomID(), folder, sourceKey, item))
        added += 1
      }
    }

    // Validate the complete prospective basket before mutating it. This keeps
    // every eventual review inside the same source-count and byte bounds as a
    // one-shot context manifest.
    buildManifest(folder, prospective.map((entry) => entry.item))
    this.entriesByFolder.set(folder, prospective)
    return { added, updated, total: prospective.length }
  }

  remove(identifier) {
    for (const [folder, entries] of this.entriesByFolder) {
      const next = entries.filter((entry) => entry.id !== identifier)
      if (next.length === entries.length) continue
      if (next.length === 0) this.entriesByFolder.delete(folder)
      else this.entriesByFolder.set(folder, next)
      return true
    }
    return false
  }

  clear(folder) {
    const entries = this.entriesByFolder.get(folder) || []
    this.entriesByFolder.delete(folder)
    return entries.length
  }

  accept(folder, acknowledgement, submittedEntries) {
    if (acknowledgement?.state !== 'accepted' || !submittedEntries) return 0
    // Entries are replaced, never mutated. Object identity is the exact
    // in-memory capture revision submitted with this acknowledged request.
    const submitted = new Set(submittedEntries)
    const current = this.entries(folder)
    const remaining = current.filter(entry => !submitted.has(entry))
    if (remaining.length === 0) this.entriesByFolder.delete(folder)
    else this.entriesByFolder.set(folder, remaining)
    return current.length - remaining.length
  }
}

function makeBasketEntry(id, folder, sourceKey, item) {
  return {
    id,
    folder,
    sourceKey,
    label: basketItemLabel(item),
    description: basketItemDescription(item),
    item,
  }
}

function contextSourceKey(item) {
  switch (item.kind) {
  case 'selection':
    return `${item.kind}\0${item.file}\0${item.startLine}\0${item.endLine}`
  case 'currentFile':
  case 'diagnostics':
    return `${item.kind}\0${item.file}`
  case 'gitWorkingDiff':
  case 'gitStagedDiff':
    return `${item.kind}\0${item.file || ''}`
  case 'gitDiff':
    return item.kind
  default:
    throw new Error('Unsupported Parley context basket source.')
  }
}

function basketItemLabel(item) {
  switch (item.kind) {
  case 'selection':
    return `${path.basename(item.file)} · lines ${item.startLine}–${item.endLine}`
  case 'currentFile':
    return path.basename(item.file)
  case 'diagnostics':
    return `${path.basename(item.file)} diagnostics`
  case 'gitDiff':
    return 'All Git changes'
  case 'gitWorkingDiff':
    return item.file ? `${path.basename(item.file)} working change` : 'Working-tree changes'
  case 'gitStagedDiff':
    return item.file ? `${path.basename(item.file)} staged change` : 'Staged changes'
  default:
    return 'Context source'
  }
}

function basketItemDescription(item) {
  switch (item.kind) {
  case 'selection': return `${item.file}:${item.startLine}-${item.endLine}`
  case 'currentFile': return `${item.file} · recaptured from disk`
  case 'diagnostics': return `${item.file} · VS Code-provided`
  case 'gitDiff': return 'staged + working tree · recaptured by Parley'
  case 'gitWorkingDiff': return `${item.file || 'repository'} · recaptured by Parley`
  case 'gitStagedDiff': return `${item.file || 'repository'} · recaptured by Parley`
  default: return ''
  }
}

function attentionRows(snapshot) {
  return (snapshot?.items || []).map((item) => ({
    type: 'attention',
    id: item.handoffID,
    label: item.label,
    description: item.workspaceName,
    reason: item.reason,
  }))
}

function workspaceRows(snapshot) {
  const panes = snapshot?.panes || []
  return (snapshot?.workspaces || []).map((workspace) => ({
    type: 'workspace',
    id: workspace.id,
    label: workspace.name,
    attentionCount: workspace.attentionCount,
    children: panes
      .filter((pane) => pane.workspaceID === workspace.id)
      .map((pane) => ({
        type: 'pane',
        id: pane.id,
        label: pane.name,
        kind: pane.kind,
        workspaceName: pane.workspaceName,
      })),
  }))
}

module.exports = {
  ContextBasket,
  attentionRows,
  basketItemDescription,
  basketItemLabel,
  workspaceRows,
}
