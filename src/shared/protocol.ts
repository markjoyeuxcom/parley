import type { AgentConfig, SessionKind } from './domain'

/**
 * Turn protocols.
 *
 * Two properties matter and are load-bearing:
 *
 *  1. **Only the opponent's latest message is relayed.** Each CLI keeps its own
 *     conversation state and is resumed by session id, so Parley never replays
 *     the whole transcript. Token cost stays linear in turns rather than
 *     quadratic.
 *
 *  2. **Neither side writes the verdict alone.** After the exchange, both sides
 *     independently emit a structured verdict and Parley merges them. Divergence
 *     lowers recorded confidence instead of being smoothed away — see
 *     `mergeVerdicts` in the orchestrator.
 */

export interface StageSpec {
  /** Stable identifier persisted on each turn. */
  id: string
  /** Shown in the UI next to the turn. */
  label: string
  /** Which participant speaks — an index into the session's seating order. */
  seat: number
}

/**
 * Debate: stake a position, attack it, refine under pressure, then converge.
 *
 * `maxTurns` trims the middle — the opening and the convergence turn are always
 * present, so a 2-turn debate is still a complete (if shallow) exchange.
 *
 * Still a two-seat schedule on purpose: the attack/refine shape has no meaning
 * for a third seat until the closing sequence is redesigned around roles, which
 * is that milestone's work, not this one's. Seats 0 and 1 are the old sides a
 * and b.
 */
export function debateStages(maxTurns: number): StageSpec[] {
  const stages: StageSpec[] = [{ id: 'open', label: 'Position', seat: 0 }]
  let seat = 1
  let round = 1
  while (stages.length < maxTurns - 1) {
    stages.push(
      seat === 1
        ? { id: `attack.${round}`, label: round === 1 ? 'Challenge' : `Challenge ${round}`, seat: 1 }
        : { id: `refine.${round}`, label: round === 1 ? 'Defence' : `Defence ${round}`, seat: 0 },
    )
    if (seat === 0) round += 1
    seat = seat === 0 ? 1 : 0
  }
  stages.push({ id: 'converge', label: 'Convergence', seat })
  return stages
}

/**
 * Review: map the territory, audit it independently, then cross-examine each
 * other's findings. The cross-examination is the point — a finding only reaches
 * `confirmed` if the *other* agent corroborates it against the code.
 */
export function reviewStages(): StageSpec[] {
  return [
    { id: 'map', label: 'Architecture map', seat: 0 },
    { id: 'audit', label: 'Independent audit', seat: 1 },
    { id: 'crossAudit', label: 'Cross-examination', seat: 0 },
    { id: 'reconcile', label: 'Reconciliation', seat: 1 },
  ]
}

export function stagesFor(kind: SessionKind, maxTurns: number): StageSpec[] {
  return kind === 'debate' ? debateStages(maxTurns) : reviewStages()
}

// ─── System prompts ──────────────────────────────────────────────────────────

const NO_FLATTERY = `Do not open with praise, restatement of the question, or meta-commentary about the exercise. Start with substance. Never describe your own output as thorough, comprehensive, or careful — let it be judged on content.`

/** Stances are positional until the role-selector redesign: seat 0 affirms. */
export function debateSystemPrompt(seat: number, cfg: AgentConfig): string {
  const stance =
    seat === 0
      ? `You argue the affirmative. Take a clear, falsifiable position and defend it honestly. When the other side lands a real hit, concede that specific point explicitly and adjust — do not defend an indefensible detail to protect the whole.`
      : `You argue the negative. Your job is to find the strongest available objection, not the easiest one. Attack the load-bearing assumption, not the phrasing. If the position is substantially correct, say so and narrow your objection to what genuinely fails — a manufactured disagreement wastes the exercise.`

  return [
    `You are one of two independent engineering advisors, from different model families, working a question to a decision. You will not see the full transcript — only the other advisor's most recent message. Rely on your own retained context for the rest.`,
    stance,
    `Be concrete. Prefer specific mechanisms, failure modes, and numbers over adjectives. Cite concrete tradeoffs rather than listing generic considerations.`,
    NO_FLATTERY,
    cfg.persona.trim() ? `Additional persona: ${cfg.persona.trim()}` : '',
  ]
    .filter(Boolean)
    .join('\n\n')
}

/** Roles are positional until the role-selector redesign: seat 0 maps. */
export function reviewSystemPrompt(seat: number, cfg: AgentConfig): string {
  const stance =
    seat === 0
      ? `You are the Codebase Cartographer. You map structure and data flow, then later cross-examine the reviewer's findings against the actual code. You are the check on false positives: a finding you cannot corroborate by reading the referenced file must be marked unsupported, however plausible it sounds.`
      : `You are the Principal Reviewer. You find defects that will actually bite: correctness bugs, unhandled failure modes, security exposure, race conditions, missing verification. Rank by consequence, not by how easy the fix is. Style opinions are out of scope.`

  return [
    `You are one of two independent reviewers, from different model families, auditing a repository. This is read-only analysis: you cannot and must not modify the repository.`,
    stance,
    `Every claim must be anchored to evidence — a file path, and a line or symbol you actually read. A finding without evidence is not a finding.`,
    NO_FLATTERY,
    cfg.persona.trim() ? `Additional persona: ${cfg.persona.trim()}` : '',
  ]
    .filter(Boolean)
    .join('\n\n')
}

