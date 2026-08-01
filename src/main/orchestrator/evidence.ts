import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { isAbsolute, join, relative as relative_ } from 'node:path'
import { extractJson, oneOf, safeString } from '@shared/extract'
import type { AgentConfig, Milestone, Mutation, MutationResult, TestResult, Vendor } from '@shared/domain'
import { capture } from '@main/util/spawn'

/**
 * What execution knows about a working tree, and about its own limits.
 *
 * A dependency leaf, and one that had to be extracted rather than left where
 * it was: these helpers lived in pipeline.ts, so the execution core importing
 * them dragged the facade — and through it the ledger and the record
 * vocabulary — into a graph that is supposed to be able to run on a machine
 * with neither. The dependency ran the wrong way, and a bundle test caught it.
 *
 * Everything here is pure or reads the filesystem. Nothing here knows what a
 * record is.
 */

/**
 * How many times a rejected milestone may be handed back to its executor.
 *
 * Bounded deliberately. Each round costs a full execute-and-review cycle, and a
 * disagreement that survives two attempts is one a human should look at rather
 * than one more prompt.
 */
export const MAX_REMEDIATION_ROUNDS = 2


export const STAGE_TIMEOUT_MS = 30 * 60 * 1000

export const TEST_TIMEOUT_MS = 20 * 60 * 1000
/** A stall inspection is a look, not a stage: bounded well under a turn. */

export class PipelineError extends Error {}

/**
 * Everything a resumed milestone run needs, persisted as one blob on the
 * milestone row (the plans.pending argument: what a resumption needs differs
 * by stage and keeps growing). Written during the run at the points where the
 * loop's own locals change, cleared on completion and at retry/adoption entry,
 * preserved on failure — presence is what "resumable" means. The domain's
 * MilestoneRunState is the wire-safe summary of this; the baseline and the
 * resume ids never leave the main process.
 */

/**
 * Everything a resumed milestone run needs, persisted as one blob on the
 * milestone row (the plans.pending argument: what a resumption needs differs
 * by stage and keeps growing). Written during the run at the points where the
 * loop's own locals change, cleared on completion and at retry/adoption entry,
 * preserved on failure — presence is what "resumable" means. The domain's
 * MilestoneRunState is the wire-safe summary of this; the baseline and the
 * resume ids never leave the main process.
 */
export function freshRunState(before: TreeState, baselineHead: string): RunState {
  return {
    startedAt: Date.now(),
    round: 0,
    previousConcerns: [],
    reviewerNote: '',
    executionReport: '',
    executorResumeId: null,
    reviewerResumeId: null,
    before,
    baselineHead,
    lastActivityAt: null,
    lastInspection: null,
  }
}

export interface RunState {
  startedAt: number
  /** The remediation round the next execution would run. */
  round: number
  previousConcerns: string[]
  /** The reviewer's critique prose — a resumed remediation needs it verbatim. */
  reviewerNote: string
  /** Tail of the executor's last report, for notes written after a crash. */
  executionReport: string
  executorResumeId: string | null
  reviewerResumeId: string | null
  /** The pre-execution baseline. Unreconstructible for a dirty checkout. */
  before: TreeState
  /** HEAD at baseline capture — the validity anchor. A resume against a moved
   *  HEAD would diff across two worlds, so it refuses instead. */
  baselineHead: string
  /** Written on real activity only, throttled; never on a watchdog tick. */
  lastActivityAt: number | null
  lastInspection: { at: number; verdict: string; note: string } | null
}

/**
 * The note a user-requested stop writes. One sentence for the act, one for
 * what it left behind — the run state survives a stop exactly as it survives
 * a crash, and the reader deciding what to do next needs to know that.
 */

/**
 * The note a user-requested stop writes. One sentence for the act, one for
 * what it left behind — the run state survives a stop exactly as it survives
 * a crash, and the reader deciding what to do next needs to know that.
 */
export const STOPPED_NOTE =
  'Stopped by you. The run state was preserved, so this milestone can be resumed with a fresh approval.'

/**
 * The planning conversation, as the engine reads it.
 *
 * Three read-only spoken stages: the planner drafts on its own thread, its
 * counterpart audits fresh, and the planner answers the audit on the same
 * resumed thread — with a human gate (a clarification) available exactly
 * where guessing would bake an unagreed assumption into the plan. The audit
 * has no such gate: an auditor's job is judgement over what is in front of
 * it, and its dead end is parking the plan blocked, not asking.
 *
 * Consulted, not decorative: `speak` resolves the actor, the resumption and
 * the telemetry label from the entry, and `clarificationOf` lets a reply park
 * the stage only where the gate declares one. The apply half of each stage —
 * what its parsed reply does to the plan — stays in the stage functions,
 * named and explicit, because those consequences are the stage.
 */

/** Result of one verify-and-review pass. */
export type VerifyOutcome =
  | { kind: 'unchanged'; milestone: Milestone }
  | {
      kind: 'reviewed'
      milestone: Milestone
      passed: boolean
      /** The reviewer's objections, which become the next round's brief. */
      concerns: string[]
      /** Its non-blocking remarks, kept apart so the surface can mute them. */
      reviewNotes: string[]
      reviewerNote: string
      reviewerResumeId: string | null
      testResult: TestResult | null
      testsPassed: boolean
      note: string
    }

