# Parley — engineering guide

Parley is a native macOS workbench for visible, supervised collaboration
between AI coding CLIs from different vendors. SwiftUI owns the application
surface; embedded Ghostty surfaces own the real interactive processes.

There is one implementation. All product source is under `native/`. Do not add
a web renderer, embedded browser runtime, second terminal stack, background
daemon or compatibility application.

## Rationale and history live in Prax

This file holds the standing rules. The account behind each rule (what broke,
who found it, when it changed, which check pins it) lives in Prax, project
`parley`, tagged `engineering-notes`. Each section below names its notes.
Before changing an area, recall them:

```bash
prax recall "<area>"                      # e.g. "Parley transport liveness"
prax recall --project parley --recent 40
```

When behaviour changes, update the rule here and refine the note in Prax
(`prax remember "<same title>" …` updates in place). Do not bring the story
back into this file: every vendor reads it on every launch, Claude Code stops
loading it past 150k characters and Codex reads only its first 32 KiB by
default. Add a rule here only when an agent needs it on every turn.

## Product boundary

Parley exists to make cross-vendor work easier. Claude Code, Codex, Agy and
GitHub Copilot CLI retain their own models, authentication, tools, permission
prompts and conversation interfaces. Parley supplies panes, workspaces,
attributed handoffs, correlated consultations and visible supervision.

Use this test for proposed scope:

> Could one vendor CLI do this on its own?

If yes, the vendor owns it. If the feature coordinates different vendors or
makes that coordination visible, safe or recoverable, it belongs in Parley.

## Product invariants

Breaking any of these changes the product.

1. **Subscription CLIs only.** Use vendor binaries installed on the host or
   in a person-reviewed local container image, with the person's vendor login.
   Never add API keys or a direct model API path.
2. **Real interactive sessions.** Preserve each CLI's TUI, prompts, permission
   flow and session behavior. Parley does not replace them with a chat UI.
3. **Host approval protection; reviewed container exception.** Host vendor
   launches never pass a `--dangerously-*` option, `danger-full-access` or an
   equivalent bypass. The person may explicitly select Bypass vendor permissions
   for a local container pane or a team's per-vendor container configuration.
   Only that reviewed container launch receives the fixed vendor bypass flag;
   Docker isolation and native host command-run approvals remain in force.
   A vendor's own automatic reviewer is not a bypass: Claude's auto mode
   (`--permission-mode auto`), Codex's auto review
   (`-c approvals_reviewer=auto_review`) and Copilot's assisted approval
   (`--assisted-approval`) keep the sandbox and the deny and ask rules and can
   refuse, so the person may select **Vendor's automatic reviewer** per
   launch or per team vendor (`PermissionApprovalHandling`,
   `TeamSessionGrant.hostApprovals`) as an explicit, disclosed choice. Agy has
   no reviewer, only a skip-all flag, so it always asks on the host. Skip-all
   flags stay forbidden.
4. **Cross-vendor first, pane-explicit.** Automatic targets are explicit agent
   panes other than the sender. Same-vendor routes require distinct panes.
   Never broadcast implicitly, target a shell through Relay/Paste/Ask, or guess
   between ambiguities. The person-approved request-run path is the sole
   explicit exception for new human Shell execution.
5. **Visible and interruptible.** The person can see every participant and
   handoff, focus either side and stop tracked work.
6. **Local coordination.** No hosted service, sync, telemetry or remote-control
   backend. Vendor CLIs contact their own services normally.
7. **One embedded terminal stack.** Ghostty is the terminal renderer and PTY
   owner. Do not add another multiplexer, renderer or hidden terminal client.
8. **One shared protocol.** `AgentProtocol.text` solely defines the agent-facing
   identity, discovery, event, Relay/Paste, Ask/Answer, delegation, status,
   cancellation and reviewed-context commands. Launch adapters may change
   delivery mechanics, never wording.
9. **Honest state.** Do not infer thinking, token use, context limits, cost,
   permission state or completion from terminal text.
10. **macOS-native restraint.** Use system fonts, hairline rules, small radii,
    one accent and tabular numerals. No gradients, emoji or decorative AI art.

## Commands

```bash
npm run scan:public
npm test
npm run build
npm run dev
npm run test:soak -- --rounds 25
npm run test:vm
```

The root npm scripts are a dependency-free runner around
`scripts/run-native-swift.mjs`. Do not run `npm install` at the repository root.
The helper chooses a compatible installed macOS SDK and writable Swift caches.

`npm run test:vm` (`scripts/test-vm.mjs`) runs CI's own sequence inside a
local Tart macOS VM named `parley-dev`, cloned once from the image
`.github/workflows/ci.yml` pins. The checks open real Ghostty surfaces, menus and
windows, which on the desktop land on the person's screen and fail when they
touch the Mac or the display sleeps; the VM has a display of its own. Prefer
it for a full run, and for the screen-touching checks in particular. Pass npm
arguments through: `npm run test:vm -- run test:checks -- --only "pane menu"`.

Normal launch must never restart a surviving in-app pane. Panes live inside
the app, so at launch every agent pane is a stopped placeholder; there is no
launch option that restarts stale-protocol panes.

## Layout

```text
native/
  Package.swift
  Package.resolved
  Sources/
    ParleyCore/
      AgentProtocol.swift              canonical agent-facing contract
      AgentProcessBoundary.swift       container host-client Seatbelt boundary
      HostAgentPermissions.swift       Codex-native host permission rules
      AppResidentPaneLifecycle.swift   explicit window/quit lifetime policy
      CommandRunner.swift              bounded argv process execution
      AutomaticUpdateConfiguration.swift signed Production update boundary
      CoreService.swift                authenticated UI control client/types
      GhosttyAppearanceImport.swift    bounded appearance-only config parser
      Models.swift                     pane/workspace vocabulary
      Relay.swift                      credentials and consultations
      RelayHTTPServer.swift            authenticated Unix-socket broker
      RelayText.swift                  terminal-frame cleanup
      WorkbenchController.swift        workspace metadata and pane launch
    ParleyNative/
      AppModel.swift                   state and confirmed human actions
      AppResidentCoordinationCore.swift
      ContentView.swift                workbench, pane and relay UI
      GhosttyPaneRegistry.swift        retained surfaces and input delivery
      NativeTerminalHost.swift         SwiftUI/AppKit Ghostty bridge
      ParleyAutomaticUpdater.swift     Production-only Sparkle bridge
      ParleyNativeApp.swift
    ParleyCoreChecks/main.swift
    ParleySoak/ParleySoak.swift
scripts/
  run-native-swift.mjs
resources/
  icon.icns
  icon.png
```

