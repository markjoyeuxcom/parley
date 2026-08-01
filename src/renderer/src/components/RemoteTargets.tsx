import { useEffect, useState, type ReactNode } from 'react'
import { Server } from 'lucide-react'
import { api, type RemoteStatusView, type RemoteTargetView } from '../lib/api'
import { useStore } from '../state'
import { Chip, Dialog, Empty, Field, Label } from './ui'

/**
 * Hosts Parley may execute on.
 *
 * Adding one reaches nothing: a target is a note about where work might run,
 * and the expensive question — is this host actually usable — is asked with
 * Check, when someone wants the answer. Doing it on every keystroke would spend
 * a connection to tell them what they already suspected while typing.
 */

const HEALTH: Record<RemoteStatusView['health'], { label: string; tone: string }> = {
  healthy: { label: 'ready', tone: 'chip--pass' },
  degraded: { label: 'limited', tone: 'chip--caution' },
  incompatible: { label: 'incompatible', tone: 'chip--fail' },
  corrupt: { label: 'corrupt', tone: 'chip--fail' },
  'not-installed': { label: 'not installed', tone: 'chip--fail' },
}

export function RemoteTargetsPanel(): ReactNode {
  const { attempt, notify } = useStore()
  const [targets, setTargets] = useState<RemoteTargetView[]>([])
  const [statuses, setStatuses] = useState<Record<string, RemoteStatusView>>({})
  const [checking, setChecking] = useState<string | null>(null)
  const [installing, setInstalling] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)

  const refresh = (): void => {
    void api
      .listRemoteTargets()
      .then((next) => setTargets(Array.isArray(next) ? next : []))
      .catch(() => {})
  }
  useEffect(refresh, [])

  const check = (target: RemoteTargetView): void => {
    setChecking(target.id)
    void attempt(() => api.remoteStatus(target.id))
      .then((status) => {
        if (status) setStatuses((current) => ({ ...current, [target.id]: status }))
      })
      .finally(() => setChecking(null))
  }

  return (
    <>
      <section className="panel foreman-panel">
        <header className="panel__header">
          <Label>Execution hosts</Label>
          <span className="spacer" />
          <button className="btn btn--sm" onClick={() => setAdding(true)}>
            <Server size={12} strokeWidth={2} />
            Add a host
          </button>
        </header>
        <div className="panel__body panel__body--flush">
          {targets.length === 0 ? (
            <Empty
              compact
              title="No execution hosts."
              body="A host runs a milestone in its own isolated worktree, as its own user, and sends back a result you review here."
            />
          ) : (
            targets.map((target) => {
              const status = statuses[target.id]
              const health = status ? HEALTH[status.health] : null
              return (
                <div key={target.id} className="list-item" style={{ cursor: 'default', display: 'block' }}>
                  <div className="row row--tight">
                    <span className="list-item__title">{target.label}</span>
                    {health ? <Chip tone={health.tone}>{health.label}</Chip> : null}
                    <span className="spacer" />
                    <button
                      className="btn btn--subtle btn--sm"
                      disabled={checking === target.id}
                      onClick={() => check(target)}
                    >
                      {checking === target.id ? 'Checking…' : 'Check'}
                    </button>
                    <button
                      className="btn btn--subtle btn--sm"
                      disabled={installing === target.id}
                      title="Uploads this build's runner, checks its hash on the host, makes it prove it starts, and only then activates it."
                      onClick={() => {
                        setInstalling(target.id)
                        void attempt(() => api.installRemote(target.id))
                          .then((done) => {
                            if (!done) return
                            notify(done.ok ? 'info' : 'error', done.detail)
                            if (done.ok) check(target)
                          })
                          .finally(() => setInstalling(null))
                      }}
                    >
                      {installing === target.id ? 'Installing…' : 'Install'}
                    </button>
                    <button
                      className="btn btn--subtle btn--sm"
                      title="Removes the note. Nothing on the host is touched."
                      onClick={() => {
                        void attempt(() => api.forgetRemoteTarget(target.id)).then((done) => {
                          if (done) {
                            notify('info', 'Host removed. Nothing on it was changed.')
                            refresh()
                          }
                        })
                      }}
                    >
                      Forget
                    </button>
                  </div>

                  <div className="list-item__meta">
                    <span className="chip chip--mono">{target.host}</span>
                    {target.nodeCommand !== 'node' ? (
                      <>
                        <span>·</span>
                        <span>node: {target.nodeCommand}</span>
                      </>
                    ) : null}
                  </div>

                  {status ? (
                    <div className="list-item__meta" style={{ marginTop: 'var(--s2)', display: 'block' }}>
                      {status.reasons.map((reason) => (
                        <div key={reason}>{reason}</div>
                      ))}
                      {status.facts.capabilities ? (
                        <div style={{ marginTop: 'var(--s2)' }}>
                          runs as {status.facts.capabilities.user} · node{' '}
                          {status.facts.capabilities.nodeVersion} · agents available:{' '}
                          {status.facts.capabilities.availableVendors.join(', ') || 'none'}
                        </div>
                      ) : null}
                    </div>
                  ) : null}
                </div>
              )
            })
          )}
        </div>
      </section>

      {adding ? (
        <AddHostDialog
          onClose={() => setAdding(false)}
          onAdded={() => {
            setAdding(false)
            refresh()
          }}
        />
      ) : null}
    </>
  )
}

function AddHostDialog({
  onClose,
  onAdded,
}: {
  onClose: () => void
  onAdded: () => void
}): ReactNode {
  const { attempt } = useStore()
  const [host, setHost] = useState('')
  const [label, setLabel] = useState('')
  const [nodeCommand, setNodeCommand] = useState('')

  return (
    <Dialog
      title="Add an execution host"
      subtitle="Nothing is contacted now. Use Check afterwards to find out what is actually there."
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button
            className="btn btn--primary"
            disabled={!host.trim()}
            onClick={() => {
              void attempt(() =>
                api.addRemoteTarget({
                  label: label.trim() || host.trim(),
                  host: host.trim(),
                  nodeCommand: nodeCommand.trim() || undefined,
                }),
              ).then((made) => {
                if (made) onAdded()
              })
            }}
          >
            Add
          </button>
        </>
      }
    >
      <Field
        label="SSH destination"
        hint="Whatever ssh understands. An alias from ~/.ssh/config is best — it keeps keys, ports and jump hosts where they already live."
      >
        <input
          className="input"
          autoFocus
          placeholder="build-01"
          value={host}
          onChange={(event) => setHost(event.target.value)}
        />
      </Field>
      <Field label="Name" hint="Optional. Defaults to the destination.">
        <input
          className="input"
          placeholder="Build box"
          value={label}
          onChange={(event) => setLabel(event.target.value)}
        />
      </Field>
      <Field
        label="Node command"
        hint="Optional. Leave empty unless a non-interactive ssh session cannot find node there — with nvm, asdf or mise it usually cannot, and an absolute path is the fix."
      >
        <input
          className="input"
          placeholder="/home/you/.nvm/versions/node/v22.18.0/bin/node"
          value={nodeCommand}
          onChange={(event) => setNodeCommand(event.target.value)}
        />
      </Field>
    </Dialog>
  )
}
