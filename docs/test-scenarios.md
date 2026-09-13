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

1. Start a Claude container pane and a Codex container pane.
2. Sign each in. Claude: paste-code flow. Codex: either device code (no
   port) or, with **Published port** set to 1455 in the container review,
   browser sign-in — the callback must complete on the Mac.
3. Confirm protocol uptake (`parley whoami`, protocol 32) fresh and resumed.
4. Send an Ask and a Delegate between a container pane and a host pane.
5. Check normal permission prompts appear (unless you chose bypass — then the
   pane badge and review must say so).
6. Close and restart the pane. **Login must persist.**
7. Quit Parley entirely, relaunch, start the pane again. Login still persists.
8. Status Center → Health → Containers: confirm the records make sense.

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

---

# Priority 2 — core functions

## P2.1 Pane lifecycle

- Create shell pane; create agent pane; both reach a prompt.
- Close a pane — its process ends (check Status Center → Health).
- Restart a pane — new launch generation, old session not claimed to survive.
- Move a pane to another workspace — surface, scrollback and process preserved.
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

- New Workspace creates a folderless container; it is a valid state.
- Attach two or more folders; both appear; search covers them.
- Remove a folder attachment while a pane is live in it — the pane is unchanged.
- `parley open <folder>` from a shell: focuses one match, asks on several,
  creates a shell workspace on none.
- Open a folder from Finder — same behaviour.
- A folderless shell pane gets a safe cwd and does not silently attach it.
- Delete a folder that appears under Recent in the New Pane Folder menu, then
  open the menu: it is no longer offered. **Manage Folders…** lists favourites
  and recents with full paths, marks a deleted one MISSING with Use disabled,
  and Remove forgets it; **Clear Recent Folders** empties the history.
  **Fail:** a deleted folder is still offered, or removing an entry touches
  anything on disk.

## P2.3 Relay, Paste, Ask, Delegate

- `parley relay` — arrives and submits immediately.
- `parley paste` — arrives **without** Enter; you can edit before sending.
- `parley ask` — blocks, returns the exact answer.
- `parley ask-many` with two targets — independent answers, neither sees the other.
- `parley delegate` — returns an id immediately, does not block.
- `parley progress current "..."` — note appears in Status Center, labelled
  AGENT-DECLARED.
- `parley done current "..."` and `parley fail current "..."` — recorded correctly.
- `parley done current --file <path>` — stages for review, does **not** forward.
- `parley status`, `parley wait <id>`, `parley cancel <id>`.
- Refusals: same pane, a shell target, an ambiguous vendor name, a busy target.

## P2.4 Discovery and protocol

- `parley whoami`, `parley panes`, `parley events --since beginning`.
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
  Vendor Enforcement says network is enabled in Codex's sandbox; for Claude,
  Agy and Copilot it says only Codex can carry the rule.
  **Fail:** the network command escalates on Flexible + network, or a
  non-Codex review claims to enforce network.
- Codex review, Approvals section: a line states what your own Codex config
  sets for `approvals_reviewer` (orange when it is `auto_review`, since that
  overrides the choice), or that it sets none.
  **Fail:** the line never appears, or says nothing when the config has it.
- **Approvals → Vendor's automatic reviewer** on a Claude pane (auto mode) and
  a Codex pane (auto review): a routine command such as `ls` runs with no
  prompt; a destructive one such as `git push --force` is refused or asked.
  On an Agy pane the picker is disabled and the review says Agy has no
  reviewer. Vendor Enforcement names the mode.
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
  not unattended, by design. Container bypass exists for Claude and Codex only.
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

## P3.4 Managed worktrees

- Create one through a team request with `--worktree`.
- A pane inside it; the pane row shows path, branch and base.
- Merge preview against main — conflicts predicted, nothing mutated.
- Finish & Cleanup: each destructive step separately confirmed; removal refuses
  with a live pane inside, then succeeds once closed.

## P3.5 Recipes

- Run the **Review and correct** recipe; confirm it requires two explicit
  non-lead targets from different vendors and refuses a single or same-vendor
  selection.
- Confirm it is a prompt template only — no state, no automatic transitions.

## P3.6 Settings and updates

- Settings → General → Swift package builds: opt in, confirm it applies to a
  newly started pane only.
- Production: check for updates manually. Confirm no background install and
  that quitting goes through the pane-aware confirmation.
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
