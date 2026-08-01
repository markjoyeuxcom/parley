# Parley — engineering guide

A local-first macOS workbench that drives Claude Code and Codex through their own
CLIs. Three surfaces over one governed engine: parallel terminals, adversarial
sessions, and capped autonomous loops.

## Product invariants

Break any of these and the product stops being what it is.

1. **Subscription CLIs only.** Every model call goes through the user's local
   `claude`, `codex` or `agy` binary, against the account it is already signed
   in to. Never add an API-key path, not even as a fallback.
2. **No `--dangerously-*` flag, ever.** Not `--dangerously-skip-permissions`, not
   `--allow-dangerously-skip-permissions`, not
   `--dangerously-bypass-approvals-and-sandbox`, not `danger-full-access`. The
   capability ladder is `none` → `read` → `write` and there is no rung above it.
3. **Read-only is the default.** Sessions never write. Only the audited pipeline
   and an explicitly write-capable loop can, and only behind an approval.
4. **Approval is recorded and single-use.** A write-capable run needs an
   `approvals` row matching its scope and subject with `consumed_at IS NULL`.
   Starting the run spends it. Running again needs a fresh one.
5. **No agent certifies its own work.** The planner is not the executor; the
   reviewer is never the vendor that wrote the diff; a loop's verifier is a
   different model family from its worker.
6. **Exit conditions are observed, not self-reported.** Either Parley runs a real
   command and reads its exit code, or the other vendor's model inspects the
   repository. "The agent said it was done" is not a termination condition.
7. **Caps are enforced by Parley, before dispatch.** An agent cannot see them or
   argue with them. Hitting one is `exhausted`, never `succeeded`.
8. **Everything stays local.** SQLite under `app.getPath('userData')`. No sync, no
   telemetry, no remote anything.
9. **Dissent is preserved.** Disagreement lowers recorded confidence and the
   losing side's objection is stored verbatim. Never smooth it away.
10. **macOS-native restraint.** Hairline rules, small radii, one accent, tabular
    numerals, system font stack. No gradients, no emoji, no decorative AI tropes.

## Commands

```bash
npm run dev          # Electron dev app; HMR is renderer-only (see the self-update section)
npm run typecheck    # both projects — must pass clean
npm test             # deterministic tests, no tokens spent
npm run build        # production bundles into out/
npm run package:mac  # signed-runtime .dmg + .zip for Apple Silicon
```

Two escape hatches:

- `PARLEY_MOCK=1 npm run dev` — deterministic adapters, no subscription usage.
  Use it for UI and orchestrator work. The one thing a mock run ever writes is a
  single placeholder file (`parley-mock-work.txt`) on a write-capable turn —
  deliberately, because without it the pipeline's changed-tree gate could never
  pass and the execute → verify → review → remediate path would be untestable.
- `PARLEY_LIVE=1 npx vitest run src/main/agents/live.test.ts` — the only test
  that really invokes the CLIs. It spends a little quota and proves the argv and
  event schemas are still right. Run it after touching an adapter.
- `PARLEY_LIVE_REMOTE=<ssh-host> PARLEY_LIVE_REMOTE_NODE=<absolute node> npx
  vitest run src/main/remote/live.test.ts` — the remote arc against a real
  machine. Needs `npm run build:remote` first. See "Remote execution" for why
  the fakes cannot replace it.
- `npm run build:cli && node out/cli/parley.mjs holds --dev` — the record from
  a terminal, as JSONL. See "The CLI reads and never writes".

## Layout

```
src/shared/      domain schemas, IPC contract, turn protocols, JSON extraction
src/main/        agents/ (CLI adapters) · orchestrator/ · store/ · pty/ · ipc/
src/preload/     the renderer's entire view of the outside world
src/renderer/    React 19 UI: three surfaces over a hand-written design system
```

Types are inferred from the zod schemas in `shared/domain.ts`. There is no
second hand-written copy of any shape.

## Security posture

- The renderer has `contextIsolation: true`, `nodeIntegration: false`, no remote
  module, and a CSP with no remote origins. Navigation and window-open both go to
  the user's browser instead.
- One IPC channel (`parley:invoke`) with a validated command table in
  `shared/ipc.ts`. Adding capability means adding a command *and* a schema.
  Terminal output uses a second channel deliberately — it is high-volume opaque
  bytes and validating it would buy nothing.
- Processes are spawned with an argv array and **never** a shell. Agent-authored
  strings reach `splitCommand`, so a shell would be an injection vector.
  `isShellFree` rejects anything needing shell syntax rather than accommodating
  it.
- `--strict-mcp-config` is passed to Claude so a governed run cannot silently
  inherit the user's global MCP servers.

## Hard-won CLI details

These cost real time to find. Changing them will break things quietly.

**claude**

- `--output-format stream-json` *requires* `--verbose`.
- The prompt goes on **stdin**, not argv.
- Deltas need `--include-partial-messages`.
- `assistant` messages carry `thinking` blocks next to `text` blocks; only the
  text blocks are the reply.
- The resumable session id comes from the `system`/`init` event; the final
  `result` event carries the complete text and the usage.
- `--system-prompt` *replaces* the default, so it is only used at `none`
  capability where there are no tool instructions to lose. Tool-using turns use
  `--append-system-prompt`.

**codex**

- **stdin must be closed** or `codex exec` waits forever.
- `--skip-git-repo-check` is needed outside a git repository.
- **`codex exec resume` accepts far fewer flags than `codex exec` — no
  `-s/--sandbox`, no `-C/--cd`.** So the sandbox is set with
  `-c sandbox_mode="…"`, which both forms accept, and the working directory is
  set on the spawn. Using `-s` works on turn one and fails on every resumed turn.
- There is no `--system-prompt`; role instructions are prepended to the first
  prompt only.
- `exec` emits no text deltas — the reply arrives whole in `item.completed`.
- It always prints `Reading additional input from stdin...` to stderr. That is
  noise, not an error, and is filtered.

**agy**

- Agy is tool-less in Parley. It is eligible only for a repository-free debate
  seat and every adapter call above `none` capability is refused.
- The prompt goes on stdin and `--conversation <id>` resumes a conversation.
- Every run ignores the requested working directory and spawns in a fresh empty
  temporary directory. Anything written there fails the run.
- Only explicit `gemini-*` model names are accepted. Parley never passes
  `--effort`; a discovered tiered model slug carries the selected tier.
- Never pass `--dangerously-skip-permissions`.

## Native modules

`node-pty` is the only one, loaded through `createRequire` so it survives being
unpacked from the asar. It is listed in `asarUnpack`. Persistence uses
`node:sqlite`, which ships inside the Node that Electron embeds — deliberately,
to avoid a second native dependency. The store's surface is small enough that
swapping to `better-sqlite3` means rewriting `store/db.ts` and nothing else.

`npm run rebuild` runs `@electron/rebuild` directly, and `postinstall` runs it
for you. **Do not** switch it to `electron-builder install-app-deps`: that
command infers the app directory from `main`, looks for `out/package.json`, and
fails — which silently leaves node-pty half-built.

## Never run npm install from a non-macOS container

If you are working on this repo through a Linux container that mounts the macOS
checkout (OrbStack, Docker with a bind mount, a devcontainer), **`node_modules`
is the same directory on both sides and can only hold one platform's binaries at
a time.** Running `npm install`, `electron-rebuild`, or
`node node_modules/electron/install.js` from the container replaces the macOS
binaries with Linux ones and breaks the app on the Mac.

Four packages here are platform-native:

| package | symptom when wrong |
| --- | --- |
| `electron` | `spawn ENOEXEC` from electron-vite |
| `node-pty` | `posix_spawnp failed` on every pane |
| `typescript` (7.x is a native binary) | `Unable to resolve @typescript/typescript-<platform>` |
| `esbuild` / `rollup` | vite fails to start |

`npm run predev` / `prebuild` run `scripts/check-electron.mjs`, which turns the
cryptic `ENOEXEC` into an actionable message. `npm run fix:electron` re-downloads
just the Electron binary for the current platform.

The container is still useful for everything that is not a native build — editing,
reading, `vitest` (once the host has installed), and reasoning about the code. Run
`npm install`, `npm run typecheck`, `npm run dev` and packaging **on the Mac**.

