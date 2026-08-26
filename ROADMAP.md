# Parley roadmap

**Direction:** the native macOS app is the product. Parley is the local
collaboration layer between the user's existing AI coding CLIs. It does not
replace their models, tools, permissions, authentication, or conversations.

This roadmap is the product backlog. Its north star is the workflow already
working in the native app:

> Give one agent a task. It consults a different vendor, waits for the answer,
> judges that answer, and hands approved work to the right agent. The person can
> see every participant, intervene at any point, and never copy and paste.

## Product boundary

Parley should win on one promise:

> **The easiest native environment for visible, supervised, cross-vendor
> collaboration between the CLI subscriptions you already use.**

Every proposed feature must pass these tests:

1. Does it make working across vendors easier or safer?
2. Does it preserve the real interactive CLI, including its permission prompts?
3. Is the collaboration visible and interruptible by the person using it?
4. Can it remain entirely local and work without API keys?

If one vendor CLI can do it better on its own, Parley should not duplicate it.

## Current baseline

The native application already has the product's essential wedge:

- A SwiftUI and SwiftTerm macOS surface over an isolated persistent tmux server.
- Real Claude Code, Codex, Agy, GitHub Copilot CLI, and shell panes.
- Panes that survive closing and reopening the window.
- A persistent per-user coordination core that survives the SwiftUI process,
  with authenticated UI reattachment and process-safe pane credentials.
- An owner-only, crash-repairing local journal retaining the latest 500
  handoffs, including transitions, vendor/workspace identities and Ask answers.
- A versioned cross-vendor protocol injected into every newly started agent.
- `relay` for an attributed asynchronous handoff, `paste` for an unsent draft,
  and correlated `ask` / `answer` for a blocking consultation.
- Protocol v6 tracked delegation through `delegate`, `done`, `fail`, `status`
  and `wait`, with exact source/target credential ownership.
- Human Ask and Return editors with explicit control over the exact text sent.
- Automatic submission that works across the supported agent TUIs.
- Folder-backed workspace tabs, each represented by a tmux window.
- Workspace-scoped pane lists, recent folders, and cross-workspace addressing.
- Deterministic native checks covering spawning, routing, submission, security
  boundaries, consultations, and workspace lifecycle.

This is a working development build, not yet a dependable distributable app.
The milestones below are ordered by what turns it into a daily tool.

## Milestone 1 — Trust the pipe

The first priority is making the working Ask/Answer loop survive ordinary app
lifecycle events and fail clearly when it cannot continue.

### Persistent local coordination core

Relay ownership now lives outside the window process in the
`parley-core-service` background executable. The tmux server, active Ask wait,
relay socket and broker state survive UI close and reopen together.

- [x] One per-user Parley core, reachable only through a Unix-domain socket.
- [x] The SwiftUI app is an authenticated client that may attach and detach.
- [x] Agent credentials remain scoped to their exact tmux pane and refresh
  safely across processes.
- [x] Closing the window does not interrupt an agent waiting on `parley ask`;
  the deterministic harness exits the launching UI process and completes the
  wait through a new client.
- [x] A core restart terminates affected waits with an explicit interruption
  error; it neither leaves the caller hanging nor pretends an answer arrived.
- [x] Connection discovery is atomic and self-healing. The lifecycle harness
  stops the service, verifies the old endpoint is unhealthy, starts it through
  a fresh UI process and rejects the impossible stale consultation.

### Delivery correctness

Safe relay hardening already applied without changing the normal workflow:

- [x] Refuse relay, paste, Ask and Return unless the target pane is relay-
  enabled, protocol-current and actively requesting bracketed paste.
- [x] Accept only Parley's fixed local Unix relay socket; reject remote
  locators, symlinked discovery files and other Unix socket paths.
- [x] Rotate a pane's relay credential on every deliberate agent restart and
  scrub inherited pane credentials when Parley is launched from another pane.
- [x] Keep lifecycle diagnostics owner-only and drain blocked Ask connections
  during a clean core shutdown.
- [x] Establish a real same-user process boundary around the tmux control
  socket and UI control capability. Every vendor pane and all descendants now
  run inside a mandatory macOS Seatbelt profile that denies Parley's private
  Application Support tree and exact tmux socket while leaving repositories,
  vendor authentication, normal tools and network access unchanged. The
  filesystem relay is split into capability-named pane endpoints; a profile
  reopens only its own endpoint and the core rejects a token presented through
  any sibling path. Shell panes remain deliberately unsandboxed human shells,
  and are therefore an explicit trusted boundary rather than an agent surface.
  The native gate proves ordinary repository access and the pane's relay still
  work while UI-token reads, sibling endpoint reads and direct tmux control all
  fail with the operating system's `Operation not permitted` result.

- [x] Give every handoff a stable core-local identifier and a sender-scoped
  idempotency key. The managed command generates the key automatically;
  concurrent and later retries reuse the original result without submitting
  twice.
- [x] Record an observable transition trail through `created`, `delivered`,
  `waiting`, `answered`, `completed`, `cancelled`, `failed`, and `interrupted`. Completed
  history is durably bounded to the latest 500 handoffs in an owner-only local
  journal.
- [x] Add explicit human cancellation and record its terminal state as
  `cancelled`.
- [x] A successful command means the target received the text and the intended
  submit action occurred; intermediate success must not be reported as final.
- [x] Complete the in-memory recovery matrix. Timeout, clean shutdown, broker
  restart, human cancellation, source/target closure and source/target restart
  all release the waiting caller with an explicit terminal reason. Durable
  recovery across a machine restart arrives with Milestone 2 history.
- [x] Keep one active blocking consultation per target until reliable busy/ready
  state exists. Refuse extra work rather than silently queueing it.

### Vendor conformance harness

The deterministic suite covers planning, fail-closed readiness and honest
reporting. `npm run test:conformance:plan` discovers safe routes without model
calls; `PARLEY_LIVE=1 npm run test:conformance` is the explicit quota-spending
run against existing panes. It proves:

- [x] protocol injection is present;
- [x] multiline bracketed paste is intact;
- [x] submit starts a turn without a person pressing Enter;
- [x] `parley answer current` returns to the correct waiting pane;
- [x] inactive panes and cross-workspace targets behave correctly;
- [x] trust and permission prompts fail closed.

