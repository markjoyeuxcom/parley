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

1. **Subscription CLIs only.** Use locally installed, already signed-in vendor
   binaries. Never add API keys or a direct model API path.
2. **Real interactive sessions.** Preserve each CLI's TUI, prompts, permission
   flow and session behavior. Parley does not replace them with a chat UI.
3. **No approval bypass.** Never pass a `--dangerously-*` option,
   `danger-full-access` or an equivalent bypass.
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
npm run dev:restart-protocol
npm run test:soak -- --rounds 25
```

The root npm scripts are a dependency-free runner around
`scripts/run-native-swift.mjs`. Do not run `npm install` at the repository root.
The helper chooses a compatible installed macOS SDK and writable Swift caches.

`dev:restart-protocol` deliberately restarts stale agent panes. Normal launch
must never restart a surviving in-app pane.

## Layout

```text
native/
  Package.swift
  Package.resolved
  Sources/
    ParleyCore/
      AgentProtocol.swift              canonical agent-facing contract
      AgentProcessBoundary.swift       per-agent Seatbelt boundary
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

- A workspace is a named collaboration container.
- Each live pane is one retained Ghostty `AppTerminalView` with its own PTY and
  shell or vendor CLI process.
- `WorkbenchController` persists workspace/pane metadata in
  `workbench-state.json`; terminal bytes and vendor conversations are never
  serialized there. Terminal titles are the one hot input: a title is applied
  in memory at once (a repeated title changes nothing durable but still
  stamps pane activity), written at most once per second by a coalesced
  deferred write, and carried immediately by any other persist, stop, close
  or shutdown. Working-directory, attach, detach and close callbacks persist
  synchronously and run the full model refresh as before; a title change only
  publishes the pane list once per run-loop turn with no relay fetch or
  layout work, because no view renders titles today.
- `GhosttyPaneRegistry` retains views by pane id across SwiftUI remounts and
  main-window hiding.
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
  reset; selection lives in the model). Minimising or hiding the application
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
- Stop Everything, Prepare to Uninstall and confirmed full quit end every pane
  process and the coordination core.
- On a later app launch, workspace definitions remain, shells can restart and
  agent panes are stopped placeholders. Never claim a vendor session survived.

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
successful compaction, never reported as a lost record. Pane attention is projected once per input generation
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
`RelayPollPolicy` forces a fetch every fifteen ticks as a safety net. The
agent file transport polls each endpoint inbox every 50 ms while requests
are flowing and backs off to 250 ms after ten quiet ticks
(`TransportPollSchedule`), with a vnode watcher per inbox that wakes it at
once on a write, so an idle app neither scans inboxes twenty times a second
nor makes an agent wait on the backed-off timer.

Sparkle.framework is the sole application-update mechanism. Its bundled helper
processes may run transiently only during an explicit update check or
person-approved installation; they are not a Parley daemon, coordination core
or login item. Development must never start Sparkle or receive the Production
feed. Production automatic checking is opt-in, background installation is
disabled and updater-initiated termination must pass through the ordinary
pane-aware quit confirmation.

A workspace is durable identity independent of folders. It may have zero or
more explicit folder attachments used for opening and search, plus an optional
independently mutable New Pane Folder. Existing panes retain their live folders;
attachment changes never grant permission or mutate a process. Several
workspaces may intentionally attach the same canonical folder. Folder opening
focuses one match, asks on several or creates a normal folder-backed shell
workspace on none. New Workspace creates a folderless container with a safe
shell cwd that is not silently attached. Starting an unbound agent requires an
explicit working folder and permission review.

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
- `parley answer <id> <answer>` completes that waiting consultation.
- `parley delegate <target> <task>` creates tracked asynchronous work.
- `parley progress <id|current> <note>` lets the exact delegated target replace
  one bounded, control-stripped, agent-declared progress note. It is never a
  lifecycle transition and never counts as completion.
- `parley done|fail <id|current> <report>` records the exact result.
- `parley done <id|current> --file <path>` completes a delegation only after
  a contained, bounded UTF-8 file is durably staged as an agent-provided draft
  for explicit human review. It never forwards the file automatically.
- `parley status` returns the caller's initiated work as JSON.
- `parley wait <id|current>` waits for one exact result.

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

Human Ask and Return submit only after an editable preview. A real current
Ghostty selection may prefill it; otherwise it starts empty. Never capture
scrollback or a whole conversation implicitly.

