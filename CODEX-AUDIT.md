# Parley codebase audit

I audited the current working tree—including its existing uncommitted changes and the untracked `native/` prototype—without modifying files.

The most urgent defects are not in command parsing. They are state/lifecycle failures: mock and real Room output can be mixed under the wrong label, Room cancellation can continue spending turns, the renderer continuously polls IPC, and Electron preserves PTY processes across window closure without preserving the terminal state needed to use them.

## 1. Correctness findings

### Critical — CONFIRMED: reopened Rooms can mix mock and real work under one false label

A Room’s `mock` flag is set once when created:

[manager.ts:136](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:136)

```ts
mock: this.deps.registry.mock,
```

Reopening restores that old value unchanged:

[manager.ts:166](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:166)

```ts
const stored = this.deps.repo.getRoom(roomId)
this.rooms.set(roomId, { room: stored, resumeIds: new Map(), inFlight: new Map() })
```

But later turns use the current process-wide registry:

[manager.ts:543](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:543)

```ts
result = await this.deps.registry.get(seat.config.vendor).run({
```

The export warning is based solely on the original Room flag:

[room.ts:265](/Users/markjoyeux/Developer/Personal/parley/src/shared/room.ts:265)

```ts
if (room.mock) lines.push('# NOT REAL WORK — mock adapters, no model was consulted', '')
```

Concrete failure paths:

- Create a real Room, restart with `PARLEY_MOCK=1`, reopen it, and send another message. Mock turns are appended to `mock: false`; a later export has no warning.
- Create a mock Room, restart normally, reopen it, and send. Real turns are added to `mock: true`; the whole export is falsely labelled mock.
- `RoomTurn` has no per-turn mock field, so after mixing, the record cannot be repaired reliably.
- `RoomPane` never displays `room.mock`; only the reopen picker does so at [GridSurface.tsx:1883](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:1883). A mock Room reopened in a real process loses the permanent visible warning.

Action: refuse writable reopening when `stored.mock !== registry.mock`, or fork into a new Room with the current mode. Do not permit mixed-mode turns until mock-ness is persisted per turn.

---

### Critical — CONFIRMED: Stop and Close do not cancel an `advance` operation

`advance()` is a multi-turn loop:

[manager.ts:444](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:444)

```ts
for (let i = 0; i < turns; i += 1) {
  ...
  const [turn] = await this.speak(...)
}
```

Stop and Close only abort controllers that exist at that instant:

[manager.ts:602](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:602)

```ts
for (const control of live.inFlight.values()) control.abort()
```

[manager.ts:612](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:612)

```ts
for (const control of live.inFlight.values()) control.abort()
this.rooms.delete(roomId)
```

Although `speak()` notices that the Room was deleted after a turn finishes, it merely returns:

[manager.ts:512](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.ts:512)

```ts
if (!this.rooms.has(roomId)) return finished
```

`advance()` then proceeds to its next loop iteration using the captured `live` object and starts another seat.

Concrete failure:

1. Click Advance in a multi-seat Room.
2. Click Stop or close the pane while the first advanced seat is running.
3. That seat aborts.
4. `advance()` starts the next paid turn anyway.
5. After Close, those later turns are invisible because the Room is no longer live.

The UI requests up to one turn per seat at [RoomPane.tsx:576](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/RoomPane.tsx:576), so one close can leave several additional CLI invocations running.

Action: give each compound operation an operation-level abort/generation token. Check it before and immediately after every `await this.speak`, and make Close permanently invalidate it.

---

### High — CONFIRMED: the renderer runs an endless IPC reconciliation loop

`StoreProvider` recreates `attempt` and `notify` whenever any global state changes:

[state.tsx:215](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/state.tsx:215)

```ts
const store = useMemo<Store>(() => {
  ...
  attempt: async <T,>(...)
}, [state])
```

The Grid’s purported one-shot reconciliation depends on `attempt` and dispatches a new global state object every time it completes:

[GridSurface.tsx:154](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:154)

```ts
void attempt(() => api.listPanes()).then((panes) => {
  ...
  dispatch({ type: 'panes', panes })
})
...
}, [attempt, dispatch])
```

Failure cycle:

1. `pane.list` resolves.
2. `dispatch({type: 'panes'})` creates new state.
3. New state creates a new `attempt` function.
4. The effect runs again.
5. Repeat for the lifetime of the Grid.

