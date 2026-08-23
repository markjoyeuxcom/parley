# Parley

Parley is a native macOS workbench for working with AI coding CLIs from
different vendors in one visible, supervised environment.

It runs the user's existing Claude Code, Codex, Agy and GitHub Copilot CLI
sessions. Authentication, models, tools and permission prompts remain owned by
those CLIs. Parley adds the missing cross-vendor layer: persistent terminal
workspaces, attributed handoffs and questions whose answers return to the agent
that asked.

There is no API-key mode, hosted Parley service, telemetry or remote sync.

## What works

- A SwiftUI app with a native SwiftTerm terminal surface.
- An isolated tmux server that owns panes, splits, scrollback and process
  lifetime without touching the user's normal tmux server.
- Real shell, Claude Code, Codex, Agy and Copilot panes.
- Folder-backed workspace tabs. Every workspace is a tmux window and every pane
  retains its own working directory.
- Pane creation, horizontal and vertical splits, selection, rename, restart,
  close, zoom and balance.
- Reattachment after closing and reopening the app; tmux keeps the pane
  processes alive.
- Human Ask and Return editors with an editable preview.
- Review shortcuts for the active pane's Git changes or a selected plan/text
  file, using that same editable attributed Ask path.
- A shared, versioned protocol supplied automatically to every new agent pane.
- Authenticated agent-to-agent `relay`, `paste`, `ask` and `answer`
  commands.
- A marked workspace lead, visible per-workspace automation policy, and four
  editable supervised-workflow recipes.
- Cross-workspace Ask targets and recent-folder shortcuts.
- Owner-only durable handoff history and a compact workspace activity strip.
- A separate native Status Center with workspace filters, live handoffs, agent
  readiness, delivery receipts, returned-result acknowledgement, recovery
  actions, core health and activity.
- A searchable native Help window covering workflows, commands, safety,
  shortcuts and troubleshooting without leaving the app.
- A permanent in-app recovery playbook for coordination-socket failure, missing
  vendor CLIs, stale pane protocols, exited panes and interrupted consultations;
  active cases surface the safe Reconnect, Check Again, Restart or Inspect
  action without requiring repository commands.
- Optional macOS launch-at-login for the local coordination core. It is off by
  default and starts neither the Parley window, tmux workspace nor a vendor CLI.
- Durable RESULT badges for requesting panes/workspaces and opt-in local
  notifications per workspace; notification text never includes the prompt or
  returned answer.

No agent starts automatically on a new session. Parley creates a shell first;
opening an agent pane is an explicit action against a CLI the user has already
installed and signed into.

## Cross-vendor collaboration

An agent running inside Parley has the `parley` command on its PATH:

```bash
parley relay codex "Review this implementation and report concrete defects."
parley paste agy "Draft question for a person to inspect"
parley ask copilot "What edge cases are missing from this plan?"
parley ask-many codex,agy "Independently name the largest risk in this plan."
parley delegate claude "Implement the reviewed change and report verification."
parley status
parley wait current
parley cancel current
```

- `relay` attributes the text, sends it to one named cross-vendor pane and
  submits it.
- `paste` performs the same attributed delivery but leaves the text
  unsubmitted.
- `ask` submits one correlated question and blocks. The target receives an
  exact `parley answer current` command; its answer becomes stdout from the
  original `ask`, allowing the requesting agent to continue the same turn.
- `ask-many` submits the same question concurrently to an explicit comma-
  separated target list and returns one ordered JSON bundle. Respondents never
  receive one another's answers; partial failures stay visible and exit non-zero.
- `answer` completes that waiting consultation. The Return control is a human
  fallback when an agent printed an answer but did not run the command.
- `delegate` submits one asynchronous tracked task and immediately returns its
  handoff id. The exact target closes it with `parley done current` or
  `parley fail current`.
- `status` returns machine-readable JSON for work initiated by that pane.
  `wait <id|current>` blocks for one exact completion or failure report without
  scraping terminal output.
- `cancel <id|current>` ends tracking only for work initiated by that exact
  pane. It never interrupts the target; only a person can choose that stronger
  action from the native UI.

Targets may be a unique vendor name, pane id, or the marked local `lead`.
Parley refuses ambiguous,
same-vendor, shell and missing targets instead of guessing. Only one unanswered
consultation or active delegation may target a pane at a time.

The workspace tab always shows its automation level: Off, Ask/Answer, or Ask +
Delegation. The broker enforces that policy before model-initiated dispatch.
Plan review, implementation review, adversarial bug hunt and comparison recipes
send one editable instruction to the marked lead; the Activity record retains
the submitted instruction and the workbench offers an immediate confirmed Stop.

Every relay, paste and Ask receives a stable local handoff id and a generated
sender-scoped idempotency key. Retrying the same command request returns the
original result without submitting its text twice. The core records the exact
state trail, vendor/workspace identities and returned answer for the latest 500
handoffs in an owner-only local journal. The activity strip reads that record
rather than inferring state from terminal output.

