# Installation footprint

Parley is distributed as a drag-to-install DMG. It does not run an installer,
request administrator access, install a privileged helper or install a
background service.

## Application bundle

The DMG contains `Parley.app`, an Applications link and release guidance.
Dragging the app to Applications normally creates:

```text
/Applications/Parley.app
```

The bundle contains one native Swift executable, the embedded Ghostty terminal
library, the icon and legal notices. SwiftUI owns the application surface;
Ghostty owns each interactive PTY and its shell or vendor process. There is no
separate coordination executable, login item, terminal multiplexer or vendor
credential store in the bundle.

## Runtime data

The first Production launch creates an owner-only directory at:

```text
~/Library/Application Support/Parley Native/
```

Files appear only when their feature is used. The principal runtime data is:

| Path | Purpose |
| --- | --- |
| `workbench-state.json` | Durable workspace and pane definitions; never terminal bytes or vendor conversations |
| `agent-protocol/AGENTS.md` | The one shared cross-vendor protocol installed for new agent panes |
| `bin/parley` | Runtime-local relay command |
| `relay-tokens.json` | Random per-pane sender capabilities |
| `core-control-token` | Owner-only UI control capability |
| `relay-url`, `relay.sock`, `core.pid` | Live app-resident coordination discovery; `core.pid` is the Parley app PID |
| `handoffs.jsonl`, `activity-events.jsonl` | Bounded local collaboration and operational history |
| `workspace-registry.json`, `workspace-layouts.json` | Durable workspace presentation and saved portable layouts |
| `permission-profiles.json`, `handoff-recipes.json` | Owner-defined local coordination policy |
| `external-context-inbox/` | Owner-only one-shot manifests from the local VS Code companion |
| `ui.lock` | Exclusive Production or Development process lease, released automatically on exit |

Production may also create:

| Path | Purpose |
| --- | --- |
| `~/.local/bin/parley` | A marked runtime-neutral router. Parley refuses to overwrite a foreign command. |
| `~/Library/Preferences/com.markjoyeux.parley.plist` | Normal macOS presentation and opt-in preferences. |
| `/private/tmp/parley-native-<uid>-<runtime-hash>/` | Owner-only capability-separated exchange files used by agent-pane commands. |

The installed bundle registers `parley://open`, a folder document role, the
**Open in Parley** Finder Service and the private `.parleycontext` document
type through its `Info.plist`. Those are LaunchServices registrations, not
background processes. Folder opening accepts one existing directory and
cannot choose a vendor or inject terminal input. Context imports stop at an
editable preview.

Parley does not modify shell startup files, vendor authentication, repository
contents, API keys or system-wide toolchains.

Development uses `~/Library/Application Support/Parley Native Development`, a
separate preferences suite and a separate transient transport. It never
changes Production preferences or replaces Production's stable router.

## Window, quit and upgrade lifetime

Closing Parley's main window keeps its retained Ghostty panes and the
app-resident coordination core alive while Parley remains running. Explicitly
closing a pane or workspace ends those processes.

Command-Q, **Stop Everything** and confirmed full quit end every pane process
and the coordination core. A later launch restores workspace definitions;
shells may restart and agent panes return as stopped placeholders. Parley does
not claim that a vendor conversation survived application exit.

For an upgrade, quit Parley, replace the application bundle and reopen it.
Application Support, preferences and collaboration history remain. Starting a
restored agent placeholder injects the protocol from the new build.

## Uninstall

Choose **Parley → Prepare to Uninstall…** before moving `Parley.app` to Trash.
Preparation refuses active tracked work, ends every pane and the app-resident
coordination core, then quits. It preserves local records so an accidental
uninstall does not erase history.

Moving the app to Trash removes only the bundle. Remove Application Support,
the preferences domain and Parley's marked `~/.local/bin/parley` router
separately only when deliberately erasing all Parley state. No Mac restart is
required.
