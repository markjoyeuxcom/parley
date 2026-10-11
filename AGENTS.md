# Parley — engineering guide

Parley is a native macOS workbench for visible, supervised collaboration
between AI coding CLIs from different vendors. SwiftUI owns the application
surface; embedded Ghostty surfaces own the real interactive processes.

There is one implementation. All product source is under `native/`. Do not add
a web renderer, embedded browser runtime, second terminal stack, background
daemon or compatibility application.

## Rationale and history live in Prax

This file holds standing rules only. The account behind each rule (what
broke, who found it, when, which check pins it) lives in Prax, project
`parley`, tagged `engineering-notes`; each section names its notes. Recall
them before changing an area:

```bash
prax recall "<area>"                      # e.g. "Parley transport liveness"
prax recall --project parley --recent 40
```

When behaviour changes, update the rule here and refine the note in Prax
(`prax remember "<same title>" …` updates in place). Keep this file under 32
KiB: every vendor reads it on every launch and Codex stops at 32 KiB by
default. Add a rule only when an agent needs it on every turn.

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
   for a local container pane or a team's per-vendor container configuration;
   only that reviewed container launch receives the fixed vendor bypass flag.
   A vendor's own automatic reviewer is not a bypass: Claude's auto mode,
   Codex's auto review and Copilot's assisted approval keep the sandbox and
   the deny and ask rules and can refuse, so the person may select **Vendor's
   automatic reviewer** per launch or per team vendor. Agy has no reviewer,
   only a skip-all flag, so it always asks on the host. Skip-all flags stay
   forbidden.
4. **Cross-vendor first, pane-explicit.** Automatic targets are explicit agent
   panes other than the sender. Same-vendor routes require distinct panes.
   Never broadcast implicitly, target a shell through Relay/Paste/Ask, or guess
   between ambiguities. The person-approved request-run path is the sole
   exception for new human Shell execution.
5. **Visible and interruptible.** The person can see every participant and
   handoff, focus either side and stop tracked work.
6. **Local coordination.** No hosted service, sync, telemetry or remote-control
   backend. Vendor CLIs contact their own services normally.
7. **One embedded terminal stack.** Ghostty is the terminal renderer and PTY
   owner. Do not add another multiplexer, renderer or hidden terminal client.
8. **One shared protocol.** `AgentProtocol.text` solely defines the agent-facing
   commands. Launch adapters may change delivery mechanics, never wording.
9. **Honest state.** Do not infer thinking, token use, context limits, cost,
   permission state or completion from terminal text.
10. **macOS-native restraint.** System fonts, hairline rules, small radii, one
    accent, tabular numerals. No gradients, emoji or decorative AI art.

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
`scripts/run-native-swift.mjs`. Do not run `npm install` at the repository
root. `npm run test:vm` runs CI's sequence inside a local Tart VM
(`parley-dev`, cloned once from the image `.github/workflows/ci.yml` pins):
the checks open real Ghostty surfaces, menus and windows that fail on the
desktop when the person touches the Mac or the display sleeps. Prefer it for
a full run; pass npm arguments through (`npm run test:vm -- run test:checks
-- --only "pane menu"`). Normal launch never restarts a surviving pane; at
launch every agent pane is a stopped placeholder.

## Layout

```text
native/
  Package.swift, Package.resolved
  Sources/
    ParleyCore/        Foundation-only domain: AgentProtocol, Relay (broker),
                       RelayHTTPServer, Models, WorkbenchController,
                       CommandRunner, HostAgentPermissions, ManagedWorktrees
    ParleyNative/      AppModel, AppResidentCoordinationCore, ContentView,
                       GhosttyPaneRegistry, NativeTerminalHost, Sparkle bridge
    ParleyUI/          AppKit helpers (menus, editors, delivery focus)
    ParleyCoreChecks/  the checks binary (main.swift plus *Checks.swift)
    ParleySoak/        the Ghostty soak
scripts/               build, test, release and scan tooling (Node, no deps)
docs/                  container-images.md, test-scenarios.md, worktrees-roadmap.md
```

