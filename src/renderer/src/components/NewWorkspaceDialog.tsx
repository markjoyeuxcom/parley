import { useEffect, useState, type ReactNode } from 'react'
import { FolderOpen } from 'lucide-react'
import type { Workspace } from '@shared/domain'
import { api } from '../lib/api'
import { shortPath } from '../lib/format'
import { useStore } from '../state'
import { Dialog, Field } from './ui'

/**
 * Starting a new project.
 *
 * This dialog is the one place a user authorises Parley to create files where
 * none existed, so it does two things carefully: it validates the destination
 * live — the refusal appears while you are still typing, not after you have
 * committed — and it states, in full, what will be written and what will be
 * run before anything is granted.
 */
export function NewWorkspaceDialog({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (workspace: Workspace) => void
}): ReactNode {
  const { attempt, notify } = useStore()
  const [templates, setTemplates] = useState<
    Array<{ id: string; name: string; description: string }>
  >([])
  const [templateId, setTemplateId] = useState('')
  const [name, setName] = useState('')
  const [parent, setParent] = useState('')
  const [busy, setBusy] = useState(false)
  const [preview, setPreview] = useState<{ ok: boolean; path: string; refusal: string } | null>(null)

  useEffect(() => {
    void api
      .listTemplates()
      .then((list) => {
        setTemplates(list)
        setTemplateId((current) => current || (list[0]?.id ?? ''))
      })
      .catch(() => setTemplates([]))
  }, [])

  // The folder name comes from the project name, so one field does the work
  // of two and the destination is always visible before it is agreed to.
  const folder = name.trim().toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '')
  const target = parent && folder ? `${parent.replace(/\/+$/, '')}/${folder}` : ''

  useEffect(() => {
    if (!target) {
      setPreview(null)
      return
    }
    let live = true
    void api
      .previewWorkspacePath(target)
      .then((result) => {
        if (live) setPreview(result)
      })
      .catch(() => {
        if (live) setPreview(null)
      })
    return () => {
      live = false
    }
  }, [target])

  const template = templates.find((entry) => entry.id === templateId) ?? null
  const ready = Boolean(name.trim() && parent && preview?.ok && templateId && !busy)

  const chooseParent = async (): Promise<void> => {
    const result = await attempt(() => api.pickDirectory('Where should the project live?'))
    if (result?.path) setParent(result.path)
  }

  const create = async (): Promise<void> => {
    if (!preview?.ok || !template) return
    setBusy(true)
    const summary =
      `Allow Parley to create a new ${template.name} project at ${preview.path}: write the ` +
      `template's files, make the first commit, install dependencies, and run the project's ` +
      `own verification. Nothing outside that folder is touched.`
    const approval = await attempt(() =>
      api.grantApproval('workspace.create', preview.path, summary),
    )
    if (!approval) {
      setBusy(false)
      return
    }
    const workspace = await attempt(() =>
      api.createWorkspace({
        name: name.trim(),
        path: preview.path,
        templateId: template.id,
        approvalId: approval.id,
      }),
    )
    setBusy(false)
    if (workspace) {
      notify('info', `Creating ${workspace.name} — installing and verifying before it is ready.`)
      onCreated(workspace)
    }
  }

  return (
    <Dialog
      title="Start a new app"
      subtitle="Parley scaffolds the project, commits it, and proves its tests pass before any agent touches it."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose} disabled={busy}>
            Cancel
          </button>
          <button className="btn btn--primary" disabled={!ready} onClick={() => void create()}>
            {busy ? 'Creating…' : 'Approve and create'}
          </button>
        </>
      }
    >
      <Field label="Name" hint="Also the folder name and the package name.">
        <input
          className="input"
          autoFocus
          value={name}
          placeholder="My great app"
          onChange={(event) => setName(event.target.value)}
        />
      </Field>

      <Field label="Location">
        <button className="btn" style={{ justifyContent: 'flex-start' }} onClick={() => void chooseParent()}>
          <FolderOpen size={12} strokeWidth={2} />
          {parent ? shortPath(parent) : 'Choose a folder to create it in'}
        </button>
      </Field>

      {target ? (
        <div
          className={preview && !preview.ok ? 'audit-note audit-note--reject' : 'audit-note'}
          style={{ fontSize: 'var(--text-small)' }}
        >
          {preview && !preview.ok ? preview.refusal : <>It will be created at <code>{target}</code>.</>}
        </div>
      ) : null}

      <Field label="Template" hint={template?.description ?? ''}>
        <select
          className="select"
          value={templateId}
          onChange={(event) => setTemplateId(event.target.value)}
        >
          {templates.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {entry.name}
            </option>
          ))}
        </select>
      </Field>

      <div className="audit-note">
        <strong>What Parley will do.</strong> Create that folder, write the template&rsquo;s
        files, make the first commit, install dependencies, then run the project&rsquo;s own
        verification. <strong>The project is only marked ready if that verification
        passes</strong> — a scaffold whose tests cannot run is not safe ground for a plan,
        and Parley removes what it made rather than leaving one behind. This is the only
        place Parley creates files where none existed, so it is recorded like any other
        authorisation to write.
      </div>
    </Dialog>
  )
}
