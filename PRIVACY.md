# Privacy

Parley does not operate a hosted service and does not collect telemetry,
analytics, prompts, answers, terminal output or repository contents.

## Data stored on the Mac

Parley keeps its runtime, workspace layouts, settings and bounded collaboration
history locally. [INSTALL.md](INSTALL.md) lists every normal installation and
runtime location, explains what survives an upgrade and describes deliberate
uninstall and purge behavior.

Vendor CLIs continue to contact their own providers under the accounts and
terms already configured by the user. Parley does not proxy, replace or observe
those service connections. Files and commands used by a vendor CLI remain
subject to that CLI's permissions and privacy behavior.

## Deliberate network actions

Parley's own application makes a network request only when the user explicitly
checks GitHub Releases or downloads a selected release asset. The update flow
does not upload local information. It validates the release manifest, asset
metadata and SHA-256 checksum before presenting a downloaded DMG.

The beta feedback and diagnostics tools create local, owner-only archives for
review. They have no upload action and structurally exclude credentials,
prompts, answers and terminal content. A collaboration-history Markdown export
is different: it intentionally contains the selected question and result bodies
and must be reviewed before sharing.

The local VS Code companion can send only explicitly selected editor context
into Parley's editable preview. It refuses web and remote extension hosts and
cannot start an agent or submit a prompt.