### Verifying from a container anyway

`~/parley-toolchain` (a container-local `npm i typescript@7`) can typecheck the
macOS tree directly — `tsc` only reads `.ts`/`.d.ts`, so the platform of the
installed deps is irrelevant:

```bash
~/parley-toolchain/node_modules/.bin/tsc --noEmit -p tsconfig.node.json
```

Tests need native esbuild/rollup, so run them from a container-local copy with
its own Linux deps (`~/parley-verify`: `vitest` + `zod`, source copied fresh each
run). Never `npm install` inside the mounted tree.

## Mock mode must never be invisible

Mock runs produce sessions, verdicts, findings, plans and reviews that are
structurally identical to real ones while consulting no model. A user who
loses track of which mode they are in will read fabricated output as
evidence — which would break the only thing this tool sells.

So mock-ness is surfaced in four places, and all four are load-bearing:

1. A non-dismissible hazard-striped banner under the titlebar.
2. A `mock` chip on every session, loop and plan, in lists and headers.
3. A `mock` column persisted on those three tables, so a record stays
   identifiable long after the process that made it has gone.
4. A `NOT REAL WORK` blockquote at the top of the exported Markdown report —
   that file outlives the app, so the warning has to travel with it.

When a milestone fails with an unchanged tree while mock mode is on, the note
says the mock executor does write a placeholder — so the likely cause is an
unwritable repository path, not mock mode itself. That is the one reasoning a
user cannot reconstruct from the UI, which is why the note spells it out.

## The Grid is multi-folder, and saved layouts do not change that

Each pane is spawned with its own `cwd` and keeps it for life. The toolbar
control is not "the workspace" — it only decides where the *next* toolbar-opened
pane lands, and a split inherits the folder of the pane it grew out of rather
than that target. Changing it never affects a running pane.

Do not collapse this into a single workspace folder. Working a change across two
repositories at once — a library and its consumer, a CLI and the repo it
provisions — is the normal case, not an edge case. A saved layout stores a
`defaultFolder` that pre-fills the toolbar, and **each leaf still carries its own
`cwd`**; the default is a convenience, never a constraint.

### Slots, not panes

The live tree is keyed by *slot*. A slot is a position in the layout that may or
may not hold a running process (`paneId: null` when it does not). That
indirection is what makes restoration possible at all — process ids die with the
app, and a restored agent pane has no process until you start it.

The persisted form (`SavedLayoutNode`) carries **no ids whatsoever**: just kind,
folder, direction and ratio. Restoring mints fresh slots. Never persist a
`paneId`; it is meaningless across runs.

### Restoring starts shells only

Opening a saved layout spawns its shells and leaves Claude and Codex panes as
placeholders with a Start button. Respawning several agent CLIs unprompted would
begin real sessions against the user's subscription that they did not ask for on
this launch. A shell costs nothing; an agent session does. `fromSavedLayout`
returns everything unstarted and lets the caller apply that policy, so the rule
lives in one place.

Opening a layout over live panes asks first, because it kills them.

### The pane registry, and what "closed" means

`state.panes` is fed by `pane.created`, patched by `pane.status`, and pruned
by `pane.closed` — and the last two are different ends on purpose. A process
**exit** is a status (`'exited'`, with the code): the handle stays in the pty
manager's map and the row stays in the renderer, so the pane can show its
corpse, its final scrollback, and its exit chip. `pane.closed` means the
handle is **gone**, which only a user's close does. Wiring exit to closed is
the exact defect that kept the exit chips unreachable for months. The Grid
reconciles once at mount via `pane.list`; events carry everything after.

### Grid-local signals never enter the holds queue

The identity line (branch/dirty/drift via the bounded `pane.identity` — four
git calls, five-second ceiling, never `readTree`), the plan-worktree chip
(matched realpath-to-realpath because the registry stores raw spellings; it
says landed or unlanded and NEVER "safe to remove"), and the unread-output
dot are all deterministic and all Grid-local. The holds queue's authority is
derived from the durable record; a PTY observation is not a record and must
not notify like one.

### Cross-surface doors are knocks, and panes are keystrokes

Another surface asks the Grid for a pane via the `focusGridSpawn` knock
(set → switch → consume, the `focusMilestoneId` shape), consumed only while
the Grid is visible so the hidden surface never spawns behind the user's
back. In the other direction, a pane promotes into a review via
`focusNewSession` with the terminal selection as matter. Resume in a pane is
the CLI's OWN picker (`claude --resume` bare, `codex resume`) — governed
resume ids never reach the Grid. Broadcast and Skills share one shape:
keystrokes into the interactive session (`pane.write`, flattened newlines,
one `\r`) — never a separate spawn, never a privileged path.

## The planning conversation

`plan → audit → correction → you`. The correction stage is what makes the audit
matter: without it the auditor's findings reach the human but never the plan, and
what gets executed is the original draft with an unread critique stapled to it.

- **The planner is resumed across its turns**, so correcting is a reply, not a
  re-explanation. Every stage that talks to the same agent twice should resume;
  a fresh session is a stranger.
- **Every finding needs a disposition.** Silence on one is the failure mode — it
  lets an inconvenient objection vanish between stages.
- **The corrected plan replaces the draft wholesale**, because milestones may be
  split, reordered or dropped and patching them would be guesswork. That means
  the draft's per-milestone audit notes are discarded, so `summariseAudit`
  captures the auditor's own findings at plan level first. Both halves of the
  exchange survive in `correctionNote`.

## Agents may ask, once

Any planning stage can return a `clarification` instead of an answer. The plan
parks on `awaiting-clarification`, the question surfaces in the UI with an answer
box, and `resume` picks the stage back up with the answer — the planner still
holding its own draft.

The alternative is worse than it looks: an agent that guesses at an ambiguous
brief produces a confident plan resting on an assumption nobody agreed to, and
the assumption is invisible by the time anyone reviews it.

Bounded to one question per stage, and only for a decision that genuinely
changes the work. `parseClarification` ignores a `clarification` field that
arrives alongside `milestones` — an agent that produced a plan has not blocked on
anything.

## Tell the agents what the harness will accept

The planner emitted `go build ./... && go test ./...` and the harness refused it,
so that milestone went unverified. The rule existed; the planner had never been
told it.

`PLAN_CONTRACT` now states the constraints that actually bite: `testCommand` is
spawned with no shell so `&&`, `|`, `>`, `$(…)` and globs are refused;
`expectedPaths` drives the post-execution check; the reviewer sees the whole
tree. When you add a harness rule, add it to the contract in the same change —
a constraint the agent cannot see is a failure waiting to happen at the far end
of a thirty-minute run.

## Remediation: the rejection goes back to the executor

A rejected milestone is handed straight back to the agent that produced it,
inside the same run, up to `MAX_REMEDIATION_ROUNDS`. Both sides are **resumed**:
the executor still holds everything it did, so it receives a critique rather than
a restatement of the milestone; the reviewer still holds its own objections, so
it checks whether they were met rather than forming a fresh opinion.

- **The original approval covers it.** The human authorised this milestone, and
  bounded self-correction toward that same milestone is within it. A fresh gate
  per round would only train people to click through gates.
- **A failing verification is actionable on its own.** Remediation triggers when
  the reviewer objects *or* the tests fail — the test output is feedback the
  executor can act on even when the reviewer is content.
- **Completion needs both signals.** Track the last round's combined
  tests-and-review result; do not re-derive it from `reviewPassed` at the end, or
  a milestone with failing tests will complete on a satisfied reviewer.
- Every round is in the note (`Round 1 —`, `Round 2 —`) so a pass after
  remediation is never mistaken for a clean first attempt.

The remediation prompt tells the executor to fix what was named and nothing else,
and to argue an objection it disagrees with rather than silently ignoring it.

## The reviewer's evidence: three layers