A failed one-way delivery exposes **Retry Original Delivery** only when Parley
recorded a pre-input failure, such as a target that was not relay-ready. The
retry reuses the original handoff id and text, and concurrent retries collapse
to one attempt. If paste may already have begun, retry remains unavailable so
Parley cannot duplicate a partial prompt. Failed Ask operations are not retried
from activity because their requesting command has already returned.

Waiting and failed activity appears on pane and workspace badges. A known trust
or permission refusal is labelled as human attention and offers a direct focus
action for the target pane; Parley does not infer attention from a quiet screen.

**Status** opens a separate operational window that can remain beside the
terminal grid or on another display. Its banner, counts, live collaboration,
agent readiness, selected-item inspector and transition timeline come only from
tmux and the durable coordination record. It does not guess whether an agent is
thinking or estimate vendor context, quota, token cost, or compaction distance.

The toolbar's Ask and Return actions provide the same workflow for a person.
A real terminal selection prefills the editor; otherwise it starts empty.
**Insert Visible Pane** adds the current screen explicitly and never silently
includes scrollback. While an Ask is outstanding, a **Waiting** menu lets the
person cancel its tracking relationship. Cancellation releases the blocked
requester and records the reason without interrupting or typing into either
agent pane.

The core also watches both ends of a waiting Ask. Closing or restarting either
pane releases the requester with an explicit failure or interruption instead
of leaving a dead long-poll behind.

The toolbar's **Review** menu removes the copy/paste step without adding a
source-control client. **Current Changes** previews bounded Git status plus the
staged and working-tree diffs; **Plan or File** opens a native file picker and
previews one bounded UTF-8 text file. Both previews are editable and require an
explicit **Ask for Review** before the normal cross-vendor submission occurs.
Git is invoked directly with argv, no pager or external diff, a five-second
ceiling and optional index locks disabled. Untracked paths are shown by status,
but their contents are never silently read.

Copilot must complete its own folder-trust prompt before Parley submits a
handoff to it. Parley fails closed while that prompt is present.

All vendors must also be at a current relay-aware prompt with bracketed paste
active. Parley refuses the handoff before loading any terminal input when that
state is absent; focusing the pane, completing its startup prompt, or explicitly
restarting a stale pane restores the normal workflow.

## Workspaces and folders

Each workspace tab represents one live tmux window:

- Opening a folder creates or focuses its workspace.
- Changing the workspace folder affects newly created panes only.
- Running panes keep the working directory with which they were created.
- Workspaces can contain different pane arrangements and agent vendors.
- An Ask target can live in the current workspace or another open workspace.
- Closing a workspace explicitly ends all processes inside it.

**Save Current Layout** writes an owner-only, ID-free definition outside tmux:
workspace name and default folder, each pane's kind/name/folder, and the split
tree with its ratios. Opening one builds a fresh window before replacing the
current workspace. Shells start automatically; agent panes appear as stopped
slots with an explicit **Start** button, so restoration never spends a vendor
subscription session. Duplicate live workspace names are visibly qualified.

Closing only the Parley window detaches from tmux and leaves workspaces running.
A separate per-user core process owns the authenticated relay socket and active
consultations. Closing and reopening the SwiftUI app does not interrupt a
blocking `parley ask`; the new UI attaches to the same core state.

**Tools → Keep Coordination Core Available at Login** registers the bundled
user LaunchAgent through macOS Service Management. Its status and approval door
also appear under **Status Center → Core Health**. Turning it off is refused
while tracked work is active; after macOS unregisters a login-owned core, the
open app reconnects its own core before returning.

## Local architecture

```text
native/
  Package.swift
  Sources/
    ParleyCore/          tmux control, relay client, protocol and domain models
    ParleyCoreService/   persistent local broker process
    ParleyNative/        SwiftUI application and SwiftTerm host
    ParleyTerminal/      production terminal configuration shared with soak
    ParleyCoreChecks/    deterministic native verification executable
    ParleySoak/          quota-free output, reattachment and relay stress gate
scripts/
  run-native-swift.mjs  macOS Swift/SDK compatibility runner
resources/
  icon.icns
  icon.png
```

Runtime files live under:

```text
~/Library/Application Support/Parley Native/
```

That directory contains the isolated tmux socket and configuration, relay and
UI-control credentials, core discovery state, logs and the generated shared
agent protocol. Pane credentials identify the exact agent making a request.
Agent processes receive only their own broker capability. Every vendor CLI and
its descendants run inside a mandatory macOS process profile that denies the
UI capability, Parley's private runtime files, the tmux control socket and
every other pane's relay endpoint. Repository files, vendor authentication,
ordinary tools and network access remain available. Shell panes are normal,
unsandboxed user shells and are explicitly trusted. The relay locator accepts
only Parley's local Unix socket; remote HTTP endpoints are never valid relay
destinations.

## Requirements

- macOS with a working Swift toolchain
- tmux
- Node only as the dependency-free task runner for the Swift/SDK helper
- At least one supported AI CLI installed and signed in

The app resolves the user's login-shell PATH at startup, so CLIs installed
outside the minimal PATH supplied to GUI applications remain discoverable.
`PARLEY_TMUX` may point to an explicit absolute tmux executable.

