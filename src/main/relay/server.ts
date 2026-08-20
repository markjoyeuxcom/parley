import { createServer, type Server } from 'node:http'
import { handleRelay, type RelayDeps } from './handle'

/**
 * The door an agent in a pane knocks on.
 *
 * A CLI inside a pane has a shell and nothing else — no MCP config to share,
 * no protocol in common across three vendors. So the capability is an HTTP
 * endpoint on loopback and a one-line shim on its PATH, which every vendor's
 * CLI can already call.
 *
 * Loopback only, on a port the OS picks, behind a token minted per run and
 * handed to panes through their environment. A web page cannot read that
 * token, which is what stops a visited site posting to the port.
 *
 * The text arrives as the raw request body rather than inside JSON, because
 * the caller is a shell script and quoting a model's output — quotes,
 * newlines, backticks — into JSON from `sh` is a bug waiting to happen.
 */
export interface RelayServer {
  url: string
  close: () => void
}

/** Bounded before it is read, not after: an unbounded POST is a memory hole. */
const MAX_BODY = 200_000

export async function startRelayServer(deps: RelayDeps): Promise<RelayServer> {

  const server: Server = createServer((req, res) => {
    const reply = (status: number, body: unknown): void => {
      res.writeHead(status, { 'content-type': 'application/json' })
      res.end(JSON.stringify(body))
    }

    const url = new URL(req.url ?? '/', 'http://localhost')
    if (req.method !== 'POST' || url.pathname !== '/relay') {
      reply(404, { ok: false, error: 'POST /relay?to=<pane>' })
      return
    }
    // The credential *is* the identity. Each pane holds its own, so who is
    // calling is derived here rather than read from a header the caller could
    // set to anything. See relay/tokens.ts.
    const from = deps.paneForToken(bearer(req.headers.authorization))
    if (!from) {
      reply(401, { ok: false, error: 'bad token' })
      return
    }

    let body = ''
    let tooBig = false
    req.on('data', (chunk: Buffer) => {
      if (tooBig) return
      body += chunk.toString('utf8')
      if (body.length > MAX_BODY) {
        tooBig = true
        reply(400, { ok: false, error: 'text too long' })
        req.destroy()
      }
    })
    req.on('end', () => {
      if (tooBig) return
      // The target travels as a header. As a query parameter it had to be
      // URL-encoded by a shell script, and `sh` has no way to do that — a pane
      // id or name containing `#` or `&` would have been silently truncated.
      const to = req.headers['x-parley-to'] ?? url.searchParams.get('to') ?? ''
      // `from` came from the token, not from the request. `X-Parley-From` is
      // ignored entirely — an older shim may still send it, and it means
      // nothing now.
      const result = handleRelay({ from, to, text: body }, deps)
      reply(result.status, result.body)
    })
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const port = typeof address === 'object' && address ? address.port : 0
  return {
    url: `http://127.0.0.1:${port}`,
    close: () => server.close(),
  }
}

/** The credential out of an Authorization header, or '' — never undefined. */
function bearer(header: string | undefined): string {
  return (header ?? '').replace(/^Bearer\s+/i, '').trim()
}
