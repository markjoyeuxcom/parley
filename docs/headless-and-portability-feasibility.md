# Feasibility: headless operation, a remote box, and a Windows port

A study, not a proposal. It answers what would have to change, what is already
done, and where each target stops being a port and starts being a different
product. Figures are measured from this repository at v0.1.33, and where
something is unverified it says so.

## The three asks are different sizes

They are usually said in one breath, but they stack:

1. **No display** — run on a Mac with nobody watching.
2. **A remote box** — run on a Linux server.
3. **Windows** — run on Windows.

Each is a superset of the one before, and the difficulty is not linear. 1 is the
smallest, but it is not small: it needs a replacement PTY owner and a decision
about who owns terminals and processes, on top of the product question. 2 adds
re-deriving platform guarantees. 3 is a platform-layer rewrite.

## What is already portable

This is the encouraging part, and it is not an accident of the codebase.

`ParleyCore` imports **no UI framework at all** — no SwiftUI, no AppKit, no
Ghostty — and its Package target declares zero dependencies. Of its 97 files and
31,419 lines, **68 files have no `import Darwin`**. Roughly 70% of the core is
already plain Swift.

More importantly, `RelayBroker` never learns what a terminal is. Delivery
arrives as injected closures:

```swift
paste: @escaping Paste,
submit: @escaping Submit,
panes: @escaping Panes,
selectedText: SelectedText?,
vendorSignal: VendorSignal?,
```

The GUI supplies them (`AppResidentCoordinationCore` wires `paste` to
`WorkbenchController.paste` to `GhosttyPaneRegistry.paste`). Swap those closures
and the broker — credentials, capability transport, correlation, delegation,
the handoff and activity journals, retention, context review — runs unchanged.

The agent-facing half is **already headless today**. `parley ask`, `delegate`,
`done` and the rest talk to a Unix socket and files under
`/private/tmp/parley-native-<uid>-<hash>/`. Nothing in that path renders
anything. A pane with no window attached would still coordinate.

## What is genuinely bound to the Mac

**The UI layer.** `ParleyNative` is 29 files and 18,651 lines of SwiftUI,
AppKit, Ghostty and Sparkle. None of it survives any of the three targets in its
current form.

**The terminal.** Parley does not call a vendor API; it types into the CLI's
TUI. `GhosttyPaneRegistry.paste` takes programmatic focus on a surface, pastes
as one text operation, settles, then sends Enter as a separate key event, and
restores `NSApp.keyWindow`. The Ghostty binary framework ships **Apple slices
only** — `macos`, `ios`, `maccatalyst`, `xros`. There is no Linux or Windows
slice, so the terminal stack does not travel.

That sounds fatal and is not. Ghostty is doing two jobs here: rendering and
owning a PTY. Delivery only needs the second. A headless build can own a PTY per
CLI and write to it, the way tmux does — same vendor TUI, same prompts, same
session, simply unrendered.

**Sparkle** is macOS-only; updates would need a different mechanism per target.

## The POSIX surface that would have to move

Narrow and concentrated, which is the good news. Measured across `ParleyCore`:

| API | Files | Linux | Windows |
| --- | --- | --- | --- |
| `posix_spawn` | 2 | yes, but `POSIX_SPAWN_CLOEXEC_DEFAULT` is Darwin-only | no — `CreateProcess` |
| `O_EXLOCK` | 3 | no — separate `flock()` | no — `LockFileEx` |
| `renamex_np` (`RENAME_EXCL`) | 1 | no — `renameat2(RENAME_NOREPLACE)` | no — `MoveFileEx` |
| `O_EVTONLY` + `DispatchSource` file watch | 1 | no — inotify | no — `ReadDirectoryChangesW` |
| `SecRandomCopyBytes` | 2 | no — `getrandom()` | no — `BCryptGenRandom` |
| `SO_NOSIGPIPE` / `F_SETNOSIGPIPE` | 2 | no — `MSG_NOSIGNAL` | not applicable |
| `sockaddr_un` | 2 | yes | AF_UNIX exists on Win10+, but named pipes are idiomatic |
| `waitpid` / `kill` | 2 / 6 | yes | no — no POSIX signals |
| Seatbelt (`sandbox-exec`) | 1 | no equivalent | no equivalent |

