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
   Never broadcast implicitly, target a shell or guess between ambiguities.
5. **Visible and interruptible.** The person can see every participant and
   handoff, focus either side and stop tracked work.
6. **Local coordination.** No hosted service, sync, telemetry or remote-control
   backend. Vendor CLIs contact their own services normally.
7. **One embedded terminal stack.** Ghostty is the terminal renderer and PTY
   owner. Do not add another multiplexer, renderer or hidden terminal client.
8. **One shared protocol.** `AgentProtocol.text` solely defines `relay`,
   `paste`, `ask`, `answer`, `delegate`, `done`, `fail`, `status` and `wait`.
   Launch adapters may change delivery mechanics, never wording.
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
      CoreService.swift                authenticated UI control client/types
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
  serialized there.
- `GhosttyPaneRegistry` retains views by pane id across SwiftUI remounts and
  main-window hiding.
- Closing/hiding the main window keeps panes and coordination alive while the
  application remains running.
- Closing a pane or workspace explicitly ends its processes.
- Stop Everything, Prepare to Uninstall and confirmed full quit end every pane
  process and the coordination core.
- On a later app launch, workspace definitions remain, shells can restart and
  agent panes are stopped placeholders. Never claim a vendor session survived.

The relay broker lives in `AppResidentCoordinationCore` inside the application
process. It owns the authenticated UI control socket, capability filesystem
transport, consultations and durable records. There is no separate core
executable, login item or background process. `core.pid` contains the app PID
while coordination is live.

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
- `parley paste <target> <text>` places attributed text without Enter.
- `parley ask <target> <question>` submits and blocks for one exact answer.
- `parley answer <id> <answer>` completes that waiting consultation.
- `parley delegate <target> <task>` creates tracked asynchronous work.
- `parley done|fail <id|current> <report>` records the exact result.
- `parley status` returns the caller's initiated work as JSON.
- `parley wait <id|current>` waits for one exact result.

Immediate Relay is intentional. `paste` is review-before-send. Targets resolve
by exact pane id, explicit role, or vendor only when unique. Refuse ambiguous,
missing, same-pane, shell and busy targets. Permit same-vendor routing only
between distinct panes. Allow at most one unanswered consultation or active
delegation per target.

Human Ask and Return submit only after an editable preview. A real current
Ghostty selection may prefill it; otherwise it starts empty. Never capture
scrollback or a whole conversation implicitly.

Multiline payloads travel through Ghostty paste as one text operation.
Submission is a separate Enter key event after paste succeeds. Never send raw
newlines as key events. Copilot may require briefly focusing the target for
paste/submit and restoring the person's previous pane; refuse delivery at its
folder-trust prompt.

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

## Reviewed context boundary

An agent-staged context part is a claim. Its path and bytes stay labelled
`agentFileDraft`. Only a separate human-authorized capture may create trusted
File, Git Diff, Selection or Command Result provenance. Approval forms return
known part ids and edited text, never source metadata or captured originals.

Context-review validation, durable recording, in-memory replacement and
broadcast share one mutation lock. Approval carries the exact `updatedAt`
revision shown in the UI and must fail stale if the draft changed.

Direct completion belongs to the app-resident core. Record approved before
terminal input and failed delivery as terminal `.failed`. A delivery followed
by persistence failure must state that delivery occurred and warn against
resending. Keep rendered packs at 90 KB and control bodies at 200 KB.

## Portable teams, roles and mobility

A team template is a portable blueprint, not a saved live layout. It may keep
vendor, display name, role, permission-profile identity/lifetime, lead,
automation policy and split geometry. It must never keep repository paths,
approved roots, live ids, credentials, terminal content or vendor sessions.
Applying a template binds every leaf to the folder selected at that moment;
agent leaves remain stopped.

Roles are owner-controlled metadata independent of display name. Use
`@reviewer` locally and `workspace/@reviewer` across workspaces. Do not fall
through from role to mutable display name. Roles are lowercase bounded slugs,
unique per workspace; vendor names and `lead` are reserved.

Move preserves the exact retained Ghostty surface, pane id, process, vendor
session, scrollback, credential and folder. Refuse moving the last source pane,
any pane with an active handoff, or a role/lead collision; revalidate topology
after confirmation. Clone copies visible configuration only, assigns fresh ids
and credentials, and leaves agent clones stopped. Clean up partial clones.

## External integration boundaries

External workspace opening accepts exactly one existing canonical directory
through `parley open`, Finder, the document role or `parley://open?folder=`. It
can focus or create a normal shell workspace. It cannot carry prompt text,
choose a vendor, start an agent or inject terminal input.

VS Code context import consumes one bounded mode-0600 `.parleycontext` manifest
from Production's private inbox and deletes it after one read. It names one
workspace and explicit sources only. Imports always stop at editable preview.

Production alone publishes a bounded, content-free attention snapshot with a
10-second heartbeat. It may contain labels, counts and opaque ids, never
prompt/result text, terminal output, commands, folders, credentials or replayable
delivery state. Focus/status URLs accept one bounded live id and cannot start a
pane or submit input.

## Shared protocol launch behavior

Increment `AgentProtocol.version` whenever canonical semantics change. A live
pane with a mismatched stamp shows **RESTART FOR PROTOCOL**. UI remounting cannot
alter an existing model context.

- Claude Code appends the protocol with `--append-system-prompt`.
- Codex receives it through `developer_instructions`.
- Agy receives generated `agent-protocol/AGENTS.md` through `--add-dir`.
- Copilot receives the same directory through
  `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` and permits only `shell(parley)` without
  an extra tool confirmation.

Do not maintain separate handwritten protocol wording per vendor.

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

## Version policy

Never recall package or tool versions from memory. Verify the authoritative
registry at query time. For GitHub packages and releases use the GitHub latest
release API; for mise-managed tools use `mise latest <tool>`.

Before changing Ghostty's exact wrapper pin, verify the current
`Lakr233/libghostty-spm` release, confirm the embedded upstream Ghostty release
and inspect relevant release notes. Keep `Package.swift`, `Package.resolved` and
`THIRD_PARTY_NOTICES.md` consistent.

## Repository safety

- Preserve unrelated user changes in a dirty worktree.
- Use conventional commit messages and branch instead of committing to main.
- Never force-push main.
- Before every commit, scan staged files for AWS keys, private keys, passwords
  and tokens, then run `npm run scan:public`.
- Agent commits include `Co-Authored-By: Claude <noreply@anthropic.com>`.