The same unstable dependency also reruns `layout.list` and `folder.list` at [GridSurface.tsx:135](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:135) and [GridSurface.tsx:197](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:197). A persistent IPC failure is worse: `attempt` adds a notice, which changes state and immediately retries.

This creates constant renderer rerenders, structured-clone traffic, SQLite reads and temporary allocation even when the app is idle.

Action: make `notify` and `attempt` stable with `useCallback`, or separate state and actions into two contexts. Add a test asserting `pane.list` is invoked once after unrelated state changes.

---

### High — CONFIRMED: closing and reopening the Electron window preserves processes but destroys their usable terminal state

On window closure, the main process deliberately retains PTYs:

[index.ts:123](/Users/markjoyeux/Developer/Personal/parley/src/main/index.ts:123)

```ts
mainWindow.on('closed', () => {
  mainWindow = null
})
```

The renderer unmount destroys every xterm buffer:

[TerminalPane.tsx:238](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/TerminalPane.tsx:238)

```ts
detach()
...
term.dispose()
```

While the window is absent, main explicitly discards output:

[renderer.ts:39](/Users/markjoyeux/Developer/Personal/parley/src/main/util/renderer.ts:39)

```ts
if (!target || target.isDestroyed()) return
...
// The chunk is lost
```

On reopen, the Grid recovers only PTY metadata and creates fresh blank `Terminal` instances.

Consequences:

- All prior scrollback is lost.
- All output produced while the window was closed is lost.
- The last-answer marker and remembered selection are lost.
- An idle TUI may not emit anything after reattachment, leaving a blank pane connected to a live process where input is accepted blindly.

This does not satisfy the stated “reopen finds the work where it was” behavior. The native tmux design has the correct ownership model: tmux retains screen, scrollback and process state.

Rooms have a parallel problem. `RoomManager` survives window closure, but Grid mount adopts only `pane.list`, not live Rooms. `RoomPane` merely unsubscribes at [RoomPane.tsx:135](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/RoomPane.tsx:135). Closing the window during a Room turn leaves it spending out of sight until manually reopened from the record.

Action: either move Electron PTYs behind tmux as well, or stop claiming process persistence until screen state can also be restored. For Rooms, explicitly choose and implement one policy: abort on window close or adopt every live Room on reopen.

---

### High — CONFIRMED: exited PTYs can become invisible while permanently consuming the pane limit

The manager intentionally retains exited handles:

[manager.ts:459](/Users/markjoyeux/Developer/Personal/parley/src/main/pty/manager.ts:459)

```ts
handle.pane.status = 'exited'
...
// The handle stays in the map
```

The pane cap counts every retained handle:

[manager.ts:365](/Users/markjoyeux/Developer/Personal/parley/src/main/pty/manager.ts:365)

```ts
get count(): number {
  return this.panes.size
}
```

But window re-adoption deliberately excludes exited panes:

[GridSurface.tsx:159](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:159)

```ts
const adoptable = panes.filter((pane) => pane.status !== 'exited')
```

Concrete failure:

1. A CLI exits.
2. Close and reopen the macOS window.
3. Its handle remains in main, but the Grid omits it.
4. There is no UI path to call `pane.close`.
5. Repeat until `this.panes.size === 16`; opening any new PTY is refused despite an apparently empty Grid.

The existing smoke test explicitly requires this broken behavior at [surfaces.smoke.test.tsx:238](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/surfaces.smoke.test.tsx:238):

```ts
// Two, not three: the exited one stays off the grid.
```

Action: adopt exited panes too, or prune them from the manager when their owning renderer disappears. Preserving the corpse requires preserving its UI reachability.

---

### High — CONFIRMED: Swap and Arrange destroy scrollback and can drop terminal bytes

Swap changes which `paneId` occupies an existing React position:

[GridSurface.tsx:1285](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:1285)

```ts
setLayout((current) => (current ? swapLeaves(current, id, other) : current))
```

`TerminalPane`’s terminal lifecycle depends on `paneId`, so changing it disposes the old xterm and creates a new one:

[TerminalPane.tsx:72](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/TerminalPane.tsx:72), [TerminalPane.tsx:238](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/TerminalPane.tsx:238)