Two observations worth more than the table.

**The Seatbelt row is smaller than it looks.** v0.1.30 already removed Parley's
outer boundary from host vendor CLIs; `AgentProcessBoundary` now wraps only the
container Docker client. Porting does not have to reproduce Seatbelt, because
the product already decided host CLIs run with vendor permissions.

**The signal row is the Windows wall.** `kill` appears in 6 files, `waitpid` in
2, and the whole reviewed-command-run worker is built on signal semantics —
`SIGCHLD`, `SIGTERM`, `SIGINT` handling, process groups, and the
`POSIX_SPAWN_SETSIGMASK` rule added in v0.1.31. Windows has no equivalent model.
That is not a shim; it is a redesign of process lifetime.

## The vendors are not the blocker

Both vendor CLIs publish native builds for all three targets:

```
@anthropic-ai/claude-code-{darwin,linux,win32}-{x64,arm64}   (+ linux musl)
@openai/codex-{darwin,linux,win32}-{x64,arm64}
```

Checked against the npm registry at the time of writing rather than recalled.
So "can the CLIs even run there" is settled. Whether their TUIs behave
identically under a foreign PTY — particularly ConPTY on Windows — is not, and
would need a spike.

## Target 1 — no display, on macOS

**Feasible, and mostly already done.**

What is needed:

- A PTY owner that is not Ghostty. The injected-closure seam means the broker
  itself does not change, but the delivery contract does not reduce to a write
  plus a newline: today a multiline payload travels as one bracketed paste and
  submission is a separate Enter key event, precisely so raw newlines are never
  sent as keys. A replacement owner has to reproduce that, and Copilot's
  focus-and-restore behaviour, against real vendor TUIs. Treat it as unproven
  until one is driven that way.
- A decision about terminal ownership. `WorkbenchController` states that Ghostty
  surfaces own the vendor process, terminal state and session, with
  `PaneTerminalTransport` as the broker's narrow interface. Moving PTY ownership
  is a change to invariant 7, independent of Linux, not a UI extraction.
- The human surfaces become commands. Ask and Return previews, context approval,
  verdicts and Status Center are today native-control-only, over the UI socket.
  Each would need a CLI equivalent (`parley review`, `parley approve <id>`),
  keeping the existing rule that only the authenticated control route may set a
  verdict.
- Something to attach with, if a person wants to watch: `parley attach <pane>`.

What does not change: the broker, credentials, transport, journals, retention,
handoff correlation, the protocol. All of `ParleyCore`.

**The real cost is not technical.** Invariant 5 is "visible and interruptible",
and the founding idea was handing text between CLIs *side by side*. Attach-on-
demand keeps coordination and loses the supervision that motivated it. Also,
`AGENTS.md` explicitly forbids "a background daemon" — a headless Parley is one.
So this is a decision about what the product is, taken before any code.

## Target 2 — a Linux remote box

**Feasible, bounded, and the natural home for a headless build.**

Everything in Target 1, plus the platform surface in the table above. Each entry
has a Linux counterpart, but a counterpart is not a direct equivalent: what has
to survive is the guarantee, not the call. `LOCAL_PEERPID` establishes who is on
the other end of the control socket; `SO_PEERCRED` or `SO_PEERPIDFD` must be
shown to establish the same thing. `O_EXLOCK` and `renamex_np` carry exclusive
publication; OFD locks and `renameat2` have to be demonstrated to, not assumed
to. Compilation succeeding proves nothing about any of them, so each needs a
contract check exercising its failure case. Treat the table as the list of
guarantees to re-derive. Docker is native rather than a VM, so container
panes get simpler, not harder.