// ─── Stage prompts ───────────────────────────────────────────────────────────

export interface StagePromptInput {
  stage: StageSpec
  matter: string
  repoPath: string | null
  /** The other side's most recent message, or null on the opening turn. */
  opponentMessage: string | null
  /** Human interjections addressed to this side, already filtered. */
  interjections: string[]
}

function interjectionBlock(interjections: string[]): string {
  if (interjections.length === 0) return ''
  return [
    ``,
    `--- DIRECTION FROM THE HUMAN DIRECTOR ---`,
    `These instructions come from the person running this session. They take precedence over the other advisor's arguments. Address them directly.`,
    ...interjections.map((t) => `• ${t}`),
    `--- END DIRECTION ---`,
  ].join('\n')
}

export function debatePrompt(input: StagePromptInput): string {
  const { stage, matter, opponentMessage } = input
  const parts: string[] = [`THE MATTER:\n${matter}`]

  if (stage.id === 'open') {
    parts.push(
      `Open the exchange. State your position in at most 400 words: what you would do, the single strongest reason, and the one condition under which you would be wrong.`,
    )
  } else if (stage.id === 'converge') {
    parts.push(
      `The other advisor's latest message:\n\n${opponentMessage ?? '(none)'}`,
      `Close the exchange. In at most 300 words: name what you both now agree on, name precisely what remains unresolved, and state your final recommendation. Do not introduce new arguments.`,
    )
  } else if (stage.id.startsWith('attack')) {
    parts.push(
      `The other advisor's latest message:\n\n${opponentMessage ?? '(none)'}`,
      `Find the strongest objection to what they just argued. In at most 350 words: name the specific assumption that fails, describe the concrete scenario where it fails, and say what would have to be true for their position to survive.`,
    )
  } else {
    parts.push(
      `The other advisor's latest message:\n\n${opponentMessage ?? '(none)'}`,
      `Respond in at most 350 words. Concede any point that landed — explicitly, by name. Then defend what still stands, addressing their actual scenario rather than restating your original case.`,
    )
  }

  parts.push(interjectionBlock(input.interjections))
  return parts.filter(Boolean).join('\n\n')
}

export function reviewPrompt(input: StagePromptInput): string {
  const { stage, matter, repoPath, opponentMessage } = input
  const parts: string[] = [
    `REPOSITORY: ${repoPath ?? '(none attached)'}`,
    `REVIEW BRIEF:\n${matter}`,
  ]

  switch (stage.id) {
    case 'map':
      parts.push(
        `Map the repository. Identify the entry points, the major modules and their responsibilities, how data and control flow between them, where external I/O and untrusted input enter, and where the verification (tests, checks) actually lives. Note anything structurally surprising. At most 700 words. Reference real paths.`,
      )
      break
    case 'audit':
      parts.push(
        `Architecture map from the other reviewer:\n\n${opponentMessage ?? '(none)'}`,
        `Now audit the code yourself. Read the files that matter — do not rely on the map alone; it may be wrong. Report defects that would cause incorrect behaviour, data loss, security exposure, or silent failure.`,
        FINDINGS_CONTRACT,
      )
      break
    case 'crossAudit':
      parts.push(
        `The reviewer's findings:\n\n${opponentMessage ?? '(none)'}`,
        `Cross-examine each finding against the actual code. For every one, open the referenced file and decide: does it hold as described? Mark it confirmed only if you independently verified it. Mark it dismissed if you checked and it does not hold, and say what the code actually does. Mark it unsupported if the evidence given is insufficient to tell. Add any defect the reviewer missed that you found while checking.`,
        FINDINGS_CONTRACT,
      )
      break
    default:
      parts.push(
        `The cross-examination:\n\n${opponentMessage ?? '(none)'}`,
        `Produce the final reconciled finding list. Drop anything dismissed with a concrete counter-explanation. Keep dismissed findings in the output with status "dismissed" — the record of what was investigated and cleared is part of the value. Assign final priorities: P0 breaks correctness or security now, P1 will bite under realistic conditions, P2 is a latent hazard, P3 is worth knowing.`,
        FINDINGS_CONTRACT,
      )
  }

  parts.push(interjectionBlock(input.interjections))
  return parts.filter(Boolean).join('\n\n')
}

// ─── Structured output contracts ─────────────────────────────────────────────

/**
 * Both CLIs stream prose. To get machine-readable results we ask for one fenced
 * JSON block at the end of the message and extract it. Prose above it is kept
 * and shown as the turn body, so nothing is lost if the JSON is malformed.
 */
