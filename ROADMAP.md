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

## Official direction: vendor-driven, Parley-coordinated

**Decision recorded 2 September 2026.** Parley will be the authenticated
cross-vendor runtime, handoff and event layer around real vendor CLIs. It will
not grow parallel research, planning, browser, memory, subagent or task systems
that compete with capabilities already owned by Claude Code, Codex, Agy or
Copilot.

The durable product primitive is the **handoff**. A handoff has an authenticated
source, one explicit target, correlation, lifecycle, result and optional human
review. Cross-vendor verification is another handoff linked to the item it
challenges; it is not a second evidence database. Workspace-level decisions
belong in the Workspace Brief, and multi-handoff review belongs in Status
Center.

Parley owns:

- retained Ghostty panes, process lifetime and exact pane identity;
- workspaces, roles, leads and reviewed folder/capability boundaries;
- authenticated Relay, Ask and Delegate delivery with durable receipts;
- handoff review, reply lineage, recovery and reviewed Context Pack promotion;
- normalized vendor events reported through authenticated pane capabilities;
- local attention, lifecycle, discovery and Task Manager facts.

Vendor CLIs own their reasoning interfaces, plans, research and browser tools,
tasks, teams, subagents, memory, model-specific hooks and MCP/tool semantics.
Parley may adapt an official vendor hook into a small shared event vocabulary,
but it must not reinterpret terminal text or replace the vendor workflow.

### Committed sequence

#### Phase 1 — consolidate around handoffs

- [x] Freeze new first-class workflow windows and further Smart Auto expansion
  until the discovery and event layer is proven.
- [x] Retire the unreleased Research Board model, window, menu, help topic,
  Status Center actions, checks and `parley research` protocol namespace.
- [x] Confirm the experiment never entered a tracked release. Its temporary
  protocol bump existed only in the dirty development tree, so removal first
  restored the released canonical v9 contract. Phase 2 then assigned v10 to
  authenticated discovery and events; Phase 3 assigned v11 to vendor hooks.
- [x] Require no production migration because no Research Board build shipped.
  Leave any local development `research-board.json` untouched rather than
  silently deleting a person's experimental data.
- [x] Retire the separate Handoff Chains model and Status Center surface after
  confirming the current Production and Development runtimes contain no chain
  data. Leave any legacy `handoff-chains.json` untouched and unloaded rather
  than silently deleting a person's data; reviewed handoff attributes and
  lineage remain explicit future work.
- [x] Move durable person-authored investigation conclusions, rationale,
  confidence and open questions into the owning Workspace Brief. Legacy v1
  briefs load with these fields empty rather than inferred.
- [x] Preserve review-gated Context Pack promotion as a Status Center action
  over 1 to 16 explicitly selected returned Ask or Delegate handoffs. The draft
  retains exact handoff ids, routes, workspaces, questions and results, and no
  new handoff is submitted automatically.

#### Phase 2 — authenticated discovery and events

- [x] Add `parley whoami` for the caller's authenticated pane, workspace,
  vendor and role identity without revealing credentials.
- [x] Add `parley panes` for bounded discovery of explicit non-self agent
  targets and authoritative pane lifecycle and input-path facts.
- [x] Add `parley events --since <cursor>` for local, monotonically ordered,
  resumable cross-vendor lifecycle and handoff events, bounded to 100 per page.
- [x] Keep discovery and event payloads content-minimal, runtime-local and
  protected by the existing pane capability boundary. They omit credentials,
  folders, terminal text, questions, results and native activity details.

#### Phase 3 — official vendor hook adapters

- [x] Add `parley signal <event>` as the authenticated ingress reserved for
  Parley-managed vendor hook adapters.
- [x] Normalize official structured hooks, where available, to a deliberately
  small vocabulary: `session-started`, `turn-started`, `turn-ended`,
  `awaiting-permission`, `notification` and `session-ended`.
- [x] Record the emitting pane and vendor as owned identity; never allow a hook
  payload to choose another sender.
