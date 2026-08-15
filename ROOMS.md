# Rooms — the Grid grows an agent management system

The arc that makes the Grid the whole product: multi-agent conversation as a
first-class pane, and the governed engine retired behind it.

**Status.** Planned, nothing landed. Written 2026-08-15 against schema v32.
Read `AGENTS.md` first — some of its invariants survive this arc and some are
deliberately retired, and the difference is stated in "What the invariants
become" below.

---

## Why

The governed surfaces were built on a premise that held: an agent's claim about
its own work is worthless, so deny it the ability to certify itself. That
premise is still true. What did not hold is the shape it took for *discussion*.

**Free flow was designed out at one function.** `debateStages(maxTurns)` in
`shared/protocol.ts` builds a fixed alternating schedule — Position, Challenge,
Defence, Challenge 2, …, Convergence — and every turn's prompt demands
structured output against `VERDICT_CONTRACT`. A human interjection is queued and
delivered *at a turn boundary*, never mid-thought. That is not a conversation
with two advisors; it is a form with two respondents, and no amount of work
downstream of that function could have given the feeling back.

The engine underneath is not the problem. `SessionRunner` is an interpreter: it
owns turn mechanics, resume threading and delivery, and reads the protocol as a
value. Remove the schedule and the verdict contract and what remains is a room.

**The free flow comes from deleting the schedule, not from deleting the engine.**
That sentence is the whole arc.

### Why not simply do it in the Grid as it stands

Because the Grid's channel to an agent is write-only. `PtyManager.submit()` types
keystrokes into an interactive TUI — it even flattens newlines to spaces, because
the CLIs' own multi-line paste handling is inconsistent between versions. That is
how Skills and Broadcast work, and it is the right mechanism for them: the agent
keeps its context and the user sees exactly what was sent.

The return path is raw ANSI bytes to xterm.js. So a pane today cannot report when
its agent finished a turn, cannot yield what the agent said, and cannot route it
anywhere. Building agent-to-agent conversation on PTY scrape means quiescence
timers and prompt-shape heuristics against three redrawing TUIs, breaking
silently on every CLI release. **Rejected**: the failure mode is invisible, and
an invisible failure in the transport means facts are lost without anyone
learning they were lost.

The adapters in `src/main/agents/` already solve this — `claude -p
--output-format stream-json`, `codex exec --json`, `agy` — giving clean text,
resume ids, usage, streaming deltas and abort. They are ~1,100 lines, already
live-tested against the real CLIs, and the quirks documented in AGENTS.md's
"Hard-won CLI details" cost real time to find. They survive this arc untouched.

---

## What a room is

**A room is a pane.** `PaneKind` gains `room`, and a room sits in the grid tree
exactly like a shell — splittable, resizable, saved in layouts, side by side with
a `claude` TUI and a `git diff` shell.

Not one agent per pane. A conversation needs one reading surface; scattering it
across panes gives you four monologues and no thread. A room holds N seats over
one transcript: transcript, seat roster, composer.

**You are seat 0.** This is the simplification the free-flow model buys. A
scheduled debate needs a side-channel for the human — hence `interjections`,
`interjection_deliveries`, per-seat delivery tracking, and the rule that an `all`
interjection must reach each seat exactly once. In a room, a human message is
just a turn with a human seat. Two tables and their entire class of edge cases
disappear rather than being ported.

**Seats are staffed from profiles.** `agent_profiles` (v32 — name UNIQUE
NOCASE, vendor, model, effort, persona) is already exactly the roster this
needs, and is currently unused by the Grid. It is not a new concept; it is a
concept that has been waiting for a surface.

---

## Decisions taken

Three, settled 2026-08-15. Each names the trade it accepts.

**1. Agent seats are read-only, with a per-seat write opt-in.**
Dispatch goes through the existing `assertCapability(capability, approved)` with
`approved` coming from the seat's own flag. The trade, stated so it is never
rediscovered: **a per-seat toggle is standing authorisation, not single-use.** A
write seat stays write until it is flipped back. That is the correct shape for a
workbench a human is driving, and it is a materially weaker guarantee than the
pipeline's recorded, single-use, spent-on-start approval. The room header must
say which seats can write, always, without being asked.

**2. Agent transcripts persist; PTY panes stay scrollback-only.**
Rooms are `sessions` + `turns` rows. Terminal panes keep the existing Grid rule —
nothing persists but scrollback and the layout — because serialising a TUI is a
different project with a worse payoff.

**3. The merged verdict survives as an optional room action.**
`verdict.ts` (433 self-contained lines) stays, invoked on demand rather than as a
protocol's closing stage. The reason is the one thing genuinely lost in the move
to free flow: in an unscheduled room, models converge fast and whoever speaks
last wins — you get agreement, which is not information. Independent scoring,
disagreement *lowering* recorded confidence, and dissent preserved verbatim are
worth keeping available for the decisions where that matters. Nothing forces a
room to end in one.

