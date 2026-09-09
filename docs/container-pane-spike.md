# Container pane spike — 9 September 2026

This records the tested local setup and the remaining compatibility work. It
does not establish compatibility with other images. The native macOS core and
Ghostty remain on the host.

## Environment

- Local Unix-socket OrbStack daemon; Docker server reported `29.4.0`, Linux
  `7.0.14-orbstack-00380-ga7e0a2dc9535`, architecture `aarch64`.
- Test-only image `parley-container-spike:local`, inspected image ID
  `sha256:42106c89f9789c73ceb9308dfde06980727e1f5f5b48a3a23367363537b332f0`.
  It uses the already installed devcontainers Debian base and the vendors'
  Linux executables. Parley does not build or pull images as a product feature.
- Codex `0.153.4`, fetched from the [npm registry metadata](https://registry.npmjs.org/@openai/codex/0.153.4-linux-arm64).
- Claude Code `2.1.266`, fetched from the [npm registry metadata](https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64/2.1.266).
  Both downloaded archives were verified against their registry SHA-512
  integrity fields. These are the versions tested, not moving recommendations.

## Observed

The generated Linux shim worked through same-path bind mounts with a non-root
UID/GID. The ownership and mode checks, UUID generation and heartbeat freshness
checks accepted the real Docker file-sharing path. Disposable broker fixtures
passed whoami, attributed Relay, correlated Ask/Answer, Delegate, done --file,
result recovery and context draft/list. A valid sibling capability could not
use the mounted source endpoint, and a nonexistent endpoint mount was refused.
No installed pane's credential was used for these checks.

The native container service pinned the daemon and image, created its private
home volume, recorded the container's full creation ID, attached, reconciled
stop/removal and explicitly deleted the unused volume. The final ownership
label queries showed no remaining containers or named volumes from these tests.

A real Ghostty surface launched a Seatbelt-wrapped Docker client. After initial
layout settled, the guest TTY measured 14 rows by 51 columns, then 27 by 93 after
resize. Foreground Control-C, input while the window was hidden and confirmed
container removal all passed. An immediate startup measurement can see zero
size before layout settles; the check requires a valid settled initial size.

Codex's default Bubblewrap namespace path failed in this unprivileged image.
The explicitly selected `features.use_legacy_landlock=true` path ran an allowed
command and denied an attempted write outside its permitted area. No privileged
container, extra namespace capability, permission bypass flag or automatic
fallback was used. Claude's binary starts, but its sandbox and permission flow
have not been validated in a signed-in interactive session.

## Human test update

Mark reported successful Codex device sign-in and an interactive reply in the
Development build on 9 September. His screenshot also shows Codex's warning
that `features.use_legacy_landlock` is deprecated and will be removed. This
confirms the reported sign-in path; the greeting is not proof that whoami ran
or that every protocol instruction was followed. Mark subsequently reported
that the container pane can both send and receive Parley messages. This records
human confirmation of bidirectional messaging; it does not mark correlated
Ask/Answer, Delegate, reviewed context or resumed-session behavior as tested.
Mark then reported that restarting the container pane worked. Native pane
restart is recorded as passing; vendor Resume and the detailed login-persistence
checks remain separate acceptance items.
No login cache or terminal history was inspected to record these results.

Choose **Sign in with Device Code** inside Codex and complete it in the host
browser. No callback port is published by the current container launch.
[Official OpenAI authentication guidance](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)
recommends device-code authentication when the localhost callback is blocked.
The deprecated Landlock mode remains an explicit compatibility choice for the
tested image. A default sandbox path that works without this setting is a
follow-up because the vendor plans to remove the legacy option.

## Release decision and compatibility follow-ups

| Vendor | Observed coverage | Compatibility follow-ups |
| --- | --- | --- |
| Codex | Device sign-in, an interactive reply, bidirectional Parley messages and pane restart reported working by Mark. Legacy Landlock is explicitly selected and deprecated. | Default sandbox compatibility, ordinary approval prompts, fresh/resumed instruction uptake and login persistence. |
| Claude Code | The image binary starts; the launch disclosure says its sandbox may be unavailable. | Subscription sign-in, sandbox/ordinary permission behavior, fresh/resumed instruction uptake and login persistence. |

Mark approved shipping the reviewed implementation on 9 September: this is a
greenfield project, and the remaining compatibility work does not block the
feature's release. If a vendor requires a permission-bypass flag, refuse that
configuration. Do not mount host credentials or substitute API authentication.
Continue the human compatibility checks
in [RELEASING.md](../RELEASING.md#experimental-container-acceptance), including
restart, workspace close, daemon outage, saved-state deletion and total host
plus VM idle cost. Docker Desktop and Colima have not been tested.

The subsequent follow-up adds explicit shared-Git mount review and container team
settings. A linked worktree does not implicitly grant access to its primary
checkout. These additions have separate checks; the earlier observations above
remain the record of the original spike.

## Default sandbox follow-up

On 9 September the installed local spike image still has `/usr/bin/bwrap`, but
`codex sandbox -- /bin/true` fails namespace creation under Parley's non-root,
capability-dropped container settings. A separate `unshare --user /bin/true`
probe also returns EPERM, while `user.max_user_namespaces` is nonzero. Neither
probe receives host mounts, a vendor login or network access. This establishes
that namespaces are unavailable under this configuration; it does not isolate
the denial to one particular kernel security mechanism.

[OpenAI's sandbox documentation](https://learn.chatgpt.com/docs/sandboxing)
requires namespace support for the Linux sandbox.
[Docker's seccomp documentation](https://docs.docker.com/engine/security/seccomp/)
describes namespace restrictions in its default profile. No working default
sandbox configuration has been established here. Parley keeps its normal
sandbox probe, reports the failure and never silently selects legacy mode,
adds privileged capabilities, or disables a vendor's approvals.
