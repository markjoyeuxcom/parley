import { useEffect, useState, type ReactNode } from 'react'
import { Pencil, Plus, Trash2 } from 'lucide-react'
import type { AgentProfile, Effort, Id, Vendor } from '@shared/domain'
import { api } from '../lib/api'
import { EFFORTS, VENDORS } from '../lib/seats'
import { Chip, Dialog, Empty, Field } from './ui'

/**
 * The roster: every named way of configuring a seat, in one place.
 *
 * Profiles have existed since schema 32 but only ever half-existed as a
 * surface — a seat picker could save one and choose one, and nothing could
 * list, correct or retire one. `profile.forget` shipped with no caller at all.
 * This is the missing half, and it is Grid-facing because the Grid is where
 * seats are going to be staffed.
 *
 * A profile is four fields under a name, and **never credentials**. The CLIs
 * hold their own authentication; a profile that carried keys would turn a
 * convenience into a vault.
 *
 * The one honest thing this dialog has to keep saying: editing a profile does
 * not reach the work it was already stamped on. A plan or journal entry naming
 * "Fast reviewer" records what a seat was called when it ran, and renaming the
 * profile later cannot make that untrue — nor should it.
 */

interface Draft {
  /** Absent for a new profile; present when correcting an existing one. */
  id: Id | null
  name: string
  vendor: Vendor
  model: string
  effort: Effort
  persona: string
}

const BLANK: Draft = { id: null, name: '', vendor: 'claude', model: '', effort: 'high', persona: '' }

function draftOf(profile: AgentProfile): Draft {
  return {
    id: profile.id,
    name: profile.name,
    vendor: profile.vendor,
    model: profile.model,
    effort: profile.effort,
    persona: profile.persona,
  }
}