**Exit gate:** close the UI during an active consultation, reopen it, and watch
the same two pane processes complete the exchange without manual recovery.

## Milestone 2 — See the collaboration

Parley currently performs handoffs correctly but shows too little of what is in
flight. Add an activity surface, not a project-management system.

### Collaboration activity

- [x] A compact workspace activity strip showing `Agy → Codex: waiting`, elapsed
  time, and the latest state.
- [x] Pane and workspace badges for waiting questions, failures, and explicit
  permission-required attention.
- [x] Add durable returned-answer badges from explicit Ask/Delegate results,
  cleared only when the result is viewed. Terminal redraws remain irrelevant.
- [x] Click an activity's source or target to focus that pane, including across
  workspace tabs.
- [x] Human actions to cancel a wait or complete a return manually when an
  agent printed instead of returning its answer.
- [x] Retry a provably pre-input failed delivery from activity without creating
  a duplicate. Uncertain and failed-Ask retries remain unavailable by design.
- [x] Native notifications when an answer returns or a pane needs human input,
  with opt-in per-workspace controls and no prompt/result text in the alert.

### Status Center window

Add a separate native window that can remain open beside the terminal
workbench or on another display. The main window keeps compact badges; Status
Center provides the detailed operational view.

- [x] An overall banner for the most important current condition: all clear,
  agents waiting, human input required, interrupted work, or core unavailable.
- [x] Workspace and all-workspaces filters, with counts for running and stopped
  agents, outstanding questions, tracked delegations, unread results and
  failures.
- [x] Durable read receipts and unread-result counts, attributed to the
  requesting pane and workspace rather than inferred from terminal output.
- [x] A **Live collaboration** section showing source → target, operation type,
  concise subject, elapsed time, and exact state for every active handoff.
- [x] An **Agents** section showing pane name, vendor, workspace, process health,
  exact injected protocol version and compatibility, relay availability, known
  attention state, and the work item currently associated with that pane.
- [x] A selected-item inspector containing the complete question or instruction,
  returned answer or completion report, timestamps, and delivery receipts.
- [x] Contextual controls for Focus Source, Focus Target, Cancel Wait, Retry
  Delivery, Return Manually, and Restart for Protocol.
- [x] Add a local Dismiss Completed control without deleting the durable record.
  Dismissals persist as a UI preference, can be shown or restored, and cannot
  conceal active work, failures, or unread results.
- [x] A chronological **Activity** timeline for recorded Ask, answer, relay,
  delegation, failure and interruption transitions.
- [x] Extend the timeline with restart, workspace and human-intervention events
  once those operations have authoritative journal records.
  - [x] Manual Return, Cancel Wait and safe Retry transitions carry a durable
    human origin and render a HUMAN marker in both Activity and receipts.
  - [x] Pane restart, workspace creation/closure and saved-layout restoration
    are written only after the native action succeeds, persisted separately
    from handoffs in an owner-only bounded journal, and merged into Activity
    with a HUMAN marker. None is inferred from tmux state after the fact.
- [x] A small **Core health** section for the local broker, tmux server, socket,
  protocol version and scoped handoff count. Add CLI discovery during first-run
  work; low-level technical details remain behind a disclosure.

Status Center must not imitate certainty it does not have. Context-window use,
token cost, quota, compaction distance, or plan limits appear only when the
vendor exposes authoritative structured values. Parley may show its own process
memory and handoff counts in diagnostics, but it must not derive impressive-
looking model gauges from terminal text or estimates.

The visual treatment should borrow the useful hierarchy from operational
dashboards—strong status banner, quiet grouped cards, compact progress states,
and an event timeline—while keeping Parley's native macOS restraint and avoiding
a permanent application-style navigation sidebar.

### Honest state only

Do not infer “thinking”, “idle”, or “blocked” from a quiet screen. Prefer
explicit protocol events and official vendor hooks. Where Parley knows only
that a process is alive, the UI must say exactly that.

### Local handoff history

Persist a small append-only record of cross-vendor events:

- [x] source and target pane identities and vendors;
- [x] workspace names;
- [x] question, answer, or delegated instruction;
- [x] timestamps, outcome, and interruption reason;
- [x] deletion per workspace from the native Status Center. It requires a
  workspace-specific destructive confirmation, removes terminal records from
  the in-memory projections and both owner-only journals, preserves every
  active handoff, and never offers an all-workspaces shortcut.

This is collaboration history, not automatic terminal transcription. It stays
local, can be deleted per workspace, and never captures unrelated pane output.

**Exit gate:** a person can explain who is doing what, who is waiting for whom,
and what failed without reading every terminal pane.

## Milestone 3 — Supervised multi-vendor work

Extend the proven one-to-one consultation into a small set of composable
coordination primitives. The lead agent remains responsible for reasoning and
decisions; Parley transports work and reports state.

### Protocol v4

- [x] `parley ask <target>` — retain the current blocking one-to-one consultation.
- [x] `parley ask-many <target-a,target-b>` — ask several explicit vendors independently
  and return a labelled bundle only after all finish or time out. Respondents
  do not see one another's answers. Routing for the whole comma-separated list
  is validated before dispatch; stdout is ordered JSON, and a partial failure
  remains visible beside successful answers while making the command non-zero.
- [x] `parley delegate <target>` — tracked asynchronous work with a required
  `parley done` or `parley fail` result.
- [x] `parley status` — machine-readable state for work initiated by the caller.
- [x] `parley wait` — wait for one delegated item without scraping terminal output.
- [x] `parley cancel` — cancel the tracking relationship and, only with explicit
  human authority, offer to interrupt the target CLI.

### Lead-agent experience

- [x] Allow a pane to be marked as the workspace lead for display and routing
  convenience, never as a source of extra filesystem authority.
- [x] Natural-language instructions such as “review the plan with Codex, adopt good
  additions, then delegate implementation” should work using the shared
  protocol without a vendor-specific skill maintained by the user.
- [x] Provide a few editable handoff recipes: plan review, implementation review,
  adversarial bug hunt, and compare recommendations.
