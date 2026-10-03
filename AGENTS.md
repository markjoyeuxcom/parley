# Parley — engineering guide

Parley is a native macOS workbench for visible, supervised collaboration
between AI coding CLIs from different vendors. SwiftUI owns the application
surface; embedded Ghostty surfaces own the real interactive processes.

There is one implementation. All product source is under `native/`. Do not add
a web renderer, embedded browser runtime, second terminal stack, background
daemon or compatibility application.

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
   between ambiguities. The person-approved request-run path below is the sole
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
```

The root npm scripts are a dependency-free runner around
`scripts/run-native-swift.mjs`. Do not run `npm install` at the repository root.
The helper chooses a compatible installed macOS SDK and writable Swift caches.

Normal launch must never restart a surviving in-app pane. There is no launch
option that restarts stale-protocol panes: panes live inside the app, so at
launch every agent pane is a stopped placeholder and none can be stale.
The `dev:restart-protocol` script and its launch flag did nothing for that
reason and were removed on 29 September 2026.

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

## Runtime and lifetime model

Runtime files are under `~/Library/Application Support/Parley Native/` for
Production and a separate Development directory.

- A workspace is a named collaboration container. It may hold no panes
  (Mark's decision on 14 September 2026): New Workspace creates none, closing
  the last pane leaves the workspace with its attachments, New Pane Folder
  and history, and moving the last pane out empties the source. The gestures
  that ask for a place to work, a fresh install and Open Folder, still seed
  one shell (`createWorkspaceLocked(initialShell:)`). Only the last workspace
  cannot be closed, and only a saved document with no workspaces is a fresh
  workbench; one with workspaces and no panes reloads as it was. The empty
  state offers New Shell and New Agent…; `EmptyWorkspaceChecks` pins the
  rules.
- Each live pane is one retained Ghostty `AppTerminalView` with its own PTY and
  shell or vendor CLI process.
- `WorkbenchController` persists workspace/pane metadata in
  `workbench-state.json`; terminal bytes and vendor conversations are never
  serialized there. Terminal titles are the one hot input: a title is applied
  in memory at once (a repeated title changes nothing durable but still
  stamps pane activity), written at most once per second by a coalesced
  deferred write, and carried immediately by any other persist, stop, close
  or shutdown. Attach, detach and close callbacks persist synchronously and
  run the full model refresh as before; a title change only publishes the
  pane list once per run-loop turn with no relay fetch or layout work,
  because no view renders titles today. A working-directory report persists
  and refreshes only when the folder changed: shells report it at every
  prompt, and until 29 September 2026 each one rewrote the state file and
  refreshed the model; an unchanged one only stamps activity in memory.
- `GhosttyPaneRegistry` retains views by pane id across SwiftUI remounts and
  main-window hiding. `NativeTerminalHost` returns that exact retained view as
  its representable's view. Do not wrap it in a container that adopts the
  surface as a subview: the registry hands the same `AppTerminalView` to every
  host that asks for the pane, SwiftUI builds a new host before dismantling the
  old one during a layout change, and the old host then tears the surface out of
  its new parent and hides it. v0.1.35 shipped that regression — every existing
  pane went black when a new one opened, leaving only the newest drawing. A pane
  whose surface was briefly unavailable therefore keeps its placeholder until
  its launch generation changes; fixing that must not reintroduce shared-view
  reparenting.
  The same class appears if a layout names one pane twice, so each pane id
  appears in a workspace's `NativeLayoutNode` at most once: `inserting` moves
  a leaf that is already there, and `reconciled` keeps each leaf's first
  place, which also repairs a stored tree at launch. Until 23 September 2026
  a team container member, reconciled in by the one-second refresh while its
  Docker preparation was awaited, was then inserted again beside the lead.
- Closing/hiding the main window keeps panes and coordination alive while the
  application remains running.
- Auxiliary windows (Status Center, Help, About, Settings) are
  `Window`/`Settings` scenes, which SwiftUI hides on close and keeps alive.
  Each scene's root is `AuxiliaryWindowRoot` (ParleyUI): it observes no
  model state and follows `AuxiliaryWindowPresence.next`, a per-window
  transition driven by AppKit window notifications because `onDisappear`
  never fires for a hidden scene window. Closed or ordered out is
  `released`: the view is destroyed, so no observer, timer, `TimelineView`
  or layout work remains, and reopening builds it fresh (filters and toggles
  reset; selection lives in the model). A request that selects something in
  a window (`requestedHelpTopicID`, `requestedStatusHandoffID`) is consumed
  once applied; Help's never was, so asking for the same topic again did
  nothing and every later plain opening jumped back to it (until 29 September
  2026). A Status Center scope change keeps a selected handoff the new scope
  still shows (`StatusCenterSelection.afterScopeChange`): "show this handoff"
  widens the scope and selects it in one update, and the scope's change
  handler used to clear it. Minimising or hiding the application
  suspends only a window that was on screen; a released window stays
  released through a global hide/unhide because that notification reaches
  closed windows too. `suspended` keeps the view and its
  unapplied drafts (for example Settings font choices), while the
  `auxiliaryWindowActive` environment turns false so the content's
  `WindowRefreshClock` stops and its once-a-second labels become static.
  Those clocks run in `MenuTrackingRefreshPolicy.runLoopMode`, owned by the
  mounted content and invalidated with it. The placeholder shown while
  released carries the same minimum frame as the content.
- Closing a pane or workspace explicitly ends its processes.
- Prepare to Uninstall and confirmed full quit end every pane process and the
  coordination core. There is no separate Stop Everything action: the
  quit-time choice was removed in the 30 August 2026 native cutover, and the
  quit dialog offers Quit Parley or Cancel only. One pane ends when the person
  exits its CLI, chooses Stop… in its menu (a started agent pane; since 1
  October 2026, `AppModel.stop`: container cleanup through
  `performAfterContainerStops`, then `stopPaneProcess` with the reviewed
  generation, leaving a stopped placeholder), closes it or restarts it; a
  container pane can also be stopped from Status Center > Health > Containers. Help, README, INSTALL and the
  protocol text described the removed item for two weeks; do not reintroduce
  the name without the button. `shutdown` checks every container first,
  saves every pane stopped, and ends the surfaces only once that is durable;
  a refusal changes nothing and the app stays open with its panes (until 29
  September 2026 it ended every surface first, so a state file or credential
  store that could not be written left Parley open with every pane gone).
- On a later app launch, workspace definitions remain, shells can restart and
  agent panes are stopped placeholders. Never claim a vendor session survived.
- A pane's exit is recorded from Ghostty's own record of it
  (`ghostty_surface_process_exited`, read by `GhosttyProcessExit` in
  ParleyUI), polled on the one-second tick and routed through the same path
  as Ghostty's close callback, once per launch generation
  (`ProcessExitTracker`). The pane then reads exited, relay and input turn
  off, and a container pane's lost-client cleanup runs. Wait-after-command
  keeps the surface open, so until 23 September 2026 Ghostty's close
  callback (sent only when the person pressed a key in the exited pane) was
  the sole record: after `/exit`, or a CLI missing from PATH, the pane stayed
  RUNNING with relay enabled. The wrapper forwards neither
  `GHOSTTY_ACTION_SHOW_CHILD_EXITED` nor this call, so the raw surface is
  read by reflection from its one private field; `ProcessExitChecks` runs
  the reader on real surfaces so a wrapper upgrade that moves the field
  fails the suite, and an unreadable record is unknown, never an exit. Check
  it again whenever the Ghostty pin changes. No exit status is available
  through this route.

Durable records are JSON lines. The handoff journal and the native activity
journal both append one synced line per record and compact the bounded file
atomically only past eight times their bound, on removal, on any retention
change that leaves pruned lines on disk (so a larger bound never reads pruned
history back) or when a truncated tail is repaired at load; a record is
durable before it is acknowledged, a failed append changes nothing in memory
and truncates the file back to the committed boundary, an append whose
partial bytes cannot be cut away marks the tail uncertain so every later
append first rewrites the acknowledged projection or refuses, and a
compaction failure after a durable append is retained as `lastError` and
surfaced through the Status Center core-health route until the next
successful compaction, never reported as a lost record. The handoff journal's
`record()` is the one non-durable write (a relay that reached a live terminal
keeps its in-memory projection when the append fails); a failed append
marks the file behind the projection, so the next write rewrites the whole
projection before `lastError` clears (until 28 September 2026 the next
append cleared the error and the lost record was never written). A durable
append whose maintenance compaction failed is not behind: later appends keep
working, since a nearly full disk has room for a line, not for the whole
projection. Every
owner-only store writes through `OwnerOnlyFile.write`: created 0600 under a
temporary name, written, `fsync`ed and only then renamed into place. They
used to `Data.write(.atomic)` and `chmod` after the rename, so the file (the
relay credentials included) was briefly 0644 and never synced, and a crash in
that moment or a torn file after power loss was refused by the store's own
owner-only check at the next launch (4b656187). Pane attention is projected once per input generation
(panes plus every handoff collection) through `PaneAttentionCache`; process
sampling for Status Center's Health section runs on one serial owner off the
main actor, only while that section is mounted in an active window, and
publishes a result only when it is the newest request and the sampled pane
set (id plus launch generation) is unchanged.

The relay broker lives in `AppResidentCoordinationCore` inside the application
process. It owns the authenticated UI control socket, capability filesystem
transport, consultations and durable records. There is no separate core
executable, login item or background process. `core.pid` contains the app PID
while coordination is live. The UI still reads relay state through the
control socket, but its one-second tick first asks the in-process broker for
`stateRevision()`, which every mutation of what the tick reads advances
(`noteChangeLocked` at each broadcast site plus read marks, busy drafts and
activity); an unchanged revision skips the five round trips, and
`RelayPollPolicy` forces a fetch every fifteen ticks as a safety net.
Status Center's two-second history fetch (500 handoffs and 500 activity
records) takes the same gate, recording a revision only for history it
applied and forgetting it wherever the tick forgets its own (a broker built
by core recovery counts from zero again). Its snapshot is cached per scope (workspace, dismissed shown) and
`statusInputGeneration` (`StatusSnapshotCache`), because the body reads it
about twenty times per render and once more per row, and each read used to
sort every handoff and timeline event (02e8932f, 26 September 2026). Every
value `AppModel.statusSnapshot` passes to the projection must bump that
generation in its `didSet`, or Status Center shows stale work;
`StatusSnapshotChecks` reads AppModel's source and fails on an input that
does not. Both gates trust the broker to advance its revision on every change
the UI reads; two changes did not until 27 September 2026 (Agy's review of
MR !111): a retry refused because its source or target pane had gone, which
marks the handoff failed with target-unavailable attention, and the
delegation-time Git facts attached in the second locked section of
`handleDelegate`. `BrokerRevisionChecks` pins both. The agent file transport polls each endpoint inbox every 50 ms while requests
are flowing and backs off to 250 ms after ten quiet ticks
(`TransportPollSchedule`), with a vnode watcher per inbox that wakes it at
once on a write, so an idle app neither scans inboxes twenty times a second
nor makes an agent wait on the backed-off timer. The check counts the ticks
the watcher runs itself (`watcherTickCount`). That is ticks begun, not
requests claimed: a request written in place is often claimed by the next
fast tick the wake brings forward, which is the guarantee. It compares idle with active
latency on the same run, never against a fixed bound. A CPU-starved CI VM
made every request take about 120 ms, idle and active alike, and failed a
fixed 100 ms bound; this was reproduced under `taskpolicy -b` on 3 October
2026 (Prax 24e184f8).

Liveness is the endpoint's `heartbeat` file, rewritten once a second, and it
must survive sleep and clock changes (26 September 2026, 117580ad). On 23
September a `parley wait` failed with "stopped before replying" the second
the Mac woke: the wall clock had moved on before the transport's timer ran,
and the shim read one stale heartbeat as a stopped broker. The shim now
treats a stale or missing heartbeat as a reason to wake the transport, by
making and removing a hidden entry in its own inbox so the watcher runs a
tick at once, and reports the broker stopped only after about five seconds
of readings in a row; a vanished endpoint is final at once. Before sending,
a refusal still means nothing was written, and a heartbeat seen to change
counts as running even when it is not recent by the shim's clock. While
waiting for a reply, the shim follows only whether the heartbeat's time
changes between readings a second apart, never how it compares with
`date`: a container's VM clock can disagree with the Mac that wrote it,
and after a clock stepped back a dead broker's future-dated heartbeat read
as fresh forever (Agy's review of MR !110). App Nap is not disabled: that
inbox wake is an event, not the timer App Nap holds back.
Every age the transport compares uses a clock chosen for it, never a wall-clock
difference: a heartbeat is due by `CLOCK_MONOTONIC`, which counts through
sleep and never steps back (a backward step used to stop every heartbeat
until the clock caught up); a request still being written ages on
`CLOCK_UPTIME_RAW`, which stops during sleep, so a shim frozen part-way gets
its full 30 seconds after a wake; and an uncollected reply, old by its file
time, is removed only after it has also stayed stale for up to 30 seconds of
awake time, because after a long sleep every reply looks old and a `parley
wait` whose reply was deleted polled for it forever. All three clocks are
injected as `RelayTransportClocks`, so `TransportLivenessChecks` models a
sleep (wall and monotonic jump, awake time does not) and a clock step (wall
alone moves). `stop()` cancels the watchers inside a barrier on the
transport's queue and every tick returns once the transport is stopped: a
tick already running used to write a heartbeat after `stop()` removed it,
so shims read a stopped transport as alive. Heartbeats are written per
endpoint, so one pane that broke its own (a container can put a directory
in its place) cannot stop the others'. `post` runs in a pipeline subshell,
where the script's `EXIT` trap never fires in macOS `sh` or dash, so the
shim cleans up its own request before reporting "stopped before replying";
a broker that comes back must not act on a request the agent was told had
failed. What a shim killed part-way leaves, the transport removes (a request
with no `ready` after 30 seconds of awake time, a reply after ten minutes,
the whole endpoint when its pane restarts); the script's top-level `EXIT`
trap never did anything and is gone. Each heartbeat's content is the
transport instance, new on every `start()`: a restart (core recovery)
discards the requests shims are still waiting on, and a request leaves the
filesystem while it is processed, so a shim that sees a different instance
cleans up and reports "restarted before replying" instead of waiting forever
(0b58a71e, 27 September 2026; the container transport check hung this way,
with an empty endpoint, when the Linux VM still showed a heartbeat `stop()`
had removed and the shim sent into the stopped transport). The shim reads
stdin into a hidden `.body-<id>` in its inbox before the request folder
exists, and copies it in once the request is written (`mv` is not in the
container utility contract): a producer slower than the 30-second
abandonment age used to lose the folder it was still filling (review of 22
September, db7c3b52). Liveness is checked before stdin is read (with no
broker, an endless producer used to be read forever) and, when the transport
instance has changed or gone meanwhile, again after it. A heartbeat with no
readable instance is not yet a running broker: the instance is the baseline
a restart is noticed by. A request still in the inbox when a new instance
appears was written after that transport discarded the old ones, so the shim
keeps waiting; otherwise "restarted before replying" says delivery is
unknown, because an old worker may have finished first. Every write before
`ready` is checked, and a refusal removes the staged body, so "not running"
and "could not write the request" still mean nothing was sent. `start()`
leaves hidden inbox entries, a live shim's scratch, to that shim, and keeps
finished replies (`ready` present) for the shim still waiting on them. Once a
second the transport removes scratch whose modification time has not
changed for the reply age in awake time: a producer still writing keeps
changing its staged body, and a killed shim's body and wake entries are
otherwise never listed by the tick. A producer silent for longer than that
loses its staged body and the command refuses cleanly ("could not write the
request, so nothing was sent"), a deliberate trade against scratch that
would otherwise wait for its pane to restart. `post` traps INT, TERM and HUP
and cleans up before exiting, so Ctrl-C or a tool timeout removes the staged
body at once (checked under macOS `sh` and, for the pattern, dash); a signal
already ignored when the shim starts cannot be trapped, and the sweep covers
that case (Agy's review of MR !112).

Every start or restart rotates a pane's capability and prepares a new
endpoint, and every stop or close forgets it. Until 26 September 2026
(f658a60c) only the transport's `start()` removed endpoints, so a long session
kept every retired one, heartbeated and watched each second, and the listing
of the first 256 could start dropping live panes. Each heartbeat now prunes
endpoints whose capability is no longer stored. The folders are listed
before the capabilities are read: an endpoint is prepared only after its
capability is stored, so a pane starting at that moment is never pruned.
Capabilities that cannot be read prune nothing. `start()` uses the same
prune, and removes leftover exchange files entry by entry, so something a
pane left that cannot be removed no longer stops the coordination core.

Sparkle.framework is the sole application-update mechanism. Its bundled helper
processes may run transiently only during an explicit update check or
person-approved installation; they are not a Parley daemon, coordination core
or login item. Development must never start Sparkle or receive the Production
feed. Production automatic checking is opt-in, background installation is
disabled and updater-initiated termination must pass through the ordinary
pane-aware quit confirmation. The manual release check (Compatibility &
Releases) is cancelled when the channel changes and publishes only a result
for the channel still selected; a Beta check finishing after a switch to
Stable used to show under Stable. Its sheet closes with Done (Escape); it
had no way to close before 29 September 2026.

Creating a pane: the toolbar's Pane menu offers **Shell** and **Agent**, each
with the same six split-and-folder items (`PaneCreationMenu`), never one
entry per vendor (Mark's decision on 14 September 2026, after the launch
review became the one form for the whole launch). A shell opens at once. An
agent opens the permission review, whose **Vendor** row, shown only for a
creation review, is where the vendor is chosen; changing it re-derives the
remembered profile default, resets an approvals choice Agy cannot honour and
discards a checked image, whose probe was for the previous vendor. The
Agent entry and Pane › New Agent Pane… (⌥⌘N) preselect
`AppModel.lastAgentVendor`, the vendor of the last creation review that
started a pane (a preference, Claude until then); the New Claude, Codex, Agy
and Copilot Pane items (⌥⌘1, 2, 3 and 5; New Shell Pane is ⌥⌘4, from
`PaneCreationShortcut`) open the same review with their
vendor preselected. They were ⇧⌘1–5 until 23 September 2026, and macOS
takes ⇧⌘3, 4 and 5 for screenshots before any application sees them;
`PaneShortcutChecks` keeps them clear of `SystemReservedShortcut` and of
Parley's own key monitor. `PanePermissionRequest.kind` is mutable for that reason
and the request id is unchanged, so the model still recognises the review.
Restart, resume and folder-access reviews have no Vendor row: a pane cannot
change vendor.

The pane header's ellipsis uses `PaneActionsMenu`, backed by the same
`ToolbarActionMenu` AppKit snapshot as the toolbar menus. Each opening keeps
its item tree and captured workspace destinations until it closes; terminal
callbacks can still publish model changes while a menu tracks, even with the
periodic timer paused. A live SwiftUI menu rebuilt its items during those
updates and disrupted Move to Workspace. The sidebar right-click and
Control-click menu uses `PaneContextMenu` with the same native item builder
and shared action definition. Ordinary input passes through its transparent
overlay; moving still revalidates the pane and destination by id. The
workspace rows (sidebar and tab strip) and the attached and favourite folder
rows use the same overlay through `snapshotContextMenu`, which also names every
enabled item as a VoiceOver action (`ToolbarMenuAccessibility`), because the
overlay is not in the accessibility tree and workspaces have no other route to
their actions; the activity history is a `ToolbarActionMenu` whose items are
built when it opens. All four were live SwiftUI menus until 29 September 2026.
A disabled destructive item is drawn disabled, not red. The New Pane Folder
menu, the workspace creation "+" and the notices' "+N" remain SwiftUI menus.

A split divider pushes the resize cursor once on hover and pops it once
(`ResizeCursorHold`): when the pointer leaves, zoomed or not, when a pane is
zoomed, and when the divider disappears under the pointer, which sends no
hover end. The pop used to sit behind the zoom check, so zooming with the
pointer on a divider left a resize arrow over the terminals. The hold is a
class in `@State`, so a hover changes no observed state and does not redraw
the terminals beside the divider.

A workspace is durable identity independent of folders. It may have zero or
more explicit folder attachments used for opening and search, plus an optional
independently mutable New Pane Folder. Existing panes retain their live folders;
attachment changes never grant permission or mutate a process. Several
workspaces may intentionally attach the same canonical folder. Folder opening
focuses one match, asks on several or creates a normal folder-backed shell
workspace on none. New Workspace creates a folderless container with a safe
shell cwd that is not silently attached. Starting an unbound agent requires an
explicit working folder and permission review. The New Pane Folder menu offers
favourites and the automatic recent history, but never a folder that no
longer exists (`FolderListMaintenance`): recent history is pruned of missing
folders at load and on every addition, favourites are the person's bookmarks
and are only reported as missing, and **Manage Folders…** lists both with
full paths, a MISSING mark, Use and Remove per entry and Clear Recent.
Removing an entry forgets it; nothing on disk changes. Views compare and
check folders through `AppModel.folderIdentity` (`FolderIdentityMemo`), which
remembers each canonical spelling and existence answer for five seconds of
uptime and forgets them on every explicit refresh (`refresh()` after a
mutation, not the once-a-second tick), so a folder Parley's own action
created or removed is read again at once: the sidebar used to realpath every
favourite against every workspace attachment, and stat each favourite and
recent folder, on every render. Actions such as toggling a favourite still
decide from the disk (`isFavouriteFolder`).

The sidebar is built for many workspaces (Mark's decision on 30 September
2026, Prax 9dd56387). It used to be one flat list with every workspace's
folders open, and the active workspace's panes came after all of them. Its
sections, from `WorkspaceSidebarSections`, are:
- **This Workspace:** the active workspace's panes.
- **Needs Attention:** other workspaces whose `needsPerson` count is above
  zero, most first, hidden when empty. The count is the menu bar's own
  (`ExternalAttentionProjection`), so the two never disagree. An unread
  result counts until it is read. A failed, interrupted or waiting handoff
  counts until the person opens it in Status Center and for at most a day
  (`acknowledgementWindow`, Mark's decision). Before, it counted until
  retention dropped it, because only results could be marked read, so both
  filled with old failures. `markHandoffRead` now also accepts a failure or
  request (`canBeAcknowledged`), and `readAt` records when it was seen.
  Selecting one in Status Center marks it (`awaitsAcknowledgement`). The
  index is computed again once the soonest counted item passes its day
  (`nextChangeAt`).
- **Pinned:** workspaces with `WorkbenchWorkspace.pinned`, in the workspace
  order. A drag there is mapped onto the whole order by `subsetMove`.
- **Recent:** up to five others by `lastSelectedAt`, shown only past eight
  workspaces. Never the current workspace, a pinned one or one already in
  Needs Attention.
- **All Workspaces:** every workspace, open by default only at eight or
  fewer, with attached folders collapsed.

`lastSelectedAt` is set only by `activateWorkspaceLocked`, the one place that
changes which workspace is active, and by `createWorkspaceLocked`, on both
the workspace left and the one entered. It lives in the document, so a
rolled-back change takes it with it; `selectWorkspace`, `selectPane` and
`setWorkspacePinned` roll back a failed save. A workspace replaced by a saved
layout is a new workspace, and it takes over the replaced one's pin. The badges and counts come from
`WorkspaceActivityProjection`, one pass over the handoffs cached per
attention input generation (which `workspaces` now advances). The four
per-workspace helpers used to scan every handoff each, several times per row
per render.

Workspace groups (MR 2 of the same task) organise All Workspaces:
- **Storage:** a `WorkspaceGroup` (id, name, `isCollapsed`) lives in the
  document's optional `workspaceGroups`, in the person's order, and
  `WorkbenchWorkspace.groupID` names a workspace's group. State written
  before groups decodes with none.
- **Ungrouped:** a workspace with no group, or with a group that no longer
  exists, is Ungrouped. Deleting a group therefore only clears its members'
  `groupID`; it closes nothing.
- **Names:** trimmed, one line, at most 64 characters, and unique ignoring
  case (`WorkspaceGroup.validatedName`). "Ungrouped" is reserved for the
  sidebar's own row. Only true control characters are refused; format
  characters such as an emoji joiner or a direction mark are text. The
  prompt checks the name itself, so a refused name asks again with the text
  kept. A group record without `isCollapsed` decodes as expanded, because
  the document decodes whole and one strict field would stop the workbench
  loading.
- **Controller operations:** create, rename, delete, move a workspace to a
  group, reorder and collapse. Each saves through `commitLocked` or rolls
  back whole, and reads its indices before writing. An optional-chained write
  (`document.workspaceGroups?[…]`) begins its access to `document` before
  its arguments are evaluated, so reading `document` for the index there
  stopped the first version with "Fatal access conflict detected". Group
  actions and pinning refresh without the relay, which they never change.
- **Display:** the sections list the groups, empty ones included so they
  can be deleted, then Ungrouped. With no groups, All is the plain list it
  was.
- **Reordering:** a drag within a group is mapped onto the whole workspace
  order by `subsetMove`, as a drag within Pinned is. Move to Group moves a
  workspace between groups.
- **Layout replacement:** a workspace replaced by a saved layout keeps its
  group as well as its pin.
- **Agents:** groups are native presentation metadata and never reach an
  agent.
- **Downgrade:** an older Parley ignores the new keys and drops the groups,
  memberships and pins at its next save. The upgrade direction is safe.

MR 3 makes any of many workspaces reachable without scrolling:
- **Go to Workspace (Command-Shift-O, Navigate menu):** the command
  palette's workspace-only scope (`CommandPaletteScope.workspaces`), listing
  every workspace. `WorkspaceSwitcherOrder` puts those needing the person
  first, then the most recently used, then the never-used by name, and the
  current one last, so Return goes where the person most likely means. The
  chord is in `WorkbenchKeyboardShortcut` so it reaches Parley while a
  terminal has focus.
- **Hidden-sidebar tabs:** every workspace up to eight. Past that,
  `sections.tabs` is the pinned ones, the current one and those needing the
  person, in the person's own workspace order, so a tab appears or
  disappears but never changes place. Recent is left out for the same
  reason, and a first version that put the current one after the pinned
  ones moved a tab when it was selected. More, beside the + and outside the
  scrolling tabs, opens Go to Workspace. The Navigate item is never
  disabled, because the key monitor takes the chord before the menu.
- **A pane's Move to Workspace menu (`WorkspaceDestinationMenu`):** pinned
  and recent destinations first, then a submenu per group holding one, then
  Ungrouped. With no groups, the other destinations follow instead, without
  repeating the shortcuts (Agy's review of MR !126); a group's submenu is its
  whole list. The switcher's ties keep the workspace order explicitly, and
  the tab strip scrolls to the current tab when a workspace is reached
  another way. With few
  workspaces and no groups it stays the plain list. The palette builds its
  list once per render: its list used to be a computed property read about
  six times per render.

## Relay and consultation contract

The `parley` command uses an authenticated capability-named filesystem
endpoint; the native UI alone uses the control socket. Each agent pane has one
durable random credential establishing its real sender. A caller cannot choose
a different source identity.

- `parley relay <target> <text>` submits one attributed message.
- `parley whoami` returns the caller's authenticated content-free identity.
- `parley panes` returns bounded explicit non-self agent targets and lifecycle facts.
- `parley events --since <cursor>` returns bounded resumable content-minimal events.
- `parley signal <event>` is reserved for generated vendor hook adapters and
  records one authenticated, content-free allowlisted lifecycle fact.
- `parley paste <target> <text>` places attributed text without Enter.
- `parley ask <target> <question>` submits and blocks for one exact answer.
- `parley answer <id> <answer>` completes that waiting consultation. A
  delivered question names its own consultation id and says to use it verbatim.
  `current` still resolves a pane's single waiting consultation and stays in the
  protocol, but it must not be what a question teaches: it resolves to whichever
  question the pane holds when the command runs, so a target that finishes an
  expired question's work and answers with `current` lands that answer on a
  newer question, and Parley reports success. A late answer naming a
  consultation that has closed is refused with the state it reached and when —
  to the pane that was asked, and to nobody else. One that failed or was
  interrupted names the reason its closing transition recorded (a timeout, or
  the target's pane closing); every failure used to read "timed out". Every
  broker change wakes every parked Ask and `parley wait`, and each checks
  liveness (a workbench read, and for an Ask a locked credential read) at most
  once per poll interval however often it is woken.
- `parley delegate <target> <task>` creates tracked asynchronous work.
- `parley progress <id|current> <note>` lets the exact delegated target replace
  one bounded, control-stripped, agent-declared progress note. It is never a
  lifecycle transition and never counts as completion.
- `parley done|fail <id|current> <report>` records the exact result. The
  delegation prompt names its own id and teaches it, as the Ask prompt does
  (protocol 33, 23 September 2026): cancel does not interrupt the target, so a
  target that finishes a cancelled delegation and runs `done current` used to
  complete the next delegation to it with the wrong report. `done`, `done
  --file` and `progress` naming a closed delegation are refused with its state
  (`retiredDelegationDetailLocked`, told only to the delegated pane), and
  `current` is refused outright for a pane whose run had a delegation
  cancelled (`cancelledDelegationRuns`, keyed to the run's credential, so a
  restart ends it). `current` otherwise still resolves a single delegation.
- `parley done <id|current> --file <path>` completes a delegation only after
  a contained, bounded UTF-8 file is durably staged as an agent-provided draft
  for explicit human review. It never forwards the file automatically.
- `parley status` returns the caller's initiated work as JSON. Each
  delegation carries `targetTurnStarted` (protocol 34, 3 October 2026):
  - true once the target's authenticated turn-start hook arrived after Parley
    began handing the text over (`RelayHandoff.targetTurnStartedAt`, stamped by
    `handleVendorSignal`);
  - false while it has not, for active work to a target that reported any
    hook this run;
  - nil otherwise: finished or historical work without a stamp, Agy (no hooks)
    and Copilot (hooks only when its plugin runs).

  Status Center shows "No turn-start report since delivery"
  (`HandoffStartProjection`, advisory) for an Ask or Delegate a minute or more
  after delivery. The stamp's bound is `submissionStartedAt`, set just before
  the writer runs:
  - not delivery, because the hook can arrive before the delivered transition
    is recorded;
  - not creation, because a turn that began during a delegation's Git read
    would hide a lost paste (Codex's review of MR !141). On 2 October 2026 a delegation was
  delivered (paste and Enter succeeded), and Codex's own session record shows
  it never arrived. The cause lies inside the vendor's terminal UI, which
  Parley must not read; the protocol tells the sending agent to ask the
  person, never to resend. The person resends: once they have looked and
  used Cancel Tracking, Status Center offers **Delegate This Again…** (3
  October 2026), as Ask This Again does for an Ask. It is native-only
  (`/ui/delegate-again`, `handleDelegateAgainFromUI`), takes an editable
  preview that warns the target may already have the task, refuses a busy
  target rather than queueing, and creates a new delegation with a fresh
  identity on the original's route. `handleDelegate` checks under its lock
  that the original is an ended Delegate from the same source to the same
  target. The new handoff records `repeatsHandoffID` (absent decodes as nil;
  an older Parley ignores it), which is not review lineage and never reaches
  `parley status`, so the protocol is unchanged.
- `parley wait <id|current>` waits for one exact result.

Relay requests never run on the shared dispatch pool (22 September 2026, H2
of that day's review). Every agent transport request, every UI control
connection and every `ask-many` child Ask runs on a thread of its own
(`RelayWorkerThread`). The transport runs at most 128 request threads at once;
a burst beyond that waits in the inbox, and the limit is always kept above the
blocking limit so a `done` always finds a thread. Only short, bounded work
stays on the pool: ticket connections and `CommandRunner`'s stdin write. The pool has a
fixed number of threads per process (70 on the review's Mac); when parked
waits filled it, the target's own `parley done`, the ticket socket and the UI
socket stopped. The requests that can block for minutes (`wait`, `ask`,
`ask-many`, `context-ask`, `request-run`, `team-request`, `team-add`) count
against a `BlockingRequestGate` of 64. Past it a new one gets 503 at once, and
short requests are never counted. `parley wait` is a bounded long-poll: the
transport passes a 55-second window, the broker and both coordinators return
`RelayBroker.stillWaiting` (status 102) when it passes, and the shim asks
again without printing. A wait whose shell a vendor killed therefore holds its
thread for one window at most. Native callers pass no window and wait as
before. The initial `ask`, `request-run` and team calls still block, because
their waiter enforces the consultation timeout and liveness; each is limited
to one per target or pane, so they cannot accumulate. Replies nobody
collected are removed after ten minutes. The shim polls every 50 ms for its
first second, then every 250 ms. `BoundedWaitChecks` parks 80 waits and
requires the worker's `done` to go through.

Message text is limited to `RelayText.maximumCharacters` (100,000) after
`RelayText.clean`, which never truncates. Every route (relay, paste, ask,
ask-many, answer, delegate, done and the reviewed busy-draft send) refuses
longer text with 400 and `RelayText.tooLong`, which states the real length
and that nothing was sent; the composer shows the real count and disables
Send, and Insert Selection refuses a selection over the limit rather than
inserting part of it. The native editor dialog (`AppModel.editRelay`)
enforces the limit itself and reopens with the person's edits, because
Forward comparison and Run recipe paste its result straight into the lead
pane without the broker; any new direct paste must keep a limit of its own. Until 22 September 2026 `clean` kept only the last
100,000 characters, so these guards never fired and a long review, answer or
report lost its beginning while Parley reported success.

Discovery is read-only and uses the same pane capability boundary as delivery.
`whoami` and `panes` never expose credentials, folders, commands, prompts or
terminal text. `events` returns at most 100 monotonically ordered handoff transitions
and native activity records per page and omits question, result and
activity-detail bodies. A cursor removed by retention fails explicitly; it
never silently skips forward.

Generated vendor adapters ignore hook input bodies and submit only one fixed
event name through the pane's existing capability. The emitting identity comes
from that capability, never request data. Claude, Codex and Copilot receive
session-scoped adapters; Agy remains Unknown because its documented hook
configuration is persistent user or workspace state. Agents must never invoke
`parley signal` themselves.

Immediate Relay is intentional. `paste` is review-before-send. Targets resolve
by exact pane id, explicit role, or vendor only when unique. Refuse ambiguous,
missing, same-pane, shell and busy targets. Permit same-vendor routing only
between distinct panes. Allow at most one unanswered consultation or active
delegation per target.

A person's reviewed Ask (composer, their own context pack, Review) keeps
its draft until the broker accepts it (22 September 2026, M9): the draft is
cleared only when the Ask is launched or queued, Cancel on the busy-queue offer
keeps it. When the Ask ends without an answer, including a transport error,
the app reads fresh history and `ReviewedAskHistory.outcome` (by the
idempotency key the app minted) decides: no record means the broker refused
before creating one, so the draft comes back and a busy target is offered the
busy queue; a record that never got past created may already have its text in
the target's input line (the paste can land and Enter fail), and a delivered
one stays sent; history that cannot be read is unknown. Only the first gives
the draft back; every other outcome says what may have happened and offers
Copy Draft Text, so a question is never offered for sending twice. Busy and existence decisions read
`latestKnownHandoffs`, the newest record per handoff across Status Center's
history and the tick's list, because Status Center's list stops refreshing when
its window closes.

Human Ask and Answer submit only after an editable preview. Answer is the manual completion of an Ask the active pane was asked, for a target that printed its reply without running `parley answer`; the toolbar shows it only while such an Ask is waiting, and it completes the waiting command directly without pasting into either pane. A real current
Ghostty selection may prefill it; otherwise it starts empty. Never capture
scrollback or a whole conversation implicitly. The composer is inline chrome,
not a sheet, so it requests focus when it appears and again for each new
draft; and the app-wide keyDown focus repair (`repairNativeTerminalFocus`,
which hands first responder back to the selected terminal on every
non-Command keystroke) must do nothing while the composer is open or while any
editable text view is first responder. Without that guard every keystroke into
the composer, or into a text field such as the container review's published
port, went to the pane behind it and the box looked dead. A human-initiated
Ask's answer is a returned result on that handoff, never text written into the
source pane's prompt: when it completes, Status Center opens on the exact
handoff, found by the idempotency key the app minted, so the answer is on
screen rather than only a Result badge. Delivering it onward is the person's
explicit Return with its own preview.

A link clicked in a pane (command-click) is opened through
`TerminalLinkPolicy`. Pane text is written by a vendor CLI rather than by the
person, and an OSC 8 hyperlink can display one address while pointing at
another, so a click is untrusted input: only `http` or `https` with a host, no
control characters, bounded length. Every other scheme is ignored, including
`file:`, `javascript:` and application schemes that could start something
locally. A refused click does nothing rather than reporting an error. Parley
never opens a link on its own; detecting that a line looks like a login URL and
acting on it would infer intent from terminal text.

Ghostty appearance import is an explicit person action. Parse only bounded
font family, font size, theme, palette and hex colour values from the documented
XDG and macOS locations. Never load a raw Ghostty config into a terminal, follow
`config-file` or retain commands, keybindings, shell integration and behavioral
options. Custom theme files receive the same allowlist. Parley's explicit font
family and size overrides win over imported values. Repeated `font-family`
lines are Ghostty's fallback list, so the import keeps the first after the
last empty reset, Ghostty's primary font (it kept the last until 28 September
2026).
Challenge and Verify are native-control-only actions over one selected returned
Ask or Delegate. They use the original ready source, one person-selected ready
target, an editable preview and the normal correlated Ask lifecycle. Store
`inReplyToHandoffID` and relationship on the child handoff. Never put linked
reviews in the ordinary busy queue because that would discard lineage.

Only the authenticated native control route may set or clear a human verdict
and note, using the exact handoff revision shown in Status Center. Pane
credentials have no review-mutation route. Context Packs, search and Markdown
export preserve this metadata on the existing handoff; do not create a separate
evidence or review database.

Cross-vendor review loop practice (guidance, not a required sequence): a lead
pane delegates with a request for milestone progress, the target posts
`parley progress` at milestones and returns with `parley done` or
`parley done --file` using the completion-evidence headings below, a
different vendor reviews the shared diff, corrections go back as one linked
`requestChanges` Delegate child (`parley delegate <target> --parent
<handoff-id>`; protocol v15 also links Ask children through Challenge and
Verify, and none of these is ever a verdict), and the reviewer verifies
independently. The built-in **Review and correct** recipe is this practice as
an editable prompt template for the lead and nothing more. Parley records
each step as an ordinary attributed handoff. It must not add a workflow state
machine, automatic transitions, an executor that verifies agent claims,
streamed progress or any completion estimate; agent-supplied progress and
evidence remain labelled claims.

Completion-evidence convention (agent-declared, presentation only): a
substantial result returned with `parley done <id> --file <path>` may use
the plain Markdown template below. Status Center recognises the three ATX
headings, in any order, as one **COMPLETION EVIDENCE** block labelled
AGENT-DECLARED and shows every body as an unchecked claim. Unknown headings
and their bodies are ignored, the first occurrence of a duplicate heading
wins, an empty recognised heading is shown as declaring nothing, and a file
without the headings renders exactly as before. Parley never runs a command
to check a claim, adds no schema and never rewrites the staged file. The
evidence is read from the review's `returnedPart`, the staged copy, not the
editable pack, where the person may edit or remove the part before sending;
a record from before the copy existed still reads the pack.

```markdown
## Implemented
- What changed, one bullet per change.

