# Parley — engineering guide

Parley is a native macOS workbench for supervised cross-vendor CLI
collaboration. SwiftUI owns the UI; Ghostty owns interactive processes. All
product code lives in `native/`. No web renderer, browser runtime, background
daemon or second app.

## Rationale and history live in Prax

Keep only standing rules needed on every turn here, under 32 KiB. Start a
session with the project card, then recall the area you are changing: its
rationale and history are in Prax project `parley`, tag `engineering-notes`,
and each section names its notes.

```bash
prax overview --project parley
prax context --budget 1200
prax recall "<area>"
```

When a note informed the work, run `prax used <id>`. When behaviour changes,
update the rule here and its Prax note in place with `prax remember "<same
title>" …`; retire a replaced note with `prax supersede`.

## Product boundary

Vendors own their models, authentication, tools, permissions and conversation
interfaces. Parley owns panes, workspaces, attributed handoffs, correlated
consultations and supervision. A feature belongs here only if it coordinates
vendors or makes their coordination visible, safe or recoverable; work one CLI
can do alone belongs to that vendor.

## Product invariants

1. **Subscription CLIs only.** Use vendor binaries installed on the host or
   in a person-reviewed local container image, with the person's vendor login.
   Never add API keys or a direct model API path.
2. **Real interactive sessions.** Preserve each CLI's TUI, prompts, permission
   flow and session behavior. Parley does not replace them with a chat UI.
3. **Host approvals; reviewed container bypass.** Host launches never pass
   `--dangerously-*`, `danger-full-access` or equivalent bypass flags. Fixed
   bypass flags require the person's explicit selection of container bypass
   for a pane or team vendor. Per launch or team vendor, the person may select
   **Vendor's automatic reviewer**: Claude auto mode, Codex auto review or
   Copilot assisted approval. These retain vendor sandboxes, deny and ask
   rules and refusal. Agy always asks on the host; it has no reviewer. Host
   skip-all flags remain forbidden.
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

Root npm scripts use the dependency-free `scripts/run-native-swift.mjs`; never
run `npm install` here. The Command Line Tools must stay enough to build:
libghostty-spm stays pinned at 2.2.2026100501, the last release without the
xcstrings resource that needs Xcode's `xcstringstool`, until
Lakr233/libghostty-spm#81 is resolved. Prefer `npm run test:vm` for full checks. Its local
Tart VM `parley-dev` is cloned once from `.github/workflows/ci.yml`'s pinned
image, and it runs only from the primary checkout, one run per VM at a time.
Pass npm arguments through, e.g. `npm run test:vm -- run test:checks -- --only
"pane menu"`.

## Layout

```text
native/Sources/
  ParleyCore/        Foundation-only domain
  ParleyNative/      SwiftUI app, retained Ghostty surfaces, coordination, Sparkle
  ParleyUI/          AppKit helpers
  ParleyCoreChecks/  checks binary
  ParleySoak/        Ghostty soak
scripts/             dependency-free Node build/test/release/scan tooling
docs/                engineering guides
```

App behavior belongs in Swift. Node scripts are build and release tooling only.

## Runtime and lifetime model

Prax notes: "Parley runtime…"; "Parley durable records…"; "Parley in-process
relay broker…"; "Parley transport liveness…"; "Parley Sparkle updates…";
"Parley workspaces…".

- Runtime files live under `~/Library/Application Support/Parley Native/`
  (Production) or a separate Development directory.
- A workspace may hold no panes; only the last workspace cannot be closed. A
  workspace is identity independent of folders: attachments and the New Pane
  Folder never grant permission or touch a process. Folder menus never offer
  a missing folder.
- Each live pane is one retained Ghostty `AppTerminalView` with its own PTY.
  `GhosttyPaneRegistry` retains views by pane id; `NativeTerminalHost` must
  return that exact view, never wrapped in a container that adopts it. Each
  pane id appears in a workspace's `NativeLayoutNode` at most once.