App behavior belongs in Swift. Node scripts are build and release tooling only.
Longer references: `docs/container-images.md`, `docs/test-scenarios.md`,
`docs/worktrees-roadmap.md`, `RELEASING.md`.

## Runtime and lifetime model

Prax notes: "Parley runtime: workspaces, panes, persistence, auxiliary windows
and process exit"; "Parley durable records: handoff and activity journals,
owner-only files, attention and status caches"; "Parley in-process relay
broker, UI tick revision gate and transport polling"; "Parley transport
liveness: heartbeats, clocks, shim cleanup and endpoint pruning"; "Parley
Sparkle updates, pane creation menu, pane menus and split divider"; "Parley
workspaces: folders, sidebar sections, groups and navigation for many
workspaces".

- Runtime files live under `~/Library/Application Support/Parley Native/` for
  Production and a separate Development directory.
- A workspace may hold no panes. New Workspace creates none; the gestures
  that ask for a place to work (fresh install, Open Folder) seed one shell.
  Only the last workspace cannot be closed. `EmptyWorkspaceChecks` pins this.
- Each live pane is one retained Ghostty `AppTerminalView` with its own PTY.
  `GhosttyPaneRegistry` retains views by pane id across remounts and window
  hiding; `NativeTerminalHost` must return that exact view and never wrap it
  in a container that adopts it as a subview. Each pane id appears in a
  workspace's `NativeLayoutNode` at most once.
- `WorkbenchController` persists metadata in `workbench-state.json`; terminal
  bytes and vendor conversations are never serialized. Title changes are
  coalesced to one write per second; a working-directory report persists only
  when the folder changed.
- Closing the main window keeps panes and coordination alive. Auxiliary
  windows (Status Center, Help, About, Settings, Worktrees) are scenes rooted
  in `AuxiliaryWindowRoot`: released when closed, so no observer, timer or
  layout work remains; suspended while hidden; a request that selects
  something in a window is consumed once applied.
- Closing a pane or workspace ends its processes. The quit dialog offers Quit
  Parley or Cancel only; there is no Stop Everything action, so do not name
  one. A pane ends when its CLI exits, or through Stop…, Close or Restart.
  After a relaunch agent panes are stopped placeholders; never claim a vendor
  session survived.
- A pane's exit is read from Ghostty's own record (`GhosttyProcessExit`),
  polled each second and routed once per launch generation; an unreadable
  record is unknown, never an exit. `ProcessExitChecks` reads real surfaces,
  so re-check it whenever the Ghostty pin changes.
- Durable records are JSON lines: one synced append per record, atomic
  compaction only past eight times the bound. A record is durable before it
  is acknowledged; a failed append changes nothing in memory; a compaction
  failure is kept as `lastError` and shown through Status Center core health,
  never reported as a lost record. Every owner-only store writes through
  `OwnerOnlyFile.write` (0600 temporary file, fsync, rename).
- The broker is `AppResidentCoordinationCore` inside the app process. No
  separate core executable, login item or background process. The UI tick
  asks the broker's `stateRevision()` first and fetches only on change
  (`RelayPollPolicy` forces one every fifteen ticks); every mutation the UI
  reads must `noteChangeLocked` (`BrokerRevisionChecks`). Every value
  `AppModel.statusSnapshot` passes to the projection must bump
  `statusInputGeneration` in its `didSet` (`StatusSnapshotChecks`).
- The agent file transport polls inboxes at 50 ms while requests flow and 250
  ms after ten quiet ticks, with a vnode watcher per inbox. Liveness is the
  per-endpoint `heartbeat` file; the shim judges it by whether its time
  changes, never against the wall clock. Every age uses the injected
  `RelayTransportClocks` (monotonic for heartbeat due, uptime-raw for in-flight
  requests, tickets and stale replies). Each heartbeat carries the transport
  instance so a restart is noticed, and prunes endpoints whose capability is
  gone; capabilities that cannot be read prune nothing. The shim stages stdin
  before the request exists and cleans up on INT, TERM and HUP; "not running"
  and "could not write the request" always mean nothing was sent.
- Sparkle.framework is the sole update mechanism and never a daemon.
  Development never starts Sparkle or receives the Production feed. Automatic
  checking is opt-in, background installation disabled, and updater-initiated
  termination passes through the pane-aware quit confirmation.