## Tested
- `command` — the outcome you observed, one line per command you ran.

## Unable to test
- What was not run — the reason.
```

Multiline payloads travel through Ghostty paste as one text operation.
Submission is a separate Enter key event after paste succeeds. Never send raw
newlines as key events. The settle between those steps pumps the main run loop,
so the pane can be stopped, closed or restarted part-way through a delivery: the
controller refuses another delivery to that pane until the first returns,
including a nested call while the run loop is pumped. The target is re-resolved
by pane id, launch generation and view identity before
each step that sends input, and a pane that went away refuses rather than
writing into a torn-down surface. Whether a failed delivery could have left
text in the pane is one classification, `ParleyWorkbenchError.refusedBeforeInput`:
the broker offers Retry Delivery only for such a refusal, and a voice draft
whose delivery was attempted stays reviewable only after one. Everything before the paste refuses with
one of its errors (a pane that is not ready or has gone, Copilot trust, a
delivery already in progress, a changed voice destination), and every
failure after the paste, before or at Enter, is `deliveryInterrupted`, which
carries the cause. Those steps are `PaneInputDelivery` (ParleyCore), which
the registry runs with its surface and the checks run scripted, each step
made to fail in turn. Until
29 September 2026 the registry reported those later failures as "not ready",
so Retry could paste the text a second time, and a voice send refused before
any input read as possibly delivered. A record saved as safe to retry by an
earlier version keeps that, since nothing tells its cause apart now. Restoring the person's focus afterwards is not
delivery and never turns a completed submission into a reported failure. Bound
those settles against a monotonic clock; a wall-clock deadline spins the main
thread for the length of any backward step. Ghostty takes paste and Enter on
a surface without focus (`DeliveryFocusChecks` proves it on real surfaces), so a
delivery leaves the person's focus and active pane alone
(`PaneSubmissionTiming.focusesTarget`). Only Copilot's submission briefly
focuses its pane, through `DeliveryFocus` (ParleyUI). For the whole delivery,
restore included, the pane's focus callbacks change no selection, and focus
repair and `focusSelected` leave the lent focus alone. Focus is restored
through the target's own window rather than whichever window is key, on every
exit, and only if the target still holds it. A text field being edited comes
back as the field with the person's selection, because its field editor
leaves the window the moment it resigns. Keys typed during the settle are not
lost to the target: pumping the run loop does not dispatch NSEvents, so they
wait in the queue and reach the restored responder. Until 23 September 2026 every delivery focused its target, the callback
made that pane the person's active pane, and the restore used
`NSApp.keyWindow`, so with Status Center key or Parley in the background
the person's next keystrokes went to the other agent. Refuse delivery at
Copilot's folder-trust prompt. Copilot handoffs remain blocked until the person confirms
**Confirm Copilot Folder Trust** in its pane menu for that launch. Hooks cannot
grant this confirmation.

## Voice input and spoken handoffs

Voice is person-operated native input/output around the existing CLI panes.
`VoiceSession`, `VoiceDestination` and `VoicePlaybackQueue` in ParleyCore are
Foundation-only policy. `VoiceRecognition` and `VoiceController` in
ParleyNative own Apple Speech/AVFoundation, microphone lifetime, cancellation
and speech synthesis; do not move audio dependencies into the Core baseline.

The initial languages are en-GB and en-US. macOS 26 uses SpeechAnalyzer and
SpeechTranscriber on supported hardware, with an explicit AssetInventory
download in Settings > Voice. Older/unsupported hardware uses
SFSpeechRecognizer only after supportsOnDeviceRecognition is true and with
requiresOnDeviceRecognition set; there is no cloud fallback. Models are
Apple-managed local assets, not Parley audio recordings. Info.plist must carry
microphone and speech consent descriptions, and the signed executable/bundle
must carry com.apple.security.device.audio-input. The unbundled developer
executable refuses recording before attempting consent.

Dictate is click to start, click to stop (`DictateButton`): a mouse click,
keyboard or VoiceOver activation toggles recording, and while recording the
button reads Stop. Until 3 October 2026 the mouse held it, recording only while
the button stayed pressed (Mark's request). Control-Shift-Space is still held
in the main window. A second click, shortcut release, loss of window/app
focus, cancellation or 60 seconds ends recording. Control-Option-Space is
reserved for VoiceOver. Preparation cancellation invalidates the session
before any late consent callback can start capture. Buffers are bounded and
copied before the audio tap returns; engine work and conversion run off the
main actor. Finalization has a five-second UI deadline and preserves a partial
transcript on failure. A new recording waits for the previous owner to stop.

The editable draft is bound to pane id, generation, vendor, workspace and
reviewed launch folder. Selection changes never redirect it; Use Active Pane
is explicit reselection. Paste and Send use the ordinary controller checks
(including Copilot folder trust) and Ghostty input path, carrying snapshots
through to validation on the main actor before paste and before Enter, after
each run-loop settle. Both participants of a voice Ask/Delegate are checked
there too. A potentially partial delivery is copy/discard only, never an
automatic retry; a refusal before any input (Copilot trust not confirmed, a
delivery already in progress) is not one, and the draft stays open to send. `VoiceHandoffRequest` is native-control-only and enters the
existing broker correlation, idempotency and history paths. It creates no
agent command and does not change AgentProtocol wording or version.

The transcript editor owns keyboard focus while open. Do not let
repairNativeTerminalFocus steal its input. Voice drafts, copied audio buffers
and the speech queue are memory-only; Parley writes no raw audio files.
Discard and quit clear the draft, and an explicit delivery clears it after
success. Ask/Delegate content follows existing journal retention and vendor
input follows the CLI's own handling. Only language and opt-in read-aloud
preferences persist, in the current Production/Development preference domain.

AVSpeechSynthesizer reads only an explicit real selection or returned
Ask/Delegate result. Read-aloud is off by default, holds three items of at
most 8,000 characters, and has stop/clear and queued-item removal. Capture and
playback exclude each other, including microphone cleanup. No terminal
scraping, completion inference, always-listening mode, spoken permission
approval or navigation commands belong to this implementation. Ordinary tests
use pure session/queue state, synthetic broker routes and a native accessible
button; bundled microphone consent/revocation and audible output remain
explicit manual acceptance in docs/test-scenarios.md, never inferred from a
green build or a missing-asset probe.

## Process and capability boundary

Spawn fixed executables with argument arrays. Agent-authored content must never
be interpolated into a shell command.

Every Git command Parley runs on the host to *read* a repository goes through
`GitReadBoundary` (22 September 2026, H1 of that day's review): delegation Git
facts, the pane Git context, worktree discovery, board facts, cleanup and
merge previews, context Git Diff, review drafts and `ContainerGitAccess`. A
repository's configuration and attributes can name programs for Git to start
(clean, smudge and process filters, textconv, external diff, fsmonitor, a lazy
fetch, a status child per submodule), an agent can write that configuration
and a container always can, and these reads run with nobody's approval, some
on a timer and some on an agent's `parley done`. The review reproduced a
container agent's clean filter running on the Mac that way. Two layers:

- The read runs as `/bin/bash -c 'ulimit -H -S -u 1 && exec "$@"'
  parley-git-read <git> <args…>`. That fixed script is the one shell on this
  path; Git's path and arguments are positional parameters it never parses.
  With the process limit at one, Git runs but every fork it attempts fails, so
  no configured program can start, including one added between the listing
  below and the read. This is the race-free layer; `posix_spawn` cannot set a
  resource limit, and `sandbox-exec` cannot nest inside a vendor's own
  sandbox, which is why it is a shell.
- Before status and diff, `git config --list --name-only -z` (itself guarded)
  names every filter driver in every scope, and `GIT_CONFIG_*` sets each one's
  clean, smudge and process to empty and `required` to false for that read.
  Without it a required filter (git-lfs installs one) makes the guarded read
  fail. An edited file under a filter is then compared as raw bytes and may
  read as modified. `-c` cannot carry a driver named `a=b`; the environment
  form can. An empty textconv is an error rather than off, so diffs pass
  `GitReadBoundary.diffArguments` (`--no-textconv --no-ext-diff
  --ignore-submodules=dirty --submodule=short`) and status passes
  `--ignore-submodules=dirty`, which compares a submodule by recorded commit
  without a child Git.

The read environment drops every inherited `GIT_*`, `BASH_*`, `ENV`,
`SHELLOPTS`, `BASHOPTS` and `CDPATH` and sets optional locks, prompts, pagers
and lazy fetch off. The person's own command capture keeps its environment.
Operations the person confirms (worktree add, remove, prune, `branch -d`,
Integrate) are Git itself and run outside the guard; `worktree remove` alone
takes the filter overrides, for the `git status` it runs inside. `--attr-source`
does not help: it replaces the in-tree `.gitattributes` but not
`.git/info/attributes`. `GitReadBoundaryChecks` plants every one of these in a
real repository and requires that no read runs any of them.

A spawned tool must start from a clean signal state. `posix_spawn` otherwise
hands the child the calling thread's blocked mask, and Swift concurrency and
the terminal stack run threads with signals blocked. A child that inherits a
blocked `SIGCHLD` is never told its own children exited: it waits forever,
silently, and only `SIGKILL` ends it. Every spawner therefore sets
`POSIX_SPAWN_SETSIGDEF` and `POSIX_SPAWN_SETSIGMASK`, resetting each
disposition to default and clearing the mask. Resetting dispositions alone is
not enough; the mask is the half that bit.

A command whose exit was never observed is not a success. When `waitpid` fails,
the raw status was never written, so `CommandWaitOutcome` reports `unobserved`
(status 125) rather than the untouched zero, and says so on the command's error
output. A timeout stays 124. Never let a command nobody saw finish satisfy a
`status == 0` check.

Every wait on that path is bounded, the one after `SIGKILL` included. A child
parked in an uninterruptible kernel wait cannot be reaped until the kernel
releases it, so `BoundedReap` gives up at its bound and still reports the
timeout rather than holding the thread past the deadline it exists to enforce.
Giving up leaves a zombie until the process exits; a permanently blocked thread
would be worse. Its primitives are injectable because that state cannot be
created on demand, and a check that cannot fail is not coverage.

Every command `ProcessCommandRunner` spawns runs in a session of its own
(`POSIX_SPAWN_SETSID`), so it leads its own process group and has no
controlling terminal. A timeout signals the group, never only the direct
child: SIGTERM, then SIGKILL after the full grace second whether or not the
child has already exited (its descendants may still be cleaning up, such as a
`git` child removing its index.lock), with the child kept unreaped
(`waitid(..., WNOWAIT)`) until then so its pid, and so the group id, cannot be
reused in between. A hook, filter or helper that ignored SIGTERM used to
outlive a timed-out command (96c795d7, 28 September 2026). It is a session, not
only a group: in Parley's session the launch's `zsh -lic` PATH discovery opens
`/dev/tty` to take the foreground and was stopped by SIGTTOU whenever Parley
had a controlling terminal (`npm run dev`), a six-second launch stall
reproduced under `script`. The context-pack Command Result runner and the
Codex configuration query use Foundation's `Process`, whose child already
leads its own group (checked per run, not assumed), and signal the group too.

Reviewed command cancellation uses the same bounded reap and a monotonic
deadline after SIGKILL; an unobserved exit returns no exit status and says
completion is unknown. The transient Codex configuration query uses bounded
nonblocking reads and writes, with bounded cleanup, so a descendant retaining
stdout cannot hold the launch review beyond its deadline.

Host vendor CLIs launch directly as trusted local applications, with their own
permissions and approval prompts. Do not put Parley's Seatbelt profile around
host CLIs: it prevents Codex from applying its tool sandbox. A host Codex
launch takes `HostAgentPermissions.launchArguments`; the generic
`PermissionProfileAdapter.launchPlan` is what the review displays and what
container and non-Codex launches use. A value on
`PermissionProfileSelection` reaches a pane only if every resolver call site
passes it: `applyPermissionProfile` re-resolves from the current store when
the review's Start is pressed, and v0.1.44 through v0.1.48 resolved there
without `approvals`, so a Claude pane reviewed as "Vendor's automatic
reviewer" launched in accept-edits mode. When adding a selection field, grep
every `PermissionProfileResolver.resolve(` and make the new argument
required at the review hand-off rather than defaulted. Anything that must reach a host Codex
pane has to be carried in both: v0.1.44 put the approvals choice in the plan
only, so a host Codex pane never received auto review while the review said
it had. Host bypass flags
remain forbidden. `HostAgentPermissions` supplies Codex-native private-runtime
denials with exact protocol/shim read access, own-endpoint write access and
read access to the exact ticket socket (including its canonical alias). This
explicitly permits the shim's pre-connect stat without granting access to the
transport directory or sibling endpoints. It does not establish that the
previous rules refused this read in a network-enabled Codex pane; that needs
a real sandbox comparison with and without the socket rule.
The built-in profile parent retains Codex's Git and configuration protections.
Those rules cover sandboxed tools, not the CLI parent, integrations or approved
unsandboxed commands. When the profile allows network access the table also
carries `network={enabled=true}`, because Codex's built-in `:workspace` and
`:read-only` profiles have none; the built-in **Flexible + network** profile
exists for that, and only Codex can carry the rule, which every other
vendor's plan says. The Codex review also reads the person's own
`approvals_reviewer` through the same bounded config query and states it,
since `auto_review` overrides whatever Approvals choice is made. Other vendors keep their existing native launch controls;
never present a profile intention as OS enforcement. The review sheet
(`PermissionProfilePickerView`) opens with a **Runs** picker (On this machine
or In a container, for every agent vendor; a Shell pane would see the fact,
never a dead control) and ends with **What is
carried** and **What is not carried**, replacing the earlier Vendor
Enforcement, Always Outside the Profile and host-disclosure sections (14
September 2026). Every carried line names who keeps it: the vendor, Docker
for a container's mounts, or nobody for a container bypass. The lines are
derived from `PermissionProfileLaunchPlan`, whose `mode`, `reviewer`,
`execution` and `network` parts are the pieces its joined `detail` is built
from; `detail` stays byte-identical because checks pin phrases in it.

The Codex start/restart/resume review and host-team approval run a bounded
preflight off the main actor. A transient `codex app-server --stdio` reads
configuration only (no thread or model); raw config is never logged. Conflicting
legacy sandbox settings are refused. `codex sandbox -P` then exercises a real
tool, synthetic private-file denials and own-endpoint access. This verifies the
configuration at that moment, not a future session's behavior. Vendor config
can change later; existing processes are never silently restarted.

Native control uses a fresh memory-only token, a socket path supplied directly
by native construction, and kernel peer-PID checks on both sides before native
control requests are accepted. The client checks the peer before sending any
authority. Both socket writers suppress SIGPIPE per send. The old control-token
file is never read. The control socket has no pane-token routes; agent requests
use the ticket-checked file transport exclusively. Request fields are read
through pinned directory/file descriptors with no-follow opens and descriptor
validation, never an `lstat` followed by a second pathname lookup.
`AgentProcessBoundary` remains only around the host Docker
client; Docker owns the vendor's container boundary and reviewed mounts.

Pane capabilities still authenticate and route explicit messages.
`RelayFileTransport` rejects a valid token through a different endpoint. An
unrestricted same-user host process can nevertheless read another pane's
credential or alter local records. Attribution is not isolation against such a
process. Since 14 September 2026 the transport narrows that where a vendor's
own sandbox allows it (a design lifted from the donkeykong review):
`RelayTicketServer` listens on `tickets.sock` beside the endpoints (or in the
user's temporary directory when that path would exceed a Unix socket's 103
bytes; `socketURL(transportDirectory:)` decides for server and shim alike),
verifies the connecting peer's uid and `LOCAL_PEERPID`, and issues a one-use
ticket, valid for ten seconds of awake time, only after a bounded kernel parent
walk reaches this app. It ages on `CLOCK_UPTIME_RAW` through the transport's
`RelayTransportClocks`: on the wall clock, a shim that got its ticket just
before the Mac slept was refused on wake ("the ticket is invalid, expired or
already used"), which a `parley wait` loop left running overnight met on 28
September 2026, and a clock change could expire one too. A team pane request
the app has not yet picked up times out after 90 seconds of awake time too
(`TeamSessionCoordinator`'s `awake` clock), and only until the pane exists:
on the wall clock a sleep failed it on wake, a clock stepped back blocked
every later add, and the same timeout failed a container member whose Docker
preparation outlasted it and tore its prepared container down. A command
run's worker ticket (120 s) is still a wall-clock window; it spans only the
moment between the approval and the worker's start.
Only the app's direct launch root (or its child below Ghostty's root-owned
`login` intermediate) may supply `PARLEY_PANE_ID` and
`PARLEY_PANE_GENERATION`; descendant markers never establish identity, and
an unreadable root refuses instead of falling back to a child. The generation
must match the current live pane. A copied token and self-chosen environment
therefore cannot impersonate a sibling launch. Host vendor applications
remain trusted local processes, not an isolation boundary. The shim asks for one with `/usr/bin/nc -U` and
writes it as the `ticket` request field; the socket request names both the
capability and the transport request UUID, and the transport redeems it once
for that exact pair. The shim stages the body before obtaining the short-lived
ticket. A pane that must present a ticket and sent none is refused with 428
(`RelayFileTransportError.ticketRequired`) before anything is read. When the
socket gave no answer within `nc -w 3`, the shim keeps its staged body and
sends the same request again under a new id with a fresh ticket, a second
apart, up to ten times. A socket that answered "refused" is final at once.
The staged body goes once the transport has read the request: the request
is in neither the inbox nor `processing`, and there is no reply yet. A
refusal is written before the request leaves `processing`, so it is never
mistaken for that. Request text therefore still leaves the filesystem before
a long Ask or wait (`checkStagedBodyLeavesBeforeAWait`). On
2 October 2026 a `parley wait` in a Claude pane died with that refusal while
the Mac slept and dark-woke every fifteen seconds; the check
`checkTicketRetriedAfterNoAnswer` delays the first ticket past `nc`'s timeout.
Both native socket bind paths share a serialized owner-only umask,
restored before listening. `RelayTicketPolicy` says per pane whether a ticket is
required, optional or unavailable, from what real panes were observed to do
on 14 September 2026 (every vendor: Claude, Agy, Codex and Copilot each
returned peer-verified from its own pane that evening), never from
documentation: required for Claude and
Copilot host panes, whose shell commands run unsandboxed, and for Agy, whose
own `--sandbox` admitted the socket from a real pane; required for Codex when
its profile allows network and optional otherwise: `codex sandbox` run with
Parley's own `permissions.parley_host` table denies Unix sockets while the
table keeps network off and admits them once `network={enabled=true}` is in
it, which `HostAgentPermissions` writes exactly for a network-allowing
profile (Mark's Flexible + network Codex pane was peer-verified for that
reason; with network off only an approved escalation could reach the
socket, so a ticket is welcome, not demanded; the broker answers the
network question from the controller's per-generation host launch snapshot
through `hostNetworkAllowed`, nil meaning unknown and therefore optional).
Editing or deleting a profile affects the next launch, never a running
pane's ticket requirement. The reviewed profile is captured when a generation
starts, before surface creation, and also supplies shared-writer warnings;
container bypass counts as write-capable regardless of the nominal profile.
`WorkbenchPane.launchFolder` persists the person-selected agent folder separately
from the terminal-reported `cwd`. Generation snapshots retain that folder;
start, restart, resume, container preparation and permission reviews use it.
Only a native stopped-pane folder selection changes it. Legacy documents use
the last stored folder until the person reviews or changes it.
Command-run containment and exact-command grants, team grants, agent context
staging and the working folder of trusted context captures use this same
reviewed folder; OSC reports never widen those roots. Worktree scans and
writer warnings use the reviewed agent root, while cleanup conservatively
protects both the launch folder and the reported folder, including records
read from the other native runtime.
Old or stopped generations have no live permission fact, and inactive or
relay-disabled source panes are refused by broker authentication. Tickets are unavailable for any container,
where the socket is not mounted, and whenever the socket is not listening;
and optional for a Claude
host pane whose own sandbox is switched on: `ClaudeHostConfiguration` reads
`sandbox.enabled` where Claude reads it and in Claude's precedence (managed
settings, `CLAUDE_CODE_FORCE_SANDBOX`, the project's `.claude/settings.local.json`,
its `.claude/settings.json`, then `~/.claude/settings.json`; unreadable or
silent files are skipped, unknown is never on or off; each file is opened
non-blocking after a type check and sized on the opened descriptor, because
the project's `.claude` folder is the agent's to write and a symlink to a
huge file or a FIFO there used to be read whole or to block the launch
review, which now reads the fact once per folder through
`ClaudeSandboxFactCache`; nothing can stop a hung network or FUSE mount from
blocking an ordinary read), and that sandbox
denies Unix sockets unless its `allowUnixSockets` list admits one, which
Parley has not checked. The controller snapshots this fact at launch alongside
the reviewed profile; later setting edits and terminal cwd reports cannot
relax that generation's ticket policy. Parley never writes Claude's settings. `whoami`
reports `attestation` (peer-verified or token-only) and the pane's policy
with its reason, and the launch review lists the same fact under What is
carried or What is not carried. A ticket socket that fails to start never
fails the core: every pane is then token-only and says so. Human Shell panes are unsandboxed; reviewed containers provide stronger
separation, subject to their mounts and trusted local daemon.

Vendor CLIs may rebuild `PATH`. The runtime-local shim is preferred but not
guaranteed, so `~/.local/bin/parley` remains a runtime-neutral router. Exact
`PARLEY_RUNTIME=DEV` selects Development; an unset marker selects Production.
Only Production may install or upgrade the stable router. The router contains
no credential and no transport authority.

The relay transport path spelling in native permission rules and the container
client Seatbelt profile must match the shim. Include canonical aliases where
needed; path spelling is part of the permission contract.

`EnvironmentResolver` may run fixed `/bin/zsh -lic` PATH discovery with
sentinels and a hard timeout. Apply `LANG=C.UTF-8` only when every effective
character locale variable is absent or empty. Never overwrite an explicit
locale.

Strip parent multiplexer marker variables from vendor environments so a
development launch cannot accidentally bind an agent to a parent terminal
session.

## Reviewed command runs

The person-authorized `parley request-run --cwd <absolute-folder> --
<absolute-executable> [args...]` path proposes exact argv and a contained
canonical folder. Native editable approval opens one NEW visible Ghostty
Shell pane; a fixed worker spawns argv directly, captures bounded stdout/stderr
and real exit status, then execs an ordinary human Shell. Never interpolate
agent content into a shell string, send input to an existing Shell, or present
captured output as verification. This is explicitly outside the agent boundary
and vendor tool enforcement; host vendor launches retain their own controls.

The command runs in a session of its own (`POSIX_SPAWN_SETSID`), with stdin
on `/dev/null` and no controlling terminal, and before the worker execs the
shell it discards input still queued on the pane's terminal, saying so in the
pane (`ApprovedCommandWorker.discardQueuedTerminalInput`). Until 23 September
2026 the command was a background process group in the pane's session: a
prompt on `/dev/tty` (git's HTTPS username) stopped it with SIGTTIN, it read
as running for up to a day and blocked that pane's later requests, and the
reply the person typed waited in the terminal until the shell exec'd after
Cancel ran it as a command, a password reaching shell history.
`ApprovedCommandTerminalChecks` pins both. A command that needs a prompt now
fails and says so, so the person runs it themselves in a Shell.

The approval preview's argument editor is `PlainTextEditor` (ParleyUI), an
AppKit text view with every automatic substitution, correction and detector
off. Every box whose text is approved or sent uses it: the Command Result
capture's argument lines, the context pack's part, selection and
instruction editors, the team objective and the handoff composer (which
asks for focus through `focusRequest`, set to the draft id, in place of
`@FocusState`). Only the voice transcript and Status Center's verdict note
remain SwiftUI editors. Each `PlainTextEditor` keeps its own undo manager,
cleared whenever its text is replaced from outside, and each context pack
part has its own editor (`.id(part.id)`): a reused text view otherwise
replayed the previous content's undo at offsets past the new text's end. A SwiftUI `TextEditor` leaves macOS
smart quotes on, so on 23 September 2026 (v0.1.61) a closing `"` became `”`
and approval failed with "The data couldn't be read because it isn't in the
correct format". `ReviewedCommand.display` writes slashes as they are rather
than `\/`, and `ReviewedCommand.parseDisplay` names a typographic quote in
its error only when straightening the quotes makes the array parse, never
rewriting it, because an argument may contain one.
`CommandRunArgvEditorChecks` pins all three.

Per-run approval is the default. Optional exact-command session trust is native,
off by default, memory-only, revocable and visibly disclosed. It keys exact argv,
canonical folder and source generation and includes mutable code with human file
and credential access. Cross-vendor attribution cannot be guaranteed while it is
granted. Restart/move/folder/policy changes and quit invalidate it. Do not restore execution authority from the handoff journal. Separately,
**Settings > General > Agent command runs** holds two native session choices.
`CommandRunAuthorizationSession` starts with both off on every app launch;
neither preference domains, agent requests nor the retired
`command-run-authorization.json` can restore authority. Both choices reset on
quit. `AppModel` pushes the approval choice into
`ReviewedCommandRunCoordinator.setAutomaticApproval`.
A worker's state is observed files first, lease last: a worker takes its
lease before it claims its ticket, so read the other way round a worker
starting between the two reads looked like one that had ended without a
result, and the run was failed with "do not resend" (96c795d7). When the
lease reads not running the files are read again, since they are then final:
a worker that started, failed its claim, recorded why and exited inside the
window keeps its real failure.
Approved worker tickets carry a digest whose expected value stays in app memory
and travels as a literal worker launch argument. A worker checks the exact
claimed bytes before decoding or executing them; editing the file cannot change
the approved argv. Result authentication does not protect against an unrestricted
same-user process reading the staged ticket's result key. Treat captures as
reported evidence, not proof against a compromised local account.
While on, an eligible request is approved exactly as requested with no
session grant and `approvedAutomatically` recorded on the run (decoded as
false for older journal records), requests already waiting are approved if
their pane is still current, the runs notice discloses it, and turning it
off restores per-run approval immediately and returns not-yet-launched
automatic approvals to pending. A permanent stop still refuses every
request. The second switch, "Close the Shell pane when a run finishes
cleanly", is decided before any shell exists: the worker ticket carries
`exitInsteadOfShellWhenClean`, so after a clean result
(`ReviewedCommandRunPaneClosePolicy.isClean`) the worker exits instead of
exec'ing a login shell. `CommandRunPaneCleanup` then decides from fresh
controller facts, bound to the pane's created generation, and `AppModel`
removes the pane once the worker's lease is released, restoring the pane that
was active at launch if the person is still on the run's pane. Ghostty forces
wait-after-command on every surface created with a command (the per-surface
flag can only turn it on), so the surface keeps showing "Process exited" and
never closes by itself. Parley records the exit from Ghostty's own record
(see the exit paragraph under the runtime model), but that says only that a
process ended; in exit-when-clean mode the released lease is the proof that
the worker exited without exec'ing a shell and nothing runs behind the
surface. The worker outlives Ghostty's
abnormal-runtime threshold before exiting (monotonic clock) so no
failed-launch screen flashes. Ghostty reports a close synchronously from
inside `terminate`, and that report refreshes the app: every termination in
`WorkbenchController` goes through `terminateSurface`, or through
`endSurfaceLocked` after the same check (see Roles and mobility), and close, restart,
stop, start, workspace close and layout restore refuse to begin while one is
in progress (`isTerminatingSurface`); the cleanup pass skips such ticks,
`closePane` removes by identity and restart/stop re-resolve their target
after the transport ran. A pane handed
to an interactive shell, a restarted pane, a failed, cancelled, truncated or
unsaved run all keep their pane; close failures are retried up to three
times and reported separately. One active run
per requester; native cancellation stops its owned process group. Result recovery
requires the same live source generation. Reuse the existing journal and 90 KB
rendered/200 KB transport bounds; agent commands never create their own approval.

A run can also be proposed by the person from the native app
(`ReviewedCommandRunCoordinator.propose`), today only from the worktree
board's **Integrate…**. Its record has `origin: .person`, no source pane and
the workspace the person was in. It is always `.pending` until the editable
preview approves it, because that preview is where the person confirms the
exact command, so neither the automatic-approval switch nor an exact-command
grant applies and the trust toggle creates no grant. A pane restart never
interrupts it, `parley wait` refuses it because no pane requested it, the
journal names the person with an empty source pane id and the Shell kind,
and its Shell opens in the chosen workspace beside the active pane. One
person proposal may be waiting or running at a time. Records written before
this carry no `origin` and decode as agent-pane runs; an agent-pane record
without a source pane is refused.

## Team sessions

`parley team request --folder <absolute-folder> [--panes <n>]
[--hours <n>] [--worktree <branch> [--base <ref>]] "<objective>"` lets one lead
pane propose a bounded team for one objective. It requires a live agent pane
in a workspace whose policy allows delegation and a folder inside the lead's
working folder. Nothing is authorized
until the person approves a native editable preview of objective, folder,
allowed vendors, permission profile, pane limit (at most 8) and deadline (at
most 128 hours). Folders bind in the approval.

Approval creates one memory-only `TeamSessionGrant` keyed to the lead pane id,
generation, workspace, automation policy and canonical folder, binding the
complete approved permission definition and roots, not merely a profile id.
While it is live only the lead may run `parley team add --vendor <vendor>
[--name] [--role]`, one creation at a time, with an idempotent request identity
and a Parley Pane Request ID announced on stderr for `parley wait` recovery.
The native app re-verifies the grant and the unchanged stored profile, then
creates a NEW started agent pane in that workspace bound to the approved folder
and exact profile. Creation is transactional: the controller rolls back a pane
it cannot persist, and the coordinator records ownership (pane id, created
generation, workspace, requesting pane, grant, time) the moment the controller
returns, before any Ghostty mounting step that may fail; a mounting failure is
reported on the owned member, never dropped from the count or from Stop. The
limit counts every creation for the session's lifetime. A request that
created nothing and failed is kept for `parley wait` recovery, but only the
newest `retainedFailedProvisions` (16) per session: they used to stay for the
life of the app, and the app scans every request each second, so a requester
retrying a refusal grew both without limit. A request that created a pane is
never pruned, because its identity is what stops a repeated request making a
second pane. Members cannot add
panes or nest sessions. Vendor permission prompts remain active except for an
explicitly approved per-vendor container bypass. Parley never answers prompts,
never restarts a pane on an agent's behalf
and never restores team authority from any journal. Sessions appear as native
activity records for visibility only. The Team Sessions sheet is the
monitoring surface and never blocks provisioning; any other sheet or modal
does, and creation never steals focus from a visible window. Its Work list is
`TeamSessionWorkScope`: only handoffs with a session-created pane on either
side, started after that pane was created and not after the session ended.
The requester's other handoffs are not the session's; listing every handoff
the requester had ever made buried the session's own work in every v0.1.42
acceptance run.

Ownership is pane id plus created generation. Stop revokes the grant and stops
only still-owned processes, leaving them as stopped placeholders; a pane the
person restarted since creation is skipped and reported, a moved pane stays
owned, and the lead, unrelated panes and in-flight Ask/Delegate work are
untouched. Actual stop failures are shown with a retry. The deadline bounds
provisioning only: expiry or interruption revokes the grant and stops nothing,
while "Stop team panes" stays available for still-owned running panes. Lead
restart, move, folder or policy change, an edited or removed approved profile
and quit interrupt the session. Requests, decisions and pane
results are recoverable only by the same live requesting-pane generation.
Whether an approved folder lies inside the requester's working folder goes
through `WorkspaceFolderIdentity.contains` on canonical spellings, as do
command-run folders, nested worktrees and container mounts against protected
runtime files (`overlaps`); agent context staging keeps its own check, which
also refuses the pane folder itself. A lead working at `/` used to be approved by the coordinator, which
treated the root specially, and then refused at every creation by the
controller's own check, which built `//` as the prefix (28 September 2026).
Agent-facing status names the requester as `requesterPaneID`; the `lead`
routing alias keeps meaning the marked workspace lead, and members address
the requester by its exact pane id. Every session transition is typed
(`TeamSessionTransition`) and its origin is derived in trusted code: requests,
provisioning, expiry and interruption are automation; approval, refusal, Stop
and stop attempts are human. Activity records and the agent events feed carry
bounded correlation only (session id, requester pane id, affected pane ids)
plus label-and-count detail, never objectives, folders, diagnostics or
terminal text; the agent events feed omits detail entirely, and older records
without the new fields still decode. Stop attempts are recorded as structured
per-member outcomes derived from a fresh workbench read (stopped,
stopped-but-unrecorded, failed, unknown when the state could not be read,
skipped restarted/closed, already stopped) with every message and reason
UTF-8-bounded, control-cleaned and flagged when truncated; retained attempts
are capped so status stays under the 200 KB cap. Historical membership is kept
separately from current ownership, and machine timestamps are ISO 8601 while
`detail` stays display-only.

## Managed Git worktrees

Parley manages one Git worktree per feature or team, never one per pane, and
only as lifecycle, evidence and safety around Git. `ManagedWorktrees.swift`
owns it: `ManagedWorktreeService` runs a fixed `/usr/bin/git` with argv only
(every read inside `GitReadBoundary`, described under the capability boundary),
an environment scrubbed of every inherited `GIT_*` variable (locks, prompts
and pagers disabled), `--end-of-options` before any person-supplied value,
bounded timeouts and no `--force` anywhere. Branch names and refs are
validated before a process runs (no option shapes, traversal, control
characters, `..`, `refs/`, trailing `/`, `.lock`), and Git's own
`check-ref-format --branch` is consulted too. Repository identity is the
canonical `--git-common-dir`; worktree listings are parsed on NUL boundaries
so a newline-bearing path survives.

Creation happens only after a native preview, and the mutation is bound to
that preview. `createPreview` resolves the base ref to one commit and the
exact planned path `<toplevel>/.worktrees/<slug>`; native flows build the
`CreateRequest` from the preview alone, and `create` re-resolves the folder
and refuses before any directory, exclude line or Git command if the common
directory, the planned path or the base commit differ from the preview (a
re-pointed alias to a clone with the same commits is refused with nothing
written there). It also refuses an existing branch, a symlinked `.worktrees`
or one resolving outside the repository, and an existing path. It appends one
`.worktrees/` line to `<common>/info/exclude` (idempotent, other lines
untouched, tracked ignore rules never edited), runs `git worktree add -b
<branch> --end-of-options <path> <commit>` once, observing a timeout as
status 124 rather than skipping reconciliation, then asks Git's registry what
happened. Only a successful add from this process is a creation receipt:
a nonzero or timed-out add that nonetheless registered a tree (for example
after a failing post-checkout hook) is `unmanaged`, described as possibly
usable, never adopted, and never retried; stderr wording or a matching
branch and HEAD is not proof of the creator. After a successful add, a tree
whose admin directory already carries a creation marker is `ambiguous` (no
marker written, the other creator's marker preserved, no record); a tree Git
does not list is `incomplete` and nothing on disk is deleted; an unreadable
registry is `uncertain`; a registered tree whose record cannot be saved is
`createdButUnrecorded` and must not be created again. The preview states the real execution boundary: checkout runs
configured post-checkout hooks and clean/smudge or process filters with the
application's permissions, and Parley does not disable them. The marker is
`<common>/worktrees/<name>/parley-worktree-owner`, written without
overwriting; a tree removed and recreated at the same path never inherits
it, and `attach` (selecting an existing tree) records `parleyCreated: false`
with no base unless a ref was given. Records live in
`managed-worktrees.json` (mode 0600) as ownership and base metadata only,
never execution authority.

Team Sessions integrate at approval. `--worktree` on the request is a
proposal only; the approval form offers ordinary folder, existing linked
worktree or new worktree, previews the base commit and path, and the native
app calls `preflightApproval` (same checks as `approve`, no mutation,
planned-path containment through the nearest existing ancestor) before any
Git runs, then creates or attaches, then approves with the folder equal to
exactly that tree and `TeamWorktreeBinding` on the session. In every mode the
approved working folder is inside the requester's working folder; only a created
tree is placed under `.worktrees/`. Host-pane grants are never widened to the
repository or shared `.git` directory. Container grants can separately bind the
explicitly reviewed shared Git mount described below, without mounting the primary
checkout. Git writes follow the reviewed vendor permission mode, as the approval, Help and protocol explain. A created tree whose approval then fails
is reported as created-but-unapproved and stays selectable or removable.
`parley team status` exposes the binding as `worktree`; panes, the Team
Sessions detail and the Status Center delegation inspector show path, branch
and recorded base. The inspector renders `ManagedWorktreeEvidence` captured
inside the delegation Git snapshot at delegation and return time, matched by
the exact `--show-toplevel` root (a nested worktree or an unmanaged nested
repository is never attributed to a managed parent), never a later lookup.
Generic `whoami`, `panes` and events stay path-free. Pane rows look the pane
up through the background scan's exact worktree root and cached records; no
filesystem work happens at render time.

Cleanup is person-triggered from the Worktrees window, for any recorded
tree. A Parley-created tree must still carry its creation marker; a tracked
tree has no marker, so Git's registry entry at the recorded path is its
identity and the preview says so (Mark's decision on 13 September 2026,
after the board showed five fully integrated trees Parley refused to touch
only because an older Parley had created them). `cleanupPreview` and
`remove` each read every fact fresh: registered identity (marker-verified
for Parley-created trees), lock and prunable state, other
registered worktrees or Parley-known trees nested inside the tree, this
runtime's pane folders (started or stopped, re-read again right before the
mutation) and the other Production/Development runtime's `workbench-state.json`
(an unreadable file refuses), `git status --porcelain=v1 -z --untracked-files=all
--ignored=matching`, the configured upstream from `branch.<name>.merge` with
`rev-list --count @{upstream}..HEAD`, and `merge-base --is-ancestor` against
the primary worktree. `WorktreeCleanupPolicy.decision` is the pure table:
a nested registered or known worktree, any live or placeholder pane inside
the tree, modified or untracked files, a present file marked assume-unchanged
or skip-worktree (`git ls-files -v`, sliced as bytes; status cannot see an
edit to it, and a sparse checkout's absent file holds nothing), a populated
submodule or a `modules` admin directory (Git's own `validate_no_submodules`
test; Git will not remove that tree without `--force`),
commits ahead of the upstream's local
remote-tracking state (a pushed but unmerged branch is allowed; the remote
is never contacted), no upstream and not contained in the primary's HEAD,
locked, prunable, unregistered, the repository's primary checkout (a
tracked record can point there), a Parley-created tree whose marker no
longer matches, a non-directory item
at the recorded path, a path that cannot be inspected (only a confirmed
"no such file" is an absence), an unreadable state file, an unreadable worktree
registry, an unreadable record store, a target record missing from or
changed in the freshly read store, or an unanswerable Git question refuses;
a path with no filesystem item at all that a successfully read registry no
longer lists as present, with its record present and unchanged in a
successfully read store, becomes record-only cleanup that runs no Git
command. Every ignored entry Git would delete is shown in full in a
scrollable native list with control characters escaped (`displayPath`), a
directory entry meaning its whole contents.

Removing a merged team worktree used to need two manual steps (the first
team trial, 2 October 2026, Prax f559be94). An upstream that is configured
but whose remote-tracking branch is gone (Git's `%(upstream:track)` reads
`[gone]`), usually GitLab's "remove source branch" plus a pruning fetch but
only ever observed as a local absence, is `upstreamGone`, and one that cannot
be read is `upstreamUnknown`. Neither
counts as a status failure any more, and the primary checkout's HEAD settles
both: a tree it already contains is removable. Otherwise each refuses under its
own name, and the board reads "upstream gone". This is the one exception to
"an unanswerable Git question refuses" above. Independent repositories in
ignored folders are `nestedRepositoryPaths`, refused as such rather than as
registered worktrees. A folder whose regular `CACHEDIR.TAG` begins with the
Cache Directory Tagging signature (read with `O_NOFOLLOW` and checked with
`fstat`) is not searched for repositories, because SwiftPM keeps its package
clones in `.build` beside one. That is the one exception to the search of
ignored directories above. The tag is a declaration, not something checked:
the preview lists each such folder (escaped, `displayedCacheDirectories`),
says it was not inspected and that everything in it goes with the tree. It
never claims the tree holds no independent repository. A tag added after the
preview is not compared at removal, because the person has already
acknowledged that ignored folder's whole contents (Codex's review of MR !136).
`worktreeRemovalAfterMergeChecks` runs both cases with real Git. Ignored directories are also
inspected for independent repositories, including bare repositories, before
cleanup can proceed; an unreadable or over-budget traversal refuses removal
as a refusal in the preview, never a failed preview. The budget counts
directories (20,000, plus the read timeout), not files, so a tree holding
node_modules or .build can be checked.
Attaching a path with a Parley creation record whose marker no longer matches
refuses rather than replacing the record with an unowned tree. More than 200
ignored entries refuses; the
person acknowledges exactly that list and the preview words the preservation
evidence from the facts (local remote-tracking state, not current remote
knowledge). While a removal runs, `WorkbenchController` holds a folder
reservation that `requireDirectory` enforces on every creation, start and
restart route, so no process can appear inside the tree. Removal runs
`git worktree remove --end-of-options <path>` from the primary worktree
without `--force`, observes a timeout as status 124, and reports only what
Git's registry and the filesystem show afterwards: `removed` (folder gone
and no longer present, record cleared, record failure reported separately),
`retained` (still listed and the folder remains; after a Git error a
partial removal is possible and the text says so) or `uncertain` (registry
unreadable or registration and folder disagree; nothing recorded, no
retry). Native titles follow that state. Folder reservations are checked
under the controller's mutation lock before any workspace or pane changes,
so a refusal leaves no half-applied metadata. Background facts (branch, HEAD,
changed count, upstream) refresh with the worktree scan for trees a pane sits
in or an active session is bound to, and for every record when the browser
opens, under a generation guard that applies only over unchanged records;
`registered` is a tri-state and a read failure stays unknown, never
"absent". Worktree discovery preserves the NUL field boundaries from
`git worktree list --porcelain -z`: line breaks inside a path or lock reason
are literal field data and must never become record separators.

