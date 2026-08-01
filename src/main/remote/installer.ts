import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { REMOTE_HELPER_COMMAND, REMOTE_PROTOCOL_VERSION, type RemoteTarget } from '@shared/remote'
import { decodeFrame } from './frames'
import { encodeRequest, handshakeRequest, sshArgv } from './protocol'
import {
  activeLinkHint,
  bootstrapArgv,
  decodeBootstrapReply,
  newNonce,
  sftpArgv,
  sftpBatch,
  stagingFor,
} from './install'

/**
 * Putting parley-remote on a host.
 *
 * Three boundaries, and the ssh command line is a constant at every one:
 * SFTP moves opaque bytes to a constrained path, a fixed `node -e` bootstrap
 * verifies and activates them, and afterwards only `parley-remote` is ever
 * invoked. Nothing about the installation — not the staged path, not the hash
 * — appears in an argument.
 *
 * The order is the safety property. Bytes land under a nonce; the host hashes
 * them and compares against what we built; the STAGED bundle answers a
 * handshake before it is activated; only then is it renamed into place and the
 * symlink swapped. A bundle that cannot run never becomes the one that runs.
 *
 * And then it is asked again, by name. That last step exists because the first
 * real host revealed how little the others proved: every one of them names an
 * absolute path, while a run names nothing and lets the host's PATH find
 * `parley-remote`. On a host with node under nvm, the staged handshake passed
 * and every run afterwards failed — the bundle arrived mode 644 from sftp and
 * its `#!/usr/bin/env node` shebang had no node to find. Both were invisible
 * to a check that ran `node <path>`. A gate that cannot fail the way the thing
 * it guards fails is not a gate.
 */

export interface InstallOutcome {
  ok: boolean
  buildId: string
  detail: string
  /** What the newly installed bundle said about itself, when it got that far. */
  nodeVersion?: string
}

export interface InstallDeps {
  /** Absolute path of the built parley-remote.mjs. */
  bundlePath: string
  sshBinary?: string
  sftpBinary?: string
  signal?: AbortSignal
}

interface Captured {
  code: number | null
  stdout: string
  stderr: string
}

function run(
  command: string,
  args: string[],
  input: string,
  signal?: AbortSignal,
): Promise<Captured> {
  return new Promise((resolve) => {
    let child: ReturnType<typeof spawn>
    try {
      child = spawn(command, args, { stdio: ['pipe', 'pipe', 'pipe'] })
    } catch (error) {
      resolve({ code: null, stdout: '', stderr: String(error) })
      return
    }
    let stdout = ''
    let stderr = ''
    let settled = false
    const finish = (code: number | null): void => {
      if (settled) return
      settled = true
      signal?.removeEventListener('abort', onAbort)
      resolve({ code, stdout, stderr })
    }
    const onAbort = (): void => {
      child.kill('SIGTERM')
      finish(null)
    }
    signal?.addEventListener('abort', onAbort, { once: true })
    child.stdout?.setEncoding('utf8')
    child.stdout?.on('data', (chunk: string) => {
      stdout += chunk
    })
    child.stderr?.setEncoding('utf8')
    child.stderr?.on('data', (chunk: string) => {
      if (stderr.length < 32 * 1024) stderr += chunk
    })
    child.on('error', (error) => finish(null) ?? void (stderr += String(error)))
    child.on('close', (code) => finish(code))
    child.stdin?.on('error', () => {})
    child.stdin?.end(input)
  })
}

