# Native application

`native/` contains the complete Parley application. It is a Swift package
with a SwiftUI front end, a SwiftTerm terminal surface and an isolated tmux
control plane.

## Targets

- **ParleyCore** — models, process execution, tmux lifecycle, relay text
  handling, the authenticated broker and the shared agent protocol.
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
```

The Node helper selects an installed macOS SDK that the active Swift compiler
can actually import. It also moves compiler caches into a writable temporary
directory. It has no third-party JavaScript dependencies.

The check harness is an executable because the Command Line Tools environment
in which it was introduced exposed neither XCTest nor Swift's newer Testing
module. Its checks are deterministic and do not launch Claude, Codex, Agy or
Copilot.

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
- Pane kind, display name, relay availability, protocol version and legacy
  Return route are tmux pane options.
- Closing the SwiftUI window detaches the client; tmux and its processes
  continue running.
- Closing a pane or workspace is explicit and ends those processes.

The broker currently runs in the application process. tmux panes survive an app
exit, but a blocking consultation and its socket wait do not. The persistent
coordination core in the roadmap removes that lifecycle mismatch.

## Process and protocol boundary

Agent commands are passed to tmux as argument arrays. Agent-authored text is
never interpolated into a shell command. Pane processes receive
`PARLEY_PANE`, their pane id and kind, the shared protocol version and a
credential scoped to that exact pane.

tmux's `TMUX` and `TMUX_PANE` variables are removed from agent environments.
Agents receive the authenticated relay command, not raw access to Parley's tmux
server.

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

The broker is reachable through an authenticated Unix-domain socket. TCP
loopback is not used because read-only agent sandboxes may block it.

- `parley relay` submits one attributed cross-vendor message.
- `parley paste` leaves the attributed message in the target prompt.
- `parley ask` creates one correlated consultation, submits it and waits.
- `parley answer` resolves the exact waiting consultation.

Payloads are loaded into a tmux buffer through stdin and pasted with bracketed
paste, preserving multiline text without allowing an early newline to submit a
partial prompt. Submit is a separate tmux key event. Copilot is briefly focused
before that event because its TUI ignores Enter after a focus-out event.

Human Ask and Return editors use selected terminal text when present and
otherwise start empty. Visible screen capture is always an explicit action and
does not include scrollback.