**Finish…** on a row opens the on-demand inspection surface,
with no timer or background disk-size scan. It groups optional review, pane
or workspace close, workspace-scoped history clearing and the existing
guarded removal preview. Each destructive step remains separately confirmed.
Close revalidates pane identity, generation and folder after confirmation;
mixed workspaces expose individual panes. History clearing explicitly covers
the entire named workspace, including other folders, and keeps its existing
active-work protections.

The **Worktrees** window (Tools › Worktrees…, also reached by Workspace ›
Open Worktree…, which selects the active pane's repository) is the worktree
manager. It is an auxiliary `Window` scene on `AuxiliaryWindowRoot`, so it
opens with no workspace or pane, is released on close and reads only while
on screen. Its repository list (`WorktreeRepositoryCatalog.merge`) is built
from every folder Parley knows, resolved off the main actor: pane folders,
workspace attachments, favourites, recent folders, managed-record paths and
folders the person added with Add Repository…, which persist in
`worktree-repositories.json` (paths only, mode 0600) so the window is
useful with nothing open. Entries are keyed by primary checkout and union
their sources; an added folder that no longer resolves stays listed as
missing until forgotten, and only an entry whose sole source is the
person's addition can be forgotten. The selected repository's registered
worktrees are the rows: Git's registry is the list and a
`ManagedWorktreeRecord`, when one exists, annotates the row with base, team
and requester (`WorktreeBoardRow.derive(tree:record:…)`; a prunable entry
is `.stale` before any fact is read, an unrecorded tree's owner is
`.unrecorded`). Facts for unrecorded trees come from
`ManagedWorktreeService.facts(forTreeAt:id:expectedCommonDirectory:)`, keyed
by path, read for the selected repository only and applied by the newest
request. Every linked row offers Open, Integrate…, Finish… and Remove…; an
unrecorded tree gets a record on the way into Finish or Remove
(`ensureWorktreeRecord`, the same `attach` Track Existing used, written
silently), so tracking is no longer a step. A STALE row offers **Prune…**
and **Delete branch…** instead. A gone folder cannot be realpath-resolved, so
Git spells a stale entry with the `/private` prefix the record lacks;
the manager matches records to stale rows by resolved path, and checks
compare resolved forms rather than strings. Prune is Git's own global prune: there is no
per-entry form, so the preview is Git's own dry run (`worktree prune -n -v`),
not the registry's prunable list, because `worktree list` omits an entry
whose gitdir file is missing and prune removes it anyway (a live tree then
reads "not a git repository"). Each entry shows Git's reason, the folder its
gitdir file records and its branch; Parley refuses the whole prune when any
entry's folder still exists, has no recorded location, or is still linked
from a Parley record or `.worktrees` folder (a relative `gitdir:` pointer,
from `worktree.useRelativePaths`, is resolved against the file holding it). The person acknowledges the
admin names, which must still match Git's dry run when it runs, no folder or
branch changes, and Parley clears its records for the forgotten entries.
Delete branch runs one `git branch -d --end-of-options <branch>` from the
primary checkout after a preview worded from Git's own rule: with an
upstream whose remote-tracking ref exists, `-d` checks that upstream, not
HEAD, so a pushed branch is deleted even when the primary's HEAD lacks it
(the preview says it is then kept only by the upstream); without one it
checks the primary's HEAD. The deletion is bound to the commit the preview
showed and refuses if the branch moved. Git's own refusal is shown as it is
and `-D` never appears in Parley's argv. The
branch step is offered as a second button on a successful removal's result
and again after a prune, for the branches the forgotten entries held (one
confirmation each); it is not on a STALE row, because Git counts a prunable
entry as still holding its branch and refuses until the entry is pruned,
which the preview states when it happens.
Integrate on an unrecorded row uses the registry's branch and refuses a
detached HEAD. **Predict…** on a row runs the existing `merge-tree`
prediction against the primary checkout's HEAD and offers Integrate… from
its result (14 September 2026); the row's facts line also says whether the
branch is pushed, unpushed by N commits, or has no upstream, since the
removal policy allows a pushed unmerged branch. **Remove integrated and
unused…** in the window's footer is the one bulk action: every linked tree
whose row reads Integrated or Unused gets a record if it lacks one, a fresh `cleanupPreview` each, and `WorktreeBulkRemovalPlan`
splits them into passing and skipped (any refusal, or a folder already
gone, which is Prune's case); the single preview lists each passing tree
with its preservation summary and every ignored entry that would go,
grouped by tree, and each skipped tree with its reason. Confirmation runs
one `git worktree remove` per passing tree, in order, under one folder
reservation and one mutation, and stops at the first outcome that is not
a confirmed removal, reporting each. The branches of the removed trees are
then offered as the same separate branch step, one confirmation each.
Nothing runs across repositories. The Open Worktree… sheet, its two-list
layout, the Managed by Parley section and Track Existing are gone; the
Workspace menu item and the pane notice's "open worktrees" action both
open the window on that folder's repository, and Finish… on a row presents
the four-step inspector (`WorktreeLifecycleView`) as a sheet on the window.

Every row of the window is the worktree board: one
`WorktreeBoardRow` per registry entry, derived on every read from the record, the
last background `ManagedWorktreeFacts`, the panes the scan mapped into the
tree, the requesting pane if it still exists and the bound team session. It
shows the owner (a team with its state, the requesting pane as running,
stopped or closed, You for a browser creation, Person-owned for a tracked
tree), the recorded base, HEAD, changed paths, commits ahead of and behind
the primary checkout, and a state: Not read yet, Missing, Unknown, In use (a
running pane inside or an active team), Integrated (HEAD contained in the
primary's HEAD and the tree clean) or Idle. The facts pass also reads
`rev-list --left-right --count` and `merge-base --is-ancestor` against the
primary checkout's HEAD; a failed read stays nil and is shown as unknown,
never as zero. Nothing about the board is stored. **Integrate…** is not
offered on a tree that already reads Integrated. It proposes
`git merge --no-ff --no-edit --end-of-options refs/heads/<branch>` in the primary
checkout as a person-proposed reviewed command run (see Reviewed command
runs); when that run ends the facts are re-read for every record so the row
can read Integrated, after which the existing removal policy passes on its
own. The tester and reviewer of v0.1.49 both thought ownership and safe
cleanup were missing when they were not; the board exists so those facts
are visible without opening the inspector. `docs/worktrees-roadmap.md`
records what was decided on 13 September 2026 and what waits on beta
evidence.

WorktreeUsage excludes stopped placeholders, other-runtime panes and active
local team bindings from inactive candidates; unreadable other-runtime state
stays unknown. This says nothing about other applications. Last retained
activity is the latest exact-path delegation Git snapshot, never a terminal
or filesystem inference. Only the target workspace is associated from such
a snapshot; a delegating source is not a cleanup scope. In-view workspace
associations remain available after closing panes, but are not a new durable
history store. WorktreeDiskUsage measures logical regular-file bytes on
request, never follows symlinks, and caps enumeration at 50,000 entries or two
seconds. Partial and unavailable readings are labelled; APFS sharing means
this is not reclaimable-space accounting.

Recovery never adopts a tree by branch name. A moved record can be relinked
only when the old path is confirmed absent, exactly one registered path in
the same repository carries its original creation token, and a store-locked
compare-and-replace still matches the reviewed record with no destination
collision. Only the record path changes; historical evidence and live pane
folders remain unchanged. Missing/foreign/unknown states get guidance and
existing guarded actions. Track Existing records an existing tree as
person-owned with no base; removal is offered through the same preview and
refusals, identified by Git's registry entry at the recorded path.

Merge previews resolve the chosen integration ref and the tree's HEAD to
immutable commits, then use fixed-argv Git merge-tree, inside
`GitReadBoundary`, in a private bare temporary repository. An alternate object directory is read-only input;
new objects are written only to temporary storage, which is removed after
the command. Global/system configuration, templates and external project
merge drivers are excluded; lazy fetching and replacement objects are
disabled. This is an isolated-defaults prediction, not an actual merge or
a verdict. It captures at most 200,001 bytes, rejects results over 200 KB or
200 paths, distinguishes exit 1 conflicts from command failure and shows
exact commits and limitations. UI requests discard stale selection/ref
results. No checkout, index, branch or source Git objects are changed.
Permission guidance is person-selected by vendor, does not inspect terminal
text or claim to know a prompt, and never grants a permission root.

A tree whose HEAD is still its recorded base and whose status is clean
reads **Unused**, not Integrated (kingpong's distinction, taken on 14
September 2026): integrated means the work landed, and a tree that never had
any work is not that. A tree with no recorded base cannot tell and keeps
reading Integrated. Remove integrated and unused… proposes unused trees too,
each labelled as such in the preview.

Deferred: merges, rebases, pushes and stashes performed by Parley itself
(Integrate is a reviewed command run the person approves, not a Parley Git
action), automatic cleanup, automatic branch deletion, per-pane worktrees and
multi-folder grants.

## Experimental container panes

Container execution is independent of `AgentLaunchMode` (fresh/resume). The
person selects it in the native permission review for any agent pane (Claude,
Codex, Agy and Copilot since 14 September 2026; the first two shipped in
v0.1.27 and the guards that excluded the others were scope, not a decision)
and checks a locally installed image. The check applies its result only
under the input revision it began with (`checkRevision`, advanced by any
change of `checkInputs`, which names every stored input of the view): its
Task holds a copy of the view, whose `let` properties never change, so a
Claude image check used to land after the review switched to Codex, and
`ContainerConfiguration` names no vendor to catch it at launch. Parley never builds or pulls images. The
image supplies the pane's vendor at `/usr/local/bin/<vendor>`, POSIX sh,
GNU stat/coreutils and `/bin/chown`; `docs/container-images.md` states the exact
utility contract, the run-time shape an image must tolerate, worked Dockerfiles
and the command to check an image against the same probe. It also says how a
pane reaches a service on the Mac (`host.docker.internal`, baked configuration,
a service's Host check) and what that opens. `docs/parley-agents.Dockerfile`
is one image for all four vendors with the Prax CLI, whose inputs
`docs/parley-agents-fetch.sh` fetches and checks against each publisher's
checksum (30 September 2026); each pane still gets its own container and
volume. Parley adds no environment or mount for this; the allowlist below
still holds.
`ContainerPaneService.preview` pins a
local Unix-socket endpoint, daemon ID and image ID and probes the vendor
without a project mount, pane capability, network or signed-in session. The fixed
probe first verifies the Linux shim and home-initializer utility contract. It
cannot establish login, instruction uptake or continued compatibility.
Codex's legacy Landlock mode is a separate explicit choice; it is not enabled
silently. Bypass vendor permissions is a separate native, off-by-default choice,
authorized by Mark on 9 September 2026 as the container-only exception to invariant 3.
`ContainerConfiguration.bypassVendorPermissions` defaults to false when absent in
older records and is part of exact configuration comparisons for preparation,
activation and team grants. Only the native review chooses it; agents cannot
supply it to team add. `ContainerLaunchProjection.bypassArguments(for:)` is the
one table: Codex receives `--dangerously-bypass-approvals-and-sandbox`, Claude
and Agy receive `--dangerously-skip-permissions`, Copilot receives
`--allow-all` (its documented tools-paths-URLs skip-all), after the image ID in
Docker's argv; `--allow-all*` arriving through vendor arguments is refused like
every other bypass flag. Copilot reads its instructions directory from the
environment, so the projection carries `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`
(the one key in `vendorEnvironmentKeys`; any other key is refused) as `--env`
before the image, and the value is the host protocol path because that mount
keeps its path inside the container; Agy's protocol directory travels as its
ordinary `--add-dir` argument. The image probe's temporary home is a tmpfs
with `exec,size=1g`: Copilot's launcher unpacks about 150 MB into
`~/.cache/copilot` on first start and maps a native addon there, which
Docker's default noexec 64 MB tmpfs refuses with "failed to map segment".
The real pane's home is its volume, so that unpack persists there. Both home
volume mounts, the initializer's and the pane's, carry `volume-nocopy=true`:
Docker populates a still-empty volume from the image's directory at the mount
point, ownership included, on every create, so an image that carries
`/home/parley` (which `docs/container-images.md` tells people to create)
handed root ownership back after the initializer's chown and the vendor
could not write its home. Found on 14 September 2026 with the first image
built from that page; the v0.1.27 spike image had no `/home/parley`, which is
the only reason it worked. Normal profile launch arguments are omitted in that mode and enforcement
is labelled guidance only; host launches retain vendor controls, with Codex
using `HostAgentPermissions` and the other vendors using `PermissionProfileAdapter`.
Bypass and legacy Landlock cannot be combined. The image probe checks utilities
and vendor `--version` with the chosen flag instead of demanding an inner sandbox.
Docker mounts, non-root UID/GID, capability drop, no-new-privileges and native
host command-run approval are unchanged. Privileged containers remain prohibited.
The native review, pane badge, Team Sessions and Status Center disclose bypass;
mounted files, shared Git metadata, network and the pane's vendor login become
available without the usual vendor permission prompts.

`ContainerLaunchProjection` builds argv with an explicit daemon, non-root
UID/GID, four exact host mounts (project and own endpoint writable; protocol
and Linux shim read-only), plus the reviewed shared Git directory for a linked
worktree, one private named home volume, disabled Docker
output logging and an explicit vendor entrypoint. An optional reviewed port
(`ContainerConfiguration.publishedPort`, nil in every record written before it
existed) is published as `127.0.0.1:<port>:<port>` — loopback only, one port,
1024–65535, network mode unchanged — so a vendor's browser sign-in callback can
reach the container. Codex listens on 1455; its device-code sign-in needs none,
and Claude's paste-code sign-in needs none. Only the native review sets it,
agents cannot supply it to team add, it is part of exact configuration
comparisons, and the pane badge and Status Center container records show it. Only allowlisted Parley
metadata reaches the container. The Docker socket, host vendor configuration
and sibling pane endpoints are never mounted. The container is the vendor's
boundary; Seatbelt remains around the host Docker client but cannot constrain
operations performed by the external daemon. Reject broad/overlapping roots,
submodules and arbitrary additional permission roots. Linked worktrees require
`ContainerGitAccess`: bounded regular Git pointers, a matching registered tree,
the canonical common directory and its device/inode, all checked again before
preparation. The native review names that writable mount and its shared refs,
objects, hooks and configuration; the primary checkout is never mounted.
Changes to shared hooks or executable Git configuration can cause commands to run on your Mac, outside the container, during later host Git operations. Parley does not review those changes again.
The same holds for an ordinary container pane whose project mount contains its
repository's `.git`: the container can rewrite that configuration, hooks and
attributes. Parley therefore runs no Git for a container pane's delegation or
return: the broker records `DelegationGitSnapshot.notCaptured` with
`containerPaneReason` ("Git facts not captured" in Status Center and the
export; `notCapturedReason` decodes absent as nil), and `compare` gives no path
comparison. Every other read of such a repository (pane context, board facts,
cleanup preview, context Git Diff) goes through `GitReadBoundary`. Every
container review states this (`GitReadBoundary.containerDisclosure`), and the
Worktrees window footer says that its confirmed actions are Git itself
(`worktreesDisclosure`).
Planned folders resolve through their nearest existing parent, so aliases match
the later inspected tree. Submodule gitdirs are refused with a named reason.
Working folders cannot contain or sit inside either runtime's control or relay
transport directories, including the current runtime's explicit paths. Compare
canonical realpath spellings before credential rotation or any Docker command;
Foundation path standardization can shorten /private/tmp back to /tmp.
A team's memory-only grant binds its reviewed per-vendor container configurations.
Agents choose an allowed vendor, never an image, daemon or mount. Creation records
an inert, owned placeholder before Docker preparation; the provision stays pending
and blocks another add. Native activation rechecks the live grant, deadline,
profile and exact placeholder, then transfers ownership to its initial started
generation. Stop/expiry while preparing refuses activation and attempts cleanup;
failed cleanup keeps the receipt and warning. No Docker work holds the team or
workbench lock or runs on the main actor. Team Stop cleans every still-owned
container before terminating its surface and reports per-member failures.
The member records where its preparation stands (`TeamSessionMember.containerPreparation`:
pending, then ended if it failed or was refused; nil once a generation
started, for a host member and in older records). A placeholder whose
preparation ended never started, so its generation never moved, and it now
reads as a stopped placeholder (`ownership(of:)`) that Close stopped panes
offers; it read as owned forever. Close stopped panes
(`TeamPlaceholderClosing`) re-reads each pane just before closing it, carries
on past one that fails or whose state cannot be read, always refreshes, and
lists every pane it skipped or could not close with the reason; it used to
stop at the first failure without refreshing. Stop leaves a placeholder still preparing to
that preparation (`TeamStopPlanner.containerCleanup`) and reports it as
`preparationCancelled`, a skip: it used to run Docker cleanup that the
controller refuses during a preparation and report the member as failed. The
ended grant refuses the activation, and the preparation removes its container
and reports the outcome on the member. A placeholder whose preparation ended
is still cleaned by Stop, which retries a cleanup that was not confirmed.
Stop plans from the members as they are after its Docker cleanup, since a
preparation can end meanwhile. After a confirmed container cleanup, a pane
found restarted is left alone and said to be, never reported as a cleanup
that failed.

Native creation first persists a stopped placeholder. `prepareContainerStart`
performs Docker work off the main actor without holding the workbench lock;
activation checks its exact pane generation, folder, workspace, policy, profile
and fresh/resume mode. Cleanup also runs in the background and issues an
in-memory generation-bound stop receipt before a main-actor Ghostty termination.
Status Center removes only the selected creation record. Once no container
remains for that pane, it clears a matching prepared receipt even when native
activation never advanced the pane generation. An older record cannot stop a
replacement; final surface cleanup checks the returned pane generation again.
A lost Docker client triggers receipt-based cleanup, never an inference that
the container stopped. Creation uses `docker create` then a Ghostty-owned
`docker start --attach --interactive`. `container-panes.json` records intent and the daemon-issued ID
before attach, with protected `container-<owner>.cid` files preserving uncertain
creates. Image probes and the home-volume initializer also have receipts.
Names and labels are discovery aids, never sufficient cleanup authority.
Cleanup checks the recorded daemon, exact full ID and ownership marker, uses
bounded stop/remove commands without force, and preserves uncertain records.
The daemon's identity is checked once per removal, and once per daemon for a
cleanup of several records; before 28 September 2026 each identity check in
a removal asked again, eleven Docker runs for one running container. The ID
and ownership marker are still checked before each step. An image check and a
preparation ask again after each container they wait on.
Every lifecycle stop the app makes names the generation it reviewed:
`stopPaneProcess` takes `expectedGeneration` with no default. The lost-client
cleanup in `GhosttyPaneRegistry` stopped whatever pane generation was current
once its detached Docker cleanup returned, so a pane restarted meanwhile lost
its new session.
`prepareContainerStop(_:requiringWorkspace:)` takes the workspace requirement
with no default. `performAfterContainerStops` (Close, Stop… and the bulk
actions) checks the pane's workspace again after cleanup, so it passes true
and a pane moved after its review is refused before any Docker command; Team
Stop, restart, the team's failed-start cleanup, shutdown and lost-client
reconciliation follow the pane wherever it is and pass false. `movePane`
refuses while the pane's container is being prepared or stopped
(`containerPreparations`), and while a person's action holds it
(`holdAgainstMove`): `performAfterContainerStops` holds every pane it
reviewed, synchronously after the confirmation, and releases them once its
last step has run. Since 3 October 2026 that sequence is
`ContainerStopSequence` (ParleyCore), over an environment `WorkbenchController`
provides. Building one holds every pane. `run` tries every container, refuses
the action when any stop failed or any pane changed or went away, runs it
exactly once otherwise, and releases on every path. `ContainerStopSequenceChecks`
drive it through a recording fake (Prax 8544b63f, from the team review of MR
!135). The cleanup reservation alone ends when
Docker returns, before that last step, and in a batch one pane's cleanup ends
while another's still runs, so a move could land between a removed container
and the step that ends its pane (the team review of the pane Stop and its
verification, 1 October 2026; `checkContainerStopAndMoveExclude`,
`checkStopHoldsPanesAgainstMove`, and PaneStopChecks for the wiring).
Stop/close/restart/quit must stop the owned container before terminating its
host surface; a failed stop refuses the lifecycle operation. Old records are
shown in Status Center and never adopted as surviving sessions. No daemon
scan or process sampling is introduced into the refresh tick. Ownership file reads
use a short independent lock, so Status Center does not wait on Docker. Bulk
cleanup visits every receipt/pane after a failure and reports each unresolved one.

Closing the main window keeps containers alive. Docker logging is disabled,
but vendor login, configuration and conversations in a pane's named volume
survive container removal. Status Center > Health > Containers separately
confirms deletion and refuses a referenced or foreign volume; ordinary history
clearing does not delete vendor state. Agent `whoami.executionBoundary` reports
host/container configuration only. Container terminal working-directory reports
never replace the reviewed host folder used by context capture and command
requests. Process rows describe the host client,
never inferred processes inside the VM. A container's `request-run` still
requests a host human Shell and the native preview discloses that boundary.

Real Docker checks are explicit, fail if prerequisites are missing, and never
count as silently skipped default tests:

```bash
node scripts/run-native-swift.mjs run --package-path native parley-native-checks --container-transport-spike <local-image>
node scripts/run-native-swift.mjs run --package-path native parley-native-checks --container-ghostty-spike <local-image>
node scripts/run-native-swift.mjs run --package-path native parley-native-checks --container-bypass-spike <local-image>
```

The transport check uses disposable fixture credentials, never a live pane's
capability. The container checks that verify protected runtime roots report a
prerequisite explicitly rather than skipping when they cannot reach those
paths; they never count as passing unrun. Since v0.1.30 removed Parley's outer
boundary from host panes, those checks and the Ghostty launch checks do run
inside a host agent pane: the full suite passes there. A container pane still
has a real boundary, so the prerequisite can still be reported from one.
Image sign-in, fresh and resumed vendor instruction uptake, normal approval prompts and post-relaunch
login persistence remain explicit human compatibility follow-ups. Ship the
reviewed greenfield implementation with known limitations recorded; untested
configurations do not hold the feature out of main or the next release.

## SwiftPM inside agent panes

SwiftPM compatibility is available in **Settings → General → Swift package
builds** and is off by default. After explicit human opt-in, newly launched
agent panes receive a runtime-local `swift` wrapper for SwiftPM `build`,
`test`, `run` and `package`. It adds SwiftPM's `--disable-sandbox`
option to avoid unsupported nested macOS sandboxes. Project and dependency manifests and plugins run
with the agent's existing permissions, including any permitted network access.
Vendor approvals and any vendor sandbox remain active. The setting only
automates a SwiftPM flag; it does not expand the agent's existing permissions.
Host launches retain invariant 3's approval protection. The separately reviewed
container bypass is independent of this opt-in, which affects only SwiftPM's
additional subprocess sandbox.

The wrapper resolves the current PATH toolchain, including mise, on each
invocation. It does not install a language toolchain or change global shell
configuration. Human Shell panes retain ordinary SwiftPM behaviour. A changed
setting applies on the next explicit pane start/restart, never on a remount.
If a vendor rebuilds PATH, `"$PARLEY_SWIFT_COMMAND" build ...` reaches the
same helper. Absolute compiler paths and `xcrun swift` do not use a PATH
wrapper. `PARLEY_SWIFTPM_COMPATIBILITY=0` opts an invocation out.

The repository's native runner honours the same explicit opt-in before
stripping pane capabilities from build children. For an existing agent pane,
a person-authorized `PARLEY_SWIFTPM_COMPATIBILITY=1 npm test` or
`PARLEY_SWIFTPM_COMPATIBILITY=1 npm run build` enables it for that command only. Never infer opt-in
merely from being inside Parley. A host agent pane has no outer Parley sandbox
since v0.1.30 and runs the whole suite; a check that still cannot run in the
current pane must report that limit rather than silently skipping.

## Terminal type for panes

Ghostty advertises `TERM=xterm-ghostty` and points `TERMINFO` at the entry in
Parley's bundle, so every program on this Mac finds it. A remote host reached
over ssh has no such entry unless it was installed there: ncurses programs
refuse to start (`cannot initialize terminal type`) and readline cannot look
up which byte the delete key sends, so it stops deleting and moves the cursor
(Mark's report on 19 September 2026). **Settings › Terminal › Terminal type**
is `TerminalTypePreference`: **Ghostty** (`xterm-ghostty`, the default, which
changes nothing) or **Compatible** (`xterm-256color`). The preference is
persisted per runtime, pushed to `WorkbenchController.setTerminalTypePreference`,
and read once per launch generation (`terminalTypeLaunches`, the SwiftPM
snapshot pattern), so a change reaches a pane at its next start or restart
and never alters a retained launch; `GhosttyPaneLaunch.terminalType` reports
what the launched process sees.

The value travels as one `TERM=xterm-256color` word for `/usr/bin/env` inside
the launch command, after the `-u` unsets and before the executable, for
shell and host agent panes alike. It is deliberately not put into the
surface's `envVars`: Ghostty at the pinned ref applies its own `term` option
after the surface environment (`Exec.zig` puts `TERM` from `cfg.term`, then
the config `env` overrides last), so a value there would be a second copy
whose precedence depends on upstream ordering, while the command is
Parley's alone. Container panes are untouched; Docker already sets
`TERM=xterm-256color` at create and the container launch reports that.
`TerminalTypeChecks` pins all of this and reproduces the remote host locally
(`tput -T xterm-ghostty` with Ghostty's terminfo out of reach fails while
`xterm-256color` resolves from the system database). Settings and Help show
Ghostty's own remedy for keeping `xterm-ghostty`,
`infocmp -x xterm-ghostty | ssh <host> -- tic -x -`, with a Copy button;
Parley never runs it. Ghostty's `ssh-env` and `ssh-terminfo` shell
integration features would do this per ssh call, but the integration is
detected from the command's first word and Parley launches every pane
through `/usr/bin/env`, so it is not active in Parley panes today.

## Reviewed context boundary

An agent-staged context part is a claim. Its path and bytes stay labelled
`agentFileDraft`. Each rendered part sits between marker lines that no text in
the pack contains: the plain `--- begin/end explicit context ---`, or the first
numbered pair none of it uses, found in one pass. With fixed markers an agent
part could close its own part and forge a following "Selected file" header
(7a7848f9, 28 September 2026). Every one-line metadata field (the name, a
source path or label, evidence fields) is rendered through
`ContextPackText.singleLine`, which shows line breaks and other control
characters escaped: an agent's staged path used to carry newlines into forged
metadata lines, and control characters that the final normalize removed only
after the boundary scan. A pack with an agent-provided part always says which
lines are its boundaries, since a look-alike marker is not one either. A
Command Result that died of a signal says "Terminated by signal N (NAME)"
rather than an exit status (`CommandOutput.terminationSignal`; the status is
128 + N). Git Diff capture reads at most `gitCaptureBytes` (1 MB) of Git
output and refuses output that reached it: a diff cut there, even one that
normalizes below the 60 KB part bound, is never accepted shortened. Only a separate human-authorized capture may create trusted
File, Git Diff, Selection or Command Result provenance. A pack carries its
origin (`ContextPackOrigin`): the rendered header says "Agent-proposed
context; not approved or sent" until the person approves, then that the
person approved delivery while agent-provided parts stay unverified, and a
source the person captured separately into an agent draft keeps its own
provenance. A review recorded before the origin existed decodes with the
origin its state proves (`AgentContextReview.legacyOrigin`: approved and
completed are approved; draft, awaiting review, rejected and discarded are
proposed; failed and interrupted, which the approval timeout and the restart
recovery reach from either side of approval, are `agentApprovalUnrecorded`
and say so), never as person-selected; only a bare pack without an origin is
person-selected. The
Context menu lists waiting approvals first and the newest eight saved drafts,
with every pending draft in Status Center's Live section. A native discard
(`discardContextDraft`, `/ui/context-reviews/discard`) names the draft and
the listed revision and is refused under the broker lock for anything but an
unchanged `.draft`, so a bulk discard can never decline a waiting Ask. A
`done --file` review keeps the part exactly as staged in `returnedPart`;
approval rebuilds `pack` from the reviewed part set and never touches it, and
the completed handoff's read-only "Show returned file" reads only that copy
(a record from before the copy existed shows the agent-provided parts still
in its draft and says they may have been edited) while the resolved review
is retained. Approval forms return
known part ids and edited text, never source metadata or captured originals.

An agent-staged file may be a PNG or JPEG image of at most 10 MB (protocol
34, 2 October 2026), so a Codex pane using its own computer use can hand over
a screenshot. Parley itself captures only a window the person picks (below).
Codex's review of MR !138 shaped most of what follows.
- **Checking:** `ContextImageInspector` decides from the bytes alone: the
  signature, one image in a PNG or JPEG container, and at most 16,384 pixels
  a side and 64 million in all. It never decodes the pixels. ImageIO yields
  an image for a PNG whose compressed data is corrupt or cut short, so a
  decode would prove nothing and cost up to 256 MB a request. A damaged image
  is staged; its preview says when ImageIO cannot draw it, which is not the
  same as Parley no longer keeping it.
- **The part:** it keeps kind `agentFileDraft` and gains an `image`
  (`ContextPackImage`: format, size, byte count, SHA-256). Its text is
  Parley's description, never the bytes, and `replacingText` leaves it
  alone. Its editor is a preview (`ContextImagePreview`), read off the main
  actor as a thumbnail of at most 1,600 pixels once per digest for each
  preview on screen; there is no shared cache.
- **Downgrade:** an older Parley decodes the record but drops `image` when it
  next saves the review store. The copy is then collected, and the part reads
  as its description alone.
- **The copy:** it lives in `context-images/<sha256>.<ext>`
  (`ContextImageStore`). It is written through `OwnerOnlyFile`, read with
  no-follow opens and hashed again on every read, so a changed file is
  refused, never served. The store holds at most 500 MB
  (`defaultMaximumTotalBytes`): sixteen parts in each of a hundred reviews
  could otherwise leave 16 GB nobody sees. A full store first collects, then
  answers 507 naming Delete Saved Context.
- **Collection:** a copy goes as soon as no saved review holds it, no
  staging pins it, the person's open pack does not hold it and no retained
  handoff delivered it. It runs when reviews are pruned or deleted, at start, and
  when the store is full. Staging pins the digest before the copy is written
  and releases it once the review is in the broker's map, or staging failed
  (`pinImage`, `unpinImage`). The pin lock is held across a collection's
  listing, so a copy whose review is still being saved is never taken.
  Staging ends through `releaseStagedImage`, which also collects a copy
  that no review ended up holding, such as a refused add's. A
  ten-minute age did this before review, and a long sleep or a forward clock
  step defeated it.
- **Fetching:** agents run `parley image <sha256> --to <file>`, a pull
  written by the agent's own command with its own permissions. Parley never
  writes into an agent's folder, and an endpoint path, which carries the
  pane's capability, never appears in any text. The shim makes a scratch
  folder beside the destination with `mkdir`, which fails on anything already
  there, links included. It copies the reply over the destination only once
  the whole image arrived (a container has `cat` but no `mv`). A refusal, or
  a reply `post` could not write out in full, leaves an existing file as it
  was. `post` now fails with 74 whenever it cannot copy a reply, for every
  command, since `set -e` does not reach it.
- **Who may fetch:** the broker (`handleImageFetch`) serves an image only to
  the pane that staged it, to the pane a person approved sending a pack
  holding it to, or to the target of an Ask that delivered it from the
  person's own pack (`deliveredImages`, below). "Staged" means an
  `agentFileDraft` part of the pane's own review. A person's window capture
  added to an agent's draft is not the agent's to fetch. A queued draft's
  image is found but not granted (403).
- **Queue downgrade:** images held only by a queued draft rely on a collector
  that knows queued drafts. The image store first ships in the same release
  as that knowledge (v0.1.65 at the earliest; v0.1.64 has no image store or
  collector at all). So no released version deletes them. A build from
  between !139 and !142 would, which Codex's review of !142 found (M2).
- **Unknown source kinds:** they decode as `.unrecognized` (3 October 2026).
  The original string is kept (`ContextPackSource.unrecognizedKind`) and
  written back when the review is saved again, so a newer Parley gets its
  own kind back.
  Strict decoding failed the whole saved review store, so a newer kind
  stopped an older core loading saved context. v0.1.64 and earlier still
  decode strictly. Moving back to one after saving a window capture in an
  agent's draft stops that version's core loading `context-reviews.json`
  until the review is deleted. That pane is the review's `requestedTargetPaneID`, with the
  review approved or completed and the image in its sent pack. Naming a
  digest in a message grants nothing. Until review, any handoff whose text or
  result held the digest granted it. A returned file named by its digest
  therefore reached the lead through Parley's own receipt before the person
  had seen it, and a digest learned that way could be passed on.
- **Transport:** `context draft`, `context add` and `done --file` carry the
  bytes in the request body. It is read through `RelayRequestFields.readData`
  up to the image bound, and anything without an image signature must then
  meet the 200,000-byte text bound and be UTF-8. A file over 10 MB is
  refused from its size before it is read
  (`RelayFileTransportError.fieldTooLarge`). A larger non-image file is read,
  then refused; both refusals name both bounds. At most four staging bodies
  are held at once (`stagingSlots`). A slot is given back when its request is
  dropped, and a fifth waits up to 30 seconds, then is refused with nothing
  staged.
- **Checks:** `ImageEvidenceChecks` covers the inspector, the store, the
  part, staging through all three commands, fetch authorization (relayed and
  digest-named cases included), deletion, the pins, room-making, and the
  shim end to end with a reply cut short by a file-size limit.

**Window capture** (2 October 2026, MR B). The person's own context pack can
take one window the person picks, captured once. The steps:
- **Picking:** **Capture Window…** shows the system window picker
  (`SCContentSharingPicker`, single-window mode, switched on only while
  picking), and `SCScreenshotManager` captures one still image.
  `WindowCapture.swift` is the only file that imports ScreenCaptureKit, and a
  check pins that.
- **Encoding:** the capture is PNG, or JPEG when the PNG would pass 10 MB,
  and it is refused if neither fits.
- **Who can start one:** no agent route starts a capture. The person may add
  one to an agent's draft awaiting review (`AgentContextTrustedCaptureKind
  .windowCapture`, 3 October 2026). The core adds it only while the person
  holds it, and saves it with the review.
- **The part:** it is `ContextPackSourceKind.windowCapture` with an `image`.
  In the person's own pack it is never saved, because that pack is never
  saved. Added to an agent's draft, it is saved with that review until the
  review is resolved and deleted or pruned.
- **Holding:** the core has no record of the person's pack, so the app tells
  it which images the pack holds (`/ui/context-images/hold`,
  `holdPersonImages`; a set replaced each time, memory-only). It does that
  before it writes the copy into the same store, as staging pins first. The
  hold is re-sent whenever the pack changes (`contextPackDraft`'s `didSet`).
- **Sending:** the pack goes through the native `/ui/ask` with its images
  (`RelayUIAskRequest.images`). `handleAskFromUI` accepts only images the
  person holds whose copy is intact, so the route grants no agent's image to
  anyone. The handoff records them (`RelayHandoff.deliveredImages`, absent
  decodes as nil), and they stay kept while it is retained. Collection
  follows handoff pruning, Clear History and a smaller retention.
- **During a send:** the app holds the send's images from before it starts
  until it ends (`beginImageSend`, `endImageSend`). The pack is cleared as
  the send is launched, and a refused send restores it.
- **Compare and the busy queue** carry the person's own pack's images (3
  October 2026). An agent's draft is sent through its review route, not these:
  - **Compare:** each child Ask of the person's Compare records them
    (`RelayUIAskManyRequest.images`).
  - **Busy queue:** a queued draft keeps them (`ReviewedBusyDraft.images`),
    and collection keeps a queued draft's images. Its explicit send attaches
    them as `deliveredImages` after checking each copy is intact. Cancelling
    the draft releases them.
  - **Native routes only:** a check finds every call that hands images to
    `handleAsk` and requires it to sit in a native route.
- **Core recovery:** AppModel builds the replacement core holding the open
  pack's images (`retainingPersonImages`, the broker's `personImageHolds`).
  Its start would otherwise collect an unsent capture, which Codex's review
  of MR !139 found. A changed `relayClient` resets the app's held set and
  holds again through the new core.
- **Status Center:** a handoff shows its **SENT IMAGES**.
- **Hand checks:** whether macOS asks for Screen Recording permission for the
  picker, and how the bundled app behaves, are hand checks
  (`docs/test-scenarios.md` P1.7).

Native **Delete Saved Context** (`/ui/context-reviews/delete`) permanently
removes selected records, including `returnedPart`, from both the store and
broker. Every selected revision is checked before any removal; waiting and
approved deliveries are refused. Agent discard remains a retained state
change. **Clear history** also removes deletable context in scope, using the
recorded workspace identity or a durable handoff link; old unbound context is
removed only by global clear or explicit context deletion. Closed workspaces
with retained records remain selectable in Status Center. New context records
capture their source workspace; legacy records decode absent identity as nil.
Deletion never follows a source path to remove an original project file.
Command history deletion holds coordinator then broker locks, clears finished
worker artifacts after fresh lease checks, and forgets recovery copies only
for durably removed handoffs. Only request-identity hashes remain in memory to
refuse replay of a deleted command during its originating pane launch, with no
command or result text. A restarted pane has a new request-identity namespace. Waiting
approvals, active work and running
workers are preserved. Independently atomic store failures report partial
completion and immediately publish only the successful removals.

Context-review validation, durable recording, in-memory replacement and
broadcast share one mutation lock. Approval and rejection carry the exact `updatedAt` revision shown in the UI
and must fail stale if the draft changed. Rejection accepts only a waiting
Ask; a plain draft uses the revision-checked discard route.

Direct completion belongs to the app-resident core. Record approved before
terminal input and failed delivery as terminal `.failed`. A delivery followed
by persistence failure must state that delivery occurred and warn against
resending. Keep rendered packs at 90 KB and control bodies at 200 KB.

A person's **Ask One Pane** on an agent-staged draft (`completeContextDraft`)
is one correlated Ask through the same engine as the toolbar Ask, from the
draft's source pane to the chosen target with human origin and the key the UI
minted, so the target answers with `parley answer <id>` and Status Center
shows the question and the returned result. It is not a direct paste: v0.1.40
pasted the pack and recorded no handoff, and the reply only ever appeared in
the target's terminal. The review is approved before any terminal input,
completed (naming the handoff) once the Ask is accepted, handed back to
`.draft` with a "Not sent" detail when the Ask is refused before any input
(a busy target, which leaves no handoff, or a writer refusal
`ParleyWorkbenchError.refusedBeforeInput` recognises, such as Copilot's
folder trust not yet confirmed, which `handleAsk` reports through
`onWriterFailed`), and `.failed` whenever input may have begun: a delivery
that failed after its paste, and an Ask cancelled or interrupted while its
text was being pasted. Until 29 September 2026 only a failed handoff
counted, so a send cancelled mid-paste went back to a sendable draft
(0bfdfb2a), while one the writer refused before input, which sent nothing,
was closed for good. The
call returns with the answer or the consultation timeout, which is why it is
a tracked request and runs off the main actor. The agent's own `parley ask
--context` follows the same rule since 28 September 2026 (the writer's own
refusal since 29 September): approved, then refused before any input, it
goes back to `.draft` ("Not sent")
instead of `.failed`, which lost the approval. Its approval timeout is saved
through `persistContextRealityLocked`, so a failed save is kept and retried
rather than leaving a pending approval on disk. Every context review save
goes through `recordContextReviewLocked`: the store keeps at most 100 reviews,
never pruning a draft, a waiting Ask or an approved review still being
delivered, and returns the ones it pruned, which leave the broker's map too (the map
used to keep every one, so Status Center listed reviews the store had
dropped).

Sending an agent-staged draft (approving the agent's waiting Ask or
sending it as the person's own Ask) closes the sheet before the tracked
request runs, so a failure used to lose the person's edits (844fa81d). After
any failed send the app reads the review fresh and `ContextSendRecovery`
decides. If the review is still `.draft` or `.awaitingReview` and unchanged
apart from what was sent (same revision, or the stored parts and note equal
the sent pack), nothing was delivered: the edits reopen at the review's
current revision, state and target, and a resend is accepted. If the agent
changed the draft meanwhile (added a part, or turned it into an Ask; the
core's stale-revision refusal), the draft opens as the agent left it and the
edits are offered to copy, because reopening the old copy at the new
revision would drop the agent's part or approve a request the person never
saw. A `.completed` review was delivered and says so. Anything else, or an
unreadable review, offers the edits to copy and never reopens them for a
second send. `ContextSendRecoveryChecks` drives every case through a real
broker.

Every UI control request that uses `trackedResponseTimeout` (Ask, Ask-many,
request changes, busy-draft send, context approve and context complete) runs
inside `Task.detached`, never on the main actor. Those requests return only
after the core has delivered into the target pane or an answer has arrived,
and the core delivers through `DispatchQueue.main.sync`; a main thread parked
in `recv` can never service that hop. v0.1.40 froze on a context-pack Ask for
exactly this reason, until the person force-quit it. `RelayCoreClient` now
refuses a tracked request made from the main thread before it touches the
socket, so a call site that forgets gets an alert instead of a frozen app;
short reads such as the refresh tick stay allowed on the main thread. The
same refusal covers every short route whose core side reaches a pane (22
September 2026, M3): Retry Delivery (`retryHandoff`, a paste) and trusted
capture into an agent draft (`captureTrustedContext`, a selection read
through `main.sync`, a 15-second command or several Git reads). Both
previously froze the UI for their 3-second timeout and reported a failure
while the delivery or capture happened anyway. They pass `reachesPane: true`
and `paneReachingResponseTimeout` (45 s), and AppModel runs them detached;
capture holds `contextCaptureInFlight` so a second click cannot add a
duplicate part, and a selection is cleared only after the core has read it.
While any capture into the open pack runs (`contextPackCaptureRunning`,
including the person's own Git Diff, now also detached, and Command Result),
Ask, Compare, Decline or Discard and every add-source button wait, because
an agent draft's revision changes when the capture lands. A second Retry of
the same handoff is ignored while the first is in flight.
A new UI route that pastes into or reads from a pane must set `reachesPane`.
Review Changes reads its repository in a detached task as well (up to five
Git commands with 5 s timeouts ran on the main actor until 29 September
2026) and rechecks both panes' generations before its editable preview.

## Roles and mobility

Roles are owner-controlled metadata independent of display name. Use
`@reviewer` locally and `workspace/@reviewer` across workspaces. Do not fall
through from role to mutable display name. Roles are lowercase bounded slugs,
unique per workspace; vendor names and `lead` are reserved.

Move preserves the exact retained Ghostty surface, pane id, process, vendor
session, scrollback, credential and folder. Refuse moving any pane with an
active handoff, or a role/lead collision (moving the last pane out leaves an
empty source workspace); revalidate topology
after confirmation. The active handoffs come from the broker's own active
listing (`/handoffs/active`, every handoff not yet terminal), as does Prepare
to Uninstall's; both read the newest 500 of the history until 29 September
2026, which held every active handoff only because retention keeps at most
500 finished ones. Team templates and configuration clone were removed in the
September 2026 reduction; saved layouts remain. Saved agent leaves and their
default folder use the reviewed launch folder, while Shell leaves keep their
current folder. A restored layout reopens with the automation policy it was
saved with; `createWorkspaceLocked` takes the policy as a required argument
(until 23 September 2026 every restore reopened as Ask and Delegate). A
restore validates that every pane it replaces may end, builds and saves
against a snapshot it puts back on any failure, and ends the replaced panes
only after the new state is saved; its rollback puts back the recorded
host launch permissions too.

Each workspace's native split tree, split fractions and selected pane live in
`workspace-registry.json` (`WorkspaceRegistry`, at most 200 records). A
record outlives its workspace's absence from the workbench, and closing a
workspace removes it. A saved layout replacing a workspace now removes the
replaced record as well. Until 30 September 2026 it did not, so records built
up, and once 200 were held every new workspace silently lost its layout,
because the callers use `try?` (Prax a444e68e). `synchronize` is given every
live workspace. When a new one needs a record in a full registry, it drops the
absent workspace unused longest, and it refuses only when all 200 records are
live. Closing a workspace checks every pane
(`requireTerminableLocked`) before ending any, so a container not confirmed
stopped refuses the close without ending its siblings, and then does the
same: it saves the workspace's removal and ends the panes only once that is
durable.

Every lifecycle route is all or nothing (29 September 2026, from Agy's review
of MR 106 and the fresh-context review of this change). A route that ends a
process (close pane, stop, close workspace, restore, shutdown) checks, saves
the change, puts the document back if the save fails, and only then ends
the surface; each ended the surface first, so a state file or credential
store that could not be written left a pane gone or stopped in the window
while the error said it was not, and back at the next launch. A route that
starts or creates one (start, the second half of restart, create pane,
create workspace) puts the document back when its save fails, rather than
leaving a pane reading started or listed, with a surface mounted for it,
that the saved state never held; restart's first half has already ended
the old process and saved the pane stopped, and it stays that way. A move
that cannot be saved puts the document back. After the save the surface
ends through `endSurfaceLocked` (`endAllSurfacesLocked` for shutdown),
which raises `terminatingDepth` like `terminateSurface` but does not check
again: the check reads the document, so after the change it can refuse a
pane that passed (a removed pane still holding a prepared container
receipt, or any container pane once shutdown has advanced every
generation) and would leave its process running behind a saved close. The
close Ghostty reports from inside the ending finds the pane gone or at a
newer generation and changes nothing, and `terminalDidClose` ignores a
report for a pane that is not started, which has no process to report on.
A Team Stop whose save fails therefore reads failed and stays retryable;
stopped-but-unrecorded remains for a stop that fails after the state changed. A credential that cannot be forgotten
afterwards names no running pane and is left, not reported.

## External integration boundaries

External workspace opening accepts exactly one existing canonical directory
through `parley open`, Finder, the document role or `parley://open?folder=`. It
can focus or create a normal shell workspace. It cannot carry prompt text,
choose a vendor, start an agent or inject terminal input.

Parley publishes nothing for external editors. The VS Code companion, its
`.parleycontext` import, the capability and acknowledgement files, the
published attention snapshot and the `parley://focus` and `parley://status`
URLs were removed in the September 2026 reduction. The attention projection
remains in process for the menu-bar indicator: it reads handoff metadata and
produces a content-free snapshot; the menu-bar summary reduces that snapshot
to coreAvailable, totalCount and headline, and the menu presentation receives
only those three fields, never a RelayHandoff or an item label.

## Shared protocol launch behavior

Increment `AgentProtocol.version` whenever canonical semantics change.
`ProtocolDriftChecks` pins a SHA-256 of `AgentProtocol.text` beside the
version (donkeykong's drift gate, taken on 14 September 2026): a wording
change that forgets the bump fails the suite with the new digest in the
message, and pinning both is the deliberate act. A live
pane with a mismatched stamp shows **RESTART FOR PROTOCOL**. UI remounting cannot
alter an existing model context.

- Claude Code appends the protocol with `--append-system-prompt` and receives
  generated lifecycle hooks through an additional `--settings` file. When the
  profile allows shell execution that file also carries `permissions.allow`
  rules for Parley's own command (`Bash(parley:*)` and the runtime-local shim
  path), the counterpart of Copilot's `shell(parley)`, so protocol commands do
  not prompt while every other shell command keeps Claude's prompt; a profile
  that asks before shell commands keeps asking for `parley` too, because
  Claude evaluates deny, then ask, then allow and specificity does not change
  that order. Flexible allows both execution rules since 13 September 2026
  (Mark's decision after it had asked before every Bash command), so it places
  no shell restriction on any vendor; Default and Workspace folders still ask.
  A host team
  is therefore supervised automation unless the person chose the vendor's
  automatic reviewer for that vendor (Claude auto mode, Codex auto review,
  Copilot assisted approval), which answers prompts inside the vendor's rules
  and can still refuse: without it Codex asks on sandbox escalation, Agy
  asks before commands and has no allowlist or reviewer (only
  `--dangerously-skip-permissions`, which invariant 3 forbids on the host).
  Members with the automatic reviewer or an approved container bypass are the
  ones that run unattended. Help, the protocol and the team approval say so
  (they said "not unattended" until protocol 33 on 23 September 2026, which
  contradicted the form).
- Codex receives the protocol through `developer_instructions` and generated
  lifecycle hooks through fixed inline `-c` values. Codex parses each `-c`
  value as TOML and, if that fails, silently uses the whole value as a literal
  string, so every string Parley puts in one (protocol, hook commands, host
  permission paths) goes through `TOMLString.basic`, never a `JSONEncoder`:
  JSON's `\/` is not a TOML escape, and until 22 September 2026 every Codex
  pane received the protocol as one escaped line for that reason.
  `CodexTOMLChecks` reads each value with a strict TOML string reader.
- Agy is passed generated `agent-protocol/AGENTS.md` through `--add-dir`.
  Automatic rule loading from that added directory remains unverified; do not
  claim uptake without the fresh/resumed-session check in RELEASING.md. No
  lifecycle adapter is installed because Agy has no verified per-launch path.
- Copilot receives the canonical text as additional instructions through
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. Applicable instructions are combined
  without a general precedence order. It permits only `shell(parley)` without an
  extra tool confirmation and loads generated lifecycle hooks through
  `--plugin-dir`.

Do not maintain separate handwritten protocol wording per vendor.

`parley help` (also `--help` and `-h`) and `parley protocol` are local,
read-only references generated from AgentProtocol. They work without a broker
or pane credential. All agent launches receive `PARLEY_COMMAND` for an absolute
shim fallback if PATH changes; vendor tool approval still applies. The launch
stamp is configuration evidence, not proof of model uptake. Never overwrite
another project's instruction files to add Parley awareness. This repository's
`CLAUDE.md` is a relative symlink to its existing `AGENTS.md`.

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

Never report work as done because it was written. Run it.

For non-trivial logic, write the failing check first, observe it fail, implement
and observe it pass. After changing app or core source:

```bash
npm test
npm run build
```

`npm run scan:public` reads `git log -p` line by line from a stream, so the
history has no size limit. It was read into one 128 MB buffer until 30
September 2026, and would have failed closed once history outgrew it (24.8
MB then, Prax c4a09fbe). Every rule and deliberate fixture fits on one line,
which is what makes the line-by-line scan equivalent. The read and git's exit
are awaited together, and git is stopped on the way out. Of the working-tree
paths it reads only regular files: `git ls-files --others` lists a nested
worktree under `.worktrees/` as a directory, which crashed the scan with
EISDIR.

`npm test` also runs the platform dependency scan. `ParleyCore` is the part of
Parley that could one day run somewhere other than macOS, and
`scripts/platform-dependency-scan.mjs` records exactly which of its files may
carry a platform import. It is a ratchet: a new file taking one fails, and a
listed file that stops needing one also fails, so the baseline tightens rather
than going stale. Change that baseline only as a deliberate decision.

Two tools support the seam work that shrinks that baseline.
`scripts/type-closure.mjs <TypeName>` reports what a type actually depends on,
following stored properties and enum associated values, and says how much of
that sits in platform-importing files. Follow referenced types rather than file
lists: a file-level guess over-reported one closure by more than double.
`scripts/lift-declarations.mjs` moves whole declarations between files and is a
dry run unless given `--write`.

After any lift, confirm it was a move rather than an edit by comparing removed
against re-added lines in the staged diff. A green suite will not notice a
renamed enum case, and these types are `Codable` and persisted in the handoff
journal, so that would be a silent migration of existing records.

It guards imports, not APIs. A Linux build additionally needs the guarantees
behind those imports re-derived rather than renamed — `LOCAL_PEERPID`,
`O_EXLOCK`, `O_EVTONLY`, `renamex_np`, `POSIX_SPAWN_CLOEXEC_DEFAULT`,
`SO_NOSIGPIPE`, `proc_pidinfo`, `KERN_PROCARGS2`. A file-level split of
ParleyCore is not currently possible: the platform-importing files define the
domain vocabulary the rest consumes, so extracting the 65 import-free files
alone fails with thousands of missing-type errors. Seams must move those
definitions first.

A check must leave nothing behind outside the repository, and a per-run unique
name is how that goes wrong quietly. `UserDefaults(suiteName:)` writes to
`~/Library/Preferences`, `removePersistentDomain` empties the domain but leaves
the file, and `cfprefsd` can write an emptied domain back after the check
returns — so deleting the file is not enough on its own. Name such a domain
fixed rather than per-run and clear it on the way in as well as out, so the
count is bounded however many times the suite runs. A UUID per run accumulated
1,626 files before anyone looked. The same goes for
`RelayFileTransport.runtimeDirectory(applicationDirectory:)`: it is the real
runtime path under `/private/tmp`, and a fixture that used it for its
transport left one folder per run (51 by 26 September 2026, c2c4c1c8). A
fixture's transport lives inside the fixture's own folder.

The checks binary is an unbundled executable, so AppKit gives it a prohibited
activation policy: none of its windows can become key, and a window-state check
sees only the window server's occlusion notification. That arrives tens to
hundreds of milliseconds after the ordering call, later on a loaded runner, and
is coalesced, so a window ordered out before the server ever reported it on
screen changes nothing and posts nothing. Minimise and deminiaturise take
effect about half a second after the call there as well. A step that acts on a
window therefore waits, bounded, for the fact it needs (on screen, mounted,
released) and reports the window's facts when the bound passes. A fixed delay
after the call was the auxiliary window check's flake, and reading
`isMiniaturized` right after `miniaturize` reported minimise unavailable for a
week while the window was merely still on its way to the Dock.

For terminal/lifetime changes also run the Ghostty soak. Default checks must
not launch a vendor CLI, spend subscription quota, mutate unrelated user
processes or depend on network access. The explicit manual
`parley-native-checks --host-vendor-spike <absolute-codex-path>` check runs a
local Codex config query and sandbox probes with disposable configuration and
synthetic files. It starts no model or signed-in session. CI runs deterministic
checks and the native build on macOS with complete Git history for the public scan.

Since 19 September 2026 the GitLab jobs run on the self-hosted `macos`
runner through the Tart custom executor: a throwaway macOS VM cloned from
the digest-pinned image in `.gitlab-ci.yml`, with PATH holding only the
system directories, so the job fetches the pinned nodejs.org build and
names every toolchain path itself (the runbook is in Prax, "macOS CI/CD on
Apple Silicon with Tart and GitLab Runner"). The VM has no Docker runtime,
and the two container checks that need one refuse rather than skip, so both
jobs pass `--skip "container bypass preflight,container follow-up image
probe"` to `parley-native-checks`. `--skip` prints one `SKIP` line per check
and counts them in the summary; a skipped check is never a passed one, and
`npm test` itself skips nothing. `npm run test:checks` and
`npm run test:scripts` are the two halves `npm test` is composed from, so a
pipeline can pass that argument without restating the suite.

The GitLab `prepare-production-release` job is manual and restricted to
protected version tags. It imports protected signing/notary variables into a
temporary keychain, deletes signing material on exit and emits verified
production assets as successful-job artifacts only. It never publishes or
changes the stable feed; public distribution remains an explicit reviewed
action. The beta job remains separate.

The manual release jobs must pass the 25-round eight-pane soak, write the
standalone JSON report, include it in SHA256SUMS and attach it to the release.
The notarized release must also Developer ID-sign nested Sparkle code
inside-out, notarize and staple the app and DMG, pass Gatekeeper assessment,
and generate a matching Ed25519-signed appcast and SHA-256-pinned cask. Missing
credentials, signatures, notarization, appcast signing or soak evidence must
fail the release closed.
Publishing a release may propose the generated cask through a branch and pull
request; release automation must never push it directly to main.

## Version policy

Never recall package or tool versions from memory. Verify the authoritative
registry at query time. For GitHub packages and releases use the GitHub latest
release API; for mise-managed tools use `mise latest <tool>`.

Before changing Ghostty's exact wrapper pin, verify the current
`Lakr233/libghostty-spm` release, confirm the embedded upstream Ghostty release
and inspect relevant release notes. Keep `Package.swift`, `Package.resolved` and
`THIRD_PARTY_NOTICES.md` consistent.

Never pin a wrapper whose Ghostty commit lacks upstream `72cf508`
("renderer: never stop the display link while holding the draw mutex",
ghostty-org/ghostty#14150); check with GitHub's compare API, where the pinned
commit must be `ahead` of it with `behind_by` 0. Without it the renderer
thread called the blocking `CVDisplayLinkStop` while holding `draw_mutex`, the
main thread's CoreAnimation layer draw waited on that mutex, and a CoreVideo
stall around sleep and wake froze the whole app: v0.1.60 (wrapper
1.6.20260909, Ghostty `82938b63`) hung 44 seconds after a wake on 23 September
2026 and had to be force-quit. Wrapper 1.6.20260922 (Ghostty `3c47ca15`) is
the first release carrying it.

Before changing Sparkle's exact pin, verify the current official GitHub release
and its Swift Package Manager artifact digest, inspect its security and release
notes, and keep `Package.swift`, `Package.resolved` and
`THIRD_PARTY_NOTICES.md` consistent.

## Repository safety

- Preserve unrelated user changes in a dirty worktree.
- Use conventional commit messages and branch instead of committing to main.
- Never force-push main.
- Before every commit, scan staged files for AWS keys, private keys, passwords
  and tokens, then run `npm run scan:public`.
- Agent commits include `Co-Authored-By: Claude <noreply@anthropic.com>`.

## September 2026 low review follow-ups

Approved command tickets bind the app owner to its kernel process start time
as well as PID; legacy tickets without that identity cannot execute. Before
handing over to the login shell the worker restores default signal dispositions
and clears the inherited signal mask. Container discovery and decoded cleanup
configurations share the same fixed Docker executable allowlist.

Worktree Predict reads identity without creating a tracking record. Integrate
validates the branch before proposing argv. A bare Git registry entry is labelled
as bare, never as a primary checkout; a repository without a primary checkout
cannot be an implicit Integrate destination.

The worktree low findings of the 22 September review (b1cb3901), fixed on
23 September 2026:
- Integrate names the branch by its full ref (`WorktreeIntegration.mergeArgv`),
  because Git resolves a short name to a same-named tag first.
- The current branch is read from `symbolic-ref --quiet HEAD` with
  `refs/heads/` stripped, never `--short` or `--abbrev-ref`, which answer
  `heads/v2` beside a tag `v2` and lost the upstream.
- `remove` takes the action the person confirmed (`WorktreeCleanupAction`);
  a confirmed record-only clear refuses if a tree is back at the path.
- Remove integrated and unused… labels each tree from facts read beside its
  fresh preview (`WorktreeBulkRemovalPlan.freshState`) and skips one that no
  longer reads either.
- A permission or privacy denial reads unknown, never Missing.
- Status porcelain is sliced as bytes, so a path beginning with a combining
  mark keeps its first letter.
- The relocation scan runs only for a record whose folder is gone, and Finish
  inspects the row it opened on first.
- A post-prune state that cannot be read is reported as unknown.
