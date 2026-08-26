# Parley security assessment

Updated: 26 August 2026

This assessment supersedes the initial 22 August 2026 audit. It describes the
current native Swift implementation and distinguishes fixed findings from
residual product risks. Report new vulnerabilities through
[SECURITY.md](SECURITY.md).

## Scope

The review covers the persistent coordination core, tmux ownership, pane and UI
capabilities, filesystem relay transport, terminal delivery, shared agent
protocol, runtime isolation, packaging and public-release metadata.

The deterministic suite includes real local tmux and macOS Seatbelt checks but
does not invoke a vendor model. Opt-in live conformance is the separate gate for
vendor CLI behavior.

## Finding status

| Initial finding | Current status |
| --- | --- |
| Agent access to the tmux control socket | **Mitigated for vendor panes.** Every vendor process tree is launched through a mandatory Seatbelt profile that denies the exact socket and Parley Application Support tree. Shell panes remain deliberately trusted, unsandboxed user shells. |
| Pane and UI capabilities readable by sibling agents | **Mitigated for vendor panes.** Each profile reopens only its capability-named relay endpoint, and the core rejects a pane token presented through a sibling endpoint. Owner-only files are not represented as protection from the Mac's owner or root. |
| Relayed model output can influence another model | **Accepted residual product risk.** Cross-vendor text is attributed and the shared protocol preserves permission prompts and visible automation policy, but model-authored content is not a trustworthy instruction source. `paste` provides explicit review-before-send behavior. |
| Bracketed paste could fail open | **Fixed.** Delivery requires a live relay-enabled agent pane, current protocol metadata and active tmux bracketed-paste mode before any buffer is loaded. Submission is a separate event. |
| Pane capabilities survived process replacement | **Fixed.** Deliberate restart rotates the pane credential, and inherited Parley capability variables are scrubbed before a controller starts. |
| Message bodies can be visible in process arguments | **Open local hardening item.** The filesystem transport keeps credentials out of command arguments and accepts body text on stdin, but callers may still choose the documented argument form. Same-user process inspection is outside the vendor-pane isolation claim. |
| Mutable relay locator permitted remote HTTP(S) | **Fixed.** Agent commands use one capability-separated local filesystem transport. The native UI uses an authenticated Unix-domain control socket; neither accepts a remote relay destination. |
| Unbounded or stranded automated work | **Mitigated.** Workspace automation policy is enforced before dispatch, targets admit one active Ask or delegation, waits observe pane closure and credential rotation, cancellation is explicit, durable records are bounded and uncertain delivery is never silently retried. |
| Complete inherited launch environment | **Partially mitigated.** Inherited Parley capabilities are scrubbed, compatibility probes use a minimal environment and vendor process access is constrained by Seatbelt. A complete vendor-launch allowlist remains incompatible with some vendor authentication and tool discovery and is not claimed. |

## Current controls

- The core and tmux server are local per-user processes with runtime-specific
  sockets and owner-only state.
- Production, Development and explicit Development-attached-to-Production modes
  have separate namespaces and a single-UI lease.
- Sender identity comes from a random pane capability; callers cannot select a
  different source identity.
- Cross-vendor, same-vendor, shell, missing, ambiguous, stale and busy targets
  fail closed.
- Stable handoff identity and idempotency prevent a command retry from
  intentionally submitting the same payload twice. An uncertain partial
  delivery remains visibly non-retryable.
- Context supplied by an agent remains labelled as an agent claim. Only the
  persistent core can capture human-approved file, Git, screen or command
  provenance, and approval is revision-checked against concurrent mutation.
- Logs, diagnostics and beta-feedback bundles exclude credentials and message
  bodies. Complete collaboration-history exports are explicitly labelled as
  sensitive before writing.
- Release automation uses a clean tagged source revision, deterministic
  metadata and SHA-256 checksums. Packages use hardened-runtime signing, but a
  build is not Gatekeeper-ready until Developer ID signing, notarization and
  stapling are independently complete.

## Verification

`npm test` exercises deterministic relay, consultation, sandbox, runtime,
history, release and privacy contracts without starting a vendor CLI. The
public repository gate additionally scans every tracked or unignored file and
the complete reachable Git patch history for common credential formats and
sensitive credential filenames. GitHub CI fetches full history so this check
cannot silently degrade to the latest commit.

The opt-in conformance runner checks the exact vendor adapters and spends model
quota only after explicit confirmation. It refuses existing tracked work,
permission prompts, stale protocols and unsafe paste state.

## Limitations

- Parley does not defend against root, the logged-in Mac owner deliberately
  reading local state, a compromised vendor CLI executable, or software running
  outside Parley's sandbox with equivalent user authority.
- Seatbelt is a containment layer around Parley-launched vendor process trees,
  not a claim that arbitrary macOS processes sharing the account are isolated.
- Prompt injection cannot be eliminated by attribution. Users should retain
  vendor permission prompts, use restrictive permission profiles and choose
  unsent paste for material requiring human review.
- SwiftTerm, tmux, vendor CLI internals, macOS crash reports and swap behavior
  are third-party or operating-system boundaries and are not independently
  audited here.
- The public beta remains explicitly unnotarized until release metadata states
  otherwise and a physical clean-Mac installation gate has passed.
