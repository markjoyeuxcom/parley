# Security policy

Parley launches local AI coding CLIs and coordinates attributed text between
them. A security issue can therefore affect repositories, interactive sessions
or authority granted to a vendor CLI. Please report suspected vulnerabilities
privately.

## Reporting a vulnerability

Use GitHub's private **Report a vulnerability** form under the repository's
Security tab. If private reporting is unavailable, email
`mark.joyeux@markjoyeux.com` with the subject `Parley security report`.

Include the affected Parley build, macOS version, vendor CLI, reproduction
steps and security impact. Do not include credentials, private source code or
complete terminal transcripts. Do not open a public issue before the report is
assessed and a coordinated disclosure date is agreed.

## Supported versions

Security fixes target the latest published beta. Older beta builds are not
maintained as parallel release lines.

## Security boundaries

- Parley has no model API-key path, hosted service, telemetry or remote-control
  backend. Vendor CLIs retain their own authentication and network behavior.
- The coordination broker lives inside the foreground application. The native
  UI uses an authenticated Unix socket; agent panes use distinct
  capability-named filesystem endpoints.
- Vendor process trees launch through a macOS Seatbelt profile that denies
  Parley's broad Application Support directory and relay transport root, then
  reopens only the generated protocol, managed shim and that pane's endpoint.
  Human shell panes remain deliberately unsandboxed user shells.
- A caller's random pane credential establishes its sender identity. It cannot
  select a different source pane or reuse its token through a sibling endpoint.
- Cross-vendor messages remain untrusted model-authored content. Attribution,
  explicit targets and visible tracking do not make that content safe. Parley
  preserves vendor permission prompts and provides an unsent `paste` path.
- Local files are owner-only. Parley does not claim to defend against root, the
  logged-in owner, a compromised vendor executable or other software running
  with equivalent user authority.
- Public beta packages remain explicitly unnotarized until release metadata
  states otherwise. Do not infer notarization from a filename.

The current implementation assessment and accepted residual risks are in
[SECURITY_AUDIT.md](SECURITY_AUDIT.md).
