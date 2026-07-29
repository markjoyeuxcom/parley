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

The self-building arc is COMPLETE: review → backlog → foreman proposal →
accept → worktree plan → audit/gates/review → land → self-gate → relaunch
into the build Parley made of itself. What remains is usage (the by-hand
loops above) and, much later, the packaged-app updater (signing, asar,
migrations, rollback — a separate project; the .dmg channel stays
`npm run package:mac` + reinstall until then).

Other candidates:
- Delta re-reviews / recurring finding identity across review sessions:
  suggest-with-confirmation matching; a recurring accepted-risk reopens with
  history attached (the within-session semantic already does this).
- Smaller carried items: `approveAndRun`/`adoptExisting` still hold one IPC
  invoke for a 30-minute run (holds and the stop button soften it;
  fire-and-forget them like `answerPlan` eventually). Landing requires plan
  status `complete` — partial landing deliberately deferred. Loop stalls get
  no inspection (milestones only); loops already have a kill switch.

## Environment notes

- Native Mac checkout: everything runs directly (`npm run dev`, `npm test`,
  `PARLEY_MOCK=1 npm run dev` for tokenless UI work).
- From an OrbStack VM (`/mnt/mac/...`): darwin-native `node_modules` — do not
  `npm install` from Linux; verify on the Mac.
- After touching any adapter: `PARLEY_LIVE=1 npx vitest run
  src/main/agents/live.test.ts` (spends a little quota).
- Worktrees live under `userData/worktrees/`; the registry reconciles at
  startup and never deletes directories.
