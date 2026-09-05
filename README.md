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
- One shared terminal appearance for every shell and agent pane, with explicit
  Parley font overrides and an allowlisted import of Ghostty fonts, themes,
  palettes and colours.
- Explicit cross-vendor Relay, Paste, Ask, Answer, Delegate, Progress, Done,
  Fail, Status and Wait commands.
- Human Ask and Return previews, correlated answers, recoverable Ask ids and
  tracked delegation receipts.
- Smart Plan → Review → Implement → Verify orchestration in Supervised and Auto
  modes. Auto advances only from correlated answers and always stops for the
  person's final completion decision.
- Durable local handoff history, Status Center recovery actions and explicit
  multi-select promotion of returned Ask or Delegate results into an editable
  Context Pack draft.
- A native Task Manager with truthful app and pane CPU/RSS sampling, pane
  process attribution anchored on Ghostty's TTY when the pinned terminal
  reports it or otherwise on the `PARLEY_PANE_ID` launch marker of the pane's
  own root process, workspace hierarchy and confirmed pane-level controls.
- Compact pane sidebar facts: exact working directory, fixed-argument Git
  branch state, bounded TCP listeners attributed to the pane-owned process tree
  and the latest official-hook or durable-handoff attention reason. Parley
  never derives these facts from terminal text.
- Folder-backed workspaces, favourites, saved layouts, portable team
  templates, stable roles, workspace leads, pane move and configuration clone.
- Reviewed context packs; workspace briefs with goals, decisions,
  person-authored investigation conclusions, rationale, confidence and open
  questions; pinned snippets; Git diff/file capture; and a VS Code companion
  with an explicit source composer, in-memory Context Basket, collaboration
  sidebar and correlated preview acknowledgement.
- Generated, session-scoped lifecycle hooks for Claude Code and Codex, plus a
  Copilot plugin attachment. Runtime state changes only after the pane capability
  reports a real signal; Copilot and unsupported vendors otherwise remain visibly
  Unknown rather than being inferred from terminal text.
- Production and Development runtime isolation.
- Pane-scoped relay capabilities and a macOS Seatbelt boundary around every
  vendor process tree.
- Production-only signed stable update checks with explicit opt-in, visible
  installation and the normal pane-aware quit confirmation. Development never
  connects to the update feed.

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

## Terminal appearance

Open **Terminal Appearance…** from the app or pane menu, or from the command
palette. A Parley font family or size is an explicit global override for every
current and future shell and agent pane; changing it does not restart the pane
or its vendor session.

**Import…** reads Ghostty's standard XDG and macOS configuration files in
Ghostty's documented order. It copies only bounded font family, font size,
theme, palette and hex colour values through typed Ghostty configuration APIs.
Built-in themes, named themes under the XDG Ghostty themes folder and explicit
absolute theme files are supported. Parley deliberately ignores `command`,
`keybind`, `config-file`, shell integration, opacity, cursor behavior and every
other option; raw Ghostty configuration text is never retained or passed to a
terminal. The Terminal Appearance panel in Settings reports both imported and
ignored setting counts before **Apply**. The sanitized snapshot is stored in the active Production or
Development preference namespace, and Parley overrides continue to win.

## Cross-vendor collaboration

Each agent pane receives one durable random credential for its real sender
identity and the shared `parley` command. A caller cannot claim to be another
pane.

```text
parley whoami
parley panes
parley events --since <beginning|now|cursor>
parley relay <target> <text>
parley paste <target> <text>
parley ask <target> <question>
parley answer <id> <answer>
parley delegate <target> <task>
parley progress <id|current> <note>
parley done <id|current> <report>
parley done <id|current> --file <path>
parley fail <id|current> <report>
parley status
parley wait <id|current>
```

`whoami` reports the authenticated caller's pane, vendor, workspace, role and
app-owned lifecycle state. `panes` lists at most 128 explicit non-self agent
targets with authoritative process, protocol, relay and Ghostty input-path
facts. `events` returns at most 100 monotonically ordered handoff transitions and
native lifecycle records per page; continue with its `nextCursor`. These JSON
responses never contain credentials, folders, terminal text, questions,
results or activity-detail content.


### Agent awareness in any project

Parley supplies its shared protocol at agent launch; using another project does
not require copying Parley's instructions into that repository. Agents can
rediscover the complete command index and canonical reference locally:

```text
parley help
parley protocol
```

Both commands work without a running broker and print no pane credential or
project data. Every agent launch also supplies `PARLEY_COMMAND`, the absolute
runtime-local shim path. If a vendor rebuilds PATH, use
`"$PARLEY_COMMAND" protocol`. Vendor tool approvals still apply.