- The Pane menu offers **Shell** and **Agent** with the same six
  split-and-folder items (`PaneCreationMenu`), never one entry per vendor. The
  vendor is chosen in the permission review's Vendor row, shown only for a
  creation review. Shortcuts are ⌥⌘1–5 (`PaneShortcutChecks` keeps them clear
  of macOS screenshot chords and Parley's key monitor).
- Pane header, sidebar, workspace-row, folder-row and history menus are AppKit
  snapshots (`ToolbarActionMenu`, `PaneActionsMenu`, `PaneContextMenu`,
  `snapshotContextMenu`), not live SwiftUI menus, and every enabled item is
  also a VoiceOver action. A disabled destructive item is drawn disabled.
- A workspace is durable identity independent of folders: zero or more
  attachments plus an optional New Pane Folder. Attachment changes never grant
  permission or touch a process. Folder menus never offer a missing folder
  (`FolderListMaintenance`); `AppModel.folderIdentity` memoises for five
  seconds and forgets on explicit refresh.
- The sidebar is built for many workspaces (`WorkspaceSidebarSections`): This
  Workspace, Needs Attention (the menu bar's own count; a failure or request
  counts until opened in Status Center and at most a day), Pinned, Recent
  (past eight workspaces), All Workspaces with groups. `lastSelectedAt`
  changes only in `activateWorkspaceLocked` and `createWorkspaceLocked`.
  Groups are presentation metadata that never reach an agent and decode
  absent as none. Go to Workspace (⇧⌘O) orders by `WorkspaceSwitcherOrder`;
  hidden-sidebar tabs past eight are pinned, current and needing the person,
  in workspace order so a tab never changes place.

## Relay and consultation contract

Prax notes: "Parley relay and consultation contract: commands, exact ids,
targetTurnStarted and Delegate Again"; "Parley relay threading, message
limits, discovery, hook adapters and target rules"; "Parley reviewed Ask
drafts, human Ask and Answer, link policy, appearance import and verdicts";
"Parley review loop practice and completion-evidence convention"; "Parley
pane input delivery: paste, Enter, focus and failure classification".

- The `parley` command uses an authenticated capability-named filesystem
  endpoint; the native UI alone uses the control socket. Each agent pane has
  one durable random credential; a caller cannot choose another source.
- `AgentProtocol.text` is the command reference (relay, whoami, panes, events,
  paste, ask/answer, ask-many, delegate, progress, done/fail, status, wait,
  context, image, request-run, team). `parley signal` is for generated hook
  adapters only.
- Every delivered question and delegation teaches its own exact id. `current`
  stays in the protocol but is never taught; a late `answer`, `done`, `done
  --file` or `progress` naming a closed item is refused with the state it
  reached, told only to the pane that was asked; `current` is refused outright
  for a pane whose run had a delegation cancelled.
- `parley status` carries `targetTurnStarted` per delegation (protocol 34):
  true once the target's turn-start hook arrived after `submissionStartedAt`,
  false for active work to a target that has reported a hook this run, nil
  otherwise. The protocol tells the agent to ask the person, never to resend;
  Status Center offers Ask This Again and Delegate This Again (native-only,
  `repeatsHandoffID`, never in `parley status`).
- Relay requests never run on the shared dispatch pool. Every transport
  request, UI connection and ask-many child runs on its own `RelayWorkerThread`
  (at most 128); requests that can block count against a `BlockingRequestGate`
  of 64 and get 503 past it; `parley wait` is a 55-second long-poll (status
  102, the shim asks again). `BoundedWaitChecks` parks 80 waits.
- Text is limited to `RelayText.maximumCharacters` (100,000) after
  `RelayText.clean`, which never truncates. Every route refuses longer text
  with 400 and the real length; any direct paste that bypasses the broker must
  keep a limit of its own.
- Discovery exposes no credentials, folders, commands, prompts or terminal
  text. `events` returns at most 100 ordered records per page and omits
  bodies; a cursor removed by retention fails explicitly.
- Hook adapters ignore hook input and submit one fixed event name through the
  pane's capability. Claude, Codex and Copilot get session-scoped adapters;
  Agy gets none. Agents never run `parley signal`.
- Relay is immediate; paste is review-before-send. Targets resolve by exact
  pane id, explicit role, or vendor only when unique. Refuse ambiguous,
  missing, same-pane, shell and busy targets; same-vendor only between
  distinct panes; at most one unanswered consultation or active delegation per
  target. The Ask and Review menus stay enabled and show
  `AskAvailability.unavailableReason`.
- A person's reviewed Ask keeps its draft until the broker accepts it. After a
  failure, `ReviewedAskHistory.outcome` decides: the draft comes back only
  when no record exists; every other outcome offers Copy Draft Text, so a
  question is never offered for sending twice. Busy and existence decisions
  read `latestKnownHandoffs`.
- Human Ask and Answer submit only after an editable preview. Never capture
  scrollback or a conversation implicitly. The composer is inline chrome;
  `repairNativeTerminalFocus` must do nothing while it, or any editable text
  view, is first responder. A human Ask's answer is a returned result shown in
  Status Center, never text written into the source pane.
- A command-clicked link goes through `TerminalLinkPolicy`: http or https with
  a host, bounded, no control characters; everything else is ignored silently.
  Parley never opens a link on its own.
- Ghostty appearance import is explicit and allowlisted (font family, size,
  theme, palette, hex colours). Never load a raw config, follow `config-file`
  or keep commands, keybindings or behaviour. Repeated `font-family` lines keep
  the first after the last reset.
- Challenge and Verify are native-only over one returned Ask or Delegate,
  recorded by `inReplyToHandoffID` and relationship, never queued in the busy
  queue. Only the native control route sets or clears a verdict and note, at
  the exact revision shown. Pane credentials have no review-mutation route. No
  separate evidence or review database.
- The review loop (delegate, `progress`, `done --file`, cross-vendor review,
  one `requestChanges` child) is guidance; the Review and correct recipe is a
  prompt template. Add no workflow state machine, automatic transitions, claim
  verifier, streamed progress or completion estimate. Completion evidence
  (`## Implemented`, `## Tested`, `## Unable to test`) is shown as
  AGENT-DECLARED unchecked claims, read from the staged `returnedPart`.
- Delivery is one Ghostty paste, then a separate Enter key event; never raw
  newlines as keys. `PaneInputDelivery` re-resolves the target by pane id,
  launch generation and view before each input step; the controller refuses a
  second delivery to a pane while one is in flight. A failure before the paste
  is `refusedBeforeInput` (Retry Delivery allowed); any failure after it is
  `deliveryInterrupted`. Settles are bounded on a monotonic clock. Delivery
  neither focuses nor selects the target (`PaneSubmissionTiming.focusesTarget`
  is false; only Copilot briefly focuses through `DeliveryFocus`) and restores
  focus through the target's own window. Refuse delivery at Copilot's
  folder-trust prompt until Confirm Copilot Folder Trust for that launch.

## Voice input and spoken handoffs

Prax notes: "Parley voice input and spoken handoffs: engineering notes".

- `VoiceSession`, `VoiceDestination` and `VoicePlaybackQueue` are
  Foundation-only policy in ParleyCore; Speech and AVFoundation stay in
  ParleyNative.
- Languages are en-GB and en-US. macOS 26 uses SpeechAnalyzer with an explicit
  asset download; older hardware uses on-device SFSpeechRecognizer only. No
  cloud fallback, no raw audio files. Info.plist consent strings and the
  audio-input entitlement are required; the unbundled executable refuses to
  record.
- Dictate is click to start, click to stop; Control-Shift-Space is hold; 60
  seconds ends recording; Control-Option-Space is reserved for VoiceOver.
- The draft is bound to pane id, generation, vendor, workspace and launch
  folder; selection changes never redirect it. Paste and Send use the ordinary
  controller checks and delivery path; a potentially partial delivery is copy
  or discard only. `VoiceHandoffRequest` is native-control-only and changes no
  protocol wording.
- The transcript editor owns focus while open. Read-aloud is off by default,
  reads only an explicit selection or returned result, and holds three items
  of at most 8,000 characters; capture and playback exclude each other. No
  terminal scraping, completion inference, always-listening mode, spoken
  approval or navigation commands. Consent and audible output are manual
  acceptance in `docs/test-scenarios.md`.

## Process and capability boundary

Prax notes: "Parley process boundary: Git read guard, signal state, bounded
waits and process sessions"; "Parley host vendor launches, Codex permissions,
profile resolution and preflight"; "Parley native control socket, pane
capabilities, ticket server and ticket policy"; "Parley PATH shim, transport
path spelling and environment resolution".

- Spawn fixed executables with argument arrays. Agent-authored content must
  never be interpolated into a shell command.
- Every Git command that *reads* a repository on the host goes through
  `GitReadBoundary`: `/bin/bash -c 'ulimit -H -S -u 1 && exec "$@"'`, so Git
  cannot start any configured program; filter drivers neutralised through
  `GIT_CONFIG_*`; diffs with `GitReadBoundary.diffArguments` and status with
  `--ignore-submodules=dirty`; inherited `GIT_*`, `BASH_*`, `ENV`,
  `SHELLOPTS`, `BASHOPTS` and `CDPATH` dropped; locks, prompts, pagers and
  lazy fetch off. Person-confirmed operations (worktree add, remove, prune,
  `branch -d`, Integrate) are Git itself outside the guard.
  `GitReadBoundaryChecks` plants every hook kind and requires none runs.
- Every spawner sets `POSIX_SPAWN_SETSIGDEF` and `POSIX_SPAWN_SETSIGMASK`.
  `ProcessCommandRunner` runs each command in its own session
  (`POSIX_SPAWN_SETSID`) and on timeout signals the group: SIGTERM, then
  SIGKILL after the full grace second, the child kept unreaped with `WNOWAIT`.
  An unobserved exit is `CommandWaitOutcome.unobserved` (125), never success;
  a timeout is 124; every wait, including after SIGKILL, is bounded
  (`BoundedReap`).
- Host vendor CLIs launch directly as trusted local applications with their
  own permissions. Do not wrap them in Parley's Seatbelt profile. Host Codex
  takes `HostAgentPermissions.launchArguments`; other vendors and containers
  use `PermissionProfileAdapter.launchPlan`. A field on
  `PermissionProfileSelection` must be passed at every
  `PermissionProfileResolver.resolve(` call site, required rather than
  defaulted, and anything a host Codex pane needs must be in both. Codex gets
  `network={enabled=true}` only when the profile allows network (Flexible +
  network). Never present a profile intention as OS enforcement. The review
  sheet shows Runs, What is carried and What is not carried, derived from
  `PermissionProfileLaunchPlan`, whose `detail` stays byte-identical.
- The Codex review runs a bounded preflight off the main actor: a transient
  `codex app-server --stdio` configuration read (never logged) and a `codex
  sandbox -P` probe with synthetic files. It verifies that moment only;
  existing processes are never restarted.
- Native control uses a fresh memory-only token, a socket path supplied by
  construction, peer-PID checks on both sides and per-send SIGPIPE
  suppression; it has no pane-token routes. Request fields are read through
  pinned descriptors with no-follow opens, never an `lstat` and a second
  lookup. `AgentProcessBoundary` wraps only the host Docker client.
- Pane capabilities authenticate and route; attribution is not isolation
  against an unrestricted same-user process. `RelayTicketServer` listens on
  `tickets.sock` (or the temporary directory when the path is too long,
  `socketURL(transportDirectory:)` deciding for both sides) and issues one-use
  tickets, ten seconds on `CLOCK_UPTIME_RAW`, after verifying peer uid,
  `LOCAL_PEERPID` and a bounded parent walk to this app. Only the app's direct
  launch root may supply `PARLEY_PANE_ID` and `PARLEY_PANE_GENERATION`.
  `RelayTicketPolicy` (from observed panes, never documentation): required for
  Claude and Copilot host panes and Agy; required for Codex when its profile
  allows network, optional otherwise; optional for a Claude host pane with its
  own sandbox on (`ClaudeHostConfiguration`, read in Claude's precedence
  through bounded opens, snapshotted at launch); unavailable in containers and
  when the socket is not listening. A ticket socket that fails to start never
  fails the core. `whoami` reports `attestation` and the policy; the review
  lists it. The shim retries a ticket that got no answer up to ten times; a
  "refused" answer is final.
- `WorkbenchPane.launchFolder` is the person-selected agent folder, separate
  from the terminal-reported `cwd`. Grants, roots, staging, captures and
  reviews use it; OSC reports never widen them; only a native stopped-pane
  selection changes it. Parley never writes Claude's or Agy's settings.
- The runtime-local shim is preferred; `~/.local/bin/parley` is a
  runtime-neutral router (`PARLEY_RUNTIME=DEV` selects Development; only
  Production installs it). Transport path spelling in permission rules and the
  container Seatbelt profile must match the shim, aliases included.
  `EnvironmentResolver` may run fixed `/bin/zsh -lic` PATH discovery with a
  hard timeout. Apply `LANG=C.UTF-8` only when every locale variable is
  absent or empty. Strip parent multiplexer markers from vendor environments.

## Reviewed command runs

Prax notes: "Parley reviewed command runs: worker, approval, tickets, pane
cleanup and person proposals".

- `parley request-run --cwd <folder> -- <executable> [args…]` proposes exact
  argv in a contained canonical folder. Native editable approval opens one NEW
  Shell pane; a fixed worker spawns argv directly, captures bounded output and
  the real exit status, then execs an ordinary shell. Never interpolate agent
  content into a shell string, send input to an existing Shell, or present
  captured output as verification.
- The command runs in its own session with stdin on `/dev/null` and no
  controlling terminal; one that needs a prompt fails and says so; queued
  terminal input is discarded before the shell (`ApprovedCommandTerminalChecks`).
- Every box whose text is approved or sent is a `PlainTextEditor` (all
  automatic substitutions off), with its own undo manager. `ReviewedCommand.
  parseDisplay` names a typographic quote only when straightening makes the
  array parse (`CommandRunArgvEditorChecks`).
- Per-run approval is the default. Exact-command session trust and the two
  Settings › General › Agent command runs choices are native, memory-only,
  off at every launch and reset on quit (`CommandRunAuthorizationSession`).
  Never restore execution authority from the journal, a preference or a file.
  Automatic approval records `approvedAutomatically`; "Close the Shell pane
  when a run finishes cleanly" travels in the worker ticket
  (`exitInsteadOfShellWhenClean`), and the released lease, not Ghostty's exit
  record, proves the worker exited.
- Worker tickets bind the app owner's PID and process start time and carry a
  digest the worker checks before decoding; legacy tickets cannot execute.
  Read a worker's state as files first, lease last, and read the files again
  when the lease is gone. Every surface termination goes through
  `terminateSurface` or `endSurfaceLocked`; lifecycle routes refuse while
  `isTerminatingSurface`.
- One active run per requester; cancellation stops the owned process group;
  recovery needs the same live source generation; the journal and the 90 KB
  rendered / 200 KB transport bounds are reused. A person-proposed run
  (`origin: .person`, today only Integrate…) is always pending until its
  preview approves it, one at a time, and refused by `parley wait`.

## Team sessions

Prax notes: "Parley team sessions: grants, provisioning, ownership, stop and
transitions".

- `parley team request` needs a live agent pane in a workspace whose policy
  allows delegation and a folder inside the lead's working folder. Nothing is
  authorized until the person approves the editable preview (objective,
  folder, vendors, profile, at most 8 panes, at most 128 hours). The grant is
  memory-only (`TeamSessionGrant`), keyed to lead pane id, generation,
  workspace, policy and canonical folder, and binds the full profile
  definition, never only an id.
- Only the lead may `team add`, one creation at a time, idempotent by request
  identity. Ownership (pane id plus created generation) is recorded before any
  mounting step; the limit counts every creation for the session's life;
  failed provisions are kept for `parley wait` only up to
  `retainedFailedProvisions` (16). Members cannot add panes or nest sessions.
  Agents choose an allowed vendor, never an image, daemon, mount or bypass.
- Stop revokes the grant and stops only still-owned processes; a restarted
  pane is skipped and reported. Expiry and interruption revoke and stop
  nothing. Lead restart, move, folder or policy change, an edited or removed
  profile and quit interrupt the session. The Team Sessions sheet never blocks
  provisioning; any other sheet or modal does. Its Work list is
  `TeamSessionWorkScope`. Transitions are typed (`TeamSessionTransition`) with
  origin derived in trusted code; activity records and events carry
  correlation ids and label-and-count detail only, never objectives, folders
  or text. Containment uses `WorkspaceFolderIdentity.contains` on canonical
  spellings. Agent status names `requesterPaneID`; `lead` means the marked
  workspace lead.
- Vendor prompts stay active except for an approved per-vendor container
  bypass. Members with the vendor's automatic reviewer or a container bypass
  run unattended; Agy always asks on the host. Parley never answers prompts,
  restarts a pane for an agent or restores team authority from a journal.

## Managed Git worktrees

Prax notes: "Parley managed worktrees: service, creation receipts and team
binding"; "Parley worktree cleanup policy and removal outcomes"; "Parley
Worktrees window, board, prune, delete branch, bulk removal and merge
previews". Decisions and open questions: `docs/worktrees-roadmap.md`.

- One worktree per feature or team, never per pane. `ManagedWorktreeService`
  runs fixed `/usr/bin/git` argv (reads inside `GitReadBoundary`), a scrubbed
  environment, `--end-of-options` before any person-supplied value, bounded
  timeouts and no `--force` anywhere. Branch names are validated and checked
  with `check-ref-format --branch`; identity is the canonical
  `--git-common-dir`; listings are parsed on NUL boundaries. The current
  branch comes from `symbolic-ref --quiet HEAD`, never `--short`.
- Creation only after a native preview, bound to it: `create` re-resolves and
  refuses if the common directory, planned path `<toplevel>/.worktrees/<slug>`
  or base commit differ; it refuses an existing branch, a symlinked or escaping
  `.worktrees` or an existing path; it appends one `.worktrees/` exclude line
  and runs `git worktree add -b` once. Only a successful add from this process
  is a creation receipt; otherwise the registry decides `unmanaged`,
  `ambiguous`, `incomplete`, `uncertain` or `createdButUnrecorded`, none of
  which is adopted or retried. The marker is
  `<common>/worktrees/<name>/parley-worktree-owner`, written without
  overwriting. `managed-worktrees.json` (0600) is ownership and base metadata,
  never execution authority.
- A team's `--worktree` is a proposal. The approval form chooses an ordinary
  folder, an existing tree or a new one, runs `preflightApproval` before any
  Git, then binds exactly that tree (`TeamWorktreeBinding`). Host grants are
  never widened to the repository; a container may bind only the reviewed
  shared Git mount. Evidence in the delegation inspector is matched by exact
  `--show-toplevel` root at delegation time, never a later lookup.
- Cleanup is person-triggered. `cleanupPreview` and `remove` read every fact
  fresh, and `WorktreeCleanupPolicy.decision` is the pure table. Refuse on: a
  nested registered or known worktree or independent repository; any pane
  inside the tree, in either runtime; modified or untracked files; a present
  assume-unchanged or skip-worktree file; a populated submodule; commits ahead
  of the upstream's local tracking state; no upstream and not contained in the
  primary's HEAD; locked, prunable or unregistered; the primary checkout; a
  Parley marker that no longer matches; an uninspectable path; an unreadable
  state file, registry or store; more than 200 ignored entries; any
  unanswerable Git question. The exceptions: `upstreamGone` and
  `upstreamUnknown` are settled by the primary's HEAD, and a `CACHEDIR.TAG`
  folder is listed as uninspected rather than searched. Every ignored entry
  Git would delete is shown in full, escaped. Removal is `git worktree remove
  --end-of-options <path>` from the primary, under a folder reservation that
  `requireDirectory` enforces on every launch route, and reports `removed`,
  `retained` or `uncertain` from what registry and filesystem show.
- The Worktrees window (Tools › Worktrees…) is an auxiliary scene. Its
  repository list merges every folder Parley knows plus repositories the
  person added (`worktree-repositories.json`, paths only). Rows are Git's
  registry annotated by records; an unrecorded tree gets a record silently on
  the way into Finish or Remove. Prune uses Git's own dry run and refuses
  when any entry's folder still exists, has no recorded location or is still
  linked from Parley. Delete branch is one `git branch -d --end-of-options`
  bound to the previewed commit; `-D` never appears. Integrate proposes `git
  merge --no-ff --no-edit --end-of-options refs/heads/<branch>` in the primary
  as a person-proposed reviewed run, always by full ref, and refuses a
  detached HEAD. A bare registry entry is labelled bare, never primary. The
  board (`WorktreeBoardRow`) is derived on every read and never stored; a
  failed fact read is unknown, never zero; Unused (HEAD at its recorded base,
  clean) is distinct from Integrated. Bulk removal runs a fresh
  `cleanupPreview` per tree and stops at the first outcome that is not a
  confirmed removal.
- Merge previews resolve both refs to commits and run `merge-tree` inside
  `GitReadBoundary` in a private bare temporary repository with a read-only
  alternate: a prediction, never a merge or a verdict, bounded at 200 KB and
  200 paths. Recovery never adopts a tree by branch name. `WorktreeDiskUsage`
  is bounded and labelled. Deferred: merges, rebases, pushes or stashes by
  Parley itself, automatic cleanup or branch deletion, per-pane worktrees,
  multi-folder grants.

## Container panes

Prax notes: "Parley container panes: review, image contract, bypass flags and
launch projection"; "Parley container lifecycle: preparation, cleanup
receipts, stops and Docker checks"; "Parley container test images on Mark's
Mac (26 Sep 2026)". Image contract and recipes: `docs/container-images.md`,
`docs/parley-agents.Dockerfile`, `docs/parley-agents-fetch.sh`.

- Container execution is independent of fresh/resume and is chosen in the
  permission review for any vendor, with a locally installed image the person
  names. Parley never builds or pulls images. The probe checks the utility
  contract and the vendor's `--version` (or `codex sandbox -- /bin/true`); it
  cannot establish login or instruction uptake. The image check applies its
  result only under the `checkRevision` it began with.
- Bypass vendor permissions is the container-only exception to invariant 3
  (authorized by Mark on 9 September 2026). `ContainerLaunchProjection.
  bypassArguments(for:)` is the one table; `--allow-all*` and every other
  bypass flag arriving through vendor arguments is refused; bypass and legacy
  Landlock cannot be combined; the review, pane badge, Team Sessions and
  Status Center disclose it. Only the native review chooses it.
- argv carries an explicit daemon, non-root uid/gid, four exact mounts
  (project and own endpoint writable; protocol and Linux shim read-only), the
  reviewed shared Git directory for a linked worktree, one private home volume
  with `volume-nocopy=true`, logging off, an explicit entrypoint, an optional
  loopback `publishedPort` and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` as the only
  vendor environment key. Never mount the Docker socket, host vendor
  configuration or sibling endpoints. Reject broad or overlapping roots and
  submodules. Working folders cannot contain or sit inside either runtime's
  control or transport directories; compare canonical realpaths before
  credential rotation or any Docker command.
- A container can rewrite its mounted repository's hooks, filters and
  configuration, so Parley runs no Git for a container pane's delegation or
  return (`DelegationGitSnapshot.notCaptured`), every other read of such a
  repository goes through `GitReadBoundary`, and every container review
  states `GitReadBoundary.containerDisclosure`.
- Creation persists a stopped placeholder, then `prepareContainerStart` runs
  Docker off the main actor without the workbench lock; activation checks the
  exact generation, folder, workspace, policy, profile and mode. `docker
  create` precedes a Ghostty-owned `docker start --attach --interactive`;
  `container-panes.json` and `container-<owner>.cid` record intent before
  attach. Cleanup checks the recorded daemon, full ID and ownership marker,
  uses bounded stop and remove without force and preserves uncertain records;
  names and labels are never cleanup authority. Every stop names the
  generation it reviewed (`stopPaneProcess(expectedGeneration:)`,
  `prepareContainerStop(_:requiringWorkspace:)`). Close, Stop… and the bulk
  actions run through `ContainerStopSequence`, which holds the panes against
  move, refuses the action if any stop failed or any pane changed, and
  releases on every path. Stop, close, restart and quit stop the container
  before the surface; a failed stop refuses the operation. No daemon scan or
  process sampling on the refresh tick.
- Closing the main window keeps containers alive. Volumes survive removal and
  are deleted only through Status Center › Health › Containers.
  `whoami.executionBoundary` reports configuration only. Container cwd reports
  never replace the reviewed host folder.
- The Docker checks are explicit, fail when prerequisites are missing and
  never count as passed unrun: `parley-native-checks
  --container-{transport,ghostty,bypass}-spike <image>`. Sign-in, instruction
  uptake and login persistence are human follow-ups; untested configurations
  do not hold a release.

## SwiftPM inside agent panes and terminal type

Prax notes: "Parley SwiftPM wrapper and terminal type for panes".

- SwiftPM compatibility (Settings › General › Swift package builds) is off by
  default and reaches newly started panes only: a runtime-local `swift`
  wrapper adds `--disable-sandbox` to `build`, `test`, `run` and `package`.
  `PARLEY_SWIFTPM_COMPATIBILITY=0` opts one invocation out;
  `"$PARLEY_SWIFT_COMMAND"` reaches the wrapper if PATH changes. It expands no
  permission. Never infer opt-in from being inside Parley; the repository
  runner honours `PARLEY_SWIFTPM_COMPATIBILITY=1 npm test` per command.
- Settings › Terminal › Terminal type (`TerminalTypePreference`): Ghostty
  (`xterm-ghostty`, default) or Compatible (`xterm-256color`), read once per
  launch generation and carried as one `TERM=` word for `/usr/bin/env` in the
  launch command, never in the surface's `envVars`. Containers already get
  `xterm-256color`. `TerminalTypeChecks` pins it. Parley shows, but never
  runs, the `infocmp -x xterm-ghostty | ssh <host> -- tic -x -` remedy.

## Reviewed context boundary

Prax notes: "Parley reviewed context boundary: parts, markers, origins and
agent-staged images"; "Parley window capture, files the person adds, context
deletion and locking"; "Parley context draft sending: Ask One Pane, send
recovery and detached UI requests".

- An agent-staged part is a claim and stays `agentFileDraft`. Only a separate
  human-authorized capture creates trusted File, Git Diff, Selection or
  Command Result provenance. Parts sit between marker lines no pack text
  contains; every one-line field renders through `ContextPackText.singleLine`.
  A pack carries `ContextPackOrigin`; a review from before it decodes the
  origin its state proves. Git Diff capture reads at most 1 MB and refuses
  output that reached it.
- Agent-staged images (PNG or JPEG, at most 10 MB): `ContextImageInspector`
  decides from the bytes without decoding pixels. The part keeps kind
  `agentFileDraft` plus `image`; its text is Parley's description. Copies live
  in `context-images/<sha256>.<ext>` (`ContextImageStore`) via
  `OwnerOnlyFile`, rehashed on every read, capped at 500 MB, and collected
  when no saved review, staging pin, person hold or retained handoff keeps
  them. `parley image <sha256> --to <file>` is served only to the staging
  pane, the approved target or the target of an Ask that delivered it
  (`deliveredImages`); naming a digest grants nothing. Unknown source kinds
  decode as `.unrecognized` and are written back unchanged. At most four
  staging bodies at once (`stagingSlots`); oversize files are refused before
  they are read.
- Window capture (`WindowCapture.swift`, the only ScreenCaptureKit import) and
  the images Add Files accepts are the person's. The core learns what the open
  pack holds through `holdPersonImages`; they travel only on native Ask,
  Compare and busy-queue routes; `ContextPackFreshness` re-reads text `.file`
  parts before a send. Every chosen file goes through `BoundedRegularFile`.
  Core recovery rebuilds the core holding the pack's images.
- Delete Saved Context checks every selected revision first and refuses
  waiting or approved deliveries; Clear history removes deletable context in
  scope; deletion never follows a source path. Validation, recording,
  replacement and broadcast share one lock; approval and rejection carry the
  exact `updatedAt` and fail stale. Rendered packs stay at 90 KB, control
  bodies at 200 KB.
- Ask One Pane (`completeContextDraft`) and `parley ask --context` are
  correlated Asks: approved before any input, back to `.draft` ("Not sent")
  when refused before input, `.failed` whenever input may have begun. The
  store keeps 100 reviews, never pruning a draft, a waiting Ask or an approved
  review in delivery. After a failed send, `ContextSendRecovery` reopens the
  edits only for an unchanged draft and otherwise offers them to copy.
- Every UI request with `trackedResponseTimeout`, and every short route that
  reaches a pane (`reachesPane: true`, 45 s), runs in `Task.detached`;
  `RelayCoreClient` refuses a tracked request made from the main thread. A new
  UI route that pastes into or reads from a pane must set `reachesPane`.

## Roles and mobility

Prax notes: "Parley roles, mobility, workspace registry, all-or-nothing
lifecycle routes and external boundaries".

- Roles are owner-controlled lowercase slugs, unique per workspace:
  `@reviewer` locally, `workspace/@reviewer` across workspaces. Vendor names
  and `lead` are reserved. Never fall through from a role to a display name.
- Move preserves the exact surface, pane id, process, session, scrollback,
  credential and folder. Refuse a pane with an active handoff (the broker's
  `/handoffs/active`) or a role or lead collision; revalidate after
  confirmation. Saved layouts restore with their saved automation policy,
  validate every replaced pane first and roll back whole.
- Split trees live in `workspace-registry.json` (`WorkspaceRegistry`, at most
  200 records). Closing or replacing a workspace removes its record; a full
  registry drops the absent record unused longest.
- Every lifecycle route is all or nothing: check, save, put the document back
  if the save fails, and only then end the surface through `endSurfaceLocked`
  or `endAllSurfacesLocked`; routes that start or create roll back when the
  save fails. Closing a workspace checks every pane before ending any.

## External integration boundaries

External workspace opening accepts exactly one existing canonical directory
through `parley open`, Finder, the document role or `parley://open?folder=`.
It can focus or create a normal shell workspace. It cannot carry prompt text,
choose a vendor, start an agent or inject terminal input.

Parley publishes nothing for external editors. The attention projection
remains in process for the menu-bar indicator and reduces to coreAvailable,
totalCount and headline, never a RelayHandoff or an item label.

## Shared protocol launch behavior

Prax notes: "Parley shared protocol launch behaviour per vendor and runtime
isolation".

- Increment `AgentProtocol.version` whenever canonical semantics change.
  `ProtocolDriftChecks` pins a SHA-256 of `AgentProtocol.text` beside the
  version; pinning both is the deliberate act. A pane with a mismatched stamp
  shows **RESTART FOR PROTOCOL**. One canonical text; never handwritten
  per-vendor wording.
- Claude Code: `--append-system-prompt` plus a `--settings` file carrying the
  hooks and, when the profile allows shell execution, `permissions.allow` for
  `Bash(parley:*)` and the shim path. Codex: `developer_instructions` and
  hooks through `-c`, every string through `TOMLString.basic`
  (`CodexTOMLChecks`). Agy: generated `agent-protocol/AGENTS.md` through
  `--add-dir`, no adapter, uptake unverified; the review reads
  `~/.gemini/antigravity-cli/settings.json` (`AgyHostConfiguration`), reports
  entries rather than Agy's decision and offers Copy Allow Entry; Parley
  never writes it. Copilot: `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, only
  `shell(parley)` without confirmation, hooks through `--plugin-dir`.
- `parley help` and `parley protocol` are generated local references. Every
  launch receives `PARLEY_COMMAND`. The launch stamp is configuration
  evidence, not proof of uptake. Never overwrite another project's
  instruction files. This repository's `CLAUDE.md` is a relative symlink to
  `AGENTS.md`.

## Production and Development isolation

`ParleyRuntime` is the sole authority for Application Support, preferences,
relay transport and lifecycle permissions. The packaged app is Production. An
unbundled SwiftPM executable is Development.

Production and Development use separate state, credentials, transports,
protocol files, records and preference suites. Development never installs the
stable router, changes Production preferences or publishes Production
attention. Keep **DEV** visible in every development window and diagnostic.

Host-agent launch commands explicitly unset an inherited `PARLEY_RUNTIME`
before applying the launching app's own Development marker, if any.

Each UI owns an exclusive runtime lease. A second instance must fail closed.
There is no Development-attached-to-Production mode.

## Verification

Prax notes: "Parley verification practices, check hygiene, CI runner, release
jobs and version pins"; "Parley moved back to GitHub on 10 October 2026";
"Parley: run the suite in a local Tart VM with npm run test:vm".

- Never report work as done because it was written. Run it. For non-trivial
  logic write the failing check first, observe it fail, then make it pass.
  After changing app or core source run `npm test` and `npm run build`; for
  terminal or lifetime changes also the Ghostty soak.
- `npm run scan:public` streams `git log -p` line by line, so every rule and
  deliberate fixture must fit on one line. `npm test` also runs the platform
  dependency scan, a ratchet over which ParleyCore files may import a
  platform module; change that baseline only as a deliberate decision.
  `scripts/type-closure.mjs` and `scripts/lift-declarations.mjs` support seam
  work; after a lift, compare removed against re-added lines, because these
  types are `Codable` and persisted.
- A check leaves nothing behind outside the repository: preference domains
  have fixed names and are cleared on the way in and out; a fixture's
  transport lives inside the fixture's folder, never
  `RelayFileTransport.runtimeDirectory`.
- The checks binary has a prohibited activation policy, so a window-state step
  waits, bounded, for the fact it needs and reports the window's facts when
  the bound passes; never a fixed delay. Run such checks through `npm run
  test:vm` rather than on the desktop: input or a sleeping display during a
  run is interference, not a regression.
- Default checks never launch a vendor CLI, spend quota, touch unrelated
  processes or need the network. `--host-vendor-spike <codex>` and the Docker
  checks are explicit. CI is GitHub Actions on the hosted `macos-latest`
  runner (the repository is public, so it costs nothing; it lived on GitLab
  with a self-hosted Tart runner from 7 September to 10 October 2026). The
  runner has no Docker, so every workflow runs `npm test` as its four parts
  and passes `--skip "container bypass preflight,container follow-up image
  probe"` to the checks; a skipped check is never a passed one and `npm test`
  itself skips nothing. `test:checks` and `test:scripts` are its halves.
  External Actions are pinned to full commit SHAs (`github-security.test.mjs`).
- The **Prepare macOS draft release** workflow is manual and tag-exact,
  imports signing material into a temporary keychain, retains an unpublished
  draft and never touches the stable feed. Release workflows must pass the
  25-round eight-pane soak with its JSON report in SHA256SUMS, Developer
  ID-sign Sparkle inside-out, notarize and staple app and DMG, pass
  Gatekeeper and produce an Ed25519-signed appcast and SHA-256-pinned cask;
  missing evidence fails closed. The cask goes through a branch and pull
  request, never a direct push to main. The test-beta workflow publishes an
  unnotarized prerelease with the workflow's own token and refuses a tag
  that already has a release.

## Version policy

Never recall package or tool versions from memory. Verify the authoritative
registry at query time: the GitHub latest release API for GitHub packages,
`mise latest <tool>` for mise-managed tools.

Before changing Ghostty's wrapper pin, verify the current
`Lakr233/libghostty-spm` release and its embedded Ghostty release. Never pin
a wrapper whose Ghostty commit lacks upstream `72cf508` ("renderer: never
stop the display link while holding the draw mutex"); check with GitHub's
compare API that the pinned commit is `ahead` with `behind_by` 0. Before
changing Sparkle's pin, verify the official release and its SwiftPM artifact
digest. Keep `Package.swift`, `Package.resolved` and `THIRD_PARTY_NOTICES.md`
consistent for both.

## Repository safety

- Preserve unrelated user changes in a dirty worktree.
- Use conventional commit messages and branch instead of committing to main.
- Never force-push main.
- Before every commit, scan staged files for AWS keys, private keys, passwords
  and tokens, then run `npm run scan:public`.
- Agent commits include `Co-Authored-By: Claude <noreply@anthropic.com>`.
