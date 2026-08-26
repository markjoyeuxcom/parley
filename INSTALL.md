# Installation footprint

Parley is distributed as a drag-to-install DMG, not a package installer. It
does not run an install script, request administrator access or install a
privileged helper.

## Opening the DMG

Opening the image mounts a temporary read-only volume, normally at
`/Volumes/Parley`. The volume contains:

- `Parley.app`
- an `Applications` link used as the drag target
- `READ ME FIRST.txt` in release DMGs

Ejecting the volume removes that mount. Nothing has been installed until
`Parley.app` is copied out of it.

## Copying the application

Dragging the app to the DMG's Applications link creates:

```text
/Applications/Parley.app
```

The destination can instead be a user-owned Applications folder. The bundle
contains the SwiftUI application, the local coordination core, the optional
Service Management LaunchAgent definition, the runtime-component manifest,
third-party licence notices and the Parley icon. It does not contain any vendor
credentials.

The release icon is deliberately source-controlled in two forms:

```text
resources/icon.png   1024 × 1024 master image
resources/icon.icns  complete macOS icon family copied into Parley.app
```

`Info.plist` names the installed copy `Contents/Resources/Parley.icns` as the
application icon.

## First launch and normal use

The first Production launch creates an owner-only runtime below:

```text
~/Library/Application Support/Parley Native/
```

Files are created as their feature is used, so a fresh directory may contain
only part of this list:

| Path | Purpose | Lifetime |
| --- | --- | --- |
| `tmux.conf`, `tmux.sock` | Parley's private tmux configuration and socket | The socket remains useful while Parley's tmux server and panes survive |
| `agent-protocol/AGENTS.md` | Exact cross-vendor protocol injected into new agent panes | Replaced when the bundled protocol changes |
| `bin/parley` | Runtime-local relay command | Replaced by Parley when its managed implementation changes |
| `relay-tokens.json` and lock | Per-pane relay capabilities | Retained only for panes Parley still knows |
| `core-control-token` and lock | Owner-only UI-to-core control capability | Persistent local secret; never leaves the Mac |
| `relay-url`, `relay.sock`, `core.pid` | Discovery and process state for the running coordination core | Recreated as the core starts; removed when it stops normally |
| `core.log` | Coordination-core diagnostic log | Persistent local diagnostic record |
| `handoffs.jsonl`, `activity-events.jsonl` | Bounded collaboration and activity history | Persistent local record |
| `workspace-layouts.json` | Saved ID-free workspace layouts | Created after a layout is saved |
| `handoff-recipes.json` | Custom recipe definitions | Created after recipes are changed |
| `permission-profiles.json` | Saved permission profiles | Created after profiles are changed |
| `external-context-inbox/` | Owner-only one-shot manifests placed by the local VS Code companion | Each manifest is deleted when Parley consumes it; abandoned files are bounded and may be removed later |
| `ui.lock` | Single-UI lease target | The actual lease is held by the open process and releases on exit |

Production also owns these locations outside Application Support:

| Path | Purpose |
| --- | --- |
| `~/.local/bin/parley` | A managed command for persistent pane relay and the person-only `parley open <folder>` entry point. Parley creates or updates only its own marked file and refuses to overwrite a foreign command. |
| `~/Library/Preferences/com.markjoyeux.parley.plist` | The normal macOS preferences domain for presentation state, favourites and opt-in settings. macOS may cache this domain through `cfprefsd`. |
| `/private/tmp/parley-native-<uid>-<runtime-hash>/` | Owner-only, capability-separated request/response transport used by commands issued inside agent panes. Exchange files are transient. |

Launch at login is off by default. If it is enabled, Parley asks macOS Service
Management to register the signed LaunchAgent definition embedded inside
`Parley.app`. Parley does not copy a plist into `~/Library/LaunchAgents`; macOS
maintains the registration in its own login-item database.

The installed Production bundle also registers `parley://open`, an alternate
`public.folder` Open With role and the **Open in Parley** Finder Service in its
own `Info.plist`. Those are LaunchServices registrations, not separate files or
background helpers. They accept exactly one existing folder and only open or
focus its normal shell workspace. Development builds do not register these
machine-wide entry points or replace the installed app's ownership of them.

The bundle also owns the private `.parleycontext` document type used by the
local VS Code companion. Such a file is accepted only from Production's fixed
owner-only integration inbox, is bounded to 200 KB, and is consumed once. It
can prepare an editable context preview but cannot start an agent, select a
target or submit terminal input.

Parley does **not** modify shell startup files, the user's ordinary tmux server
or configuration, vendor CLI authentication, repositories, API keys or
system-wide directories.

Development builds use `~/Library/Application Support/Parley Native
Development`, a different preferences domain, a different tmux socket and a
different transient transport. They do not replace Production's stable relay
command or login item.

## Upgrade

Replacing `/Applications/Parley.app` changes only the application bundle.
Application Support, preferences, tmux panes and local collaboration history
remain in place. An active Ask or delegation can delay the coordination-core
handover until that work finishes.

## Uninstall

Choose **Parley → Prepare to Uninstall…** before moving `Parley.app` to Trash.
Preparation refuses active Ask or delegated work, unregisters launch at login
when enabled, stops the coordination core and quits. It deliberately preserves
tmux panes and local records.

Moving the app to Trash removes only the bundle. The Application Support tree,
preferences and managed `~/.local/bin/parley` command remain so reinstalling
does not lose work. Remove those separately only when deliberately erasing all
Parley state, and only after confirming no surviving Parley panes are needed.
The private temporary transport contains no durable history and can be left to
normal macOS temporary-file cleanup.