- [x] Report **Unknown** when a vendor lacks an authoritative hook. Do not fill
  gaps with prompt scraping, terminal heuristics or guessed completion.
- [x] Keep high-frequency turn and notification signals out of durable human
  activity. They update live pane state and a separate bounded in-memory event
  ring; only session boundaries and awaiting-permission remain durable for
  supervision and recovery diagnostics.
- [x] Verify each vendor's current official hook contract at implementation
  time and keep adapters independent of the canonical protocol wording.
  Verification on 2 September 2026 confirmed session-scoped hook execution for
  Claude Code and Codex and confirmed Copilot `--plugin-dir` attachment. Copilot
  remains Unknown until its CLI executes the attached hook. Agy documents hooks
  only in persistent user or workspace configuration, so Parley intentionally
  installs no Agy adapter.

#### Phase 4 — review primitives in Status Center

- [x] Add **Challenge** and **Verify** actions that create one correlated
  handoff to one explicit pane and retain `inReplyTo` lineage.
- [x] Add person-owned verdict and note fields to completed handoffs. Agents may
  propose evidence but cannot mark their own result reviewed.
- [x] Support side-by-side and multi-select review without creating a separate
  evidence entity or hidden synthesis step.
- [x] Extend selected-result Context Pack promotion so relationship, verdict
  and review state are preserved with the existing source pane and route
  attribution.
- [x] Keep source selection explicit and stop at human review before any new
  vendor submission.

  Implementation verified on 2 September 2026 with deterministic broker,
  journal, legacy decoding, Context Pack, Markdown export and authenticated
  native-control transport checks. Linked reviews use the ordinary correlated
  Ask lifecycle; human verdict mutation has no pane-capability route.

#### Phase 5 — prove the runtime, then prune

- [x] Add local-only product diagnostics for which coordination primitives are
  used, without collecting prompts, results, terminal content or telemetry.
- [ ] Measure delivery correctness, event loss/replay, recovery time and
  long-running pane stability before expanding automation.
- [x] Remove unused duplicate surfaces after their durable data has migrated.
- [x] Make runtime soak quality and exact teardown a release gate for this
  direction.

  Schema 3 diagnostics now record content-free primitive usage, typed delivery
  outcomes, the retained event window and authoritative failure-to-session
  recovery timings. The retired Research Board and separate Handoff Chains
  surfaces were removed before this phase. Draft releases now fail closed on a
  25-round, eight-pane Ghostty soak and attach its checksummed JSON report.
  A passing long-running pane-stability measurement remains open: the managed
  development harness used on 2 September 2026 denied every Ghostty child shell
  (0/8 PIDs and 0/8 TTYs), so it could not produce a valid passing report here.

## Ranked product improvements

**Claude review recorded 2 September 2026.** These are the next product
opportunities in priority order. They remain subject to the product boundary:
each must improve visible, safe or recoverable cross-vendor coordination
without replacing vendor-owned reasoning or terminal workflows.

1. [x] **Two-keystroke selection relay** — Command-Shift-A opens the active
   pane's exact Ghostty selection in the existing reviewed Ask composer using
   that source pane's last explicit eligible target. The source, target and both
   vendors remain prominent; Command-Return is a separate confirmation and
   nothing auto-submits. Target memory is bounded, source-specific and
   session-local. **Effort:** small.
2. [x] **Detached Ask recovery and Delegate steering** — Print an Ask handoff
   id at submission, allow `parley wait <id>` to recover its durable completed
   answer for the original source credential generation, and guide work likely
   to exceed one minute toward Delegate. **Effort:** small.
   Protocol v12 now prints the accepted Ask id once on stderr while preserving
   stdout for the exact answer. Explicit Wait accepts Ask or Delegate ids,
   enforces the original source pane launch generation and reloads completed
   answers from the durable handoff journal. `current` remains delegation-only,
   and shared guidance directs work likely to exceed one minute to Delegate.