App behavior belongs in Swift. Node scripts are build and release tooling only.

## Runtime and lifetime model

Prax notes: "Parley runtime: workspaces, panes, persistence, auxiliary windows
and process exit"; "Parley durable records…"; "Parley in-process relay broker,
UI tick revision gate and transport polling"; "Parley transport liveness…";
"Parley Sparkle updates, pane creation menu, pane menus and split divider";
"Parley workspaces: folders, sidebar sections, groups and navigation…".

- Runtime files live under `~/Library/Application Support/Parley Native/`
  (Production) or a separate Development directory.
- A workspace may hold no panes; only the last workspace cannot be closed
  (`EmptyWorkspaceChecks`). A workspace is identity independent of folders:
  attachments and the New Pane Folder never grant permission or touch a
  process. Folder menus never offer a missing folder.
- Each live pane is one retained Ghostty `AppTerminalView` with its own PTY.
  `GhosttyPaneRegistry` retains views by pane id; `NativeTerminalHost` must
  return that exact view, never wrapped in a container that adopts it. Each
  pane id appears in a workspace's `NativeLayoutNode` at most once.
- `workbench-state.json` holds metadata only; terminal bytes and vendor
  conversations are never serialized. Title writes are coalesced to one per
  second; a cwd report persists only when the folder changed.
- Closing the main window keeps panes alive. Auxiliary windows are scenes on
  `AuxiliaryWindowRoot`: released when closed (no observer or timer remains),
  suspended while hidden. Quit offers Quit Parley or Cancel only; there is no
  Stop Everything. After a relaunch agent panes are stopped placeholders;
  never claim a vendor session survived.
- A pane's exit comes from Ghostty's own record (`GhosttyProcessExit`), once
  per launch generation; unreadable is unknown, never an exit. Re-check the
  reader whenever the Ghostty pin changes.
- Durable records are JSON lines: synced append, atomic compaction, durable
  before acknowledged, a failed append changes nothing in memory, a failed
  compaction is `lastError`, never a lost record. Owner-only stores write
  through `OwnerOnlyFile.write`.
- The broker is `AppResidentCoordinationCore` in the app process; no separate
  core, login item or daemon. The UI tick fetches only when `stateRevision()`
  changed, so every mutation the UI reads must `noteChangeLocked`
  (`BrokerRevisionChecks`); every input of `AppModel.statusSnapshot` must bump
  `statusInputGeneration` (`StatusSnapshotChecks`).
- Transport liveness is the per-endpoint heartbeat judged by whether its time
  changes, never against the wall clock; every age uses the injected
  `RelayTransportClocks`. Heartbeats carry the transport instance and prune
  endpoints whose capability is gone. The shim stages stdin before the request
  exists; "not running" and "could not write the request" mean nothing was
  sent.
- Sparkle is the sole updater, opt-in, never a daemon; Development never
  starts it. The Pane menu offers Shell and Agent, never one entry per vendor;
  the vendor is chosen in the creation review. Shortcuts are ⌥⌘1–5. Pane,
  sidebar, workspace and folder menus are AppKit snapshots, not live SwiftUI
  menus, with every enabled item also a VoiceOver action.