`renderDiffForReview` layers three sources, each doing the one thing it is good
at. Git's own diff (with `--no-renames`, so a rename arrives as removal plus
addition with content) is the primary channel — full hunks with no per-file
bound, which is what lets an edit deep in a 2,000-line file arrive as real code.
Untracked files, which `git diff` omits, come from bounded snapshots (40 files,
6000 characters each) as `--- new file: path ---` blocks. And a digest layer
(`git hash-object` against `HEAD`, computed for every dirty path regardless of
size) does what git cannot: separate the milestone's work from dirt that
predates it. Only digest-verified paths may appear under `--- NOT part of this
milestone ---`, and pre-existing dirty paths the milestone did touch get a
bounded incremental delta (`contentPatch`, a real multi-hunk line diff) so the
reviewer can tell which part of the combined diff is the milestone's. An
unknown digest — a failed git spawn — is never treated as unchanged.

## A verification that never ran is not a verdict

Parley's claim is that a green result is observed rather than asserted. That
claim is worth exactly as much as its willingness to say when it observed
nothing — and the absence of evidence arrives looking identical to bad
evidence: an exit code and some stderr.

`CaptureResult.startError` and `TestResult.startError` carry the reason a
command never began, following the precedent `signal` and `timedOut` set. The
message, not a boolean: whoever reads it has to fix something outside Parley,
and `ENOENT` and `EACCES` send them to different places. Four paths set it —
a spawn failure, a command needing shell syntax, one that will not parse, and
a dev container that will not start. All four previously reported exit `-1`
and were read as failing tests.

A milestone whose verification carries one is **`parked`**, not `failed`:

- **Nothing downstream may treat it as evidence.** The check runs before the
  mutation stage (which would "prove" the tests catch nothing) and before the
  review that starts remediation. Adoption parks too — it is the path whose
  only output IS the verification.
- **`parked` is its own status and its own fact.** A failure is a judgement;
  a park is the absence of one. A `finished` with `passed: false` would write
  "the tests failed" about tests that never ran, and a reviewer believing that
  sentence is what makes an executor rewrite working code. It cost two paid
  remediation rounds on a real host.
- **Nothing may attribute it to an agent.** `reviewPassed` stays null, no
  `completedAt`, and the renderer does not put the reason under "Review by
  Codex" — no reviewer saw the work.
- **A park exists to be left.** `EXECUTABLE_PAIRS` admits it, the button says
  "Approve and run again" rather than "retry" (nothing was tried), and the
  hold's generation includes the start error so fixing one missing thing and
  hitting another is new waiting rather than something an old ack hides.
- **`milestone-parked` is its own hold kind.** "It failed" sends someone to
  the diff; "it never ran" sends them to the machine. Telling them the wrong
  one costs an afternoon.

Remote needed nothing: the fact vocabulary is shared, so a remote park lands
through the same `milestonePatch` and is indistinguishable from a local one.

## A finding says where it is

Session findings have carried `Evidence` (path, line, symbol, excerpt) since
the beginning. The findings raised DURING a run — the ones that gate approval
and become backlog items — were bare sentences. "The retry ceiling is not
surfaced" cannot be opened, cannot be counted against a file, and means very
little read back six weeks later.

`REVIEW_CONTRACT` now takes `{"what": ..., "where": [...]}` for blocking
entries and notes. Three rules, in the order they matter:

- **A bare string is still a finding.** Every reviewer wrote them that way
  until the contract grew somewhere to put a reference, and a run whose real
  objection was dropped for arriving as prose would be worse off than before
  any of this existed. `findingList` accepts both shapes; `what` and `text`
  are both read, because rejecting a model's obvious synonym loses a real
  objection over a word.
- **A reference that cannot be opened is not kept.** No path, no entry. A line
  that is not a positive integer becomes null rather than being clamped: a
  wrong line sends the next reader somewhere with confidence, which is worse
  than sending them to the file.
- **Evidence lives on the SIGHTING, not the finding.** Findings dedupe by
  normalised text, so one sentence raised against two files is one finding and
  two occurrences; hanging the reference off the finding would attribute one
  file's line to the other. `ledger_sightings.evidence` (schema 29), defaulted
  to `[]` so rows written before the reviewer was ever asked read as "said
  nothing about where", which is exactly true.

The surfaces all render it through `evidenceLabel` — `path:line — symbol`,
one notation so the ledger panel, the run room and the backlog brief cannot
drift into three. In the run room the reference goes in the LINE and the
reviewer's words stay the detail: putting a path inside a quote edits what
somebody said. An accepted risk carries the references from the sightings in
that repository and no others — a path from a different checkout is worse
than none.

**`domain.ts` is not a place to put a function.** Twice in this milestone the
boundary went red on it: once validating the fact's evidence with the zod
schema (fixed by hand-checking, like every other field in that decoder), and
once by adding a four-line formatter beside the type it formats. `domain.ts`
builds schemas at module scope, so ANY value imported from it pulls the whole
of zod behind it — fine in the app, fatal in `parley-remote`. Helpers the
execution core needs go in a leaf: `usage.ts`, `ids.ts`, and now
`evidenceLabel.ts`. Type imports erase and are always safe.

## Adoption: verifying work Parley did not write

An interrupted run leaves a milestone's files behind. Every retry then finds them
already present, the executor declines to overwrite finished-looking work, the
tree is unchanged, and the milestone can never succeed — while the code itself
sits there working. One interruption can poison several milestones this way.

Deleting the work to satisfy the pipeline throws away good code. Marking the
milestone done by hand would put a lie in the audit trail. So `adoptMilestone`
takes the third path: **skip execution, keep the checks that actually establish
anything** — the deterministic tests, the declared mutation checks, and the
independent cross-vendor review — and set `adopted: true`. The mutation checks
run on a green suite only, with stale anchors re-resolved by the reviewer's
vendor, because adopted code has unknown provenance: whether its tests would
catch a wrong implementation is worth more here, not less. A surviving or
unapplicable break fails the adoption exactly as it fails an execution.

Four properties are load-bearing:

- **No approval, because no agent gets write capability.** The only writes on
  this path are the harness's own break checks, applied and restored the same
  way execution applies them. Do not add an approval; requiring one for a
  verification teaches people to click through gates.
- **The findings-ledger gate covers it.** Adoption completes a milestone
  through review, so an open blocking occurrence stops "Adopt & verify"
  exactly as it stops "Approve and run" — and the adopt review's own blocking
  findings are ingested as occurrences, so a failed adoption holds the next
  attempt to them.
- **`adopted` is persisted and shown.** A milestone that reads `complete` must
  never imply Parley's executor authored it when it did not.
- **The reviewer is told the provenance is unknown** and to be harder than usual,
  since no agent is accountable for the diff. `adoptReviewPrompt`, not
  `reviewDiffPrompt`.

Adoption is refused when the tree is clean or none of the expected paths exist —
there would be nothing to adopt, and saying otherwise would be false.

## Holds are derived, never stored

A hold is one thing currently waiting on a human — a parked question, an
approvable milestone, a landable branch, a stopped run. `computeHolds`
(orchestrator/holds.ts) recomputes the open set from the durable rows on every
relevant transition; **there is no holds table to go stale**, and there cannot
be one: "approvable" depends on the finding gate, and the gate moves with no
plan or milestone transition at all (a review records an occurrence, a human
records a disposition). Only two facts about a hold are written down —
`hold_acks` and `hold_notifications`, both keyed by the content-addressed hold
identity (`holdIdentity`, same sha256 as the ledger), which is what lets an
ack and a notify-once stamp survive recomputation and restarts.

Two rules are load-bearing. **Decision-class holds refuse acknowledgement in
the main process**, not the UI — an ack-able "waiting on your answer" clears
the badge while the plan stays parked, the exact silent stall the queue exists
to kill. And **the stamp is written before any display attempt**, so a denied
notification permission degrades to the badge without ever re-arming the
banner. The engine wraps `deps.emit` in the Manager constructor; two mutations
reach the database with no event (archiving, the ack itself) and call
`Manager.holdsChanged()` explicitly. When you add a durable state a human must
react to, add its derivation to `computeHolds` — do not mint another toast.

## The backlog: identity, provenance, one choke point

The per-repository backlog (store tables `backlog_items` / `backlog_events` /
`learnings`, logic in `orchestrator/backlog.ts`) is a projection of the
record, not a second task system. Three rules are structural:

- **Identity is a random id plus a content hash, never hash-as-key.** Dedupe
  (`fileBacklogItem`) is read-then-insert in a transaction against **live
  states only**; a collision appends a `resighted` event to the live item. A
  terminal row must never block refiling — a `done` item whose problem comes
  back deserves a fresh row with a fresh trail, not a silent reopen. The hash
  reuses `normaliseFindingText` from shared/ledger.ts; do not invent a second
  normalisation. Near-duplicate *wording* across fresh reviews is accepted —
  semantic matching belongs to the delta-review work, and the mock adapters
  emit byte-identical findings, so tests must not oversell what live dedupe
  does.
- **Mock provenance is invariant-level.** `mock` columns on items and
  learnings, copied from the origin session or plan; chips on every surface
  row; brief injection filtered to the running mode; `createPlan` refuses a
  cross-mode selection. Mock ingestion is never skipped — PARLEY_MOCK=1 is the
  sanctioned tokenless workflow and this surface must be exercisable in it.
- **Every state change goes through `transitionBacklogItem`** — legality
  table, column update, append-only event with a monotonic `seq`, one
  transaction. The store test pins fold(events) === column over legal
  sequences; a write path that bypasses the choke point breaks that proof.
  Repo keying uses `canonicalRepoPath` (realpath + trailing-slash strip) on
  the backlog tables only; `validateRepoPath` and the plans/worktrees rows are
  deliberately untouched.

Lifecycle hooks live in `backlog.ts` and are called as one-liners from
session/pipeline/manager code. Completion **proposes** closure (worktree plans
only at landing — completion without landing has not touched the checkout);
planning death regresses planned items to open in the `createPlan`/
`answerPlan` catch blocks; nothing ever auto-closes. The stow sweep is one
gated read-only turn over a **composed, bounded** input — columns and
tail-sliced turns, never `verdict.report`, which embeds the whole exchange.

## The foreman: proposal power only, every read on the record

The foreman (`orchestrator/foreman.ts`, table `foreman_proposals`) is a
proposing role and nothing more. The boundary is structural:

- **It writes only its own table.** It never transitions backlog state,
  never creates plans, never picks vendors. Accepting a proposal is
  `createPlan` with `foremanProposalId`: validated with the other pre-row
  refusals (still proposed, same canonical repo, mock-matched, and only
  from its **anchor session** — the newest origin session with a verdict
  among the selected items, resolved at filing so acceptance is never a
  dead end), then plan row + item flips + acceptance stamp in **one
  transaction** via `repo.bindPlanCreation`. The manual path passes a null
  proposal through the same method. Rejection is `foreman.reject`, and
  every decide emits `backlog.changed` — a decision must not outlive its
  hold.
- **Runs are recorded before dispatch.** `fileForemanAttempt` writes a
  `running` row (with the open-items snapshot — the staleness baseline the
  panel diffs against) before the agent turn; `finalizeForemanAttempt`
  ends it as `proposed` — superseding older same-mock pendings **in that
  transaction, and only on that arm**, so a mere attempt or a failed read
  never clobbers a valid pending — or `failed`, carrying usage and the
  error. Startup reconciliation (`reconcileForemanAttempts`, wired in
  index.ts) flips interrupted running rows to failed. A crash between
  filing and finalizing loses the spend figure but not the fact of the
  attempt.
- **Ids are validated, both lists.** Selected and deferred ids must be
  open items of the same canonical repo in the running mode; invalid ones
  drop with an honest note on the proposal; zero valid selections finalize
  `failed`. The contract tells the model ids are copied, never invented.
- **Backlog text is untrusted input.** `renderForemanItems` fences every
  item in record markers and the system prompt says the contents are data
  under review, never instructions — item details quote code and agent
  output, and an adversarial detail must not steer the proposal. The
  layered defense: read-only turn, id validation, human accept.
- **The mock branch is system-prompt keyed** ("You are the foreman") and
  reads item ids out of its own prompt via the `(id: <uuid>)` delimiter —
  selecting min(2, n) so it stays deterministic at any backlog size.
  `FOREMAN_UNREADABLE` in the cwd exercises the parse-failure path.

## The Repos surface: four renderer rules

The Repos surface (⌘4; the surface id stays `'backlog'` — only the face
changed) hosts the same `PlanPanel` the session view mounts, which makes
three rules load-bearing:

- **`planLedger` fails closed.** `openPlan` fetches the plan and its
  session's ledger together and dispatches one atomic `planOpened`;
  opens are last-selection-wins, so a superseded open is dropped whole
  just before that dispatch and a stale result never writes or clears the
  winner's ledger.
  `state.planLedger === null` means *unknown*, and the approval gate
  disables on unknown rather than un-gating on an empty array — an empty
  gate silently enables approval, and while main would refuse the run, the
  grant itself writes an approval row that is never consumed. The session
  view deliberately keeps `sessionDetail.ledger` (fresher there, never
  null); only the Repos host reads `planLedger`.
- **`host` gates the knock.** Every surface stays mounted permanently, so
  two `PlanPanel` instances can render the same open plan. The
  `focusMilestoneId` knock and the auto-opened approval dialog obey only
  the instance whose `host` matches `state.surface` — otherwise both
  consume the knock and the hidden one strands an invisible stale dialog.
- **Canonical at the boundary; summaries drive membership.** Plan rows keep
  raw `repo_path` (validateRepoPath untouched); `listPlansForRepo` and the
  hold factories canonicalise, so filters compare canonical-to-canonical.
  The sidebar and empty states key off `repos.list` summaries — the union
  of plan, backlog and learning repos — never the backlog-derived memo,
  or a plans-only repository dead-ends.
- **Archive is a reveal filter, not deletion or silence.** The sidebar mirrors
  sessions with `Show N archived` / `Hide archived`; its Archive/Restore control
  delegates every refusal to main and displays that refusal verbatim. A loaded
  empty summary result clears a departed selection (`summariesLoaded`, never
  `summaries.length`), and `repoActivityVersion` refetches the projection after
  session, plan, loop or backlog activity. The global backlog and learnings
  exclude archived repos, but named-repo views and holds remain unfiltered.

## Worktree isolation: the checkout is never touched mid-run

A plan created with `isolation: 'worktree'` executes every milestone in a
per-plan git worktree on branch `parley/<kind>-<planId8>`, under
`userData/worktrees/<repoBasename>--<planId8>` — the directory name embeds the
origin basename **on purpose**, because mock-mode behavior keys on cwd
substrings and the integration fixtures depend on those switches still
tripping. Parley commits each passing milestone there (adoption commits too,
or the landed branch would silently lack work its record claims); the agent
still never commits. Landing is `git merge --ff-only`, human-initiated,
refused by git itself when the checkout moved or dirt would be overwritten; a
refusal parks as a `merge-blocked` hold naming the branch.

The ordering inside `runMilestone` is deliberate and pinned by tests:
refusal → finding gate → worktree ensure + health → **approval consumption** →
baseline → execute. Setup (`npm ci` class, minutes, can fail) runs before the
single-use approval is spent. The health check is **fail-closed** because
`readTree` fails *open* — a broken directory reads as an unknown tree, which
silently disables the changed-tree guard and blinds the reviewer. It also
compares the worktree and origin repositories' canonical Git common directories;
an unreadable identity or a different repository fails closed. And the status
refusal is re-checked in the same synchronous block as the spend: the ensure is
an await, so two racing starts carrying two different approvals would otherwise
both get through — the atomic spend only protects one approval against itself.

Nothing in worktrees.ts deletes work. Reconciliation flags rows orphaned when
their directory or origin vanished and never removes either; re-attachment
(`git worktree add <path> <branch>`, never `-B`) recovers a vanished directory
from its surviving branch; landing from an orphaned row still works, because
it needs only the origin and the branch. Mock plans refuse to land outright —
fast-forwarding a real branch onto mock commits would be invisible mock work,
with no marking anywhere in git.

Landing teardown is best-effort only after the fast-forward. Both `git worktree
remove` and `git branch -d` are checked; a refusal cannot undo the merge, so the
row is marked landed first and then flagged with every leftover, naming the
directory and branch. That ordering is load-bearing because
`markWorktreeLanded` clears `last_error`; the landed-row hold covers both
verification failures and cleanup litter.