Ghostty appearance import is an explicit person action. Parse only bounded
font family, font size, theme, palette and hex colour values from the documented
XDG and macOS locations. Never load a raw Ghostty config into a terminal, follow
`config-file` or retain commands, keybindings, shell integration and behavioral
options. Custom theme files receive the same allowlist. Parley's explicit font
family and size overrides win over imported values.
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
substantial result returned with `parley done current --file <path>` may use
the plain Markdown template below. Status Center recognises the three ATX
headings, in any order, as one **COMPLETION EVIDENCE** block labelled
AGENT-DECLARED and shows every body as an unchecked claim. Unknown headings
and their bodies are ignored, the first occurrence of a duplicate heading
wins, an empty recognised heading is shown as declaring nothing, and a file
without the headings renders exactly as before. Parley never runs a command
to check a claim, adds no schema and never rewrites the staged file.

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
newlines as key events. Copilot may require briefly focusing the target for
paste/submit and restoring the person's previous pane; refuse delivery at its
folder-trust prompt. Copilot handoffs remain blocked until the person confirms
**Confirm Copilot Folder Trust** in its pane menu for that launch. Hooks cannot
grant this confirmation.

## Process and capability boundary

Spawn fixed executables with argument arrays. Agent-authored content must never
be interpolated into a shell command.

Every vendor process tree launches through `AgentProcessBoundary`. Its macOS
Seatbelt profile denies Parley's broad Application Support directory and relay
transport root, then reopens only generated protocol files, the managed shim
and that pane's capability-named endpoint. `RelayFileTransport` must reject a
valid token through a different endpoint. Shell panes remain deliberately
unsandboxed human shells.

Vendor CLIs may rebuild `PATH`. The runtime-local shim is preferred but not
guaranteed, so `~/.local/bin/parley` remains a runtime-neutral router. Exact
`PARLEY_RUNTIME=DEV` selects Development; an unset marker selects Production.
Only Production may install or upgrade the stable router. The router contains
no credential and no transport authority.

The relay transport path spelling granted by Seatbelt must exactly match the
path embedded in the shim. Filesystem aliases are not interchangeable in
Seatbelt subpath rules.

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
and vendor tool enforcement; normal vendor launches retain their boundary.

Per-run approval is the default. Optional exact-command session trust is native,
off by default, memory-only, revocable and visibly disclosed. It keys exact argv,
canonical folder and source generation and includes mutable code with human file
and credential access. Cross-vendor attribution cannot be guaranteed while it is
granted. Restart/move/folder/policy changes, Stop Everything and quit invalidate
it. Do not restore execution authority from the handoff journal. Separately,
**Settings > General > Agent command runs** holds the person's durable choice
to approve requested runs automatically. Both switches in that section are
execution authority and live in `CommandRunAuthorizationStore`
(`command-run-authorization.json`, owner-only, inside the agent-denied
application directory, narrowly validated on every read, anything odd reads
as off), never in a preference domain an agent process could write; nothing
reads them from an agent request or the journal. `AppModel` pushes the
approval choice into `ReviewedCommandRunCoordinator.setAutomaticApproval`.
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
never reports its process as ended by itself; in exit-when-clean mode the
released lease is the proof that the worker exited without exec'ing a shell
and nothing runs behind the surface. The worker outlives Ghostty's
abnormal-runtime threshold before exiting (monotonic clock) so no
failed-launch screen flashes. Ghostty reports a close synchronously from
inside `terminate`, and that report refreshes the app: every termination in
`WorkbenchController` goes through `terminateSurface`, and close, restart,
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
limit counts every creation for the session's lifetime. Members cannot add
panes or nest sessions. Every created pane keeps its vendor's own permission
prompts; Parley never answers them, never restarts a pane on an agent's behalf
and never restores team authority from any journal. Sessions appear as native
activity records for visibility only. The Team Sessions sheet is the
monitoring surface and never blocks provisioning; any other sheet or modal
does, and creation never steals focus from a visible window.

Ownership is pane id plus created generation. Stop revokes the grant and stops
only still-owned processes, leaving them as stopped placeholders; a pane the
person restarted since creation is skipped and reported, a moved pane stays
owned, and the lead, unrelated panes and in-flight Ask/Delegate work are
untouched. Actual stop failures are shown with a retry. The deadline bounds
provisioning only: expiry or interruption revokes the grant and stops nothing,
while "Stop team panes" stays available for still-owned running panes. Lead
restart, move, folder or policy change, an edited or removed approved profile,
Stop Everything and quit interrupt the session. Requests, decisions and pane
results are recoverable only by the same live requesting-pane generation.
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
owns it: `ManagedWorktreeService` runs a fixed `/usr/bin/git` with argv only,
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
grant is one folder inside the requester's working folder; only a created
tree is placed under `.worktrees/`. A grant is never widened to the
repository or to the shared `.git` directory: whether a vendor may commit
from a linked worktree is that vendor's own permission decision, and the
approval, help and protocol say so. A created tree whose approval then fails
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

