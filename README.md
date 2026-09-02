# Parley

Parley is a native macOS workbench for visible, supervised collaboration
between AI coding CLIs from different vendors. Claude Code, Codex, Agy and
GitHub Copilot CLI keep their own models, subscriptions, authentication,
permission prompts and terminal interfaces. Parley supplies the shared
workspaces, panes and local coordination around them.

Parley uses subscription CLIs already installed and signed in on the Mac. It
does not contain API-key fields, call model APIs directly, hide vendor activity
or bypass a vendor's approval flow.

## What works

- Native SwiftUI workspaces with embedded Ghostty terminal surfaces.
- Independent shell, Claude Code, Codex, Agy and Copilot panes.
- Clear selected-pane borders and direct Ghostty mouse selection, copy and
  scroll behavior.
- Explicit cross-vendor Relay, Paste, Ask, Answer, Delegate, Done, Fail, Status
  and Wait commands.
- Human Ask and Return previews, correlated answers and tracked delegation
  receipts.
- Smart Plan → Review → Implement → Verify orchestration in Supervised and Auto
  modes. Auto advances only from correlated answers and always stops for the
  person's final completion decision.
- Durable local handoff history and Status Center recovery actions.
- A native Task Manager with truthful app and pane CPU/RSS sampling, exact
  Ghostty TTY process attribution, workspace hierarchy and confirmed pane-level
  controls.
- Folder-backed workspaces, favourites, saved layouts, portable team
  templates, stable roles, workspace leads, pane move and configuration clone.
- Reviewed context packs, workspace briefs, pinned snippets, Git diff/file
  capture and a VS Code companion with an explicit source composer, in-memory
  Context Basket, collaboration sidebar and correlated preview acknowledgement.
- Production and Development runtime isolation.
- Pane-scoped relay capabilities and a macOS Seatbelt boundary around every
  vendor process tree.

## Lifetime contract

Ghostty owns the real PTY, process, vendor TUI, terminal modes, selection and
scrollback for each pane. Parley retains those Ghostty surfaces at the
application level rather than tying them to one SwiftUI view mount.

- Closing or hiding Parley's main window keeps every pane and the coordination
  core running while the Parley application remains open.
- Reopening the window shows the same retained panes and processes.
- Closing a pane or workspace explicitly ends the processes it contains.
- **Stop Everything**, **Prepare to Uninstall** and a confirmed full application
  quit end every pane process and the app-resident coordination core.
- After a full quit, workspace definitions and local history remain. Shell
  surfaces can be recreated on the next launch; agent panes return as stopped
  placeholders because Parley never pretends a vendor conversation survived.

There is no separate background coordination executable and no external
terminal multiplexer. The application is the process-lifetime boundary.

## Cross-vendor collaboration

Each agent pane receives one durable random credential for its real sender
identity and the shared `parley` command. A caller cannot claim to be another
pane.

```text
parley relay <target> <text>
parley paste <target> <text>
parley ask <target> <question>
parley answer <id> <answer>
parley delegate <target> <task>
parley done <id|current> <report>
parley fail <id|current> <report>
parley status
parley wait <id|current>
```

Targets are explicit pane ids, unique vendors or stable roles such as
`@reviewer` and `workspace/@reviewer`. Parley refuses missing, ambiguous,
same-pane, shell and busy targets. Same-vendor routing is allowed only between
distinct panes.

`relay` submits immediately because that is the capability the person selected.
`paste` is the explicit review-before-send route. Multiline content is passed
through Ghostty paste as one payload; submission is a separate Enter event, so
the first newline cannot submit a truncated prompt.

Parley never infers thinking, token use, cost, context limits, permission state
or completion from terminal text. Status contains only facts Parley owns or
structured values a vendor exposes authoritatively.

## Product direction

Parley's official direction is a vendor-driven, cross-vendor coordination
layer. Vendor CLIs own reasoning, research, browser tools, plans, tasks,
subagents, memory and model-specific integrations. Parley owns retained panes,
authenticated identities and handoffs, durable receipts, human review,
lineage, recovery and authoritative lifecycle events.

The unreleased Research Board experiment and the separate Handoff Chains
surface have been retired. Their independent models and UI are removed;
ordinary broker handoff history, receipts, recovery controls and Workspace
Briefs remain. Useful primitives—human verdicts and notes,
verification/challenge lineage and reviewed multi-result Context Pack
promotion—will move onto handoffs in Status Center. Any legacy
`research-board.json` or `handoff-chains.json` file is left untouched but is
not loaded by the app; neither file is a stable format or protocol to integrate
with.

