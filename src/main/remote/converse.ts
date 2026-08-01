import type { RemoteFrame, RemoteRequest, RemoteTarget } from '@shared/remote'
import type { RemoteDriverDeps } from './driver'
import { runSsh } from './ssh'

/**
 * Where the local driver and the ssh transport finally meet.
 *
 * Small on purpose. Everything interesting is on one side or the other — the
 * driver decides what happens in what order, the transport decides what a
 * dying connection means — and this only translates between the two
 * vocabularies. Keeping it thin is what let both be tested without the other.
 */
export function sshConverse(
  signal?: AbortSignal,
  /**
   * The ssh to run. Injected for one reason: without it there was no way to
   * put a fake host under the manager, so the whole remote path above the
   * driver — approval, reporter wiring, ledger consequences — had no test at
   * all, and a defect sat visibly in its source for an entire arc.
   *
   * It took a `nodeCommandFor` before this, which every call site supplied
   * and nothing ever read: the helper is invoked by name off the host's PATH,
   * so the node it runs under is the launcher's business.
   */
  sshBinary?: string,
): RemoteDriverDeps['converse'] {
  return async (target, request: RemoteRequest, onFrame: (frame: RemoteFrame) => void) => {
    const result = await runSsh({ target, request, onFrame, signal, sshBinary })
    return {
      kind: result.end.kind,
      detail:
        result.end.kind === 'closed'
          ? ''
          : 'detail' in result.end
            ? result.end.detail
            : 'the conversation was cancelled',
    }
  }
}
