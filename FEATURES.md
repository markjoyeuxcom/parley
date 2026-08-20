# Features under consideration

Proposals, triaged. Eight came from an AI review of the codebase on 20 August
2026; the ranking and the reasons for declining are mine, and several disagree
with that review.

## The test

> Could Claude Code or Codex do this on its own?
> If yes, do not build it. If no — because it is cross-vendor, terminal-aware,
> or workbench-level — it belongs in Parley.

A second test that ranks what survives the first:

> Does it shorten the path between two CLIs in the same window?

That is what Parley is for. The grid and the relay are the parts that earn
their keep; the rest of the codebase is larger than the product.

---

## Building

### 1. Cross-vendor diff review

Take the uncommitted diff from a pane's folder and relay it to a counterpart
seat for review, attributed and unsent.

    @claude produced the following uncommitted changes on branch feat/auth:
    <unified diff>
    Please review this for correctness, edge-case regressions, and missing tests.

The strongest of the eight, and the only one worth starting immediately: it is
the workflow Mark described wanting when asked what the app was for — copy
Claude's output into Codex, paste the answer back — turned into one action.
Every part exists already: pane identity, folder paths, `capture()` for git, the
relay for delivery. Single-vendor tools cannot do it without API keys, which
this app does not have and will not add.

## Next, if that lands well

### 2. `parley room append` and `parley broadcast`

Extend the PATH shim so a script inside a pane can put text into a room, or into
every agent pane at once.

    npm test 2>&1 | parley room append
    parley broadcast "rebuild done, port 3000"

Cheap, because the shim and the loopback relay are built and proven. A test
watcher piping failures into a room is a genuinely good workflow.

**Caution:** broadcast is one pane reaching every other, which is a
prompt-injection amplifier by design. The paste-never-submit rule is what holds
it, and that rule was found bypassable on 20 August — a payload could splice a
closing paste marker out of the sanitiser's own leftovers. Fixed, but the path
deserves adversarial testing before it fans out to N panes instead of one.

### 3. Template variables in skills — `{{selection}}`, `{{file}}`, `{{branch}}`

Skills are static strings. Interpolating the terminal selection, the active
file, or the current branch is cheap and immediately useful.

Build only those three. The Finder drag-and-drop half of the original proposal
is a separate, larger feature and should not ride along.

## Deferred

### Git worktree splitting

Spawn a pane in an isolated worktree so agents do not contend over one tree.
Real problem, but it solves contention between multiple *write-capable* agents,
and that is not how this app is used — most seats are advisory. Revisit if that
changes. The lifecycle (creation, drift, teardown, merge) is most of the work.

### Room transcript branching

Fork a room from turn N to explore an alternative. Clever, cheap in SQLite, and
speculative: rooms are barely exercised yet. Build it when somebody wants it
twice.

### Export presets — ADR, PR review, clean markdown

The domain already holds structured verdicts, scores and dissent, so this is
templating rather than new abstractions. Nice to have, no urgency.

## Declined

### Voice dictation

A native dependency — whisper.cpp or a Swift speech addon — for a bottleneck
that does not exist. The constraint was moving text *between* panes, not typing
it. macOS already has system-wide dictation that works in any text field,
including Parley's. Building it in-app duplicates the operating system.

### A quota dashboard

Proposed as auth status plus quota and model tier. The auth half is buildable
and useful. The quota half asks for data the app no longer has: all three health
probes were changed on 20 August to check authentication rather than run a turn,
precisely because probing cost money. Codex only reveals its limit when a turn
actually runs. Building this means re-introducing paid probes.

An auth and model dashboard without quota is worth doing. Say what it is.

---

## Non-goals

These are settled and should not be reopened without a reason that names what
changed.

| Proposal | Why not |
|---|---|
| API keys, direct cloud endpoints | Parley drives authenticated local CLIs only. No key ever enters this app. |
| Autonomous background orchestration | Loops and foremen were deliberately retired in favour of human-directed steering. |
| Cloud sync, telemetry | Everything stays in local SQLite. Nothing leaves the machine. |
| Auto-submitting agent relays | An agent that could press Enter in another agent's session is a prompt-injection channel with a command runner on the far end. |