/**
 * The audited execution pipeline.
 *
 * The separation of powers is the product:
 *
 *   plan (read-only)  →  audit by a different vendor (read-only)
 *                     →  human approval, single-use
 *                     →  execute one milestone (write)
 *                     →  deterministic tests, run by Parley
 *                     →  independent review of the diff by the vendor that did
 *                        not execute it
 *
 * No agent both writes code and certifies its own work, and no repository write
 * happens without a recorded approval that is spent in the act of starting.
 */

/**
 * Reads the reply to {@link mutationRepairPrompt}.
 *
 * `impossible` is treated as a real answer rather than a failure. A reviewer that
 * says an intent cannot be checked against this file is telling us something worth
 * recording, and it is a far more useful reply than a fabricated anchor that would
 * pass by accident.
 */
export function parseMutationRepairs(text: string): {
  repairs: Map<number, { find: string; replace: string }>
  impossible: Map<number, string>
} {
  const repairs = new Map<number, { find: string; replace: string }>()
  const impossible = new Map<number, string>()
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return { repairs, impossible }

  const index = (item: Record<string, unknown>): number | null => {
    const raw = item['index']
    const n = typeof raw === 'number' ? raw : Number.parseInt(String(raw ?? ''), 10)
    return Number.isInteger(n) && n >= 1 && n <= 10 ? n : null
  }

  if (Array.isArray(data['repairs'])) {
    for (const entry of data['repairs'].slice(0, 10)) {
      if (typeof entry !== 'object' || entry === null) continue
      const item = entry as Record<string, unknown>
      const i = index(item)
      const find = safeString(item['find'], 4000)
      const replace = safeString(item['replace'], 4000)
      // A no-op edit is not a check, so it is dropped rather than run.
      if (i === null || !find.trim() || find === replace) continue
      repairs.set(i, { find, replace })
    }
  }
  if (Array.isArray(data['impossible'])) {
    for (const entry of data['impossible'].slice(0, 10)) {
      if (typeof entry !== 'object' || entry === null) continue
      const item = entry as Record<string, unknown>
      const i = index(item)
      if (i === null || repairs.has(i)) continue
      impossible.set(i, safeString(item['why'], 500) || 'no reason given')
    }
  }
  return { repairs, impossible }
}


/**
 * The config an agent actually runs with when its vendor was coerced.
 *
 * The pipeline overrides a same-vendor reviewer to the counterpart, but it used
 * to spread the configured record and swap only the vendor field — carrying a
 * vendor-specific model name across the boundary, so the codex CLI could be
 * invoked with a Claude model string. Effort and persona are vendor-neutral and
 * survive; the model does not, so a swap blanks it and the CLI falls back to its
 * own default.
 */
export function reviewerConfig(configured: AgentConfig, vendor: Vendor): AgentConfig {
  if (configured.vendor === vendor) return configured
  return { ...configured, vendor, model: '' }
}


export interface ParsedReview {
  passed: boolean
  /** Problems that must be fixed. Non-empty means the milestone did not pass. */
  blocking: string[]
  /** Recorded, not acted on. Never sent to remediation. */
  notes: string[]
  note: string
}


export function parseReview(text: string): ParsedReview | null {
  const { data } = extractJson<Record<string, unknown>>(text)
  if (!data) return null
  if (typeof data['passed'] !== 'boolean') return null

  // `concerns` is the old single-list key. A model still using it has ignored
  // the schema, and the safe reading of an unclassified problem is that it
  // blocks — erring toward a milestone being handed back rather than shipped.
  const blocking = stringList(data['blocking'] ?? data['concerns'])

  return {
    // Derived, not read. The reviewer's own flag is not trusted against its own
    // findings: on three consecutive milestones a real defect was written down
    // and passed anyway, so a listed blocking problem now fails the milestone
    // whether or not the box was ticked. This is the whole point of the split —
    // it makes "acknowledged but shipped" impossible to express.
    passed: data['passed'] === true && blocking.length === 0,
    blocking,
    notes: stringList(data['notes']),
    note: safeString(data['note'], 2000),
  }
}

// ─── Repository inspection ───────────────────────────────────────────────────

/**
 * A snapshot of the working tree.
 *
 * Captured before *and* after execution. Comparing the two is the only sound way
 * to answer "did this milestone change anything": comparing against a clean tree
 * assumes the repository started clean, and a single stray file — an exported
 * report, a leftover from an earlier attempt — silently defeats that assumption
 * and lets a milestone that wrote nothing proceed to tests and review.
 */

/**
 * A snapshot of the working tree.
 *
 * Captured before *and* after execution. Comparing the two is the only sound way
 * to answer "did this milestone change anything": comparing against a clean tree
 * assumes the repository started clean, and a single stray file — an exported
 * report, a leftover from an earlier attempt — silently defeats that assumption
 * and lets a milestone that wrote nothing proceed to tests and review.
 */
export interface TreeState {
  /** True when the directory is not a git repository, so nothing can be judged. */
  unknown: boolean
  /** Content-sensitive fingerprint of the whole working tree state. */
  signature: string
  /** Paths that differ from HEAD, tracked or not. */
  paths: string[]
  diffText: string
  stagedText: string
  statText: string
  untracked: string[]
  /**
   * Contents of paths that differ from HEAD.
   *
   * The HEAD content distinguishes a path that became clean from one that was
   * removed. Both sides are bounded, because a dirty `node_modules` would
   * otherwise be read into memory.
   */
  files: TreeFileSnapshot[]
}


export interface TreeFileSnapshot {
  path: string
  text: string | null
  truncated: boolean
  exists: boolean
  digest: string | null
  /** False when the digest could not be established (a failed git spawn), which
   * is different from the file being absent — unknown must not read as same. */
  digestKnown: boolean
  headText: string | null
  headTruncated: boolean
  headExists: boolean
  headDigest: string | null
  headDigestKnown: boolean
}