## Search: one index, kept by triggers

`search_index` (FTS5, `porter unicode61`, schema 30) covers sessions, turns,
plans, milestones, ledger findings, backlog items and learnings. The record
could always say what the state of a plan was and never where anybody said
anything about retries — an answer spread over a debate, a milestone's intent,
a reviewer's finding and a backlog item, in tables nothing joins.

- **Triggers, not write-through.** An index kept current by remembering to
  update it is silently wrong the first time somebody adds a write site and
  forgets. This codebase already has a guard test whose whole job is catching
  that class of omission; here the database does it instead. Adding a
  searchable field means editing the INSERT in three triggers and the backfill.
- **The query language is unreachable, not escaped.** `ftsQuery` splits on
  non-word characters and re-quotes each token as a literal phrase, so no input
  arrives at FTS5 as an operator — `"unclosed`, `foo* NEAR/2 bar` and `a AND`
  are all just words. MATCH throws on malformed syntax, and a search that
  crashes while somebody is mid-word is worse than no search.
- Trailing `*` for prefix matching, `AND` between tokens (a second word
  narrows), and bm25 weighted 10:1 toward the title so a finding whose own
  sentence matched outranks a turn that mentioned the word in passing.
- `Repo.search` is the only entry point, so the app and the CLI get the same
  ranking. The cost is a second copy of the text — roughly doubling what the
  turns take — which is stated in the schema rather than discovered.

## The CLI reads and never writes

`out/cli/parley.mjs` (`npm run build:cli`, and part of `npm run build`) answers
questions about the record from a shell. Everything Parley knows is already in
one SQLite file; the app was the only way to ask it anything, which is fine for
deciding and useless for CI, cron, or someone three weeks later.

- **Stdout is data, stderr is for humans** — one JSON object per line, no
  headers or totals, so it pipes into `jq` with nothing to strip. The record it
  opened is named on stderr every run, because dev and packaged keep separate
  ones and an answer from the wrong one looks perfectly plausible.
- **It refuses rather than repairs.** `openRecordForReading` will not create a
  missing database (every command would then truthfully report nothing — a
  confident wrong answer) and will not accept a schema that is not exactly this
  build's, in EITHER direction. Migrating is the owner's job; a reader doing it
  would rewrite the record of a running app to suit a command someone typed.
- **It does not execute.** Not a gap to be filled later without thought: a run
  spends a single-use approval and real money, and a human gate does not
  survive being handed a `--yes` flag.
- **No Electron, enforced at build.** The store and orchestrator were kept
  Electron-free so they could be tested without a window; `scripts/build-cli.mjs`
  fails on an `electron` import and prints the edge, because such a bundle
  builds cleanly here and dies on the first line of every real invocation.
- The tests build the bundle and run it as a subprocess. Stdout being valid
  JSONL, a refusal exiting non-zero with an empty stdout, and the absence of
  Electron are all properties of the artifact that a function call cannot see.

## Remote execution: one snapshot in, one candidate back

Structural rules for anything touching `src/remote/**` or `src/main/remote/**`.

**The execution core may not reach the record.** `src/main/orchestrator/execution.ts`
runs wherever the repository is, so it states FACTS through a `MilestoneReporter`
and never writes a row. `boundary.test.ts` proves this by BUNDLING the module
and asserting its graph contains no `/store/`, no `/ipc/` and no `node_modules`
— not by reading imports, because the first version of that boundary looked
clean and pulled in `ipc/ledger` transitively. Adding a store import fails the
`parley-remote` build.

**The bundle contains no npm code, absolutely.** Not "no npm except X". A
runtime value that drags a library in belongs in a dependency leaf
(`src/shared/usage.ts`, `src/main/util/ids.ts` are the precedents). The build
prints the edge that pulled a package in, because "npm code appeared" is not
actionable.

**Nothing dynamic reaches an ssh command line, ever.** Not for runs, not for
installation. The remote command is a compile-time constant; everything that
varies goes as JSON on stdin. Installation uses `sftp -b -` for bytes and a
base64-encoded constant `node -e` bootstrap for hash, handshake and activation.
`scp` is not used: it has spoken SFTP only since OpenSSH 9.0 and `-O` reverts
it.

**Stdin stays open for the life of a run.** It is how the far end learns the
connection died, and closing it IS the graceful cancel. A reader that consumed
to EOF would never return while the link was healthy and would return instantly
once it was not.

**Frames carry identity; soup is fatal once alive.** Every frame has a runId
and a sequence contiguous from 1. Before the handshake, unreadable output is
tolerated (ssh banners, shell profiles). After it, any unframed byte or gap is
fatal — a run that continues while silently dropping facts writes a record with
a hole in it. Sequences belong to the CONVERSATION: every frame is admitted to
the sequencer, not just the ones carrying facts.

**The pipeline never runs in the process ssh talks to.** A worker leads its own
process group so cancellation reaches every agent and test command; if the
pipeline ran in the supervisor, killing that group would kill the cleanup.

**A published ref is a candidate.** Ancestry against the submitted snapshot and
changed-path reconciliation both run locally, against objects this machine
holds. Replay refuses the whole report if the milestone's fingerprint moved
while the run was in flight.

**Refusals**: worktree-only, no mock plans, self repo exempt. Checked before
anything is snapshotted, pushed or spent.

**A finished run's record consequences belong to whoever holds the record.**
The execution core states facts and writes no rows, so ingesting a finding as
a ledger occurrence, settling the blockers a passing milestone answered, and
moving the plan's status are all done locally — including for a run that
happened on another machine. `Pipeline.settleFinishedRun` and
`Pipeline.ingestFinding` are the single implementation both paths call.

Settling and ingestion are ONE method deliberately. Recording findings without
settling them is worse than dropping them: every remote run would leave open
blocking occurrences gating the next approval, so a host that worked perfectly
would make the plan unrunnable. Whoever calls one must call the other, and the
way to guarantee that is to have one thing to call.

The remote side runs it only when the milestone actually settled
(complete/failed/parked), not per driver outcome: `unstarted` spent nothing
and touched nothing, and a disconnect may have left the work finished over
there and unknown here. Concluding anything about the plan from either would
be inventing a result.

**A fake host goes under the Manager**, through two deps: `sshBinary` and
`remoteMirrorUrl`. `remote.integration.test.ts` drives the whole path —
approval, reporter wiring, ledger consequences, journal attribution — against
an ssh that is a real program doing real git work in a real bare repository.
It publishes an actual candidate, so the local ancestry and changed-path
reconciliation run for real; a fake that merely returned a manifest would
agree with itself. That test was written by reverting the ledger fix
underneath it and confirming it went red, which is the only way to know a test
has teeth.

`sshConverse` took a `nodeCommandFor` before this that every caller supplied
and nothing read — the helper is invoked by name off the host's PATH, so which
node runs it is the launcher's business.

**A host's environment is the part fakes cannot prove.** Everything above was
green against a fake `ssh` for the whole arc, and the first real host broke
three times in the same place — nvm puts node where a non-interactive ssh
session will not look:

- sftp carries no mode, so the bundle landed 644 and could not be executed;
- its `#!/usr/bin/env node` shebang had no node to find;
- the run's own verification command (`node test.js`) could not be spawned.

The first two are why activation writes a **launcher** — a small `sh` script
naming `process.execPath` absolutely — and links THAT rather than the `.mjs`.
It is written twice on purpose: once in staging so the probe executes it, and
again after the rename, because the staging path it first named is the
directory activation just destroyed. The third is why `src/remote/main.ts`
appends `dirname(process.execPath)` to `PATH` at entry — appended, never
prepended, so a repository that pins its own toolchain still wins.

**Prove an installation the way a run uses it.** The staged handshake ran
`node <path>`, which bypasses both the executable bit and the shebang — it
passed on a host where every run then failed. `installRemote` now ends by
speaking the protocol to bare `parley-remote`, resolved off the host's own
PATH, and reports `ok: false` if that fails. A gate that cannot fail the way
the thing it guards fails is not a gate.