Claude receives the canonical text through its appended system prompt; Codex
through developer instructions. Copilot receives an additional instructions
directory; it combines applicable instruction files without a general
precedence order. Agy is passed the generated protocol directory with
`--add-dir`, but automatic rule loading from that added directory remains
unverified. Its documented rule discovery starts with workspace files.
See the [Copilot instruction rules](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions)
and [Agy workspace-rule guidance](https://www.antigravity.google/docs/cli/best-practices/).

A protocol stamp records the instructions configured for launch, not proof that
a model loaded or retained them. Use the fresh/resumed-session smoke check in
[RELEASING.md](RELEASING.md) before claiming vendor uptake. When a vendor needs a
manual reminder, ask it to run `parley protocol` and then `parley whoami`.
After a protocol upgrade, explicitly restart panes marked **RESTART FOR
PROTOCOL**; Parley does not silently restart existing sessions.

This repository's `CLAUDE.md` links to `AGENTS.md` so Claude receives the
engineering guide as well. Parley does not create that alias in other projects.

High-frequency turn and notification signals update live pane state and a
separate bounded in-memory event ring. They never consume durable human-history
retention or appear in the Status Center timeline. Session start/end and
awaiting-permission signals remain in the small durable coordination journal
because they support supervision and recovery diagnostics.

Parley generates per-launch hook configuration for Claude Code and Codex and a
plugin attachment for Copilot. Those adapters report only an allowlisted
lifecycle event through the pane's existing authenticated capability; they
ignore vendor hook input and cannot choose another sender. Copilot remains
Unknown unless its CLI actually executes the attached plugin hook. The reserved
`parley signal <event>` ingress is
not an agent coordination command. Agy remains Unknown because its documented
hooks require persistent user or workspace configuration rather than a safe
per-launch attachment.

Targets are explicit pane ids, unique vendors or stable roles such as
`@reviewer` and `workspace/@reviewer`. Parley refuses missing, ambiguous,
same-pane, shell and busy targets. Same-vendor routing is allowed only between
distinct panes.

After choosing an explicit target from **Ask**, Command-Shift-A opens the active
pane's exact Ghostty selection in the reviewed Ask composer for that same
source-target route. Parley remembers at most one last target per source pane
for the current application session, shows both vendors in the route, and still
requires Command-Return or the visible Send Ask button before submission. It
never captures scrollback or sends merely because the shortcut was pressed.

When that composer targets a pane with a supported authenticated vendor hook
report, a compact **TARGET SIGNAL** strip names the exact pane and vendor hook,
reported state, official event and live age. It is labelled **ADVISORY ONLY**:
the signal neither blocks nor authorizes Send. No strip means Parley has no
supported official target signal; terminal text and elapsed time are never used
as a substitute.

Actionable panes carry a semantic attention ring without replacing the inset
accent line that identifies the selected terminal. Orange is a permission
request, the app accent is an unread returned result and red is a failed or
interrupted handoff. Pane headers include the signal age. Official vendor hook
state is labelled **PERMISSION REPORTED** with that age, never asserted as a
current prompt from terminal text. Command-Shift-J cycles the newest attention
items, focusing a live permission pane or opening the exact durable handoff in
Status Center.

Agent-initiated Ask is for a focused consultation likely to finish within one
minute. Once terminal submission succeeds, the managed command prints
`Parley Ask ID: <id>` on stderr and reserves stdout for the exact answer. If
that calling shell disconnects, `parley wait <id>` recovers the durable answer
only from the same still-running source pane generation. Use Delegate for work
likely to take longer; `parley wait current` remains shorthand only for one
active delegation.

The exact target of active delegated work may run
`parley progress current "<note>"` to replace one control-stripped,
200-byte progress note. The initiating pane sees it in structured
`parley status`, and the person sees it in the existing Status Center
inspector. It is explicitly agent-declared and never counts as activity,
completion or failure; terminal work still requires `parley done` or
`parley fail`.

For a substantial UTF-8 result, the exact delegated target can run
`parley done current --file <path>`. The path must remain inside that pane's
working folder. Parley preserves formatting within the existing 60 KB source
and 90 KB rendered Context Pack limits, completes the tracked work only after
the agent-provided draft is durable, and returns a compact linked receipt to
the initiator. The file appears in the Context menu and its handoff inspector
for explicit review, editing, discard or optional Context Pack delivery.
Nothing is forwarded automatically, and agent-provided provenance is never
silently promoted to person-selected evidence.

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
ordinary broker handoff history, receipts and recovery controls remain.
Workspace Briefs now hold person-authored investigation conclusions,
rationale, confidence and open questions. Status Center can inspect results
beside the multi-select history, launch Challenge or Verify as one editable
correlated Ask to one explicit reviewer, and save a person-owned verdict and
note. It can also promote 1 to 16 explicitly selected returned Ask or Delegate
handoffs into an editable, attributed Context Pack draft without submitting a
new handoff. Linked-review lineage and human review metadata remain attached to
the existing durable handoff and are preserved in Context Packs and exports.
Any legacy `research-board.json` or `handoff-chains.json` file is left
untouched but is not loaded by the app; neither file is a stable format or
protocol to integrate with.

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

Agent pane menus distinguish **Start Fresh Session**, **Restart Fresh Session**
and vendor-owned **Resume**. Claude, Codex and Copilot open their own session
pickers; Agy attempts its documented most recent conversation for that working
directory. Resume keeps the pane folder and repeats Parley's permission review,
but the vendor alone decides which history is available and whether a
conversation resumes. Parley records **RESUME REQUESTED**, never that a prior
session survived.

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

The package links `GhosttyTerminal` through `libghostty-spm` and embeds Sparkle
only for the installed app's signed update path. `Package.swift` and
`Package.resolved` are the authoritative dependency pins.

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

### Swift package builds in agent panes

SwiftPM compatibility is available in **Settings → General → Swift package
builds** and is off by default. After explicit human opt-in, newly launched
agent panes receive a runtime-local `swift` wrapper for SwiftPM `build`,
`test`, `run` and `package`. It adds SwiftPM's `--disable-sandbox`
option to avoid unsupported nested macOS sandboxes. Project and dependency manifests and plugins run
with the agent's existing permissions, including any permitted network access.
Parley's outer boundary and vendor approvals remain active. The setting only
automates a SwiftPM flag; it does not expand the agent's existing permissions.

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

Tools > Export Diagnostics writes a local schema-3 report with aggregate counts
for Relay, Paste, Ask, Delegate, Challenge, Verify, human reviews and retained
durable vendor signals. It also measures typed delivery outcomes, the
bounded content-free event projection available to Status Center and
failure-to-restart/session recovery times. High-frequency vendor turn signals
are excluded from the durable human-history count. Prompts, results, terminal
content, names, folders and raw event bodies
are excluded, and nothing is uploaded.

The manual GitHub draft workflow must pass the 25-round eight-pane Ghostty soak.
Its standalone JSON report is checksummed and attached to the draft release.

## Package and release

```bash
npm run package:mac
npm run verify:package:mac
npm run release:mac
```

The app bundle has one Parley executable: `parley-native`. Ghostty and the
app-resident coordination core are linked into it. Sparkle.framework contributes
its standard transient update helpers; Parley adds no coordination daemon,
login item or always-running helper. Packaging emits an app, ZIP and DMG,
validates the embedded framework and resources, signs nested code inside-out
and includes the project and third-party licences. Ghostty's runtime bundle is
installed in `Contents/Resources`; release builds apply a guarded temporary
overlay to the official wrapper's resource resolver, restore the checkout after
compilation and fail closed if the expected upstream source shape changes.

`npm run package:mac` and `npm run verify:package:mac` remain local ad-hoc
package checks. `npm run release:mac` now fails closed unless the Developer ID,
Apple notary and Sparkle Ed25519 configuration is present. The manual GitHub
workflow notarizes and staples the app and DMG, verifies Gatekeeper, generates
an Ed25519-signed stable appcast and a SHA-256-pinned `parley.rb`, and creates
only an unpublished draft. Publishing that reviewed release opens a separate
pull request to update `Casks/parley.rb`; it never pushes directly to main. See
[RELEASING.md](RELEASING.md).

After the first notarized cask update has been merged, Homebrew users can add
this repository as an explicit tap and install the same notarized DMG:

```bash
brew tap markjoyeuxcom/parley https://github.com/markjoyeuxcom/parley
brew install --cask markjoyeuxcom/parley/parley
```

`Prepare to Uninstall…` refuses active Ask or delegated work, ends every pane
and coordination endpoint, and quits. It leaves workspace definitions and
local collaboration history for a safe reinstall unless the person explicitly
chooses a separate data purge.

## Licence

Parley is licensed under Apache-2.0. Embedded third-party notices are in
`THIRD_PARTY_NOTICES.md`.