## Develop

No JavaScript dependency installation is required.

```bash
npm test
npm run build
npm run dev
npm run package:mac
npm run verify:package:mac
npm run release:mac
npm run test:conformance:plan
npm run test:soak
```

`npm run test:soak` opens a temporary accessory window for about 36 seconds and
uses a completely separate tmux socket and runtime directory. Seven fixture
panes generate sustained scrolling and full-screen redraw output across four
workspaces while the harness switches workspaces, tears down and reattaches the
terminal client, and drives thousands of authenticated four-vendor fixture
handoffs through the bounded broker journal. It invokes no AI CLI and spends no
subscription quota. Each pane first writes beyond tmux's 10,000-line history
cap, then switches to full-screen redraws. The command fails unless Metal is
active, fixture process ids survive reattachment, both handoff stores remain
capped at 500, and robust app/broker and tmux RSS medians each stay within the
larger of 16 MB or 10%. Set
`PARLEY_SOAK_SECONDS` to a larger value for an extended run.

The conformance plan inspects existing panes and spends no subscription quota.
When its routes look right, the explicitly opt-in live harness tests the loaded
protocol, exact multiline paste, automatic submission, correlated
`answer current`, inactive panes and cross-workspace routing:

```bash
PARLEY_LIVE=1 npm run test:conformance
PARLEY_LIVE=1 npm run test:conformance -- --vendor codex --timeout 120
```

Live conformance sends clearly labelled probe messages to existing ready agent
panes and records normal Ask handoffs. It refuses to run while another Ask is
waiting, never creates, restarts or closes a pane, cancels its own timed-out
wait, and does not type through a visible trust or permission prompt.

To deliberately restart only agent panes carrying an old protocol stamp:

```bash
npm run dev:restart-protocol
```

That operation ends those agent conversations. A normal launch never restarts
surviving panes.

`npm run package:mac` produces `dist/Parley.app` plus Apple Silicon ZIP and DMG
artifacts. Local builds use an ad-hoc hardened-runtime signature and are meant
for verification on the building Mac; they are not notarized releases. Set
`PARLEY_CODESIGN_IDENTITY` to a Developer ID Application identity when preparing
a release candidate, then complete notarization and stapling before distribution.
The bundle includes an `SMAppService` LaunchAgent plist whose relocatable
`BundleProgram` points only to `parley-core-service --login-agent`.

`npm run verify:package:mac` runs the complete no-account package gate in an
isolated temporary Applications and Application Support tree. It validates the
ZIP and DMG, mounts the disk image, installs and atomically replaces the app,
starts the packaged core against a private tmux socket, uninstalls the app while
preserving its local record, and finally verifies the deliberately confirmed
data-purge path. It never installs over `/Applications/Parley.app`, touches the
normal Parley core or starts a vendor CLI.

`npm run release:mac` is stricter: it refuses a dirty Git tree, records the full
source commit, writes a deterministic release manifest, SHA-256 checksums and an
install guide, verifies those checksums, then runs the same archive and lifecycle
gate. Ad-hoc releases say **UNNOTARIZED LOCAL BETA** both in the DMG and release
metadata. They never claim Gatekeeper readiness and never tell a user to disable
Gatekeeper. An optional `--tag v0.1.0` must match `package.json` and point at HEAD.

The GitHub **Prepare macOS draft release** workflow is manual-only. It checks out
one existing version tag, runs the native and release gates on a macOS runner and
creates an unpublished draft containing the DMG, ZIP, manifest, checksums and
install guide. Nothing is published merely by pushing a tag. Until Developer ID
and notarization are added, the draft title and instructions remain explicitly
unnotarized.

Upgrades preserve the live workbench: quit Parley, replace the app, and reopen
it. The new UI compares its versioned coordination contract with the persistent
core. An idle old core is drained and replaced automatically; an active Ask or
delegation stays alive and the Status Center shows **Core upgrade: pending**
until it finishes. tmux, workspace tabs and vendor pane processes are never part
of the core handover. Layouts and handoff history remain under
`~/Library/Application Support/Parley Native`.

For uninstallation, choose **Parley → Prepare to Uninstall…**. It refuses while
Ask or Delegate work is active, disables launch-at-login, stops the coordination
core, and quits without touching tmux panes or local records. Then move
Parley.app to Trash; no Mac restart is required. Remove
`~/Library/Application Support/Parley Native` separately only when deliberately
erasing layouts and collaboration history.

The ordered path from this locally packaged beta foundation to a dependable
distributed tool is in [ROADMAP.md](ROADMAP.md).

On first launch, Parley opens a readiness sheet for its private tmux server,
local coordination core, relay command, shared agent protocol and supported
vendor CLIs. Claude, Codex and Agy authentication use their own status-only
commands; no prompt is submitted and no model quota is spent. Copilot is
labelled "check on start" because it exposes an interactive login command but
no read-only authentication status command. Repeat the checks at any time from
**Tools → Environment Check…** without restarting a pane.