/**
 * HEAD at this moment, or '' outside a git repository. Recorded beside a
 * baseline so a later resume can prove the world has not moved underneath the
 * preserved state — every signature in a TreeState is relative to HEAD, and a
 * comparison across two different HEADs silently inverts the attribution
 * machinery instead of failing.
 */

export async function readTree(repoPath: string, signal?: AbortSignal): Promise<TreeState> {
  const stat = await capture('git', ['--no-pager', 'diff', '--stat'], repoPath, 60_000, signal)
  if (stat.exitCode !== 0) {
    return {
      unknown: true,
      signature: '',
      paths: [],
      diffText: '',
      stagedText: '',
      statText: '',
      untracked: [],
      files: [],
    }
  }

  const [full, staged, stagedStat, others, unstagedNames, stagedNames] = await Promise.all([
    // --no-renames on the content diffs as well as the name lists: a rename must
    // reach the reviewer as a removal plus an addition with full content, not as
    // two lines of content-free metadata.
    capture('git', ['--no-pager', 'diff', '--no-renames'], repoPath, 120_000, signal),
    capture('git', ['--no-pager', 'diff', '--no-renames', '--cached'], repoPath, 120_000, signal),
    capture('git', ['--no-pager', 'diff', '--cached', '--stat'], repoPath, 60_000, signal),
    capture('git', ['ls-files', '--others', '--exclude-standard'], repoPath, 60_000, signal),
    capture('git', ['diff', '--no-renames', '--name-only', '-z'], repoPath, 60_000, signal),
    capture('git', ['diff', '--cached', '--no-renames', '--name-only', '-z'], repoPath, 60_000, signal),
  ])

  const untracked = others.stdout.split('\n').map((l) => l.trim()).filter(Boolean)

  // Untracked content is not in git, so fingerprint it from the filesystem.
  // Size and mtime together move on any write, which is all this needs to do.
  const untrackedStamps = untracked.map((rel) => {
    try {
      const info = statSync(join(repoPath, rel))
      return `${rel}:${info.size}:${info.mtimeMs}`
    } catch {
      return `${rel}:missing`
    }
  })

  const trackedPaths = new Set(
    `${unstagedNames.stdout}\0${stagedNames.stdout}`.split('\0').filter(Boolean),
  )

  const signature = createHash('sha256')
    .update(full.stdout)
    .update('\0')
    .update(staged.stdout)
    .update('\0')
    .update(untrackedStamps.join('\n'))
    .digest('hex')

  const paths = [...trackedPaths, ...untracked].sort()

  return {
    unknown: false,
    signature,
    paths,
    diffText: full.stdout,
    stagedText: staged.stdout,
    statText: [stat.stdout.trim(), stagedStat.stdout.trim()].filter(Boolean).join('\n'),
    untracked,
    files: await readChangedFiles(repoPath, paths, signal),
  }
}


export const MAX_CHANGED_FILE_CHARS = 6000

/** Reads dirty working-tree and HEAD content so their incremental delta can reach the reviewer. */

/**
 * Whether this is a new project rather than an existing codebase.
 *
 * Tracked files, not commits: a repository someone has `git init`-ed and left
 * empty is greenfield, and so is one holding only the untracked debris of an
 * interrupted attempt. A directory that is not a repository at all counts as
 * greenfield when it holds nothing but dotfiles.
 *
 * The distinction matters because the planner and auditor prompts are otherwise
 * built on an assumption that does not hold — that there is prior work to read
 * and existing paths to check against.
 */
export async function isGreenfield(repoPath: string, signal?: AbortSignal): Promise<boolean> {
  const tracked = await capture('git', ['ls-files'], repoPath, 60_000, signal)
  if (tracked.exitCode === 0) return tracked.stdout.trim() === ''

  try {
    return readdirSync(repoPath).filter((name) => !name.startsWith('.')).length === 0
  } catch {
    return false
  }
}

/** A baseline meaning "nothing was here before", for adoption reviews. */

/** A baseline meaning "nothing was here before", for adoption reviews. */
export function emptyTree(): TreeState {
  return {
    unknown: true,
    signature: '',
    paths: [],
    diffText: '',
    stagedText: '',
    statText: '',
    untracked: [],
    files: [],
  }
}

/** True when the milestone provably changed nothing. Unknown trees never qualify. */

/** True when the milestone provably changed nothing. Unknown trees never qualify. */
export function treeUnchanged(before: TreeState, after: TreeState): boolean {
  if (before.unknown || after.unknown) return false
  return before.signature === after.signature
}


/** The paths dirty before execution whose observed contents did not change. */
export function preExistingUntouched(before: TreeState, after: TreeState): string[] {
  if (before.unknown || after.unknown) return []
  return before.paths.filter((path) => {
    const oldContent = contentAt(before, after, path)
    const newContent = contentAt(after, before, path)
    return oldContent !== undefined && newContent !== undefined && sameContent(oldContent, newContent)
  })
}

/** A pure rendering of only the changes observed between two tree snapshots. */

