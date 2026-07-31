/**
 * The remote execution protocol.
 *
 * Parley can run a milestone on another machine. The boundary is deliberately
 * transactional rather than conversational: the local side submits ONE
 * immutable snapshot of the tree to execute, the remote side runs the ENTIRE
 * milestone pipeline inside its own isolated worktree, and one validated
 * result plus a separate evidence bundle comes back. Nothing about the run
 * straddles two filesystems, because a pipeline whose commands see one tree
 * while its containment checks inspect another has no guarantees at all — it
 * has a race with good manners.
 *
 * Four properties this file exists to protect:
 *
 * **Nothing dynamic is ever interpolated into the ssh command line.** The
 * remote command is a compile-time constant. Every value that varies — the
 * run id, the refs, the plan, argv, cwd, environment — travels as JSON on
 * stdin and is handed to the remote's own spawn as an argv array. OpenSSH
 * joins a remote command's arguments with spaces and feeds the string to the
 * remote login shell, so argv does not survive the wire; the answer is to send
 * no argv over the wire at all. `isShellFree` keeps meaning what it means.
 *
 * **Everything is framed and sequenced.** The helper's stdout carries protocol
 * frames only — a child process's output is wrapped in one, never written raw
 * to the same stream, or one test printing `{` at the wrong moment would turn
 * the protocol into soup. Each frame carries the run it belongs to and a
 * sequence number so a receiver can deduplicate. That matters BEFORE
 * reconnection exists, not after: a connection that dies between the remote
 * emitting a fact and learning it was received will resend, and a protocol
 * without identity has no way to notice. Adding these fields later would
 * change every message. The ssh process's own stderr stays reserved for
 * failures where the helper could not start or could not speak at all.
 *
 * **Omission and null are different instructions.** A fact that omits
 * `completedAt` leaves the stamp alone; one that sends null clears it. JSON
 * drops undefined, which is the behaviour we want — but only if the receiving
 * side tests for PRESENCE rather than for undefined.
 *
 * **The local environment never travels.** The remote process inherits the
 * remote user's environment plus a small, explicitly allowed overlay. Sending
 * process.env would transport cloud credentials, API keys, session tokens and
 * paths that mean nothing over there.
 *
 * Lives in shared because the renderer must describe a target and its
 * capabilities before you approve a run on it, not after.
 */

/**
 * Bumped when a change would make an older helper misread a request, never for
 * additive optional fields. The handshake compares this against the helper's
 * own; a mismatch is refused before anything is pushed or spent.
 */
export const REMOTE_PROTOCOL_VERSION = 1

/**
 * The command invoked on the remote host. A constant, with no arguments that
 * vary by run — see the note above about ssh and argv.
 */
export const REMOTE_HELPER_COMMAND = 'parley-remote'

/** The bundle is one file with no runtime npm dependencies. This is its floor. */
export const REMOTE_NODE_FLOOR = 20

/** Ref namespace for a run's transported states. Never user-visible history. */
export const RUN_REF_PREFIX = 'refs/parley/runs'

export function inputRefFor(runId: string): string {
  return `${RUN_REF_PREFIX}/${runId}/input`
}

export function resultRefFor(runId: string): string {
  return `${RUN_REF_PREFIX}/${runId}/result`
}

/* ------------------------------------------------------------------ */
/* Requests                                                            */
/* ------------------------------------------------------------------ */

export type RemoteOperation = 'handshake' | 'run' | 'cancel' | 'cleanup'

export interface RemoteRepositorySpec {
  /** Where the helper fetches the input snapshot from, as the remote sees it. */
  remote: string
  inputRef: string
  /**
   * The commit the input ref must resolve to after fetching. The helper
   * refuses if it does not match: a ref is a name and names move, and the
   * whole point of the snapshot is that it is immutable.
   */
  expectedCommit: string
}

