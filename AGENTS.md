# Parley — engineering guide

A local-first macOS workbench that drives Claude Code, Codex and Agy through
their own CLIs. One surface: a splittable grid of panes, where a pane is either
a real interactive terminal or a **room** — a conversation with one or more
agent seats over a single transcript.

The governed engine this app was built around — debates, codebase reviews, the
audited execution pipeline, capped loops, the backlog and its foreman, remote
execution, self-update — was retired in the Rooms arc and is gone. What it was
for is a room with two seats and a person deciding who speaks.

## Product invariants

Break any of these and the product stops being what it is.

1. **Subscription CLIs only.** Every model call goes through the user's local
   `claude`, `codex` or `agy` binary, against the account it is already signed
   in to. Never add an API-key path, not even as a fallback.
2. **No `--dangerously-*` flag, ever.** Not `--dangerously-skip-permissions`,
   not `--allow-dangerously-skip-permissions`, not
   `--dangerously-bypass-approvals-and-sandbox`, not `danger-full-access`. The
   capability ladder is `none` → `read` → `write` and there is no rung above it.
3. **Read-only is the default.** Every seat a room opens with is read-only.
   Writing is a per-seat flag somebody turns on, the capability is *derived*
   from that flag rather than passed beside it, and the room header states who
   holds it — permanently, because it is standing authorisation and a
   capability nobody is reminded of is one nobody remembers granting.
4. **Seats answering the same question do not hear each other.** An
   unaddressed message reaches every seat concurrently and independently. Two
   answers are two reads rather than one read and an agreement; that property
   is the whole reason to seat more than one. Sharing is an explicit act —
   naming a seat mid-sentence relays its last turn, and `advance` is the mode
   where each hears the one before it.
5. **Caps are enforced by Parley, before dispatch.** A room's turn budget is
   checked before every seat is dispatched and is never visible to one: an
   agent that can see its budget can argue about it. Reaching it is
   `exhausted`, never done, and continuing takes a deliberate new number.
6. **Everything stays local.** SQLite under `app.getPath('userData')`. No sync,
   no telemetry, no remote anything.
7. **Dissent is preserved.** Where a verdict exists — the optional converge
   action — disagreement lowers recorded confidence and the losing seat's
   objection is stored verbatim. Never smooth it away.
8. **The record outlives the window.** A room's turns are written as they
   happen, a turn when it *starts* so a crash loses the answer and not the
   question, and closing a pane never destroys a transcript.
9. **Mock mode is never invisible.** `PARLEY_MOCK=1` produces turns and
   verdicts structurally identical to real ones while consulting no model, so
   the chip is permanent and a saved transcript says NOT REAL WORK on its first
   line.
10. **macOS-native restraint.** Hairline rules, small radii, one accent,
    tabular numerals, system font stack. No gradients, no emoji, no decorative
    AI tropes.

## Commands

```bash
npm run dev          # Electron dev app; HMR is renderer-only
npm run typecheck    # both projects — must pass clean
npm test             # deterministic tests, no tokens spent
npm run build        # production bundles into out/
npm run package:mac  # signed-runtime .dmg + .zip for Apple Silicon
```

`npm run typecheck` deletes its own `.tsbuildinfo` first, and that is not
tidiness. Both tsconfigs are `composite`, and a stale build info let tsc report
a clean run over code it had not re-checked — the gate passed while the app
referenced a field that no longer existed. If you change these scripts, verify
the fix the only way worth trusting: break a file, see the error, run again
**unchanged**, and see it again.

Two escape hatches:

- `PARLEY_MOCK=1 npm run dev` — deterministic adapters, no subscription usage.
  Use it for UI work. A mock room's turns are structurally identical to real
  ones, which is why the chip is permanent and a saved transcript says so.
- `PARLEY_LIVE=1 npx vitest run src/main/agents/live.test.ts` — the only test
  that really invokes the CLIs. It spends a little quota and proves the argv
  and event schemas are still right. Run it after touching an adapter.


## Layout

