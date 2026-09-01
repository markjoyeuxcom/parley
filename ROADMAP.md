# Parley roadmap

Parley is a native macOS workbench for visible, supervised cross-vendor AI CLI
collaboration. It coordinates existing subscription CLIs; it does not replace
their models, authentication, tools, permission prompts or terminal interfaces.

## Product boundary

A feature belongs in Parley when it coordinates different vendor panes or makes
that coordination visible, safe, portable or recoverable. Work one vendor can
perform alone stays with that vendor.

Non-negotiable properties:

- locally installed subscription CLIs only;
- real vendor TUIs and permission prompts;
- explicit pane targets and no implicit broadcast;
- visible, interruptible work;
- local-only coordination and durable records;
- one canonical shared protocol;
- honest state from owned or authoritative facts only;
- one native app and one embedded Ghostty terminal stack.

## Official direction: vendor-driven, Parley-coordinated

**Decision recorded 2 September 2026.** Parley will be the authenticated
cross-vendor runtime, handoff and event layer around real vendor CLIs. It will
not grow parallel research, planning, browser, memory, subagent or task systems
that compete with capabilities already owned by Claude Code, Codex, Agy or
Copilot.

The durable product primitive is the **handoff**. A handoff has an authenticated
source, one explicit target, correlation, lifecycle, result and optional human
review. Cross-vendor verification is another handoff linked to the item it
challenges; it is not a second evidence database. Workspace-level decisions
belong in the Workspace Brief, and multi-handoff review belongs in Status
Center.

Parley owns:

- retained Ghostty panes, process lifetime and exact pane identity;
- workspaces, roles, leads and reviewed folder/capability boundaries;
- authenticated Relay, Ask and Delegate delivery with durable receipts;
- handoff review, reply lineage, recovery and reviewed Context Pack promotion;
- normalized, authoritative vendor events where official hooks exist;
- local attention, lifecycle, discovery and Task Manager facts.

Vendor CLIs own their reasoning interfaces, plans, research and browser tools,
tasks, teams, subagents, memory, model-specific hooks and MCP/tool semantics.
Parley may adapt an official vendor hook into a small shared event vocabulary,
but it must not reinterpret terminal text or replace the vendor workflow.

### Committed sequence

#### Phase 1 — consolidate around handoffs

- [x] Freeze new first-class workflow windows and further Smart Auto expansion
  until the discovery and event layer is proven.
- [x] Retire the unreleased Research Board model, window, menu, help topic,
  Status Center actions, checks and `parley research` protocol namespace.
- [x] Confirm the experiment never entered a tracked release. Its v10 protocol
  bump existed only in the dirty development tree, so removal restores the
  released canonical v9 contract instead of manufacturing v11.
- [x] Require no production migration because no Research Board build shipped.
  Leave any local development `research-board.json` untouched rather than
  silently deleting a person's experimental data.
- [x] Retire the separate Handoff Chains model and Status Center surface after
  confirming the current Production and Development runtimes contain no chain
  data. Leave any legacy `handoff-chains.json` untouched and unloaded rather
  than silently deleting a person's data; reviewed handoff attributes and
  lineage remain explicit future work.
- [ ] Move durable investigation conclusions, rationale, confidence and open
  questions into the owning Workspace Brief.
- [ ] Preserve reviewed Context Pack promotion as a Status Center action over
  selected handoffs.

#### Phase 2 — authenticated discovery and events

- [ ] Add `parley whoami` for the caller's authenticated pane, workspace,
  vendor and role identity without revealing credentials.
- [ ] Add `parley panes` for bounded discovery of valid explicit targets and
  authoritative pane lifecycle facts.
- [ ] Add `parley events --since <cursor>` for local, ordered, resumable and
  bounded cross-vendor lifecycle/handoff events.
- [ ] Keep event payloads content-minimal, runtime-local and protected by the
  existing pane capability boundary.

#### Phase 3 — official vendor hook adapters

