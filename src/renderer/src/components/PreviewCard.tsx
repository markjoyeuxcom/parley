import { useEffect, useState, type ReactNode } from 'react'
import { ExternalLink, Play, Square } from 'lucide-react'
import { api } from '../lib/api'
import { useStore } from '../state'
import { Chip, Field, Label, Spinner } from './ui'

/**
 * The project's own dev server, run by Parley.
 *
 * Useful for a scaffolded project and an existing one alike: the value is
 * that Parley starts it in the project's own folder, tells you where it is
 * listening, keeps its output when it dies, and can reliably stop the whole
 * process group — which is the part a terminal tab does badly.
 */

/** Only while running: a stopped server's log does not change. */
const LOG_REFRESH_MS = 2000

export function PreviewCard({ repo }: { repo: string }): ReactNode {
  const { state, attempt, notify } = useStore()
  const [command, setCommand] = useState('')
  const [suggested, setSuggested] = useState(false)
  const [showOutput, setShowOutput] = useState(false)
  const [log, setLog] = useState('')
  const [busy, setBusy] = useState(false)

  const preview =
    state.previews.find(
      (candidate) => candidate.repoPath === repo && candidate.status !== 'exited',
    ) ?? state.previews.find((candidate) => candidate.repoPath === repo) ?? null
  const live = preview?.status === 'starting' || preview?.status === 'running'

  // Ask the project what it uses to serve itself, once per repository.
  useEffect(() => {
    setSuggested(false)
    setCommand('')
    let alive = true
    void api
      .suggestPreviewCommand(repo)
      .then(({ command: suggestion }) => {
        if (!alive) return
        setCommand(suggestion)
        setSuggested(Boolean(suggestion))
      })
      .catch(() => {})
    return () => {
      alive = false
    }
  }, [repo])

  // The log is pulled rather than pushed: a dev server is chatty, and the
  // bytes only matter when someone is looking at them.
  useEffect(() => {
    if (!preview || (!showOutput && live)) return
    if (!showOutput) return
    const refresh = (): void => {
      void api
        .previewLogs(preview.id)
        .then(({ text }) => setLog(text))
        .catch(() => {})
    }
    refresh()
    if (!live) return
    const timer = setInterval(refresh, LOG_REFRESH_MS)
    return () => clearInterval(timer)
  }, [preview, showOutput, live])

  const start = async (): Promise<void> => {
    setBusy(true)
    const started = await attempt(() => api.startPreview(repo, command.trim()))
    setBusy(false)
    if (started) setShowOutput(true)
  }

  const stop = async (): Promise<void> => {
    if (!preview) return
    setBusy(true)
    await attempt(() => api.stopPreview(preview.id))
    setBusy(false)
  }

  return (
    <section className="panel foreman-panel">
      <header className="panel__header">
        <Label>Preview</Label>
        {preview?.status === 'starting' ? <Spinner /> : null}
        {preview ? (
          <Chip tone={preview.status === 'running' ? 'chip--accent' : preview.status === 'exited' ? '' : ''}>
            {preview.status === 'exited'
              ? `exited ${preview.exitCode ?? '?'}`
              : preview.status}
          </Chip>
        ) : null}
        <span className="spacer" />
        {preview?.url ? (
          <button
            className="btn btn--subtle btn--sm"
            onClick={() => {
              void attempt(() => api.openPreview(preview.id)).then((done) => {
                if (done) notify('info', `Opened ${preview.url} in your browser.`)
              })
            }}
            title={`Open ${preview.url} in your browser`}
          >
            <ExternalLink size={12} strokeWidth={2} />
            {preview.url.replace(/^https?:\/\//, '').replace(/\/$/, '')}
          </button>
        ) : null}
        {live ? (
          <button className="btn btn--subtle btn--sm" disabled={busy} onClick={() => void stop()}>
            <Square size={12} strokeWidth={2} />
            Stop
          </button>
        ) : (
          <button
            className="btn btn--sm"
            disabled={busy || !command.trim()}
            onClick={() => void start()}
          >
            <Play size={12} strokeWidth={2} />
            Start
          </button>
        )}
      </header>

      <div className="panel__body">
        {live ? (
          <p style={{ margin: 0, fontSize: 'var(--text-small)', color: 'var(--text-tertiary)' }}>
            Running <code>{preview?.command}</code>
            {preview?.url ? '' : ' — waiting for it to say where it is listening'}. Stopping ends
            the whole process group, so nothing is left holding the port.
          </p>
        ) : (
          <Field
            label="Command"
            hint={
              suggested
                ? "Read from this project's package.json. One command — no pipes or redirection."
                : "This project has no dev script Parley recognised; name the command yourself."
            }
          >
            <input
              className="input"
              value={command}
              placeholder="npm run dev"
              onChange={(event) => setCommand(event.target.value)}
            />
          </Field>
        )}

        {preview ? (
          <div style={{ marginTop: 'var(--s3)' }}>
            <button className="btn btn--subtle btn--sm" onClick={() => setShowOutput((v) => !v)}>
              {showOutput ? 'Hide output' : 'Show output'}
            </button>
            {showOutput ? (
              <div
                className="iteration__check"
                style={{ marginTop: 'var(--s3)', maxHeight: 220, overflow: 'auto' }}
              >
                {log.trim() || '(nothing yet)'}
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
    </section>
  )
}