export function RosterDialog({ onClose }: { onClose: () => void }): ReactNode {
  const [profiles, setProfiles] = useState<AgentProfile[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [error, setError] = useState('')
  const [confirmingDelete, setConfirmingDelete] = useState<Id | null>(null)

  const load = (): void => {
    void api
      .listAgentProfiles()
      .then((rows) => {
        // The guard AgentPicker and RunRoom both carry: a bridge answering
        // with nothing must produce an empty roster, not a crashed one.
        setProfiles(Array.isArray(rows) ? rows : [])
      })
      .catch((err: unknown) => {
        setError(err instanceof Error ? err.message : String(err))
      })
  }

  useEffect(load, [])

  const save = async (): Promise<void> => {
    if (!draft) return
    const name = draft.name.trim()
    if (!name) {
      setError('a profile needs a name')
      return
    }
    const fields = {
      name,
      vendor: draft.vendor,
      model: draft.model.trim(),
      effort: draft.effort,
      persona: draft.persona.trim(),
    }
    try {
      // The store owns both rules — the NOCASE unique name and the blank
      // refusal — so its words are the ones shown rather than a guess made
      // here about which one fired.
      if (draft.id) await api.updateAgentProfile(draft.id, fields)
      else await api.addAgentProfile(fields)
      setDraft(null)
      setError('')
      load()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  const forget = async (profileId: Id): Promise<void> => {
    try {
      await api.forgetAgentProfile(profileId)
      setConfirmingDelete(null)
      setError('')
      load()
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    }
  }

  return (
    <Dialog
      title="Roster"
      subtitle="Named ways of configuring a seat — a CLI, a model, an effort and a persona. Never credentials."
      onClose={onClose}
      wide
      footer={
        <div className="row">
          <span className="dimmer" style={{ fontSize: 'var(--text-tiny)' }}>
            Editing a profile never changes work it was already stamped on.
          </span>
          <div className="spacer" />
          <button className="btn" onClick={onClose}>
            Done
          </button>
        </div>
      }
    >
      <div className="stack">
        {error ? (
          <div className="field__hint" role="alert">
            {error}
          </div>
        ) : null}

        {profiles.length === 0 && !draft ? (
          <Empty
            title="No profiles yet"
            body="A profile saves a seat's CLI, model, effort and persona under a name you can pick next time."
            action={
              <button className="btn btn--primary" onClick={() => setDraft(BLANK)}>
                <Plus size={12} strokeWidth={2} />
                New profile
              </button>
            }
          />
        ) : null}

        {profiles.map((profile) => (
          <div key={profile.id} className="row" style={{ alignItems: 'baseline' }}>
            <span style={{ fontWeight: 500 }}>{profile.name}</span>
            <Chip>{VENDORS.find((v) => v.vendor === profile.vendor)?.label ?? profile.vendor}</Chip>
            {profile.model ? <Chip>{profile.model}</Chip> : null}
            <Chip>{profile.effort}</Chip>
            {profile.persona ? (
              <span className="dimmer" style={{ fontSize: 'var(--text-tiny)' }} title={profile.persona}>
                {profile.persona}
              </span>
            ) : null}
            <div className="spacer" />
            {confirmingDelete === profile.id ? (
              <>
                <span className="dimmer" style={{ fontSize: 'var(--text-tiny)' }}>
                  Forget it?
                </span>
                <button className="btn btn--sm" onClick={() => void forget(profile.id)}>
                  Forget
                </button>
                <button className="btn btn--subtle btn--sm" onClick={() => setConfirmingDelete(null)}>
                  Keep
                </button>
              </>
            ) : (
              <>
                <button
                  className="btn btn--subtle btn--icon btn--sm"
                  aria-label={`Edit ${profile.name}`}
                  onClick={() => {
                    setError('')
                    setDraft(draftOf(profile))
                  }}
                >
                  <Pencil size={12} strokeWidth={2} />
                </button>
                <button
                  className="btn btn--subtle btn--icon btn--sm"
                  aria-label={`Forget ${profile.name}`}
                  onClick={() => setConfirmingDelete(profile.id)}
                >
                  <Trash2 size={12} strokeWidth={2} />
                </button>
              </>
            )}
          </div>
        ))}

        {draft ? (
          <div className="stack stack--tight">
            <div className="label">{draft.id ? 'Edit profile' : 'New profile'}</div>
            <Field label="Name">
              <input
                className="input"
                placeholder="Fast reviewer"
                value={draft.name}
                autoFocus
                onChange={(event) => setDraft({ ...draft, name: event.target.value })}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') void save()
                }}
              />
            </Field>
            <div className="field-row field-row--3">
              <Field label="CLI">
                <select
                  className="select"
                  value={draft.vendor}
                  onChange={(event) =>
                    // Clearing the model with the CLI, exactly as the seat
                    // picker does: a Codex model slug means nothing to Claude.
                    setDraft({ ...draft, vendor: event.target.value as Vendor, model: '' })
                  }
                >
                  {VENDORS.map((option) => (
                    <option key={option.vendor} value={option.vendor}>
                      {option.label}
                    </option>
                  ))}
                </select>
              </Field>
              <Field
                label="Model"
                hint={draft.vendor === 'agy' ? 'An explicit Gemini model is required.' : undefined}
              >
                <input
                  className="input"
                  placeholder={draft.vendor === 'agy' ? 'Required Gemini model' : 'CLI default'}
                  value={draft.model}
                  onChange={(event) => setDraft({ ...draft, model: event.target.value })}
                />
              </Field>
              <Field label="Effort">
                <select
                  className="select"
                  value={draft.effort}
                  onChange={(event) => setDraft({ ...draft, effort: event.target.value as Effort })}
                >
                  {EFFORTS.map((effort) => (
                    <option key={effort} value={effort}>
                      {effort}
                    </option>
                  ))}
                </select>
              </Field>
            </div>
            <Field>
              <input
                className="input"
                placeholder="Persona (optional)"
                value={draft.persona}
                onChange={(event) => setDraft({ ...draft, persona: event.target.value })}
              />
            </Field>
            <div className="row">
              <button className="btn btn--primary btn--sm" onClick={() => void save()}>
                {draft.id ? 'Save changes' : 'Create profile'}
              </button>
              <button
                className="btn btn--subtle btn--sm"
                onClick={() => {
                  setDraft(null)
                  setError('')
                }}
              >
                Cancel
              </button>
            </div>
          </div>
        ) : profiles.length > 0 ? (
          <button
            className="btn btn--subtle btn--sm"
            style={{ alignSelf: 'flex-start' }}
            onClick={() => {
              setError('')
              setDraft(BLANK)
            }}
          >
            <Plus size={12} strokeWidth={2} />
            New profile
          </button>
        ) : null}
      </div>
    </Dialog>
  )
}
