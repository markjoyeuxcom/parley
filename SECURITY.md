# Security policy

Parley launches local AI coding CLIs and coordinates text between them. A
security issue can therefore affect source repositories, terminal sessions or
the authority granted to a vendor CLI. Please report suspected vulnerabilities
privately.

## Reporting a vulnerability

Use GitHub's private **Report a vulnerability** form under the repository's
Security tab. If private vulnerability reporting is unavailable, email
`mark.joyeux@markjoyeux.com` with the subject `Parley security report`.

Include the affected Parley build, macOS version, vendor CLI, reproduction
steps and the security impact. Do not include real credentials, private source
code or complete terminal transcripts. Please do not open a public issue until
the report has been assessed and a coordinated disclosure date agreed.

## Supported versions

Security fixes target the latest published beta. Older beta builds may receive
an explicit replacement release when a fix affects safe upgrade or local data
handling, but they are not maintained as parallel release lines.

## Security boundaries

- Parley has no model API-key path, hosted service, telemetry or remote-control
  endpoint. Vendor CLIs retain their own authentication and network behavior.
- Vendor agent process trees run inside a mandatory macOS Seatbelt profile that
  denies Parley's control files, tmux socket and sibling pane endpoints. Human
  shell panes are deliberately unsandboxed and trusted.
- Cross-vendor messages are attributed but remain untrusted model-authored
  content. Parley preserves vendor permission prompts and exposes an unsent
  `paste` path; attribution is not a guarantee that the receiving model will
  disregard hostile instructions.
- Local state is protected from other login users with owner-only directories
  and capabilities. Parley does not claim to defend against the Mac's owner,
  root, a compromised vendor binary, or software outside Parley's process
  boundary running with equivalent authority.
- Public beta packages remain explicitly unnotarized until the release metadata
  says otherwise. Never infer notarization from a downloaded filename alone.

The current implementation assessment and accepted residual risks are recorded
in [SECURITY_AUDIT.md](SECURITY_AUDIT.md).