Cleanup is person-triggered from the worktree browser, for Parley-created
trees only. `cleanupPreview` and `remove` each read every fact fresh:
registered and token-verified identity, lock and prunable state, other
registered worktrees or Parley-known trees nested inside the tree, this
runtime's pane folders (started or stopped, re-read again right before the
mutation) and the other Production/Development runtime's `workbench-state.json`
(an unreadable file refuses), `git status --porcelain=v1 -z --untracked-files=all
--ignored=matching`, the configured upstream from `branch.<name>.merge` with
`rev-list --count @{upstream}..HEAD`, and `merge-base --is-ancestor` against
the primary worktree. `WorktreeCleanupPolicy.decision` is the pure table:
a nested registered or known worktree, any live or placeholder pane inside
the tree, modified or untracked files, commits ahead of the upstream's local
remote-tracking state (a pushed but unmerged branch is allowed; the remote
is never contacted), no upstream and not contained in the primary's HEAD,
locked, prunable, unregistered, unverified identity, a non-directory item
at the recorded path, a path that cannot be inspected (only a confirmed
"no such file" is an absence), an unreadable state file, an unreadable worktree
registry, an unreadable record store, a target record missing from or
changed in the freshly read store, or an unanswerable Git question refuses;
a path with no filesystem item at all that a successfully read registry no
longer lists as present, with its record present and unchanged in a
successfully read store, becomes record-only cleanup that runs no Git
command. Every ignored entry Git would delete is shown in full in a
scrollable native list with control characters escaped (`displayPath`), a
directory entry meaning its whole contents; more than 200 refuses; the
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
"absent". Deferred: merge-tree previews, disk usage, merges, rebases, pushes,
stashes, automatic cleanup, automatic branch deletion, per-pane worktrees and
multi-folder grants.

## SwiftPM inside agent panes

SwiftPM compatibility is available in **Settings → General → Swift package
builds** and is off by default. After explicit human opt-in, newly launched
agent panes receive a runtime-local `swift` wrapper for SwiftPM `build`,
`test`, `run` and `package`. It adds SwiftPM's `--disable-sandbox`
option to avoid unsupported nested macOS sandboxes. Project and dependency manifests and plugins run
with the agent's existing permissions, including any permitted network access.
Parley's outer boundary and vendor approvals remain active. The setting only
automates a SwiftPM flag; it does not expand the agent's existing permissions.
The no-approval-bypass invariant still applies to all vendor launch permissions
and Parley's mandatory boundary; this opt-in affects only SwiftPM's additional
subprocess sandbox.

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
merely from being inside Parley. Tests that themselves create another
Seatbelt sandbox or need an unrestricted UI process may still require a
human Shell pane; report those limits rather than silently skipping checks.

## Reviewed context boundary

An agent-staged context part is a claim. Its path and bytes stay labelled
`agentFileDraft`. Only a separate human-authorized capture may create trusted
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

Context-review validation, durable recording, in-memory replacement and
broadcast share one mutation lock. Approval carries the exact `updatedAt`
revision shown in the UI and must fail stale if the draft changed.

Direct completion belongs to the app-resident core. Record approved before
terminal input and failed delivery as terminal `.failed`. A delivery followed
by persistence failure must state that delivery occurred and warn against
resending. Keep rendered packs at 90 KB and control bodies at 200 KB.

## Roles and mobility

Roles are owner-controlled metadata independent of display name. Use
`@reviewer` locally and `workspace/@reviewer` across workspaces. Do not fall
through from role to mutable display name. Roles are lowercase bounded slugs,
unique per workspace; vendor names and `lead` are reserved.

Move preserves the exact retained Ghostty surface, pane id, process, vendor
session, scrollback, credential and folder. Refuse moving the last source pane,
any pane with an active handoff, or a role/lead collision; revalidate topology
after confirmation. Team templates and configuration clone were removed in the
September 2026 reduction; saved layouts remain.

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

Increment `AgentProtocol.version` whenever canonical semantics change. A live
pane with a mismatched stamp shows **RESTART FOR PROTOCOL**. UI remounting cannot
alter an existing model context.

- Claude Code appends the protocol with `--append-system-prompt` and receives
  generated lifecycle hooks through an additional `--settings` file.
- Codex receives the protocol through `developer_instructions` and generated
  lifecycle hooks through fixed inline `-c` values.
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

For terminal/lifetime changes also run the Ghostty soak. Checks must not launch
a vendor CLI, spend subscription quota, mutate unrelated user processes or
depend on network access. CI runs deterministic checks and the native build on
macOS with complete Git history for the public scan.

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
