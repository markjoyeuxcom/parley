# Parley — engineering guide

Parley is a native macOS workbench for visible, supervised collaboration
between AI coding CLIs from different vendors. SwiftUI and SwiftTerm provide the
application surface; an isolated tmux server owns the real interactive
processes.

There is one application implementation. All product source is under
`native/`. Do not add a web renderer, embedded browser runtime, second
terminal stack or compatibility application.

## Product boundary

Parley exists to make cross-vendor work easier. Claude Code, Codex, Agy and
GitHub Copilot CLI retain their own models, authentication, tools, permission
prompts and conversation interfaces. Parley supplies the environment around
them: panes, workspaces, attributed handoffs, correlated consultations and
visible supervision.

Use this test for proposed scope:

> Could one vendor CLI do this on its own?

If yes, the vendor owns it. If the feature coordinates different vendors or
makes that coordination visible, safe or recoverable, it belongs in Parley.

## Product invariants

Breaking any of these changes the product.

1. **Subscription CLIs only.** Use the locally installed and already signed-in
   vendor binaries. Never add API keys or a direct model API path.
2. **Real interactive sessions.** Preserve each CLI's own TUI, permission
   prompts and session behavior. Parley does not replace them with a chat UI.
3. **No dangerous bypass flags.** Never pass a `--dangerously-*` option,
   `danger-full-access` or an equivalent approval bypass.
4. **Cross-vendor by design.** Automatic targets are explicit agent panes from
   a different vendor. Never broadcast implicitly, target a shell or guess
   between ambiguous panes.
5. **Visible and interruptible.** The person can see every participant and
   handoff, focus either side and stop tracked work. Do not create invisible
   background agent activity.
6. **Local coordination.** Parley has no hosted service, sync, telemetry or
   remote-control path. Vendor CLIs contact their own services as normal.
7. **Isolated tmux ownership.** Use only Parley's socket and configuration.
   Never inspect, attach to or mutate the user's default tmux server.
8. **One shared protocol.** `AgentProtocol.text` is the sole definition of
   `relay`, `paste`, `ask`, `answer`, `delegate`, `done`, `fail`, `status` and
   `wait`. Vendor launch adapters may
   change delivery mechanics, never wording.
9. **Honest state.** Do not infer thinking, token use, context limits, cost or
   completion from terminal text. Display only facts Parley owns or structured
   values a vendor exposes authoritatively.
10. **macOS-native restraint.** Use the system font stack, hairline rules,
    small radii, one accent and tabular numerals. No gradients, emoji or
    decorative AI imagery.

## Commands

```bash
npm test                 # deterministic native checks; starts no AI CLI
npm run build            # build the Swift package
npm run dev              # run the native app from this checkout
npm run dev:restart-protocol
```

`dev:restart-protocol` is destructive to stale agent conversations. It
restarts only agent panes whose protocol stamp is missing or outdated. Normal
launch must never restart a surviving pane.

The npm scripts are a dependency-free task runner around
`scripts/run-native-swift.mjs`. Do not run `npm install`; there are no
JavaScript dependencies. The helper selects a compatible installed macOS SDK
and gives Swift compiler caches a writable temporary location.

## Layout

```text
native/
  Package.swift
  Package.resolved
  Sources/
    ParleyCore/
      AgentProtocol.swift  canonical agent-facing contract
      CommandRunner.swift  bounded argv-based process execution and PATH repair
      CoreService.swift    UI control client, credential and service launcher
      Models.swift         pane and workspace vocabulary
      Relay.swift          credentials, consultations and command shim
      RelayHTTPServer.swift authenticated Unix-socket broker
      RelayText.swift      terminal-frame cleanup
      TmuxController.swift isolated tmux lifecycle and delivery
    ParleyNative/
      AppModel.swift       application state and confirmed user actions
      ContentView.swift    native workspace, pane and relay UI
      ParleyNativeApp.swift
      TerminalHost.swift   SwiftTerm host
    ParleyCoreService/
      main.swift           persistent per-user coordination process
    ParleyCoreChecks/
      main.swift           deterministic verification executable
scripts/
  run-native-swift.mjs
resources/
  icon.icns
  icon.png
```

App behavior belongs in Swift. The Node script is build tooling only.

## Runtime model

Runtime files are under `~/Library/Application Support/Parley Native/`.
`TmuxController` owns a dedicated socket, configuration and session named
`parley`.

- A tmux window is a workspace.
- A tmux pane is a live shell or vendor CLI.
- Workspace names and default folders are stored as window options.
- Pane kind, name, relay availability, protocol stamp and legacy Return route
  are stored as pane options.
- Closing the UI detaches; tmux panes and processes keep running.
- Closing a pane or workspace is explicit and ends its processes.
- A new session starts with one shell. Agent panes start only after a user
  chooses a vendor.

