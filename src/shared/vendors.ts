import type { Vendor } from './domain'

const VENDORS = ['claude', 'codex', 'agy'] as const satisfies readonly Vendor[]

/** A vendor Parley can only dispatch without repository tools. */
export function isToolless(vendor: Vendor): boolean {
  return vendor === 'agy'
}

/**
 * Picks an independent vendor without ever selecting one that cannot perform
 * the tool-using check the counterpart role exists for.
 */
export function pickCounterpart(
  from: Vendor,
  toolless: (vendor: Vendor) => boolean = isToolless,
): Vendor {
  const counterpart = VENDORS.find((vendor) => vendor !== from && !toolless(vendor))
  if (counterpart) return counterpart

  const fallback = VENDORS.find((vendor) => !toolless(vendor))
  if (fallback) return fallback

  throw new Error('no tool-capable vendor is available')
}

export type SeatRole =
  | 'debate-seat'
  | 'review-seat'
  | 'planner'
  | 'executor'
  | 'reviewer'
  | 'loop-worker'
  | 'loop-verifier'
  | 'foreman'

export interface VendorSeat {
  vendor: Vendor
  role: SeatRole
  /** True only when this exact seat will be dispatched at capability `none`. */
  toolFree: boolean
}

/**
 * Returns every tool-less seat that the requested workflow cannot safely
 * dispatch. A tool-less vendor is admitted only to a genuinely tool-free
 * debate seat; `none` on any other workflow does not make that role eligible.
 */
export function seatingRefusals(seats: readonly VendorSeat[]): string[] {
  return seats
    .filter(
      (seat) =>
        isToolless(seat.vendor) && (seat.role !== 'debate-seat' || !seat.toolFree),
    )
    .map(({ vendor, role }) => {
      const label = role.replaceAll('-', ' ')
      return `${vendor} is tool-less in Parley and cannot serve as ${label}; it is available only for a tool-free debate seat`
    })
}

/** Vendors the selected workflow can actually dispatch for this seat. */
export function eligibleVendors(role: SeatRole, toolFree: boolean): Vendor[] {
  return VENDORS.filter(
    (vendor) => seatingRefusals([{ vendor, role, toolFree }]).length === 0,
  )
}