3. [x] **Pane attention ring and jump-to-attention shortcut** — Highlight
   authoritative permission requests, returned results and interrupted
   handoffs, then cycle those items through the existing attention model. Show
   signal age so stale hook state is never presented as current fact.
   **Effort:** small to medium.
   Pane leaves now use an orange permission, accent result or red interrupted
   outer ring while a separately inset accent line preserves selected-pane
   identity. Headers show a live age; official hook state says **PERMISSION
   REPORTED** rather than claiming the prompt is still waiting. Command-Shift-J
   cycles newest-first, focusing a live permission pane or opening the exact
   durable result/interruption in Status Center.
4. [x] **Explicit restart and vendor-owned resume** — Offer Restart and Resume
   per pane using only a vendor's documented continuation mechanism, with plain
   restart as fallback. State clearly that the vendor decides whether its
   conversation can resume; Parley never claims the session survived.
   **Effort:** small to medium.
   Agent menus now separate fresh Start/Restart from Resume. Claude, Codex and
   Copilot open their vendor-owned pickers; Agy attempts its documented most
   recent conversation in the pane working directory. Every Resume retains the
   pane folder, repeats permission review and is launch-generation scoped.
   Status Center records **RESUME REQUESTED** rather than claiming restoration.
5. [x] **Signal provenance and age in the composer** — Show which authenticated
   pane hook capability reported the advisory state and when, without using it
   as a delivery refusal or inferring readiness. **Effort:** small.
   The reviewed handoff composer now shows the exact target pane and vendor
   hook, reported state, official event and live age. Unsupported, unsigned,
   stopped and dead targets produce no signal claim. The strip is explicitly
   **ADVISORY ONLY** and neither blocks nor authorizes submission.
6. [x] **Bounded delegation progress notes** — Add one latest 200-byte,
   control-stripped, agent-declared progress note to each active delegation and
   show it in the existing handoff inspector rather than creating an event
   stream or workflow window. **Effort:** small to medium.
   Protocol v13 adds target-owned `parley progress current "<note>"`. The
   broker normalizes it to one control-free line, enforces the UTF-8 byte bound,
   durably replaces one latest note without inventing a lifecycle transition,
   exposes it only through the initiator's structured status and labels it
   **AGENT-DECLARED** in the existing Status Center inspector.
7. [x] **Owned workspace facts in the sidebar** — Add pane cwd, Git branch,
   attributed listening ports and last authoritative attention reason using
   throttled fixed-argument process inspection, never terminal scraping.
   **Effort:** medium.
   Pane rows now show the exact abbreviated cwd and existing bounded Git
   snapshot, plus a second compact line for process state, up to eight
   deduplicated TCP listeners and the latest exact-pane attention reason.
   Listener discovery runs at most every ten seconds, or immediately when the
   Task Manager's Refresh button forces it, and invokes `/usr/sbin/lsof` once
   with a bounded newest-first PID argv after Task Manager's TTY/process-tree
   attribution. The one-second refresh signature contains only Ghostty and
   pane-lifecycle facts, so a change in the marker anchor alone waits for the
   next ten-second or manual refresh. The pane anchor comes from Ghostty when
   the pinned terminal reports a foreground PID or TTY; otherwise the resolver
   reads the `PARLEY_PANE_ID` marker from app-owned launch roots (a visible
   process whose parent is the app, or whose parent is exactly one verified
   invisible intermediate such as `login` that the app owns) and, only when a
   platform root hides its environment, from a bounded set of that root's own
   descendants. Nothing read is persisted. lsof stdout is used on exit status
   0, and on exit status 1 only when it carries process records; a failed,
   empty-status-1 or timed-out inspection keeps the previous snapshot and its
   freshness. Unrelated host processes and terminal bytes never enter the
   projection.