- [x] Show every automatically submitted prompt in activity history with sender
  attribution and an immediate Stop control.

### Safety boundary

- [x] Automatic delivery targets agent panes only, never shells.
- [x] Each workspace exposes a visible automation policy: off, Ask/Answer only, or
  Ask plus tracked delegation.
- [x] No agent receives raw tmux control, pane credentials belonging to another
  agent, or permission to create and destroy workspaces.
- [x] Message size limits, sender attribution, exact target resolution, and
  cross-vendor enforcement remain mandatory.
- [x] Fan-out always names its recipients; there is no implicit broadcast to every
  pane.

**Exit gate:** one instruction to a lead agent can produce the demonstrated
review → evaluate → implement sequence across vendors, while the UI shows the
whole chain and the person performs no copy, paste, or Enter presses.

The deterministic native gate now exercises that complete chain, including a
correlated review answer, an adopted tracked delegation, its returned completion
report, policy refusal, exact `lead` routing and source-owned cancellation.

## Milestone 4 — Workspace as the daily driver

Workspaces should preserve context and make returning to several projects
effortless without becoming task boards.

### Durable workspace restoration

- [x] Persist workspace names, folders, pane kinds, pane names, layout, and ratios
  outside tmux so they survive a Mac restart.
- [x] Restore shells automatically; restore agent panes as stopped placeholders
  requiring an explicit Start, so reopening Parley never spends subscription
  quota unexpectedly.
- [x] Preserve recent and favourite folders, expose favourites in the sidebar,
  and retain user-controlled tab ordering and the last selected workspace. The
  order and selection use name/folder stamps, never persisted tmux ids; native
  rename and folder changes retain their tab position.
- [x] Make duplicate workspace names impossible or visibly qualify them.

### Project context

- [x] Show branch, dirty state, and pane folder using one shell-free, lock-free
  Git status command per distinct visible folder. Resolution runs off the main
  thread on a five-second cadence with a two-second process ceiling.
- [x] Add “Ask another vendor to review these changes” using an explicit diff
  preview and the normal attributed Ask path.
- [x] Add “Review this plan/file with…” without copying its contents manually.
- [x] Allow an occasional pane folder override from each pane-creation menu
  while retaining the workspace default for ordinary new panes.
- [x] Add a native ⌘K command palette for workspace and cross-workspace pane
  focus, editable Ask targets, recent activity lookup, workspace opening and
  Status Center access. Search is tokenized, deterministically ranked and
  bounded.

### Native interaction polish

- [x] Reorder workspace tabs with bounded Move Left/Right controls. Pane
  reordering remains future polish.
- Complete keyboard navigation and VoiceOver labels.
  - [x] Add deterministic wrapping shortcuts for previous/next workspace and
    pane focus, with native Navigate menu equivalents.
  - [x] Give the primary workspace tabs and pane selectors explicit action,
    state and folder accessibility metadata.
  - [x] Audit the remaining toolbar, activity, Status Center and command
    palette controls with VoiceOver. Icon menus now expose their action and
    state, dense rows speak one authoritative summary, headings remain
    navigable, command results announce selection, and prompt-derived subjects
    are bounded so VoiceOver never reads an entire handoff body as a label.
  - [x] Add a searchable native Help window for workspaces, handoffs, supervised
    recipes, automation policy, permissions, shortcuts and troubleshooting.
- [x] Improve narrow-window behaviour and long-name truncation. The main
  workbench now reaches a 720-point native minimum, swaps its full toolbar for
  a compact New/Ask/Actions surface without dropping capabilities, adapts the
  activity strip, and middle-truncates workspace, pane and context names while
  retaining their full help and accessibility text.
- [x] Provide clear empty, exited, disconnected, and protocol-stale states.
  tmux retains dead panes and their numeric status so final output survives;
  stopped placeholders, exited processes, stale protocol and missing relay have
  distinct precedence and recovery actions. A relay-core failure is now
  non-blocking when tmux is healthy, while actual tmux loss replaces the
  terminal with an explicit reconnect state.
- [x] Remove redundant tmux chrome once the native controls cover it reliably.
  The embedded tmux status row and pane-title bars are explicitly disabled on
  both new and existing sessions; native tabs, context and activity own that
  information, while restrained inactive/active pane borders remain for spatial
  focus.

### Cross-vendor CLI permission profiles

- [x] Put a task-focused permission guide in native Help. It explains how to
  judge the command, path, purpose and duration; covers ordinary project reads,
  the Agy `cat` case, secrets, repository execution, network and destructive
  actions; and never reduces the decision to an executable name.
- [x] Define one vendor-neutral, local-only permission profile schema based on
  capabilities and approved roots rather than command-name allowlists. A
  profile contains no credentials and grants no Parley relay capability.
  `PermissionProfiles.swift` now defines complete capability decisions, exact
  canonical root resolution, session versus remembered lifetime, immutable
  built-in definitions and an owner-only local custom-profile store. Hard
  boundaries are carried separately from editable definitions so a custom
  profile cannot remove them.
- [x] Ship immutable built-ins with clear guidance:
  - **Review only** — project reads and Git inspection, no project mutation;
  - **Default** — routine project reads, with writes and execution still
    requiring the vendor's appropriate decision;
  - **Flexible** — project-local reads, writes, tests and builds, while network,
    external folders and consequential operations remain explicit;
  - **Broad workspace (near-full)** — broad work inside exact approved roots,
    visibly session-scoped by default and never equivalent to host-wide access.
- [x] Keep non-negotiable denials outside every profile: Parley's private tmux
  socket and pane credentials, credential/keychain directories, permission-
  bypass flags, `sudo`, destructive host operations and silent external
  mutation. Git push, deployment and infrastructure mutation always remain an
  explicit decision.
- [x] Add a profile picker when creating or restarting an agent pane, plus a
  persistent pane badge, exact approved-root preview and clone-to-custom flow.
  Built-ins remain immutable and Broad Workspace never becomes sticky silently.
  New agent panes, stopped saved-layout agents and restarts all pass through the
  same picker. Selections and honest enforcement state live in tmux metadata,
  survive saved-layout capture and restoration, and remain visible in the pane
  list. Custom clones expose capability, root-scope and lifetime editing while
  preserving the non-editable boundary.