**The runner ships with the app, outside the archive.** `npm run build`
produces it (so the self-update gate's rebuild keeps a relaunched Parley's
runner matching), electron-builder ships it via `asarUnpack: out/remote/**`,
and `remoteBundlePath(appPath)` resolves it in both worlds by substituting a
TRAILING `app.asar` for `app.asar.unpacked`. Unpacked is not a detail: sftp is
a separate process and cannot read out of an asar, while Electron patches `fs`
so an in-archive path hashes perfectly and only fails at the upload — the
failure that looks most like success. `install.test.ts` asserts the packaging
manifest itself, because every other test resolves paths on a disk where
`out/` always exists, which is how remote execution stayed dev-checkout-only
through the whole arc without a single red test.

**Integrity is read off the disk, never asked of the runner.** `remoteStatus`
takes two readings: the handshake for what the runner can do, and a bootstrap
`status` operation for what is actually installed — the resolved link, the
versioned directory's NAME, and what the bytes beside it hash to. It used to
have one source and passed the handshake's build id into all three identity
fields, grading a number against itself, so `corrupt` was unreachable by
construction.

The runner is honest — it hashes its own bytes at startup — but a self-report
cannot in principle be the check on itself: a tampered bundle truthfully
reports the tampered hash and has no way to know that is not what it was
installed as. The **directory name** is the independent witness, and it is the
only thing that remembers what was activated. The bootstrap resolves the link
exactly ONCE and derives everything from that path, because two readings could
straddle an activation and report one build's directory against another's
bytes — which reads as corruption and is not.

What this does NOT catch is a consistent replacement, where the directory is
renamed to match the new bytes. That is a supply-chain question, defended at
install time by hashing against the bundle Parley itself built; status cannot
help, because a target may legitimately run an older build than the Parley
inspecting it.

**The acceptance**: `PARLEY_LIVE_REMOTE=<ssh-host>
PARLEY_LIVE_REMOTE_NODE=<absolute node> npx vitest run
src/main/remote/live.test.ts` after `npm run build:remote`. It installs, runs a
real milestone with a real agent CLI on the host, checks the candidate came
back with only the declared path changed and local HEAD untouched, then rolls
back and reinstalls. Run it after touching anything under `src/remote/**` or
the installer — the fakes will stay green through all three failures above.

Point `PARLEY_LIVE_REMOTE_BUNDLE` at
`dist/mac-arm64/Parley.app/Contents/Resources/app.asar.unpacked/out/remote/parley-remote.mjs`
after `npm run package:mac:dir` to accept the SHIPPED artefact rather than the
checkout's — the only copy most people will ever have.

## The self repo: worktree-only, gate fail-closed, quit never exit

`electron-vite dev` watches and hot-reloads the **renderer only**. The main
and preload bundles are built once into `out/` at startup and never rebuilt
while the app runs — so after a plan lands on Parley's own checkout, the
running process is executing stale bytes *by construction*. That is the
hazard this section exists for: not an uncontrolled restart, but a user who
lands self-improvements and keeps running old code without realising.

The rules, each enforced in main, none only in the renderer:

- **Identity.** `OrchestratorDeps.selfRepoPath` is
  `app.isPackaged ? null : app.getAppPath()`, canonicalised once by the
  Manager. Null (packaged, or tests that don't care) leaves every rule here
  dormant. The renderer's copy in `AppInfo` is advisory UI-greying only.
- **Worktree-only, both doors.** createPlan refuses checkout isolation for
  the self repo, and the pipeline's execution entry (`entryRefusal`, beside
  the shared `executionRefusal` at every entry and raced re-check) refuses
  grandfathered rows — a checkout plan created before the rule must not
  bypass it forever. An agent writing into the live app's source under it is
  the one uncontrolled case.
- **The gate replaces the smoke check.** Landing a plan whose repo is the
  self repo runs `npm run verify` then `npm run build` (the self-update
  gate) INSTEAD OF the generic `verifyLanding` — two npm runs racing one
  origin would fight over node_modules and out/. The gate **fails closed**,
  in deliberate contrast to `verifyLanding`'s fail-open: that one is a
  courtesy smoke test of someone else's repo; this one gates an offer to
  restart the app into the bytes it produced, so every anomaly — spawn
  error, timeout, abort, throw — is a red row, never a shrug. Its captures
  use `killTree` (detached spawn, process-group signals), because a timeout
  that only reaches npm leaves the build's grandchildren alive and writing
  out/ behind the guard's back. Immediately before the build it snapshots
  every output file as path → size:mtimeMs, then requires a non-empty,
  changed snapshot after a zero exit. There is no clock grace: a no-op build
  cannot inherit output from a previous gate.
- **Supersede at attempt, not at outcome.** Filing a new gate attempt
  supersedes the previous green offer in the same transaction — the moment a
  new gate can touch out/, no stale "verified" offer may survive it, or a
  later failed build leaves green pointing at half-written bytes. One gate
  per checkout (`Manager.selfGateRuns`); landings that arrive mid-gate
  coalesce to the newest in `selfGateQueue`, with no durable row until that
  follow-up starts. A green gate with a queued successor supersedes its own
  row before starting the follow-up, so even a failed filing cannot leave an
  obsolete relaunch offer. `busyWithRuns` counts both states, and `disposeAll`
  clears the queue before aborting the controller so a quitting app finalizes
  only the live row red instead of starting more work or stranding `running`.
- **Relaunch is a recorded decision, decided before the quit.**
  `selfupdate.relaunch` refuses while `busyWithRuns()` names anything in
  flight, writes `relaunched`, and only then calls the injected
  `IpcAppControl.relaunch` — a crash mid-restart must not resurrect an offer
  already taken. The wrapper dedupes `--parley-fresh-build`, calls
  `app.relaunch({args})` and then **`app.quit()` — NEVER `app.exit`**:
  before-quit is what disposes agent CLIs and ptys, and skipping it orphans
  paid runs that keep spending quota headless. `applyFreshBuildFlag` deletes
  `ELECTRON_RENDERER_URL` when the flag is present — deletion, not assignment
  or ignoring — and index.ts calls it before reading that environment key, so
  the load, the navigation allowlist and every child spawn all see a world
  without the dev server.
- **The mock-walkability exception is deliberate.** Mock plans never land
  (invariant above), and the gate hooks at landing, so the PARLEY_MOCK
  walkthrough cannot exercise landing→gate→relaunch. The honest coverage is
  the integration suite (real git, real npm, fake self checkouts), the
  mounted smoke tests of the hold's inline controls, and the by-hand loop on
  the real checkout. Do not "fix" this by making mock plans land.
- **Two channels.** This loop upgrades the dev checkout — the factory. The
  installed .dmg is a frozen snapshot updated by `npm run package:mac` and
  reinstalling; packaged self-update (signing, asar, migrations, rollback)
  is a separate, much later project. The hold's detail says so, so the UI
  never implies the installed copy updated.

## The guided build is a guide, not an engine

There is no fourth engine behind Build an app. Each stage opens the same
control a user would reach for anyway, and the journey records what came
back. Keep it that way: the moment a stage runs something itself, every
gate that control carries has to be re-implemented here, and one of them
will be forgotten.

- **The record stores LINKS ONLY; the stage is derived** (`shared/journey.ts`
  over observations the Manager reads from the record). A stored stage
  would be a second opinion about state the record already answers, and it
  would disagree the first time someone worked outside the guide.
- **It follows the work, never the reverse.** Someone who ran the debate
  themselves and pointed the journey at it must arrive at the next stage,
  not be asked to repeat one. And it never skips ahead: building before
  briefing does not make the brief unnecessary.
- **The panel mounts its own dialogs** rather than knocking on another
  surface, because it needs their return value. That is the exception to
  the knock pattern and the reason for it.
- **Deleting a journey deletes only the guide.** Everything it links is
  durable on its own, which is also why the repository-activity guard puts
  it out of scope.
- The **readiness/disposition ergonomics** idea stays disposition
  ERGONOMICS if it is ever built — never auto-disposition, which would
  breach no-self-certification.

## Acceptance is a record, not a gate

Verification and independent review decide correctness. Acceptance records
whether the human wanted it. Keep them separate: making acceptance gate
anything would put a human judgement in the position of a machine check,
and the pipeline already refuses to let an agent certify its own work for
the same family of reasons.