8. [x] **Reviewed `parley done --file <path>` results** — Reuse the bounded
   `agentFileDraft` path so a delegation can return a substantial file for
   explicit human review and optional Context Pack promotion. Preserve existing
   path containment, provenance and 90 KB limits. **Effort:** small to medium.
   Protocol v14 adds `parley done <id|current> --file <path>` for one UTF-8
   file contained by the authenticated target pane's working folder. Completion
   is recorded only after the existing 60 KB part/90 KB rendered Context Pack
   boundary accepts and durably stores an `agentFileDraft`; failures leave the
   delegation waiting. The initiator receives a compact receipt linked to the
   review rather than the file body. Status Center opens the exact editable
   review for optional delivery, while unrelated panes, stale credentials,
   oversized files and implicit provenance promotion remain refused.
9. [x] **Allowlisted Ghostty appearance import** — Reuse appearance-only font,
   theme and palette settings from the person's Ghostty configuration while
   excluding commands, key bindings and all behavioral options. Parley's own
   terminal preference remains the explicit override. **Effort:** small to
   medium.
   Terminal Appearance now imports Ghostty's standard XDG and macOS config
   locations in documented precedence order, plus built-in, XDG-named or
   explicit absolute theme files. A dependency-free 256 KB/4,096-line parser
   retains only bounded font family, font size, palette and hex colour fields;
   it never follows `config-file`, retains raw text or admits commands,
   keybindings, shell integration, cursor behavior or other settings. The UI
   previews the sanitized result, reports imported and ignored counts, applies
   it to every retained and future pane through typed Ghostty theme commands
   and keeps Parley's independently optional family and size as higher-priority
   overrides. Sanitized preferences remain isolated by runtime. Protocol v14
   is unchanged because no agent-facing semantics changed.
10. [ ] **Notarized automatic updates and Homebrew cask** — After Developer ID
    notarization, publish a signed update feed from the release workflow and a
    cask for straightforward installation. Protect the update channel with
    signed entries and local verification before replacement. **Effort:**
    medium to large.

    The implementation now pins and embeds Sparkle, exposes a Production-only
    opt-in stable checker, forbids silent background installation and preserves
    Parley's pane-aware quit confirmation. Release automation fails closed on
    missing Developer ID, notary or Ed25519 material; signs Sparkle helpers
    inside-out; notarizes and staples the app and DMG; verifies Gatekeeper; and
    emits a signed appcast plus SHA-256-pinned cask. Publishing opens a separate
    reviewed cask pull request and never writes directly to main. This item
    remains open until repository secrets are configured and one real draft is
    notarized, installed on a clean Mac, updated through Sparkle and published
    with its cask PR verified.

## Cross-vendor delegation loop

**Recorded 3 September 2026** after the first real end-to-end loop: Claude
investigated and implemented the macOS pane process-attribution fix under a
Codex delegation of roughly twenty minutes, Codex reviewed the shared diff and
found three weaknesses, Claude corrected them, and Codex verified the result
independently. The loop produced correct work. Its one real weakness was
visibility while the delegation ran, not the duration.

The decisive fact for planning: **protocol v14 already provides
`parley progress current "<note>"`** (item 6 above), and the delegated pane
never called it. The delegation asked for a result rather than milestones, and
nothing in Status Center made the silence visible. Visibility is therefore an
adoption and presentation problem before it is a protocol problem, and every
item below is ordered on that basis.

Already built (no roadmap work): one latest 200-byte AGENT-DECLARED progress
note per active delegation with its age in the inspector (protocol v13/v14);
`parley done --file` for substantial results (protocol v14); Challenge and
Verify lineage for Ask children (`inReplyToHandoffID`, relationship); target
hook signal provenance and age (Phase 3, item 5).

Guardrails that apply to every item in this section:

- No progress, readiness or completion is ever inferred from terminal text.
- No estimate of completion, remaining time or "thinking" is shown.
- Progress stays one bounded latest note, never a stream or a transition.
- No daemon, background executor or Parley-run verification of agent claims.
- Every agent-supplied field is labelled **AGENT-DECLARED** and shown as a
  claim; Parley-owned facts are limited to timestamps, Git revision and paths.
- Any new agent-facing command lands in one batched protocol bump (v15) so
  live panes see **RESTART FOR PROTOCOL** once; presentation, Git facts and
  conventions need no bump.

