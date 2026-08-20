import type { Id, Pane } from '@shared/domain'
import { resolveRelayTarget } from './target'

/**
 * A relay an agent asked for, rather than one a person clicked.
 *
 * The menu relay is a person deciding what crosses. This one is a CLI in a
 * pane deciding, which is a different thing and needs a different ending: the
 * text is pasted into the target's prompt and NOT submitted. It sits there,
 * visible and editable, until a person presses Enter.
 *
 * That single property is what makes the whole path safe to have. An agent
 * that could submit into another agent's session would be a prompt-injection
 * channel with a command runner on the far end — anything Claude read on a web
 * page could steer Codex. Landing in an input box costs an agent nothing it
 * actually needs and closes that entirely.
 */
export interface RelayDeps {
  panes: () => readonly Pane[]
  /** Pastes without submitting. Throws if the pane cannot receive it. */
  paste: (paneId: Id, text: string) => void
  nameOf: (paneId: Id) => string
}

/** Bounded because it arrives over a socket from a process we do not control. */
const MAX_TEXT = 100_000

export interface RelayResult {
  status: number
  body: { ok: true; delivered: string; submitted: false; note: string } | { ok: false; error: string }
}

export function handleRelay(input: unknown, deps: RelayDeps): RelayResult {
  const body = input as { from?: unknown; to?: unknown; text?: unknown } | null
  const from = typeof body?.from === 'string' ? body.from : ''
  const to = typeof body?.to === 'string' ? body.to : ''
  const text = typeof body?.text === 'string' ? body.text : ''

  if (!from || !to || !text.trim()) {
    return { status: 400, body: { ok: false, error: 'need from, to and text' } }
  }
  if (text.length > MAX_TEXT) {
    return { status: 400, body: { ok: false, error: `text too long (max ${MAX_TEXT} characters)` } }
  }

  const target = resolveRelayTarget(deps.panes(), to, from)
  if (!target.ok) return { status: 400, body: { ok: false, error: target.error } }

  // Attributed, like every relay. The receiving CLI has no idea where this
  // came from, and an unattributed wall of another model's words reads as the
  // user's own.
  const relayed = `${deps.nameOf(from)} said:\n\n${text.trim()}`
  try {
    deps.paste(target.paneId, relayed)
  } catch (err) {
    // A pane that went between resolving and writing. Saying "delivered" over
    // that would be the exact lie the menu relay was fixed for.
    return { status: 409, body: { ok: false, error: err instanceof Error ? err.message : String(err) } }
  }

  return {
    status: 200,
    body: {
      ok: true,
      delivered: deps.nameOf(target.paneId),
      submitted: false,
      // Stated every time. The caller is a model, and it will otherwise report
      // to the user that it sent a message somebody still has to send.
      note: 'Pasted into the prompt and NOT sent. The person there presses Enter.',
    },
  }
}