/** A pure rendering of only the changes observed between two tree snapshots. */
export function incrementalDelta(
  before: TreeState,
  after: TreeState,
  scope?: ReadonlySet<string>,
): string {
  if (after.unknown) return ''

  const sections: string[] = []
  const paths = [...new Set([...before.paths, ...after.paths])]
    .filter((path) => !scope || scope.has(path))
    .sort()
  for (const path of paths) {
    const oldContent = contentAt(before, after, path)
    const newContent = contentAt(after, before, path)
    if (!oldContent || !newContent) {
      if (!after.paths.includes(path)) {
        sections.push(`--- removed file: ${path} ---\n(contents not shown)`)
      } else if (!before.paths.includes(path)) {
        sections.push(`--- new file: ${path} ---\n(contents not shown)`)
      }
      continue
    }
    if (sameContent(oldContent, newContent)) continue

    if (!oldContent.exists) {
      const detail = newContent.text === null
        ? '(contents not shown — bounded snapshot unavailable)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- new file: ${path} ---\n${detail}`)
    } else if (!newContent.exists) {
      const detail = oldContent.text === null
        ? '(contents not shown — bounded snapshot unavailable)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- removed file: ${path} ---\n${detail}`)
    } else {
      const detail = oldContent.text === null ||
        newContent.text === null ||
        (oldContent.text === newContent.text && (oldContent.truncated || newContent.truncated))
        ? '(contents differ beyond the bounded snapshot)'
        : contentPatch(path, oldContent, newContent)
      sections.push(`--- changed file: ${path} ---\n${detail}`)
    }
  }
  return sections.join('\n\n')
}

/**
 * Renders the diff for review, naming anything that predates the milestone.
 *
 * A reviewer told to judge "the diff" against a milestone's scope will otherwise
 * count unrelated pre-existing changes against it, or credit them to it.
 */
/**
 * The reviewer's evidence, in three layers that each do the one thing they are
 * good at.
 *
 * Git's own diff is the primary channel: full hunks, up to the overall budget,
 * for every tracked change — an edit deep in a 2,000-line file arrives as real
 * code, which the first version of this renderer lost by replacing git's output
 * with 6KB snapshots (a milestone editing this repo's own pipeline.ts reached
 * its reviewer as "(contents differ beyond the bounded snapshot)" and nothing
 * else). Untracked files, which git diff omits entirely, come from the bounded
 * snapshots. The digest layer then does what git cannot: separate this
 * milestone's work from dirt that predates it — the untouched list only ever
 * names digest-verified paths, and pre-existing dirty paths the milestone DID
 * touch get their own bounded incremental delta so the reviewer can tell which
 * part of the combined diff is the milestone's.
 */

/**
 * Renders the diff for review, naming anything that predates the milestone.
 *
 * A reviewer told to judge "the diff" against a milestone's scope will otherwise
 * count unrelated pre-existing changes against it, or credit them to it.
 */
/**
 * The reviewer's evidence, in three layers that each do the one thing they are
 * good at.
 *
 * Git's own diff is the primary channel: full hunks, up to the overall budget,
 * for every tracked change — an edit deep in a 2,000-line file arrives as real
 * code, which the first version of this renderer lost by replacing git's output
 * with 6KB snapshots (a milestone editing this repo's own pipeline.ts reached
 * its reviewer as "(contents differ beyond the bounded snapshot)" and nothing
 * else). Untracked files, which git diff omits entirely, come from the bounded
 * snapshots. The digest layer then does what git cannot: separate this
 * milestone's work from dirt that predates it — the untouched list only ever
 * names digest-verified paths, and pre-existing dirty paths the milestone DID
 * touch get their own bounded incremental delta so the reviewer can tell which
 * part of the combined diff is the milestone's.
 */
export function renderDiffForReview(after: TreeState, before: TreeState): string {
  if (after.unknown) {
    return '(no diff available — this directory is not a git repository, so the change could not be shown for review)'
  }

  const preExisting = preExistingUntouched(before, after)
  const sections: string[] = []

  if (preExisting.length) {
    sections.push(
      `--- NOT part of this milestone ---\nThese paths were already modified before this milestone ran, and their content is byte-identical to before it ran. ` +
        `Do not attribute them to it:\n${preExisting.map((p) => `  ${p}`).join('\n')}`,
    )
  }

  const statText = [after.statText].filter(Boolean).join('\n')
  sections.push(`--- diffstat ---\n${statText || '(no tracked changes)'}`)

  const trackedDiff = [after.diffText.trim(), after.stagedText.trim()].filter(Boolean).join('\n')
  const preExistingDirty = new Set(
    before.unknown ? [] : before.paths.filter((path) => !preExisting.includes(path)),
  )
  sections.push(
    `--- combined diff vs HEAD (tracked files; includes pre-existing edits on any dirty paths listed above or below) ---\n${trackedDiff || '(empty)'}`,
  )

  // Untracked files never appear in git diff, so their content has to come from
  // the snapshots. Only the milestone's own new files belong here — untracked
  // paths that predate the milestone are covered by the delta section below.
  const newFileSections: string[] = []
  for (const file of after.files) {
    if (!after.untracked.includes(file.path)) continue
    if (preExistingDirty.has(file.path) || preExisting.includes(file.path)) continue
    newFileSections.push(
      `--- new file: ${file.path} ---\n${
        file.text ?? '(contents not shown — too large or unreadable)'
      }${file.truncated ? '\n[truncated]' : ''}`,
    )
  }
  sections.push(...newFileSections)

  if (preExistingDirty.size) {
    sections.push(
      `--- this milestone's own changes to already-dirty paths ---\n${
        incrementalDelta(before, after, preExistingDirty) || '(none — every already-dirty path is byte-identical)'
      }`,
    )
  }

  const joined = sections.join('\n\n')
  return joined.length > MAX_DIFF_CHARS
    ? `${joined.slice(0, MAX_DIFF_CHARS)}\n\n[diff truncated at ${MAX_DIFF_CHARS} characters]`
    : joined
}

