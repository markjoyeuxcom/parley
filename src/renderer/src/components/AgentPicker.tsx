import { useEffect, useMemo, type ReactNode } from 'react'
import type { AgentConfig, Effort, Vendor } from '@shared/domain'
import { eligibleVendors, type SeatRole } from '@shared/vendors'
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

const EFFORTS: Effort[] = ['low', 'medium', 'high', 'xhigh', 'max']
const VENDORS = [
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
  const listId = `models-${value.vendor}`
  const eligible = useMemo(
    () => eligibleVendors(role, toolFree),
    [role, toolFree],
  )
  const vendorEligible = eligible.includes(value.vendor)

  useEffect(() => {
    if (vendorEligible) return
    const fallback = eligible[0]
    if (fallback) onChange({ ...value, vendor: fallback, model: '' })
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

      <div className="field-row field-row--3">
        <Field label="CLI">
          <select
            className="select"
            value={value.vendor}
            onChange={(event) => onChange({ ...value, vendor: event.target.value as Vendor, model: '' })}
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
            onChange={(event) => onChange({ ...value, model: event.target.value })}
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
            onChange={(event) => onChange({ ...value, effort: event.target.value as Effort })}
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
          placeholder={personaPlaceholder ?? 'Persona (optional)'}
          value={value.persona}
          onChange={(event) => onChange({ ...value, persona: event.target.value })}
        />
      </Field>
    </div>
  )
}

export const defaultAgentA: AgentConfig = { vendor: 'claude', model: '', effort: 'high', persona: '' }
export const defaultAgentB: AgentConfig = { vendor: 'codex', model: '', effort: 'high', persona: '' }