- [ ] Add `parley signal <event>` as the authenticated ingress used only by
  Parley-managed vendor hook adapters.
- [ ] Normalize official structured hooks, where available, to a deliberately
  small vocabulary: `session-started`, `turn-started`, `turn-ended`,
  `awaiting-permission`, `notification` and `session-ended`.
- [ ] Record the emitting pane and vendor as owned identity; never allow a hook
  payload to choose another sender.
- [ ] Report **Unknown** when a vendor lacks an authoritative hook. Do not fill
  gaps with prompt scraping, terminal heuristics or guessed completion.
- [ ] Verify each vendor's current official hook contract at implementation
  time and keep adapters independent of the canonical protocol wording.

#### Phase 4 — review primitives in Status Center

- [ ] Add **Challenge** and **Verify** actions that create one correlated
  handoff to one explicit pane and retain `inReplyTo` lineage.
- [ ] Add person-owned verdict and note fields to completed handoffs. Agents may
  propose evidence but cannot mark their own result reviewed.
- [ ] Support side-by-side and multi-select review without creating a separate
  evidence entity or hidden synthesis step.
- [ ] Promote selected reviewed results into an editable Context Pack with
  source pane, route, relationship and review state preserved.
- [ ] Keep source selection explicit and stop at human review before any new
  vendor submission.

#### Phase 5 — prove the runtime, then prune

- [ ] Add local-only product diagnostics for which coordination primitives are
  used, without collecting prompts, results, terminal content or telemetry.
- [ ] Measure delivery correctness, event loss/replay, recovery time and
  long-running pane stability before expanding automation.
- [ ] Remove unused duplicate surfaces after their durable data has migrated.
- [ ] Make runtime soak quality and exact teardown a release gate for this
  direction.

## Current baseline

### Native app and pane lifetime

- [x] SwiftUI workspace surface with retained Ghostty panes.
- [x] One real PTY/process and direct mouse selection, copy and scroll per pane.
- [x] Selected-pane border and pane identity visible in the native split tree.
- [x] More than four independent panes without shared-input or focus collapse.
- [x] Closing the main window keeps panes alive while the app remains running.
- [x] Reopening the window returns to the same retained surfaces.
- [x] Full quit and Stop Everything end exact pane processes and coordination.
- [x] Eight-pane real-Ghostty soak verifies input isolation, hidden-window
  continuity and exact PID teardown.
- [x] Remove the external terminal multiplexer, old renderer, conversion path
  and related CI/release dependencies.

### App-resident coordination

- [x] Relay broker, control socket, consultations and filesystem transport live
  inside the application process.
- [x] Remove the standalone core executable, background login item and upgrade
  handover machinery.
- [x] One-executable app packaging and runtime manifest.
- [x] Window close keeps coordination available; application quit ends it.
- [x] Status Center reports embedded terminal and app-resident core health.
- [x] Native Task Manager attributes live process trees to exact Ghostty panes,
  groups them by workspace and exposes only confirmed pane-level controls.

### Delivery correctness

- [x] Pane-scoped durable credentials establish the real sender.
- [x] Exact pane, explicit role and unique-vendor target resolution.
- [x] Refuse ambiguous, same-pane, shell, missing and busy targets.
- [x] Relay submits; Paste remains the explicit review-before-send route.
- [x] Ghostty paste carries one multiline payload and Enter is a separate event.
- [x] Ask/Answer correlation, tracked Delegate/Done/Fail, Status and Wait.
- [x] Copilot focus/trust handling without bypassing its approval flow.
- [x] Durable receipts and interruption reasons.

### Safety boundary

- [x] One canonical `AgentProtocol.text` and protocol version stamp.
- [x] Vendor-specific injection mechanics without divergent wording.
- [x] Seatbelt boundary around every vendor process tree.
- [x] Capability-named relay endpoints and exact endpoint/token authentication.
- [x] No raw control capability, credentials or broad private runtime exposed to
  an adjacent agent pane.
