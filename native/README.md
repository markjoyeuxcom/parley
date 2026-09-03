# Native application

All Parley product code lives in this Swift package. The application is a
SwiftUI workbench over retained Ghostty terminal surfaces with an app-resident
local coordination core. There is one terminal stack and one app
implementation.

## Targets

- **ParleyCore** — domain models, durable workbench metadata, canonical agent
  protocol, authenticated relay broker, context/review services, process
  boundaries and runtime isolation.
- **ParleyNative** / `parley-native` — SwiftUI application, Ghostty pane
  registry, native split host and app-resident coordination lifecycle.
- **ParleyCoreChecks** / `parley-native-checks` — deterministic contract checks
  plus bounded real-Ghostty lifecycle and multi-pane isolation checks. It never
  launches a vendor CLI.
- **ParleySoak** / `parley-native-soak` — eight real Ghostty shell surfaces,
  repeated independent input, hidden-window continuity and exact child-PID
  teardown verification.

`GhosttyTerminal` from `libghostty-spm` is the terminal dependency. Sparkle is
the Production app's signed update installer; it is never started by an
unbundled Development runtime. Exact revisions are locked by `Package.swift`
and `Package.resolved`.

## Run and verify

From the repository root:

```bash
npm run dev
npm run dev:restart-protocol
npm test
npm run build
npm run test:soak -- --rounds 25
```

The Node helper has no package dependencies. It selects an installed compatible
macOS SDK and places Swift compiler caches in a writable temporary location.

After any app or core source change, run `npm test` and `npm run build`.
Non-trivial logic should first have a failing deterministic check. Tests must
not launch a vendor CLI, spend quota, rely on the network or alter a user's
terminal sessions.

## Runtime ownership

`ParleyRuntime` defines two isolated namespaces:

- Production: `~/Library/Application Support/Parley Native/`
- Development: `~/Library/Application Support/Parley Native Development/`

Each runtime has separate workbench state, relay endpoints, credentials,
generated protocol, records and preferences. The packaged app is always
Production; an unbundled SwiftPM app is Development.

`WorkbenchController` persists workspace and pane identity in
`workbench-state.json`. The file does not contain terminal output or a vendor
conversation. `GhosttyPaneRegistry` owns one retained `AppTerminalView` for
each live pane and keeps it across SwiftUI remounts and main-window hiding.

The lifetime boundary is explicit:

- close/hide main window: keep retained panes and coordination running;
- close pane/workspace: end its exact processes;
- full quit, Stop Everything or Prepare to Uninstall: end all surfaces,
  processes and coordination endpoints;
- next app launch: retain workspace definitions, recreate shells, present agent
  panes as stopped placeholders.

`AppResidentCoordinationCore` owns `RelayBroker`, the authenticated UI control
socket and pane-capability filesystem transport inside the app process. There
is no separate background executable or login item. `core.pid` contains the
application PID while coordination is available.

## Terminal delivery

`GhosttyPaneRegistry` is the only terminal transport. It:

- pastes each payload through Ghostty as text;
- sends Enter as a separate key event only after paste succeeds;
- focuses Copilot briefly when its TUI requires focus for submission, then
  restores the person's previous pane;
- sends interrupt to the exact pane;
- exposes only a real current selection for reviewed context capture;
- destroys the exact surface when a pane closes.

The registry retains views by pane id. SwiftUI hiding or restructuring a split
must never deallocate a live terminal surface.

## Process and protocol boundary

`AgentProtocol.text` is the sole agent-facing definition of Relay, Paste, Ask,
Answer, Delegate, Done, Fail, Status and Wait. Increment
`AgentProtocol.version` whenever those semantics change. A running pane with an
old stamp is shown as **RESTART FOR PROTOCOL**; UI reattachment cannot change
an existing model context.

Agent launch adapters are load-bearing:

- Claude Code appends the protocol with `--append-system-prompt`.
- Codex receives it through `developer_instructions`.
- Agy receives a generated `agent-protocol/AGENTS.md` through `--add-dir`.
- Copilot uses that directory through `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and
  permits only `shell(parley)` without an extra tool confirmation.

Every agent process tree is launched through `AgentProcessBoundary`. Its
Seatbelt profile denies Parley's broad private runtime and relay transport,
then reopens only generated protocol files, the managed shim and that pane's
capability-named relay endpoint. Shell panes remain explicitly trusted human
shells.

All executables are spawned with fixed argument arrays. Agent-authored text is
never placed in a command string. Vendor environments have multiplexer marker
variables removed so a GUI or development launch cannot accidentally attach an
agent process to a parent terminal session.

## Relay behavior

The UI control socket uses a random UI-only credential. Agent panes receive a
different durable credential that proves one exact sender. Credentials are
stored with restrictive permissions and refreshed across runtime mutations.

Targets resolve by exact pane id, explicit role, or vendor only when unique.
Ambiguous, missing, same-pane, shell and busy targets are refused. There is at
most one unanswered consultation or active delegation per target.

Multiline payloads use Ghostty paste and a separate Enter event. Raw newlines
are never sent as individual key events. Human Ask and Return actions always
show an editable preview first.

The reviewed-context boundary is stricter than terminal delivery. Agent-staged
files remain labelled `agentFileDraft`; trusted File, Git Diff, Selection and
Command Result provenance can be created only by a separate human-authorized
capture. Approval is revision checked, size bounded and recorded before input.

## Packaging

`scripts/native-macos-package.mjs` creates a standard macOS app with one
executable, `Contents/MacOS/parley-native`. The runtime manifest records the
embedded Ghostty terminal and app-resident core. The bundle also contains the
icon, Apache-2.0 licence, project notice and third-party MIT notices.
