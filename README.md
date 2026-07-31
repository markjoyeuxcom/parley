# Parley

A local-first macOS workbench for governed agent work. It drives **Claude Code**
and **Codex** through their own CLIs, so everything runs against the
subscriptions you already pay for — Parley never asks for an API key and has no
API-key code path.

**Development status.** When run from its own checkout, Parley updates itself through its own pipeline — plan, worktree landing, an `npm run verify` plus `npm run build` gate, then an offered relaunch — as described in [Self-update (dev mode)](#self-update-dev-mode).

## Choosing a surface

| | Use it when |
| --- | --- |
| **Grid** | You're driving, and you'd rather not be interrupted by structure. |
| **Debate** | The decision is expensive to reverse and disagreement would be informative. |
| **Codebase review** | You need findings you can act on without re-verifying each one. |
| **Loop** | "Done" is machine-checkable and the work converges. |
| **Audited execution** | A change matters enough to want gates, tests and an independent reviewer between the agent and your repository. |
| **Repos** | You want the repository — its backlog, its plans across every session, its foreman — answering for itself in one place. |

Each section below says when the surface earns its cost — and when it doesn't.

## Worked example: a codebase you've just inherited

The obvious move is a codebase review. It is the right tool, but not the first
step — and the reason generalises.

**A review's quality is bounded by its brief.** "Review this repository" over an
unfamiliar codebase gives you breadth without depth: the agents sample, you get
thirty findings, and you cannot judge which matter because you do not yet know
which paths are hot or which oddities are deliberate. Scoping is what makes a
review good, and scoping needs understanding you do not have on day one.

**1. Orient, in the Grid.** Open the repo in two panes — Claude and Codex — and
drag the **Orient me** skill onto each. Running it in both gives you a cheap
cross-check without the full four-turn protocol. Read both and note where they
*disagree*: that is a reliable signal for where the codebase is genuinely
confusing rather than merely unfamiliar. Then poke — ask follow-ups, open the
files that sounded odd, run the suite and see what it actually covers. Save the
layout; you will be back.

This is minutes of conversation, and it is exactly what the Grid is for: you
cannot state a precise question yet, so don't use a surface that demands one.

**2. Then run reviews, scoped.** Two or three narrow briefs beat one broad one:

- *Audit error handling and partial-failure recovery in the sync layer.*
- *Audit the auth path: where untrusted input enters, and what validates it.*
- *Audit what the test suite actually proves, and what it only appears to.*

That last one is worth running on any inherited codebase. Tautological tests are
common and invisible from a green suite.

**3. Debate only once there's a fork.** On day one you have no decision to make.
Debate becomes useful when a review surfaces one — *incremental refactor or
replace this layer* — and by then you can state it falsifiably.

**The exception.** If the real question is not "how do I work in this?" but *"how
bad is this, and should we invest?"*, run a broad review immediately and accept
the shallowness. The five-dimension score and the exportable report are a
defensible artifact for a conversation with whoever handed you the repo — a
different job from making you competent in it.

---

## Grid

Up to sixteen live terminals in a splittable, resizable layout. A pane can be a
shell, or a real interactive `claude` or `codex` session — the actual CLI with
its own prompts and TUI, not a re-hosted imitation.

Panes are **multi-folder**. Each keeps the folder it started in, a split inherits
its neighbour's, and the toolbar only decides where the *next* pane opens. Working
a change across two repositories at once is the normal case, not an edge case.

**Skills** are reusable prompt packs on the rail along the bottom. Drag one onto
an agent pane and it is typed into that live session, so it lands with all the
context that session already has.

**Saved layouts** keep an arrangement — pane kinds, split tree, each pane's
folder. Reopening restores the shells immediately and leaves Claude and Codex
panes as one-click placeholders, so no CLI session begins against your
subscription without you asking.

`⌘D` splits right · `⌘⇧D` splits down · `⌘W` closes · `⌘]` cycles

### When to use it

- **You can't state the question yet.** The other surfaces demand precision
  upfront — a matter, a brief, a goal with an exit condition. When you're poking
  at unfamiliar code or following a hunch, this is where you find out what you're
  actually asking.
- **The loop is tighter than a turn.** A pane answers in seconds; governed turns
  take minutes. If you're genuinely conversing, structure is pure overhead.
- **You want the CLI itself** — `/model`, plan mode, its own permission prompts.
  The governed surfaces deliberately constrain those CLIs; the Grid deliberately
  doesn't.
- **Something governed is running.** While a milestone grinds for half an hour,
  this is where you `git diff` and run the suite yourself.

### When not to

Not when you'll need a record — nothing here persists but scrollback and the
layout. Not when you want the cross-check; a pane is one agent marking its own
homework.

And **the Grid is ungoverned**. A pane has the CLI's own permission prompts and
none of Parley's — no single-use approval, no deterministic verification, no
independent review. That's the right trade for small edits you're watching, and
the wrong one for a change you'll ship.

### Orientation and lifecycle

Every pane header carries its identity: branch, a `±` when the checkout is
dirty, `↑↓` drift from upstream — refreshed when the pane gains focus, never
on a timer. When a pane's folder is one of Parley's own plan worktrees, a
chip says **landed** or **unlanded** and opens the plan; it deliberately
never says "safe to remove". Output landing in an unfocused pane marks it
with a dot until you look. These signals are Grid-local by rule: nothing
here enters the holds queue, whose authority comes from the durable record.

The pane menu separates the slot from its process: **Stop** kills the
process and keeps the corpse with its exit code, **Restart**/**Reopen**
relaunch into the same position, **Replace** swaps the kind, **Rename**
gives the slot a name that survives restarts and rides saved layouts,
**Duplicate** splits with the same folder. **Resume a session…** opens the
CLI's *own* picker (`claude --resume`, `codex resume`) — Parley's governed
resume ids never reach a pane. ⌘⏎ maximizes (an overlay — siblings stay
mounted, scrollback survives), ⌘[ and ⌘] cycle, ⌘F finds in the focused
pane's scrollback, and the menu can save a full transcript.

Two bridges connect the Grid to the governed side. Every worktree plan
offers **Open worktree in Grid** — a shell in the plan's own checkout, with
the header saying landed or not. And **Review this in Parley…** promotes a
pane (with any selected terminal text as the brief's starting matter) into
a real review session. **Broadcast** types one prompt into every running
agent pane, exactly as if you had typed it in each.

---

## Debate

Put a decision to two CLIs from **different model families**. One stakes a
position, the other attacks the load-bearing assumption, they refine under
pressure, then converge.

Two things make this different from asking one model twice:

**Neither side writes the verdict.** After the exchange, both sides record their
own verdict independently and concurrently. Parley merges them — and
**disagreement lowers the recorded confidence**. Two advisors who each claim 90%
certainty while scoring the option ten points apart have not produced a confident
answer, and the report says so.

**Dissent is preserved verbatim.** The losing side's objection is the most
perishable output of an adversarial session, so it is stored and shown in full,
never summarised away.

You can interject mid-session: address both sides, or **whisper** to one. The
other side never learns it happened, which is how you test whether an agent will
hold a position under private pressure.

The session list is newest-first, which answers "what was I just doing" and
cannot answer "what have I done about X". **Group sessions** in the sidebar
header regroups it by project or by repository without sorting: groups appear
in the order their first session does, so the work you were just in stays at
the top either way. Grouping and folds are view preference — they reset with
the window. The **Project** field suggests the projects already in use, but
stays free text, so a new one costs nothing.

### When to use it

- **You can't cheaply just try it.** If you can prototype both branches in an
  afternoon, do that — it produces evidence, not opinion. Debate is for choices
  you discover are wrong six months later.
- **Competent engineers would actually differ.** If the answer is findable in the
  docs, you'll get two agents agreeing at 90% and learn nothing — and that
  confidence will read as validation.
- **You'll be asked to justify it.** The record, with the dissent, is the point.
- **You can state it falsifiably.** The protocol asks for *"the one condition
  under which you would be wrong"*. Vague matters produce vague turns.

### When not to

Not for questions with ground truth — that's a review. Not for seeking
validation; you'll get it. Not for small reversible choices.

**A low confidence score is a success.** It tells you the decision is genuinely
contested and shouldn't be treated as settled — which is exactly what you cannot
learn by asking one model twice.

---

## Codebase review

One agent maps the architecture, the other audits it independently, then they
cross-examine each other's findings. A finding only reaches `confirmed` if the
*other* agent corroborated it against the code, and a confirmed claim with no
file-and-line evidence is downgraded automatically.

Three structural things make it worth four turns instead of one:

- **Findings are cross-examined.** Plausible-sounding false positives die against
  the actual files rather than in your head.
- **Evidence is enforced by the harness, not requested.** An agent asserting a bug
  it cannot point at is not taken on trust.
- **Dismissed findings are kept.** Knowing something was investigated and cleared
  is often worth as much as the finding — it's the difference between "no issue
  here" and "nobody looked".

### When to use it

- **You're about to trust code you didn't write** — inheriting a repo, evaluating
  a dependency, due diligence.
- **Before building on a foundation**, not after writing a diff. The pipeline's
  per-milestone review already covers the latter.
- **A one-shot review gave you thirty findings you don't believe.** This is the
  failure mode the mode exists for.
- **A false negative would be expensive** — security, money paths, data loss.

### When not to

Not for your own uncommitted diff. Not to answer one specific question — a Grid
pane is seconds, not half an hour. Not for exploration: the Grid skills
(*Security pass*, *Find the bug*, *Orient me*) are one agent, fast, no
cross-examination. **Skills for exploration, review for adjudication.**

**Scope it, or it goes shallow.** "Audit error handling in the sync layer"
produces findings worth having; "review this repository" produces breadth without
depth. It is also read-only — nothing gets fixed — and has no memory of previous
reviews.

---

## Audited execution

A verdict can become work, through a pipeline with the roles deliberately split:

```
plan (read-only)
  → audited by the other vendor (read-only)
    → the planner answers that audit, and corrects the plan
      → your approval, single-use
        → execute one milestone (write)
          → deterministic tests, run by Parley itself
            → the diff reviewed by the vendor that did not write it
              → rejection handed back to the executor, up to twice
```

**The planner answers its own audit.** Without that stage the auditor's findings
reach you but never the plan, and what gets executed is the original draft with an
unread critique attached. Every finding gets a disposition; both halves of the
exchange are kept.

**Agents may ask, once.** If a brief has a genuine fork, the plan stops on a
question rather than guessing, and your answer resumes it — the planner still
holding its own draft. An agent that guesses produces a confident plan resting on
an assumption nobody agreed to, invisible by the time anyone reviews it.

**A rejection goes back to the executor**, inside the same run, with both sides
resumed so it receives a critique rather than a restatement. Bounded to two
rounds; after that the note says a person is needed.

Approval is per-milestone, recorded, and **spent the moment the run starts** — so
re-running asks again. A milestone completes only if the tests are green *and*
the independent reviewer passes it.

**Where the work lands is a choice, made at plan creation.** In the default
mode nothing is ever committed: milestones write into your checkout and the
changes are left in the working tree for you. A plan can instead run with
**worktree isolation**: every milestone executes in an isolated git worktree on
a per-plan branch, Parley commits each passing milestone there, and your
checkout is untouched until you **land** the branch — fast-forward only, behind
its own recorded single-use approval, refused by git itself if your checkout
moved, and smoke-verified in the origin after it lands. Nothing reaches your
checkout without you. Isolation is what lets Parley work on a repository that
is in use — including, eventually, its own.

**Interruptions are cheap.** A crashed or stopped milestone keeps its run
state — the remediation round, the reviewer's critique, both agents' resumable
sessions, the exact baseline — and can be **resumed** with a fresh approval:
the executor continues from a critique instead of re-executing, and finished
work is verified rather than redone. A running milestone has a stop button
(the run state survives a stop too), and a run that goes silent surfaces as a
stalled hold with a read-only cross-vendor inspection attached. Nothing is
ever aborted automatically.

**Adopt & verify** handles work that already exists — usually from an interrupted
run. It skips execution but keeps both checks that establish anything, and records
the milestone as *adopted* so the trail never implies Parley authored code it
merely inspected. Honestly, that's two of the three guarantees: you get
verification and independent review, but not "a supervised agent produced exactly
this diff from this instruction".

Five post-verdict workflows: implementation, validation, remediation, migration,
research.

---

## Loops

Autonomous runs that stop for reasons you can check.

- **Caps are enforced by Parley before each iteration** — iterations, wall-clock,
  and reported spend. An agent cannot see them or talk past them. Hitting one is
  reported as `exhausted`, never as success.
- **The exit condition is never self-reported.** Either Parley runs a real command
  and reads its exit code, or the *other vendor's* model inspects the repository.
- A kill switch aborts the in-flight CLI immediately.

### When to use it

- **There's a real exit command** — `go test ./...` exits 0, the type-checker is
  clean, the linter passes.
- **The work converges.** Getting a suite green, updating forty call sites,
  clearing a lint backlog. Design work does the opposite: iterating on
  architecture wanders.
- **The unit is too small to gate.** Forty mechanical edits shouldn't mean forty
  approval dialogs.
- **You want to walk away.** The caps are what make that safe.

### When not to, and one real limitation

If you'd want to see each diff, use milestones. If you can't state a completion
test, the work isn't loop-shaped. Exploration has no exit condition.

**A write-capable loop is a weaker guarantee than a milestone.** The pipeline
requires green tests *and* an independent cross-vendor review of the diff; a loop
requires only its exit condition. An agent that can edit the repository and whose
exit is `go test ./...` can in principle reach green by weakening a test — Parley
reads the exit code honestly, but the exit code is only as trustworthy as the
suite behind it. Prefer read-only loops; when writing, pick a check the worker has
little room to subvert; for changes that matter, use the pipeline.

Two smaller things: **exhausted is not success**, and the **spend cap barely
bites** on subscriptions — Codex reports no cost and Claude reports a notional
figure, so iterations and wall-clock are the caps doing the real work.

---

## Holds — what is waiting on you

Everything that blocks on a human decision queues in one place: a planner's
question, a milestone ready to approve, an approval gated by open findings, a
branch ready to land, a failed milestone, a stalled run, an exhausted loop.
The titlebar count is decisions only; each hold notifies **once, ever** — a
macOS notification when it first appears, and never again, including across
restarts. Opening a hold lands you at its exact control — a milestone hold
opens the approval dialog itself, where approve, resume, adopt and the
finding dispositions all live.

Two kinds, with different clearing rules. **Decision holds clear only by
acting** — answering, approving, landing. They cannot be acknowledged away,
and the app refuses the attempt: a dismissible "waiting on your answer" would
clear the badge while the plan stays parked, which is the silent stall the
queue exists to kill. **Notice holds** carry no pending action, so
acknowledging them is the action.

The queue is derived from the durable record, never stored beside it — it
cannot drift, and it survives restarts. Park work, walk away, resolve the
batch when you return.

---

## Repos — the repository is the unit (⌘4)

Sessions are how work happens; repositories are what the work is *about* —
and the Repos surface makes the repository answer for itself. The sidebar
lists every repo Parley has ever worked (plans, backlog or learnings — any
record counts); selecting one opens five tabs:

- **Overview** — the radar: every unsettled plan with its status and one
  click to its controls, the holds queue filtered to this repo, and the
  foreman. "What's happening in this repo right now" on one screen.
- **Backlog** — the triage board described below.
- **Plans** — every plan that ever targeted the repo, across every session,
  numbered and newest first; a row opens the plan **in place**, and the
  origin session is a provenance link into ⌘2, the reading room. Sessions
  became links, not homes.
- **Sessions** — every debate and review that named this repository, newest
  first, with how many plans came out of each. The tab counts only *running*
  sessions, so the badge means live work rather than history. Rows open in ⌘2;
  the repository chip in a session's header is the door back.
- **Learnings** — the curated prose record.

"All repositories" remains the cross-repo triage board.

Repositories can be archived only when they have no work requiring attention.
Archived repositories stay in the local record but leave the sidebar and the
global backlog until **Show N archived** reveals them; opening one there exposes
the Restore control. New repository activity revives the sidebar projection
automatically, while holds remain visible regardless of archival state.

### The backlog

Work worth doing accumulates in a per-repository backlog, filed by the record
itself rather than by anyone's discipline:

- **A completed review's confirmed findings** become open items automatically,
  with the evidence refs copied over. Past reviews are swept in at startup, so
  the backlog opens already populated from everything Parley has seen.
- **An accepted risk is not a resolved risk.** Dispositioning a finding as
  accepted-risk files it against the repository it was accepted in — the
  decision is honored today and remembered tomorrow.
- **Stow** — a button on any finished session with a verdict — runs one
  read-only pass by the counterpart vendor over the bounded record (matter,
  verdict, findings, closing turns) and drafts backlog items and prose
  learnings from what the structured record does not already say. Everything
  it drafts is a **proposal**: nothing enters the working backlog until you
  confirm it, and re-filed duplicates just re-sight the item they matched.

Items move `proposed → open → planned → closure-proposed → done` (or are
dropped), every transition a human act or a pipeline act on an append-only
trail. Creating a plan lets you select open items; they ride the brief with
their evidence, flip to planned, and — when the plan completes (for worktree
plans, when it **lands**) — come back as closure proposals. The pipeline never
closes its own work: it says "I believe this is done", and you agree or send
the item back.

**Learnings** are the prose counterpart: short lessons a stow sweep drafts and
you confirm. Confirmed learnings ride every new plan brief for their
repository — newest first, capped, attributed — so a hard-won constraint
("the retry tests need a cold cache") stops being re-discovered by every
agent. Retiring a learning is what stops it; write-time is never capped.

Pending proposals surface as a decision hold per repository, so triage reaches
you through the same queue as everything else.

---

### The foreman

The one judgment the backlog still left to you was *which items to take next,
batched how*. The foreman is that judgment as a proposing role: **Ask the
foreman** (on the repo's Overview tab) runs one read-only agent turn over the
repository's open items — priorities, dependency edges, confirmed learnings,
recent plan history — and files a proposal: this batch, in this order, for
this reason; these deferred, because. It arrives as a decision hold, like
everything else that waits on you.

The power boundary is strict, and structural rather than promised:

- **Proposal power only.** The foreman never transitions backlog state, never
  creates plans, never picks vendors. Its output survives id validation
  (items it names must actually be open — invented ids are dropped with a
  note on the record), and then waits.
- **Accepting is creating.** Accept opens the normal plan dialog prefilled —
  you pick the vendors, you can edit the selection — and creating the plan
  *is* the acceptance, in one database transaction with the item flips.
  There is no state where a plan runs while its proposal still reads
  pending. Rejecting records your reason.
- **Every read is on the record.** An attempt is filed before the turn
  dispatches, so a crash is a recorded failure, not a vanished spend; failed
  reads keep their token usage and their error; a newer run supersedes the
  older proposal rather than erasing it. If the backlog moved after the
  read, the proposal says so — "3 items arrived after this proposal,
  including one P1" — and lets you decide anyway.
- **Backlog text is treated as records, not instructions.** Item details
  quote code and agent output; the foreman's prompt frames all of it as data
  under review, and its only power is suggesting a batch you approve.

With the foreman in place the loop originates work from its own record:
review → backlog → proposal → your accept → plan, audit, gates, review,
landing — your role compresses to answering questions and resolving holds.

---

## Building a new app, guided

**Build an app** on the Repos surface walks an idea to a reviewed,
running project in six steps:

**Brief** — say what you want, in your own words. **Challenge** — put that
brief to two model families before any code exists, which is the cheapest
moment to discover an idea does not survive contact. **Foundation** —
scaffold the project, with its tests proven green before any agent touches
it. **Build** — plan the work against the new project and run it in audited
slices, each verified and independently reviewed. **Preview** — run it, look
at it, and say whether it is what you wanted. **Harden** — review what now
exists, scoped to what you actually built.

It is a guide, not a generator. Every step opens the ordinary Parley
control for that step and every gate is still the gate; the guide's only
job is remembering which debate, project, plan and review belong together,
and naming the next honest step. It never skips ahead, and it follows work
you do outside it — run the debate yourself, point the guide at it, and you
arrive at the next stage rather than being asked to repeat one. Removing a
guide keeps everything it linked.

## Starting a new app

Parley can scaffold a new project rather than only improving existing ones.
**New app** — in the ⌘K palette or on the Repos sidebar — asks for a name,
a location and a template, then does four things in order: creates the
folder, writes the template, makes the first commit, installs, and runs the
project's own verification.

The order is the feature. **A project is only recorded ready if its
verification passes**, and if it does not, Parley removes what it made
rather than leaving a half-built scaffold behind. A project whose tests
could never run is the failure that eats an agent's hour and produces work
nobody can honestly review; here it cannot reach milestone one.

This is the one place Parley creates files where none existed, so it is
fenced accordingly. The destination must be an empty folder or a
not-yet-existing one inside a folder that does exist; never someone else's
work, never an existing git repository, never inside Parley's own record or
checkout. The path is validated live as you type, and creating the project
spends a recorded `workspace.create` approval naming that exact path — the
same shape as every other authorisation to write.

The first commit is the project, not its dependency tree: the template
carries a `.gitignore` and the commit lands before the install. What you get
is a repository whose `npm run verify` means something from its first
commit — which is exactly what an audited plan needs to verify anything at
all.

## Acceptance

A completed milestone has passed its tests and an independent review, which
settles whether it is *correct*. It does not settle whether it is what you
wanted, and nothing but you can. So a completed milestone offers **Accept**
and **Request changes…**, and what you say is recorded.

Requesting changes is also how feedback gets into the backlog at all.
Parley has no free-typing "add item" anywhere: everything on a backlog is
traceable to something that happened — a confirmed review finding, an
accepted risk, a stow sweep. Notes written while judging finished work file
as items with source `acceptance`, carrying that acceptance's id, so
"someone typed it" becomes real provenance because the typing itself is on
the record. They file straight to open, since you are the author and there
is no one to propose to.

Acceptance is deliberately **not a gate**. Nothing waits on it and nothing
unlocks from it — it is a record, and a way of turning "that's not right"
into work you will find again.

## Previews

A repository's Overview carries a **Preview** card: Parley runs the
project's own dev server, in the project's own folder, and tells you where
it is listening. The command is read from the project's `package.json`
(`dev`, then `start`, then `serve`) rather than assumed, and you can name a
different one.

The reason this beats a terminal tab is stopping. `npm run dev` is npm
spawning vite, so a plain signal to the child reaps npm and orphans the
server — which then holds the port with nothing visible left to kill.
Parley starts every preview in its own process group and stops the group,
and quitting the app takes them all with it.

The address is read from the server's own output, not guessed — the port it
got may not be the port it asked for — and it opens in your browser, never
inside Parley. The output is kept even after the process dies, which is
exactly when the last twenty lines matter.

## Unattended runs

Five milestones normally cost five approval clicks with dead time between
each. An **envelope** replaces them with one: you state the bounds up
front — how many milestones, how many hours, optionally a spend ceiling —
and Parley mints each milestone's own single-use approval from it as the
run proceeds. The per-milestone record keeps exactly the shape it always
had; every minted approval names the envelope it came from.

It adds no new power. The driver loops over the same machinery you drive
by hand, and every gate still applies: the findings check before each
milestone, the single-use approval, the deterministic verification, the
independent cross-vendor review.

Three rules make it safe to leave alone:

- **Worktree-only.** An envelope refuses a checkout plan. Unattended work
  happens in the plan's isolated branch or not at all.
- **It parks, it never presses on.** A blocking finding, a failed
  milestone, or a planner question ends the run and leaves the existing
  hold to surface it — with a record of how far it got. **Parked is
  terminal**: after you fix the cause, continuing takes a fresh envelope,
  because re-entering autonomy is a new decision, not a resumption.
- **It ends at merge-ready.** Landing is never inside the envelope. The
  fast-forward onto your checkout stays a separate, human click.

Caps are checked before each milestone starts, never mid-run — a
milestone already executing always finishes. Reaching one ends the run as
`exhausted` with the plan unharmed. Parley holds off idle sleep while a
run is live; **closing the lid still suspends the Mac**, and the run
parks mid-milestone to be resumed like any interrupted one.

The morning briefing is the holds queue — whatever needs you is already
there. The **In flight** popover beside it answers the other question:
what is running right now, with each capped run's consumption shown
against the bounds you set, and every row opening where its work lives.

## Dev containers

Some repositories' toolchains live in a `.devcontainer/` image — Terraform,
kubectl, a pinned Go — not on your Mac. Parley can run **its own
deterministic commands** for such a repository inside that container: the
milestone verification command, the worktree setup command, the post-land
smoke check, and a loop's command exit. That is the whole surface. The
repository and git stay on your machine, agents keep writing files on the
host, and nothing else crosses — verification is the thing that must be
true, so it is the thing that runs where the toolchain lives.

Turn it on per repository from the Repos Overview — the **Dev container**
card. Enabling requires a devcontainer configuration
(`.devcontainer/devcontainer.json` or `.devcontainer.json`) and the
`devcontainer` CLI (`npm install -g @devcontainers/cli`); execution
additionally needs a running docker daemon, whose absence surfaces as an
honest failure at run time, never as a silent fallback to the host. The
choice is **snapshotted onto each plan and loop at creation** — flipping
it later never changes what an already-granted approval meant, and the
approval text names the container when it applies.

Failure shapes are the ones you already know. A container that will not
start refuses a worktree creation with nothing half-made and the approval
unspent, fails a milestone verification closed with the reason in the
test result, surfaces fail-open after a landing that already happened,
and reads as exit-not-met in a loop's iteration detail, bounded by the
loop's caps.

Honest limits: the first `up` may build an image (it gets its own
generous timeout, and its output rides the failure detail); a cancelled
or timed-out command kills the host-side CLI client while the
in-container process may keep finishing; Parley never tears containers
down — `docker ps` is the lifecycle surface; git does not work *inside*
the container for worktree plans, so container-routed commands must not
need git; and mutation testing depends on the default bind mount — a
volume-cloned workspace configuration would blind it. Parley's own
repository is exempt permanently: its gate builds host bytes for the
host Electron.

## Self-update (dev mode)

When you run Parley from its own checkout (`npm run dev`), it knows which
repository it is: plans targeting that checkout are worktree-only — the
dialog greys the in-checkout option, and the engine refuses it at creation
and again at execution — because an agent writing into the live app's
source under it is the one uncontrolled case. When such a plan lands,
Parley automatically runs its own `npm run verify` and then `npm run
build` on the result. Green means the landed bytes both pass their checks
and now exist as a fresh build in `out/` — and that green is an offer in
the holds queue, not an act: **Relaunch** quits the app and boots the
version Parley just built of itself (the `npm run dev` terminal ends;
running panes close), **Not now** records the decline and you keep
running the old bytes deliberately. A red gate flags the landed plan
through the existing landed-but-verification-failed hold instead. Every
attempt, outcome and decision is a `self_updates` row — recorded like
everything else.

Two channels, deliberately distinct: this loop upgrades the **dev
checkout** — the factory. An installed Parley.app from a .dmg is a frozen
snapshot; it stays on its old version until you run `npm run package:mac`
and reinstall. Packaged-app self-update (signing, asar, migration
compatibility, rollback) is a separate, much later project.

One honest gap: mock plans never land, and the gate hooks at landing, so
the `PARLEY_MOCK=1` walkthrough cannot exercise this loop end to end.
Integration tests drive the real thing against fake checkouts instead —
see `AGENTS.md` for why that exception is deliberate.

---

## Requirements

- macOS on Apple Silicon
- [Claude Code](https://claude.com/claude-code) and/or
  [Codex CLI](https://github.com/openai/codex), installed and signed in
- Node 24+ to build

Parley shows each CLI's status in the toolbar, because "installed but not signed
in" is the most likely reason a session produces nothing.

## Build

```bash
npm install
npm run package:mac
```

`npm install` runs `npm run rebuild` for you, which builds `node-pty` against
Electron's ABI. If npm's script policy blocks it, run it yourself:

```bash
npm run rebuild
```

Develop without spending any subscription quota:

```bash
PARLEY_MOCK=1 npm run dev
```

In that mode a hazard-striped banner sits under the toolbar, every session, loop
and plan is tagged `mock`, and exported reports carry a **NOT REAL WORK** header —
because mock output is structurally identical to real output while consulting no
model. (The one thing a mock run ever writes is a single placeholder file during
a write-capable milestone, so the pipeline's tree checks stay exercisable.)

### If terminals will not start

`posix_spawnp failed` on every pane — including a plain shell — means node-pty's
`spawn-helper` binary is missing or not executable. It is a separate mac-only
build target, and npm blocking node-pty's install script leaves it out while
still providing `pty.node`, so the module imports fine and every spawn fails.
Parley detects this at startup and says so. The fix is `npm run rebuild`.

### If the CLIs are reported missing but work in Terminal

macOS starts GUI apps from `launchd` with a minimal PATH, so Homebrew, `npm -g`,
bun and mise installs are invisible to them. Parley reads your login shell's PATH
at startup to correct this. If your PATH is set somewhere the login shell doesn't
read, launching Parley from Terminal once will inherit the right environment.

### If a milestone reports "the working tree is byte-for-byte unchanged"

The files it was meant to create already exist, usually left by an earlier
attempt, and the executor declined to overwrite them. The approval dialog warns
about this before you spend anything and offers **Adopt & verify** instead.

## Where your data goes

Nowhere. Sessions, verdicts, findings, approvals, loops, saved layouts and the
whole audit trail live in SQLite under the app's own support directory. There is
no sync, no telemetry, and no remote service. The renderer runs sandboxed with no
Node access and a CSP that permits no remote origins.

Development and packaged installs keep **separate records**: a build running
from the checkout (`npm run dev` — it wears a `dev` chip in the titlebar) uses
`~/Library/Application Support/parley-dev/`, while an installed Parley.app owns
`~/Library/Application Support/parley/`. Deliberate, not incidental — the dev
checkout migrates the schema ahead of any frozen .dmg, whose downgrade guard
would otherwise refuse to start, and two instances sharing one database would
each mark the other's live runs interrupted at boot. The two can run side by
side safely.

See [AGENTS.md](AGENTS.md) for the engineering guide and the invariants that hold
this together.