/**
 * The milestone state the execution core actually consumes.
 *
 * Deliberately not the database row. Sending the whole record because it is
 * convenient would put every column on the wire and make each schema change a
 * protocol change; it would also ship fields the core never reads to a machine
 * that has no business holding them.
 *
 * `recordVersion` is what makes replay safe. The remote reports facts against
 * the state it was given, and if the local record has moved on since — a human
 * stopped the run, an adopt landed, the plan was re-drafted — those facts are
 * true about a state that no longer exists. Replay rejects them rather than
 * writing a truthful report onto the wrong row.
 */
export interface RemoteMilestoneContext {
  milestoneId: string
  planId: string
  status: string
  /** Serialised run state: where an interrupted run would resume from. */
  checkpoint: unknown | null
  narrative: string | null
  verification: unknown | null
  recordVersion: number
}

export interface RemoteRunSpec {
  context: RemoteMilestoneContext
  /** The plan fields the core reads — executor, reviewer, isolation, caps. */
  plan: unknown
  /** The milestone definition itself: intent, files, test command, mutations. */
  milestone: unknown
}

/**
 * Environment variables a request may never set.
 *
 * Every one of these would let a request reach past the protocol and change
 * how the runner itself behaves: relocate the home directory the agent CLIs
 * read their credentials from, redirect git at another repository, or inject
 * code into every process the runner spawns. The runner owns them.
 */
export const FORBIDDEN_ENV = [
  'HOME',
  'PATH',
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_CONFIG_GLOBAL',
  'GIT_SSH_COMMAND',
  'LD_PRELOAD',
  'DYLD_INSERT_LIBRARIES',
  'NODE_OPTIONS',
]

export interface RemoteRequest {
  version: number
  operation: RemoteOperation
  runId: string
  repository?: RemoteRepositorySpec
  run?: RemoteRunSpec
  /**
   * A small overlay on the REMOTE user's environment — never a copy of this
   * machine's. Secrets get their own declared mechanism when they are needed;
   * they must not arrive by generic forwarding.
   */
  env?: Record<string, string>
}

/** Strips anything a request may not set. Applied on both sides, deliberately. */
export function safeEnvOverlay(env: Record<string, string> | undefined): Record<string, string> {
  if (!env) return {}
  const forbidden = new Set(FORBIDDEN_ENV)
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(env)) {
    if (forbidden.has(key.toUpperCase())) continue
    out[key] = value
  }
  return out
}

/* ------------------------------------------------------------------ */
/* What a host can actually do                                         */
/* ------------------------------------------------------------------ */

export interface RemoteVendorDetail {
  /** Absolute path as the runner resolved it, or null when nothing was found. */
  executable: string | null
  version: string | null
  /** The CLI's own config was found. NOT a promise that the subscription works. */
  configured: boolean
  /**
   * The permission posture the runner observed, when the CLI has one worth
   * naming. Surfaced rather than buried in an adapter: a host whose agy will
   * execute allow-listed tools is a materially different host to run on.
   */
  permissionMode: string | null
}

/**
 * What the helper reports before any work is dispatched.
 *
 * The distinction that earns its place here is supported vs available.
 * "This bundle knows how to drive codex" and "codex is usable on this host"
 * are different facts, and collapsing them into one list makes every failure
 * ambiguous — you cannot tell an out-of-date bundle from an unprovisioned host.
 */
export interface RemoteCapabilities {
  /**
   * What the helper can SPEAK. Compared against REMOTE_PROTOCOL_VERSION.
   * Deliberately separate from buildId: two different builds may correctly
   * implement the same protocol, and conflating them would either refuse a
   * good helper or accept an incompatible one.
   */
  protocolVersion: number
  /**
   * What the helper IS: the SHA-256 of the bundle, computed by the runner
   * hashing its own file at startup. Identity, not compatibility.
   */
  buildId: string
  nodeVersion: string
  nodeExecutable: string
  /** Named abilities, so a helper can grow without a protocol bump. */
  capabilities: string[]
  /** Adapters this bundle contains. */
  supportedVendors: string[]
  /** Of those, the ones this host can actually run. */
  availableVendors: string[]
  vendorDetails: Record<string, RemoteVendorDetail>
  /** Who the run would execute as, and whose CLI credentials it would use. */
  user: string
  home: string
  /**
   * The PATH a non-interactive ssh session actually gets. Reported because it
   * is usually different from an interactive one — nvm, asdf and mise all live
   * in shell startup files a non-interactive session never reads — and "it
   * works in my ssh terminal" is the single most likely support question.
   */
  path: string
  git: string | null
  runsRoot: string
}

