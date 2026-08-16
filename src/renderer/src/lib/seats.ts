import type { Effort, Vendor } from '@shared/domain'

/**
 * The seat vocabulary a person picks from.
 *
 * Lived in the seat picker until the governed dialogs were deleted; it is
 * shared by the roster and by anything else that offers a CLI, and a list
 * this small is not worth a component to own.
 */
export const EFFORTS: Effort[] = ['low', 'medium', 'high', 'xhigh', 'max']

export const VENDORS = [
  { vendor: 'claude', label: 'Claude Code' },
  { vendor: 'codex', label: 'Codex' },
  { vendor: 'agy', label: 'Agy' },
] as const satisfies ReadonlyArray<{ vendor: Vendor; label: string }>
