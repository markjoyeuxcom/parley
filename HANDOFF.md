# Parley — continuation handoff

Refreshed 2026-07-28, after the SelfUpdate series landed — the self-building
arc is complete. Everything a fresh session needs that the code and git
history do not already say.

## What this repo is

Parley: a local-first macOS Electron workbench that drives Claude Code and Codex
through their own CLIs — parallel terminals, adversarial sessions, and capped
autonomous loops over one governed engine. **Read `AGENTS.md` first**; its ten
product invariants are non-negotiable.

This repo is the rebuild called for by the **Parley Flexibility Roadmap**
(2026-07-25, `ROADMAP.html` in the repo root). The 2026-07-27 planning sessions
added a second arc on top of the roadmap, adapted from studying
github.com/kunchenguid/firstmate: the prerequisites for Parley building and
improving *itself* through its own pipeline.

## How work proceeds here

- Named milestone **series**, one commit per milestone, directly on `main`.
  Completed: **Remediation m1–m10**, **Ledger m1–m9**, **Participants m1–m6**
  and **Engine m1–m2** (a parallel session's arcs — seats as data, protocols
  as values), **Holds m1–m3**, **Worktrees m1–m3**, **Recovery m1–m6**,
  **Backlog m1–m5**, **Foreman m1–m5**, **Repos m1–m5**, **SelfUpdate
  m1–m5**, plus a day of walkthrough-found fixes (emit side-door, plan
  tabs/titles, exchange fold, four-column layout, bulk dispositions,
  mounted smoke tests).