The workspace folder is a default for new toolbar-created panes. It never
changes a running pane's working directory. Multiple repositories across
workspaces and panes are normal.

The relay broker lives in `parley-core-service`, not the SwiftUI process. The
app starts or reattaches to that service through `RelayCoreLauncher`. Closing
the UI leaves the core and tmux running, so an in-flight `parley ask` keeps its
waiting socket and consultation state.

The UI uses a separate random control credential to list active consultations
and complete the explicit Return fallback. Agent panes never receive that
capability. Pane credentials are stored behind a cross-process file lock and
must be refreshed before authentication so a long-running core observes pane
creation and revocation by a later UI process.

## Relay and consultation contract

The `parley` shim connects through an authenticated Unix-domain socket. Each
agent pane has a durable random credential establishing its real sender. A
caller cannot choose a different source identity.

- `parley relay <target> <text>` submits one attributed message.
- `parley paste <target> <text>` places the attributed text without Enter.
- `parley ask <target> <question>` submits one correlated question, blocks
  and writes the returned answer to stdout.
- `parley answer <id> <answer>` completes the exact waiting consultation.
  Piped multiline input is supported.
- `parley delegate <target> <task>` submits tracked asynchronous work and
  returns a stable handoff id immediately.
- `parley done|fail <id|current> <report>` records the target pane's exact
  terminal result.
- `parley status` returns JSON for work initiated by the calling pane, while
  `parley wait <id|current>` waits for one exact result.

`relay` sending automatically is an intentional capability selected by the
user. Do not silently change it back to paste-only behavior. `paste` is the
explicit review-before-send path.

Targets resolve by exact pane id or by vendor only when unique. Ambiguous,
missing, same-vendor, same-pane, shell and busy targets are refused. There is at
most one unanswered consultation or active delegation per target until the
roadmap introduces explicit scheduling.

The human Ask and Return actions submit after an editable preview. A real
SwiftTerm selection may prefill the editor; otherwise it starts empty.
`Insert Visible Pane` captures only the current tmux screen. Never insert
scrollback or an entire conversation implicitly.

Multiline payloads travel through `tmux load-buffer` on stdin, followed by
bracketed `paste-buffer`. Raw newlines must never be sent as keystrokes because
the first can submit a truncated prompt. Submission is a separate key event
after the paste completes.

Agent processes receive the broker credential and shim path, not raw tmux
control. Remove `TMUX` and `TMUX_PANE` from their environments and do not
expose the socket path as a shortcut.

Vendor CLIs may rebuild `PATH` after launch. The runtime-local shim directory
is therefore a preference, not a guarantee: a pane can fall back to
`~/.local/bin/parley`. That stable command must remain a **runtime-neutral
router**, never a shim pinned to one transport. Exact `PARLEY_RUNTIME=DEV`
selects the Development-local shim; an unset marker and
`DEV ATTACHED TO PRODUCTION` select Production. Only Production installs or
upgrades the stable router. Development must never replace it.

Every vendor process tree must also be launched through
`AgentProcessBoundary`. Its macOS Seatbelt profile denies the complete Parley
Application Support directory and exact tmux socket, then reopens only the
generated protocol, managed shim and that pane's capability-named filesystem
relay endpoint. `RelayFileTransport` must reject a token used through a
different endpoint. Do not weaken this to Unix modes: processes in adjacent
panes share a user id. A Shell pane remains a deliberately unsandboxed human
shell and is the explicit trusted side of this boundary.

Seatbelt subpath rules are literal enough that filesystem aliases cannot be
treated as interchangeable. In particular, never standardize the relay
transport from `/private/tmp/...` to `/tmp/...` in only the shim or only the
boundary. Both must use the exact same `transportDirectory.path` spelling.
Otherwise the core and fresh heartbeat can be healthy while the pane reports
`the Parley relay broker is not running` because it cannot see its endpoint.
That message is not proof that the core process is absent: verify the selected
stable-router destination, exact endpoint spelling and heartbeat before
restarting a broker or pane.

## Shared protocol and vendor launch behavior

`AgentProtocol.version` is stamped into the process environment and a tmux
pane option. Increment it whenever the canonical semantics change. A surviving
agent with a mismatched stamp must show **RESTART FOR PROTOCOL**; reattaching a
UI cannot alter the model context of an existing process.

The current injection adapters are load-bearing:

- **Claude Code:** append the canonical text using
  `--append-system-prompt`; do not replace its default system prompt.
- **Codex:** pass the canonical text through its
  `developer_instructions` configuration override.
- **Agy:** generate a Parley-owned `agent-protocol/AGENTS.md` and pass its
  directory with `--add-dir`.
