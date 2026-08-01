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
  nodeCommandFor: (target: Pick<RemoteTarget, 'host'>) => string | undefined,
  signal?: AbortSignal,
): RemoteDriverDeps['converse'] {
  return async (target, request: RemoteRequest, onFrame: (frame: RemoteFrame) => void) => {
    const result = await runSsh({ target, request, onFrame, signal })
    void nodeCommandFor
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