11. [x] **Delegation visibility from owned facts** — For each active or
    recently returned delegation, show elapsed time since delivery, the latest
    AGENT-DECLARED progress note with its age, the target's last authenticated
    hook signal with its age, and the factual state **No explicit update for
    10 minutes** once no progress note or hook signal has arrived in that
    window. Change the Delegate composer's default guidance to ask the target
    to post `parley progress current` at each milestone and to use
    `parley done --file` for substantial results. **Effort:** small.
    **Depends on:** nothing; no protocol change. **Acceptance:** a projection
    check computes elapsed, note age, signal age and the ten-minute state from
    timestamps alone and yields no state when no timestamps exist; the row and
    inspector never show an estimate or a "thinking" label; the ten-minute
    state is styled as information, not failure; the default Delegate text
    contains the milestone request and remains fully editable; a real
    delegation shows all three facts within one refresh tick.
    The projection requires an exact delivered transition and derives, from
    owned timestamps only, elapsed time since delivery, the bounded
    **AGENT-DECLARED** progress note with its age, the exact target pane's
    authenticated hook signal with its age, and the informational
    **No explicit update for 10 minutes** state measured from the newest of
    those timestamps; a never-delivered delegation yields no facts. Active
    and unread-result rows, the Status Center inspector and the Collaboration
    dock render the facts on one-second timelines without inferred activity
    or completion. The editable default Delegate guidance now requests
    milestone `parley progress current` notes and the complete
    `parley done current --file <path>` form. Protocol remains v14.
    Verification: 136 deterministic native checks pass; the two real-Ghostty
    child-shell checks remain blocked by the installed managed-agent boundary;
    58 Node and companion checks pass; the public scan passes; the native
    build passes using the established no-nested-sandbox path.
12. [x] **Request Changes as a linked child delegation** — Add a native
    **Request Changes…** action on a returned Delegate result and a lead-pane
    form of `parley delegate` that names the parent, creating one Delegate
    child with `inReplyToHandoffID` and relationship `requestChanges`. Status
    Center will render the thread Delegation → Result → Request Changes →
    Revised Result on the existing handoffs, and the Markdown export will
    preserve it.
    Human verdicts stay native-control-only; a vendor's request for changes is
    a linked delegation, never a verdict. **Effort:** medium. **Depends on:**
    item 11 for presentation; this is the one item that needs the batched
    protocol v15 bump. **Acceptance:** a pane credential cannot forge lineage
    or name a parent it did not initiate or receive; the parent must be a
    Delegate with a returned result; the child inherits target busy rules and
    is never queued as a busy draft; deterministic checks cover forged parent,
    missing parent, parent without result, thread ordering and export; no new
    store, window, state or assignee field is introduced.
    Protocol v15 is the planned single bump. `parley delegate <target>
    --parent <handoff-id>` and the native **Request Changes** action create
    exactly one Delegate child with `inReplyToHandoffID` and relationship
    `requestChanges` on the existing handoffs. The broker requires a parent
    that exists, is a Delegate and has a returned result; a pane credential
    may name only a parent it initiated or received; ordinary target
    resolution and the busy refusal apply, and nothing is queued or drafted.
    Human verdicts remain native-control-only. Status Center renders the
    chronological Delegation → Result → Request changes → Revised result
    thread from owned receipts, and the Markdown export carries the same
    thread and linked children. Independent review reproduced 140 native
    checks passing plus the two known managed-pane real-Ghostty failures, 58
    Node checks passing, syntax passing, the public scan passing, the diff
    check clean and the native build passing.