- [x] Translate each profile only through permission mechanisms the installed
  Claude, Codex, Agy or Copilot CLI actually supports. Show the resolved state
  as **Enforced**, **Partially enforced** or **Guidance only**; instructions to
  the model are never presented as a security boundary. The launch adapter uses
  only each vendor's supported safe modes, sandbox/approval controls and exact
  directory flags; no bypass or blanket-approval mode is ever generated.
- [x] Preserve Parley's mandatory macOS process boundary underneath vendor
  settings. The boundary is constructed independently of the selected profile,
  and real Seatbelt checks prove agents cannot read sibling pane credentials or
  Parley's control files or operate its tmux socket. Adapter checks prove exact
  root flags contain every approved root and no unapproved root. Filesystem
  scope beyond that remains honestly vendor-specific—**Partially enforced** or
  **Guidance only**—because claiming host-wide isolation would break vendor
  authentication and be false.
- [x] Detect recognisable vendor permission/trust stops after delivery and link
  the Activity and Status Center explanation directly to the relevant Help
  topic without approving or dismissing the prompt. While an Ask or Delegate is
  waiting, the persistent core observes only the target's current visible
  screen. Conservative prompt-and-decision matching records one durable
  permission-required transition; ordinary prose and `Permission denied` output
  do not match, and Parley never types, approves, retries or releases the waiter.

**Exit gate:** a person can choose the same named intent for every vendor, see
the exact effective scope before launch, avoid repeated ordinary source-read
prompts where the vendor supports it, and never mistake guidance for enforced
isolation.

Read-only Git worktree discovery and shared-writer awareness are complete in
Milestone 7. Worktrees are not required for cross-vendor consultation and are
never forced per agent; optional creation remains contingent on real usage.

**Exit gate:** after a Mac restart, a person can restore a project's layout,
choose which agents to resume, and continue work without reconstructing the
team or its folder routing.

## Milestone 5 — Ship a dependable macOS beta

### Installed and development runtime isolation

The installed application and a source-tree build previously used separate
executables while converging on one Application Support directory, tmux socket,
coordination core, relay command and durable record. This section now records
the isolation contract which replaced that unsafe development arrangement.

- [x] Introduce an explicit runtime namespace resolved before any local file,
  tmux or core access. The installed application always uses **Production**;
  ordinary `npm run dev` always uses **Development** and cannot silently fall
  back to Production.
- [x] Give Development its own Application Support directory, tmux socket and
  session, core discovery/control files, relay credentials and transport,
  protocol files, shim, layouts, recipes, activity/history and preferences.
  Building or launching Development must never rewrite Production's managed
  `parley` command or launch-at-login registration.
- [x] Keep the environments unmistakable: every Development window, pane,
  Status Center, diagnostic export and managed command displays a permanent
  **DEV** marker; Production never reads a Development record accidentally.
- [x] Add a per-runtime UI lease. A second UI for the same runtime focuses the
  existing window or refuses with a useful explanation instead of attaching as
  another controller. Core uniqueness remains separate and continues to defer
  version handover while Ask/Delegate work is active.
- [x] Provide an explicit developer-only `npm run dev:attach-production` path
  for integration work against real panes. It previews the exact production
  runtime, refuses while the installed UI holds its lease, never starts a
  second tmux/core, and leaves a visible **DEV ATTACHED TO PRODUCTION** warning
  for the entire session.
- [x] Make conformance and every tool that targets a live runtime require an
  explicit runtime target. Deterministic tests continue to use fresh temporary namespaces; no
  normal test or build command may touch either live runtime.
- [x] Add lifecycle tests that run Production and Development namespaces
  together and prove distinct pane process ids, sockets, cores, shims and durable files;
  then exercise the explicit attach path and prove only one UI can mutate the
  production runtime at a time.
- [x] Document the supported daily workflow: use installed Parley while editing,
  testing and building; use isolated Development for ordinary UI work; use the
  explicit attach path only when a production-pane integration test is truly
  required.

**Exit gate:** an installed Parley can remain open as the daily driver while a
development build runs beside it, with no shared runtime files, processes,
selection state or protocol installation; attaching Development to Production
is deliberate, visible and single-controller.

- [x] Produce a proper app bundle containing the Swift executable, terminal
  dependency, local coordination core, relay shim, and tmux integration.
  `npm run package:mac` now builds an Apple Silicon release, places the UI and
  persistent core together in `Contents/MacOS`, links SwiftTerm into the UI,
  carries the runtime component contract and icon, and emits both a ZIP and a
  drag-to-Applications DMG. The relay shim remains generated owner-only from
  the bundled implementation at launch; tmux remains an explicitly detected
  external dependency using Parley's private socket, not an embedded copy.
- [ ] Sign, harden, notarize, package, install, upgrade, and uninstall cleanly.
  The no-paid-account portion is complete: local packages use hardened runtime,
  sign the nested core before the outer app, and pass strict code-signature,
  ZIP and disk-image verification. A clean-tree release gate emits the full Git
  commit, deterministic artifact metadata, SHA-256 checksums and an install
  guide. Its isolated short-path lifecycle mounts the DMG, installs and replaces
  the bundle atomically, starts the packaged core on a private tmux socket,
  preserves local records during uninstall and requires an exact confirmation
  before purging them. A manual GitHub workflow can create only an unpublished,
  explicitly unnotarized draft from an existing matching tag. The persistent
  core now exposes a versioned identity and an atomic idle-drain endpoint: the
  UI replaces mismatched cores automatically, defers while Ask/Delegate work is
  active, preserves queued filesystem exchanges, and never restarts tmux or a
  vendor pane. An in-app Prepare to Uninstall transaction now refuses active
  work, disables the login item with rollback, atomically stops the core and
  quits without requiring a reboot or deleting tmux/local records. Developer ID,
  notarization/stapling and the physical clean-Mac gate remain required before
  this item is complete.