export const FINDINGS_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "findings": [
    {
      "title": "short, specific claim",
      "detail": "what goes wrong and under what conditions",
      "priority": "P0" | "P1" | "P2" | "P3",
      "status": "confirmed" | "dismissed" | "unsupported",
      "evidence": [{ "path": "relative/path.ts", "line": 42, "symbol": "fnName", "excerpt": "the line you read" }]
    }
  ]
}
\`\`\`

Rules: a "confirmed" finding must have at least one evidence entry with a real path you opened. Use [] for evidence only when status is "unsupported". Write the prose analysis above the block; put nothing after it.`.trim()

export const VERDICT_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "decision": "one sentence: what should be done",
  "rationale": "why, in at most 120 words",
  "confidence": 0.0,
  "scores": {
    "correctness": 0,
    "robustness": 0,
    "clarity": 0,
    "maintainability": 0,
    "risk": 0
  },
  "dissent": "what you still disagree with, or empty string if nothing"
}
\`\`\`

Scores are 0–10 and describe the *recommended course of action*, not the debate. "risk" is scored so that 10 means lowest risk. "confidence" is 0–1 and is your own credence — do not inflate it to signal agreement. If you still disagree with the other advisor on something material, put it in "dissent" rather than dropping it.`.trim()

/** Asks each side, independently, for its own structured verdict. */
export function verdictPrompt(matter: string, kind: SessionKind): string {
  return [
    kind === 'debate'
      ? `The exchange is over. Independently record your own verdict on the matter.`
      : `The review is over. Independently record your own verdict on the state of this codebase.`,
    `THE MATTER:\n${matter}`,
    `Do not try to guess or match the other advisor's verdict. If you disagree with them, that disagreement is the most useful thing you can record.`,
    VERDICT_CONTRACT,
  ].join('\n\n')
}

// ─── Audited execution pipeline ──────────────────────────────────────────────

export const PLAN_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "title": "short plan title",
  "milestones": [
    {
      "title": "short imperative title",
      "intent": "what changes and why, in at most 60 words",
      "expectedPaths": ["src/a.ts", "src/b.ts"],
      "testCommand": "the exact command that verifies this milestone, or empty string",
      "mutations": [
        { "file": "src/a.ts", "find": "exact text to break", "replace": "the broken version", "describes": "the mistake this simulates" }
      ]
    }
  ]
}
\`\`\`

Rules: order milestones so each leaves the repository in a working state. Keep milestones small enough to review as a single diff. Do not include a milestone that only writes documentation unless the brief asked for it.

How the workbench will use these fields — write them to suit it:

• "testCommand" is run by the workbench itself, spawned directly with **no shell**. A command containing &&, ||, |, >, <, $(...), backticks, ~ or * will be refused and the milestone will go unverified. Give one command. If a milestone genuinely needs several steps, name a script in the repository that does them, or pick the single command that most nearly proves the milestone.
• "expectedPaths" is not decoration. The workbench checks these paths after execution and reports any that do not exist, so name the files the milestone will actually create or change — no more, and no fewer.
• "mutations" is how a milestone proves its tests are worth anything. Passing tests only show the code works on the paths someone thought to write; they say nothing about whether a *wrong* implementation would have been caught. For each milestone, name the plausible wrong implementations its tests are supposed to exclude — then the workbench applies each one and requires the verification command to **fail**. A mutation that survives means the milestone's central claim rests on nothing, and it counts against the milestone exactly like a failing test.
  Write them as an exact "find" string that appears **once** in the file, and a "replace" that is a mistake a competent engineer might actually make: a hardcoded return value, a dropped guard, a comparison against a constant instead of derived state, an early return that skips the work. Two or three per milestone is usually enough; aim them at the milestone's own claim, not at incidentals. If you genuinely cannot think of a wrong implementation the tests would miss, give an empty array and say so — an honest empty list is better than a mutation aimed at a comment.
• The reviewer is shown the whole working tree, including new files, not only the paths you listed.`.trim()

/**
 * How a planning-stage agent escalates instead of guessing.
 *
 * Guessing at a genuinely ambiguous brief produces a confident plan built on an
 * assumption nobody agreed to, and the assumption is invisible by the time it
 * reaches review. One question is cheaper than a wrong plan — but only one, and
 * only when the answer actually changes what gets built.
 */
export const CLARIFICATION_CONTRACT = `
If — and only if — you cannot proceed without a decision that is genuinely the
user's to make, reply with a single fenced JSON block of exactly this shape and
nothing else:

\`\`\`json
{
  "clarification": "one consolidated question",
  "context": "why this blocks you, and what the realistic options are"
}
\`\`\`

Use this for a real fork in the work, not for a preference you could pick
sensibly yourself and note in the plan. You get one question, so consolidate.`.trim()

/**
 * Guidance that differs entirely depending on whether there is a codebase.
 *
 * The established wording tells the planner to follow what is already there. On
 * an empty repository that instruction has no referent, so the planner either
 * hedges or invents conventions and presents them as the project's own.
 */