- [x] Fixed executable/argv process spawning and bounded payloads.
- [x] Shell panes remain explicit trusted human shells.

### Supervised collaboration

- [x] Human Ask and Return previews.
- [x] Activity lane and Status Center. The separate Handoff Chains experiment
  was later retired before the handoff-review event model so Parley does not
  maintain a parallel evidence store.
- [x] Explicit stop/cancel/retry/repeat actions.
- [x] Local handoff history with retention and reviewed export.
- [x] Supervised lead workflows and bounded fan-out.
- [x] Smart Plan → Review → Implement → Verify orchestration with persisted
  Supervised and Auto modes, automation-attributed transitions and a mandatory
  final human completion decision.
- [x] Research Board experiment validated exact handoff attribution,
  person-owned verdicts, reply lineage and reviewed multi-result Context Pack
  promotion. It is superseded as a standalone product surface; Phase 1 retains
  those useful primitives while removing the parallel evidence model.
- [x] Bounded independent evidence collection demonstrated explicit multi-pane
  sourcing without inferred synthesis. Future collection remains ordinary,
  attributable handoffs reviewed in Status Center.
- [x] Honest Unknown when no structured vendor state exists.

### Daily workspace

- [x] Stable workspace ids, zero-to-many folder attachments and optional New
  Pane Folders.
- [x] Favourite folders and bounded external opening.
- [x] Durable native split layouts without live ids.
- [x] Saved layouts and portable team templates.
- [x] Stable roles and explicit local/cross-workspace role addressing.
- [x] Pane move preserving the exact retained surface and configuration clone
  creating fresh identity.
- [x] Workspace briefs, pinned snippets and reviewed context packs.
- [x] Git context/diff capture and optional worktree awareness.
- [x] VS Code companion Phase 1 — fail-closed Production capability negotiation,
  correlated one-shot preview acknowledgements and privacy-safe diagnostics.
- [x] VS Code companion Phase 2 — one multi-select context composer for editor
  selections, files, diagnostics, Explorer resources and whole or path-scoped
  staged/working Git changes.
- [x] VS Code companion Phase 3 — native Collaboration views for content-free
  attention, durable workspaces and exact live-pane navigation without a chat
  surface or hidden vendor control.
- [x] VS Code companion Phase 4 — per-window, per-folder in-memory Context
  Baskets with exact-source replacement, bounded review and clear-on-accepted
  acknowledgement semantics. Captured text is never persisted by the extension.
- [x] VS Code companion Phase 5 — recovery actions, native welcome/onboarding
  surfaces, packaging assets and deterministic model/extension-host coverage.

### Shipping

- [x] Isolated Production and Development runtimes.
- [x] Quota-free environment and semantic vendor compatibility checks.
- [x] Deterministic native contracts, real-Ghostty lifecycle checks and soak.
- [x] One-executable app/ZIP/DMG packaging with signatures and licence notices.
- [x] Atomic install/upgrade verification and explicit safe data purge.
- [x] Complete-history public secret scan in CI.

## Next hardening work

### Workspace identity and folder attachments

- [x] Make a workspace a durable collaboration identity independent of any
  repository or directory; zero attached folders must be a valid normal state.
- [x] Replace the mandatory single home-folder association with explicit
  zero-to-many folder attachments. Preserve a separate optional New Pane
  Folder policy rather than treating either value as workspace identity.
- [x] Make **New Workspace** create a folderless collaboration container while
  retaining **Open Folder as Workspace** as the convenient folder-first path.
- [x] Keep every live pane's cwd authoritative and pane-local. Attaching,
  removing or reordering workspace folders must never change a running pane,
  start an agent or imply filesystem permission.
- [x] Give a folderless shell pane a safe launch-directory fallback without
  silently attaching that directory. Require an explicit working directory
  and permission scope before a vendor agent can start.