- **It is the backlog's provenance for feedback.** The backlog rule is that
  every item traces to something that happened, which is why no free-typing
  add exists. Notes filed while judging carry `source: 'acceptance'` and
  the acceptance id; that is what makes typed feedback admissible at all.
  Do not add a bare "new item" button — add a record it can come from.
- **Recording is one transaction.** An acceptance whose notes did not file
  is feedback nobody can act on; items without their acceptance are exactly
  the untraceable typing the rule forbids. That is why `fileBacklogItemCore`
  exists — SQLite refuses a nested BEGIN, so a caller already in a
  transaction needs the core (the `createPlanCore` precedent).
- **A human's own words file `open`, not `proposed`.** Proposals exist
  because an AGENT drafted them and nobody had agreed yet. The event log
  records the source as `human` for the same reason.
- **Refused before completion.** Judging unfinished work would record
  someone looking at something that did not exist.

## Previews: the third process path, and why it is separate

`capture` runs a command to completion; a Grid pane is an interactive
terminal the user drives; a preview is a long-running server Parley starts
and must be able to stop. Do not fold it into either of the others.

- **Process-group discipline is the feature.** Every preview spawns
  `detached` so it leads its own group; stop signals the group (negative
  pid) with a SIGKILL escalation, and `disposeAll` runs on quit. A plain
  `child.kill()` reaps npm and orphans vite, which then holds the port with
  no visible way to end it.
- **Listen for `exit`, never `close`.** `close` waits for every writer to
  release the stdio pipe, and a dev server's own grandchild routinely holds
  it open — a crashed server would show as running forever. Output arriving
  after exit must not revive the record either; there is a guard and a test
  for exactly this, and it was a real defect caught by that test.
- **Read the URL, never construct it.** The port a server got may differ
  from the port it wanted; a link to a port nothing serves is worse than no
  link. `0.0.0.0` is rewritten to localhost because it is not an address a
  browser should open.
- **It opens in the user's browser**, through an injected `openExternal`.
  The renderer has no navigation and no remote origins, and a dev server is
  precisely the content that must not be granted an exception.
- **Nothing is persisted.** A preview dies with the app, so a stored row
  claiming one runs would be a promise the disk cannot keep — the Pane
  precedent.

## Scaffolding is its own capability class

Until the workspace creator, one rule held absolutely: **Parley creates no
file in a user directory that did not already exist.** The two `writeFile`
sites are save-dialog destinations the user typed; the pipeline's writes
overwrite-then-restore a tracked file behind a `realpathSync` containment
check; `mkdir` happens only under userData. `validateRepoPath` demanding
"the directory must already exist" is that rule's load-bearing expression.

The creator inverts it, so the fence is the feature:

- **`validateNewWorkspacePath` is the deliberate inverse** and is stricter
  than it needs to be: absolute and shell-free (`~` is a metachar, and an
  unexpanded tilde would create a literal `~` folder), the PARENT must
  exist so a typo cannot grow a tree, the target must be absent or an EMPTY
  directory, and never inside userData or the self checkout. Widening any
  of these needs a better reason than convenience.
- **`workspace.create` is a real approval**, granted against the RESOLVED
  path and consumed in the same synchronous block as the validation. An
  approval spent against a different path than it named would make the
  record a lie.
- **Verify before ready, always.** The workspace is recorded `ready` only
  after the template's own verification exits 0. This is the whole point of
  the series — the environmental-failure class dies by construction, not by
  remediation — so a future change that marks a project ready on a skipped
  or failed verification has removed the feature while keeping its UI.
- **Unwind removes only what it made.** `createdRoot` distinguishes a
  directory Parley created (remove entirely) from an empty one the user
  chose in the picker (keep the folder, empty it).
- **Commit before install**, so the first commit is the project rather than
  its dependency tree. A test asserts `node_modules` is untracked.
- **The template is code, not user data.** What Parley writes into a
  stranger's empty folder belongs under review with the rest of the app;
  `templates.test.ts` pins the load-bearing lines, including that the
  shipped starting test passes against the shipped starting function.
  `PARLEY_LIVE_TEMPLATE=1` proves the real install and verify.
- **`workspaces` is the fourth source of repository membership.**
  `listRepoSummaries` unions plans, backlog items and learnings; a
  brand-new project has none of those and would otherwise be invisible.

## The envelope: batch the authorisation, never the authority

An unattended run rests on one recorded approval (`plan.envelope`) from
which the driver mints each milestone's own single-use `milestone.execute`
approval. Keep that shape. A single envelope-wide approval spent by many
milestones would break two things at once: `milestones.approval_id`, and
the `milestone-failed` hold's generation, which folds that id — a second
failure after an ack would stop being a fresh hold.

- **The driver adds no power.** `driveEnvelope` loops over the same
  `runMilestone` a human drives; every gate still runs, including the
  findings check before each mint. It lives in `orchestrator/envelope.ts`
  with an injected `runMilestone`, so the whole loop is testable without
  the pipeline — the `runSelfGate` precedent.
- **Caps bound dispatch, never a running milestone.** Checked before each
  mint (milestones, wall clock, spend since the envelope started, with 0
  disabling the spend cap). A milestone already executing always finishes,
  exactly as loop iterations do.
- **Fail-park, and parked is TERMINAL.** Anything a human would have to
  answer ends the run; the existing hold surfaces it and the envelope's
  detail says how far it got. Continuing takes a fresh envelope. Do not
  add auto-resume — re-entering autonomy after an intervention is a new
  authorisation, and quietly reusing the old one is authorisation drift.
- **Order matters at the end of a milestone.** Read the gate BEFORE the
  result: a milestone stopped by the user returns non-complete, and
  reading the result first files the user's own Stop as a park — as
  something needing their attention. There is a test pinned on exactly
  this.
- **Never throws.** Every exit is a recorded state; a driver that threw
  would leave the row `running` forever, the one outcome an authorisation
  record must not have. `settleEnvelope` is conditional on `running`, so
  a startup reconcile and a live driver cannot both write an ending.
- **Worktree-only, and it ends at merge-ready.** Both are refusals at the
  grant, not conventions. Landing stays outside the envelope.
- **`keepAwake` is injected** (like `notifyUser`) so the orchestrator
  stays Electron-free. Its limit is stated wherever it is offered: it
  defers idle sleep, and a closed lid still suspends the machine.

## In flight is derived, never stored

`computeInFlight` reads the durable record — not the Manager's run
registries. Those registries are liveness for refusals; this is a view,
and a view that disagreed with the record would be worse than none.
Startup reconciliation already settles what a crash stranded. Same rules
as holds: oldest-first, every row openable, mock marked as mock, and a
consumption bar only where a cap actually exists.

## Dev containers: one seam, snapshots at creation, stated limits

Parley's own deterministic project commands can run inside a repository's
dev container. The rules that keep this narrow:

- **One seam.** `runProjectCommand`/`ensureUp` in
  `src/main/orchestrator/containers.ts` are the only way a project command
  reaches `devcontainer`. Exactly five call sites: milestone verification
  (`pipeline.runTests`, which also serves both mutation stages), worktree
  setup, landing verification, and the loop's command exit. Git operations,
  CLI probes and agent spawns never route through it — agents are
  host-authenticated and write on the host by design.
- **The argv contract is grounded, not assumed.** Probed live against
  @devcontainers/cli 0.87.0: `exec --workspace-folder <ws> -- <argv>`
  passes inner argv through verbatim (the CLI parses unknown options as
  args and consumes `--`), inner exit codes flow back unchanged, the
  command runs in the mapped workspace, and the default workspace mount is
  a bind mount — the fact mutation testing depends on. A volume-cloned
  `workspaceMount` would blind the mutation stage; that requirement is
  documented, not detected.
- **`up` only in write flows.** All five sites sit inside approved write
  flows, so this is structural. The pipeline brings a workspace up once per
  pipeline lifetime (same folder, same container); the loop runner once per
  run. Audits, reviews and foreman runs execute no project commands and can
  never trigger an image build.