function planGrounding(greenfield: boolean): string {
  return greenfield
    ? `This repository is empty. You are **establishing** the conventions, not discovering them — so choose them deliberately and say why: the language and runtime, the test runner, the directory layout, the build. Prefer boring, widely-used choices unless the brief argues otherwise.\n\nThe first milestone must scaffold enough that a real verification command can run at all — a project whose tests cannot be invoked until milestone four cannot be verified until milestone four.`
    : `Read enough of the codebase to make the plan concrete — real file paths, the project's actual test command, its actual conventions. A plan that names the wrong files is worse than no plan.`
}

export function planPrompt(
  kind: string,
  brief: string,
  repoPath: string,
  answer = '',
  greenfield = false,
): string {
  return [
    greenfield
      ? `You are planning a ${kind} for a new project in an empty directory. This turn is READ-ONLY: produce a plan, do not create anything.`
      : `You are planning a ${kind} change. This turn is READ-ONLY: inspect the repository and produce a plan. Do not modify anything.`,
    `REPOSITORY: ${repoPath}${greenfield ? ' (empty — nothing has been written yet)' : ''}`,
    `BRIEF:\n${brief}`,
    planGrounding(greenfield),
    answer
      ? `THE USER HAS ANSWERED YOUR QUESTION:\n${answer}\n\nProceed on that basis. Do not ask again.`
      : CLARIFICATION_CONTRACT,
    PLAN_CONTRACT,
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * The planner answering its own audit.
 *
 * This is the stage that turns the audit from a report into an exchange. Without
 * it the auditor's findings reach the human but never the plan, and the thing
 * that gets executed is the original, unamended draft.
 *
 * Every finding must be dispositioned. Silence on a finding is the failure mode
 * — it lets an inconvenient objection disappear between stages.
 */
export function correctionPrompt(input: {
  planText: string
  auditText: string
  auditorVendor: string
  repoPath: string
  answer?: string
}): string {
  return [
    `You wrote the plan below. ${input.auditorVendor} audited it independently and its findings follow. Correct your plan. This turn is READ-ONLY.`,
    `REPOSITORY: ${input.repoPath}`,
    `YOUR PLAN:\n${input.planText}`,
    `THE INDEPENDENT AUDIT:\n${input.auditText}`,
    `Record a disposition for every finding — accepted, partly accepted, rejected with evidence, or deferred with a reason. Do not silently drop one, and do not defer a correctness or safety objection merely to keep your original shape. If the auditor is wrong, say so and show why from the repository.`,
    `Then reissue the plan in full, amended. Milestones may be added, split, reordered or removed.`,
    input.answer
      ? `THE USER HAS ANSWERED YOUR QUESTION:\n${input.answer}\n\nProceed on that basis. Do not ask again.`
      : CLARIFICATION_CONTRACT,
    CORRECTION_CONTRACT,
  ]
    .filter(Boolean)
    .join('\n\n')
}

export const CORRECTION_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "dispositions": [
    { "finding": "the auditor's objection, in your own words", "disposition": "accepted" | "partly-accepted" | "rejected" | "deferred", "note": "what you changed, or why you did not" }
  ],
  "title": "short plan title",
  "milestones": [
    {
      "title": "short imperative title",
      "intent": "what changes and why, in at most 80 words",
      "expectedPaths": ["src/a.ts"],
      "testCommand": "one shell-free command, or empty string",
      "mutations": [
        { "file": "src/a.ts", "find": "exact text to break", "replace": "the broken version", "describes": "the mistake this simulates" }
      ]
    }
  ]
}
\`\`\`

Every audit finding needs an entry in "dispositions". The "milestones" array is the corrected plan in full, not a diff against the original — the same field rules apply as before, including the no-shell rule for "testCommand".

**Whoever builds a milestone sees that milestone and nothing else** — its title, intent and expected paths. Your dispositions explain your reasoning to a human reader; they are not instructions anyone will act on. So every decision that changes what gets built must appear in the milestone's own "intent", written as the requirement itself rather than as a reference to the argument you had.

Concretely: if a finding asked for a strict check and you decided a looser one is correct, the intent must say which check to build. Writing "add a version guard" in the intent while the decision about *what kind* of guard lives only in a disposition means the guard gets built the way the finding asked for — your correction is the part that gets lost. The intent budget is 80 rather than 60 words because it now has to carry these decisions.`.trim()

export const AUDIT_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "verdict": "sound" | "needs-changes" | "unsound",
  "dispositions": [
    { "milestone": 0, "disposition": "accept" | "revise" | "reject", "note": "why, in at most 40 words" }
  ],
  "blockingConcerns": ["concern that must be resolved before any execution"]
}
\`\`\`

Rules: index milestones from 0 in the order given. "unsound" means the plan should not be executed at all. Be specific — "milestone 2 edits a generated file" is useful, "could be clearer" is not.`.trim()

