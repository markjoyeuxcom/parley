# Parley roadmap

Parley is a native macOS workbench for visible, supervised cross-vendor AI CLI
collaboration. It coordinates existing subscription CLIs; it does not replace
their models, authentication, tools, permission prompts or terminal interfaces.

## Product boundary

A feature belongs in Parley when it coordinates different vendor panes or makes
that coordination visible, safe, portable or recoverable. Work one vendor can
perform alone stays with that vendor.

Non-negotiable properties:

- locally installed subscription CLIs only;
- real vendor TUIs and permission prompts;
- explicit pane targets and no implicit broadcast;
- visible, interruptible work;
- local-only coordination and durable records;
- one canonical shared protocol;
- honest state from owned or authoritative facts only;
- one native app and one embedded Ghostty terminal stack.

## Current baseline

### Native app and pane lifetime

- [x] SwiftUI workspace surface with retained Ghostty panes.
- [x] One real PTY/process and direct mouse selection, copy and scroll per pane.
- [x] Selected-pane border and pane identity visible in the native split tree.
- [x] More than four independent panes without shared-input or focus collapse.
- [x] Closing the main window keeps panes alive while the app remains running.
- [x] Reopening the window returns to the same retained surfaces.
- [x] Full quit and Stop Everything end exact pane processes and coordination.
- [x] Eight-pane real-Ghostty soak verifies input isolation, hidden-window
  continuity and exact PID teardown.
- [x] Remove the external terminal multiplexer, old renderer, conversion path
  and related CI/release dependencies.

### App-resident coordination

- [x] Relay broker, control socket, consultations and filesystem transport live
  inside the application process.
- [x] Remove the standalone core executable, background login item and upgrade
  handover machinery.
- [x] One-executable app packaging and runtime manifest.
- [x] Window close keeps coordination available; application quit ends it.
- [x] Status Center reports embedded terminal and app-resident core health.

### Delivery correctness

- [x] Pane-scoped durable credentials establish the real sender.
- [x] Exact pane, explicit role and unique-vendor target resolution.
- [x] Refuse ambiguous, same-pane, shell, missing and busy targets.
- [x] Relay submits; Paste remains the explicit review-before-send route.
- [x] Ghostty paste carries one multiline payload and Enter is a separate event.
- [x] Ask/Answer correlation, tracked Delegate/Done/Fail, Status and Wait.
- [x] Copilot focus/trust handling without bypassing its approval flow.
- [x] Durable receipts and interruption reasons.

### Safety boundary

- [x] One canonical `AgentProtocol.text` and protocol version stamp.
- [x] Vendor-specific injection mechanics without divergent wording.
- [x] Seatbelt boundary around every vendor process tree.
- [x] Capability-named relay endpoints and exact endpoint/token authentication.
- [x] No raw control capability, credentials or broad private runtime exposed to
  an adjacent agent pane.
- [x] Fixed executable/argv process spawning and bounded payloads.
- [x] Shell panes remain explicit trusted human shells.

### Supervised collaboration

- [x] Human Ask and Return previews.
- [x] Activity lane, handoff chains and Status Center.
- [x] Explicit stop/cancel/retry/repeat actions.
- [x] Local handoff history with retention and reviewed export.
- [x] Supervised lead workflows and bounded fan-out.
- [x] Honest Unknown when no structured vendor state exists.

### Daily workspace

- [x] Stable workspace ids, zero-to-many folder attachments and optional New
  Pane Folders.
- [x] Favourite folders and bounded external opening.
- [x] Durable native split layouts without live ids.
- [x] Saved layouts and portable team templates.
- [x] Stable roles and explicit local/cross-workspace role addressing.
- [x] Pane move preserving the exact retained surface and configuration clone
  creating fresh identity.
- [x] Workspace briefs, pinned snippets and reviewed context packs.
- [x] Git context/diff capture and optional worktree awareness.
- [x] Preview-only VS Code context import and content-free attention projection.

### Shipping

- [x] Isolated Production and Development runtimes.
- [x] Quota-free environment and semantic vendor compatibility checks.
- [x] Deterministic native contracts, real-Ghostty lifecycle checks and soak.
- [x] One-executable app/ZIP/DMG packaging with signatures and licence notices.
- [x] Atomic install/upgrade verification and explicit safe data purge.
- [x] Complete-history public secret scan in CI.

