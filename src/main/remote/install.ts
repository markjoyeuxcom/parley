import { randomBytes } from 'node:crypto'
import type { RemoteTarget } from '@shared/remote'
import { BIN_DIR, INSTALL_ROOT, isBoringPath, LINK_NAME, bootstrapArgument } from './bootstrap'

/**
 * Putting the runner on a host, and telling you what is actually there.
 *
 * Three boundaries, and the point of the design is that the ssh command line
 * is a constant at every one of them:
 *
 *   SFTP                  — moves opaque bytes to a constrained path
 *   node -e <constant>    — verifies, handshakes, activates
 *   parley-remote         — status, and every real run afterwards
 *
 * SFTP rather than scp deliberately. Modern scp speaks SFTP, but only since
 * OpenSSH 9.0, and `-O` puts it back to remote-shell path handling with all
 * the quoting hazards that implies. Depending on that would mean also
 * depending on a client version floor and on nobody ever passing a flag.
 * `sftp -b -` says what it means, and its batch mode aborts on the first
 * failed operation rather than carrying on into a half-installed state.
 */

export interface InstallPaths {
  /** Sibling of the final directory, so the activation rename cannot cross a filesystem. */
  stagingDir: string
  stagedBundle: string
  nonce: string
}

/**
 * Where an upload goes while it is still unproven.
 *
 * Inside the install root, never /tmp. That is the whole reason the staging
 * directory is a sibling: rename(2) is only atomic within a filesystem, and
 * `/tmp` is very often a different one — so staging there would give an
 * activation that looks atomic, passes review, and is not.
 */
export function stagingFor(nonce: string): InstallPaths {
  const stagingDir = `${INSTALL_ROOT}/.install-${nonce}`
  return { stagingDir, stagedBundle: `${stagingDir}/parley-remote.mjs`, nonce }
}

export function newNonce(): string {
  return randomBytes(8).toString('hex')
}

/**
 * The SFTP batch script.
 *
 * `-mkdir` because a leading minus tells sftp to tolerate that one failing —
 * the parent directories may well already exist, and that is not an error.
 * Everything after it is unprefixed, so any real failure aborts the batch and
 * leaves the existing installation untouched.
 */
export function sftpBatch(localBundle: string, paths: InstallPaths): string {
  for (const path of [paths.stagingDir, paths.stagedBundle]) {
    if (!isBoringPath(path)) throw new Error(`refusing an install path that is not boring: ${path}`)
  }
  return [
    `-mkdir ${INSTALL_ROOT.split('/').slice(0, 1).join('/')}`,
    `-mkdir .local/lib`,
    `-mkdir .local/lib/parley`,
    `-mkdir ${INSTALL_ROOT}`,
    `-mkdir ${BIN_DIR}`,
    `mkdir ${paths.stagingDir}`,
    `put ${localBundle} ${paths.stagedBundle}`,
    'quit',
    '',
  ].join('\n')
}

/** argv for the upload. The batch itself arrives on stdin, not as an argument. */
export function sftpArgv(target: Pick<RemoteTarget, 'host'>): string[] {
  return [
    '-b',
    '-',
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    target.host,
  ]
}

/**
 * argv for the bootstrap.
 *
 * Every element is a compile-time constant. The path just uploaded, the hash
 * to check it against and the operation all travel as JSON on stdin — which is
 * the same rule the runner follows, applied to the one stretch of the process
 * where the runner does not exist yet.
 *
 * `nodeCommand` is the single value a target may vary here, and it is a narrow,
 * deliberate exception: a host where node is not on the non-interactive PATH
 * cannot be bootstrapped at all otherwise, and that is a common enough setup
 * (nvm, asdf, mise) to be worth solving rather than refusing. It is validated
 * against the boring grammar, it comes from the user's own target
 * configuration rather than from any run, and it is constant per target.
 */
/**
 * A command name or an absolute path to one, and nothing else.
 *
 * Separate from {@link isBoringPath} because the two answer different
 * questions: an install path must stay under the home directory, while a node
 * command is very often absolute — /opt/node20/bin/node is exactly the case
 * this exists to allow, since a host managed by nvm or asdf may have no node
 * on its non-interactive PATH at all.
 */
export function isBoringCommand(command: string): boolean {
  if (!/^[A-Za-z0-9._/-]+$/.test(command)) return false
  return !command.split('/').includes('..')
}

export function bootstrapArgv(
  target: Pick<RemoteTarget, 'host'>,
  nodeCommand = 'node',
): string[] {
  if (!isBoringCommand(nodeCommand)) {
    throw new Error(`refusing a node command that is not boring: ${nodeCommand}`)
  }
  return [
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=yes',
    target.host,
    nodeCommand,
    '-e',
    bootstrapArgument(),
  ]
}

/* ------------------------------------------------------------------ */
/* Requests the bootstrap understands                                  */
/* ------------------------------------------------------------------ */

export interface VerifyRequest {
  operation: 'verify-and-handshake'
  relativePath: string
  expectedHash: string
  protocolVersion: number
}

export interface ActivateRequest {
  operation: 'activate'
  relativePath: string
  buildId: string
}

export interface RollbackRequest {
  operation: 'rollback'
}

export type BootstrapRequest = VerifyRequest | ActivateRequest | RollbackRequest

export interface BootstrapReply {
  ok: boolean
  error?: string
  hash?: string
  node?: string
  nodeVersion?: string
  handshake?: string
  handshakeStderr?: string
  status?: number | null
  active?: string
  previous?: string | null
  restored?: string
}

export function decodeBootstrapReply(stdout: string): BootstrapReply | null {
  const line = stdout
    .split('\n')
    .map((entry) => entry.trim())
    .filter((entry) => entry.startsWith('{'))
    .pop()
  if (!line) return null
  try {
    const parsed = JSON.parse(line) as BootstrapReply
    return typeof parsed === 'object' && parsed !== null && typeof parsed.ok === 'boolean'
      ? parsed
      : null
  } catch {
    return null
  }
}

/** Where the active runner should be, for the message that says it is not on PATH. */
export function activeLinkHint(home: string): string {
  return `${home}/${BIN_DIR}/${LINK_NAME}`
}
