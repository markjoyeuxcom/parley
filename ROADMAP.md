# Parley roadmap

**Direction:** the native macOS app is the product. Parley is the local
collaboration layer between the user's existing AI coding CLIs. It does not
replace their models, tools, permissions, authentication, or conversations.

This roadmap supersedes older feature lists for product prioritisation. Those
documents describe useful history, but the current north star is the workflow
already working in the native app:

> Give one agent a task. It consults a different vendor, waits for the answer,
> judges that answer, and hands approved work to the right agent. The person can
> see every participant, intervene at any point, and never copy and paste.

## Product boundary

Parley should win on one promise:

> **The easiest native environment for visible, supervised, cross-vendor
> collaboration between the CLI subscriptions you already use.**

Every proposed feature must pass these tests:

1. Does it make working across vendors easier or safer?
2. Does it preserve the real interactive CLI, including its permission prompts?
3. Is the collaboration visible and interruptible by the person using it?
4. Can it remain entirely local and work without API keys?

If one vendor CLI can do it better on its own, Parley should not duplicate it.

## Current baseline

The native application already has the product's essential wedge:

- A SwiftUI and SwiftTerm macOS surface over an isolated persistent tmux server.
- Real Claude Code, Codex, Agy, GitHub Copilot CLI, and shell panes.
- Panes that survive closing and reopening the window.
- A versioned cross-vendor protocol injected into every newly started agent.
- `relay` for an attributed asynchronous handoff, `paste` for an unsent draft,
  and correlated `ask` / `answer` for a blocking consultation.
- Human Ask and Return editors with explicit control over the exact text sent.
- Automatic submission that works across the supported agent TUIs.
- Folder-backed workspace tabs, each represented by a tmux window.
- Workspace-scoped pane lists, recent folders, and cross-workspace addressing.
- Deterministic native checks covering spawning, routing, submission, security
  boundaries, consultations, and workspace lifecycle.

This is a working development build, not yet a dependable distributable app.
The milestones below are ordered by what turns the current prototype into a
daily tool.

## Milestone 1 — Trust the pipe

The first priority is making the working Ask/Answer loop survive ordinary app
lifecycle events and fail clearly when it cannot continue.

### Persistent local coordination core

Move relay ownership out of the window process into a small local background
service. The tmux server already survives the UI closing; Ask, Answer, Relay,
credentials, and collaboration state must survive with it.

- One per-user Parley core, reachable only through a Unix-domain socket.
- The SwiftUI app becomes a client that may attach and detach freely.
- Agent credentials remain scoped to their exact tmux pane.
- Closing the window must not interrupt an agent waiting on `parley ask`.
- A core restart must terminate affected waits with an explicit interruption
  error; it must never leave a caller hanging or pretend an answer arrived.
- Connection discovery must be atomic and self-healing, with no stale port or
  stale socket ambiguity.

### Delivery correctness

- Give every handoff a stable local identifier and an idempotency key.
- Record distinct states: `created`, `delivered`, `waiting`, `answered`,
  `completed`, `cancelled`, `failed`, and `interrupted`.
- A successful command must mean the target received the text and the intended
  submit action occurred; intermediate success must not be reported as final.
- Add timeout, cancellation, dead-pane, app-restart, target-restart, and broker-
  restart tests.
- Keep one active blocking consultation per target until reliable busy/ready
  state exists. Refuse extra work rather than silently queueing it.

### Vendor conformance harness

Create an opt-in live test for each supported CLI that proves:

- protocol injection is present;
- multiline bracketed paste is intact;
- submit starts a turn without a person pressing Enter;
- `parley answer current` returns to the correct waiting pane;
- inactive panes and cross-workspace targets behave correctly;
- trust and permission prompts fail closed.

**Exit gate:** close the UI during an active consultation, reopen it, and watch
the same two pane processes complete the exchange without manual recovery.

## Milestone 2 — See the collaboration

Parley currently performs handoffs correctly but shows too little of what is in
flight. Add an activity surface, not a project-management system.

### Collaboration activity

- A compact workspace activity strip showing `Agy → Codex: waiting`, elapsed
  time, and the latest state.
- Pane and workspace badges for waiting questions, returned answers, failures,
  unread output, and permission-required attention.
- Click any activity to focus its source or target pane.
- Human actions to cancel a wait, retry a failed delivery, or complete a return
  manually when an agent printed instead of returning its answer.
- Native notifications when an answer returns or a pane needs human input,
  with per-workspace controls.

### Status Center window

Add a separate native window that can remain open beside the terminal
workbench or on another display. The main window keeps compact badges; Status
Center provides the detailed operational view.