- **Snapshot at creation, canonical at rest.** `repo_containers` stores the
  standing choice under the canonical path (the archives precedent);
  `plans.container` and `loops.container` are filled at creation and never
  re-read from the setting — an approval means what its row said. The self
  repo is exempt at creation and again at execution (`containerFor`'s
  belt): the gate builds host bytes for the host Electron.
- **Failure follows each site's existing contract.** Worktree creation:
  refuse, nothing half-made, approval unspent. Milestone verification: fail
  closed with the reason in the test result — explicit contrast with
  landing verification, which stays fail-open because the landing already
  happened. Loop exit: exit-not-met with the cause in the iteration detail,
  bounded by caps.
- **Honest limits, stated in results.** Timeout/abort kills the host-side
  CLI client; the in-container process may keep finishing. Containers are
  never torn down here. Git inside the container does not work for our
  worktrees (the CLI mounts the worktree common dir only for
  `--relative-paths` worktrees, which ours are not).
- **Testing.** `OrchestratorDeps.devcontainerBinary` injects an
  argv-refusing shim — a fake CLI that exits 64 on any shape the real one
  would not serve, then runs the inner command for real. The operator-run
  acceptance is `PARLEY_LIVE_DEVCONTAINER=1 npx vitest run
  src/main/orchestrator/worktree.integration.test.ts`, which completes a
  real milestone whose verification reads `/etc/alpine-release` inside a
  real container — a file that does not exist on the host.

## Long runs must not be opaque

A milestone can occupy half an hour between approval and verdict. The adapters
already report every tool use, file edit and command through `onActivity`; the
pipeline and the loop runner forward those as `plan.activity` / `loop.activity`,
and `RunActivity` renders them as a live feed with an elapsed clock.

This telemetry is **ephemeral and bounded** — never persisted, capped at 60
entries per subject. The durable record is the milestone row; the feed only
answers "is it stuck, or is it working?". If you add a new long-running stage,
wire `onActivity` into it, or it becomes another spinner.

## Grid tracks: `minmax(0, 1fr)`, never `1fr`

A bare `1fr` is `minmax(auto, 1fr)`, so the track refuses to shrink below its
content's min-content width. One long unbroken line — a file path, a JSON block
in a transcript — then pushes the grid wider than the window and clips whatever
is furthest left. The observed symptom was a sidebar heading that read
"ESSIONS".

Every track list in `styles/` uses `minmax(0, 1fr)`. Text that can contain long
tokens also needs `overflow-wrap: anywhere` — `break-word` does *not* reduce
min-content width, so it does not fix the layout, only the visual overflow.

## Crash recovery: terminal states, preserved run state, cheap resume

Runners live only in memory. Anything in flight when the process stops leaves a
row claiming to be `running` or `executing`, and the UI then correctly refuses to
retry something it believes is already going — the symptom is a milestone
spinning on "executing" forever.

`Repo.reconcileInterrupted()` runs at startup and moves every in-flight row to a
terminal state with an explicit reason. It is idempotent, it leaves settled rows
and unstarted (`idle`) loops alone, and it deliberately does **not** release a
consumed approval: retrying a write requires fresh authorisation even after a
crash — resuming too.

What a crash no longer destroys is the run itself. `milestones.run_state` (one
JSON blob, the `plans.pending` argument) carries the remediation round, the
concerns and the reviewer's critique verbatim, both vendors' resume ids — the
vendor CLIs own their transcripts on disk, so a resume id survives our process —
the pre-execution baseline (the one thing a dirty checkout makes
unreconstructible), and `baselineHead`, the validity anchor. It is written where
the loop's own locals change, cleared on completion and at retry/adoption entry,
preserved on failure and stop: **presence is what "resumable" means**, and
reconcile words the interrupted note accordingly.

`resumeMilestone` spends a fresh `milestone.execute` approval (the summary
carries the resume framing — no fourth scope) and re-enters the **same seeded
driver** `runMilestone` uses; never a parallel loop, or the two would drift.
Entry is decided by the world, not a recorded label: work present in the tree
means verify it against the preserved baseline; an untouched tree means execute
— a continuation prompt when the vendor session survived ("if the work is
complete, say so and stop"), the ordinary prompts with the persisted critique
when it did not. Resume refuses toward plain retry when `baselineHead` no
longer matches — every signature in a baseline is relative to HEAD, and
resuming across a moved HEAD silently misattributes the diff. The run-state
re-read and the spend share one synchronous block, because a racing retry
clears the state during the worktree await.

Two companions. **Stop**: `Manager.milestoneRuns` holds a `RunGate` per
in-flight milestone (execution, adoption and resume share it); the synchronous
has-check is both the stop button's handle and the concurrency guard. A stop
takes effect at the next boundary — commits and mutation restores finish, both
atomic — writes 'Stopped by you.' at every failure sink (never 'run was
cancelled', which now means only what it says; timeouts say 'run timed out'),
and keeps the run state. **Liveness**: the `LivenessWatchdog` observes the
activity stream, persists a throttled stamp on real activity only (a silent
run's stamp freezes — that frozen value is the stall hold's notify-once
generation), and asks the counterpart vendor for one read-only inspection per
stall episode. The verdict lands in the run state and the hold shows it.
Nothing is ever aborted automatically; the stopper stays human.

## Show both stdout and stderr, always

Never render or relay `stdout || stderr`. Compilers and test runners split their
output across both — `go test` prints `FAIL … [setup failed]` to stdout while the
compile error that explains it goes to stderr — so picking one hides the only
useful line. This was a real bug in the milestone panel and in the loop exit
check, and it made failures look like they had no cause.

## Judge the diff against a baseline, never against "clean"

`readTree()` snapshots the working tree **before** execution and again after;
`treeUnchanged()` compares the two. If nothing moved, the milestone fails
immediately — before tests and before review, both of which would otherwise pass
it, since an unchanged tree usually still passes its tests and a reviewer handed
no work has nothing to object to.

Do not go back to asking "is the tree dirty?". That was the original bug: a
single stray untracked file — an exported `VERDICT-*.md`, a leftover from an
earlier attempt — made the check see changes and wave through a milestone that
had written nothing. Repositories are dirty in practice; the baseline is the only
sound comparison.

The signature covers unstaged diffs, staged diffs, and untracked files (by size
and mtime, since their content is not in git). `readTree` reports
`unknown: true` outside a git repository, and `treeUnchanged` never returns true
for an unknown tree — otherwise every milestone in a non-git directory would
fail.

`renderDiffForReview()` also lists the paths that predate the milestone, so the
reviewer neither credits nor blames it for work it did not do, and
`missingExpectedPaths()` reports plan paths that were never created — the usual
reason a path-scoped test command fails instantly.

## Two macOS failure modes that look like something else

Both produce symptoms that point at the wrong thing, so they are worth
recognising on sight. `src/main/util/environment.ts` handles both.

**"posix_spawnp failed" for every pane, including `/bin/zsh`.** On macOS,
`pty.fork` execs through a separate `spawn-helper` binary that binding.gyp builds
as its own target (`['OS=="mac"', …]`). If it is missing or not executable, every
spawn fails identically, and the error names the command you asked for rather
than the helper — so it reads as "the CLI isn't installed" even for an absolute
path to a shell that plainly exists. npm's `allow-scripts` policy blocking
node-pty's build script is the usual cause: `pty.node` may come from a prebuild
so the module imports fine, while `spawn-helper` never gets built. `preflightPty()`
checks for it at startup and says so directly.

Under a signed hardened runtime the same symptom comes from library validation
refusing to exec the helper. `resources/entitlements.mac.plist` carries
`disable-library-validation` for that reason.

**The CLIs work in Terminal but not in the app.** A GUI-launched app is started
by `launchd`, which hands over a minimal `/usr/bin:/bin:/usr/sbin:/sbin` — not
your shell's PATH. Anything from Homebrew, `npm -g`, bun, mise or an install
script is invisible. `applyResolvedPath()` asks the login shell for its PATH at
startup and applies it to `process.env.PATH`, so every later spawn inherits it.

That shell query is the one place the app runs a shell, and it is a deliberate,
narrow exception to the no-shell rule: a fixed literal command with nothing
interpolated, sentinel-delimited output, and a hard timeout because it sits on
the launch critical path.
