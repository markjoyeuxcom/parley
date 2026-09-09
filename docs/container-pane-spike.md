# Container pane spike — 9 September 2026

This is a local prototype result, not a release acceptance or a compatibility
promise for other images. The native macOS core and Ghostty remain on the host.

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
or that every protocol instruction was followed. No login cache or terminal
history was inspected to record this result.

Choose **Sign in with Device Code** inside Codex and complete it in the host
browser. No callback port is published by the current container launch.
[Official OpenAI authentication guidance](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)
recommends device-code authentication when the localhost callback is blocked.
The deprecated Landlock mode remains a temporary prototype compatibility
choice; a supported vendor sandbox path is required before stable promotion.

## Decision and remaining acceptance

| Vendor | Prototype decision | Release decision |
| --- | --- | --- |
| Codex | Device sign-in and an interactive reply reported working by Mark. Legacy Landlock is a deprecated prototype option. | Pending a supported sandbox path, ordinary approval prompts, fresh/resumed instruction uptake and login persistence. |
| Claude Code | Continue as an experimental image launch with explicit disclosure that its sandbox may be unavailable. | Pending subscription sign-in, sandbox/ordinary permission behavior, fresh/resumed instruction uptake and login persistence. |

Neither vendor is cleared for a stable release by this spike. If a vendor
requires a permission-bypass flag, refuse that configuration. Do not mount host
credentials or substitute API authentication. Follow the human acceptance steps
in [RELEASING.md](../RELEASING.md#experimental-container-acceptance), including
restart, workspace close, daemon outage, saved-state deletion and total host
plus VM idle cost. Docker Desktop and Colima have not been tested.

Worktree Git mounts and container team provisioning remain deferred. A linked
worktree does not implicitly grant access to its parent repository.