export async function installRemote(
  target: Pick<RemoteTarget, 'host'> & { nodeCommand?: string },
  deps: InstallDeps,
): Promise<InstallOutcome> {
  if (!existsSync(deps.bundlePath)) {
    return {
      ok: false,
      buildId: '',
      detail: `no built runner at ${deps.bundlePath} — run \`npm run build:remote\` first`,
    }
  }
  const bytes = readFileSync(deps.bundlePath)
  const buildId = createHash('sha256').update(bytes).digest('hex')

  // ── The bytes ────────────────────────────────────────────────────────────
  const paths = stagingFor(newNonce())
  const upload = await run(
    deps.sftpBinary ?? 'sftp',
    sftpArgv(target),
    sftpBatch(deps.bundlePath, paths),
    deps.signal,
  )
  if (upload.code !== 0) {
    return {
      ok: false,
      buildId,
      // sftp's own words: it knows whether the host refused, the key was
      // rejected, or a directory could not be made.
      detail: `the upload failed: ${(upload.stderr || upload.stdout).trim().slice(0, 400) || 'sftp exited non-zero'}`,
    }
  }

  // ── Hash it there, and make the staged copy prove it runs ────────────────
  const argv = bootstrapArgv(target, target.nodeCommand)
  const verified = await run(
    deps.sshBinary ?? 'ssh',
    argv,
    `${JSON.stringify({
      operation: 'verify-and-handshake',
      relativePath: paths.stagedBundle,
      expectedHash: buildId,
      protocolVersion: REMOTE_PROTOCOL_VERSION,
    })}\n`,
    deps.signal,
  )
  const reply = decodeBootstrapReply(verified.stdout)
  if (!reply) {
    return { ok: false, buildId, detail: nodeFailure(verified, target.nodeCommand ?? 'node') }
  }
  if (!reply.ok) return { ok: false, buildId, detail: reply.error ?? 'the host refused the upload' }

  const announced = (reply.handshake ?? '')
    .split('\n')
    .map((line) => decodeFrame(line))
    .find((frame) => frame?.body.type === 'ready')
  if (!announced || announced.body.type !== 'ready') {
    return {
      ok: false,
      buildId,
      // It hashed correctly and still could not answer. Activating it would
      // replace a working installation with one that does not start.
      detail: `the uploaded runner did not answer a handshake: ${(reply.handshakeStderr ?? '').trim().slice(0, 300) || 'no output'}`,
    }
  }
  if (announced.body.capabilities.protocolVersion !== REMOTE_PROTOCOL_VERSION) {
    return {
      ok: false,
      buildId,
      detail: `the uploaded runner speaks protocol v${announced.body.capabilities.protocolVersion}, this Parley speaks v${REMOTE_PROTOCOL_VERSION}`,
    }
  }

  // ── Only now does it become the one that runs ────────────────────────────
  const activated = await run(
    deps.sshBinary ?? 'ssh',
    argv,
    `${JSON.stringify({ operation: 'activate', relativePath: paths.stagedBundle, buildId })}\n`,
    deps.signal,
  )
  const done = decodeBootstrapReply(activated.stdout)
  if (!done?.ok) {
    return { ok: false, buildId, detail: done?.error ?? 'the host could not activate the upload' }
  }

  // ── And prove it answers the way a run will reach it ─────────────────────
  //
  // Everything above named a path. A run names nothing: it says
  // `ssh host parley-remote` and lets the host's own PATH find the symlink.
  // That last hop is its own failure — the link may not be on a
  // non-interactive PATH, or may not be executable — and it went undetected
  // for the whole arc because no earlier step took it.
  const reachable = await run(
    deps.sshBinary ?? 'ssh',
    sshArgv(target),
    encodeRequest(handshakeRequest('install-reachability')),
    deps.signal,
  )
  const answered = reachable.stdout
    .split('\n')
    .map((line) => decodeFrame(line))
    .some((frame) => frame?.body.type === 'ready')
  if (!answered) {
    return {
      ok: false,
      buildId,
      // Installed, and unusable. Saying "installed" here is what produced a
      // host that looked ready and failed every single run.
      detail: `the runner is installed but the host could not run it as \`${REMOTE_HELPER_COMMAND}\`. It should be at ${activeLinkHint('~')} — check that directory is on the PATH of a non-interactive ssh session.${
        (reachable.stderr || '').trim() ? `\n\n${reachable.stderr.trim().slice(0, 300)}` : ''
      }`,
    }
  }

  return {
    ok: true,
    buildId,
    nodeVersion: announced.body.capabilities.nodeVersion,
    detail: done.previous
      ? `installed; the previous build is kept for rollback`
      : 'installed',
  }
}

/**
 * The failure people actually hit, said in a way they can act on.
 *
 * A non-interactive ssh session does not read the shell startup files where
 * nvm, asdf and mise install node, so a host where `node` works perfectly in
 * an interactive terminal will answer 127 here. Reporting the raw exit code
 * sends people to check the wrong thing.
 */
function nodeFailure(result: Captured, nodeCommand: string): string {
  const said = (result.stderr || result.stdout).trim().slice(0, 300)
  if (result.code === 127 || /not found/i.test(said)) {
    return `the host could not start "${nodeCommand}" (exit ${result.code ?? '?'}). Non-interactive ssh sessions often miss nvm, asdf and mise — set an absolute node path for this target, for example /home/you/.nvm/versions/node/v22.18.0/bin/node.${said ? `\n\n${said}` : ''}`
  }
  return said || 'the host did not answer the installer'
}

export async function rollbackRemote(
  target: Pick<RemoteTarget, 'host'> & { nodeCommand?: string },
  deps: Omit<InstallDeps, 'bundlePath'>,
): Promise<{ ok: boolean; detail: string }> {
  const result = await run(
    deps.sshBinary ?? 'ssh',
    bootstrapArgv(target, target.nodeCommand),
    `${JSON.stringify({ operation: 'rollback' })}\n`,
    deps.signal,
  )
  const reply = decodeBootstrapReply(result.stdout)
  if (!reply?.ok) {
    return { ok: false, detail: reply?.error ?? 'the host could not roll back' }
  }
  return { ok: true, detail: `rolled back to ${reply.restored ?? 'the previous build'}` }
}
