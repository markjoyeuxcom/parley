# Parley Companion for VS Code

The Parley Companion is a thin local remote control for the installed macOS
app. It does not embed a terminal, own a vendor session or submit work.

Commands available from the Command Palette:

- **Parley: Open or Focus Workspace**
- **Parley: Show Attention and Panes**
- **Parley: Open Selection in Context Preview**
- **Parley: Open Current File in Context Preview**
- **Parley: Open Current File Diagnostics in Context Preview**
- **Parley: Open Git Diff in Context Preview**
- **Parley: Open Selection and Git Diff in Context Preview**

Editor and Explorer context menus expose the relevant commands as well.

The status-bar item shows the installed Production app's current local
attention count. Choose it to open one durable handoff in Parley's Status
Center or focus one exact live agent pane. When Parley is closed or its
heartbeat is stale, the item reports status as unavailable rather than showing
old state as current.

## Safety boundary

The companion runs only in the local macOS desktop UI extension host. It
refuses VS Code for the Web and remote workspaces rather than treating a remote
path as a local path.

An editor command writes one bounded, owner-only `.parleycontext` manifest to
Parley's private Production integration inbox and asks LaunchServices to open
it with the installed app. The manifest contains only a workspace and explicit
source descriptions; it cannot name a pane, vendor, permission, prompt or
submit action.

Parley consumes the manifest once and opens its normal editable context-pack
preview. Current files and Git diffs are recaptured from disk by Parley.
Selections and diagnostics are labelled as VS Code-provided captures. A ready
agent pane in that workspace is required as the eventual source, but no agent
is started and nothing is sent until the person reviews the pack and uses one
of Parley's existing confirmed send actions.

Attention uses a separate owner-only, bounded snapshot. It contains workspace
and pane labels, counts and opaque pane/handoff ids only—never prompt or answer
text, terminal output, commands, folders or credentials. Strict focus links can
select an existing pane or Status Center record but cannot start an agent,
inject terminal input or submit work.

## Development

Launch a VS Code Extension Development Host for this directory, then invoke a
Parley command there:

```bash
code --new-window --extensionDevelopmentPath="$PWD/vscode-extension" "$PWD"
```

The installed Production app must include the matching context-import
contract.

Run the deterministic companion checks from the repository root:

```bash
npm --prefix vscode-extension test
```

Build a locally installable VSIX:

```bash
npm install --prefix vscode-extension
npm run package:vscode
```

The package is written to `dist/Parley-Companion-0.1.0.vsix` and the manual
draft-release workflow attaches that same audited artifact to GitHub Releases.
