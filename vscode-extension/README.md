# Parley Companion for VS Code

This companion is open source with Parley under the
[Apache License 2.0](LICENSE).

The Parley Companion is a thin local remote control for the installed macOS
app. It does not embed a terminal, own a vendor session or submit work.

Commands available from the Command Palette:

- **Parley: Open or Focus Workspace**
- **Parley: Show Attention and Panes**
- **Parley: Open Collaboration View**
- **Parley: Open Production App**
- **Parley: Build Context Pack…**
- **Parley: Add Selection to Context Basket**
- **Parley: Add File to Context Basket**
- **Parley: Add Diagnostics to Context Basket**
- **Parley: Review Context Basket…**
- **Parley: Clear Context Basket**
- **Parley: Diagnose Companion**

The context-pack composer is multi-select and shows the number of resulting
sources plus the known byte estimate. Depending on the current VS Code state,
it offers every non-empty editor selection, the saved current file,
current-file diagnostics, explicitly selected Explorer files, all Git changes,
staged changes, and working-tree changes. Git SCM resource menus also open the
same composer with the selected staged or working paths preselected.

The Parley Activity Bar container uses native Tree Views rather than a webview:

- **Attention** shows content-free actionable handoffs and opens the exact
  authoritative Status Center record.
- **Workspaces and Panes** groups exact live agent panes by durable Production
  workspace and focuses only the selected pane.
- **Context Basket** collects explicit sources across several editor actions
  before opening one reviewed context preview.

Context Baskets exist only in the current VS Code extension-host process and
are separated by canonical local workspace folder. Adding the same file,
diagnostic set, Git scope or selection range refreshes that source instead of
silently duplicating it. A basket is bounded by the same 16-source and manifest
size contract as an immediate preview. It clears automatically only after
Parley returns the matching accepted acknowledgement; cancellation or rejection
leaves it available for correction and retry.

The status-bar item shows the installed Production app's current local
attention count. Choose it to open one durable handoff in Parley's Status
Center or focus one exact live agent pane. When Parley is closed or its
heartbeat is stale, the item reports status as unavailable rather than showing
old state as current.

## Safety boundary

The companion runs only in the local macOS desktop UI extension host. It
refuses VS Code for the Web and remote workspaces rather than treating a remote
path as a local path.

Before staging anything, the companion reads a current owner-only capability
heartbeat from the installed Production app and verifies the context contract,
supported source kinds, limits and acknowledgement version. An editor command
then writes one bounded, owner-only `.parleycontext` manifest to Parley's
private Production integration inbox and asks LaunchServices to open it. The
manifest contains only a workspace and explicit source descriptions; it cannot
name a pane, vendor, permission, prompt or submit action.

Parley consumes the manifest once and opens its normal editable context-pack
preview. Current files and Git diffs are recaptured from disk by Parley; scoped
SCM diffs pass an explicit relative path only after Git's `--` separator.
Selections and diagnostics are labelled as VS Code-provided captures. A ready
agent pane in that workspace is required as the eventual source, but no agent
is started and nothing is sent until the person reviews the pack and uses one
of Parley's existing confirmed send actions.

LaunchServices success is not treated as acceptance. Parley writes a bounded,
correlated, one-shot acknowledgement to a fixed private outbox only after it
has accepted or rejected the preview. The companion reports success only after
reading that acknowledgement; rejection and expiry messages carry no source
text, paths, prompt, result, credential or replay authority.

**Parley: Diagnose Companion** reports local runtime, contract, heartbeat and
limit state in an output channel. Its report intentionally omits workspace
paths, source text, prompts, results, terminal output and credentials.

Attention uses a separate owner-only, bounded snapshot. It contains workspace
and pane labels, counts and opaque pane/handoff ids only—never prompt or answer
text, terminal output, commands, folders or credentials. Strict focus links can
select an existing pane or Status Center record but cannot start an agent,
inject terminal input or submit work.

Basket tree labels contain source kind, relative file and line attribution but
never selection or diagnostic bodies. Those explicitly captured bodies remain
in memory until accepted review, manual removal/clear or extension-host exit.

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
