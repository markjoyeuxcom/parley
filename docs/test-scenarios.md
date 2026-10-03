# Parley test scenarios

A working checklist for a deep manual pass. Every scenario says what to do, what
should happen, and what counts as a failure — so a "pass" means something.

## How to use this

- **Record the build first.** `Parley → About`, and note the version in any
  report. A fault without a build number is much harder to act on.
- **Change one thing at a time.** The v0.1.35 regression only appeared with a
  second pane open; single-pane testing would have missed it entirely.
- **On any failure, capture:** the version, how many panes were open and of
  which vendors, whether it was Production or Development, and the exact
  sequence. A screenshot of the window beats a description.
- **Priority 1 is the short list.** If time runs out, P1 is what matters: it is
  the regressions from this week plus the acceptance nobody has ever done.
- Automated checks cover none of this. `ParleyCoreChecks` cannot reach
  `ParleyNative`, and the Ghostty soak drives the registry without building the
  window. Everything below is only ever verified by hand.

---

# Priority 1 — regressions and never-done acceptance

## P1.1 Multiple panes keep drawing (the v0.1.35 regression)

1. Open one pane. Confirm it draws.
2. Open a second. **Both** must still draw.
3. Open a third, then a fourth. All must draw.
4. Close the second. The rest must keep drawing.
5. Switch to another workspace and back. All panes still drawing.

**Fail:** any existing pane goes black or blank when another is opened or
closed. This is exactly what shipped in v0.1.35.

## P1.2 Vendor sessions, fresh and resumed

For **each** of Claude, Codex, Agy, Copilot:

1. Start a pane fresh. It reaches its normal prompt.
2. Ask it something trivial that makes it use a tool, and approve the prompt.
   The vendor's own permission prompt must appear and behave normally.
3. Ask it `parley whoami`. Identity, vendor and protocol version are right.
4. Ask what Parley protocol version it received. It should say 32.
5. End the session from inside the CLI (`/exit`, or Control-D at its prompt).
   The pane shows the process as exited; there is no Parley "stop" for a host
   pane. Then use the pane menu's **Resume** item. Confirm the vendor's own
   picker appears and the session continues on its terms.
6. Repeat step 3 after resume.

**Fail:** a vendor can't start, the protocol is missing after resume, or Parley
claims a session survived when the vendor says otherwise.
**Note:** Copilot needs **Confirm Copilot Folder Trust** in its pane menu before
handoffs work. Agy reports hook state as Unknown by design.

## P1.3 Container pane acceptance

1. Start one container pane per vendor: Claude, Codex, Agy and Copilot
   (Runs › In a container in each review; `parley-agents:local` carries all
   four, see `docs/container-images.md`).