/** Which of the plan's expected paths the executor actually produced. */

/** Which of the plan's expected paths the executor actually produced. */
export function missingExpectedPaths(repoPath: string, expected: string[]): string[] {
  return expected.filter((rel) => !existsSync(join(repoPath, rel)))
}

/**
 * Changed paths that fall outside a milestone's declared scope.
 *
 * A milestone's verification command is written against its own paths, so
 * anything here was included in the review but never exercised by the tests.
 * Matching is prefix-wise in both directions because git reports an untracked
 * directory as `pkg/` while a plan names `pkg/file.go`.
 */

export function summariseTests(result: TestResult | null): string {
  if (!result) {
    return 'No verification command was defined for this milestone, so nothing was run. Weigh the diff on its own.'
  }
  // Three outcomes that all arrive as "non-zero" and call for three different
  // responses. Told "FAILED", an executor changes the code — right for a real
  // failure, wrong for a crash, and worse than useless for a hang, where the
  // code may be perfectly correct and simply never returns.
  //
  // The timeout is checked before the signal because a timeout *is* a signal
  // death: Parley kills with SIGTERM. Reported as "killed by SIGTERM" it looks
  // like something external intervened, when in fact nothing did — the command
  // never finished and the deadline ran out.
  const verdict = result.timedOut
    ? `DID NOT FINISH — the command was still running after ${(TEST_TIMEOUT_MS / 60000).toFixed(0)} minutes and Parley stopped it, so nothing was verified. Treat this as a hang: something waits for what never arrives. The code may be correct and simply never returns.`
    : result.signal
      ? `DID NOT COMPLETE — the runner was killed by ${result.signal}, so nothing was verified. This is a crash in the verification command itself, not a failing test.`
      : result.exitCode === 0
        ? 'PASSED'
        : `FAILED (exit ${result.exitCode})`
  const output = tail(`${result.stdout}\n${result.stderr}`.trim(), 4000)
  return `\`${result.command}\` ${verdict} in ${(result.durationMs / 1000).toFixed(1)}s\n\n${output || '(no output)'}`
}

/**
 * Renders mutation outcomes for the reviewer and the record.
 *
 * Deliberately states the survivors first and plainly. A surviving mutation is
 * the strongest possible evidence that a milestone's tests do not pin its claim
 * — stronger than any reading of the diff, because it was tried.
 */
/**
 * Decides whether one applied mutation was caught.
 *
 * Pulled out as its own function because the tempting shorthand — treating
 * anything that did not obviously pass as caught — turns an unapplied mutation
 * into a free pass, which is the exact false-green the mutation stage exists to
 * catch. `caught` is therefore only ever true on real evidence: the tests ran,
 * and they failed. Everything else is a skip, reported as not checked rather
 * than counted either way.
 */

/**
 * Renders mutation outcomes for the reviewer and the record.
 *
 * Deliberately states the survivors first and plainly. A surviving mutation is
 * the strongest possible evidence that a milestone's tests do not pin its claim
 * — stronger than any reading of the diff, because it was tried.
 */
/**
 * Decides whether one applied mutation was caught.
 *
 * Pulled out as its own function because the tempting shorthand — treating
 * anything that did not obviously pass as caught — turns an unapplied mutation
 * into a free pass, which is the exact false-green the mutation stage exists to
 * catch. `caught` is therefore only ever true on real evidence: the tests ran,
 * and they failed. Everything else is a skip, reported as not checked rather
 * than counted either way.
 */
export function judgeMutation(
  mutation: Pick<Mutation, 'describes' | 'file'>,
  outcome: { applied: true; result: TestResult | null } | { applied: false; reason: string },
): MutationResult {
  const base = { describes: mutation.describes, file: mutation.file }
  if (!outcome.applied) {
    return { ...base, caught: false, skipped: outcome.reason, skipKind: 'unapplied', exitCode: null }
  }
  const test = outcome.result
  if (test === null) {
    return {
      ...base,
      caught: false,
      skipped: 'this milestone has no verification command',
      skipKind: 'no-test-command',
      exitCode: null,
    }
  }
  // A crash or a timeout is not the suite noticing the break. A suite that dies on
  // any malformed input would "catch" every mutation while checking nothing, which
  // is the precise false green this stage exists to detect — so an abnormal run is
  // recorded as having proved nothing rather than as a pass. Timeout first: it is
  // delivered as a SIGTERM and would otherwise read as a crash.
  if (test.timedOut) {
    return {
      ...base,
      caught: false,
      skipped: 'the suite timed out under this mutation, so it proved nothing',
      skipKind: 'crashed',
      exitCode: test.exitCode,
    }
  }
  if (test.signal) {
    return {
      ...base,
      caught: false,
      skipped: `the suite was killed by ${test.signal} under this mutation, so it proved nothing`,
      skipKind: 'crashed',
      exitCode: test.exitCode,
    }
  }
  return { ...base, caught: test.exitCode !== 0, skipped: '', skipKind: '', exitCode: test.exitCode }
}

