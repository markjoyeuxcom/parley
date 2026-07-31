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
 * Two properties this file exists to protect:
 *
 * **Nothing dynamic is ever interpolated into the ssh command line.** The
 * remote command is a compile-time constant. Every value that varies — the
 * run id, the refs, the plan, argv, cwd, environment — travels as JSON on
 * stdin and is handed to the remote's own spawn as an argv array. OpenSSH
 * joins a remote command's arguments with spaces and feeds the string to the
 * remote login shell, so argv does not survive the wire; the answer is to send
 * no argv over the wire at all. `isShellFree` keeps meaning what it means.
 *
 * **Output is framed.** The helper's stdout carries protocol messages only. A
 * child process's stdout is wrapped in a message, never written raw to the
 * same stream — one test printing `{` at the wrong moment would otherwise turn
 * the protocol into soup. The ssh process's own stderr stays reserved for
 * failures where the helper could not start or could not speak the protocol,
 * which is exactly the class of failure that has no in-band representation.
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
 * What the remote needs to execute a milestone. Deliberately the milestone
 * itself and its plan's execution-relevant fields — NOT the record. Parley's
 * record stays on the user's machine; the remote is an execution appliance
 * that is told what to run, not a second copy of the truth.
 */
export interface RemoteRunSpec {
  planId: string
  milestoneId: string
  /** Serialised milestone + the plan fields the pipeline reads. */
  payload: unknown
}

export interface RemoteRequest {
  version: number
  operation: RemoteOperation
  runId: string
  repository?: RemoteRepositorySpec
  run?: RemoteRunSpec
  /**
   * Allow-listed environment for the remote pipeline. Never the local
   * environment wholesale: it carries this machine's PATH, tokens and
   * home-directory assumptions, none of which are true over there.
   */
  env?: Record<string, string>
}

/* ------------------------------------------------------------------ */
/* Events                                                              */
/* ------------------------------------------------------------------ */

/**
 * Capabilities the helper reports before any work is dispatched.
 *
 * `vendors` is load-bearing: a target without the plan's executor CLI
 * installed and signed in cannot run the plan, and discovering that after
 * pushing a snapshot and spending an approval is the expensive way to find
 * out. Parley refuses at the gate instead.
 */
export interface RemoteCapabilities {
  version: number
  helperVersion: string
  /** Vendor slugs the remote can actually run, with the versions it found. */
  vendors: Array<{ vendor: string; version: string }>
  /** Absolute path under which the helper creates run worktrees. */
  runsRoot: string
  git: string
}

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
  /** Where logs and artifacts live on the remote, by run id. Never in the result tree. */
  artifactsPath: string | null
}

export type RemoteEvent =
  | { type: 'ready'; capabilities: RemoteCapabilities }
  /** A child process's output, attributed. Never raw on the wire. */
  | { type: 'stdout'; processId: string; data: string }
  | { type: 'stderr'; processId: string; data: string }
  | { type: 'exit'; processId: string; code: number; signal: string | null }
  /** Pipeline progress, mapped locally onto the same record writes as a local run. */
  | { type: 'progress'; phase: string; text: string }
  /** One store write the local side must make on the remote's behalf. */
  | { type: 'report'; report: unknown }
  | { type: 'result'; outcome: 'complete' | 'failed'; manifest: RemoteEvidenceManifest }
  /** The helper could speak, and is telling us it cannot continue. */
  | { type: 'error'; message: string; retryable: boolean }

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