- [x] Offer optional launch-at-login for the local core, independently of
  opening the window. The packaged app contains a relocatable user LaunchAgent
  registered through `SMAppService`; it is off by default and invokes only
  `parley-core-service --login-agent`. Login mode opens the authenticated core
  transports without creating tmux, a workspace, the window or any vendor
  process, and exits cleanly instead of duplicating an already healthy core.
  Tools and Status Center expose registration and macOS approval state.
  Disabling fails closed while an Ask or tracked delegation is active, waits
  for Service Management to stop a login-owned core, then reconnects a
  foreground-owned core so the open app remains usable.
- [x] Add first-run detection for tmux and supported CLIs, plus authentication
  and protocol health checks that do not spend model quota. The native
  readiness sheet checks tmux, the persistent core, managed relay and shared
  protocol, then uses only vendor-owned status commands for Claude, Codex and
  Agy. Copilot is reported as installed but explicitly unchecked because its
  CLI exposes no read-only authentication status command; Parley never invents
  a result or opens an interactive login flow. The check returns from the Tools
  menu without restarting panes.
- [x] Provide a local diagnostics export with secrets and prompt bodies excluded
  by default. Tools and Status Center now save an owner-only ZIP containing a
  versioned JSON report and privacy README. It includes typed local readiness,
  pane/process health, bounded RSS figures, up to 50 recent failures and the
  last 20 state transitions per failure while structurally excluding prompts,
  answers, terminal content,
  names, folders, commands, transition details, credentials, raw journals and
  raw logs. A deterministic leak test plants unique secrets in every excluded
  source and checks both the report and extracted archive.
- [x] Run long terminal-output, repeated workspace switching, UI reattachment,
  and multi-agent soak tests. `npm run test:soak` is a quota-free isolated gate
  using the exact production SwiftTerm/Metal configuration: seven controlled
  output panes across four temporary workspaces, repeated switching, terminal
  teardown/reattachment with unchanged child process ids, and continuous
  authenticated four-vendor fixture relays through the real bounded broker and
  journal. The robust verdict ignores warm-up and compares early/late
  steady-state medians, failing growth above the larger of 16 MB or 10%.
  A corrected two-minute dual-process gate completed 510 switches and 10,790
  handoffs, retained exactly 500 broker and journal records, and held the app,
  renderer and broker process to +0.16 MB (130.25 MB to 130.42 MB median;
  130.45 MB peak). Every output fixture wrote beyond tmux's 10,000-line history
  cap; the independently sampled tmux server held to +0.05 MB (53.33 MB to
  53.38 MB median and peak). No model CLI is started. The harness drains an
  autorelease pool per event, matching a real `NSApplication` loop; without
  that, Foundation process/pipe objects made the test harness—not Parley—appear
  to grow.
- [x] Document recovery from a damaged socket, missing CLI, stale protocol,
  dead pane, and interrupted consultation in the UI itself. Status Center now
  projects active recovery cases from authoritative core, readiness, pane and
  handoff state, scoped to the selected workspace. Each case offers only its
  safe action: reconnect the existing UI, rerun the quota-free environment
  check, confirm a single-pane restart, or inspect the durable handoff receipt.
  A permanent five-case playbook explains symptoms and recovery without asking
  somebody to delete sockets, start a second app instance or use repository
  commands.

**Exit gate:** install Parley on a clean Apple Silicon Mac, connect existing CLI
subscriptions, complete a supervised cross-vendor workflow, restart the app and
Mac, and repeat without using the repository or a development command.

## Milestone 6 — Add vendors without diluting the product

Once the core is reliable and shipped:

- Extract a small adapter contract for launch arguments, protocol injection,
  submit behaviour, trust detection, and optional official status hooks.
- Evaluate CAP and other CLI-agent protocols as adapter inputs, not as reasons
  to replace the real terminal sessions.
- Add another CLI only when it supports local authenticated use and passes the
  full conformance harness.
- Prefer vendors that add genuine model diversity. Supporting many wrappers
  around the same provider is not the goal.

## Milestone 7 — Deepen the cross-vendor daily workflow

These are post-beta candidates, not conditions for producing the first tagged
DMG. Beta use should determine their order within the milestone. They remain
subject to the product boundary: visible, supervised, local collaboration
between real vendor CLIs rather than a new autonomous orchestration engine.

### Better questions, comparisons and context

- [x] Add a native **Ask-many comparison view** that presents independent
  answers side by side without manufacturing consensus. Preserve dissent and
  let the person forward one answer, several attributed answers, or an edited
  synthesis to the workspace lead through the normal previewed handoff path.
  The Ask menu now opens an explicit multi-pane picker and one exact editable
  question preview, then routes the concurrent requests through the durable
  Ask broker. The authenticated native route never exposes a pane credential,
  bypasses agent automation policy only because the click is a human control,
  refuses fewer than two target vendors before dispatch, and records exact
  child handoff ids. Returned answers and failures remain separate attributed
  cards; forwarding one or several and drafting a synthesis both use a second
  human preview before submission to the source workspace's ready lead. The
  synthesis starts blank, no conclusion is generated, and cancelling
  outstanding waits does not interrupt a vendor CLI process.
- [x] Add explicit, editable **context packs** assembled from selected files,
  a Git diff, visible terminal output and captured command results. Show the
  source and exact byte size of every part before sending; never scrape hidden
  scrollback or include a whole transcript implicitly.
  Context is now a native toolbar workflow anchored to one ready source agent.
  Every selected UTF-8 file, read-only Git snapshot, explicitly chosen visible
  pane screen and direct argv command result remains a separate editable part
  with immutable provenance, captured/current byte counts and an edit marker.
  Git names but never reads untracked files; terminal capture never requests
  history; commands require an absolute executable, accept one literal argument
  per line, run without a shell in the source folder, retain status plus both
  output streams, and have hard time/output bounds. The live rendered total
  includes the person's required receiving instruction and all attribution.
  Oversized edits remain visible and unsendable rather than being clipped.
  The reviewed pack can go through attributed one-vendor Ask or the independent
  multi-vendor comparison view. Packs deliberately remain ephemeral here;
  durable reference material enters only as an explicit snapshot.