The committed phases, migration guarantees and explicit non-goals are in the
[roadmap](ROADMAP.md#official-direction-vendor-driven-parley-coordinated).

## Smart orchestration

The existing bounded recipe remains available, but expansion of first-class
workflow windows and Smart Auto is frozen until Parley's authenticated target
discovery and authoritative vendor-event layer are proven.

Mark one ready agent pane as the workspace lead, then open **Recipes → Smart
Orchestration → New Plan → Review → Implement → Verify**. Choose explicit
reviewer and verifier panes, select a mode and enter the exact objective.

- **Supervised** pauses at every handoff. The person inspects and may edit the
  exact plan, critique, implementation instruction and verification evidence.
- **Auto** advances Plan, Review, Implement and Verify only when each target
  returns one correlated Parley answer. Every automatic delivery and workflow
  transition is labelled **AUTO** and remains visible in history.
- Starting Auto authorizes the bounded implementation stage. It never bypasses
  a vendor permission or folder-trust prompt, never guesses completion from
  terminal text and stops if an exact handoff fails or the workspace automation
  policy is switched Off.
- Both modes stop at Completion Approval. Only the person can review the saved
  evidence and mark the run complete.

Closing the main window does not stop an active run because the application and
its retained panes remain alive. Full application quit ends the current Ask and
records an unfinished Auto run as interrupted; it is never silently resumed on
the next launch.

## Workspaces and panes

A workspace is a named collaboration container with:

- zero or more explicit folder attachments used for folder opening and search;
- a separately optional New Pane Folder;
- a native split tree containing retained Ghostty panes;
- one automation policy and optional workspace lead;
- durable owner-controlled pane roles.

**New Workspace** creates a normal folderless container. **Open or Focus
Folder** is the folder-first fast path. Existing panes keep their own live
working directories when attachments or the New Pane Folder change, and those
metadata changes never grant filesystem permission. Several workspaces may
intentionally attach the same folder. Opening a folder focuses one match, asks
when several match, or creates a normal folder-backed shell workspace when none
exists.

Agent folder access is pane-specific and reviewed. The **Workspace folders**
permission profile can grant selected workspace attachments as exact roots when
an agent starts. For a running agent, **Folder Access…** shows its working folder,
checked attachments and any other reviewed roots; applying a change explicitly
restarts that vendor session while preserving the pane and working folder.
Attaching or detaching workspace metadata never mutates a running pane's access.

Move transfers the exact retained pane, process, terminal state, credential and
folder. Clone copies visible configuration only and never copies a process,
vendor session, terminal history or credential. Agent clones remain stopped
until a person starts them.

Saved layouts and team templates contain portable configuration, not live ids,
paths from another machine, credentials or terminal content. A team can be
applied folderless; its agents remain stopped and unbound until their working
folders and permissions are reviewed explicitly.

## Local architecture

```text
SwiftUI workspace tree
  └─ GhosttyPaneRegistry
       └─ one AppTerminalView + real PTY/process per pane

AppResidentCoordinationCore
  ├─ authenticated control socket for the native UI
  ├─ pane-capability filesystem relay endpoints
  ├─ RelayBroker consultations and delegations
  └─ durable local collaboration records
```

Product source lives under `native/`:

```text
native/Sources/
  ParleyCore/        protocol, relay, workbench state and domain services
  ParleyNative/      SwiftUI app, Ghostty host and app-resident core
  ParleyCoreChecks/  deterministic contract and real Ghostty lifecycle checks
  ParleySoak/        eight-pane Ghostty input/lifetime soak
```

The package links `GhosttyTerminal` through `libghostty-spm`. `Package.swift`
and `Package.resolved` are the authoritative dependency pins.

## Security boundary

- Vendor processes receive only their pane credential, managed relay command
  and canonical shared protocol.
- `AgentProcessBoundary` denies the broad Parley Application Support tree and
  relay transport root, then reopens only generated protocol files, the managed
  shim and that pane's capability-named endpoint.
- The endpoint authenticates both its token and exact filesystem location.
- Shell panes are deliberately unsandboxed human shells and are the explicit
  trusted side of this boundary.
- Agent-authored content is never interpolated into a shell command.
- Parley has no hosted service, sync, telemetry or remote-control backend.

The stable `~/.local/bin/parley` command is a runtime-neutral router for vendor
CLIs that rebuild `PATH`. Production is the default route; exact
`PARLEY_RUNTIME=DEV` selects the isolated Development runtime. The router has no
credential and no transport authority of its own.

## Requirements

- macOS 14 or later.
- At least one supported vendor CLI installed and signed in with its normal
  subscription flow.
- Xcode command-line tools and a compatible macOS SDK for development.
- Node from the machine's mise toolchain for the dependency-free task runner.

## Develop

No JavaScript dependencies are used at the repository root. Do not run
`npm install` there.

```bash
npm run dev
npm run dev:restart-protocol
npm test
npm run build
npm run test:soak -- --rounds 25
```

`npm run dev` uses `~/Library/Application Support/Parley Native Development/`
and a separate preference suite. The packaged app always uses Production under
`~/Library/Application Support/Parley Native/`. Development cannot install the
machine-wide stable router or publish Production attention state.

`dev:restart-protocol` deliberately restarts only stale agent panes. Normal
launch never restarts a surviving in-app pane.

The deterministic checks do not launch a vendor CLI or spend subscription
quota. The Ghostty checks and soak use real local shells, exercise more than
four panes, verify per-pane input isolation, hide the UI while input continues,
then verify every exact child PID ends at teardown.

## Package and release

```bash
npm run package:mac
npm run verify:package:mac
npm run release:mac
```

The app bundle contains one executable: `parley-native`. Ghostty and the
app-resident coordination core are linked into it. Packaging emits an app, ZIP
and DMG, validates the one-executable contract, signs the bundle and includes
the project and third-party licences. Ghostty's runtime bundle is installed in
`Contents/Resources`; release builds apply a guarded temporary overlay to the
official wrapper's resource resolver, restore the checkout after compilation
and fail closed if the expected upstream source shape changes.

`Prepare to Uninstall…` refuses active Ask or delegated work, ends every pane
and coordination endpoint, and quits. It leaves workspace definitions and
local collaboration history for a safe reinstall unless the person explicitly
chooses a separate data purge.

## Licence

Parley is licensed under Apache-2.0. Embedded third-party notices are in
`THIRD_PARTY_NOTICES.md`.
