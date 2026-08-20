import { createServer, type Server } from 'node:http'
import { randomBytes, timingSafeEqual } from 'node:crypto'
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
  token: string
  close: () => void
}

/** Bounded before it is read, not after: an unbounded POST is a memory hole. */
const MAX_BODY = 200_000

export async function startRelayServer(deps: RelayDeps): Promise<RelayServer> {
  const token = randomBytes(24).toString('hex')

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
    if (!authorised(req.headers.authorization, token)) {
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
      const result = handleRelay(
        { from: req.headers['x-parley-from'], to: url.searchParams.get('to') ?? '', text: body },
        deps,
      )
      reply(result.status, result.body)
    })
  })

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const address = server.address()
  const port = typeof address === 'object' && address ? address.port : 0
  return {
    url: `http://127.0.0.1:${port}`,
    token,
    close: () => server.close(),
  }
}

/** Length-independent compare, so the token cannot be guessed a byte at a time. */
function authorised(header: string | undefined, token: string): boolean {
  const given = (header ?? '').replace(/^Bearer\s+/i, '')
  const a = Buffer.from(given)
  const b = Buffer.from(token)
  return a.length === b.length && timingSafeEqual(a, b)
}