- Commit messages: `<Series> mN: <lowercase sentence>`, thorough provenance
  body, `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.
- Two sessions have worked this repo in parallel all day. Schema numbers are
  taken as max+1 at land time, never assumed; existing migration guard blocks
  are never edited.

## State at handoff (schema v20)

- **Holds m1–m3**: the attention queue. Derived, never materialised; acks +
  notify-once stamps are the only new rows; decision holds refuse acks in the
  main process; titlebar badge counts decisions only.
- **Worktrees m1–m3**: isolated execution. Per-plan worktree/branch, Parley
  commits each pass, ff-only human landing, registry reconciled at startup,
  never deletes work. Mock plans refuse to land.
- **Recovery m1–m6**: `milestones.run_state` preserves round/critique/resume
  ids/baseline+HEAD anchor (written where the loop's locals change, kept on
  failure and stop — presence is what "resumable" means); timeouts and stops
  are distinguished ('run timed out' vs 'Stopped by you.'); a stop button and
  in-flight registry (`Manager.milestoneRuns`); `resumeMilestone` re-enters
  the same seeded driver with a fresh `milestone.execute` approval, refusing
  when `baselineHead` moved; the `LivenessWatchdog` surfaces stalls as holds
  with one read-only cross-vendor inspection per episode (never auto-aborts);
  landing consumes a recorded `plan.land` approval behind the finding gate,
  preflighted before the spend, smoke-verified in the origin after; the holds
  queue deep-links into the approval dialog.
- **Backlog m1–m5**: the per-repo backlog + stow (see AGENTS.md "The backlog"
  for the structural rules). Deterministic ingestion (confirmed review
  findings, accepted risks, startup back-sweep), the gated Stow sweep filing
  proposals + learnings, plan briefs carrying selected items + confirmed
  learnings, closure **proposals** at completion (worktree plans at landing),
  the ⌘4 surface (columns, blocked-by editing, linked-plan status, learnings
  curation), and a per-repo `backlog-review` decision hold (generation =
  newest pending item's timestamp — never a count).
- **Foreman m1–m5**: the proposing role (see AGENTS.md "The foreman" for the
  structural rules). One gated read of a repo's open backlog files a plan
  proposal: attempt rows `running` before dispatch (startup-reconciled),
  supersede-at-finalize, failed rows keep their spend, open-items snapshot
  for staleness display, untrusted-records prompt framing. Acceptance IS
  plan creation — `createPlan({foremanProposalId})` routes plan row + item
  flips + accept stamp through `repo.bindPlanCreation` in one transaction;
  rejection records the reason; a per-repo-per-mode `foreman-proposal`
  decision hold (generation = proposal id) joins the queue. The surface's
  ForemanPanel (Ask the foreman, proposal card with live-title resolution +
  staleness line, accept → prefilled NewPlanDialog).
- **Repos m1–m5**: the repository is the navigation unit (see AGENTS.md
  "The Repos surface" for the three renderer rules). ⌘4 relabeled "Repos"
  (id 'backlog' kept): sidebar from repos.list summaries (union of
  plan/backlog/learning repos), tabs Overview (in-flight plans + repo-
  scoped holds via useHoldJump + foreman + New review) · Backlog · Plans
  (cross-session table, plan opens IN PLACE via the session view's own
  PlanPanel with host="backlog") · Learnings. planLedger travels with the
  plan atomically and fails closed (null = unknown → gate disables);
  ParleySurface gained the ownership guard killing the wrong-session-gate
  latent bug; every hold now carries canonical repoPath (outside
  holdIdentity, identity-pinned); plansVersion keeps fetched plan lists
  fresh; getSessionDetail's 200-cap bug fixed (listPlansForSession).
- **SelfUpdate m1–m5**: Parley lands on itself deliberately (see AGENTS.md
  "The self repo" for the structural rules). `selfRepoPath` identity
  (packaged = null = dormant); worktree-only for the self repo at createPlan
  AND at the pipeline's execution entry (grandfathered rows covered);
  `self_updates` record (FK-less; supersede-at-ATTEMPT); the gate = `npm run
  verify` then `npm run build` INSTEAD of verifyLanding, fail-closed, killTree
  captures, one per checkout, disposeAll aborts → red 'interrupted'; green =
  a `self-update` decision hold with inline [Relaunch]/[Not now] + cost
  confirm (ids re-resolved at click time via selfupdate.pending); relaunch =
  decide THEN app.relaunch + app.quit (NEVER app.exit — orphans paid CLIs),
  `--parley-fresh-build` deletes ELECTRON_RENDERER_URL; red flags the landed
  row through the existing hold. Mock cannot walk landing→gate→relaunch
  (mock never lands, deliberate — integration + smoke cover it).
- Verified per milestone on this Mac: `npm run typecheck` clean, `npm test`
  green (659 passing at SelfUpdate m4, 6 skipped — the `PARLEY_LIVE` adapter
  suite, by design; the suite includes 8 mounted-surface smoke tests). The
  2026-07-28 walkthroughs found and fixed six real defects. **The SelfUpdate
  loop was accepted by hand on 2026-07-28 evening**: a real plan added the
  README "Development status" line (commit 6716735), landed by fast-forward,
  gate green in 35s, Relaunch taken (self_updates row `relaunched`), the app
  survived closing the originating dev terminal — no detached-respawn
  fallback needed. The Foreman flow was walked the same evening (ask →
  proposal with deferrals → hold → accept → prefilled dialog → atomic
  acceptance → drafted plan gated by audit findings) and surfaced two
  fixes, landed as 122c5d9: open → done is now a legal human transition
  (board Close control — "already landed" advice was previously only
  actionable as a lying `dropped`), and a zero-selection foreman read now
  keeps its rationale/deferrals on the failed row, rendered under the
  panel's idle line. The Repos round trip was walked 2026-07-29 by running
  the foreman's own accepted plan end to end from the Plans tab in place:
  six audit findings dispositioned, three milestones executed and
  reviewed, branch landed on the real repo, closure proposal confirmed.
  Nothing on the by-hand list remains.

## Open threads (good next candidates)

The self-building arc is COMPLETE and has run its **second lap
(2026-07-29), fully self-originated**: Parley reviewed its own test suite
(scoped brief: "what does the suite prove vs appear to prove"; 9 confirmed
findings with two hitting the SelfUpdate tests themselves, 3 dismissed by
cross-examination, dissent preserved at 77% confidence), the foreman
batched five into "Make CI verify, and make four untested guards fail
when broken" and deferred four with reasons, the plan landed as
ddee145..0c23d57 (GitLab `verify` job — node:24-bookworm,
`npm ci --ignore-scripts`, `allow_failure: false` — plus ci.test.ts
pinning the yaml itself; the self-gate build-failure arm exercised; the
npm-path test de-tautologised via a fake npm on PATH; verifyLanding
tested for real, fabricated test replaced; the relaunch wrapper extracted
to src/main/ipc/relaunch.ts as an injectable seam and tested), the gate
went green in 33s, the relaunch was taken, and **the CI job's first run
on GitLab passed** — every push is now verified, blocking. The repo lives
at gitlab.com (origin configured); Parley never pushes — that stays a
human act.

What remains is usage, and much later the packaged-app updater (signing,
asar, migrations, rollback — a separate project; the .dmg channel stays
`npm run package:mac` + reinstall until then).

The deferred-findings batch closed 2026-07-29, with one honest asterisk:
plan 3 ("Close the three deferred coverage gaps") completed its ledger-
disabled and deep-link milestones, but milestone 3 failed EXACTLY as the
guards intend — codex claimed completion with a byte-for-byte unchanged
tree (capturing live CLI streams is impossible inside the executor's
network-blocked sandbox), the tree guard and reviewer blocked it, and the
plan stays failed on the record. The recovery was human-side: milestones
1–2 cherry-picked from the surviving branch (bd2b7e1, 0ed9ea7), and the
operator captured the fixtures outside the pipeline — real Claude 2.1.220
and codex-cli 0.145.0 streams, scrubbed, replayed through the public
adapter run methods in src/main/agents/events.test.ts with provenance in
the header. Lesson recorded: live-CLI capture is a privileged act, like
landing.

Laps three through six landed 2026-07-29/31, mixing self-review findings
with the first debate-originated feature work (schema now **v21**):
- The openPlan race fixed by its own plan; a third same-brief self-review
  came back with ZERO P1s, none of the original nine recurring, and two
  earlier repairs verified in its dismissed list.
- "Close three P3 worktree and relaunch gaps" — landWorktree teardown
  recorded, worktree origin-identity in the health check (recovered via
  Adopt & verify after a **stale-position mutation** burned the
  remediation budget: a declared break that matches its anchor textually
  but is a semantic no-op against the executor's final code reads as
  vacuous tests; amend the mutation, adopt — lesson on the record), and
  the fresh-build flag behind a testable seam.
- "Give the three untested boundaries real seams" — injectable Codex
  config path, preflightPty probe seam, mounted-bridge invoke-envelope
  rejection.
- **Repository archiving** (the fourth-lap feature, debate-originated at
  65% confidence with both dissent demands promoted to requirements):
  repo_activity watermark + repo_archives at v21, noteRepoActivity
  committed atomically with each durable write and proven complete by a
  total-classification tripwire (unclassified table fails), archive
  refuses live attention naming every reason, later durable activity
  auto-revives, All-repositories toggle mirrors the sessions sidebar,
  every milestone verified with full `npm run verify`.

**The queue (designs banked in the assistant's memory, each with
pushbacks and verify-at-build lists):**
**Landed since this list was written:** packaging prep (userData split
`parley-dev`/`parley`, titlebar dev chip, naming settled) and the **agy
adapter series** — third vendor live end to end (through 03fbd3a; first
three-vendor debate settled 2026-07-30). Facts superseding the old
item: delivery is FLAGLESS piped stdin — no `-p` at all (bare `-p`
swallows the next token as its prompt, and a value would put the brief
in the process table; with no print flag agy detects the non-TTY pipe
and reads stdin headless). `--effort` is never passed — tiers are baked
into the gemini-* slugs, resolved against `agy models` discovery.
Headless agy EXECUTES global permissions.allow rules without prompting
(proven live), and its shell runs in agy's own scratch that Parley's
scratch check can't see — so the adapter fails any observed
`step_type: "tool"` closed (real recording:
src/main/agents/fixtures/agy-tool-stream.ndjson). agy seats are
tool-free debate seats only (`seatingRefusals` in shared/vendors.ts);
planner/executor/reviewer stay claude/codex until per-lineage grant
validation (backlog item filed). Advise operators to keep
`~/.gemini/antigravity-cli/settings.json` permissions.allow empty.

**Dev containers: LANDED** (Containers m1–m4, schema 22). One seam
(`orchestrator/containers.ts` runProjectCommand/ensureUp) routes exactly
five sites — milestone verification incl. both mutation stages, worktree
setup, landing verification, loop command exit; repo stays local, agents
write on host. Per-repo choice on the Repos Overview card, refused
without config/CLI/for the self repo; **snapshotted onto plans and loops
at creation** (approval text names it). Failures follow each site's
contract (refuse-unspent / fail-closed / fail-open post-land /
exit-not-met under caps). Grounded live against @devcontainers/cli
0.87.0: flagless `exec --ws -- argv`, exit codes flow, bind-mount edits
visible in-container; operator acceptance arm
`PARLEY_LIVE_DEVCONTAINER=1 npx vitest run
src/main/orchestrator/worktree.integration.test.ts` completed a real
milestone reading /etc/alpine-release inside a real container. Known
limits documented (lingering containers, orphaned in-container work on
timeout, no git-in-container for worktrees, bind-mount required for
mutations). Follow-up chips: agents-in-container (runJsonl seam, auth
question), container lifecycle/cleanup. The infra pairings (render
attachments, skill pack, Grid kube-context chips, verification presets)
remain future work.

**Grid I: LANDED** (Grid m1–m6). The load-bearing find: state.panes had
been empty since the Grid was built (pane.created never emitted,
pane.list never called) — every status dot, exit chip and the ⌘1 count
was unreachable; m1 connected the pipe and fixed the semantics (exit is
a STATUS and the corpse survives; pane.closed = user close = removal).
Then: slot lifecycle menu (stop/restart/reopen/replace/rename/duplicate
+ Resume via the CLIs' OWN pickers — `claude --resume`, `codex resume`,
never governed ids); maximize (overlay — siblings stay mounted,
scrollback survives)/swap/⌘[ + the window-keydown surface guard (⌘W on
other surfaces was silently closing Grid panes); identity headers
(bounded pane.identity — 4 git calls 5s ceiling, never readTree;
worktree chip matched realpath-to-realpath, says landed/unlanded, never
"safe to remove") + deterministic unread dot, all Grid-local, NEVER
into holds; both bridges (focusGridSpawn/focusNewSession knocks —
"Open worktree in Grid" on every worktree plan, "Review this in
Parley…" with terminal selection as matter) + Broadcast (keystrokes
shape, one writePane per agent pane); ⌘F scrollback search (the
installed-unused search addon) + Save transcript (@xterm/addon-serialize
added, save-dialog IPC mirroring session.export); AGENTS.md carries the
new Grid rules. **Grid II comforts** follow usage; comparison mode
stays parked as a PIPELINE feature.

**Unattended runs: LANDED** (Envelope m1–m5, schema 23). `plan.envelope`
approval scope routed through the grant switch's typecheck tripwire;
`envelopes` table (FK-less, conditional settle so reconcile and driver
cannot both end a run); `orchestrator/envelope.ts` driver loops over the
SAME runMilestone, minting each milestone's own single-use approval
whose summary names the parent envelope — milestones.approval_id and
the milestone-failed generation keep their exact shape. Caps bound
dispatch only (0 spend = disabled, the loops rule). Fail-park at the
EXISTING holds; **parked is terminal** (a fresh envelope to continue —
do not add auto-resume). Worktree-only and ends-at-merge-ready are
refusals at the grant. Defect the integration arm caught and pinned:
read the gate BEFORE a non-complete milestone result, or the user's own
Stop files as a park. keepAwake injected like notifyUser (idle sleep
only — a closed lid still parks the run). Plus **In flight**: a
titlebar popover, derived from the record not the run registries,
oldest-first, every row openable, bars only where a cap exists.
**Still to do: the by-hand acceptance** — grant an envelope on a small
real worktree plan and come back to merge-ready.

**App Builder series 1 of 4: LANDED** (Workspace m1–m4, schema 24).
The load-bearing fact: scaffolding is a NEW CAPABILITY CLASS — until this,
Parley created no file in a user directory that did not already exist
(the two writeFile sites are save-dialog destinations; the pipeline
overwrites-then-restores a tracked file behind containment).
`validateNewWorkspacePath` is the deliberate inverse of
validateRepoPath and is stricter than needed (absolute, shell-free so
`~` cannot make a literal folder, parent must exist, target absent or
EMPTY, never userData/self). `workspace.create` approval granted
against the RESOLVED path. Order is the feature: scaffold → commit →
install → **verify must pass before `ready`**, else unwind (removing a
dir Parley made entirely; emptying one the user picked). Template is
CODE not config, pinned by templates.test.ts incl. that the shipped
test passes against the shipped function; `PARLEY_LIVE_TEMPLATE=1`
proves the real install+verify (passed 2026-07-31). `workspaces` is the
FOURTH source of listRepoSummaries membership — a new project has no
plan/backlog/learning and would otherwise be invisible. **Still to do:
the by-hand acceptance** — create a real app, then plan a first feature
against it.

**App Builder series 2 of 4: LANDED** (Preview m1–m3). The third
process path: `capture` runs to completion, a Grid pane is interactive,
a preview is a long-running server Parley must be able to STOP. Every
preview spawns detached (own process group), stop signals the group
with SIGKILL escalation, disposeAll on quit — a plain child.kill()
reaps npm and orphans vite holding the port. **Defect the tests caught:
listen for `exit`, NEVER `close`** — close waits for every pipe writer
and a dev server's grandchild holds it open, so a crashed server showed
as running forever; late output must not revive an exited record
either (guard + test). URL is READ from output (the port it got may
differ) and opened via injected openExternal — never navigation inside
the renderer. Command suggested from the project's package.json
(dev→start→serve). Nothing persisted: a preview dies with the app (Pane
precedent). One per repo.

**App Builder series 3 of 4: LANDED** (Acceptance m1–m3, schema 25).
An acceptance is the human's judgement on a COMPLETED milestone —
deliberately NOT a gate (verification + independent review already
decide correctness; this decides whether it is what they wanted).
Second job is the load-bearing one: it is the backlog's provenance for
FEEDBACK. The backlog rule is that every item traces to something that
happened, hence no free-typing add; notes written while judging file
with source 'acceptance' + originAcceptanceId, straight to `open` (the
human is the author; proposals exist because an AGENT drafted them),
and the event log calls it a `human` act. **Recording is ONE
transaction** — an acceptance whose notes did not file is unusable
feedback, items without their acceptance are the untraceable typing the
rule forbids — which required extracting `fileBacklogItemCore` (SQLite
refuses nested BEGIN; the createPlanCore precedent). Controls sit ABOVE
the fold: a completed milestone folds by default and the first draft
hid the only thing still needing a person.

Remaining: **App Builder series (4) the thin guided shell**
(Brief → Challenge → Foundation → Build → Preview → Harden). Readiness
stage = disposition ERGONOMICS, never auto-disposition.

1. **SSH/remote execution arc** after App Builder (execution-target
   abstraction over the ~6 local-assuming touchpoints), composing with
   unattended for overnight VM runs.

Small UI batch (foreman-sized, slots anywhere): sessions organization —
a group-by control on the ⌘2 sidebar (None | Project | Repository,
collapsible headers, archived toggle unchanged), a **Sessions tab on
the Repos surface** (the missing tab — a repository's reviews and
debates are its record too, and the future delta re-review work needs
this listing as its home), and recent-project suggestions in the
new-session dialogs (datalist nudge; project stays free text — no
project entity, no third organizing surface).

Older carried items: delta re-reviews / recurring finding identity;
`approveAndRun`/`adoptExisting` still hold one IPC invoke per run;
partial landing deferred; loop stalls get no inspection. New from the
laps: a survived mutation has no inspect-and-waive disposition (the
stale-position gap above); side A's boot-sequence observation
(src/main/index.ts has zero coverage) still lives only in a dissent —
stow the second self-review to file it.

## Environment notes

- Native Mac checkout: everything runs directly (`npm run dev`, `npm test`,
  `PARLEY_MOCK=1 npm run dev` for tokenless UI work).
- From an OrbStack VM (`/mnt/mac/...`): darwin-native `node_modules` — do not
  `npm install` from Linux; verify on the Mac.
- After touching any adapter: `PARLEY_LIVE=1 npx vitest run
  src/main/agents/live.test.ts` (spends a little quota).
- Worktrees live under `userData/worktrees/`; the registry reconciles at
  startup and never deletes directories.
