# Parley — engineering guide

A local-first macOS workbench that drives Claude Code and Codex through their own
CLIs. Three surfaces over one governed engine: parallel terminals, adversarial
sessions, and capped autonomous loops.

## Product invariants

Break any of these and the product stops being what it is.

1. **Subscription CLIs only.** Every model call goes through the user's local
   `claude` or `codex` binary, against the account it is already signed in to.
   Never add an API-key path, not even as a fallback.
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
npm run dev          # Electron dev app with HMR
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
silently disables the changed-tree guard and blinds the reviewer. And the
status refusal is re-checked in the same synchronous block as the spend: the
ensure is an await, so two racing starts carrying two different approvals
would otherwise both get through — the atomic spend only protects one
approval against itself.

Nothing in worktrees.ts deletes work. Reconciliation flags rows orphaned when
their directory or origin vanished and never removes either; re-attachment
(`git worktree add <path> <branch>`, never `-B`) recovers a vanished directory
from its surviving branch; landing from an orphaned row still works, because
it needs only the origin and the branch. Mock plans refuse to land outright —
fast-forwarding a real branch onto mock commits would be invisible mock work,
with no marking anywhere in git.

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