/** The abilities a v1 milestone run needs a helper to declare. */
export const REQUIRED_CAPABILITIES = ['git-worktree', 'pipeline-v1', 'mutation', 'evidence']

/* ------------------------------------------------------------------ */
/* Frames                                                              */
/* ------------------------------------------------------------------ */

export interface RemoteEvidenceManifest {
  /** The commit the milestone produced, published at the result ref. */
  resultCommit: string | null
  /** The snapshot it was executed against; the local side re-checks ancestry. */
  baseCommit: string
  /**
   * Paths the remote observed as changed. The local side reconciles the
   * fetched result against this independently — a second guard that costs
   * almost nothing and would catch a helper that lied or a ref that moved.
   */
  changedPaths: string[]
  /** Where logs and artifacts live on the remote. Never in the result tree. */
  artifactsPath: string | null
}

export type RemoteBody =
  | { type: 'ready'; capabilities: RemoteCapabilities }
  /** A child process's output, attributed. Never raw on the wire. */
  | { type: 'stdout'; processId: string; data: string }
  | { type: 'stderr'; processId: string; data: string }
  | { type: 'exit'; processId: string; code: number; signal: string | null }
  /** Progress worth showing a human. Never persisted. */
  | { type: 'progress'; phase: string; text: string }
  /**
   * One thing the execution core observed. Deliberately a fact, not a store
   * write: the core reports what happened and each side decides what that
   * means, so the protocol never depends on the shape of anybody's database.
   */
  | { type: 'fact'; fact: unknown }
  | { type: 'result'; outcome: 'complete' | 'failed'; manifest: RemoteEvidenceManifest }
  /** The helper could speak, and is telling us it cannot continue. */
  | { type: 'error'; message: string; retryable: boolean }

/**
 * Every line the helper writes.
 *
 * `sequence` is monotonic within a run and starts at 1. It exists so a
 * receiver can deduplicate: the moment reconnection is possible, a frame the
 * remote sent but could not confirm will arrive twice, and a record written
 * twice from one observation is a corrupted record. The remote also journals
 * its frames per run, so a future reconnect can ask to resume after a
 * sequence rather than replay a whole milestone.
 */
export interface RemoteFrame {
  protocolVersion: number
  runId: string
  sequence: number
  body: RemoteBody
}

/* ------------------------------------------------------------------ */
/* Targets                                                             */
/* ------------------------------------------------------------------ */

/**
 * An execution target the user has configured. `host` is an ssh destination as
 * ssh itself understands it (an alias from ~/.ssh/config is the recommended
 * form — it keeps identity files, ports and jump hosts in the place that
 * already owns them rather than duplicating them into Parley's record).
 */
export interface RemoteTarget {
  id: string
  label: string
  host: string
  /** Where the helper may create run worktrees. Validated remotely too. */
  runsRoot: string
  createdAt: number
}

/** The shape a run's outcome takes once it is back on this machine. */
export type RemoteRunOutcome =
  | { status: 'complete'; manifest: RemoteEvidenceManifest }
  | { status: 'failed'; manifest: RemoteEvidenceManifest | null; detail: string }
  /** The transport died. Distinct from failure: the run may have SUCCEEDED. */
  | { status: 'disconnected'; detail: string }
  | { status: 'cancelled'; detail: string }