---

## What survives, what goes

### Tables — 9 of 38

Surviving: `meta`, `grid_layouts`, `skills`, `agent_profiles`, `sessions`,
`turns`, `agent_threads`, `verdicts`, `search_index`.

`agent_threads` (PK `session_id, seat`) is reused verbatim — it is what keeps
token cost linear in turn count, and a room needs exactly that.

`search_index` arrives nearly free: its triggers already cover `sessions` and
`turns`, so full-text search across every agent conversation lands with m4
rather than as its own project. See "Schema notes" for the one trigger that
needs attention.

Going: everything else — the ledger tables, plans, milestones, approvals, loops,
backlog, learnings, foreman proposals, worktrees, envelopes, acceptances,
run\_events, remote targets and runs, workspaces, journeys, self-updates,
holds acks and notifications, repo activity/archives/containers, findings,
interjections and their deliveries.

### Modules

| Survives | Retired |
| --- | --- |
| `pty/`, `preview/` (optional) | `orchestrator/{pipeline,execution,evidence}` |
| `agents/` in full | `orchestrator/{backlog,foreman,holds,inflight}` |
| `util/{environment,spawn,ids,repoPath}` | `orchestrator/{loop,envelope,liveness,reporter}` |
| `store/{db,search}`, slimmed `repo.ts` | `orchestrator/{worktrees,workspace,templates}` |
| `orchestrator/session.ts` → room runner | `orchestrator/{selfupdate,containers,gate}` |
| `orchestrator/verdict.ts` | `remote/` and `src/remote/` entirely |
| slimmed `manager.ts`, `ipc/` | `src/cli/` |
| `GridSurface`, `TerminalPane`, `Titlebar`, `CommandPalette`, `ui.tsx`, `Notices`, `AgentPicker`, `VerdictPanel` | `ParleySurface`, `LoopsSurface`, `BacklogSurface`, `PlanPanel`, `HoldsPanel`, `InFlightPanel`, `JourneyPanel`, `FindingsLedgerPanel`, `PlanProgress`, `PreviewCard`, `RemoteTargets`, `RunActivity`, `RunRoom` |