13. [x] **Bounded informational Git facts per delegation** — At delegate
    creation and again at done or fail, record the target pane cwd's `HEAD`
    revision and dirty path list (paths only, at most about 200, read with the
    existing fixed-argument Git capture) and show **N paths changed since
    delegated** with the list. Label it **shared worktree: not attribution**,
    because other panes and the person edit the same tree. **Effort:** small
    to medium. **Depends on:** item 11 for placement; no protocol change.
    **Acceptance:** file contents and diffs are never captured; the list is
    capped and labelled; a mismatch or an unreadable repository is
    informational and never a failure state; a non-Git cwd records nothing;
    checks cover the cap, the label, a clean tree and a detached HEAD.
    Existing handoff and journal records carry two optional snapshots of the
    target pane's cwd, taken at delegation and again at done or fail. One
    fixed `/usr/bin/git` argv captures the HEAD revision, the branch or
    detached state, and a sorted, deduplicated dirty path list capped at 200
    paths, never file contents, diffs or authorship. A non-Git cwd records
    nothing; a missing folder, unreadable repository or timeout is recorded
    as an informational reason only and never changes the outcome. The
    comparison is the symmetric difference of the two dirty path lists,
    calls out HEAD movement and truncation, and is labelled **shared
    worktree: not attribution**. Git runs outside the coordination lock; the
    broker revalidates the authoritative created record under the lock
    before submit and journals the delegation-time facts before terminal
    input, so a cancellation during capture can never submit and a target
    that completes while submit unwinds retains both snapshots. Raw paths
    stay exact for comparison while the inspector and the Markdown export
    escape Unicode control and format characters and line and paragraph
    separators. Protocol remains v15. Independent verification: 149 native
    checks pass; the two known managed-pane real-Ghostty checks remain
    environment-blocked; 58 Node and companion checks pass; syntax, the
    public scan over 179 files, the diff check and the native build pass
    using the established no-nested-sandbox path.
14. [x] **Completion-evidence convention in `done --file`** — Document a
    plain Markdown template with the sections **Implemented**, **Tested**
    (each command and its outcome) and **Unable to test** (with the reason).
    Status Center renders those headings as a **COMPLETION EVIDENCE**
    section labelled AGENT-DECLARED and falls back to plain text for any
    other shape.
    No schema and no automatic executor; Parley never runs a command to check
    a claim. **Effort:** small. **Depends on:** item 12 so a Request Changes
    child can refer to evidence items; no protocol change. **Acceptance:** the
    renderer accepts the three headings in any order, ignores unknown
    headings, never marks anything verified, and a file without the headings
    renders exactly as today; a structured JSON shape is considered only after
    the existing diagnostics counts show the convention is used.
    Verification: the 5 focused completion-evidence checks pass; the full
    native suite reports 154 passing with exactly the two known managed-pane
    real-Ghostty failures (app-resident pane lifecycle and six-pane input
    isolation); 58 Node and companion checks pass; the node syntax checks,
    the public scan over 181 files, `git diff --check` and the native build
    via the established `--disable-sandbox` path pass. AgentProtocol remains
    v15 and is unchanged by item 14.
15. [x] **Lead practice and a Review and correct recipe** — Document the
    sequence Delegate → Progress → Result → Cross-vendor review →
    Corrections → Independent verification as practice in the engineering
    guide, and add one built-in Recipe whose text asks the target for milestone
    progress and the completion-evidence sections. **Explicitly rejected:** a
    mandatory workflow state machine, a workflow window or automatic
    transitions; this loop ran end to end with none of them, which is the
    evidence it does not need them. **Effort:** small. **Depends on:** items
    11 and 14 for the text it references. **Acceptance:** the recipe is a
    prompt template only, carries no state and no automation, and the guide
    names the practice as guidance rather than a required sequence.
    The engineering guide names the practice as guidance, not a required
    sequence, and the built-in **Review and correct** recipe is that practice
    as an editable prompt template only: it asks the lead to delegate with
    milestone `parley progress` notes, to require the completion-evidence
    headings, to have a different vendor review, to send corrections as one
    linked Request Changes child and to verify independently. It carries no
    phase, state or automation. The recipe requires at least two explicit
    non-lead targets from different vendors, refuses a single target or a
    same-vendor-only selection before anything is sent, and leaves ordinary
    Delegate and Compare targeting unchanged. The recipe store migrates a
    valid version 1 four-recipe file additively to version 2, keeping local
    edits and backfilling only the new recipe, and still refuses an
    incomplete set. AgentProtocol remains v15 and is unchanged by item 15.
    Verification: the 3 focused Review and correct checks pass; all 3 recipe
    and migration checks pass; the full native suite reports 158 passing with
    exactly the two known managed-pane real-Ghostty failures (app-resident
    pane lifecycle and six-pane input isolation); 58 Node and companion
    checks pass; the node syntax checks, the public scan over 182 files,
    `git diff --check` and the native build via the established
    `--disable-sandbox` path pass.

