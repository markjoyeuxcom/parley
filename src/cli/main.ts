import { Repo } from '@main/store/repo'
import { computeHolds } from '@main/orchestrator/holds'
import { summariseRuns } from '@shared/runroom'
import { parseArgs, USAGE, type Args } from './args'
import { defaultRecordPath, openRecordForReading, RecordError } from './record'

/**
 * parley — the record, from a terminal.
 *
 * Everything Parley knows already lives in one SQLite file; until now the only
 * way to ask it anything was the app. That is fine for deciding and wrong for
 * everything else: CI cannot open a window to find out whether a plan is
 * waiting on a human, and neither can a shell script, a cron job, or someone
 * three weeks later trying to remember why a milestone failed.
 *
 * Two rules, both borrowed from `parley-remote` because they were right there:
 *
 * **Stdout is data.** One JSON object per line, nothing else — no headers, no
 * totals, no progress. A run of this can be piped into `jq` without anyone
 * having to strip anything, and a command that printed a friendly summary
 * would make that untrue for every consumer in order to be nicer to one.
 *
 * **Stderr is for humans**, including which record was opened. Reading the
 * wrong database is the failure this tool makes easiest — dev and packaged
 * keep separate ones — and the answer looks perfectly plausible either way.
 *
 * It reads and never writes. Not a limitation to be lifted later without
 * thought: running a milestone spends an approval and real money, and a
 * single-use human gate does not survive being handed a `--yes` flag.
 */

/** One line, one object. The only thing that ever reaches stdout. */
function emit(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value)}\n`)
}

function say(message: string): void {
  process.stderr.write(`${message}\n`)
}

function run(args: Args): number {
  if (!args.command || args.command === 'help' || args.command === '--help') {
    say(USAGE)
    return args.command ? 0 : 1
  }

  const path = args.db ?? defaultRecordPath(args.dev)
  const db = openRecordForReading(path)
  // Named on every run. The two records answer the same questions differently
  // and nothing about an answer says which one it came from.
  say(`reading ${path}`)
  const repo = new Repo(db)

  switch (args.command) {
    case 'holds': {
      // The same derivation the titlebar counts, with no acknowledgements
      // applied: an ack is a UI state about who has looked, and a script
      // asking what is outstanding wants the work, not the reading history.
      for (const hold of computeHolds(repo, new Set())) emit(hold)
      return 0
    }

    case 'plans': {
      const plans = args.repo ? repo.listPlansForRepo(args.repo) : repo.listPlans()
      for (const plan of plans) {
        emit({
          id: plan.id,
          title: plan.title,
          status: plan.status,
          repoPath: plan.repoPath,
          isolation: plan.isolation,
          mock: plan.mock,
          createdAt: plan.createdAt,
          milestones: repo.listMilestones(plan.id).map((milestone) => ({
            id: milestone.id,
            index: milestone.index,
            title: milestone.title,
            status: milestone.status,
          })),
        })
      }
      return 0
    }

    case 'journal': {
      const milestoneId = args.rest[0]
      if (!milestoneId) {
        say('journal needs a milestone id')
        return 1
      }
      // Oldest first, and flat: the shape of a log, because that is what a
      // consumer of this is building. Attempt boundaries are recoverable from
      // runId without imposing a nesting nobody asked for.
      for (const run of repo.listMilestoneRuns(milestoneId)) {
        for (const event of repo.listRunEvents(run.runId)) emit(event)
      }
      return 0
    }

    case 'runs': {
      const milestoneId = args.rest[0]
      if (!milestoneId) {
        say('runs needs a milestone id')
        return 1
      }
      // The same summary the Run Room renders, so what a script reads and
      // what a person sees cannot disagree about how an attempt went.
      const runs = repo
        .listMilestoneRuns(milestoneId)
        .map((run) => ({ runId: run.runId, events: repo.listRunEvents(run.runId) }))
      for (const summary of summariseRuns(runs)) emit(summary)
      return 0
    }

    default:
      say(`unknown command: ${args.command}\n\n${USAGE}`)
      return 1
  }
}

function main(): void {
  try {
    process.exit(run(parseArgs(process.argv.slice(2))))
  } catch (error) {
    // A missing or mismatched record is a normal thing to hit and needs no
    // stack; anything else is a bug and the trace is the useful part.
    if (error instanceof RecordError) {
      say(error.message)
      process.exit(2)
    }
    throw error
  }
}

main()