```ts
useEffect(() => {
  const term = new Terminal(...)
  ...
  return () => term.dispose()
}, [paneId])
```

The buffer layer also removes an in-flight chunk from its queue before xterm acknowledges it:

[ptyBuffer.ts:100](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/lib/ptyBuffer.ts:100)

```ts
const chunk = flow.queue
flow.queue = ''
flow.writing = true
```

On reattachment, that chunk is not restored. The test explicitly expects it to disappear:

[ptyBuffer.test.ts:184](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/lib/ptyBuffer.test.ts:184)

```ts
send(pane, 'before')
...
expect(second.writes).toEqual(['after'])
```

Thus Swap definitely loses scrollback and relay boundaries; Arrange can do the same whenever rebuilding the tree changes component positions. If a write was in flight, terminal bytes are also dropped despite `ptyBuffer.ts` claiming “Nothing is dropped” at line 30.

Action: key terminal ownership by stable `paneId` outside the layout tree and move DOM hosts without destroying the terminal, or persist/replay serialized terminal state. Requeue in-flight chunks on generation replacement.

---

### High — CONFIRMED: asynchronous slot operations can orphan live processes and Rooms

`startSlot` captures an idle slot, awaits creation, then writes it back without verifying the slot still exists:

[GridSurface.tsx:310](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:310)

```ts
const slot = slots[slotId]
...
const pane = await attempt(() => api.openPane(...))
...
setSlots((current) => ({ ...current, [slotId]: { ...slot, paneId: pane.id } }))
```

Meanwhile `closeSlot` can remove the slot and layout leaf:

[GridSurface.tsx:482](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:482)

```ts
delete next[slotId]
...
removeLeaf(current, slotId)
```

The open completion then reintroduces only the slot record, not its layout leaf. The process remains live in main with no visible owner.

`relaunchSlot` detects a deleted slot after its open, but simply returns the current state without closing the new process:

[GridSurface.tsx:372](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:372)

```ts
const opened = await ...
setSlots((current) => {
  const existing = current[slotId]
  if (!existing) return current
```

Saved-layout restoration has the same class of race: idle shells are rendered before the sequential startup loop finishes at [GridSurface.tsx:574](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:574), allowing manual Start or Close to overlap automatic startup.

Action: assign each slot an operation generation. Commit an open only if the same generation and idle slot still exist; otherwise immediately close the returned process/Room. Disable Start while an open is pending.

---

### Medium — CONFIRMED: native Return routes survive process replacement

Ask stores a pane-local tmux option:

[TmuxController.swift:200](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/TmuxController.swift:200)

```swift
set-option ... "@parley-return-to", requesterID
```

The option is cleared only after a successful Return:

[TmuxController.swift:219](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/TmuxController.swift:219)

```swift
try paste(... into: requester.id, submit: true)
set-option -u ... "@parley-return-to"
```

Restarting preserves the tmux pane and never clears the route:

[TmuxController.swift:165](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/TmuxController.swift:165)

```swift
respawnArguments(...)
setRelayMetadata(...)
```

Closing a requester also does not clear other panes whose route points to it:

[TmuxController.swift:173](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/TmuxController.swift:173)

```swift
kill-pane
credentials.forget(paneID)
```

Failure paths:

- Restart the consultant: the new CLI process inherits a RETURN badge for a consultation it never received.
- Restart the requester: Return submits the old answer into a new process in the same tmux pane.
- Close the requester: the consultant shows RETURN indefinitely; every attempt fails before consuming the route.

This contradicts the exact-process rule already implemented in Electron consultations.

Action: clear the restarted pane’s route and every route pointing to it. Do the same before closing a pane.

---

### Medium — CONFIRMED: native polling can block the main UI for up to ten seconds every second

`AppModel` is main-actor isolated:

[AppModel.swift:23](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyNative/AppModel.swift:23)

```swift
@MainActor
final class AppModel
```

The view polls it on the main run loop every second:

[ContentView.swift:6](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyNative/ContentView.swift:6)

```swift
Timer.publish(every: 1, on: .main, in: .common)
...
model.refreshQuietly()
```

`refresh()` synchronously executes `tmux list-panes`, whose runner waits on a semaphore for up to ten seconds:

[AppModel.swift:92](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyNative/AppModel.swift:92), [CommandRunner.swift:85](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/CommandRunner.swift:85)