/**
 * Applies one mutation, runs something, and restores the file whatever happens.
 *
 * Split out of the pipeline because this is the only part of Parley that
 * deliberately corrupts a file in the user's repository, and it must be provable
 * in isolation that it always puts it back. The original content is held in
 * memory for the duration and rewritten in a `finally`; a failure to restore
 * throws loudly rather than being swallowed, because a silently mutated file
 * would poison every subsequent run and every review after it.
 *
 * Edited in place rather than on a copy on purpose: the verification command is
 * only known to work in the real tree, where relative paths, installed
 * dependencies and engine project files resolve. A mutation check that ran
 * somewhere else would be measuring a different thing.
 */

/**
 * Applies one mutation, runs something, and restores the file whatever happens.
 *
 * Split out of the pipeline because this is the only part of Parley that
 * deliberately corrupts a file in the user's repository, and it must be provable
 * in isolation that it always puts it back. The original content is held in
 * memory for the duration and rewritten in a `finally`; a failure to restore
 * throws loudly rather than being swallowed, because a silently mutated file
 * would poison every subsequent run and every review after it.
 *
 * Edited in place rather than on a copy on purpose: the verification command is
 * only known to work in the real tree, where relative paths, installed
 * dependencies and engine project files resolve. A mutation check that ran
 * somewhere else would be measuring a different thing.
 */
export async function withMutationApplied<T>(
  repoPath: string,
  mutation: Mutation,
  run: () => Promise<T>,
): Promise<{ applied: true; result: T } | { applied: false; reason: string }> {
  const target = join(repoPath, mutation.file)

  // `file` comes from a model, so it is checked rather than trusted.
  const lexicalRelative = relative_(repoPath, target)
  if (lexicalRelative.startsWith('..') || isAbsolute(lexicalRelative) || lexicalRelative === '') {
    return { applied: false, reason: 'that path resolves outside the repository' }
  }
  if (!existsSync(target)) return { applied: false, reason: 'that file does not exist' }

  // Resolved, not lexical. `relative()` compares strings, so a symlink that lives
  // inside the repository but points outside it passes the check — and writeFileSync
  // follows the link. The path comes from a model, so the containment has to hold
  // against the real filesystem rather than against how the path is spelled.
  let realTarget: string
  let realRoot: string
  try {
    realTarget = realpathSync(target)
    realRoot = realpathSync(repoPath)
  } catch (err) {
    return { applied: false, reason: `could not resolve it: ${err instanceof Error ? err.message : String(err)}` }
  }
  const relative = relative_(realRoot, realTarget)
  if (relative.startsWith('..') || isAbsolute(relative) || relative === '') {
    return { applied: false, reason: 'that path resolves outside the repository' }
  }

  let original: string
  try {
    original = readFileSync(target, 'utf8')
  } catch (err) {
    return { applied: false, reason: `could not read it: ${err instanceof Error ? err.message : String(err)}` }
  }

  // Exactly once, or the edit is ambiguous and so is any conclusion from it.
  const occurrences = original.split(mutation.find).length - 1
  if (occurrences !== 1) {
    return {
      applied: false,
      reason:
        occurrences === 0
          ? 'the text to replace was not found'
          : `the text to replace appears ${occurrences} times, so the edit is ambiguous`,
    }
  }

  try {
    writeFileSync(target, original.replace(mutation.find, mutation.replace), 'utf8')
    return { applied: true, result: await run() }
  } finally {
    try {
      writeFileSync(target, original, 'utf8')
    } catch (err) {
      throw new PipelineError(
        `A mutation check could not restore ${mutation.file}: ${err instanceof Error ? err.message : String(err)}. ` +
          `That file is left modified and must be reverted by hand before trusting anything else.`,
      )
    }
  }
}

/**
 * Decides whether the deterministic half of a milestone passed.
 *
 * Separate from the reviewer's judgement, and pure, because these are the facts:
 * a command exited non-zero, a declared break went unnoticed, a declared break
 * could not be applied at all. None of them is a matter of opinion, so none of
 * them is left to one.
 *
 * The three failing conditions are deliberately all fatal. Earlier only the first
 * two were, and the third — a check that could not be applied — passed silently on
 * the assumption the reviewer would notice the gap. That is the same soft signal
 * this pipeline keeps having to remove: it works exactly until the one time it
 * matters.
 */

/**
 * Decides whether the deterministic half of a milestone passed.
 *
 * Separate from the reviewer's judgement, and pure, because these are the facts:
 * a command exited non-zero, a declared break went unnoticed, a declared break
 * could not be applied at all. None of them is a matter of opinion, so none of
 * them is left to one.
 *
 * The three failing conditions are deliberately all fatal. Earlier only the first
 * two were, and the third — a check that could not be applied — passed silently on
 * the assumption the reviewer would notice the gap. That is the same soft signal
 * this pipeline keeps having to remove: it works exactly until the one time it
 * matters.
 */
export function milestoneVerdict(
  testResult: TestResult | null,
  mutationResults: MutationResult[],
): {
  testsPassed: boolean
  surviving: MutationResult[]
  unverifiable: MutationResult[]
  notRunnable: MutationResult[]
} {
  const surviving = mutationResults.filter((m) => !m.caught && !m.skipped)
  const unverifiable = mutationResults.filter(
    (m) => m.skipKind === 'unapplied' || m.skipKind === 'crashed',
  )
  const notRunnable = mutationResults.filter((m) => m.skipKind === 'no-test-command')
  const testsPassed =
    (testResult === null || testResult.exitCode === 0) &&
    surviving.length === 0 &&
    unverifiable.length === 0
  return { testsPassed, surviving, unverifiable, notRunnable }
}


