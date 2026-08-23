# Native application

`native/` contains the complete Parley application. It is a Swift package
with a SwiftUI front end, a SwiftTerm terminal surface and an isolated tmux
control plane.

## Targets

- **ParleyCore** — models, process execution, tmux lifecycle, relay text
  handling, the authenticated broker and client, service launcher and shared
  agent protocol.
- **ParleyCoreService** — the persistent per-user coordination process that
  owns the relay socket and active consultations independently of the UI.
- **ParleyNative** — the macOS application, workspace and pane UI, terminal
  attachment, editors and user confirmations.
- **ParleyCoreChecks** — deterministic executable checks that exercise the
  core without starting an AI CLI or spending subscription quota.

SwiftTerm is the only package dependency and is locked by
`Package.resolved`.

## Run and verify

From the repository root:

```bash
npm test
npm run build
npm run dev
npm run test:conformance:plan
```

The Node helper selects an installed macOS SDK that the active Swift compiler
can actually import. It also moves compiler caches into a writable temporary
directory. It has no third-party JavaScript dependencies.

The check harness is an executable because the Command Line Tools environment
in which it was introduced exposed neither XCTest nor Swift's newer Testing
module. Its checks are deterministic and do not launch Claude, Codex, Agy or
Copilot.

`parley-conformance` is separate because it does exercise real subscription
CLIs. `npm run test:conformance:plan` only reads current pane metadata and shows
the exact source/target routes it would use. A live run requires an explicit
`PARLEY_LIVE=1 npm run test:conformance`; it sends unique multiline sentinels to
existing ready panes, verifies the correlated answer, and records ordinary Ask
history. `--vendor <name>` is repeatable and `--timeout <seconds>` bounds each
probe. The runner refuses an existing consultation, visible trust or permission
prompt, stale protocol, missing bracketed paste, or unavailable relay instead
of pushing input through it.

## Runtime ownership

Parley stores its runtime under:

```text
~/Library/Application Support/Parley Native/
```

It uses a dedicated tmux socket and configuration and never connects to the
user's default tmux server. The tmux session is named `parley`.

- A tmux window is a Parley workspace.
- A tmux pane is a live shell or agent pane.
- Workspace names and default folders are tmux window options.
- Workspace presentation continuity lives in UserDefaults as ID-free
  name/folder bookmarks: favourite folders are directly accessible in the
  sidebar, Move Left/Right tab order, and the last selected workspace survive a
  UI restart without changing tmux windows or starting an agent.
- Pane rows show their folder plus bounded Git branch and dirty state. A single
  argv-based Git status runs per distinct visible folder off the main thread,
  with optional locks disabled and a hard process timeout.
- Saved layouts live in the owner-only `workspace-layouts.json`, never in tmux.
  They contain no pane/window ids. Restored shells start; restored agent slots
  remain stopped until a person chooses Start.
- The Review toolbar prepares an editable, size-bounded prompt from explicit
  Git status/diffs or one person-selected UTF-8 file, then uses the existing
  attributed cross-vendor Ask path.
- Status Center is a separate native window over the authoritative pane and
  handoff projections: scoped counts, live work, agent readiness, inspection,
  durable unread results, delivery receipts, recovery actions, activity history
  and core health. Local notifications are opt-in per workspace and contain no
  prompt or answer text. Routine completed records can be dismissed locally and
  restored later; the owner-only handoff journal is never changed by dismissal.
  With one workspace explicitly selected, its terminal collaboration history
  and operational activity can also be permanently deleted after confirmation.
  Active handoffs and every other workspace are preserved, and there is no
  delete-all shortcut.
  Manual Return, Cancel Wait and safe Retry receipts are durably marked HUMAN,
  so the timeline does not make a person's intervention look automatic.
  Successful pane restarts, workspace creation/closure and saved-layout
  restoration are likewise stamped HUMAN in a separate owner-only,
  500-event `activity-events.jsonl` journal; they are recorded by the native
  action itself and never reconstructed from tmux output.
- Pane kind, display name, relay availability, protocol version and legacy
  Return route are tmux pane options.
- Closing the SwiftUI window detaches the client; tmux and its processes
  continue running.
- Closing a pane or workspace is explicit and ends those processes.

The broker runs in `parley-core-service`, not the SwiftUI process. The app
starts it when needed and becomes an authenticated client. Closing the UI
leaves both tmux and the core running, so an active blocking consultation keeps
its socket wait and can be inspected or completed after the UI reattaches.
Stopping the core releases blocked Ask commands with an explicit interruption;
a later UI launch replaces stale socket discovery and starts with no impossible
in-memory wait.