```swift
panes = try controller.listPanes()
...
let timedOut = finished.wait(timeout: deadline)
```

A stalled tmux socket therefore freezes selection, menus, redraw and terminal interaction on the main thread.

Action: run tmux control calls off-main, publish the parsed pane list back on `MainActor`, and prevent overlapping refreshes.

---

### Low — CONFIRMED: failed PTY spawns leak relay credentials

A credential is minted while constructing spawn options:

[manager.ts:416](/Users/markjoyeux/Developer/Personal/parley/src/main/pty/manager.ts:416)

```ts
proc = pty.spawn(resolved, args, {
  env: {
    ...paneEnv(id, kind, process.pid, this.tokens.mint(id)),
```

If `pty.spawn` throws, the catch does not call `tokens.forget(id)`. `RelayTokens` retains it in an unbounded map at [tokens.ts:19](/Users/markjoyeux/Developer/Personal/parley/src/main/relay/tokens.ts:19).

Repeated `posix_spawnp` failures therefore grow the token registry until application quit. The leaked credential cannot relay because no corresponding pane exists, so impact is memory only.

Action: forget the token in the spawn catch.

## 2. Security findings

### Medium — CONFIRMED hardening gap: the renderer is not sandboxed and is effectively trusted with shell input

The actual BrowserWindow setting is:

[index.ts:72](/Users/markjoyeux/Developer/Personal/parley/src/main/index.ts:72)

```ts
contextIsolation: true,
nodeIntegration: false,
sandbox: false,
```

This contradicts README’s statement that “The renderer runs sandboxed” at [README.md:155](/Users/markjoyeux/Developer/Personal/parley/README.md:155).

More importantly, the preload exposes the whole generic command dispatcher:

[preload/index.ts:19](/Users/markjoyeux/Developer/Personal/parley/src/preload/index.ts:19)

```ts
ipcRenderer.invoke(CH.invoke, { command, payload })
```

`pane.write` accepts arbitrary strings and writes them directly to a live shell:

[ipc.ts:40](/Users/markjoyeux/Developer/Personal/parley/src/shared/ipc.ts:40), [commands.ts:213](/Users/markjoyeux/Developer/Personal/parley/src/main/ipc/commands.ts:213)

```ts
data: z.string()
...
ctx.pty.write(paneId, data)
```

Therefore any renderer script execution is already equivalent to command execution: list panes, write a command followed by `\r`. Enabling Chromium sandboxing would still be worthwhile, but it would not make this IPC surface untrusted.

Action: correct the documentation and threat model. Either explicitly treat renderer compromise as RCE and keep the renderer free of remote/HTML execution surfaces, or redesign input delivery around a stronger main-process trust decision.

---

### Medium — CONFIRMED bad predicate; exploitability currently limited to development navigation

Development navigation is accepted using a string prefix:

[index.ts:96](/Users/markjoyeux/Developer/Personal/parley/src/main/index.ts:96)

```ts
url.startsWith(process.env['ELECTRON_RENDERER_URL'])
```

For a development URL of `http://localhost:5173`, both of these pass:

```text
http://localhost:5173@evil.example/
http://localhost:51730/
```

The first parses as origin `http://evil.example`. A remote page loaded into the top frame would receive the preload bridge and pass the existing top-frame IPC check at [register.ts:35](/Users/markjoyeux/Developer/Personal/parley/src/main/ipc/register.ts:35). It could then write to a pane or read arbitrary repository diffs through `git.workingDiff`.

There is currently no normal link/navigation producer—the code says so at [externalUrl.ts:9](/Users/markjoyeux/Developer/Personal/parley/src/main/util/externalUrl.ts:9)—so this is not a production remote-code path today.

Action: compare parsed `URL.origin` values, not prefixes, and reject credentials in the URL.

---

### No confirmed shell-injection path

The command construction I traced is sound:

- Agent processes use `spawn(command, args)` with no shell at [spawn.ts:54](/Users/markjoyeux/Developer/Personal/parley/src/main/util/spawn.ts:54).
- PTYs use an absolute executable plus an argv array at [manager.ts:393](/Users/markjoyeux/Developer/Personal/parley/src/main/pty/manager.ts:393).
- Git operations use fixed `git` argv arrays at [workingDiff.ts:24](/Users/markjoyeux/Developer/Personal/parley/src/main/util/workingDiff.ts:24).
- Native `Process` assigns `executableURL` and `arguments` separately at [CommandRunner.swift:41](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCore/CommandRunner.swift:41).
- Native tmux agent respawns are built as separate argv entries.
- Model Markdown is rendered as React text nodes, never HTML, at [RoomPane.tsx:892](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/components/RoomPane.tsx:892).
- External URLs are restricted to HTTP, HTTPS and mailto at [externalUrl.ts:17](/Users/markjoyeux/Developer/Personal/parley/src/main/util/externalUrl.ts:17).
- Transcript writes require a native save dialog at [commands.ts:274](/Users/markjoyeux/Developer/Personal/parley/src/main/ipc/commands.ts:274).

I found no confirmed production command injection or arbitrary silent filesystem write outside the explicitly granted Room seat capability.

## 3. Architecture and dead weight

The project’s own scope test says, “The grid and the relay are the parts that earn their keep; the rest of the codebase is larger than the product” at [FEATURES.md:7](/Users/markjoyeux/Developer/Personal/parley/FEATURES.md:7). I agree.

### What I would keep

- Interactive shell/Claude/Codex/Agy panes.
- Multi-folder split grid.
- Human Ask → Return.
- Agent-initiated paste-only relay.
- Cross-vendor diff review.
- A small folder/layout store, if saved layouts are genuinely used.

### What I would cut

1. **Cut the entire Room orchestration stack unless Rooms have demonstrated use.** That removes `RoomPane`, `RoomManager`, verdict merging, Advance, Converge, write-capable headless seats, profiles/roster, transcript FTS, all three headless adapters and most of the 489-line mock adapter. Rooms duplicate conversations the interactive CLIs already own and introduce the two critical quota/data-integrity defects above.

   If Rooms must stay, reduce them to the one unique behavior: independent cross-vendor answers to one human question. Cut Advance, Converge, scored verdicts and write-capable seats first.

2. **Cut Skills and Broadcast.** Skills are static prompts typed into vendor CLIs at [GridSurface.tsx:819](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/GridSurface.tsx:819); the vendors already own prompt/skill systems. Broadcast is a cross-agent prompt-injection amplifier and does not shorten the principal Ask/Return loop.

3. **Make native replacement finite.** Electron and native now duplicate process lifecycle, environment resolution, pane discovery, relay credentials, text cleaning, Ask/Return and terminal ownership. The native route has already drifted from Electron’s exact-process guarantee. Set a parity milestone and delete one implementation; do not maintain both indefinitely.

### Immediate dead code and residue

- `surfaces.css` still contains large retired blocks for session inspectors, milestones, pipelines, backlog and foreman, e.g. [surfaces.css:788](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/styles/surfaces.css:788), [surfaces.css:1228](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/styles/surfaces.css:1228), and [surfaces.css:1984](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/styles/surfaces.css:1984). No current TSX uses those selectors.
- `MockAdapter` still implements the retired planner, foreman, mutation-repair and milestone contracts at [mock.ts:181](/Users/markjoyeux/Developer/Personal/parley/src/main/agents/mock.ts:181) and [mock.ts:216](/Users/markjoyeux/Developer/Personal/parley/src/main/agents/mock.ts:216).
- `motion` is declared at [package.json:41](/Users/markjoyeux/Developer/Personal/parley/package.json:41) but has no source import.
- `canonicalRepoPath` is imported but unused at [repo.ts:17](/Users/markjoyeux/Developer/Personal/parley/src/main/store/repo.ts:17).
- `splitCommand` and `isShellFree` survive only in tests at [spawn.ts:368](/Users/markjoyeux/Developer/Personal/parley/src/main/util/spawn.ts:368); the governed command-execution callers are gone.
- `layout.delete` and `skill.save` remain in the IPC/API surface at [ipc.ts:166](/Users/markjoyeux/Developer/Personal/parley/src/shared/ipc.ts:166), but have no renderer caller.
- `app.info` can spend up to 20 seconds running `agy models` at [agy.ts:173](/Users/markjoyeux/Developer/Personal/parley/src/main/agents/agy.ts:173), yet `state.agyModels` and `codexDefaultModel` are never read by a component.
- `AgentRegistry.counterpart()` at [index.ts:51](/Users/markjoyeux/Developer/Personal/parley/src/main/agents/index.ts:51) has no production caller.