export function summariseMutations(results: MutationResult[]): string {
  if (!results.length) return ''
  const lines: string[] = []
  for (const r of results) {
    if (r.skipKind === 'unapplied') {
      // Named as blocking here because it is: the reviewer should not read this as a
      // harmless gap it may wave through, having already had a repair round.
      lines.push(
        `  COULD NOT BE CHECKED (blocking) — ${r.file}: ${r.describes}. ${r.skipped}.`,
      )
    } else if (r.skipped) {
      lines.push(`  NOT CHECKED — ${r.file}: ${r.describes}. ${r.skipped}.`)
    } else if (r.caught) {
      lines.push(`  CAUGHT — ${r.file}: ${r.describes}. The suite failed as it should.`)
    } else {
      lines.push(
        `  SURVIVED — ${r.file}: ${r.describes}. The suite still passed, so nothing in it pins this.`,
      )
    }
  }
  return lines.join('\n')
}


export function tail(text: string, max: number): string {
  if (text.length <= max) return text
  return `…${text.slice(-max)}`
}



const MAX_DIFF_CHARS = 120_000


function stringList(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((v): v is string => typeof v === 'string' && v.trim().length > 0).slice(0, 30)
    : []
}


async function readChangedFiles(
  repoPath: string,
  paths: string[],
  signal?: AbortSignal,
): Promise<TreeFileSnapshot[]> {
  // Bounded fan-out. This used to Promise.all the whole path list with two git
  // spawns each — a dirty node_modules meant tens of thousands of concurrent
  // processes, and a spawn that failed under that load made the file read as
  // absent on both sides, which sameContent then called unchanged.
  const CONCURRENT = 8
  const out: TreeFileSnapshot[] = []
  for (let start = 0; start < paths.length; start += CONCURRENT) {
    const batch = paths.slice(start, start + CONCURRENT)
    const settled = await Promise.all(
      batch.map((rel, offset) => readOneChangedFile(repoPath, rel, start + offset, signal)),
    )
    out.push(...settled)
  }
  return out
}


function contentAt(state: TreeState, other: TreeState, path: string): FileContent | undefined {
  const own = state.files.find((file) => file.path === path)
  if (own) {
    return {
      text: own.text,
      truncated: own.truncated,
      exists: own.exists,
      digest: own.digest,
      digestKnown: own.digestKnown,
    }
  }

  if (state.paths.includes(path)) return undefined

  const counterpart = other.files.find((file) => file.path === path)
  if (!counterpart) return undefined
  return {
    text: counterpart.headText,
    truncated: counterpart.headTruncated,
    exists: counterpart.headExists,
    digest: counterpart.headDigest,
    digestKnown: counterpart.headDigestKnown,
  }
}


function sameContent(left: FileContent, right: FileContent): boolean {
  // Two genuinely absent sides are the one same-without-a-digest case. Anything
  // else without both digests is UNKNOWN, and unknown must never read as
  // unchanged: the failure mode this guards against is a git spawn failing under
  // load, both sides reporting not-exists, and a file the milestone edited being
  // filed under "NOT part of this milestone" because two failures compared equal.
  if (!left.exists && !right.exists) return left.digestKnown && right.digestKnown
  if (!left.exists || !right.exists) return false
  return left.digest !== null && right.digest !== null && left.digest === right.digest
}


function contentPatch(path: string, before: FileContent, after: FileContent): string {
  const oldLines = before.text?.split('\n') ?? []
  const newLines = after.text?.split('\n') ?? []
  if (oldLines.at(-1) === '') oldLines.pop()
  if (newLines.at(-1) === '') newLines.pop()

  // A real per-line diff, not a single prefix/suffix hunk. The collapse version
  // rendered an edit at line 5 plus an edit at line 145 as one hunk that removed
  // and re-added every line between them — attributing ~140 untouched lines to
  // the milestone, which is the exact misattribution this renderer exists to end.
  // Inputs are bounded snapshots (≤ MAX_CHANGED_FILE_CHARS), so quadratic LCS is
  // a few hundred lines square at worst.
  const ops = diffLines(oldLines, newLines)

  const CONTEXT = 3
  const hunks: string[][] = []
  let current: string[] | null = null
  let oldLine = 0
  let newLine = 0
  let hunkOldStart = 0
  let hunkNewStart = 0
  let hunkOldCount = 0
  let hunkNewCount = 0
  let trailingContext = 0

  const flush = (): void => {
    if (!current) return
    // Trim context beyond CONTEXT lines at the hunk's tail.
    while (trailingContext > CONTEXT) {
      current.pop()
      trailingContext -= 1
      hunkOldCount -= 1
      hunkNewCount -= 1
    }
    hunks.push([
      `@@ -${hunkOldStart + 1},${hunkOldCount} +${hunkNewStart + 1},${hunkNewCount} @@`,
      ...current,
    ])
    current = null
  }

  for (const op of ops) {
    if (op.kind === 'same') {
      if (current) {
        current.push(` ${op.line}`)
        trailingContext += 1
        hunkOldCount += 1
        hunkNewCount += 1
        // Once enough context has accumulated after a change, the hunk can close;
        // a later change opens a fresh one instead of dragging this one along.
        if (trailingContext >= CONTEXT * 2) flush()
      }
      oldLine += 1
      newLine += 1
      continue
    }
    if (!current) {
      const lead = Math.min(CONTEXT, oldLine, newLine)
      hunkOldStart = oldLine - lead
      hunkNewStart = newLine - lead
      hunkOldCount = lead
      hunkNewCount = lead
      current = oldLines.slice(oldLine - lead, oldLine).map((line) => ` ${line}`)
    }
    trailingContext = 0
    if (op.kind === 'del') {
      current.push(`-${op.line}`)
      hunkOldCount += 1
      oldLine += 1
    } else {
      current.push(`+${op.line}`)
      hunkNewCount += 1
      newLine += 1
    }
  }
  flush()

  const body = hunks.flat()
  if (before.truncated || after.truncated) body.push('[snapshot truncated]')
  return [`--- a/${path}`, `+++ b/${path}`, ...body].join('\n')
}