- [x] Let pane agents stage explicit context without silently collecting or
  dispatching it. `parley context draft/add/list/show` is pane-authenticated,
  owner-scoped and confines agent-staged files to that pane's working folder;
  every part says the content was agent-provided and not independently read by
  Parley. `parley ask <vendor> --context <draft>` enters a durable native review
  checkpoint and blocks: the Context menu exposes the complete editable pack,
  provenance, requested target and waiting source. Only a person's explicit
  Approve and Ask action starts the correlated consultation; Decline and timeout
  submit nothing and release the pane with an explicit failure. Person-created
  context drafts remain ephemeral, while pending agent review records survive UI
  reattachment and are marked interrupted rather than revived after a core
  restart.
- [x] Add bounded, predefined **workflow sequences** such as plan → independent
  review → human checkpoint → implementation → verification. Every transition
  remains visible and interruptible, consequential steps retain their explicit
  authorization, and the feature never becomes a generic DAG designer or
  autonomous project manager.
  The first fixed sequence now lives under Recipes. A person chooses a ready
  cross-vendor reviewer and verifier, reviews the planning instruction, then
  advances through six explicit phases. Plans, independent objections, current
  Git evidence and verification results each pass through an editable capture;
  implementation and completion have separate human approval gates. An
  owner-only durable state machine rejects skipped phases, preserves exact
  captured artifacts and every human-origin transition across UI reattachment,
  and can be ended without pretending to cancel agent work already in flight.
  This is one bounded product workflow, not a programmable graph or autonomous
  scheduler.
- [x] Group related Ask, review, delegation and verification records into
  readable **handoff chains**. Allow important answers, objections and human
  decisions to be bookmarked without creating a task board or smoothing away
  disagreement. Status Center now creates or extends explicit workspace-scoped
  chains from selected broker records. Each entry is an exact durable snapshot;
  returned results can be bookmarked verbatim as answers or objections, while
  person-written decisions carry an explicit HUMAN origin. Curated records stay
  readable after the bounded broker journal prunes its source, and no chain
  action contacts an agent, infers consensus or changes handoff state.
- [x] Add a local, editable **workspace brief** containing the current goal,
  constraints and important decisions. It is never injected automatically; a
  person or an explicitly approved recipe chooses when to attach it.
  Context now creates and edits one owner-only durable brief per live tmux
  workspace. The sheet separates the current goal, constraints and important
  decisions, enforces a bounded text size and states permanently that saving
  contacts no agent. A person can start a new pack with the brief or add it to
  an existing editable pack; the attributed attachment is an independent
  snapshot, so pack edits never mutate the saved reference. Agent-proposed
  context drafts cannot read or attach a person's brief, and deleting one
  neither contacts a pane nor rewrites an already captured snapshot.
- [x] Add local **pinned context snippets** for reusable architecture notes,
  test instructions and review criteria. Insertion always opens the existing
  editable preview and snippets never contain credentials managed by a vendor.
  Context now manages a bounded, owner-only application-wide library with
  case-insensitive unique names and exact multiline content. A person-created
  pack can open a multi-select picker and add each chosen entry as a separately
  attributed editable snapshot with stable source identity, preventing an
  accidental duplicate. Library edits never rewrite a captured pack and pack
  edits never rewrite the reusable source. Agent-proposed drafts cannot read or
  attach the person's library, nothing is injected automatically, and the UI
  states that snippets are reference material rather than credential storage.

### Context reliability gate

Context packs, workspace briefs and pinned snippets stay in the product: they
are useful safety boundaries for supervised cross-vendor work. Do not add
another context source type until this gate is complete and beta use shows that
the existing sources justify their complexity. Agent-provided file paths and
content remain explicitly labelled as claims; only content captured through a
separate person-authorized local action may be described as independently
verified by Parley.

- [x] Make every context-review mutation transactional. Concurrent `context
  add` operations must retain both accepted parts, while `add` racing approval,
  decline, timeout or `ask --context` must have one deterministic winner and
  must never roll a review back to an earlier state. Add deterministic tests for
  add/add and add/Ask races before changing the broker.
  The broker now holds one mutation lock across validation, durable recording
  and publication. Deterministic simultaneous-start checks cover add/add and
  add/Ask without accepting a lost part or rolling a review back to draft.
  Approval and direct completion also carry the exact review revision shown in
  the preview, so a later accepted add makes that preview explicitly stale
  instead of letting both operations succeed while one source disappears.
- [x] Complete the draft lifecycle. Add an authenticated owner-scoped CLI and
  native action to discard a draft, clean up abandoned drafts without weakening
  the existing 32-pending-review safety bound, and make simultaneous pending
  reviews selectable rather than relying on one application-wide UI draft.
  Protocol v6 adds owner-authenticated `parley context discard`; the native
  review uses a distinct Discard Draft action, seven-day abandoned editable
  drafts become durable discarded records, and every pending review is
  individually selectable from the Context menu.
- [x] Make completion and validation failures explicit and recoverable. Never
  silently ignore a failed durable completion after terminal delivery; cover
  missing and binary files, near-limit JSON escaping, oversized approval
  payloads and failed draft completion with end-to-end transport tests.
  Direct completion is now owned by the core: it records approval before input,
  records delivery failure as terminal failed state, and reports the rare
  delivered-but-not-persisted case without inviting a resend. End-to-end checks
  cover missing and binary inputs, escape-heavy 80+ KB packs, explicit 413
  rejection before an oversized control request reaches the socket, and failed
  direct completion.
- [x] Let a person add missing trusted local sources to an agent-proposed pack
  through the existing bounded, shell-free core capture paths. Keep captured
  originals immutable and reject approval payloads that invent or relabel a
  source outside that trusted path.
  The agent review now permits explicit Files, Git Diff, Visible Screen and
  direct-argv Command captures. The persistent core performs each capture,
  creates its provenance and durable part id, returns the exact captured part
  to the editor, and still accepts only known ids plus edited text at approval.
- [x] Profile editing at the 90 KB pack limit. Cache or debounce rendered-size
  work only if measurements show meaningful per-keystroke allocation or frame
  cost; do not trade the live, exact send-size gate for speculative speed.
  A production-optimized 88,637-byte fixture measured about 2.32 ms per full
  size render and 2.26 ms per edit normalization on the development Mac. The
  editor now performs one exact measurement per mutation (about 4.61 ms with
  normalization in the same fixture) and caches byte count plus validity for
  SwiftUI reads; the exact rendered send gate remains unchanged.