`util/environment.ts` is easy to overlook and load-bearing: it reads the login
shell's PATH, without which a GUI-launched macOS app cannot see Homebrew, `npm
-g`, bun or mise installs, and every CLI reports missing. It survives regardless
of how much else goes.

Rough scale: ~75k lines today; the Grid plus the shell it needs is ~8–10k. This
arc deletes on the order of two thirds of the codebase, including the remote arc,
which had a real-host acceptance test behind it. **That is a one-way door**, which
is why deletion is m6 and not m1.

### What the invariants become

**`AGENTS.md` is authoritative** — each of its ten invariants now carries a
status tag, and that list is the one to keep current. Summarised here only so
this plan can be read on its own:

- **Permanent** (1, 2, 8, 10): subscription CLIs only; no `--dangerously-*`
  ever; everything stays local; macOS-native restraint.
- **Permanent, narrowed** (3): read-only is the default — the default for an
  agent seat rather than an absolute for a session.
- **Permanent as a default, not a rule** (5): no agent certifies its own work —
  a room may seat two of the same vendor if a human asks; the roster makes
  cross-vendor obvious rather than enforced.
- **Permanent wherever a verdict exists** (9): dissent is preserved — after m6
  that means inside the optional converge action, which is the only place a
  verdict still exists.
- **Retired with the engine** (4, 6): recorded single-use approval, replaced by
  the standing per-seat toggle; observed exit conditions, which a room has none
  of — it ends when a human stops it or its budget does.
- **Retired in form, kept in substance** (7): the loop's caps go, the reason
  does not — m3's per-room token budget is enforced before dispatch and unseen
  by the seats, exactly as caps were.

The critical reading, spelled out in AGENTS.md and repeated because it is the
one that gets misread: **a retirement takes effect at m6, not now.** Every
invariant binds the code it governs for as long as that code exists. Working
m2 alongside a live pipeline means the pipeline's guarantees are still
absolute.

---

## Milestones

One commit each, on `main`, in the house convention: `Rooms mN: <lowercase
sentence>`.

### m1 — the roster

A Grid-facing surface over `agent_profiles`: list, add, edit, forget. The IPC
commands (`profile.list`, `profile.add`, `profile.forget`) already exist and are
schema-validated; this is UI plus the seat vocabulary.

Add `agy` to `PaneKind` while here. The engine has supported three vendors since
the agy adapter landed and the Grid has only ever offered two, which is an
inconsistency with no defence.

*Done when*: a profile can be created, edited and deleted from the Grid, and a
`agy` pane opens an interactive session.

### m2 — one seat, headless

A room pane with a single agent seat. `registry.get(vendor).run()` at
`capability: 'read'`, streaming deltas into a markdown transcript, `resumeId`
threaded per seat. No routing, no persistence, no second seat.

This is the milestone that proves the pivot. **If a headless seat does not feel
as alive as a TUI pane, that must surface at m2, not at m5** — the TUI gives
tool-call visibility and permission prompts that a rendered transcript does not,
and it is an open question whether the streaming deltas plus an activity line
close that gap. Budget time here for the transcript to feel right rather than
merely work.

*Done when*: a one-seat room holds a multi-turn conversation with visible
streaming, and cost stays flat per turn (proving resume threading).

### m3 — routing, and a budget

Addressing between seats: `@name` to one, `all` to every seat, and round-robin
auto-advance with a hard stop. Broadcast's "running agent panes are the
audience" concept generalises into the router.

**The token budget lands here, not later.** A PTY pane burns quota only when a
human types; four headless seats on auto-advance are a furnace with no TUI to
watch and no natural pause. A per-room turn budget and a visible spend line,
built on the existing `Usage` shape and `shared/usage.ts`. This is the useful
half of the retired caps invariant, and it is the difference between leaving a
room running and not daring to.

*Done when*: three seats hold a conversation without human input, stop at the
budget, and report spend honestly.

### m4 — persistence and search

Rooms become `sessions` + `turns` rows; reopening a saved layout restores the
transcript and leaves seats as **one-click placeholders**. That last part is the
existing saved-layout rule and it must hold for seats too: no CLI session begins
against a subscription without being asked for.

Search over room transcripts arrives with the triggers already in place.

*Done when*: a room survives a restart with its transcript intact and no seat
running, and its text is findable in search.

### m5 — converge, and the write toggle

`verdict.ts` as an optional room action, rendering through the surviving
`VerdictPanel`. Per-seat write opt-in, gated by `assertCapability`, with the
room header stating which seats can write.

*Done when*: a room can be asked to converge and produces a scored verdict with
dissent preserved; a write-enabled seat can edit a file and a read-only one is
refused at dispatch.

### m6 — the deletion pass

Everything in the "Retired" column, the 29 dropped tables, and the dead IPC
commands. Last, deliberately: the app stays working the whole way, and the
decision is reversible at any point before this.

*Done when*: `npm run verify` is green, the IPC command table contains nothing
unreachable, and no surviving module imports a deleted one.

**m6 also lands the documentation.** The status tags on AGENTS.md's invariants
describe a future until this milestone and describe the present after it — so
m6 rewrites them as plain statements, drops the "Status under the Rooms arc"
preamble, retires this file the way HANDOFF.md was retired (kept as the record
of why, not as a plan), and corrects AGENTS.md's opening line, which still
promises three surfaces over a governed engine.

---

## Schema notes

The house convention holds: schema numbers are taken as max+1 **at land time**,
never assumed; existing `if (current < N)` guard blocks are never edited; each
new block is additive and tolerant of a fresh database where SCHEMA already
created the column.

Four specific things this arc must handle:

**`SessionKind` gains `'room'`.** `debate` and `review` remain legal until m6 so
old sessions still read.

**`turns.stage` becomes vestigial.** It is a protocol artifact with no meaning in
a room — but the search trigger builds each turn's index title as `vendor || ' ·
' || stage`, so a room's turns need something sensible written there (the seat's
profile name is the obvious candidate) or every room turn indexes with a trailing
separator and no title.

**`StartSessionReq.participants` is `min(2).max(4)`.** The cap's stated reason is
that the exchange schedule is two-seat, so further chairs are assessors. With no
schedule that rationale dies, and the cap becomes a cost decision rather than a
protocol one. The floor should drop to 1 (a room with you and one agent is
legitimate, and a room should be able to open empty).

**`verdicts.session_id` is a PRIMARY KEY** — one verdict per session. A room may
reasonably be asked to converge more than once over its life. Either accept
last-write-wins or give the table its own id at m5; decide there, not by
accident.

---

## Honest limits

- **Nothing here has been built.** This is a plan, and the m2 question — whether
  a rendered transcript feels as alive as a TUI — is genuinely open. It is
  sequenced early for that reason.
- **The write model is weaker than what it replaces**, on purpose, and is stated
  under Decisions rather than buried.
- **The deletion is irreversible in practice.** The remote arc in particular
  cost a long series and carries an acceptance test against a real host; it will
  not come back cheaply if the pivot is regretted.
- **Mock mode must keep working.** `PARLEY_MOCK=1` and its hazard-striped banner
  are how this app is developed without spending quota, and the mock adapters
  answer the same `run()` interface rooms will use — so rooms inherit it, but no
  milestone here has verified that.
- **The dev/packaged record split stays.** `parley-dev/` vs `parley/` and the
  downgrade guard are unaffected by this arc and must not be simplified away
  alongside it.
