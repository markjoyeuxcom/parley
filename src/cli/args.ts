/**
 * The command line, taken apart.
 *
 * Its own module so it can be tested without running the program. `main.ts`
 * is an entry point: importing it starts the CLI and exits the process, which
 * is correct for a program and useless for a test.
 */

export const USAGE = `parley — read Parley's record as JSONL

  parley holds                    what is waiting on a human
  parley plans [--repo <path>]    plans, newest first
  parley journal <milestone-id>   every event of every run, oldest first
  parley runs <milestone-id>      one line per attempt, newest first

  --db <path>   read this record
  --dev         read the development checkout's record instead of the app's

Stdout is one JSON object per line. Diagnostics go to stderr.
`

export interface Args {
  command: string
  rest: string[]
  db: string | null
  dev: boolean
  repo: string | null
}

export function parseArgs(argv: readonly string[]): Args {
  const rest: string[] = []
  let db: string | null = null
  let dev = false
  let repo: string | null = null
  for (let at = 0; at < argv.length; at += 1) {
    const arg = argv[at]
    if (arg === '--dev') dev = true
    else if (arg === '--db') {
      db = argv[at + 1] ?? null
      at += 1
    } else if (arg === '--repo') {
      repo = argv[at + 1] ?? null
      at += 1
    } else if (arg !== undefined) rest.push(arg)
  }
  return { command: rest[0] ?? '', rest: rest.slice(1), db, dev, repo }
}