### Portable teams and navigation

- [x] Add reusable **team templates** containing pane vendors, names, roles,
  permission profiles, lead, automation policy and layout. Applying one to a
  folder creates stopped agent placeholders so no subscription session starts
  without an explicit person action.
  Team templates now live in an owner-only bounded store and deliberately omit
  folders, approved roots, live ids, credentials and sessions. Saving captures
  the current configured grid; applying chooses one target folder, rebinds
  permission profiles to it, creates a new workspace and leaves every agent
  stopped. Shells retain the saved-layout policy and may start automatically.
- [x] Add stable workspace-scoped **pane roles and aliases** such as `lead`,
  `implementer`, `reviewer` and `tester`. Routing by role must remain valid
  across display-name changes, refuse ambiguity, and never silently retarget a
  different live pane.
  Roles are independent owner-controlled tmux metadata with a lowercase slug
  grammar and one-role-per-workspace uniqueness. Their routing namespace is
  explicit (`@reviewer` and `workspace/@reviewer`), so a missing role can never
  fall through to a mutable display name. `lead` remains the separately marked
  built-in role. Protocol v7 teaches every newly started vendor this syntax;
  Status Center shows the exact injected version and restart requirement.
- [x] Add deliberate **pane mobility**: move a pane between workspaces when tmux
  can preserve it safely, or clone only its visible configuration into another
  workspace. Folder ownership, running-process consequences and active
  handoffs must be previewed before either action.
  The pane context menu now names every other workspace as a destination. Move
  uses tmux `join-pane`, keeps the exact process/id/scrollback/folder and
  rechecks the authoritative handoff state after confirmation; the last source
  pane, an active handoff, duplicate `@role` or duplicate lead is refused before
  mutation. Clone leaves source work and handoffs in place, copies only visible
  configuration and turns an agent copy into a stopped credential-free
  placeholder. Both actions explain their consequences before running.
- [x] Add external entry points such as `parley open <folder>`, a Finder action
  and a local `parley://` URL for opening or focusing a matching workspace.
  They may focus or prepare UI state but never start a vendor turn implicitly.
  The managed command now exposes a person-only `open` verb that asks
  LaunchServices for the installed Production app. Its Info.plist registers an
  alternate folder handler, an Open in Parley Finder Service and the bounded
  `parley://open?folder=` scheme. All three converge on one parser that accepts
  exactly one existing canonical directory and one UI action: focus a matching
  workspace or create its shell. Launch-time requests queue until SwiftUI binds;
  none can carry text, context, a pane kind or a submit action. DEV deliberately
  does not claim the machine-wide scheme.
- [x] Build a thin local **Visual Studio Code companion extension** on those
  entry points and context packs. From a local macOS workspace it can open or
  focus the folder in Parley, place a selection, current file, diagnostics or
  Git diff into Parley's editable context-pack preview, show attention counts,
  and focus the authoritative pane or Status Center record. The extension is a
  remote control for the native app: it never embeds a terminal, owns tmux or
  pane credentials, starts an agent implicitly, bypasses the handoff preview,
  or submits work on its own. Its first release runs in VS Code's local UI
  extension host and refuses unsupported web or remote-only execution rather
  than pretending a remote path is local.
  The companion is implemented in-tree: six context Command Palette and
  editor/explorer actions open or focus the local folder and stage a selection,
  saved current file, current-file diagnostics, Git diff, or selection plus
  diff. One owner-only one-shot manifest feeds the existing editable preview;
  files and diffs are recaptured by Parley, editor text stays attributed, and
  nothing starts or sends. An owner-only content-free Production heartbeat now
  supplies the VS Code status item and its attention/live-pane picker; strict
  focus URLs can select one exact pane or durable Status Center record and
  carry no work. The VSIX is built and attached by the manual draft-release
  workflow alongside the native macOS assets.

### Vendor-owned tools, including browser use

Agent panes remain the vendors' real interactive CLIs, so a pane may use a
browser through capabilities that its CLI already supplies or through MCP/tool
configuration the person has explicitly enabled for that vendor. Parley does
not replace that tool runtime or take custody of browser profiles, cookies or
website credentials.

- [ ] Show a small, truthful per-pane capability summary for explicitly
  configured browser/tool access when the vendor exposes a trustworthy way to
  inspect it. Unknown stays **Unknown**; terminal output and successful-looking
  browser prose are not capability evidence.
- [ ] Let browser-derived URLs, selected text, screenshots and saved artifacts
  be added deliberately to an editable context pack with source attribution
  and byte size before a cross-vendor handoff. Never scrape a vendor's browser
  session, share cookies, or forward browsing results invisibly.
- [ ] Add browser/tool checks to a vendor adapter only when the check can be
  performed without opening a website, spending model quota, changing vendor
  configuration or exposing credentials.

### Optional Git worktree awareness

Worktrees are parallel filesystem locations, not Parley workspaces, tasks or
agents. A workspace may point at a worktree folder, and several panes may share
one intentionally when one vendor implements and another reviews the same
uncommitted changes.

- [x] **Stage 1 — discover and open:** parse `git worktree list --porcelain`
  without a shell, show repository, branch and worktree identity, and offer
  **Open Existing Worktree as Workspace**. Continue to support ordinary folders
  and never require a worktree for review or consultation.
- [x] **Stage 2 — collision awareness:** warn when multiple write-capable agent
  panes share the same real worktree. Base the warning on exact canonical paths
  and visible permission state; do not claim which process changed a file or
  infer safety from a quiet terminal.
- [ ] **Stage 3 — optional creation:** only after the read-only stages prove
  useful, offer an explicitly previewed operation to create a new worktree at
  an exact destination and branch. Parley must not automatically merge, rebase,
  delete, prune or label any worktree as safe to remove.

### Attention, history and human control

- [x] Add a restrained **menu-bar attention inbox** for waiting answers,
  permission requests, completed delegations and failures while the main window
  is closed. Notifications and menu labels exclude prompt and answer bodies;
  selecting an item focuses the authoritative record in Parley.
- [x] Add collaboration-history search, filters, selective Markdown export and
  **Ask this again**. Repeating a handoff always opens an editable preview and
  receives a new identity rather than mutating or silently replaying history.