- An overall banner for the most important current condition: all clear,
  agents waiting, human input required, interrupted work, or core unavailable.
- Workspace and all-workspaces filters, with counts for running agents,
  outstanding questions, tracked delegations, failures, and unread results.
- A **Live collaboration** section showing source → target, operation type,
  concise subject, elapsed time, and exact state for every active handoff.
- An **Agents** section showing pane name, vendor, workspace, process health,
  protocol compatibility, relay availability, known attention state, and the
  work item currently associated with that pane.
- A selected-item inspector containing the complete question or instruction,
  returned answer or completion report, timestamps, and delivery receipts.
- Contextual controls such as Focus Source, Focus Target, Cancel Wait, Retry
  Delivery, Return Manually, Restart for Protocol, and Dismiss Completed.
- A chronological **Activity** timeline for asks, answers, relays, delegation,
  failures, restarts, workspace changes, and human interventions.
- A small **Core health** section for the local broker, tmux server, socket,
  supported CLI discovery, and protocol versions. Low-level logs remain behind
  a disclosure instead of dominating the normal status view.

Status Center must not imitate certainty it does not have. Context-window use,
token cost, quota, compaction distance, or plan limits appear only when the
vendor exposes authoritative structured values. Parley may show its own process
memory and handoff counts in diagnostics, but it must not derive impressive-
looking model gauges from terminal text or estimates.

The visual treatment should borrow the useful hierarchy from operational
dashboards—strong status banner, quiet grouped cards, compact progress states,
and an event timeline—while keeping Parley's native macOS restraint and avoiding
a permanent application-style navigation sidebar.

### Honest state only

Do not infer “thinking”, “idle”, or “blocked” from a quiet screen. Prefer
explicit protocol events and official vendor hooks. Where Parley knows only
that a process is alive, the UI must say exactly that.

### Local handoff history

Persist a small append-only record of cross-vendor events:

- source and target pane identities and vendors;
- workspace names;
- question, answer, or delegated instruction;
- timestamps, outcome, and interruption reason.

This is collaboration history, not automatic terminal transcription. It stays
local, can be deleted per workspace, and never captures unrelated pane output.

**Exit gate:** a person can explain who is doing what, who is waiting for whom,
and what failed without reading every terminal pane.

## Milestone 3 — Supervised multi-vendor work

Extend the proven one-to-one consultation into a small set of composable
coordination primitives. The lead agent remains responsible for reasoning and
decisions; Parley transports work and reports state.

### Protocol v2

- `parley ask <target>` — retain the current blocking one-to-one consultation.
- `parley ask-many <targets...>` — ask several explicit vendors independently
  and return a labelled bundle only after all finish or time out. Respondents
  must not see one another's answers.
- `parley delegate <target>` — tracked asynchronous work with a required
  `parley done` or `parley fail` result.
- `parley status` — machine-readable state for work initiated by the caller.
- `parley wait` — wait for one delegated item without scraping terminal output.
- `parley cancel` — cancel the tracking relationship and, only with explicit
  human authority, offer to interrupt the target CLI.

### Lead-agent experience

- Allow a pane to be marked as the workspace lead for display and routing
  convenience, never as a source of extra filesystem authority.
- Natural-language instructions such as “review the plan with Codex, adopt good
  additions, then delegate implementation” should work using the shared
  protocol without a vendor-specific skill maintained by the user.
- Provide a few editable handoff recipes: plan review, implementation review,
  adversarial bug hunt, and compare recommendations.
- Show every automatically submitted prompt in activity history with sender
  attribution and an immediate Stop control.

### Safety boundary

- Automatic delivery targets agent panes only, never shells.
- Each workspace exposes a visible automation policy: off, Ask/Answer only, or
  Ask plus tracked delegation.
- No agent receives raw tmux control, pane credentials belonging to another
  agent, or permission to create and destroy workspaces.
- Message size limits, sender attribution, exact target resolution, and
  cross-vendor enforcement remain mandatory.
- Fan-out always names its recipients; there is no implicit broadcast to every
  pane.

**Exit gate:** one instruction to a lead agent can produce the demonstrated
review → evaluate → implement sequence across vendors, while the UI shows the
whole chain and the person performs no copy, paste, or Enter presses.

## Milestone 4 — Workspace as the daily driver

Workspaces should preserve context and make returning to several projects
effortless without becoming task boards.

### Durable workspace restoration

- Persist workspace names, folders, pane kinds, pane names, layout, and ratios
  outside tmux so they survive a Mac restart.
- Restore shells automatically; restore agent panes as stopped placeholders
  requiring an explicit Start, so reopening Parley never spends subscription
  quota unexpectedly.