```
src/shared/      domain schemas, the IPC contract, room vocabulary, JSON extraction
src/main/        agents/ (CLI adapters) · rooms/ · store/ · pty/ · ipc/
src/preload/     the renderer's entire view of the outside world
src/renderer/    React 19 UI: one surface over a hand-written design system
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
- `--strict-mcp-config` is passed to Claude so a room seat cannot silently
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

## Rooms: what the arc settled

A room is a pane holding seats over one transcript, and the rules that shaped
it are worth not re-deriving.

**The human is seat 0.** A scheduled exchange needed a side-channel to reach a
seat mid-schedule; a room has no schedule, so a person's message is simply a
turn. Two tables and a class of delivery edge cases disappeared with that.

**Seats are resumed, never replayed.** Each CLI keeps its own conversation and
Parley relays only what is new, so cost grows linearly with turn count. A
"re-send the transcript" implementation would look correct and quietly destroy
that.

**Addressing has three rules, each because the alternative spends money.**
Unaddressed means the whole room. Mentions are read only at the start, so "the
@reviewer decorator" stays prose. An unknown leading name is refused rather
than broadcast — a typo that falls back to everybody buys a turn per seat and
looks exactly like success. Mid-sentence a bad name is prose, because there it
costs input tokens rather than turns.

**Nothing usable back means nothing recorded.** A converge that produced prose
instead of a contract established nothing, and a row claiming otherwise is
worse than no row.

**Vendor resume ids are not persisted.** A thread belongs to a CLI process's
own history and Parley cannot know it survived a restart; a stale one fails at
the next turn in a way that reads as the seat breaking.

**Agy is tool-less in Parley's dispatch**, so it cannot hold a room seat — but
it can hold a *pane*, which is agy's own CLI with whatever tools it has
natively. That asymmetry is correct, not an oversight.

## The relay is the point

A grid of real CLIs that can hand work to each other. That is the product, and
it is the one thing no vendor will build: Claude Code's subagents take Claude
models, Codex's threads take OpenAI's, and every agent system is a closed loop
around its own models. The copy-and-paste people do between two terminals
exists because of that, and closing it is what this app is for.

Two rules fall out of it.

**Relayed content is pasted, never typed.** `submit` flattens newlines to
spaces — right for a one-line instruction, ruinous for a diff — and raw
newlines are worse, because a TUI reads the first one as Enter and sends a
message cut off after its opening line. `paste` wraps the payload in bracketed
paste, which is what ⌘V already does, and normalises carriage returns first
since content copied out of a terminal is full of them.

**A selection is not required, and not trusted to still exist.** The default
is the last answer — everything drawn since the person last pressed Enter,
tracked with an xterm marker — because "hand me its answer" is the actual
request and dragging a rectangle over a redrawing TUI is asking somebody to do
the terminal's job. A selection wins when there is one, and the last real
selection per pane is remembered, since letting go of ⌥ drops the highlight and
a live TUI redraws over it constantly.

**The frame comes off before sending.** A terminal buffer is a picture, and
`│ Welcome back Mark! │` is noise pretending to be a message. `cleanRelayText`
strips box-drawing characters only — never ASCII `-` or `|`, which are diffs,
fences and flags, and are the most valuable thing the relay carries.

**Relayed content carries where it came from.** The receiving CLI has no idea,
and an unattributed wall of another model's reasoning reads as the user's own
words.

The scope test for anything new: *could Claude Code do this on its own?* If yes,
do not build it — the vendor owns the model and the session and will do it
better. If no, it is cross-vendor, and it is this app's. The grid passes. The
relay passes. Task boards, worktree lifecycles, review queues and orchestration
all fail it, which a parked branch called `feat/workbench-ux` demonstrated at a
cost of ten thousand lines.

### If you are reading this from inside a pane

A CLI running in a Parley pane has `PARLEY_PANE=1` in its environment, with
`PARLEY_PANE_ID`, `PARLEY_PANE_KIND` and `PARLEY_APP_PID` beside it. If those
are set, you are already inside the app.

**Do not start another instance.** Asked to send something to a neighbouring
pane, a Claude Code session launched a second Parley with a remote debugging
port and drove it over CDP — building an entire app to reach a pane it was
sitting next to, because nothing told it where it was. There is no way to relay
from inside a pane today: relaying is a menu action the person takes, which is
the design rather than an omission. Say so and let them do it.

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

## Agent profiles: a name for a way of configuring a seat

The Buzz idea taken without its luggage: a reusable agent identity is a
vendor, model, effort and persona under a name — **never credentials**. The
CLIs hold their own authentication; a profile that carried keys would turn a
convenience into a vault. `agent_profiles` (schema 32), unique NOCASE name,
CRUD beside the remote targets it resembles.

The load-bearing decision is that a seat carries the profile's **name as a
stamp**, not a reference. `AgentConfig.profile` is set at pick time, travels
wherever the config goes — into the plan row, over the wire to a remote
worker that holds no record of profiles — and lands in the journal as
`actor_profile` on every event the seat produced. A name and not an id
because the journal is read by people and outlives renames: what a seat was
called when it acted is a fact, and deleting or renaming the profile later
does not reach it.

A hand edit ends the profile. The picker routes every field change through
one `edit()` that deletes the stamp, because a config that has drifted from
its profile is not that profile — leaving the name on would put "Fast
reviewer" in the journal on a seat somebody quietly retuned. The eligibility
fallback (vendor auto-corrected for a role) drops it for the same reason.

The Run Room and the CLI's `runs`/`journal` output lead with the profile name
when one is present ("Fast executor on build-01"); the vendor stays on the
event for queries.

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
- **In the app, search lives in the ⌘K palette** — actions first, "In the
  record" beneath, one cursor across both. `Manager.search` resolves each
  hit's DOORS (session, plan, milestone, repository) before it leaves main,
  because a milestone hit's scope is a plan id and only the record knows which
  session and repository that plan belongs to; four surfaces doing that join
  would be four copies. Hits route exactly as a hold's jump does: through the
  session when one survives, to the Repos surface when only the repository
  does. The «marks» in a snippet are the search layer's highlighting protocol
  and become `<mark>` only at the palette — chosen as characters that cannot
  appear in a git path or survive tokenising.

## Grid tracks: `minmax(0, 1fr)`, never `1fr`

A bare `1fr` is `minmax(auto, 1fr)`, so the track refuses to shrink below its
content's min-content width. One long unbroken line — a file path, a JSON block
in a transcript — then pushes the grid wider than the window and clips whatever
is furthest left. The observed symptom was a sidebar heading that read
"ESSIONS".

Every track list in `styles/` uses `minmax(0, 1fr)`. Text that can contain long
tokens also needs `overflow-wrap: anywhere` — `break-word` does *not* reduce
min-content width, so it does not fix the layout, only the visual overflow.

## Show both stdout and stderr, always

Never render or relay `stdout || stderr`. Compilers and test runners split their
output across both — `go test` prints `FAIL … [setup failed]` to stdout while the
compile error that explains it goes to stderr — so picking one hides the only
useful line. This was a real bug in the milestone panel and in the loop exit
check, and it made failures look like they had no cause.

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
