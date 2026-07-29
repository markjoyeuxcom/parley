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
1. **Packaging prep, next commit**: dev/packaged userData separation
   (dev takes `parley-dev` BEFORE the module-level databasePath
   computes; user copies the existing dir to keep dev history; titlebar
   dev chip on non-packaged builds). Naming recommendation: productName
   **Parley** plain, bundle id com.moomora.parley, "by Moomora" in
   prose only — final before the first .dmg, since it names userData.
2. **agy adapter series** (user directive): Antigravity CLI third
   vendor — `agy -p --output-format stream-json`, conversation_id
   resume, --effort low|medium|high, Google-account OAuth. v1 gemini-*
   models ONLY (agy also serves Claude/GPT-OSS — vendor≠family trap);
   `--dangerously-skip-permissions` joins the forbidden list.
3. **Dev containers** (promoted by the user's real workload —
   Terraform/K8s/EKS/ArgoCD/Go controllers): repo stays local, only
   execution enters the container via `devcontainer exec` argv; `up`
   only in write flows, never read-only reviews. Pairs with infra:
   render attachments for briefs (helm template/kustomize build safe
   tier), infra skill pack, kube-context/AWS-profile chips in Grid,
   verification presets recorded as learnings.
4. **Grid I** (lifecycle slot/process controls, maximize/swap,
   git+worktree identity headers with plan chips, Grid-LOCAL status —
   inferred states never enter the holds queue — and both bridges) then
   **Grid II** comforts. Comparison mode parked as a PIPELINE feature.
5. **Unattended runs**: envelope approval (bounds up front, per-
   milestone approvals minted from it), fail-park at existing holds,
   end at merge-ready always; foreman acceptance stays outside.
6. **App Builder arc** (four series: workspace creator + foundation,
   preview management, acceptance records + 'acceptance' ingestion
   source, then the guided shell); readiness stage = disposition
   ergonomics, never auto-disposition.
7. **SSH/remote execution arc** after App Builder (execution-target
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