Minimal implementation order: 11, then 12 with the single v15 bump, then 13,
then 14, then 15. Items 11, 13, 14 and 15 change no agent-facing protocol.

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
- [x] Native Task Manager attributes live process trees to exact Ghostty panes,
  groups them by workspace and exposes only confirmed pane-level controls.

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
- [x] Activity lane and Status Center. The separate Handoff Chains experiment
  was later retired before the handoff-review event model so Parley does not
  maintain a parallel evidence store.
- [x] Explicit stop/cancel/retry/repeat actions.
- [x] Local handoff history with retention and reviewed export.
- [x] Supervised lead workflows and bounded fan-out.
- [x] Smart Plan → Review → Implement → Verify orchestration with persisted
  Supervised and Auto modes, automation-attributed transitions and a mandatory
  final human completion decision.
- [x] Research Board experiment validated exact handoff attribution,
  person-owned verdicts, reply lineage and reviewed multi-result Context Pack
  promotion. It is superseded as a standalone product surface; Phase 1 retains
  those useful primitives while removing the parallel evidence model.
- [x] Bounded independent evidence collection demonstrated explicit multi-pane
  sourcing without inferred synthesis. Future collection remains ordinary,
  attributable handoffs reviewed in Status Center.
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
- [x] VS Code companion Phase 1 — fail-closed Production capability negotiation,
  correlated one-shot preview acknowledgements and privacy-safe diagnostics.
- [x] VS Code companion Phase 2 — one multi-select context composer for editor
  selections, files, diagnostics, Explorer resources and whole or path-scoped
  staged/working Git changes.
- [x] VS Code companion Phase 3 — native Collaboration views for content-free
  attention, durable workspaces and exact live-pane navigation without a chat
  surface or hidden vendor control.
- [x] VS Code companion Phase 4 — per-window, per-folder in-memory Context
  Baskets with exact-source replacement, bounded review and clear-on-accepted
  acknowledgement semantics. Captured text is never persisted by the extension.
- [x] VS Code companion Phase 5 — recovery actions, native welcome/onboarding
  surfaces, packaging assets and deterministic model/extension-host coverage.

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

- [x] Run the full Ghostty soak on each release candidate and retain the JSON
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
- A separate research/evidence database or first-class Research Board.
- Parley-owned replacements for vendor planning, browsing, task, team,
  subagent, memory, MCP or tool interfaces.
- Treating terminal text, raw keystroke control or an unauthenticated external
  socket as authoritative coordination state.
- A mandatory delegation workflow state machine, a background executor that
  runs commands to verify agent claims, streamed progress, or estimates of
  completion.

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
- Every reviewed claim remains an attributable handoff with optional human
  verdict, note and reply lineage; workspace decisions have one durable home in
  the Workspace Brief.
- An authenticated pane can discover its own identity, valid targets and new
  authoritative events without gaining control of another pane.
- Unsupported vendor lifecycle state is visibly **Unknown**, never guessed from
  terminal output.
- Failed, interrupted and completed work remains distinguishable without
  reading or guessing from terminal text.
- During a long delegation the person can see elapsed time, the latest
  agent-declared progress note and its age, and the target's last authenticated
  signal without Parley estimating completion or inferring activity.
- Deterministic checks, native build, Ghostty soak, packaging checks and public
  repository scan all pass before release.