export function auditPrompt(planJson: string, repoPath: string, greenfield = false): string {
  return [
    `You are auditing another engineer's implementation plan before any code is written. This turn is READ-ONLY.`,
    `REPOSITORY: ${repoPath}${greenfield ? ' (empty — this is a new project)' : ''}`,
    `THE PLAN:\n${planJson}`,
    // The established check is "do these paths exist?", which on an empty
    // repository answers "none of them" for every milestone — a false alarm
    // that would reject the whole plan for the one reason that is not a defect.
    greenfield
      ? `The repository is empty, so none of the named paths exist yet. That is expected: **do not report missing files as findings.** Audit the plan on its own terms instead. Is the ordering sound — does each milestone leave something that builds and runs? Can the verification command actually be invoked by the time it is first used, or does the plan assume a test runner it has not installed yet? Is the stack coherent, and are the choices justified rather than assumed? What has been left out entirely — configuration, entry point, the loop that makes it runnable at all?`
      : `Check it against the actual repository. Do the named files exist and contain what the plan assumes? Is the test command real and does it cover the change? Does the ordering leave the tree working at each step? Is anything missing that this change requires — a migration, a config update, a call site?`,
    `You did not write this plan. Your value is catching what its author assumed without checking.`,
    AUDIT_CONTRACT,
  ].join('\n\n')
}

/**
 * @param decisions The plan's correction record — what the auditor objected to
 *   and how the planner resolved each one.
 *
 *   Included because the milestone alone was not enough. A planner rejected an
 *   audit finding on good grounds, recorded the reasoning in a disposition, and
 *   wrote a summary of the *requirement* into the intent; the executor, seeing
 *   only the intent, implemented what the original finding had asked for. The
 *   decision existed and simply never reached the stage that acts on it. The
 *   milestone's own intent is still the contract — this is the record of what
 *   has already been argued, so it is not quietly re-argued in code.
 */
