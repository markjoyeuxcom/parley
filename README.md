# Parley

A local-first macOS workbench for working with several AI agents at once. It
drives **Claude Code**, **Codex** and **Agy** through their own CLIs, so
everything runs against the subscriptions you already pay for — Parley never
asks for an API key and has no API-key code path.

One surface: a splittable grid of panes. A pane is either a real interactive
terminal — a shell, or a live `claude` / `codex` / `agy` session with its own
TUI and its own permission prompts — or a **room**.

## Passing work between CLIs

The loop this exists for: Claude asks something, you want Codex's read on it,
then you want that answer back in Claude. People run it with ⌘C.

Open a pane's menu and **Send last answer to** another — no selecting. It takes
what the CLI has drawn since you last pressed Enter, lifts the box-drawing
frame off it, and hands it over. Select text first if you want only part of it,
and the menu offers that instead; either way it shows you what it is about to
send. It arrives attributed — the receiving CLI has no idea where it came from, and
an unattributed wall of someone else's reasoning reads as your own words — and
it arrives as a *paste*, so newlines survive and a diff stays a diff. Nothing
is submitted until the paste completes.

Selecting inside a CLI that has claimed the mouse (Claude Code does) needs ⌥
held while you drag; a plain drag goes to the application, which highlights its
own text and looks selected while the terminal has nothing.

An agent in a pane can relay too: `parley relay codex "have a look at this"` is
on its PATH. It attributes and submits that exact text to the named cross-vendor
pane. Use `parley paste codex "draft"` when the text should be placed in the
prompt without pressing Enter.

For a question whose answer should return to the same planning turn, use
`parley ask agy "question"`. Parley attributes and submits that question once,
then leaves the command blocked until Agy returns through the consultation. Its
answer becomes the command output, so the planner continues without another
copy, paste, approval, or Return click. Only one consultation may await an
answer in a target pane at a time.

Every agent Parley starts receives the same versioned cross-vendor protocol,
independently of the folder it opens in. Claude receives it as an appended
system prompt, Codex as developer instructions, and Agy through a Parley-owned
rules workspace. The protocol defines `relay`, `paste`, `ask`, and `answer` once;
the vendor adapters only decide how that identical text reaches each CLI.
Existing panes show **RESTART FOR PROTOCOL** until deliberately restarted.

No vendor will build this. Claude Code's subagents take Claude models and
nothing else; Codex's threads are OpenAI's. Every agent system is a closed loop
around its own models, which is exactly why the copy-paste existed.

## Rooms

A room is a pane that holds a conversation instead of a process: one or more
**seats**, a transcript, and you.

**You are seat 0.** What you type is a turn like any other.

**Say something and every seat answers, independently.** They run at the same
time and none of them sees the others' replies, which is the entire reason to
seat more than one: two answers are two readings, not one reading and an
agreement. Models converge fast when they can hear each other, and agreement
you manufactured is not information.

**Address one with `@name`.** Leading mentions choose who speaks. A mention
*mid-sentence* chooses what they see — so

> `@auditor check the three file:line claims @sceptic just made`

sends the question to the auditor with the sceptic's last turn attached. That
is one turn, not two: relaying is context, not a dispatch.

**`Advance`** is the opposite mode — each seat hears the one before it, in
order, for as many turns as you ask. This is where seats argue with each other
rather than answering you in parallel.

**`Converge`** asks every seat for its own scored verdict, independently, and
merges them. Disagreement *lowers* the recorded confidence: two advisors each
claiming 90% while scoring ten points apart have not produced a confident
answer, and the record says so. The losing side's objection is kept verbatim.
A room can converge more than once and every verdict is kept — what the seats
thought before, and what changed their minds, is usually the interesting half.

### What it costs, and what stops it

Every unaddressed message is one CLI invocation per seat, each reading your
folder. Three seats is three times a single pane, and the seat line shows
`14/40 turns · $3.20` as you go.

The turn budget is checked by Parley before every dispatch and is never
visible to a seat — an agent that can see its budget can argue about it.
Reaching it is reported as **exhausted**, never as done, and continuing takes
a deliberate new number.

### Reading and writing

Every seat starts **read-only**: it reads the folder its pane lives in and
changes nothing. Writing is a per-seat toggle, and the room header says who
holds it for as long as they hold it — that is standing permission, not a
one-time approval, and a capability nobody is reminded of is one nobody
remembers granting.

### The roster

**Roster** in the toolbar keeps named ways of configuring a seat: a CLI, a
model, an effort and a persona, under a name like *Sceptic* or *Auditor*. Never
credentials — the CLIs hold their own authentication. A profile's name becomes
the seat's address, so keep it short.

## Terminal panes

Up to sixteen panes in a splittable, resizable layout, and rooms sit among them.
Panes are **multi-folder**: each keeps the folder it started in, a split
inherits its neighbour's, and the toolbar only decides where the *next* one
opens.

