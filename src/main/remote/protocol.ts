import {
  REMOTE_HELPER_COMMAND,
  REMOTE_PROTOCOL_VERSION,
  REQUIRED_CAPABILITIES,
  type RemoteCapabilities,
  type RemoteRequest,
  type RemoteTarget,
} from '@shared/remote'

/**
 * Reaching a host, and deciding whether it can do the work.
 *
 * Total and synchronous, so the rules can be proven without a network, a host
 * or a helper. Reading and writing frames lives next door in frames.ts, which
 * both ends share.
 */

/**
 * Argv for reaching a target's helper.
 *
 * Read the shape carefully, because it is the security property: every element
 * is a constant or a value from the user's own target record, and the remote
 * command is the bare constant `parley-remote`. Nothing about the run appears
 * here. ssh will hand `parley-remote run` to the remote login shell — that is
 * unavoidable and harmless, because there is nothing in it to interpret.
 *
 * The options are not decoration:
 *  - `BatchMode=yes` makes a missing key an immediate error instead of an
 *    interactive password prompt against a process with no terminal, which
 *    would otherwise look exactly like a hang.
 *  - `StrictHostKeyChecking=yes` refuses an unknown or changed host key rather
 *    than trusting it on first sight. Parley executes code on the other end of
 *    this connection; accepting whatever answers is not a default we get to
 *    have. The user adds the host to known_hosts themselves, deliberately.
 *  - `ExitOnForwardFailure` and the keepalives make a dead connection fail in
 *    seconds rather than hanging until a run's own timeout.
 */
export function sshArgv(target: Pick<RemoteTarget, 'host'>): string[] {
  return [
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=4',
    target.host,
    REMOTE_HELPER_COMMAND,
  ]
}

/** The request body written to the helper's stdin, newline-terminated. */
export function encodeRequest(request: RemoteRequest): string {
  return `${JSON.stringify(request)}\n`
}

export function handshakeRequest(runId: string): RemoteRequest {
  return { version: REMOTE_PROTOCOL_VERSION, operation: 'handshake', runId }
}

/* ------------------------------------------------------------------ */
/* The handshake's verdict                                             */
/* ------------------------------------------------------------------ */

/**
 * Why a target cannot run this plan, or null if it can.
 *
 * Checked BEFORE a snapshot is pushed and before an approval is spent, because
 * every one of these failures is knowable in advance and none of them is worth
 * discovering from a half-finished run.
 *
 * The vendor check distinguishes two failures that look identical from the
 * outside and have opposite fixes. A vendor this BUNDLE does not support means
 * the helper is out of date — upgrade the host's parley-remote. A vendor the
 * bundle supports but the HOST cannot run means the CLI is missing or
 * unconfigured over there — install it and sign in. Collapsing them into "no
 * claude on that host" would send people to fix the wrong machine.
 *
 * What it deliberately does NOT claim: that the subscription works. A config
 * file is evidence of intent, not of a valid session, and probing properly
 * would mean spending. An expired login is an ordinary execution failure and
 * must arrive as one.
 */
export function targetRefusal(
  capabilities: RemoteCapabilities,
  needs: readonly string[],
): string | null {
  if (capabilities.protocolVersion !== REMOTE_PROTOCOL_VERSION) {
    return `the remote helper speaks protocol v${capabilities.protocolVersion}, this Parley speaks v${REMOTE_PROTOCOL_VERSION} — run \`parley remote upgrade\` for that host, or update this Parley`
  }

  // Named abilities are checked separately from the protocol version, because
  // a helper can grow one without the other moving. A helper that cannot
  // mutate should be refused here, not halfway through a mutation stage.
  const declared = new Set(capabilities.capabilities)
  const unsupported = REQUIRED_CAPABILITIES.filter((ability) => !declared.has(ability))
  if (unsupported.length > 0) {
    return `the remote helper (build ${short(capabilities.buildId)}) does not support ${unsupported.join(', ')} — run \`parley remote upgrade\` for that host`
  }

  const wanted = [...new Set(needs)]
  const supported = new Set(capabilities.supportedVendors)
  const outdated = wanted.filter((vendor) => !supported.has(vendor))
  if (outdated.length > 0) {
    return `the remote helper (build ${short(capabilities.buildId)}) has no adapter for ${outdated.join(' or ')} — run \`parley remote upgrade\` for that host`
  }

  const available = new Set(capabilities.availableVendors)
  const missing = wanted.filter((vendor) => !available.has(vendor))
  if (missing.length > 0) {
    return `${missing.map((vendor) => vendorProblem(vendor, capabilities)).join('; ')} — fix that on ${capabilities.user}@${capabilities.home}, then try again`
  }
  return null
}

/** The specific reason one vendor is unusable, so one trip fixes the host. */
function vendorProblem(vendor: string, capabilities: RemoteCapabilities): string {
  const detail = capabilities.vendorDetails[vendor]
  if (!detail || detail.executable === null) {
    // The likeliest cause by far, and the one people lose an afternoon to: a
    // non-interactive ssh session gets a different PATH from a login shell,
    // so nvm/asdf/mise-managed CLIs are simply not there. Say the PATH.
    return `${vendor} was not found on the remote PATH (${capabilities.path})`
  }
  if (!detail.configured) {
    return `${vendor} is installed at ${detail.executable} but has no configuration — sign in there`
  }
  return `${vendor} is present but unusable`
}

function short(buildId: string): string {
  return buildId.slice(0, 12)
}

/**
 * Whether a host is worth reporting on at all, separate from any one plan.
 *
 * Used by `parley remote status`, which should describe a host honestly even
 * when nothing is being run on it.
 */
export function hostWarnings(capabilities: RemoteCapabilities): string[] {
  const warnings: string[] = []
  if (capabilities.git === null) {
    warnings.push('git was not found on the remote PATH — no run can fetch its snapshot')
  }
  const unusable = capabilities.supportedVendors.filter(
    (vendor) => !capabilities.availableVendors.includes(vendor),
  )
  for (const vendor of unusable) warnings.push(vendorProblem(vendor, capabilities))
  for (const [vendor, detail] of Object.entries(capabilities.vendorDetails)) {
    // Surfaced rather than left in the adapter: a host whose agy will execute
    // allow-listed tools without asking is a materially different host to run
    // on, and that should be visible before a run, not after.
    if (detail.permissionMode && detail.permissionMode !== 'ask') {
      warnings.push(`${vendor} on that host is set to "${detail.permissionMode}" — it may act without prompting`)
    }
  }
  return warnings
}