- **Copilot:** add that same directory to
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`. Permit only
  `shell(parley)` without an extra tool confirmation; all other tools retain
  Copilot's normal approval flow.

Copilot ignores Enter after receiving a terminal focus-out event. For a
submitted handoff, focus the target briefly, paste, wait for the TUI to accept
the payload, submit and restore the person's previous pane. Refuse delivery
while Copilot displays its folder-trust prompt.

Do not maintain separate skills or hand-written instructions per vendor.

## Process and environment safety

Spawn fixed executables with argument arrays. Agent-authored content must never
be interpolated into a shell command.

`EnvironmentResolver` may query `/bin/zsh -lic` for the GUI user's PATH.
This is a narrow exception: the command is fixed, contains no user or agent
input, uses sentinel-delimited output and has a hard timeout. This is necessary
because Finder-launched apps inherit a minimal PATH.

`PARLEY_TMUX` is accepted only as an absolute executable path. Otherwise tmux
is resolved from the corrected PATH and known macOS locations.

Relay credentials, the socket and generated protocol files are private
per-user runtime material. Maintain restrictive filesystem permissions. Never
log credentials or include them in UI diagnostics.

## Production and Development runtime isolation

`ParleyRuntime` is the only authority for a UI's Application Support directory,
tmux session, preference suite and lifecycle permissions. The packaged app is
always Production. An unbundled SwiftPM executable is Development unless the
explicit `attached-production` mode is requested; it must never fall into the
Production namespace because an argument was missing or malformed.

Production uses `Parley Native` and tmux session `parley`. Development uses
`Parley Native Development` and `parley-development`, with its own socket,
core, relay transport, credentials, protocol, shim, record and preferences.
Pass the session name and runtime marker into every core launch: a core that
defaults those independently can create a second session inside the otherwise
isolated socket and overwrite the marked shim.

Every UI owns an `O_EXLOCK` lease for its runtime. The explicit
`dev:attach-production` mode shares Production's lease, requires its existing
tmux/config/protocol/core, and may neither create nor upgrade them. Development
never installs the stable `~/.local/bin/parley` command and never changes the
Production login item. Keep **DEV** or **DEV ATTACHED TO PRODUCTION** visible in
every development window, diagnostics and managed agent environment.

The stable command is shared only as a router because vendors may discard the
runtime-local PATH prefix. It carries no credential and owns no transport.
Keep its routing contract covered for all three cases: Production by default,
Development only for exact `DEV`, and attached Development back to Production.
Also preserve the foreign-command refusal when upgrading an older
Parley-managed runtime-pinned shim.

Live conformance must name `production` or `development`; deterministic checks
and soak use short, fresh temporary namespaces. The lifecycle check must keep
proving that Production and Development have distinct pane PIDs, sockets, core
PIDs, shims and durable records, and that stopping one leaves the other alive.

## Verification

Never report work as done because it was written. Run it.

For non-trivial logic, write the failing check first, observe it fail, then
implement the change and observe it pass. One-line edits and documentation-only
changes do not need ceremonial tests.

After changing app or core source:

```bash
npm test
npm run build
```

The checks must remain deterministic and must not launch a vendor CLI, consume
subscription quota, mutate the user's default tmux server or depend on network
access.

The SwiftUI package requires macOS, so the current GitLab configuration performs
security scanning only. Local native checks and build are mandatory until a
macOS runner is configured. Do not add a Linux job that appears green while
skipping the application target.

## Version policy

Never recall package or tool versions from memory. Verify before recommending
or writing a version string.

| Ecosystem | Authoritative source |
| --- | --- |
| Helm charts | `https://artifacthub.io/api/v1/packages/helm/{repo}/{chart}` |
| npm / Node | `https://registry.npmjs.org/{package}/latest` |
| Python | `https://pypi.org/pypi/{package}/json` |
| Go modules | `https://proxy.golang.org/{module}/@latest` |
| GitHub releases | `https://api.github.com/repos/{owner}/{repo}/releases/latest` |
| Docker images | `https://hub.docker.com/v2/repositories/{image}/tags` |

For anything mise manages, `mise latest <tool>` is authoritative and
`mise ls-remote <tool>` lists available versions. Do not use Homebrew for a
language toolchain or a tool mise pins. Python work uses uv, Node and Go come
from mise, and AWS access uses IAM Identity Center through `aws-use <profile>`.

Before changing SwiftTerm's exact pin, verify its current release from GitHub
and inspect its changelog. Keep `Package.swift` and `Package.resolved`
consistent.

## Repository safety

- Preserve unrelated user changes in a dirty worktree.
- Use conventional commit messages.
- Branch instead of committing directly to `main`.
- Never force-push `main`.
- Before every commit, scan staged files for AWS access keys, private keys,
  passwords and tokens. Stop if any are found.
- Include this trailer on commits made by an agent:

```text
Co-Authored-By: Claude <noreply@anthropic.com>
```

No trailer is needed for the human author.

For Kubernetes work, inspect the current context before every operation and
confirm before mutating production. For Terraform, run a plan before any apply,
never use automatic approval, and explicitly warn before a destroy affecting
stateful resources.
