# Parley security assessment

Updated: 10 September 2026 (vendor-managed host permissions)

This assessment describes the current native Swift implementation. Report new
vulnerabilities through [SECURITY.md](SECURITY.md).

## Scope

The review covers embedded Ghostty pane ownership, the app-resident
coordination broker, per-pane capabilities, filesystem transport, terminal
delivery, reviewed context, shared protocol launch behavior, runtime isolation,
packaging and public-release metadata.

The deterministic suite exercises local Ghostty lifecycle, input isolation,
relay, consultation, Seatbelt profile, privacy and release contracts without
launching a vendor CLI or spending subscription quota.

## Finding status

| Finding | Current status |
| --- | --- |
| Agent access to Parley control authority | **Native authority separated; host isolation deliberately reduced.** Native control tokens and command-run settings are memory-only; control requests require the app peer PID, and clients pin the socket path and verify its peer before sending authority. Approved worker bytes must match an app-held digest. Host CLIs have no Parley outer sandbox. Codex receives native tool rules; other vendors retain their own controls. Unrestricted same-user host code can still read pane capabilities or alter local records. Containers retain exact reviewed mounts; the daemon is trusted. |
| Sibling pane capability reuse | **Mitigated.** Each pane has a durable random credential, and the filesystem transport rejects a valid token presented through another pane's endpoint. |
| Relayed model output can influence another model | **Accepted product risk.** Messages are attributed and targets are explicit, but model-authored content is untrusted. Permission prompts remain vendor-owned and `paste` allows review before submission. |
| Terminal submission could merge multiline payloads with Enter events | **Fixed.** Ghostty paste carries the payload as one text operation. Submission is a distinct Enter event after paste succeeds. |
| Process metadata could be mistaken for prompt readiness | **Fixed.** Parley records only whether a retained Ghostty surface is attached and can accept input. It does not infer prompt, permission or thinking state from terminal text. |
| Pane capabilities survived process replacement | **Fixed.** Restart rotates the credential and inherited Parley capability variables are scrubbed before launch. |
| Mutable relay locator permitted remote delivery | **Fixed.** Agent commands use the local filesystem transport. The native client uses a directly supplied socket path, ignores editable locator contents and checks the server PID before sending its token. |
| Unbounded or stranded automated work | **Mitigated.** Targets admit one active Ask or delegation, waits observe pane closure and credential rotation, cancellation is explicit, durable records are bounded and uncertain delivery is never silently retried. |
| Complete inherited launch environment | **Partially mitigated.** Parley capabilities and parent multiplexer markers are scrubbed where required. A complete vendor-launch allowlist is not claimed; host CLIs remain trusted local applications. |

## Host launch and native authority

Host vendors no longer inherit Parley's outer Seatbelt profile, which prevented
Codex from applying its own tool sandbox. No host bypass flags are introduced.
Codex extends its read-only or workspace profile with private-runtime denies and
exact protocol, shim and endpoint exceptions. A transient local config query and
real sandbox probe precede the native host review's start; legacy configuration
that would replace the native rules is refused without editing vendor settings.
Host-team approval checks the same configuration. Other vendor launch controls
remain unchanged; guidance is not presented as enforcement.

The retired `core-control-token` and `command-run-authorization.json` files are
never read. Both automatic command-run choices reset to off on app relaunch.
The control client and server verify kernel peer identity; the client never reads
a mutable locator to choose where to send its memory-only token. Socket writes
suppress SIGPIPE per call, including after a peer closes before sending headers.
Approved worker tickets are single-use and checked against the digest passed from
native memory before any decode or command execution.

## Container permission bypass

The person can explicitly enable vendor permission bypass for a local container
pane or a team's per-vendor container settings. It is off by default; older
records decode as off. Fixed flags are generated only for that container's vendor
command, never the host launch. Native preparation and activation compare the
complete reviewed configuration, including bypass; changing it requires review
and restart. The normal profile restrictions are omitted and the mode is visible.

Docker retains the exact mounts, non-root user, dropped capabilities and
no-new-privileges setting; no daemon socket or host vendor login is mounted.
Bypass permits commands, network use and changes to mounted files without the
usual vendor prompts. The pane's persisted vendor credentials are accessible
inside the container. Shared writable Git hooks or executable configuration may
cause commands to run on the Mac during later host Git operations. Native
requested-host-command approvals remain separate. Neither a vendor bypass nor a
container is a claim that untrusted project code is harmless.

## Current controls

- Production and Development have separate Application Support, preferences,
  relay transports, protocol files, records and exclusive runtime leases.
- The coordination broker shares the Parley application's lifetime. There is
  no background service, login item or separately upgradeable core.
- Automatic routes require a distinct explicit agent target and fail closed on
  shell, missing, ambiguous, stale, dead, unavailable or busy panes.
- Stable handoff identity and idempotency prevent intentional duplicate
  submission. Uncertain partial delivery remains visibly non-retryable.
- Agent-staged context remains labelled as an agent claim. Trusted File, Git
  Diff, Selection and Command Result provenance requires a separate
  revision-checked human approval.
- Diagnostics and beta-feedback bundles exclude credentials, terminal content,
  folders, commands, names and message bodies. Complete history exports are
  explicitly labelled sensitive.
- Release automation requires clean source metadata and produces checksums.
  Hardened-runtime signing does not imply notarization or stapling.

## Verification

`npm test` runs deterministic native checks, packaging/security tests and the
public repository scan. The public scan checks
tracked and publishable files plus complete reachable Git patch history for
common credential patterns and sensitive filenames. CI fetches complete history
so the gate cannot silently shrink to the latest commit.

Terminal and lifetime changes additionally use `npm run test:soak` to exercise
retained Ghostty surfaces without starting a vendor CLI.

## Limitations

- Parley does not defend against root, the logged-in Mac owner deliberately
  reading local state, a compromised vendor binary or peer software with equal
  user authority.
- Host vendor permission rules constrain sandboxed tools, not the vendor parent,
  integrations or approved unsandboxed commands. A profile preflight proves only
  the configuration and tool behavior observed then. Vendor configuration may
  change afterwards. Containers provide stronger separation subject to mounts.
- Native authority is protected against editable-file substitution, not debugger
  injection into app memory or compromise of the Mac account. The staged worker
  result key is readable by unrestricted same-user code before consumption, so
  authenticated captured results are not proof against that adversary.
- Prompt injection cannot be eliminated by attribution. Keep vendor permission
  prompts enabled, use restrictive profiles and choose unsent paste when human
  review is required.
- Ghostty, vendor CLI internals, macOS crash reports and swap behavior remain
  third-party or operating-system boundaries.
- The beta remains unnotarized until release metadata and clean-Mac validation
  say otherwise.