## Next hardening work

### Workspace identity and folder attachments

- [x] Make a workspace a durable collaboration identity independent of any
  repository or directory; zero attached folders must be a valid normal state.
- [x] Replace the mandatory single home-folder association with explicit
  zero-to-many folder attachments. Preserve a separate optional New Pane
  Folder policy rather than treating either value as workspace identity.
- [x] Make **New Workspace** create a folderless collaboration container while
  retaining **Open Folder as Workspace** as the convenient folder-first path.
- [x] Keep every live pane's cwd authoritative and pane-local. Attaching,
  removing or reordering workspace folders must never change a running pane,
  start an agent or imply filesystem permission.
- [x] Give a folderless shell pane a safe launch-directory fallback without
  silently attaching that directory. Require an explicit working directory
  and permission scope before a vendor agent can start.
- [x] Route Finder, `parley open <folder>` and URL requests only through
  explicit attachments: focus one match, offer a choice for several, create a
  folder-backed workspace for none and never guess.
- [x] Support multi-repository collaboration directly, including clear
  attachment management, workspace search and honest **No folders attached**
  state across the sidebar, context tools and Status Center.
- [x] Migrate existing workspaces losslessly: the current home folder becomes
  an attachment and the current New Pane Folder remains the pane-launch
  default. Preserve workspace ids, panes, roles, layouts and handoff history.
- [x] Keep portable team templates path-free. Applying a team to a folderless
  workspace leaves agents stopped until their pane directories and permission
  roots are explicitly bound.
- [x] Add deterministic coverage for zero-, one- and multi-folder workspaces,
  folder removal with live panes, external routing ambiguity and migration of
  existing records.

### Ghostty integration

- [ ] Exercise rapid split/create/close/move cycles with 16 retained panes.
- [ ] Add long-duration resize, Unicode, IME and high-output soak profiles.
- [ ] Verify VoiceOver traversal and keyboard focus restoration across every
  native split mutation.
- [ ] Track upstream wrapper updates and keep the exact pin, lockfile, release
  notes and third-party notices aligned.

### Coordination recovery

- [ ] Add explicit UI recovery for a damaged app-resident control endpoint
  without touching healthy terminal surfaces.
- [ ] Add fault injection between delivery, receipt persistence and terminal
  teardown for every Ask and Delegate terminal state.
- [ ] Preserve clear "delivery occurred; do not resend" guidance on all
  post-delivery persistence failures.

### Cross-vendor workflow depth

- [ ] Improve side-by-side comparison review while retaining exact source pane
  attribution.
- [ ] Add clearer role/lead collision previews for workspace moves and template
  application.
- [ ] Expand context reliability checks for repository changes between preview
  and submission.
- [ ] Continue adding vendor adapters only when their official CLIs preserve
  real subscription, TUI and permission behavior.

### Release confidence

- [ ] Run the full Ghostty soak on each release candidate and retain the JSON
  report as a local release artifact.
- [ ] Add packaged-app UI automation for window close/reopen and confirmed quit
  once it can run deterministically on the macOS CI runner.
- [ ] Complete Developer ID signing and notarization without weakening local
  install verification.

## Explicit non-goals

- Direct model APIs, API-key storage or usage billing.
- A custom chat interface that hides vendor TUIs.
- Hidden background agents or hosted orchestration.
- Approval-bypass flags.
- Inferring internal model state from terminal text.
- A web renderer, embedded browser runtime, second terminal stack or external
  multiplexer.
- Automatic repository mutation outside an explicit visible vendor pane.

## Success measures

- A workspace can be created and retained with zero attached folders, can
  explicitly attach several repositories, and never conflates those
  associations with a live pane's cwd or permission authority.
- A person can run at least six mixed-vendor panes and type, select, copy and
  scroll in each without focus/input collapse.
- Closing and reopening the main window preserves every exact pane process.
- Full application quit leaves no pane or coordination process behind.
- Every cross-vendor message is attributable to an authenticated source and an
  explicit target.
- Failed, interrupted and completed work remains distinguishable without
  reading or guessing from terminal text.
- Deterministic checks, native build, Ghostty soak, packaging checks and public
  repository scan all pass before release.