- Preserve recent and favourite folders, tab ordering, and the last selected
  workspace.
- Make duplicate workspace names impossible or visibly qualify them.

### Project context

- Show branch, dirty state, and pane folder without running unbounded git work.
- Add “Ask another vendor to review these changes” using an explicit diff
  preview and the normal attributed Ask path.
- Add “Review this plan/file with…” without copying its contents manually.
- Allow an occasional pane folder override while retaining the workspace's
  default folder for new panes.
- Add a command palette for workspace, pane, Ask target, and activity lookup.

### Native interaction polish

- Reorder workspace tabs and panes.
- Complete keyboard navigation and VoiceOver labels.
- Improve narrow-window behaviour and long-name truncation.
- Provide clear empty, exited, disconnected, and protocol-stale states.
- Remove redundant tmux chrome once the native controls cover it reliably.

Optional git worktrees belong here only if real use shows multiple write agents
colliding. They are not required for cross-vendor consultation.

**Exit gate:** after a Mac restart, a person can restore a project's layout,
choose which agents to resume, and continue work without reconstructing the
team or its folder routing.

## Milestone 5 — Ship a dependable macOS beta

- Produce a proper app bundle containing the Swift executable, terminal
  dependency, local coordination core, relay shim, and tmux integration.
- Sign, harden, notarize, package, install, upgrade, and uninstall cleanly.
- Offer optional launch-at-login for the local core, independently of opening
  the window.
- Add first-run detection for tmux and supported CLIs, plus authentication and
  protocol health checks that do not spend model quota.
- Provide a local diagnostics export with secrets and prompt bodies excluded by
  default.
- Run long terminal-output, repeated workspace switching, UI reattachment, and
  multi-agent soak tests. Memory must plateau rather than grow with output
  history or redraw count.
- Document recovery from a damaged socket, missing CLI, stale protocol, dead
  pane, and interrupted consultation in the UI itself.

**Exit gate:** install Parley on a clean Apple Silicon Mac, connect existing CLI
subscriptions, complete a supervised cross-vendor workflow, restart the app and
Mac, and repeat without using the repository or a development command.

## Milestone 6 — Add vendors without diluting the product

Once the core is reliable and shipped:

- Extract a small adapter contract for launch arguments, protocol injection,
  submit behaviour, trust detection, and optional official status hooks.
- Evaluate CAP and other CLI-agent protocols as adapter inputs, not as reasons
  to replace the real terminal sessions.
- Add another CLI only when it supports local authenticated use and passes the
  full conformance harness.
- Prefer vendors that add genuine model diversity. Supporting many wrappers
  around the same provider is not the goal.

## Explicit non-goals

- No API-key vault, model router, or direct cloud inference.
- No generic Kanban board, issue tracker, DAG designer, or autonomous project
  manager.
- No invisible background model calls or hidden agents.
- No replacement editor, source-control client, or deployment platform.
- No cloud sync or telemetry.
- No scraping an entire terminal transcript and pretending it is a structured
  answer.
- No forced worktree-per-agent workflow.

Parley may expose enough state for a lead agent to supervise other vendors, but
it should not become the agent that plans their work. That distinction keeps
the product small and lets each CLI improve without Parley competing with it.

## Immediate build order

The next implementation sequence is deliberately narrow:

1. Extract the relay broker from `AppModel` into a persistent local core.
2. Define and persist the handoff state machine and event record.
3. Make the existing UI attach to that core and render a minimal activity strip.
4. Prove Ask/Answer across UI close and reopen with unchanged pane process IDs.
5. Add cancel, retry, dead-pane handling, and notifications.
6. Introduce tracked `delegate` / `done` only after one-to-one recovery is solid.
7. Add `ask-many` with independent answers and explicit target lists.
8. Persist workspace layouts outside tmux.
9. Add diff and plan review shortcuts through the same transport.
10. Package and test the complete native application on a clean Mac.

Anything not required by those ten steps waits.

## Success measures

- A supported vendor pair can repeat 100 Ask/Answer exchanges without manual
  submission, wrong-pane delivery, or a stranded wait.
- Closing and reopening the UI changes no agent pane process ID and interrupts
  no active handoff.
- Every failed handoff reaches a terminal state with a useful reason.
- Cross-workspace bare and qualified routing never guesses under ambiguity.
- A person can identify all waiting and failed collaboration from one screen.
- A lead-agent review → evaluate → delegate workflow needs one initial human
  instruction and zero manual transfers.
- Terminal and broker memory plateau under sustained output and repeated
  handoffs.
- No model API key, prompt, answer, or activity record leaves the Mac.