- The sidebar (`WorkspaceSidebarSections`) is built for many workspaces: This
  Workspace, Needs Attention (the menu bar's count), Pinned, Recent, All with
  groups. Groups never reach an agent. `lastSelectedAt` changes only in
  `activateWorkspaceLocked` and `createWorkspaceLocked`. Hidden-sidebar tabs
  never change place.

## Relay and consultation contract

Prax notes: "Parley relay and consultation contract…"; "Parley relay
threading, message limits, discovery, hook adapters and target rules";
"Parley reviewed Ask drafts, human Ask and Answer, link policy…"; "Parley
review loop practice and completion-evidence convention"; "Parley pane input
delivery: paste, Enter, focus and failure classification".

- `parley` uses an authenticated capability-named filesystem endpoint; the
  native UI alone uses the control socket. A caller cannot choose another
  source identity. `AgentProtocol.text` is the command reference.
- Every delivered question and delegation teaches its own exact id. `current`
  stays in the protocol but is never taught; a late answer, `done`, `done
  --file` or `progress` naming a closed item is refused with its state.
- `parley status` carries `targetTurnStarted` (protocol 34). A lost paste is
  the person's to resend: Status Center offers Ask This Again and Delegate
  This Again, never the protocol.
- Relay requests never run on the shared dispatch pool: each runs on its own
  `RelayWorkerThread` (at most 128); blocking requests count against a
  `BlockingRequestGate` of 64; `parley wait` is a 55-second long-poll.
- Text is limited to `RelayText.maximumCharacters` (100,000) after `clean`,
  which never truncates; every route refuses longer text with the real
  length, and any direct paste bypassing the broker keeps its own limit.
- Discovery exposes no credentials, folders, commands, prompts or terminal
  text. Hook adapters submit one fixed event name through the pane's
  capability; agents never run `parley signal`.
- Relay is immediate; paste is review-before-send. Targets resolve by exact
  pane id, explicit role, or vendor only when unique; refuse ambiguous,
  missing, same-pane, shell and busy targets; one unanswered consultation or
  active delegation per target. Ask and Review menus stay enabled and show
  `AskAvailability.unavailableReason`.
- A reviewed Ask keeps its draft until the broker accepts it; after a failure
  `ReviewedAskHistory.outcome` returns the draft only when no record exists,
  otherwise Copy Draft Text, so a question is never offered twice. Human Ask
  and Answer submit only after an editable preview; never capture scrollback
  implicitly. `repairNativeTerminalFocus` must do nothing while the composer
  or any editable text view is first responder.
- Clicked links go through `TerminalLinkPolicy` (http/https with a host only,
  silently ignored otherwise); Parley never opens a link on its own. Ghostty
  appearance import is explicit and allowlisted; never load a raw config.
- Challenge and Verify are native-only linked Asks, never queued. Only the
  native control route sets a verdict, at the exact revision shown. No
  separate evidence database. The review loop is guidance: add no workflow
  state machine, claim verifier or completion estimate; completion evidence
  headings are shown as AGENT-DECLARED claims.
- Delivery is one Ghostty paste then a separate Enter; never raw newlines as
  keys. `PaneInputDelivery` re-resolves the target before each input step;
  one delivery per pane at a time. Before the paste a failure is
  `refusedBeforeInput` (Retry allowed); after it, `deliveryInterrupted`.
  Delivery neither focuses nor selects the target (only Copilot briefly
  focuses) and restores focus through the target's own window. Refuse
  delivery at Copilot's folder-trust prompt until the person confirms it.

## Voice input and spoken handoffs

Prax notes: "Parley voice input and spoken handoffs: engineering notes".

- Policy types are Foundation-only in ParleyCore; Speech and AVFoundation
  stay in ParleyNative. en-GB and en-US, on-device only, no cloud fallback,
  no raw audio files. The unbundled executable refuses to record.
- Dictate is click to start, click to stop; Control-Shift-Space is hold; 60
  seconds ends recording. The draft is bound to pane, generation, vendor,
  workspace and folder; selection changes never redirect it. A potentially
  partial delivery is copy or discard only. `VoiceHandoffRequest` is
  native-control-only and changes no protocol wording.
- Read-aloud is off by default and reads only an explicit selection or
  returned result. No terminal scraping, completion inference,
  always-listening mode, spoken approval or navigation commands.

## Process and capability boundary

Prax notes: "Parley process boundary: Git read guard, signal state, bounded
waits and process sessions"; "Parley host vendor launches, Codex permissions,
profile resolution and preflight"; "Parley native control socket, pane
capabilities, ticket server and ticket policy"; "Parley PATH shim…".

- Spawn fixed executables with argument arrays. Agent-authored content must
  never be interpolated into a shell command.
- Every host Git *read* goes through `GitReadBoundary` (`ulimit -u 1` so Git
  can fork nothing, filter drivers neutralised, `diffArguments`, submodules
  ignored, inherited `GIT_*` and shell variables dropped, prompts and pagers
  off). Person-confirmed operations (worktree add, remove, prune, `branch
  -d`, Integrate) are Git itself outside the guard.
- Every spawner sets `POSIX_SPAWN_SETSIGDEF` and `POSIX_SPAWN_SETSIGMASK`.
  `ProcessCommandRunner` runs each command in its own session and signals the
  group on timeout. An unobserved exit is `unobserved` (125), never success;
  timeout is 124; every wait, including after SIGKILL, is bounded.
- Host vendor CLIs launch directly with their own permissions; never wrap them
  in Parley's Seatbelt. Host Codex takes `HostAgentPermissions`; others use
  `PermissionProfileAdapter.launchPlan`. A field on
  `PermissionProfileSelection` must be passed, required not defaulted, at
  every `PermissionProfileResolver.resolve(` call site, and reach both. Never
  present a profile intention as OS enforcement; the review's `detail` stays
  byte-identical. The Codex preflight runs off the main actor and never logs
  raw config.
- Native control: memory-only token, peer-PID checks both ways, no pane-token
  routes, fields read through pinned no-follow descriptors. `AgentProcessBoundary`
  wraps only the host Docker client. Attribution is not isolation against an
  unrestricted same-user process.
- `RelayTicketServer` issues one-use tickets (ten seconds on
  `CLOCK_UPTIME_RAW`) after verifying peer uid, pid and a parent walk to this
  app; only the app's launch root may supply `PARLEY_PANE_ID`. `RelayTicketPolicy`
  comes from observed panes: required for Claude and Copilot host panes and
  Agy, required for Codex with network and optional without, optional for a
  Claude pane with its own sandbox on, unavailable in containers. A ticket
  socket that fails to start never fails the core.
- `WorkbenchPane.launchFolder` is the reviewed agent folder; grants, roots,
  staging and captures use it, and OSC cwd reports never widen them. Parley
  never writes a vendor's settings. Transport path spelling in permission
  rules must match the shim. Apply `LANG=C.UTF-8` only when every locale
  variable is empty; strip parent multiplexer markers.

## Reviewed command runs

Prax notes: "Parley reviewed command runs: worker, approval, tickets, pane
cleanup and person proposals".

- `parley request-run` proposes exact argv in a contained folder; approval
  opens one NEW Shell pane whose fixed worker spawns argv directly, captures
  bounded output and the real status, then execs a shell. Never send input to
  an existing Shell or present output as verification. The command has no
  controlling terminal; one that needs a prompt fails and says so.
- Every box whose text is approved or sent is a `PlainTextEditor` (automatic
  substitutions off).
- Per-run approval is the default. Session trust and the Settings › General
  › Agent command runs choices are memory-only, off at every launch; never
  restore execution authority from a journal or file. Worker tickets carry a
  digest checked before decoding; read state files first, lease last. One
  active run per requester. A person-proposed run (Integrate…) is always
  pending until its preview approves it.

## Team sessions

Prax notes: "Parley team sessions: grants, provisioning, ownership, stop and
transitions".

- Nothing is authorized until the person approves the editable preview
  (objective, folder inside the lead's, vendors, profile, ≤ 8 panes, ≤ 128
  hours). The grant is memory-only and binds the full profile definition.
- Only the lead may `team add`, one at a time, idempotent by request identity;
  ownership is recorded before any mounting step; the limit counts every
  creation ever. Members cannot add panes or nest sessions. Agents choose a
  vendor, never an image, daemon, mount or bypass.
- Stop revokes the grant and stops only still-owned processes; expiry stops
  nothing. Transitions are typed with origin derived in trusted code; records
  carry correlation ids and counts only, never objectives or text. Parley
  never answers prompts or restarts a pane for an agent; unattended members
  need the vendor's automatic reviewer or a container bypass.

## Managed Git worktrees

Prax notes: "Parley managed worktrees: service, creation receipts and team
binding"; "Parley worktree cleanup policy and removal outcomes"; "Parley
Worktrees window, board, prune, delete branch, bulk removal and merge
previews". Decisions: `docs/worktrees-roadmap.md`.

- One worktree per feature or team, never per pane. Fixed `/usr/bin/git`
  argv, scrubbed environment, `--end-of-options`, bounded timeouts, no
  `--force` anywhere; branch names validated and checked with
  `check-ref-format --branch`; listings parsed on NUL; the current branch from
  `symbolic-ref --quiet HEAD`.
- Creation is bound to its preview and refuses if common dir, planned path
  (`<toplevel>/.worktrees/<slug>`) or base commit differ. Only a successful
  add from this process is a creation receipt; every other outcome is named
  and never adopted or retried. Records are metadata, never authority.
- Cleanup is person-triggered; `WorktreeCleanupPolicy.decision` is the pure
  table and refuses on nested repositories, any pane inside, dirty or
  untracked files, unpushed commits, no upstream and not merged, locked,
  prunable, unregistered, the primary checkout, a mismatched marker, anything
  unreadable, over 200 ignored entries, or any unanswerable Git question.
  `upstreamGone` and a `CACHEDIR.TAG` folder are the exceptions. Removal runs
  without `--force` under a folder reservation and reports only what the
  registry and filesystem show.
- The Worktrees window is the manager: Git's registry is the list, records
  annotate it, Prune uses Git's own dry run, Delete branch is `branch -d`
  bound to the previewed commit, Integrate proposes `merge --no-ff` by full
  ref as a reviewed command run. The board is derived, never stored; a failed
  fact read is unknown, never zero; Unused is distinct from Integrated.
- Merge previews are `merge-tree` in a private temporary repository: a
  prediction, never a verdict. Recovery never adopts a tree by branch name.
  Deferred: Parley-performed merges, rebases, pushes, automatic cleanup,
  per-pane worktrees.

## Container panes

Prax notes: "Parley container panes: review, image contract, bypass flags and
launch projection"; "Parley container lifecycle…"; "Parley container test
images on Mark's Mac (26 Sep 2026)". Recipes: `docs/container-images.md`,
`docs/parley-agents.Dockerfile`, `docs/parley-agents-fetch.sh`.

- Chosen in the permission review for any vendor, with a local image the
  person names; Parley never builds or pulls images. The probe proves the
  utility contract and `--version`, never login or instruction uptake.
- Bypass vendor permissions is the container-only exception to invariant 3;
  `ContainerLaunchProjection.bypassArguments(for:)` is the one table; bypass
  flags arriving through vendor arguments are refused; the review, badge and
  Status Center disclose it.
- argv: explicit daemon, non-root uid/gid, four exact mounts, the reviewed
  shared Git directory for a linked worktree, one private home volume
  (`volume-nocopy=true`), optional loopback `publishedPort`. Never mount the
  Docker socket, host vendor configuration or sibling endpoints. Working
  folders cannot overlap either runtime's control or transport directories;
  compare canonical realpaths first.
- A container can rewrite its mounted repository's hooks, so Parley runs no
  Git for a container pane's delegation (`DelegationGitSnapshot.notCaptured`)
  and every review states `GitReadBoundary.containerDisclosure`.
- Creation persists a stopped placeholder, then Docker work runs off the main
  actor without the workbench lock; activation re-checks generation, folder,
  workspace, policy, profile and mode. Cleanup checks daemon, full ID and
  ownership marker, never names or labels, and preserves uncertain records.
  Every stop names the generation it reviewed; Close, Stop… and bulk actions
  go through `ContainerStopSequence`, which holds panes against move. A
  failed container stop refuses the lifecycle operation. No daemon scan on
  the tick. Volumes are deleted only from Status Center › Health.
- The Docker checks (`--container-{transport,ghostty,bypass}-spike <image>`)
  are explicit and fail when prerequisites are missing; they never pass unrun.

## SwiftPM inside agent panes and terminal type

Prax notes: "Parley SwiftPM wrapper and terminal type for panes".

- SwiftPM compatibility is off by default and reaches newly started panes
  only: a `swift` wrapper adds `--disable-sandbox` to build, test, run and
  package. Never infer opt-in from being inside Parley; the repository runner
  honours `PARLEY_SWIFTPM_COMPATIBILITY=1 npm test` per command.
- Terminal type (Ghostty `xterm-ghostty` or Compatible `xterm-256color`) is
  read once per launch generation and carried as one `TERM=` word in the
  launch command, never in surface `envVars`. Parley shows, never runs, the
  `infocmp | ssh tic` remedy.

## Reviewed context boundary

Prax notes: "Parley reviewed context boundary: parts, markers, origins and
agent-staged images"; "Parley window capture, files the person adds, context
deletion and locking"; "Parley context draft sending…".

- An agent-staged part is a claim (`agentFileDraft`); only a human-authorized
  capture creates trusted provenance. Parts sit between marker lines no pack
  text contains; every one-line field renders through
  `ContextPackText.singleLine`. Git Diff capture refuses output that reached
  its 1 MB bound.
- Agent-staged images (PNG/JPEG ≤ 10 MB) are inspected from bytes without
  decoding; copies live in `context-images/<sha256>` through `OwnerOnlyFile`,
  rehashed on read, capped at 500 MB, collected when nothing holds them.
  `parley image` is served only to the staging pane or an approved target;
  naming a digest grants nothing. Unknown source kinds decode as
  `.unrecognized` and round-trip.
- Window captures and Add Files images are the person's, held through
  `holdPersonImages`, sent only on native routes. `ContextPackFreshness`
  re-reads text file parts before a send; chosen files go through
  `BoundedRegularFile`.
- Delete Saved Context refuses waiting or approved deliveries and never follows
  a source path. Approval and rejection carry the exact `updatedAt` and fail
  stale. Rendered packs 90 KB, control bodies 200 KB; the store keeps 100
  reviews, never pruning a draft, waiting Ask or approved delivery.
- Ask One Pane and `parley ask --context` are correlated Asks: `.draft` ("Not
  sent") when refused before input, `.failed` whenever input may have begun.
  `ContextSendRecovery` reopens edits only for an unchanged draft.
- Every tracked UI request, and every short route that reaches a pane
  (`reachesPane: true`), runs in `Task.detached`; `RelayCoreClient` refuses a
  tracked request from the main thread.

## Roles and mobility

Prax notes: "Parley roles, mobility, workspace registry, all-or-nothing
lifecycle routes and external boundaries".

- Roles are lowercase slugs, unique per workspace (`@reviewer`,
  `workspace/@reviewer`); vendor names and `lead` are reserved; never fall
  through from a role to a display name.
- Move preserves surface, pane id, process, session, credential and folder;
  refuse with an active handoff or a role collision. Saved layouts restore
  with their saved policy and roll back whole. Split trees live in
  `workspace-registry.json` (200 records, the absent one unused longest
  dropped when full).
- Every lifecycle route is all or nothing: check, save, roll back the document
  on failure, only then end the surface (`endSurfaceLocked`).
- External opening accepts exactly one existing directory (`parley open`,
  Finder, `parley://open?folder=`); it cannot carry prompt text, choose a
  vendor, start an agent or inject input. Parley publishes nothing for
  external editors.

## Shared protocol launch behavior

Prax notes: "Parley shared protocol launch behaviour per vendor and runtime
isolation".

- Bump `AgentProtocol.version` whenever semantics change; `ProtocolDriftChecks`
  pins a SHA-256 beside it, and pinning both is the deliberate act. A
  mismatched pane shows **RESTART FOR PROTOCOL**. One canonical text, never
  per-vendor wording.
- Claude: `--append-system-prompt` plus a `--settings` file with hooks and,
  when execution is allowed, `permissions.allow` for `Bash(parley:*)`. Codex:
  `developer_instructions` and `-c` hooks, every string through
  `TOMLString.basic`. Agy: `agent-protocol/AGENTS.md` via `--add-dir`, uptake
  unverified; the review reports its settings entries, never an outcome, and
  Parley never writes them. Copilot: `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`,
  `shell(parley)`, `--plugin-dir`.
- `parley help` and `parley protocol` are generated local references. Every
  launch receives `PARLEY_COMMAND`. The stamp is configuration evidence, not
  uptake. Never overwrite another project's instruction files. `CLAUDE.md`
  here is a relative symlink to `AGENTS.md`.
- `ParleyRuntime` is the sole authority for runtime paths. Production (the
  bundle) and Development (unbundled) use separate state, credentials,
  transports and preferences; Development never installs the stable router.
  Keep **DEV** visible. Each UI owns an exclusive runtime lease; a second
  instance fails closed.

## Verification

Prax notes: "Parley verification practices…"; "Parley moved back to GitHub on
10 October 2026"; "Parley: run the suite in a local Tart VM…"; "GitReadBoundary
fails on a Mac with full Xcode selected and a cold xcrun cache".

- Never report work as done because it was written. Run it. Failing check
  first for non-trivial logic. After app or core changes run `npm test` and
  `npm run build`; for terminal or lifetime changes also the soak.
- `scan:public` streams `git log -p` line by line, so every rule and fixture
  fits on one line. `scan:platform` is a ratchet over which ParleyCore files
  may import a platform module; change its baseline only deliberately. After
  a declaration lift, compare removed against re-added lines: these types are
  `Codable` and persisted.
- A check leaves nothing outside the repository (fixed-name preference
  domains cleared in and out; a fixture's transport inside its own folder).
  Window-state steps wait, bounded, for the fact they need; never a fixed
  delay. Run screen-touching checks through `test:vm`: interference is not a
  regression.
- Default checks never launch a vendor CLI, spend quota or need the network.
  CI is GitHub Actions on `macos-latest` (public repository, free). Workflows
  select the Command Line Tools first, run `npm test` as its four parts and
  pass `--skip "container bypass preflight,container follow-up image probe"`;
  a skipped check is never a passed one and `npm test` itself skips nothing.
  External Actions are pinned to full commit SHAs.
- Release workflows are manual and tag-exact: the test beta publishes an
  unnotarized prerelease with the workflow's token and refuses an existing
  release; the draft release signs in a temporary keychain, retains an
  unpublished draft and never touches the feed. Both need the 25-round soak
  with its report in SHA256SUMS. The cask goes through a pull request.

## Version policy

Never recall package or tool versions from memory; verify the registry at
query time. Before changing Ghostty's wrapper pin, verify the release and
never pin a wrapper whose Ghostty commit lacks upstream `72cf508` (check with
GitHub's compare API: `ahead`, `behind_by` 0). Verify Sparkle's release and
artifact digest. Keep `Package.swift`, `Package.resolved` and
`THIRD_PARTY_NOTICES.md` consistent.

## Repository safety

- Preserve unrelated user changes in a dirty worktree.
- Use conventional commit messages and branch instead of committing to main.
- Never force-push main.
- Before every commit, scan staged files for AWS keys, private keys, passwords
  and tokens, then run `npm run scan:public`.
- Agent commits include `Co-Authored-By: Claude <noreply@anthropic.com>`.
