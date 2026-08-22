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
- A shared, versioned protocol supplied automatically to every new agent pane.
- Authenticated agent-to-agent `relay`, `paste`, `ask` and `answer`
  commands.
- Cross-workspace Ask targets and recent-folder shortcuts.

No agent starts automatically on a new session. Parley creates a shell first;
opening an agent pane is an explicit action against a CLI the user has already
installed and signed into.

## Cross-vendor collaboration

An agent running inside Parley has the `parley` command on its PATH:

```bash
parley relay codex "Review this implementation and report concrete defects."
parley paste agy "Draft question for a person to inspect"
parley ask copilot "What edge cases are missing from this plan?"
```

- `relay` attributes the text, sends it to one named cross-vendor pane and
  submits it.
- `paste` performs the same attributed delivery but leaves the text
  unsubmitted.
- `ask` submits one correlated question and blocks. The target receives an
  exact `parley answer <id>` command; its answer becomes stdout from the
  original `ask`, allowing the requesting agent to continue the same turn.
- `answer` completes that waiting consultation. The Return control is a human
  fallback when an agent printed an answer but did not run the command.

Targets may be a unique vendor name or a pane id. Parley refuses ambiguous,
same-vendor, shell and missing targets instead of guessing. Only one unanswered
consultation may target a pane at a time.

The toolbar's Ask and Return actions provide the same workflow for a person.
A real terminal selection prefills the editor; otherwise it starts empty.
**Insert Visible Pane** adds the current screen explicitly and never silently
includes scrollback.

Copilot must complete its own folder-trust prompt before Parley submits a
handoff to it. Parley fails closed while that prompt is present.

## Workspaces and folders

Each workspace tab represents one durable tmux window:

- Opening a folder creates or focuses its workspace.
- Changing the workspace folder affects newly created panes only.
- Running panes keep the working directory with which they were created.
- Workspaces can contain different pane arrangements and agent vendors.
- An Ask target can live in the current workspace or another open workspace.
- Closing a workspace explicitly ends all processes inside it.

Closing only the Parley window detaches from tmux and leaves workspaces running.
The current coordination broker still belongs to the app process, so an
in-flight blocking consultation does not yet survive the app exiting. Making
that broker persistent is the first milestone in [ROADMAP.md](ROADMAP.md).

## Local architecture

```text
native/
  Package.swift
  Sources/
    ParleyCore/        tmux control, relay broker, protocol and domain models
    ParleyNative/      SwiftUI application and SwiftTerm host
    ParleyCoreChecks/  deterministic native verification executable
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

That directory contains the isolated tmux socket and configuration, relay
credentials and the generated shared agent protocol. Credentials identify the
exact pane making a request. Agent processes receive the broker capability but
not tmux's control variables.

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
```

To deliberately restart only agent panes carrying an old protocol stamp:

```bash
npm run dev:restart-protocol
```

That operation ends those agent conversations. A normal launch never restarts
surviving panes.

Parley is currently a working development build rather than a packaged release.
The ordered path to a dependable daily tool is in [ROADMAP.md](ROADMAP.md).
