# Where we are

State of Parley as of 20 August 2026, `feat/tauri`. Written so the next session
does not have to re-derive it from the diff.

For how the app is built and what may never change, read `AGENTS.md`. For the
Rooms protocol, `ROOMS.md`. This file is the current position: what is settled,
what is running, and what is still open.

---

## The shape of the thing

A local-first macOS workbench driving `claude`, `codex` and `agy` through their
own CLIs. One surface: a splittable grid of panes, where a pane is either a real
interactive terminal or a **room** — a conversation with one or more agent seats
over a single transcript.

The part that earns its keep is narrower than the codebase suggests: three CLIs
side by side, and a relay that hands text from one to another without
copy-and-paste. Everything else is in service of that or is not yet load-bearing.

## Settled this week

**The Tauri port is gone.** It was begun on the theory that Chromium was the
memory ceiling. It is not — xterm.js parses on the main thread in any webview,
so WKWebView inherits the identical arithmetic. It reached a working terminal
grid with a working relay, and was deleted at commit `4de4cd2`, where it can be
read if it is ever wanted.

Deleted rather than parked because keeping it cost real work: every fix on 20
August had to be mirrored into Rust — the bracketed-paste allowlist, per-pane
relay credentials, flow control, pane limits, the lifecycle kill — five times,
on a build nobody ran. One of those mirrors was worse than useless: the Rust
paste-bypass test passed against the vulnerable code because its payload used
the wrong marker. Dead code that must be kept in sync is a liability; dead code
with tests that lie is a trap.

What the port produced and Parley kept: the pane lifecycle work, and a
pane-adoption bug it exposed in the Electron build. The three hard-won PTY
traps it carried are written up below and in AGENTS.md as prose, which is where
they were always the more useful for being.

**The renderer OOM is mitigated, not solved.** From dying at 8-14 minutes to
running past an hour under a harsher load. It still peaks near 12GB. The full
causal record — including what did *not* fix it, which is the more useful half —
is in `AGENTS.md` under "The renderer OOM, and what actually fixed it".

**Two AI audits were run against the codebase from inside the app itself**, via
the relay, and worked through. Roughly half the findings survived checking. The
ones that did are fixed; the ones that did not are recorded with reasons in the
commits, so nobody re-derives them.

## Running state

- **Electron is the app.** `npm run dev`. There is no second runtime.
- **Health probes cost nothing.** All three check authentication rather than
  running a turn. They no longer report a spent quota as a login problem.
- **Codex room seats run under an isolated `CODEX_HOME`** with no MCP servers.
  Codex *panes* keep the user's own configuration.
- **Each pane holds its own relay credential.** The sender is derived from it;
  `X-Parley-From` no longer exists.

## Open, in the order I would take them

1. **Fragmentation or a native cache.** The split has been run: the JS heap
   stays in a 37-133MB band while renderer RSS climbs to 7.9GB, and is capped
   at 4192MB regardless — so the growth is native and a heap snapshot would
   show nothing. See AGENTS.md for the curve. What remains is fragmentation of
   PartitionAlloc's fixed 16 GiB pool versus a native cache. The clean test is
   the CDP harness run twice, fixed colour against rotating, moving one
   variable; the eight-colour repro makes the glyph atlas an unlikely driver.

2. **The app cannot be shipped.** No signing identity, no notarisation, and one
   entitlement whose necessity could not be tested without a Developer ID —
   see the note in `resources/entitlements.mac.plist`. It runs on one machine.
   Fine if it is only ever Mark's; a blocker the moment it is not.

3. **Profiles on panes.** The relay attributes by pane title, so it says
   `codex` where it should say `implementer`. This is the gap between "three
   CLIs" and "a team", and it is why a shell pane relaying is attributed as the
   folder name.

4. **The keyboard.** ⌘K has no pane actions, and the menu bar is stock Electron.

5. **Four or more busy agent panes are unproven.** Three is measured. The
   ceiling is close enough that a fourth may reach it.

## Things that look like bugs and are not

- **A shell pane's relay is attributed to the folder** (`Personal/parley said:`)
  rather than a vendor, because shell panes carry no vendor in their title.
  Ugly, deliberate, item 3 above.
- **`sandbox: false`** in the Electron window is required for the preload to use
  `contextBridge` with ESM, and is documented at the line.
- **Turns are written to the record before they complete.** That is what stops a
  crash losing the fact that money was spent. Anything reading a turn as an
  answer has to ask `isAnswered` first.

## How this app gets debugged

Every real defect here has been found by using it, not by the suite — including
two on the same day the suite grew past 450 tests. Typecheck clean and all green
has repeatedly coexisted with a blank window.

Drive it rather than reasoning about it. Where a check is claimed, run it for
its exit code rather than grepping its output.
