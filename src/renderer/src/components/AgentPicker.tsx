import { useEffect, useMemo, type ReactNode } from 'react'
import type { AgentConfig, Effort, Vendor } from '@shared/domain'
import { seatingRefusals, type SeatingRole } from '@shared/vendors'
import { useStore } from '../state'
import { Field } from './ui'

/**
 * Model suggestions per vendor.
 *
 * The two CLIs need opposite treatment:
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
 * Either way this is a datalist, not a closed dropdown: anything the CLI accepts
 * can be typed, and blank means "let the CLI choose".
 */
const MODEL_HINTS: Record<Vendor, string[]> = {
  claude: ['opus', 'sonnet', 'haiku', 'fable'],
  codex: ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna'],
  agy: [
    'gemini-3-pro',
    'gemini-3-flash-high',
    'gemini-3-flash-medium',
    'gemini-3-flash-low',
  ],
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
  role: SeatingRole
  toolFree?: boolean
}): ReactNode {
  const { state } = useStore()
  const listId = `models-${value.vendor}`
  const eligibleVendors = useMemo(
    () =>
      VENDORS.filter(
        ({ vendor }) => !seatingRefusals([{ vendor, role, toolFree }]).length,
      ),
    [role, toolFree],
  )
  const eligible = eligibleVendors.some(({ vendor }) => vendor === value.vendor)

  useEffect(() => {
    if (eligible) return
    const fallback = eligibleVendors[0]?.vendor
    if (fallback) onChange({ ...value, vendor: fallback, model: '' })
  }, [eligible, eligibleVendors, onChange, value])

  // The configured model leads, so the first thing offered is one this machine
  // demonstrably accepts.
  const configured = value.vendor === 'codex' ? state.codexDefaultModel : ''
  const suggestions = [
    ...(configured ? [configured] : []),
    ...(MODEL_HINTS[value.vendor] ?? []).filter((m) => m !== configured),
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
            {eligibleVendors.map(({ vendor, label: vendorLabel }) => (
              <option key={vendor} value={vendor}>
                {vendorLabel}
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