- `workbench-state.json` holds metadata only; terminal bytes and vendor
  conversations are never serialized. Title writes are coalesced to one per
  second; a cwd report persists only when the folder changed.
- Closing the main window keeps panes alive. Release auxiliary scenes on
  close (including observers and timers); suspend them while hidden. Quit
  offers only Quit Parley or Cancel. Relaunch leaves agents as stopped
  placeholders; never claim their sessions survived.
- A pane's exit comes from Ghostty's own record, once per launch generation;
  unreadable is unknown, never an exit. Re-check the reader whenever the
  Ghostty pin changes.
- Durable records are JSON lines: synced append, atomic compaction, durable
  before acknowledged, a failed append changes nothing in memory, a failed
  compaction is `lastError`, never a lost record. Owner-only stores write
  through `OwnerOnlyFile.write`.
- The broker stays in the app process; no separate core, login item or
  daemon. The UI tick fetches only when `stateRevision()` changes.
  UI-visible mutations must `noteChangeLocked`; inputs to
  `AppModel.statusSnapshot` must bump `statusInputGeneration`.
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
- Sidebar sections: This Workspace, Needs Attention (menu-bar count), Pinned,
  Recent, All with groups. Groups never reach agents. `lastSelectedAt`
  changes only in `activateWorkspaceLocked` and `createWorkspaceLocked`.
  Hidden-sidebar tabs never move.

## Relay and consultation contract

Prax notes: "Parley relay and consultation contract…"; "Parley relay
threading…"; "Parley reviewed Ask drafts…"; "Parley review loop practice…";
"Parley pane input delivery…".

- `parley` uses an authenticated capability-named filesystem endpoint; the
  native UI alone uses the control socket. A caller cannot choose another
  source identity.
- Every delivered question and delegation teaches its own exact id. `current`
  stays in the protocol but is never taught; a late answer, `done`, `done
  --file` or `progress` naming a closed item is refused with its state.
- `parley status` carries `targetTurnStarted`. A lost paste is the person's
  to resend: Status Center offers Ask This Again and Delegate This Again,
  never the protocol.
- Relay requests never run on the shared dispatch pool: use at most 128
  dedicated worker threads and 64 concurrent blocking requests; `parley wait`
  is a 55-second long-poll.
- Text is limited to `RelayText.maximumCharacters` (100,000) after `clean`,
  which never truncates; every route refuses longer text with the real
  length, and any direct paste bypassing the broker keeps its own limit.
- Discovery exposes no credentials, folders, commands, prompts or terminal
  text. Hook adapters submit one fixed event name through the pane's
  capability; agents never run `parley signal`.
- Relay is immediate; paste is review-before-send. Targets resolve by exact
  pane id, explicit role, or vendor only when unique; refuse ambiguous,
  missing, same-pane, shell and busy targets; one unanswered consultation or
  active delegation per target. Keep Ask and Review menus enabled and show
  the unavailability reason.
- A reviewed Ask retains its draft until broker acceptance. After failure,
  offer the draft only if no record exists; otherwise offer Copy Draft Text.
  Human Ask and Answer require an editable preview; never capture scrollback
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

Prax notes: "Parley voice input and spoken handoffs…".

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

Prax notes: "Parley process boundary…"; "Parley host vendor launches…";
"Parley native control socket…"; "Parley PATH shim…".

- Spawn fixed executables with argument arrays. Agent-authored content must
  never be interpolated into a shell command.
- Every host Git read uses `GitReadBoundary`: the real Git behind the
  `/usr/bin/git` shim resolved outside the guard (`realGit`, filesystem
  only), `ulimit -u 1`, neutralised filter drivers, `diffArguments`, ignored
  submodules, scrubbed `GIT_*` and shell variables, no prompts or pagers. Person-confirmed worktree add,
  remove and prune, `branch -d` and Integrate run Git outside the guard.
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

Prax notes: "Parley reviewed command runs…".

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

Prax notes: "Parley team sessions…".

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