Sequencing that avoids a big-bang port: raise `Package.swift` to declare Linux,
then move the platform primitives behind small protocols in `ParleyCore`
(random bytes, exclusive file lock, atomic exclusive rename, directory watch,
spawn, signal-or-equivalent). Those are the six seams. `ParleyCore` is already
the right shape for it because it has no UI dependency to untangle first.

Vendor login is worth a thought: a headless server has no browser, which is
exactly the container-login problem that motivated command-click link opening
in v0.1.32. On a remote box the answer is the vendor's own device-code or
token flow, not a link — worth confirming per vendor before committing.

## Target 3 — Windows

**Not a port. A platform-layer rewrite, and a different product.**

Beyond everything above:

- **ConPTY instead of a PTY.** `CreatePseudoConsole` has a different lifecycle
  and different semantics. Whether a vendor TUI drives correctly under it is
  unknown and is the first thing to spike.
- **No signals.** The reviewed-command-run worker, cancellation, process groups
  and the v0.1.31 signal-mask rule all rebuild on job objects and handles.
- **No Ghostty and no Sparkle**, so a Windows GUI means choosing a new terminal
  renderer and a new update mechanism — both of which `AGENTS.md` currently
  forbids adding.
- **Toolchain.** Swift on Windows is real but the Foundation and Dispatch
  surface differs, and `scripts/run-native-swift.mjs` exists specifically to
  pick a macOS SDK. That script does not survive.

The blunt version: after this work the shared asset is `ParleyCore`'s pure
logic and the protocol. That is worth having, but calling it a Windows port
undersells what is actually being proposed.

## What I would actually do

**If the goal is "run coordination on a server", Windows is not needed.** Run
Linux on the box and keep the Mac as the client. That collapses the problem to
Targets 1 and 2, which share almost all their work, and leaves the GUI where it
is good rather than reimplementing it twice.

Order:

1. Decide whether headless Parley is this product or a sibling. `AGENTS.md`
   says no daemon and one terminal stack; both change here. Nothing else is
   worth starting until that is answered.
2. Spike the PTY seam on macOS only: one vendor CLI under `forkpty`, driven by
   the existing broker with swapped closures. This tests the single assumption
   everything else rests on — that delivery works without a rendered terminal —
   and it is cheap because the seam already exists.
3. If that holds, extract the six platform primitives behind protocols and
   build for Linux.
4. Treat Windows as a separate decision afterwards, informed by a ConPTY spike
   rather than by this document.

## Confidence and gaps

Measured here: the file and line counts, the Darwin import distribution, the
POSIX API table, the Ghostty framework slices, `.macOS(.v14)`, and the vendor
CLIs' published platform variants. Also measured since: in a Linux Swift
container, `Darwin` to `Glibc` and `CryptoKit` to `swift-crypto` are mechanical
and the compiler walks past them; the residue is roughly 18 files around the
syscall guarantees above.

One number that could mislead: extracting only the 65 import-free files into
their own target fails with about 5,000 errors, 612 of them for `RelayHandoff`
alone. That is not 5,000 obstacles. It establishes that a file-level filter is
invalid, because the platform-importing files define the domain vocabulary the
rest consumes, and missing vocabulary fans out. It neither proves a small
extraction nor an enormous one. The ordering it implies is to lift domain
declarations out of platform-importing files first, following referenced types
rather than the file list, and only then choose platform protocols.

Not established, and each would change the shape of this: whether vendor TUIs
behave correctly under a bare PTY with no renderer; whether they behave under
ConPTY at all; how vendor login works headlessly per vendor; and how much of
the 18,651-line UI layer represents product behaviour that would have to be
rebuilt as commands rather than simply dropped.

No effort estimates in days appear above deliberately. The unknowns in the
previous paragraph dominate any number that could be written today.
