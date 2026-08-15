import { useEffect, useMemo, useState, type ReactNode } from 'react'
import type { AgentConfig, AgentProfile, Effort, Vendor } from '@shared/domain'
import { eligibleVendors, type SeatRole } from '@shared/vendors'
import { api } from '../lib/api'
import { useStore } from '../state'
import { Field } from './ui'

/**
 * Model suggestions per vendor.
 *
 * Claude and Codex need opposite treatment:
 *
 * **Claude** names families, not versions — `opus` resolves to whatever the
 * latest Opus is (currently `claude-opus-5`). These never go stale, so a fixed
 * list is right.
 *
 * **Codex** names versions — `gpt-5.6-sol`. Any list shipped in this app starts
 * rotting immediately; the previous one offered `gpt-5.1-codex`, which the CLI
 * had already begun *rejecting* as unknown. So the user's own configured model
 * is offered first, read from their `~/.codex/config.toml`, and the fixed
 * entries are only a fallback for someone who has never set one.
 *
 * **Agy** model ids are discovered from the installed CLI, and only eligible
 * `gemini-*` entries reach the datalist.
 *
 * This is a datalist, not a closed dropdown: anything the CLI accepts can be
 * typed. Blank means "let the CLI choose" except for Agy, which requires an
 * explicit Gemini model.
 */
const MODEL_HINTS: Record<Vendor, string[]> = {
  claude: ['opus', 'sonnet', 'haiku', 'fable'],
  codex: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'],
  agy: [],
}

/** Exported so the roster offers exactly the seat vocabulary a picker does. */
export const EFFORTS: Effort[] = ['low', 'medium', 'high', 'xhigh', 'max']
export const VENDORS = [
  { vendor: 'claude', label: 'Claude Code' },
  { vendor: 'codex', label: 'Codex' },
  { vendor: 'agy', label: 'Agy' },
] as const satisfies ReadonlyArray<{ vendor: Vendor; label: string }>