Prax notes: "Parley managed worktrees…"; "Parley worktree cleanup policy…";
"Parley Worktrees window…"; "Parley worktrees roadmap…" (decisions).

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

Prax notes: "Parley container panes…"; "Parley container lifecycle…";
"Parley container test images…". Recipes: `docs/container-images.md`,
`docs/parley-agents.Dockerfile`, `docs/parley-agents-fetch.sh`.

- Chosen in the permission review for any vendor, with a local image the
  person names; Parley never builds or pulls images. The probe proves the
  utility contract and `--version`, never login or instruction uptake.
- `ContainerLaunchProjection.bypassArguments(for:)` is the sole bypass table.
  Refuse bypass flags in vendor arguments; disclose the mode in the review,
  badge and Status Center.
- argv: explicit daemon, non-root uid/gid, four exact mounts, the reviewed
  shared Git directory for a linked worktree, one private home volume
  (`volume-nocopy=true`), optional loopback `publishedPort`. Never mount the
  Docker socket, host vendor configuration or sibling endpoints. Working
  folders cannot overlap either runtime's control or transport directories;
  compare canonical realpaths first.
- Never run Git for container-pane delegations (`.notCaptured`); every
  container review must state `GitReadBoundary.containerDisclosure`.
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

Prax notes: "Parley SwiftPM wrapper and terminal type…".

- SwiftPM compatibility is off by default and reaches newly started panes
  only: a `swift` wrapper adds `--disable-sandbox` to build, test, run and
  package. Never infer opt-in from being inside Parley; the repository runner
  honours `PARLEY_SWIFTPM_COMPATIBILITY=1 npm test` per command.
- Terminal type (Ghostty `xterm-ghostty` or Compatible `xterm-256color`) is
  read once per launch generation and carried as one `TERM=` word in the
  launch command, never in surface `envVars`. Parley shows, never runs, the
  `infocmp | ssh tic` remedy.

## Reviewed context boundary

Prax notes: "Parley reviewed context boundary…"; "Parley window capture…";
"Parley context draft sending…".

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

Prax notes: "Parley roles, mobility…".

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

Prax notes: "Parley shared protocol launch behaviour…".

- Change `AgentProtocol.version` and the SHA-256 in `ProtocolDriftChecks`
  together when semantics change. Mismatched panes show **RESTART FOR
  PROTOCOL**.
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

Prax notes: "Parley verification practices…"; "Parley moved back to GitHub…";
"Parley: run the suite in a local Tart VM…"; "GitReadBoundary fails…".

- Never report work as done because it was written. Run it. Failing check
  first for non-trivial logic. After app or core changes run `npm test` and
  `npm run build`; for terminal or lifetime changes also the soak.
- Keep `scan:public` rules and fixtures on one line. Deliberately maintain the
  `scan:platform` ratchet over platform imports in ParleyCore. After
  declaration lifts, compare removed and re-added lines to preserve persisted
  `Codable` types.
- A check leaves nothing outside the repository (fixed-name preference
  domains cleared in and out; a fixture's transport inside its own folder).
  Window-state steps wait, bounded, for the fact they need; never a fixed
  delay. Run screen-touching checks through `test:vm`.
- Default checks never launch a vendor CLI, spend quota or need the network.
  CI is GitHub Actions on `macos-latest`, on the image's default Xcode.
  Workflows run `npm test` as its four parts and pass `--skip "container
  bypass preflight,container follow-up image probe"`; a skipped check is
  never a passed one and `npm test` itself skips nothing. External Actions
  are pinned to full commit SHAs.
- Release workflows are manual, dispatched from the version tag they name,
  and preflight the tag, notes and existing release before any expensive
  step. The test beta publishes an unnotarized prerelease with the workflow's
  token; the draft release runs in the `release-signing` environment, signs
  in a temporary keychain removed unconditionally, retains an unpublished
  draft and never touches the feed. Both need the 25-round soak with its
  report in SHA256SUMS. The cask goes through a pull request.

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