export function executePrompt(
  milestoneTitle: string,
  intent: string,
  expectedPaths: string[],
  repoPath: string,
  decisions = '',
  testCommand = '',
): string {
  // A runaway guard, not a budget. A real correction record runs to about 8k
  // characters, and dropping any of it drops rulings arbitrarily — whichever
  // happen not to be last. The reviewer in this same pipeline is handed up to
  // 120k characters of diff, so this costs nothing worth saving.
  const MAX_DECISIONS = 24_000
  const trimmedDecisions = decisions.trim()
  return [
    `Implement exactly one milestone. Nothing beyond it.`,
    `REPOSITORY: ${repoPath}`,
    `MILESTONE: ${milestoneTitle}`,
    `INTENT: ${intent}`,
    expectedPaths.length
      ? `The plan expects this to touch: ${expectedPaths.join(', ')}. If you must touch anything else, do it, but say so plainly at the end.`
      : ``,
    trimmedDecisions
      ? `ALREADY SETTLED — this plan was audited and the planner answered every finding. These decisions are made; do not reopen them, and where one bears on this milestone, build what was decided rather than what the finding originally asked for. If a decision looks wrong to you, implement it and say so at the end.\n\n${
          trimmedDecisions.length > MAX_DECISIONS
            ? `…${trimmedDecisions.slice(-MAX_DECISIONS)}`
            : trimmedDecisions
        }`
      : ``,
    // Told deliberately, because it was not before. An executor that does not
    // know what will check its work cannot aim at it, and one that does not know
    // the workbench runs that command may spend turns trying to run it itself —
    // which inside a CLI sandbox can fail in ways that look like a broken
    // repository rather than a blocked syscall. Real case: a Godot project whose
    // engine writes outside the workspace, so every attempt from inside the
    // sandbox aborted about a second in while the same command run by the
    // workbench passed cleanly.
    testCommand
      ? `HOW YOUR WORK WILL BE CHECKED. When you finish, the workbench runs this itself, outside your sandbox, on the tree you leave behind:\n\n    ${testCommand}\n\nWrite so that command passes. Run it yourself if you can — but if it fails in a way that looks like the toolchain rather than your change (a crash on startup, a permission error, an inability to write outside the working directory), that is your sandbox and not a defect you should try to fix. Say so at the end and leave it; the workbench's own run is the one that counts, and its output comes back to you if it fails.`
      : ``,
    `Match the surrounding code's conventions. Do not reformat untouched code, do not add commentary about what you did in code comments, and do not commit — leave the working tree dirty for review.`,
    `When done, state in two or three sentences what you changed and anything a reviewer should look at closely.`,
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Hands a rejection back to the agent that caused it.
 *
 * Sent on the executor's *resumed* session, so it still holds everything it did
 * and needs only the critique — not a restatement of the milestone. Rerunning
 * from scratch instead would discard that context and invite the same mistake.
 *
 * The framing is deliberately narrow: fix what was named, change nothing else. A
 * remediation round that wanders is worse than no remediation, because the
 * reviewer then has a larger diff to re-examine and the milestone's scope has
 * quietly grown.
 */
export function remediationPrompt(input: {
  round: number
  maxRounds: number
  concerns: string[]
  reviewerNote: string
  testSummary: string
  reviewerVendor: string
  /** Rendered outcome of the milestone's declared mutation checks. */
  mutationSummary?: string
}): string {
  const { round, maxRounds, concerns, reviewerNote, testSummary, reviewerVendor } = input
  const mutationSummary = input.mutationSummary ?? ''
  return [
    `Your work on this milestone was reviewed by ${reviewerVendor}, independently, and rejected. This is remediation round ${round} of ${maxRounds}.`,
    concerns.length
      ? `WHAT THE REVIEWER OBJECTED TO:\n${concerns.map((c) => `  • ${c}`).join('\n')}`
      : '',
    reviewerNote ? `THE REVIEWER'S ASSESSMENT:\n${reviewerNote}` : '',
    `DETERMINISTIC VERIFICATION (run by the workbench, not by an agent):\n${testSummary}`,
    // A milestone can fail with a passing suite and a passing review: a declared
    // break the tests were supposed to catch survived. When that is the whole
    // reason for the rejection, this block is the only actionable information in
    // the prompt — without it the executor is told "rejected", shown green
    // verification, and given nothing to fix.
    mutationSummary
      ? `MUTATION CHECKS (the workbench broke the code on purpose and re-ran the tests):\n${mutationSummary}\n\nA SURVIVED line means the suite still passed with that break in place. The fix is to strengthen the tests until the break is caught — not to change the behaviour the break simulates.`
      : '',
    `Address these specific objections and nothing else. Do not refactor around them, do not expand the milestone's scope, and do not weaken or delete a test to make a complaint go away — the reviewer will see the diff again and that is exactly what it is looking for.`,
    `If you believe an objection is wrong, say so plainly and explain why rather than silently ignoring it. A disagreement you argue is useful; one you bury is not.`,
    `When you are done, state in two or three sentences what you changed in response to each objection.`,
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * The reviewer's verdict.
 *
 * Split into "blocking" and "notes" for a reason found the hard way: with a
 * single undifferentiated list, a reviewer that spotted a real defect could
 * write it down and still pass the milestone, and did so on three consecutive
 * runs — a test harness that could report success having executed nothing,
 * state that could go stale behind correct events, and a snapshot that could
 * hardcode the two fields no test ever varied. Every one was found. Every one
 * shipped. The list was where a problem went to be acknowledged instead of
 * acted on.
 *
 * `parseReview` derives `passed` from `blocking` being empty rather than
 * trusting the flag, so naming a blocking problem *is* failing the milestone.
 * The reviewer cannot hold both positions any more.
 *
 * The neutralised-verification rule is named separately from the general
 * "unverified claim" rule because it has now appeared five times in six
 * milestones and was misfiled as advisory even after the split: a runner exiting
 * 0 having executed nothing, an engine exiting 0 when it cannot load the script
 * it was given, a snapshot able to hardcode the two fields no test varied, state
 * able to go stale behind correct events, and an ambient environment variable
 * that turns the whole verification command into `exit 0`. Reviewers recognise
 * each one and reach for "worth noting". Stating the shape plainly is cheaper
 * than hoping the general principle gets applied.
 */
export const REVIEW_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{
  "passed": true,
  "blocking": ["a problem that must be fixed before this milestone is done"],
  "notes": ["worth recording, not worth blocking"],
  "note": "your assessment in at most 80 words"
}
\`\`\`

"passed" must be false whenever "blocking" is non-empty. A problem you are willing to record but not act on belongs in "notes".

Blocking:
  - The change does not do what the milestone said.
  - A test was weakened, narrowed or deleted, or an assertion loosened, to reach green.
  - The diff goes substantially beyond what the milestone authorised.
  - A defect you can state concretely: the input or state that triggers it, and what goes wrong.
  - The milestone's central claim is not established by its tests. Apply this check: imagine an implementation that gets the milestone's main point wrong but is otherwise plausible — stale state behind correct events, a hardcoded field, a value the tests never vary. Would it pass this suite? If it would, the claim is unverified and passing tests are evidence of nothing. This blocks even when the code in front of you looks correct: what is under review is the milestone, and an unverifiable milestone is not done.
  - **The verification can be made to pass without running.** Any path by which the command reports success while executing nothing, or while ignoring the state of the code: an empty or unreadable test directory treated as zero failures, a runner that cannot load and exits 0 anyway, an environment variable or argument that short-circuits the command, a mode flag that stubs out the real work. This blocks however unlikely you judge the trigger, and whether or not anything is broken today, because the exit code is the entire basis on which this work is judged — and a green result you cannot trust is worse than a red one. If you find yourself writing that something *could* report success without testing anything, that sentence belongs in "blocking", not "notes".

  - **Behaviour that is wrong, however narrow the window.** If you can name the input or state and say what goes wrong, it is blocking. How rarely you judge it to fire is not a reason to downgrade it: a same-millisecond tie, an off-by-one at a boundary, a default that silently widens a destructive scope, a comparison that admits the case its own description excludes. If your sentence contains "silently", "never fires", "is skipped", or "clears everything", you are describing a defect and it belongs here.
  - **A primitive this milestone depends on whose real path is untested.** Hand-written hashing, comparison, parsing, normalisation or serialisation where the tested inputs do not reach the code that will actually run — a single-block vector for a hash whose every production input spans several blocks. Reading it and finding it correct is not a substitute. This is the exact class of error that careful reading does not catch and one known-answer vector does, so the absence of that vector is the finding.

Notes, not blocking:
  - Coverage you would like that is not the milestone's own claim.
  - Naming, structure, style, or how you would have written it.
  - Concerns about milestones not yet built.
  - Work that belongs elsewhere in the plan.

Before you put anything in "notes", read it back to yourself. If it says something is wrong, missing, or quietly skipped, it is a finding and it belongs in "blocking" — "notes" is for what you would like, not for what does not work. Filing a defect as a note is the same failure as ticking "passed" beside it; both leave a known problem in the tree with nothing stopping it.

Do not block on taste. A milestone that does what it said, proves it, and stays in scope passes — say so plainly and put the rest in "notes".`.trim()

/**
 * Asks for a corrected anchor for a mutation that would not apply.
 *
 * The planner writes mutations before the code exists, so its `find` string is a
 * guess about identifiers and formatting the executor has not chosen yet. A stale
 * guess is not a defect, and blocking on one would put the operator on a treadmill
 * of false stops — which teaches them to click through the real ones. So the anchor
 * is re-resolved against the file that actually got written.
 *
 * What is deliberately NOT renegotiable is `describes`: the planner fixed the intent
 * of the check, and this call may only relocate it, never weaken or reinterpret it.
 * That keeps the separation of powers intact — the planner owns what gets verified,
 * this call owns only where, and the executor (the one party graded by the outcome)
 * owns neither.
 */
export function mutationRepairPrompt(
  items: { describes: string; file: string; find: string; reason: string; contents: string }[],
): string {
  return [
    'A verification check could not be applied to the code as written.',
    '',
    'Each item below describes a break that this milestone claims its tests would catch.',
    'The quoted "find" text was written before the code existed and no longer matches it.',
    'Your job is to point the same check at the code that is actually there.',
    '',
    'Rules:',
    '- Keep the intent in "describes" exactly as it is. Do not soften it, reinterpret it,',
    '  or substitute an easier check. If the intent cannot be expressed against this file,',
    '  say so rather than inventing something weaker.',
    '- "find" must appear EXACTLY ONCE in the file, character for character. Copy it from',
    '  the contents below; do not retype it from memory.',
    '- "replace" must genuinely break the behaviour the intent names, not merely alter the',
    '  text. A change the tests cannot possibly notice is worse than admitting failure.',
    '- Do not change the file. You are only describing an edit.',
    '',
    ...items.flatMap((item, i) => [
      `── ${i + 1}. ${item.file} ──`,
      `Intent (fixed): ${item.describes}`,
      `Previous find: ${JSON.stringify(item.find)}`,
      `Why it failed: ${item.reason}`,
      'Current contents:',
      '```',
      item.contents,
      '```',
      '',
    ]),
    'Reply with JSON only:',
    '{"repairs":[{"index":1,"find":"<exact text from the file>","replace":"<broken version>"}],',
    ' "impossible":[{"index":2,"why":"<why this intent cannot be checked here>"}]}',
    '',
    'Every item must appear in exactly one of the two lists.',
  ].join('\n')
}

export function reviewDiffPrompt(
  milestoneTitle: string,
  intent: string,
  diff: string,
  testSummary: string,
  /** Your own objections from the previous round, when this is a re-review. */
  previousConcerns: string[] = [],
  /** Rendered outcome of the milestone's declared mutation checks. */
  mutationSummary = '',
  /** Declared milestone outputs that were still absent after execution. */
  missingPaths: string[] = [],
): string {
  const isFollowUp = previousConcerns.length > 0
  return [
    isFollowUp
      ? `PREVIOUS REVIEW FOLLOW-UP. You rejected this milestone once already and the executor has had another attempt. Judge the new diff, not the old one. This turn is READ-ONLY.`
      : `Review a diff produced by a different agent. You did not write it. This turn is READ-ONLY.`,
    `MILESTONE: ${milestoneTitle}`,
    `INTENT: ${intent}`,
    isFollowUp
      ? `WHAT YOU OBJECTED TO LAST TIME — say for each whether it is now resolved:\n${previousConcerns
          .map((c) => `  • ${c}`)
          .join('\n')}`
      : '',
    missingPaths.length
      ? `DECLARED OUTPUTS THAT DO NOT EXIST — this milestone cannot pass while any of these paths are absent. Treat this as a blocking completeness failure:\n${missingPaths
          .map((p) => `  ${p}`)
          .join('\n')}`
      : '',
    `DETERMINISTIC VERIFICATION (run by the workbench, not by an agent):\n${testSummary}`,
    // Given to the reviewer because it is evidence about the tests rather than
    // about the code, and it is exactly the judgement the reviewer would
    // otherwise have to make by imagination: would a wrong implementation have
    // been caught? Here it has been tried.
    mutationSummary ? `MUTATION CHECKS (the workbench broke the code on purpose and re-ran the tests):\n${mutationSummary}` : '',
    `THE DIFF:\n${diff}`,
    isFollowUp
      ? `Do not pass it merely because it changed. Check that each objection above is actually addressed, and that the fix did not introduce something new or quietly widen the milestone's scope. Being asked twice is not a reason to lower the bar.`
      : `Passing tests are necessary, not sufficient. Check specifically: does the change do what the milestone said? Did it weaken or delete a test to get green? Did it go beyond the authorised scope? Is there a failure mode the tests do not cover?`,
    REVIEW_CONTRACT,
  ]
    .filter(Boolean)
    .join('\n\n')
}

/**
 * Review of work that was already in the tree when Parley found it.
 *
 * Deliberately does not pretend an agent authored it under supervision. The
 * reviewer is told the provenance is unknown, because that is the honest frame:
 * the usual assurance — that a specific executor produced exactly this diff
 * under a specific instruction — does not apply, so the code has to stand on its
 * own merits against the milestone's intent.
 */
export function adoptReviewPrompt(
  milestoneTitle: string,
  intent: string,
  diff: string,
  testSummary: string,
  unverifiedPaths: string[] = [],
  missingPaths: string[] = [],
  /** Rendered outcome of the milestone's declared mutation checks. */
  mutationSummary = '',
): string {
  return [
    `Review work that was already present in the repository. Nobody executed it under supervision, and its provenance is unknown — it may be complete, partial, or subtly wrong. This turn is READ-ONLY.`,
    `THE MILESTONE IT IS SUPPOSED TO SATISFY: ${milestoneTitle}`,
    `INTENT: ${intent}`,
    missingPaths.length
      ? `DECLARED OUTPUTS THAT DO NOT EXIST — the existing work is incomplete while any of these paths are absent, regardless of the test result:\n${missingPaths
          .map((p) => `  ${p}`)
          .join('\n')}`
      : '',
    `DETERMINISTIC VERIFICATION (run by the workbench, not by an agent):\n${testSummary}`,
    // Evidence about the tests rather than the code, exactly as in a supervised
    // review — and worth more here: "are the tests real tests?" is the question
    // this reviewer is told to press, and a tried break answers it by trial
    // rather than by reading.
    mutationSummary ? `MUTATION CHECKS (the workbench broke the code on purpose and re-ran the tests):\n${mutationSummary}` : '',
    // Stated rather than left to be inferred: the verification is scoped to the
    // milestone, but the diff below is the whole tree, so some of what you are
    // reviewing was never run.
    unverifiedPaths.length
      ? `NOT COVERED BY THAT VERIFICATION — these changed paths lie outside the milestone's scope and were not exercised by the command above, so treat their correctness as unestablished:\n${unverifiedPaths
          .map((p) => `  ${p}`)
          .join('\n')}`
      : '',
    `THE EXISTING WORK:\n${diff}`,
    `Decide whether this genuinely accomplishes the milestone. Because no agent is accountable for it, be harder than usual on the questions that a supervised diff would have answered: is it complete, or does it stop short? Does it do things the milestone did not ask for? Are the tests real tests, or do they assert against the implementation? Passing tests are necessary, not sufficient.`,
    REVIEW_CONTRACT,
  ]
    .filter(Boolean)
    .join('\n\n')
}

// ─── Loops ───────────────────────────────────────────────────────────────────

export function loopWorkPrompt(goal: string, iteration: number, lastFeedback: string, repoPath: string): string {
  return [
    `You are working toward a goal across multiple iterations. This is iteration ${iteration + 1}.`,
    `REPOSITORY: ${repoPath}`,
    `GOAL:\n${goal}`,
    lastFeedback
      ? `Result of the previous iteration's verification:\n${lastFeedback}\n\nAddress what it reports. Do not repeat an approach that has already been shown not to work.`
      : `This is the first iteration.`,
    `Make concrete progress this iteration. Then state in two or three sentences what you did and what remains.`,
  ].join('\n\n')
}

export const LOOP_VERIFY_CONTRACT = `
End your message with a single fenced JSON block, exactly in this shape:

\`\`\`json
{ "met": false, "reason": "why the goal is or is not yet met, in at most 60 words" }
\`\`\`

Set "met" to true only if the goal is genuinely satisfied. An agent reporting its own success is not evidence — check the repository yourself.`.trim()

export function loopVerifyPrompt(goal: string, criterion: string, workerReport: string, repoPath: string): string {
  return [
    `You are the independent verifier for an autonomous loop. Another agent, from a different model family, is doing the work. Your only job is to decide whether the goal is actually met.`,
    `REPOSITORY: ${repoPath}`,
    `GOAL:\n${goal}`,
    criterion ? `COMPLETION CRITERION:\n${criterion}` : ``,
    `THE WORKER'S OWN REPORT (treat as a claim, not as evidence):\n${workerReport}`,
    `Verify against the repository. A loop that exits early because the worker said it was finished is the failure mode you exist to prevent — as is a loop that made its check pass by weakening the check.`,
    LOOP_VERIFY_CONTRACT,
  ]
    .filter(Boolean)
    .join('\n\n')
}