/** Line-level LCS diff. Bounded inputs only — this is quadratic by design. */


async function readOneChangedFile(
  repoPath: string,
  rel: string,
  index: number,
  signal?: AbortSignal,
): Promise<TreeFileSnapshot> {
  const object = `HEAD:${rel}`
  // Absence is a filesystem fact, not a git exit code: hash-object fails the
  // same way for a missing file and for a spawn that died, and those must land
  // differently — absent is a real state, unhashable is unknown.
  const exists = existsSync(join(repoPath, rel))
  const [currentHash, headHash] = await Promise.all([
    exists
      ? capture('git', ['hash-object', `--path=${rel}`, '--', rel], repoPath, 60_000, signal)
      : Promise.resolve(null),
    capture('git', ['rev-parse', '--verify', object], repoPath, 60_000, signal),
  ])
  const digest = currentHash && currentHash.exitCode === 0 ? currentHash.stdout.trim() : null
  const digestKnown = !exists || digest !== null
  const headExists = headHash.exitCode === 0
  let current = { text: null as string | null, truncated: false }
  let head = { text: null as string | null, truncated: false }

  if (index < MAX_CHANGED_FILES) {
    current = readBoundedFile(join(repoPath, rel))
    if (headExists) {
      const size = await capture(
        'git',
        ['cat-file', '-s', headHash.stdout.trim()],
        repoPath,
        60_000,
        signal,
      )
      const bytes = Number.parseInt(size.stdout.trim(), 10)
      if (size.exitCode === 0 && Number.isFinite(bytes) && bytes <= 2 * MAX_CHANGED_FILE_CHARS * 4) {
        const shown = await capture('git', ['show', object], repoPath, 60_000, signal)
        if (shown.exitCode === 0) {
          head = {
            text: shown.stdout.slice(0, MAX_CHANGED_FILE_CHARS),
            truncated: shown.stdout.length > MAX_CHANGED_FILE_CHARS,
          }
        }
      } else {
        head.truncated = true
      }
    }
  } else {
    current.truncated = exists
    head.truncated = headExists
  }

  return {
    path: rel,
    text: current.text,
    truncated: current.truncated,
    exists,
    digest,
    digestKnown,
    headText: head.text,
    headTruncated: head.truncated,
    headExists,
    headDigest: headExists ? headHash.stdout.trim() : null,
    // rev-parse failing for a path legitimately absent from HEAD and failing
    // because the spawn died are indistinguishable; the conservative reading —
    // treat it as a new file — over-attributes to the milestone rather than
    // silently excusing it.
    headDigestKnown: true,
  }
}


interface FileContent {
  text: string | null
  truncated: boolean
  exists: boolean
  digest: string | null
  digestKnown: boolean
}


function diffLines(
  oldLines: string[],
  newLines: string[],
): Array<{ kind: 'same' | 'del' | 'add'; line: string }> {
  const n = oldLines.length
  const m = newLines.length
  // lcs[i][j] = longest common subsequence length of old[i..] and new[j..]
  const lcs: Int32Array[] = Array.from({ length: n + 1 }, () => new Int32Array(m + 1))
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      lcs[i]![j] =
        oldLines[i] === newLines[j]
          ? lcs[i + 1]![j + 1]! + 1
          : Math.max(lcs[i + 1]![j]!, lcs[i]![j + 1]!)
    }
  }
  const ops: Array<{ kind: 'same' | 'del' | 'add'; line: string }> = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (oldLines[i] === newLines[j]) {
      ops.push({ kind: 'same', line: oldLines[i]! })
      i += 1
      j += 1
    } else if (lcs[i + 1]![j]! >= lcs[i]![j + 1]!) {
      ops.push({ kind: 'del', line: oldLines[i]! })
      i += 1
    } else {
      ops.push({ kind: 'add', line: newLines[j]! })
      j += 1
    }
  }
  while (i < n) ops.push({ kind: 'del', line: oldLines[i++]! })
  while (j < m) ops.push({ kind: 'add', line: newLines[j++]! })
  return ops
}



const MAX_CHANGED_FILES = 40

function readBoundedFile(full: string): { text: string | null; truncated: boolean } {
  try {
    if (!existsSync(full)) return { text: null, truncated: false }
    // Skip anything too large to be source, rather than reading it to throw
    // most of it away.
    if (statSync(full).size > 2 * MAX_CHANGED_FILE_CHARS * 4) {
      return { text: null, truncated: true }
    }
    const text = readFileSync(full, 'utf8')
    return {
      text: text.slice(0, MAX_CHANGED_FILE_CHARS),
      truncated: text.length > MAX_CHANGED_FILE_CHARS,
    }
  } catch {
    // Binary, unreadable, or vanished between the listing and now.
    return { text: '(unreadable)', truncated: false }
  }
}



export async function revParseHead(repoPath: string, signal?: AbortSignal): Promise<string> {
  const result = await capture('git', ['rev-parse', 'HEAD'], repoPath, 30_000, signal)
  return result.exitCode === 0 ? result.stdout.trim() : ''
}