2. Sign each in, by the vendor's flow in `docs/container-images.md`
   ([Signing in](container-images.md#signing-in)). For Codex, try both device
   code and browser sign-in with **Published port** set to 1455; the
   callback must complete on the Mac.
   **Fail:** the vendor cannot write its home (Agy: "mkdir
   /home/parley/.gemini: permission denied"; Copilot: "EACCES … .cache"),
   which every image with a `/home/parley` directory did before 14
   September 2026 until the home volume was mounted with nocopy.
3. Confirm protocol uptake (`parley whoami`, protocol 34) fresh and resumed.
4. Send an Ask and a Delegate between a container pane and a host pane,
   including a `done --file` result and a reviewed context pack.
5. Check normal permission prompts appear (unless you chose bypass — then the
   pane badge and review must say so). Try one allowed and one refused
   operation and record what the vendor actually did; hook signals are not
   proof.
6. Restart the pane. **Login must persist.** Then choose **Stop…** in the
   pane's menu: the pane stays, stopped, and Status Center → Health →
   Containers shows its container removed. Start it again from its menu:
   **login must persist** there too. (Close Pane is different: it removes the
   pane, and a new pane starts with a new, empty home volume.)
7. Quit Parley entirely, relaunch, start the pane again. Login still persists.
8. Status Center → Health → Containers: confirm the records make sense.
9. Stop a pane while it is working, then quit the Docker runtime during a
   cleanup. An uncertain removal must stay visible. **Delete Saved Vendor
   State** must refuse while a container still uses the volume, then remove
   only the selected unused one.
10. Compare total idle resource use, the Docker VM included; Parley's process
    list shows only the host Docker client.
11. In a new agent review, choose Runs › In a container, press **Check Image
   and Daemon** and, while it reads "Checking…", change the Vendor row.
   **Fail:** the first vendor's result ("Ready for your review", its image
   ID) appears under the new vendor. Before 28 September 2026 it did.

**Fail:** login lost across restart, protocol missing, bypass not disclosed.

## P1.4 A question is answered by the right question (v0.1.37)

1. From pane A, `parley ask <B> "..."`. Don't answer it.
2. Look at the question delivered into B. It must name a **specific id** in the
   answer command, not `current`.
3. Answer with that exact command. A gets the answer.
4. Now let one expire: ask B something, leave it unanswered past the timeout.
5. After it fails, have B run `parley answer <that id> "late"`. It must be
   refused with a message saying the consultation closed and when — not
   "unknown consultation".

**Fail:** the prompt says `current`, or a late answer lands on a different
question, or the refusal is a bare error.

## P1.5 Coordination survives a restart (v0.1.36 journal fix)

1. Do real work: several relays, an Ask, a Delegate that completes.
2. Quit Parley fully. Relaunch.
3. Status Center → history shows everything from before.
4. Status Center → Health reports the core as available.

**Fail:** coordination unavailable after relaunch, or history missing records.

## P1.6 Delivery into a pane that is closing

1. Start a Delegate or Ask into pane B.
2. While it is being delivered, close B.
3. The sender must report a failure rather than a success.

**Fail:** a submission is reported that never arrived.

## P1.7 Images in handoffs (protocol 34)

Use the packaged app: the window picker and macOS's own consent need a bundle.

1. In a Codex pane, ask it to screenshot a window with its computer use, save
   it as a PNG in its folder and run `parley context draft --name Shot --file
   <png>`. The Context menu lists the draft; opening it shows the image as a
   preview, "Agent-provided image", with its size and SHA-256.
   **Fail:** the part shows text, or no preview.
2. Send that draft to a Claude pane with **Ask One Pane**. Claude runs the
   `parley image <sha256> --to <file>` the pack names and describes the
   picture. A third pane running the same command is refused.
   **Fail:** Claude cannot fetch it, or the third pane can.
3. Open a context pack of your own and choose **Capture Window…**. macOS shows
   its window picker; pick a window. Note whether macOS asks for Screen
   Recording permission, and what it shows in the menu bar while picking.
   The capture appears in the pack as "Window capture" with a preview.
   **Fail:** Parley captures without the picker, captures a window you did
   not pick, or the picker stays active (its menu-bar indicator remains)
   after the capture.
4. Cancel the picker once: nothing is added and no error appears.
5. With the capture in the pack, **Compare** is unavailable. Send it with
   **Ask One Pane** to an agent pane: the target fetches the image with the
   command in the pack, and Status Center shows the Ask with **SENT IMAGES**.
   **Fail:** the target cannot fetch it, or another pane can.
6. Ask One Pane to a pane that already has tracked work: Parley says the pack
   cannot wait in the busy queue and keeps it open.
7. Remove a capture from an unsent pack, or close the pack unsent, then
   **Clear history** for an Ask that sent one: the image is gone (a fetch
   says Parley no longer keeps it).

---

# Priority 2 — core functions

## P2.1 Pane lifecycle

- Create shell pane; create agent pane; both reach a prompt.
- Close a pane — its process ends (check Status Center → Health).
- Restart a pane — new launch generation, old session not claimed to survive.
- Move a pane to another workspace — surface, scrollback and process preserved.
- Move the last pane out of a workspace: the source stays, empty, offering
  New Shell and New Agent…; nothing about it is deleted.
  **Fail:** the source workspace disappears, or the move is refused.
  Move the **selected** pane: the source workspace stays on screen with one of
  its remaining panes selected, and the moved pane is drawing when you switch
  to the target.
  **Fail:** the source shows "No pane in this workspace", the window content
  collapses, or the move only takes effect after reselecting the workspace.
- Zoom and unzoom a single terminal.
- Close the main window — panes keep running; reopen — same surfaces.
- Quit with panes running — the pane-aware confirmation appears ("Quit and end
  N agents?"); confirming ends every pane process and the coordination core.
  There is no separate Stop Everything item: quitting is how everything stops.

## P2.2 Workspaces and folders

- New Workspace creates a folderless container with no panes; it is a valid
  state: the empty view offers New Shell and New Agent…, and attachments and
  the New Pane Folder can be set before any pane exists.
- Close the last pane in a workspace: the workspace stays, empty; quit and
  relaunch: it is still there. Close the workspace itself to remove it.
  **Fail:** the workspace vanishes with its last pane, or a relaunch treats
  the empty workbench as a fresh install.
- Attach two or more folders; both appear; search covers them.
- Remove a folder attachment while a pane is live in it — the pane is unchanged.
- `parley open <folder>` from a shell: focuses one match, asks on several,
  creates a shell workspace on none.
- Open a folder from Finder — same behaviour.
- A folderless shell pane gets a safe cwd and does not silently attach it.
- Delete a folder that appears under Recent in the New Pane Folder menu, wait
  five seconds, then open the menu: it is no longer offered. **Manage Folders…** lists favourites
  and recents with full paths, marks a deleted one MISSING with Use disabled,
  and Remove forgets it; **Clear Recent Folders** empties the history.
  **Fail:** a deleted folder is still offered, or removing an entry touches
  anything on disk.
- Right-click a workspace row, an attached folder and a favourite folder while
  an agent is working, and hold each menu open for a few seconds. **Fail:** a
  menu redraws, closes or moves its items under the pointer. The recent
  collaboration (clock) menu behaves the same while handoffs change.
- Hover a split divider (resize cursor), zoom a pane with the keyboard, then
  move over a terminal. **Fail:** the resize cursor stays.

## P2.3 Relay, Paste, Ask, Delegate

- `parley relay` — arrives and submits immediately.
- `parley paste` — arrives **without** Enter; you can edit before sending.
- `parley ask` — blocks, returns the exact answer.
- `parley ask-many` with two targets — independent answers, neither sees the other.
- `parley delegate` — returns an id immediately, does not block.
- `parley progress <id> "..."` — note appears in Status Center, labelled
  AGENT-DECLARED.
- `parley done <id> "..."` and `parley fail <id> "..."` — recorded correctly.
- `parley done <id> --file <path>` — stages for review, does **not** forward.
- `parley status`, `parley wait <id>`, `parley cancel <id>`.
- Refusals: same pane, a shell target, an ambiguous vendor name, a busy target.

## P2.4 Discovery and protocol

- `parley whoami`, `parley panes`, `parley events --since beginning`.
  whoami on a Claude, Copilot or Agy host pane reports `attestation:
  peer-verified` and `ticketPolicy: required`; on a Codex host pane on
  Flexible + network the same, and on Flexible `ticketPolicy: optional`
  naming the escalation; inside a container
  `token-only` and `unavailable` with the mount as the reason.
  With `"sandbox": {"enabled": true}` in the folder's `.claude/settings.local.json`,
  a Claude host pane reports `ticketPolicy: optional` naming that file.
  **Fail:** a Claude host pane reads token-only while the socket listens and
  its sandbox is off, or a copied capability used from a plain Terminal is
  served for a Claude pane.
- `parley help` and `parley protocol` work with no broker.
- Events contain no prompts, terminal text or folders.

## P2.5 Human handoffs and review

- Select text in a pane, use Ask — the selection prefills the editable preview.
- Send with no selection — the composer starts empty.
- Toolbar **Ask**: the composer takes focus on open; your first keystrokes land
  in the box without clicking it. Open a second Ask; focus returns again.
  **Fail:** keystrokes go to the terminal behind the composer.
- Click back into a terminal and type — the pane still takes input normally.
  **Fail:** the focus guard has broken ordinary terminal focus.
- Send an Ask and let the target answer: Status Center opens on that exact
  handoff with the answer visible. Nothing is pasted into the source pane.
  **Fail:** only a Result badge appears, or text lands in the source prompt.
- Answer a waiting Ask by hand: ask pane A → B, let B print its reply without
  running `parley answer`, then use the **Answer** toolbar item on B (it shows
  only while B holds an unanswered Ask). The preview is prefilled from B's
  selection; sending completes A's waiting `parley ask` with your text and
  pastes nothing into either pane.
  **Fail:** the item shows when no Ask is waiting, or text lands in a pane.
- Challenge and Verify on a returned handoff — lineage is recorded.
- Set a human verdict and note; confirm an agent cannot set one.

## P2.6 Reviewed context

- Capture a File, a Git Diff and a Selection into a Context Pack.
- An agent stages a draft — it is labelled agent-provided and unapproved.
- Approve a pack and deliver it; the header wording changes appropriately.
- **Ask with Context** on an agent-staged draft, and **Approve and Ask** on an
  agent's context Ask: the sheet closes at once, the target pane receives the
  pack, and the app stays responsive the whole time.
  **Fail:** Parley stops responding after confirming. v0.1.40 froze here until
  it was force-quit.
- After **Ask with Context**: Status Center shows one new Ask (Questions
  count 1, Live shows it waiting), the delivered pack ends with a
  `parley answer <id>` instruction, and when the target answers that id the
  answer arrives as the returned result on that handoff and Status Center
  opens on it. The review shows Completed and names the Ask.
  **Fail:** Questions stays 0 and the reply only appears in the target's
  terminal. That is what v0.1.41 did.
- Discard a draft; delete a saved context record.
- A `done --file` result: open **Show returned file**.

## P2.7 Status Center

- Live section shows active work; History shows completed.
- Health: core availability, pane-to-process attribution, containers.
- Search history; export to Markdown — verdicts and lineage preserved.
- Clear history for one workspace; confirm active work survives.

## P2.8 Reviewed command runs

- `parley request-run --cwd <folder> -- <executable> <args>`.
- The native preview shows exact argv and folder, and is editable.
- Approve — a **new** Shell pane opens and runs it; output captured.
- Cancel a running one.
- Settings → General → Agent command runs: turn automatic approval on, confirm
  the disclosure, confirm it resets on quit.
- Turn on "close the Shell pane when a run finishes cleanly"; confirm a clean
  run closes the pane and a failed one keeps it.

## P2.9 Permission profiles

- Start Claude Code or Copilot on this machine and read the review: What is
  carried lists Peer-attested requests as enforced by Parley. For Codex, a
  container, or Agy, What is not carried says why a ticket is not required.
  **Fail:** the line is missing, or claims attestation for Codex or a container.

- Start an agent and review the permission profile; the review names what is
  and is not carried to the vendor.
- A profile requiring approval for execution: the agent gets a permission
  prompt before a shell command.
  **Codex note:** if `~/.codex/config.toml` sets
  `approvals_reviewer = "auto_review"`, Codex sends sandbox escalations to its
  own automatic reviewer and shows no prompt; that is Codex's documented
  behaviour, not Parley's. Parley still shows PERMISSION REPORTED because
  Codex's hook fires when it prepares the request. An escalation the reviewer
  allows still runs inside the sandbox: Codex documents auto-review as "a
  reviewer swap, not a permission grant", so a network command still fails
  under a network-restricted profile. Remove that line to see Codex's prompt.
- **Flexible + network** on a Codex host pane: `curl -I https://example.com`
  runs inside the sandbox with no escalation. On Flexible it still escalates.
  What is carried lists Network as enforced by Codex; for Claude, Agy and
  Copilot, Network sits under What is not carried and says only Codex's
  sandbox can carry the rule.
  **Fail:** the network command escalates on Flexible + network, or a
  non-Codex review claims to enforce network.
- Codex review, Approvals section: a line states what your own Codex config
  sets for `approvals_reviewer` (orange when it is `auto_review`, since that
  overrides the choice), or that it sets none.
  **Fail:** the line never appears, or says nothing when the config has it.
- **Approvals → Vendor's automatic reviewer** on a Claude pane (auto mode) and
  a Codex pane (auto review): the Claude pane's status line says "auto mode
  on" from the first frame, not "accept edits on" (v0.1.44 to v0.1.48 opened
  in accept-edits because the review dropped the choice); a routine command
  such as `ls` runs with no prompt; a destructive one such as
  `git push --force` is refused or asked.
  On an Agy pane the picker is disabled and the review says Agy has no
  reviewer. What is carried names the mode on its Profile line and the
  reviewer on its Approvals line.
  **Fail:** a routine command still prompts, a destructive one runs silently,
  or the pane launch carries any skip-all flag.
- A container pane with **Bypass vendor permissions**: badge, review, Status
  Center and Team Sessions all disclose it.

## P2.10 Terminal behaviour

- Select, copy, scroll in each pane; no focus collapse across six panes.
- Resize the window and the splits.
- Command-click an `http(s)` link in output — it opens.
- Command-click a `file:` or `javascript:` link — **nothing happens**.
- Settings → Terminal Appearance: import from Ghostty config; only font, size,
  theme and palette come across.
- Set an explicit font family and size; confirm it wins over the import.
- Settings → Terminal → Terminal type. In a Shell pane, `echo $TERM` reads
  `xterm-ghostty`. Choose **Compatible**: the running pane still reads
  `xterm-ghostty` (nothing restarts). Open a new Shell pane: it reads
  `xterm-256color`, and `htop` or `vim` run normally there.
- With Compatible chosen, `ssh` from that new pane to a Linux host that has
  never had Ghostty's terminfo installed. `htop` starts, and the delete key
  deletes the character to the left. Before this setting the host printed
  `ncurses: cannot initialize terminal type ($TERM="xterm-ghostty")` and
  delete moved the cursor.
- Choose **Ghostty** again and restart the pane; `echo $TERM` reads
  `xterm-ghostty`. Copy the command in the Remote hosts section, run it once
  against the same host, and ssh there again: `htop` now starts with the
  Ghostty type too.

**Fail:** a running pane's `TERM` changes without a restart; an agent pane
started after the choice reads the old value; the Copy button copies anything
other than the command shown.

---

# Priority 3 — breadth

## P3.1 Attention

- A pane awaiting permission shows the permission ring.
- A returned result shows the result ring; an interrupted handoff the red one.
- Command-Shift-J cycles attention newest first.
- The menu-bar indicator reflects waiting work.
- Signal age is shown, and the wording says **reported**, never "is waiting".

## P3.2 Roles, lead and mobility

- Assign a role with the pane's More menu → Set Routing Role. The pane header
  must show `@reviewer` straight away. Address it as `@reviewer` and as
  `workspace/@reviewer`.
- Set the same role on a second pane in the same workspace: an alert must say
  the role is already assigned, and the second pane must show no role. The
  same role on a pane in another workspace is allowed by design.
  **Fail:** no badge after the first set, or no alert on the second.
- Mark a workspace lead; address `lead`.
- Refuse a role collision on move; refuse moving the last source pane.

## P3.3 Team sessions

- `parley team request --folder <f> --panes 2 "<objective>"` from a lead pane.
- Approve the preview; `parley team add --vendor codex`.
- `parley team status`; Team Sessions sheet shows membership.
- The sheet's Work list shows only handoffs with the session's panes, made
  while it ran. The requester's earlier or unrelated handoffs are absent.
  **Fail:** older workspace handoffs appear under Work. v0.1.42 did this.
- Stop team panes; confirm a pane you restarted yourself is skipped and reported.
- An Agy host member keeps its own approval prompts; a run that needs them is
  not unattended, by design. Container bypass exists for every vendor; only a
  container member with approved bypass runs unattended.
- A Claude host member on **Flexible** or **Broad workspace** runs
  `parley whoami` with no prompt and still prompts for `ls`, which is Claude's
  own acceptEdits behaviour, not a Parley rule. Neither profile carries a Bash
  restriction. With Approvals set to the vendor's reviewer, `ls` runs too.
  On **Default** or **Workspace folders** every shell command asks, `parley`
  included: those profiles ask before local processes, Claude carries that as
  an ask rule for all of Bash, and Claude's ask rules beat allow rules even in
  auto mode.
  **Fail:** a `parley` command prompts on Flexible, or a Default pane runs a
  shell command without asking.
- After Stop: **Close stopped team panes…** in the sheet names each stopped
  placeholder, closes only those, and leaves the requester, unrelated panes
  and any pane you restarted alone.
- With a container vendor approved, `parley team add` it and press Stop while
  its member reads "preparing its container". The stop outcome lists it under
  Skipped with "container preparation cancelled", not under "Could not
  confirm a stop"; once the preparation returns, the member reads stopped and
  **Close stopped team panes…** offers it. A member whose container failed to
  prepare (for example an image removed after approval) is offered the same
  way. **Fail:** the member is reported as failed, or stays "stopped" but is
  never offered for closing.

## P3.4 Managed worktrees

- In the Worktrees window, a tree created and never committed to reads
  UNUSED, not Integrated; Remove integrated and unused… proposes it labelled
  unused; after one commit merged into the primary it reads Integrated, and
  its facts line says pushed, N unpushed commits, or no upstream.
  **Fail:** a fresh empty tree reads Integrated.

- Create one through a team request with `--worktree`.
- A pane inside it; the pane row shows path, branch and base.
- Merge preview against main — conflicts predicted, nothing mutated.
- Finish… on a row: each destructive step separately confirmed; removal
  refuses with a live pane inside, then succeeds once closed.
- Board: every row in the Worktrees window shows owner, base, HEAD, changed
  paths, ahead/behind the primary and a state. With the team active the row
  reads IN USE; after Stop with no pane inside it reads IDLE (commits ahead)
  or INTEGRATED, as the facts say. A count Git could not read shows as
  unknown, never as 0.
- Manager: with every pane closed, **Tools › Worktrees…** opens and lists the
  repositories of your favourites and recent folders; **Add Repository…**
  accepts a repository folder and refuses a plain folder with Git's reason;
  the added one survives a relaunch and **Forget** removes only it. Select a
  repository: every registered worktree is a row, the primary first and
  never removable, an unrecorded tree reads "Not recorded", a prunable
  entry reads STALE. Close the window: no facts are read until it reopens.
- Manager actions: on an unrecorded linked tree press **Remove…**; the
  preview opens without a tracking step and the tree is removed with its
  branch kept; the result offers **Delete Branch…**, which deletes a merged
  branch and shows Git's refusal for an unmerged one. Delete a worktree's
  folder with Finder, refresh: the row reads STALE with **Prune…**; Prune
  lists every prunable entry and forgets them, then offers **Delete
  Branch…** for the branches they held; a merged one is deleted after its
  own confirmation. **Integrate…** on an unrecorded tree opens the same
  "Proposed by you" preview. **Predict…** on a row with a known conflict
  says so and lists the paths; on a clean branch it offers Integrate….
  **Remove integrated and unused…** with two integrated
  trees and one dirty tree: the dirty tree reads IDLE and is not a
  candidate; the single preview lists the two with their checks (a tree
  that reads INTEGRATED but fails its fresh check, say a pane opened inside
  it meanwhile, is listed as skipped with the reason); confirming removes
  the two, the report names each, and the branch step is offered for both. **Fail:** any -D or --force in a run, a folder
  deleted by Prune, or a branch deleted without its own confirmation.
- Unrecorded tree: make a worktree with Git yourself, then **Remove…** on its
  row. The preview says Parley did not create it and is
  using Git's registry entry at the recorded path; a dirty or unmerged
  tracked tree is refused like any other; a clean, integrated one is removed
  with its branch kept. INTEGRATED rows show **Integrate…** disabled.
- Integrate…: commit in the tree, press **Integrate…**. The Requested
  command runs sheet opens on a run headed "Proposed by you" with the exact
  `git merge --no-ff --no-edit --end-of-options <branch>` argv and the primary
  checkout as folder, and no session-trust toggle. Approve; a new Shell pane
  runs it and the captured result appears. Reopen the browser: the row reads
  INTEGRATED and removal now passes. With **Approve agent command runs
  automatically** on, the proposal still waits for the preview. **Fail:** the
  run starts without the preview, the row claims Integrated before the merge,
  or a second Integrate… is accepted while the first is waiting.

## P3.5 Recipes

- Run the **Review and correct** recipe; confirm it requires two explicit
  non-lead targets from different vendors and refuses a single or same-vendor
  selection.
- Confirm it is a prompt template only — no state, no automatic transitions.

## P3.6 Settings and updates

- Settings → General → Swift package builds: opt in, confirm it applies to a
  newly started pane only.
- Settings → Terminal → Terminal type: the choice survives quitting and
  relaunching Parley, and Development and Production keep separate choices.
- Production: check for updates manually. Confirm no background install and
  that quitting goes through the pane-aware confirmation.
- Compatibility & Releases: press Check with Beta selected and switch to
  Stable before it finishes. **Fail:** a Beta release appears under Stable.
  Done (or Escape) closes the sheet.
- Open a permission guide link twice (a handoff needing permission, Open
  Permission Guide), choosing another Help topic in between: the second opens
  the guide again. Then open Help from the menu: it does not jump to it.
- Development: confirm Sparkle never runs and **DEV** is visible everywhere.

## P3.7 Isolation and uninstall

- Run Production and Development together; confirm separate state, separate
  panes, separate history.
- Prepare to Uninstall: confirm what it removes before doing it on a scratch
  setup only.

---

# After the pass

Note for each area: pass, fail, or not reached. A scenario not reached is more
useful information than one marked pass without being run.

If nothing fails, the honest position is not "it is finished" — it is that the
app does what it claims for the paths above. Notarization, automatic updates and
packaged-app UI automation remain open regardless of how this pass goes.

## Voice acceptance — packaged app, real microphone and speakers

Record the app commit/build, runtime, macOS version, hardware, language and
whether Apple's local model was already installed. These checks are manual;
`--only voice` covers synthetic state and transport behavior, not microphone
consent or audible output. Run on supported macOS 26 hardware for en-GB and
en-US and on macOS 14/15 where local recognition is available. Unsupported
configurations must refuse clearly. Never interpret an unavailable model as a
successful dictation test.

1. **Setup and denial.** In Settings > Voice, select a language and check
   support. A missing macOS 26 model offers an explicit download; cancel the
   request, check the Apple-managed download state, retry and verify the
   installed status. Disconnect the network after setup.
   Start dictation, deny microphone consent and confirm no capture or delivery.
   Grant it in macOS Privacy & Security and retry. Test Speech Recognition
   denial too on the older backend. Use a dedicated test app identity or
   explicitly reset only its consent; do not reset system-wide permissions.
2. **Start, stop and consent race.** Click Dictate (or hold
   Control-Shift-Space), then click it again (or release the keys) while
   preparation/consent is pending, then grant permission: no late recording
   may begin. Click Dictate, dictate a short sentence without holding
   anything, click Stop and confirm the microphone indicator ends. Repeat with
   keyboard release, release of a modifier before Space, window close/app
   deactivation and the 60-second limit. Test device disconnection and consent
   revocation during recording: show an error, stop capture, retain any partial
   transcript, and allow retry after recovery.
3. **Edit and target.** Correct the transcript by keyboard. No keystroke may
   reach the terminal behind it. Dictate again and confirm edits are retained.
   Switch the active pane: the named destination must remain unchanged. Paste
   must not press Enter; Send must. Discard before either must deliver nothing.
   Send to a Copilot pane whose folder trust is not confirmed: the draft stays
   open with the trust message and can be sent after confirming. **Fail:** it
   reads "Check delivery in the pane" and offers only copy or discard.
   Close, move, restart or change the reviewed folder of the bound pane before
   sending; refuse until explicit reselection. Exercise Copilot without its
   native folder-trust confirmation; Voice must not bypass it.
4. **Handoffs.** Create both an Ask draft and a Delegate draft. Check source
   and target pane/vendor/workspace, edit the text and cancel once with no
   handoff. Send deliberately, confirm normal history/correlation and a
   returned result. Restart either participant while the composer is open and
   verify refusal. Never use a live paid vendor as an ordinary automated test.
5. **Playback.** Confirm read-aloud starts disabled. Opt in, select a short
   real terminal passage and choose Voice > Read Selection. Listen for the
   selected words only. Read an explicitly returned Ask and Delegate result.
   Queue three items, refuse a fourth, remove a waiting item and stop/clear
   during speech. Hide the main workbench window and confirm these controls,
   the enable/settings link and playback errors remain visible beside Read
   Result in Status Center. Start capture during playback and playback during capture;
   both conflicts must refuse. The microphone must never pick up the output.
6. **Accessibility and retention.** With full keyboard access and VoiceOver,
   activate Dictate to start/stop and reach the transcript, Copy, Discard,
   destination, Paste/Send and playback controls. Control-Option-Space must
   retain its VoiceOver function. Quit and relaunch: there must be no retained
   voice draft or speech queue. Inspect only the app's ordinary history for
   explicitly sent handoffs; no audio recording files should have been added.

Record failures and untested configurations explicitly before a release.