These should be removed before adding another abstraction; they actively obscure which code is load-bearing.

## 4. Test coverage gaps

### Verification performed

- `npm test`: **44 files passed, 1 skipped; 479 tests passed, 9 skipped**.
- `npm run native:test`: **11/11 checks passed**.
- The skipped Vitest file is the quota-spending live adapter suite guarded by `PARLEY_LIVE=1` at [live.test.ts:20](/Users/markjoyeux/Developer/Personal/parley/src/main/agents/live.test.ts:20).
- I did not run `npm run typecheck` because its scripts deliberately delete `.tsbuildinfo`, which would violate the no-modification requirement.

### Important gaps

- `manager.test.ts` imports only readiness, submission, command and environment helpers—not `PtyManager` itself—at [manager.test.ts:1](/Users/markjoyeux/Developer/Personal/parley/src/main/pty/manager.test.ts:1). Exit retention, count accounting, late output and spawn failure cleanup are untested.
- The Store tests exercise only the reducer at [state.test.ts:24](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/state.test.ts:24). Nothing tests callback identity or effect invocation counts, so the infinite IPC loop passes.
- The Room stop test covers a single `send`, not a multi-turn `advance`, at [manager.test.ts:228](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.test.ts:228). Close is tested only after work has finished at [manager.test.ts:606](/Users/markjoyeux/Developer/Personal/parley/src/main/rooms/manager.test.ts:606).
- No test reopens a Room under the opposite mock mode.
- The Arrange smoke test asserts only that `pane.open`/`pane.close` counts do not change at [surfaces.smoke.test.tsx:279](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/surfaces.smoke.test.tsx:279). It cannot observe scrollback, terminal identity, markers or in-flight data.
- Vitest emitted repeated “HTMLCanvasElement.getContext not implemented” messages while the terminal smoke tests passed. Those tests therefore do not exercise real xterm rendering, WebGL, serialization or context loss.
- The pty-buffer remount test positively expects pre-remount data loss at [ptyBuffer.test.ts:174](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/lib/ptyBuffer.test.ts:174).
- No test holds a deferred `pane.open`, closes/replaces its slot, and then resolves it.
- Native checks cover Ask and successful Return, but not restart/close route invalidation.
- The preload test reads source code and matches regular expressions at [bridge.test.ts:5](/Users/markjoyeux/Developer/Personal/parley/src/preload/bridge.test.ts:5). It does not instantiate the bridge, verify WebContents identity, or test navigation behavior.

### Tests/assertions that cannot catch what they claim

- In the native “agent relay paste only” check, the injected test closure itself hard-codes `submit: false`:

  [main.swift:258](/Users/markjoyeux/Developer/Personal/parley/native/Sources/ParleyCoreChecks/main.swift:258)

  ```swift
  paste: { paneID, text in delivered = (paneID, text, false) }
  ...
  expect(delivered?.submit == false, "agent relay pressed Enter")
  ```

  That final assertion cannot detect production wiring changing to `submit: true`; it is asserting its own fixture value. The broker’s `response.body.submitted == false` assertion is meaningful, but the delivery assertion is not.

- `assertLedgerGateActionsDisabled` at [surfaces.smoke.test.tsx:163](/Users/markjoyeux/Developer/Personal/parley/src/renderer/src/surfaces/surfaces.smoke.test.tsx:163) is never called. The retired governed-engine controls it names no longer exist, so none of its assertions can fail.

## Recommended repair order

1. Prevent cross-mode Room reopening from contaminating the record.
2. Add operation-level cancellation to Advance and Close.
3. Stabilize `attempt`/`notify` and stop the perpetual IPC loop.
4. Decide whether Electron panes genuinely survive window closure; use tmux or stop retaining unusable PTYs.
5. Restore exited-pane reachability and pane-limit accounting.
6. Preserve terminal identity across layout moves and requeue in-flight output.
7. Add slot-operation generations to prevent orphan opens.
8. Clear native Return routes on restart/close and move tmux polling off-main.
9. Then make the architectural cut: preferably Rooms/orchestration first, followed by dead CSS, APIs and dependencies.