export function AgentPicker({
  label,
  value,
  onChange,
  personaPlaceholder,
  role,
  toolFree = false,
}: {
  label: string
  value: AgentConfig
  onChange: (next: AgentConfig) => void
  personaPlaceholder?: string
  role: SeatRole
  toolFree?: boolean
}): ReactNode {
  const { state } = useStore()
  const [profiles, setProfiles] = useState<AgentProfile[]>([])
  const [saving, setSaving] = useState(false)
  const [saveName, setSaveName] = useState('')
  const [saveError, setSaveError] = useState('')

  useEffect(() => {
    let cancelled = false
    void api
      .listAgentProfiles()
      .then((rows) => {
        // The same guard RunRoom carries: a bridge that answers with nothing
        // must produce an empty picker, not a crashed one.
        if (!cancelled) setProfiles(Array.isArray(rows) ? rows : [])
      })
      .catch(() => {
        // Profiles are a convenience; a picker with none is still a picker.
      })
    return () => {
      cancelled = true
    }
  }, [])

  /**
   * A hand edit ends the profile.
   *
   * The stamp means "this seat IS that profile", and a config that has
   * drifted from it is not. Keeping the name on an edited config would put a
   * profile's name on work it never described — the journal would then say
   * "Fast reviewer" about a seat someone had quietly retuned.
   */
  const edit = (patch: Partial<AgentConfig>): void => {
    const next = { ...value, ...patch }
    delete next.profile
    onChange(next)
  }

  const applyProfile = (name: string): void => {
    const chosen = profiles.find((profile) => profile.name === name)
    if (!chosen) return
    onChange({
      vendor: chosen.vendor,
      model: chosen.model,
      effort: chosen.effort,
      persona: chosen.persona,
      profile: chosen.name,
    })
  }

  const saveProfile = async (): Promise<void> => {
    const name = saveName.trim()
    if (!name) return
    try {
      const created = await api.addAgentProfile({
        name,
        vendor: value.vendor,
        model: value.model,
        effort: value.effort,
        persona: value.persona,
      })
      setProfiles((rows) => [...rows, created].sort((a, b) => a.name.localeCompare(b.name)))
      setSaving(false)
      setSaveName('')
      setSaveError('')
      // The seat becomes the profile it was just saved as.
      onChange({ ...value, profile: created.name })
    } catch (error) {
      // Almost always the unique name; the exact words come from the store.
      setSaveError(error instanceof Error ? error.message : String(error))
    }
  }

  const listId = `models-${value.vendor}`
  const eligible = useMemo(
    () => eligibleVendors(role, toolFree),
    [role, toolFree],
  )
  const vendorEligible = eligible.includes(value.vendor)

  useEffect(() => {
    if (vendorEligible) return
    const fallback = eligible[0]
    if (fallback) {
      const next = { ...value, vendor: fallback, model: '' }
      delete next.profile
      onChange(next)
    }
  }, [eligible, onChange, value, vendorEligible])

  // The configured model leads, so the first thing offered is one this machine
  // demonstrably accepts.
  const configured = value.vendor === 'codex' ? state.codexDefaultModel : ''
  const discovered = value.vendor === 'agy' ? state.agyModels : MODEL_HINTS[value.vendor]
  const suggestions = [
    ...(configured ? [configured] : []),
    ...discovered.filter((m) => m !== configured),
  ]

  return (
    <div className="stack stack--tight">
      <div className="label">{label}</div>

      {profiles.length > 0 || saving ? (
        <div className="field-row">
          <Field label="Profile">
            <select
              className="select"
              value={value.profile ?? ''}
              onChange={(event) => {
                if (event.target.value) applyProfile(event.target.value)
              }}
            >
              {/* A blank first option, because "no profile" is the normal
                  state and a select that cannot express it would stamp one on
                  every seat that merely opened the menu. A hand edit clears
                  the stamp, so the select falls back here on its own. */}
              <option value="">None</option>
              {profiles.map((profile) => (
                <option key={profile.id} value={profile.name}>
                  {profile.name}
                </option>
              ))}
            </select>
          </Field>
          {saving ? (
            <Field label="Save as" hint={saveError || undefined}>
              <div className="row">
                <input
                  className="input"
                  placeholder="Profile name"
                  value={saveName}
                  autoFocus
                  onChange={(event) => setSaveName(event.target.value)}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') void saveProfile()
                    if (event.key === 'Escape') setSaving(false)
                  }}
                />
                <button className="btn btn--sm" onClick={() => void saveProfile()}>
                  Save
                </button>
              </div>
            </Field>
          ) : null}
        </div>
      ) : null}

      <div className="field-row field-row--3">
        <Field label="CLI">
          <select
            className="select"
            value={value.vendor}
            onChange={(event) => edit({ vendor: event.target.value as Vendor, model: '' })}
          >
            {VENDORS.filter(({ vendor }) => eligible.includes(vendor)).map((option) => (
              <option key={option.vendor} value={option.vendor}>
                {option.label}
              </option>
            ))}
          </select>
        </Field>

        <Field
          label="Model"
          hint={
            value.vendor === 'claude'
              ? 'Aliases track the latest of each family.'
              : value.vendor === 'agy'
                ? 'An explicit Gemini model is required.'
              : configured
                ? `Your codex default is ${configured}.`
                : undefined
          }
        >
          <input
            className="input"
            list={listId}
            placeholder={
              value.vendor === 'agy' ? 'Required Gemini model' : configured || 'CLI default'
            }
            value={value.model}
            onChange={(event) => edit({ model: event.target.value })}
          />
          <datalist id={listId}>
            {suggestions.map((model) => (
              <option key={model} value={model} />
            ))}
          </datalist>
        </Field>

        <Field label="Effort">
          <select
            className="select"
            value={value.effort}
            onChange={(event) => edit({ effort: event.target.value as Effort })}
          >
            {EFFORTS.map((effort) => (
              <option key={effort} value={effort}>
                {effort}
              </option>
            ))}
          </select>
        </Field>
      </div>

      {!saving ? (
        <button
          type="button"
          className="btn btn--subtle btn--sm"
          style={{ alignSelf: 'flex-start' }}
          onClick={() => {
            setSaving(true)
            setSaveName(value.profile ?? '')
          }}
        >
          Save as profile…
        </button>
      ) : null}

      <Field>
        <input
          className="input"
          placeholder={personaPlaceholder ?? 'Persona (optional)'}
          value={value.persona}
          onChange={(event) => edit({ persona: event.target.value })}
        />
      </Field>
    </div>
  )
}

export const defaultAgentA: AgentConfig = { vendor: 'claude', model: '', effort: 'high', persona: '' }
export const defaultAgentB: AgentConfig = { vendor: 'codex', model: '', effort: 'high', persona: '' }
