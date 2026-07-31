import { REMOTE_NODE_FLOOR, REMOTE_PROTOCOL_VERSION, type RemoteCapabilities } from '@shared/remote'
import { hostWarnings } from './protocol'

/**
 * What is actually installed on a host, and whether it can be trusted.
 *
 * The load-bearing rule is that every check runs against ONE resolved path.
 * Status reads the active symlink once, resolves it to a versioned bundle, and
 * then hashes and interrogates that exact file. Re-invoking the symlink partway
 * through would let an upgrade land in the middle of an inspection: hash the
 * old directory, question the new bundle, and report corruption from two
 * individually perfect installations. Version directories are retained, so the
 * resolved path stays valid for the whole inspection without needing the
 * activation lock.
 */

export type RemoteHealth = 'not-installed' | 'corrupt' | 'incompatible' | 'degraded' | 'healthy'

export interface StatusFacts {
  /** What the symlink pointed at, read exactly once. */
  activeTarget: string | null
  /** The build id taken from the versioned directory's NAME. */
  directoryBuildId: string | null
  /** SHA-256 of the bytes at the resolved path, computed on the host. */
  calculatedHash: string | null
  /** What that same file said about itself when invoked. Null if it would not run. */
  capabilities: RemoteCapabilities | null
  /** The command configured for this target, and whether it could start node. */
  nodeCommand: string
  nodeUsable: boolean
  /** A previous build recorded at activation time — never inferred from timestamps. */
  previousAvailable: boolean
}

export interface RemoteStatus {
  health: RemoteHealth
  /** Why, most important first. Empty only when healthy. */
  reasons: string[]
  facts: StatusFacts
}

/**
 * The verdict.
 *
 * Priority is fixed and checked in order, because these are not independent
 * observations — a host with no runner cannot also be incompatible, and a
 * corrupt bundle's self-report is not worth comparing against anything. The
 * order also decides what a human is told first, which is the point.
 */
export function statusVerdict(facts: StatusFacts): RemoteStatus {
  const reasons: string[] = []

  if (!facts.activeTarget) {
    return {
      health: 'not-installed',
      reasons: ['no parley-remote is active on this host'],
      facts,
    }
  }

  // Corrupt means the three answers to "which build is this" disagree. Any
  // disagreement makes every other check meaningless, so it is asked first.
  const identities = [facts.directoryBuildId, facts.calculatedHash, facts.capabilities?.buildId]
  const known = identities.filter((value): value is string => typeof value === 'string' && value !== '')
  if (facts.calculatedHash && facts.directoryBuildId && facts.calculatedHash !== facts.directoryBuildId) {
    reasons.push(
      `the installed bytes hash to ${short(facts.calculatedHash)} but sit in a directory named ${short(facts.directoryBuildId)}`,
    )
  }
  if (facts.capabilities && facts.calculatedHash && facts.capabilities.buildId !== facts.calculatedHash) {
    reasons.push(
      `the runner reports build ${short(facts.capabilities.buildId)} but its file hashes to ${short(facts.calculatedHash)}`,
    )
  }
  if (known.length > 1 && new Set(known).size > 1 && reasons.length > 0) {
    return { health: 'corrupt', reasons, facts }
  }

  // A perfectly intact bundle that cannot be executed is not corrupt — the
  // configured runtime is the problem, and telling someone their install is
  // corrupt would send them to reinstall a file that is exactly right.
  if (!facts.nodeUsable) {
    return {
      health: 'incompatible',
      reasons: [
        `the configured node command (${facts.nodeCommand}) could not be started on this host`,
        'non-interactive ssh sessions often miss nvm, asdf and mise — configure an absolute node path for this target',
      ],
      facts,
    }
  }

  if (!facts.capabilities) {
    return {
      health: 'incompatible',
      reasons: ['the installed runner did not answer a handshake'],
      facts,
    }
  }

  if (facts.capabilities.protocolVersion !== REMOTE_PROTOCOL_VERSION) {
    return {
      health: 'incompatible',
      reasons: [
        `the installed runner speaks protocol v${facts.capabilities.protocolVersion}, this Parley speaks v${REMOTE_PROTOCOL_VERSION}`,
      ],
      facts,
    }
  }

  const major = Number.parseInt((facts.capabilities.nodeVersion || 'v0').slice(1).split('.')[0] ?? '0', 10)
  if (!Number.isFinite(major) || major < REMOTE_NODE_FLOOR) {
    return {
      health: 'incompatible',
      reasons: [
        `the runner is running on ${facts.capabilities.nodeVersion}, below the Node ${REMOTE_NODE_FLOOR} floor`,
      ],
      facts,
    }
  }

  // Degraded is "this will work, but not for everything" — a missing agent, a
  // probe that timed out, a permissive posture worth knowing about.
  const host = hostWarnings(facts.capabilities)
  if (host.length > 0) return { health: 'degraded', reasons: host, facts }

  return { health: 'healthy', reasons: [], facts }
}

/**
 * Whether the runtime that answered is the one that was configured.
 *
 * Only meaningful for an absolute command. When the target simply says `node`,
 * the resolved execPath is worth reporting and worth nothing as a comparison —
 * treating the string difference as a problem would flag every correctly
 * configured host on earth.
 */
export function runtimeMismatch(nodeCommand: string, execPath: string | undefined): string | null {
  if (!nodeCommand.startsWith('/') || !execPath) return null
  if (nodeCommand === execPath) return null
  return `configured node is ${nodeCommand} but the runner is executing under ${execPath}`
}

function short(buildId: string): string {
  return buildId.slice(0, 12)
}
