# Parley Native

This is the first runnable native migration slice: an easy macOS front end for
an isolated tmux session. There is no Chromium, Electron, xterm.js or node-pty
in this path.

## What works

- A native SwiftUI window with a SwiftTerm terminal surface and Metal rendering.
- One persistent tmux session containing shell, Claude, Codex and Agy panes.
- Split right or below, select, rename, restart, close, zoom and balance.
- A default-folder picker for newly created panes.
- Cross-vendor **Ask** and **Return** composers. A terminal selection is the
  only automatic input; without one the editor starts empty. **Insert Visible
  Pane** adds the current screen explicitly and never includes scrollback.
- **Return** on the answering pane, routed back to the exact requester.
- `parley relay codex "text"` (or piped stdin) from a newly opened agent pane.
  It carries only the supplied text, attributes it, and submits it. `parley
  paste codex "text"` is the explicit unsent form.
- `parley ask agy "question"` from a planning agent. It creates a correlated,
  attributed question, submits it once, and blocks until the target returns
  with `parley answer <id>`. The answer becomes output from the original
  command, so that agent continues the same turn without human approval.
- Named Return indicators for active consultations. If a target prints its
  answer without invoking `parley answer`, Return can complete the waiting
  command without injecting terminal input into the requester.
- Reattachment: closing the window detaches the terminal client while tmux and
  its processes continue running.
- One shared, versioned agent protocol, automatically injected on agent start:
  Claude via `--append-system-prompt`, Codex via its `developer_instructions`
  override, and Agy via a Parley-owned `AGENTS.md` rules workspace. Existing
  panes visibly request a restart when their protocol stamp is stale.

No agent starts on launch. The initial pane is a shell; opening an agent pane is
an explicit menu action against a CLI that is already installed and signed in.

## Run it

From the repository root on macOS:

```bash
npm run native:test
npm run native:build
npm run native:dev
```

For an explicit one-time protocol migration during development:

```bash
npm run native:dev -- --restart-stale-protocol
```

That flag stops and relaunches every agent pane whose protocol stamp is missing
or old. It ends those conversations; normal launches never do this.

The check harness is a normal executable because the Command Line Tools
installation used to build this slice exposes neither XCTest nor Swift's newer
Testing module. It is deterministic and never starts an agent CLI.

## Session ownership

Parley uses its own socket and configuration under:

```text
~/Library/Application Support/Parley Native/
```

It does not use the default tmux socket, import a user's tmux configuration or
kill the server when the UI closes. Pane kind, display name and pending Return
route are stored as tmux pane options, so they survive a UI restart with the
process they describe.

tmux receives executable and argument entries directly. Parley never constructs
a shell command string for an agent. Relays go through `load-buffer` on stdin
and `paste-buffer` with multiline bracketed-paste handling. Ask and Return
submit because they are explicit human UI actions. Agent-initiated `parley
relay` submits one attributed handoff, while `parley paste` places the same
handoff without Enter. `parley ask` submits one attributed, correlated question
and then blocks until the requested pane returns its answer.

The agent-facing command enters through an authenticated Unix-domain socket.
TCP loopback is deliberately not used because Codex's read-only sandbox blocks
it. Each pane has a
durable random credential that establishes the sender; the caller cannot claim
a different identity. The broker holds separate `paste` and `submit`
capabilities: `parley paste` can reach only the former; `parley relay` uses the
latter; and `parley ask` records an exact source and target, refuses a second
unanswered question to the same target, submits once, and waits. Its answer
completes the source's existing socket command; it is never pasted into that
pane. Agent processes are also launched with tmux's control-discovery variables
removed and receive the broker capability instead.

Parley maintains its shim both inside its application-support directory and at
`~/.local/bin/parley`. The stable copy lets panes created by an older build gain
the command after the UI reattaches, without restarting their agent sessions.
Parley refuses to overwrite a different command at that path.

The canonical instruction text lives in `AgentProtocol.swift` and is written to
`~/Library/Application Support/Parley Native/agent-protocol/AGENTS.md` for Agy.
Never fork the wording inside a vendor adapter. Bump `AgentProtocol.version`
whenever its semantics change; new or deliberately restarted agent panes are
stamped with that version, while tmux-surviving panes retain their older stamp.

## Migration boundary

This directory currently replaces only the terminal workbench slice. The
Electron app remains the implementation of rooms, transcripts, persistence,
saved layouts, search, profiles and packaging. Those should move only after the
native tmux interaction has proved itself under real multi-agent use.
