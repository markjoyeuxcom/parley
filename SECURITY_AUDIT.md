# Parley security assessment

Updated: 30 August 2026

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
| Agent access to Parley control authority | **Mitigated for vendor panes.** Every vendor process tree receives a deny-first Seatbelt profile and only its generated protocol files, managed shim and capability-named endpoint. Shell panes remain trusted, unsandboxed human shells. |
| Sibling pane capability reuse | **Mitigated.** Each pane has a durable random credential, and the filesystem transport rejects a valid token presented through another pane's endpoint. |
| Relayed model output can influence another model | **Accepted product risk.** Messages are attributed and targets are explicit, but model-authored content is untrusted. Permission prompts remain vendor-owned and `paste` allows review before submission. |
| Terminal submission could merge multiline payloads with Enter events | **Fixed.** Ghostty paste carries the payload as one text operation. Submission is a distinct Enter event after paste succeeds. |
| Process metadata could be mistaken for prompt readiness | **Fixed.** Parley records only whether a retained Ghostty surface is attached and can accept input. It does not infer prompt, permission or thinking state from terminal text. |
| Pane capabilities survived process replacement | **Fixed.** Restart rotates the credential and inherited Parley capability variables are scrubbed before launch. |
| Mutable relay locator permitted remote delivery | **Fixed.** Agent commands use one local capability-separated filesystem transport; the UI uses an authenticated local Unix socket. Neither accepts a remote destination. |
| Unbounded or stranded automated work | **Mitigated.** Targets admit one active Ask or delegation, waits observe pane closure and credential rotation, cancellation is explicit, durable records are bounded and uncertain delivery is never silently retried. |
| Complete inherited launch environment | **Partially mitigated.** Parley capabilities and parent multiplexer markers are scrubbed, compatibility probes use a minimal environment and vendor process access is constrained by Seatbelt. A complete vendor-launch allowlist is not claimed. |

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

`npm test` runs deterministic native checks, packaging/security tests, the VS
Code companion contract and the public repository scan. The public scan checks
tracked and publishable files plus complete reachable Git patch history for
common credential patterns and sensitive filenames. CI fetches complete history
so the gate cannot silently shrink to the latest commit.

Terminal and lifetime changes additionally use `npm run test:soak` to exercise
retained Ghostty surfaces without starting a vendor CLI.

## Limitations

- Parley does not defend against root, the logged-in Mac owner deliberately
  reading local state, a compromised vendor binary or peer software with equal
  user authority.
- Seatbelt contains Parley-launched vendor trees; it is not account-wide process
  isolation.
- Prompt injection cannot be eliminated by attribution. Keep vendor permission
  prompts enabled, use restrictive profiles and choose unsent paste when human
  review is required.
- Ghostty, vendor CLI internals, macOS crash reports and swap behavior remain
  third-party or operating-system boundaries.
- The beta remains unnotarized until release metadata and clean-Mac validation
  say otherwise.