Pane credentials and the UI control credential are distinct capabilities. The
core reloads pane identity through a process-safe locked store, allowing a
reattached UI to add, restart or revoke pane credentials without restarting the
service.

## Process and protocol boundary

Agent commands are passed to tmux as argument arrays. Agent-authored text is
never interpolated into a shell command. Pane processes receive
`PARLEY_PANE`, their pane id and kind, the shared protocol version and a
credential scoped to that exact pane.

tmux's `TMUX` and `TMUX_PANE` variables are removed from agent environments.
Agents receive the authenticated relay command rather than a supported raw tmux
control path. This is discovery reduction, not same-user process isolation: a
hostile process running as the user's account can still find the fixed tmux
socket. Denying that path at the OS boundary remains a release-blocking security
milestone.

`AgentProtocol.swift` owns the only copy of the cross-vendor instructions:

- Claude receives it with an appended system prompt.
- Codex receives it as developer instructions.
- Agy receives a generated Parley-owned `AGENTS.md` directory.
- Copilot receives that directory as custom instructions and is allowed to run
  only the `parley` shell tool without an additional tool confirmation.

Bump `AgentProtocol.version` whenever those semantics change. Existing agent
processes cannot acquire new model instructions merely because the UI
reattached; the app marks them **RESTART FOR PROTOCOL** and leaves the restart
to an explicit user action.

## Relay behavior

Agent commands reach the broker through an authenticated, owner-only request/
response directory under `/tmp`; this works when a vendor sandbox denies all
network syscalls. The native UI uses the broker's local Unix-domain control
socket. Neither path uses TCP loopback.

- `parley relay` submits one attributed cross-vendor message.
- `parley paste` leaves the attributed message in the target prompt.
- `parley ask` creates one correlated consultation, submits it and waits.
- `parley ask-many` creates independent concurrent consultations for an
  explicit comma-separated target list and returns ordered JSON.
- `parley answer` resolves the exact waiting consultation.
- `parley delegate` submits tracked asynchronous work and returns its handoff
  id without waiting.
- `parley done` and `parley fail` let only the exact target credential return a
  terminal report.
- `parley status` emits JSON scoped to work initiated by the calling pane, and
  `parley wait` blocks for one exact tracked result.

Relay, paste, Ask and delegate requests carry a generated sender-scoped idempotency key.
The core assigns one stable handoff id, returns cached results for matching
retries instead of delivering twice, and rejects reuse of a key for different
content. Each handoff keeps an authoritative transition trail, vendor and
workspace identities, question and returned answer. The latest 500 are stored
in an owner-only `handoffs.jsonl` journal for the activity UI. A truncated final
write is repaired during replay, and periodic owner-only compaction bounds the
record. Native lifecycle events use the same bounded and repairable persistence
posture in the separate `activity-events.jsonl` journal so they remain distinct
from cross-vendor handoffs.

The native **Waiting** menu can cancel an active Ask through the UI-only control
capability. This records `cancelled` and releases every waiter without sending
input to either terminal. The core polls live pane identity while an Ask waits;
pane closure and credential rotation on restart produce explicit terminal
failures rather than abandoned requests.

The same UI capability may retry a failed one-way delivery only when the
failure type proves terminal input never began. The original handoff id,
idempotency scope, attribution and text are reused under a single retry lock.
An uncertain failure—especially one after paste but before a successful Enter—
is never retried because doing so could duplicate the prompt. Failed Ask
records are also not retryable: the command that owned their response route has
already returned. Explicit attention metadata distinguishes target readiness,
permission and disappearance without scraping or guessing from terminal quiet.

Payloads are loaded into a tmux buffer through stdin and pasted with bracketed
paste, preserving multiline text without allowing an early newline to submit a
partial prompt. Immediately before loading the buffer, Parley requires a live
agent pane, current protocol metadata, relay readiness and tmux's active
bracketed-paste flag. Submit is a separate tmux key event. Copilot is briefly
focused before that event because its TUI ignores Enter after a focus-out event.

The managed agent command accepts only the fixed local Unix relay socket. Pane
credentials rotate when an agent pane is deliberately restarted, and inherited
credentials from a parent Parley pane are removed before the controller starts.

Human Ask and Return editors use selected terminal text when present and
otherwise start empty. Visible screen capture is always an explicit action and
does not include scrollback.

The main window polls only the newest 24 records and shows the most important
workspace handoff in a compact activity strip. Its source and target names
focus the corresponding pane, including across workspace tabs; the history
menu exposes recent authoritative states without scraping terminal output.