- [x] Route Finder, `parley open <folder>` and URL requests only through
  explicit attachments: focus one match, offer a choice for several, create a
  folder-backed workspace for none and never guess.
- [x] Support multi-repository collaboration directly, including clear
  attachment management, workspace search and honest **No folders attached**
  state across the sidebar, context tools and Status Center.
- [x] Migrate existing workspaces losslessly: the current home folder becomes
  an attachment and the current New Pane Folder remains the pane-launch
  default. Preserve workspace ids, panes, roles, layouts and handoff history.
- [x] Keep portable team templates path-free. Applying a team to a folderless
  workspace leaves agents stopped until their pane directories and permission
  roots are explicitly bound.
- [x] Add deterministic coverage for zero-, one- and multi-folder workspaces,
  folder removal with live panes, external routing ambiguity and migration of
  existing records.

### Ghostty integration

- [ ] Exercise rapid split/create/close/move cycles with 16 retained panes.
- [ ] Add long-duration resize, Unicode, IME and high-output soak profiles.
- [ ] Verify VoiceOver traversal and keyboard focus restoration across every
  native split mutation.
- [ ] Track upstream wrapper updates and keep the exact pin, lockfile, release
  notes and third-party notices aligned.

### Coordination recovery

- [ ] Add explicit UI recovery for a damaged app-resident control endpoint
  without touching healthy terminal surfaces.
- [ ] Add fault injection between delivery, receipt persistence and terminal
  teardown for every Ask and Delegate terminal state.
- [ ] Preserve clear "delivery occurred; do not resend" guidance on all
  post-delivery persistence failures.

### Cross-vendor workflow depth

- [ ] Improve side-by-side comparison review while retaining exact source pane
  attribution.
- [ ] Add clearer role/lead collision previews for workspace moves and template
  application.
- [ ] Expand context reliability checks for repository changes between preview
  and submission.
- [ ] Continue adding vendor adapters only when their official CLIs preserve
  real subscription, TUI and permission behavior.

### Release confidence

- [ ] Run the full Ghostty soak on each release candidate and retain the JSON
  report as a local release artifact.
- [ ] Add packaged-app UI automation for window close/reopen and confirmed quit
  once it can run deterministically on the macOS CI runner.
- [ ] Complete Developer ID signing and notarization without weakening local
  install verification.

## Explicit non-goals

- Direct model APIs, API-key storage or usage billing.
- A custom chat interface that hides vendor TUIs.
- Hidden background agents or hosted orchestration.
- Approval-bypass flags.
- Inferring internal model state from terminal text.
- A web renderer, embedded browser runtime, second terminal stack or external
  multiplexer.
- Automatic repository mutation outside an explicit visible vendor pane.
- A separate research/evidence database or first-class Research Board.
- Parley-owned replacements for vendor planning, browsing, task, team,
  subagent, memory, MCP or tool interfaces.
- Treating terminal text, raw keystroke control or an unauthenticated external
  socket as authoritative coordination state.

## Success measures

- A workspace can be created and retained with zero attached folders, can
  explicitly attach several repositories, and never conflates those
  associations with a live pane's cwd or permission authority.
- A person can run at least six mixed-vendor panes and type, select, copy and
  scroll in each without focus/input collapse.
- Closing and reopening the main window preserves every exact pane process.
- Full application quit leaves no pane or coordination process behind.
- Every cross-vendor message is attributable to an authenticated source and an
  explicit target.
- Every reviewed claim remains an attributable handoff with optional human
  verdict, note and reply lineage; workspace decisions have one durable home in
  the Workspace Brief.
- An authenticated pane can discover its own identity, valid targets and new
  authoritative events without gaining control of another pane.
- Unsupported vendor lifecycle state is visibly **Unknown**, never guessed from
  terminal output.
- Failed, interrupted and completed work remains distinguishable without
  reading or guessing from terminal text.
- Deterministic checks, native build, Ghostty soak, packaging checks and public
  repository scan all pass before release.