**Skills** are reusable prompt packs on the bottom rail. Drag one onto an agent
pane and it is typed into that live session; drop it on a room and it lands as
your own turn.

**Saved layouts** keep an arrangement — pane kinds, split tree, each pane's
folder. Restoring one opens shells immediately and leaves agent panes and rooms
as one-click placeholders, so no CLI session ever begins against your
subscription without you asking. A restored room is a *new* room; to bring back
a conversation, use **Reopen a room…** on an unstarted room pane.

`⌘D` splits right · `⌘⇧D` splits down · `⌘W` closes · `⌘]` cycles · `⌘⏎`
maximizes · `⌘F` finds in a pane · `⌘K` is the command palette, which searches
everything ever said in a room.

## Native tmux prototype

The first replacement path for the unstable Electron/xterm terminal surface is
now runnable in `native/`. It is a native SwiftUI window with SwiftTerm doing
terminal input and Metal rendering, while an isolated tmux server owns the
shells, agent processes, splits, scrollback and session lifetime. It never
touches your normal tmux server.

The prototype can open and manage shell, Claude, Codex and Agy panes; split
right or below; rename, restart and close panes; zoom or balance the grid; and
choose the folder for new panes. Its **Ask** action sends a selected answer (or
text composed in an initially empty editor) to a different vendor after an
editable preview, remembers the requesting pane, and exposes **Return** on the
answering pane. **Insert Visible Pane** explicitly adds the current screen and
never includes scrollback. Both clicks are human actions and submit only after
that preview.

New agent panes also receive four cross-vendor commands. `parley relay <pane>
<text>` carries only its explicit arguments or stdin through an authenticated
local broker and submits it. `parley paste <pane> <text>` is the explicit
unsent form. `parley ask <pane> <question>` submits, waits for the target's
correlated `parley answer`, and then returns that answer to the original agent
as command output; `parley answer` completes that waiting command.

Run it on the Mac without starting an agent automatically:

```bash
npm run native:test
npm run native:dev
```

It starts or reattaches one shell. Claude, Codex and Agy begin only when you
choose them from the menu. Closing the window detaches from tmux; the panes keep
running and are there on the next launch.

This is a working migration slice, not yet the packaged Parley replacement.
Rooms, transcripts, saved layouts, the record and release packaging still live
in the Electron application. See [native/README.md](native/README.md) for the
boundary and commands.

## Where your data goes

Nowhere. Rooms, their transcripts, verdicts, saved layouts, skills and the
roster live in SQLite under the app's own support directory. There is no sync,
no telemetry, and no remote service. The renderer runs sandboxed with no Node
access and a CSP that permits no remote origins.

Development and packaged installs keep **separate records**: a build running
from the checkout (`npm run dev`) uses `~/Library/Application
Support/parley-dev/`, an installed Parley.app owns
`~/Library/Application Support/parley/`. The two can run side by side.

A room's transcript survives quitting. Closing a pane keeps the record — a room
nobody ever spoke in is swept at startup, one that was used is not — and
**Save transcript…** writes the whole conversation out as Markdown.

## Requirements

- macOS on Apple Silicon
- At least one of [Claude Code](https://claude.com/claude-code),
  [Codex CLI](https://github.com/openai/codex) or Agy, installed and signed in
- Node 24+ to build
- Swift and tmux to build and run the native prototype

Parley shows each CLI's status in the toolbar, because "installed but not
signed in" is the most likely reason a seat produces nothing.

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

In that mode a chip sits in the titlebar, and any transcript you save carries a
**NOT REAL WORK** header — because mock output is structurally identical to real
output while consulting no model.

### If terminals will not start

`posix_spawnp failed` on every pane — including a plain shell — means
node-pty's `spawn-helper` binary is missing or not executable. npm blocking
node-pty's install script leaves it out while still providing `pty.node`, so
the module imports fine and every spawn fails. Parley detects this at startup
and says so. The fix is `npm run rebuild`.

### If the CLIs are reported missing but work in Terminal

macOS starts GUI apps from `launchd` with a minimal PATH, so Homebrew, `npm -g`,
bun and mise installs are invisible to them. Parley reads your login shell's
PATH at startup to correct this. If your PATH is set somewhere the login shell
doesn't read, launching Parley from Terminal once will inherit the right
environment.

## History

Parley began as a governed engine — adversarial debates, cross-examined
codebase reviews, an audited execution pipeline with single-use approvals,
capped autonomous loops, a per-repository backlog and a foreman that proposed
work from it, remote execution over ssh, and a self-update loop that let the
app improve itself through its own machinery. All of that is gone.

The premise held: an agent's claim about its own work is worthless, so deny it
the ability to certify itself. What did not hold was the shape that took for
*discussion* — a fixed stage schedule with a structured verdict contract, where
a human interjection could only land at a turn boundary. That is a form with
two respondents, not a conversation.

[ROOMS.md](ROOMS.md) is the record of retiring it, and [AGENTS.md](AGENTS.md)
is the engineering guide to what remains.