- [x] Add configurable local retention and explicit per-workspace export or
  purge controls. The persistent core now owns one runtime-local 100, 250 or
  500-record bound applied independently to handoffs and lifecycle activity;
  lowering it immediately compacts the owner-only journals after an explicit
  irreversible warning while preserving active work and curated chains. A
  workspace-scoped archive action exports every retained handoff involving the
  selected workspace, including dismissed records, and states that lifecycle
  activity is not part of that body-containing Markdown. The existing
  workspace-specific purge removes eligible handoffs and activity without an
  all-workspaces shortcut. Nothing syncs or reports telemetry.
- [x] Add a human-controlled **busy queue** for a reviewed draft when a target
  already has active work. The persistent core keeps at most 32 owner-only
  exact Ask drafts with their cross-vendor route and no credentials; pane
  capabilities cannot operate the queue. Status Center keeps the complete text
  visible as TARGET BUSY or READY TO REVIEW, but no idle observation has a
  dispatch hook. Review and Send opens a fresh editable preview and creates a
  normal tracked Ask only after explicit human authorization; discard touches
  no terminal. An interrupted explicit send remains SEND UNCERTAIN and DO NOT
  RESEND rather than being silently made safe to repeat.
- [x] Add a **workspace safety summary** before closing, replacing or moving a
  workspace. Show active handoffs, running agents, dirty repositories and
  shared-worktree writers without guessing whether an agent is thinking.

### Vendor and release lifecycle

- [ ] Add per-vendor compatibility checks that can run the conformance harness
  after a CLI upgrade and report launch, submit, Ask/Answer and permission
  support without spending model quota where the vendor permits that.
- [ ] Prefer official vendor hooks for runtime readiness—ready, working,
  awaiting permission or exited—and display **Unknown** when no trustworthy
  signal exists. Terminal silence and timing heuristics never become facts.
- [ ] Add an explicit GitHub Releases update channel with stable/beta choice,
  release notes and verified artifacts. Never download or install an update
  silently, and never replace the persistent core while tracked work is active.
- [ ] Add an explicitly user-reviewed **beta feedback bundle** containing build
  information, vendor versions, conformance results and redacted diagnostics.
  Reuse the structural privacy boundary of diagnostics export: no prompts,
  answers, terminal content, credentials or automatic telemetry.

**Exit gate:** Parley can compare independent vendors, carry explicitly chosen
context, reuse a stopped team safely and warn about concurrent writers without
becoming a source-control client, task board or hidden autonomous agent.

## Explicit non-goals

- No API-key vault, model router, or direct cloud inference.
- No generic Kanban board, issue tracker, DAG designer, or autonomous project
  manager.
- No invisible background model calls or hidden agents.
- No replacement editor, source-control client, or deployment platform.
- No cloud sync or telemetry.
- No scraping an entire terminal transcript and pretending it is a structured
  answer.
- No forced worktree-per-agent workflow.

Parley may expose enough state for a lead agent to supervise other vendors, but
it should not become the agent that plans their work. That distinction keeps
the product small and lets each CLI improve without Parley competing with it.

## Immediate build order

The completed foundation remains recorded below. The active sequence starts at
step 13 and deliberately hardens the context feature before expanding it:

1. [x] Persist the now-defined handoff state machine and transition record locally.
2. [x] Prove graceful core restart, stale discovery recovery, dead-pane handling,
   cancellation and retry without leaving a caller blocked.
3. [x] Run the UI-close lifecycle gate with live vendor panes and unchanged
   process ids.
4. [x] Add the opt-in vendor conformance harness.
5. [x] Render a minimal activity strip from the core's authoritative state.
6. [x] Add safe retry and permission-required actions to the existing cancel/manual-return activity controls.
7. [x] Introduce tracked `delegate` / `done` only after one-to-one recovery is solid.
8. [x] Add `ask-many` with independent answers and explicit target lists.
9. [x] Persist workspace layouts outside tmux.
10. [x] Add diff and plan review shortcuts through the same transport.
11. [x] Isolate installed and Development runtimes, including a single-UI lease
    and an explicit developer-only production attachment mode.
12. [x] Add cross-vendor CLI permission profiles with visible effective
    enforcement and immutable safe boundaries.
13. [x] Complete the context reliability gate: transactional mutation and race
    tests first, then draft disposal, explicit completion failures, trusted
    human-added sources and measured editor performance.
14. [x] Finish and land the current context-pack arc only after its native
    checks, build, help and protocol documentation pass together.
15. [x] Build portable teams and navigation, beginning with stopped team
    templates and stable pane roles/aliases, then deliberate pane mobility.
16. [x] Build the thin VS Code companion on the completed local external-entry
    contract and the same reviewed context-pack and focus contracts.
17. [x] Add read-only worktree discovery and writer-collision awareness. Keep
    optional worktree creation contingent on evidence from those two stages.
18. [x] Improve attention and history: menu-bar inbox, search/export/retention,
    a human-controlled busy queue and workspace safety summaries.
19. [ ] Integrate vendor-owned browser/tool evidence only through truthful
    capability checks and explicit attributed context-pack captures.
20. [ ] Add vendor compatibility checks, trustworthy readiness hooks, the
    stable/beta update channel and the reviewed beta feedback bundle.
21. [ ] Finish distribution: Developer ID signing and notarization, then test
    install, upgrade and uninstall on a physical clean Apple Silicon Mac. The
    repeatable isolated package lifecycle remains the prerequisite gate.

Anything not required by those steps waits.

## Success measures

- A supported vendor pair can repeat 100 Ask/Answer exchanges without manual
  submission, wrong-pane delivery, or a stranded wait.
- Closing and reopening the UI changes no agent pane process ID and interrupts
  no active handoff.
- Every failed handoff reaches a terminal state with a useful reason.
- Cross-workspace bare and qualified routing never guesses under ambiguity.
- A person can identify all waiting and failed collaboration from one screen.
- A lead-agent review → evaluate → delegate workflow needs one initial human
  instruction and zero manual transfers.
- Terminal and broker memory plateau under sustained output and repeated
  handoffs.
- No model API key, prompt, answer, or activity record leaves the Mac.
