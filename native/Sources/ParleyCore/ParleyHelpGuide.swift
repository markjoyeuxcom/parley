import Foundation

public struct ParleyHelpCommand: Equatable, Sendable {
    public let command: String
    public let explanation: String

    public init(_ command: String, _ explanation: String) {
        self.command = command
        self.explanation = explanation
    }
}

public struct ParleyHelpSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let paragraphs: [String]
    public let items: [String]
    public let commands: [ParleyHelpCommand]

    public init(
        id: String,
        title: String,
        paragraphs: [String] = [],
        items: [String] = [],
        commands: [ParleyHelpCommand] = []
    ) {
        self.id = id
        self.title = title
        self.paragraphs = paragraphs
        self.items = items
        self.commands = commands
    }

    fileprivate var searchableText: String {
        ([title] + paragraphs + items + commands.flatMap { [$0.command, $0.explanation] })
            .joined(separator: "\n")
    }
}

public struct ParleyHelpTopic: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbol: String
    public let sections: [ParleyHelpSection]

    public init(
        id: String,
        title: String,
        summary: String,
        symbol: String,
        sections: [ParleyHelpSection]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.symbol = symbol
        self.sections = sections
    }

    public var searchableText: String {
        ([title, summary] + sections.map(\.searchableText)).joined(separator: "\n")
    }
}

/// The local guide shown by Parley's Help menu. Keeping the product vocabulary
/// in the core makes command coverage deterministic and prevents the UI from
/// drifting away from the protocol every agent pane receives.
public enum ParleyHelpGuide {
    public static let topics: [ParleyHelpTopic] = [
        ParleyHelpTopic(
            id: "start",
            title: "Start here",
            summary: "Use several subscription CLIs in one native workbench and move work between vendors without copy and paste.",
            symbol: "sparkles.rectangle.stack",
            sections: [
                ParleyHelpSection(
                    id: "start-purpose",
                    title: "What Parley does",
                    paragraphs: [
                        "Parley is a local-first macOS workbench for the Claude Code, Codex, Agy and GitHub Copilot CLIs already signed in on this Mac. Each pane is a real interactive CLI or shell; Parley does not replace the vendor session.",
                        "Its distinctive job is cross-vendor handoff: ask one agent to review another, compare independent opinions, or let a marked workspace lead supervise a sequence of work.",
                    ],
                    items: [
                        "No API keys, hosted Parley account, remote sync or telemetry.",
                        "Agent output and handoff history stay on this Mac.",
                        "Vendor permission and trust prompts remain under your control.",
                    ]
                ),
                ParleyHelpSection(
                    id: "start-first-flow",
                    title: "A useful first workflow",
                    items: [
                        "Open one Claude pane and one Codex, Agy or Copilot pane in the same workspace.",
                        "Work normally in either CLI. Use Ask when you want a correlated answer returned to the current agent turn.",
                        "Mark one agent as Workspace Lead and run Plan Review when you want that agent to judge another vendor's advice and continue.",
                        "Open Status Center when you need the durable history, a pending answer, retry guidance or cancellation controls.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "workspaces",
            title: "Workspaces and panes",
            summary: "Organise several folders without pretending every pane belongs to one repository.",
            symbol: "rectangle.3.group",
            sections: [
                ParleyHelpSection(
                    id: "workspaces-folders",
                    title: "Folderless workspaces, attachments and pane folders",
                    paragraphs: [
                        "A workspace is a named collaboration container, not a repository identity. New Workspace creates one with no attached folders. Open Folder is the folder-first navigation path. Every pane owns its live working directory.",
                    ],
                    items: [
                        "Attach zero, one or several folders for opening and search. Attachment order is presentation metadata; attaching, moving or removing one never changes a pane or grants filesystem permission.",
                        "Split Right and Split Below use the optional New Pane Folder. When it is clear, shells follow the active pane and a new agent asks for an explicit working folder.",
                        "When the active pane has moved elsewhere, Split Right Here and Split Below Here explicitly use that pane's current folder.",
                        "Changing the New Pane Folder does not move or restart running panes.",
                        "Several task workspaces may attach one folder. Opening that folder presents a chooser instead of guessing; Open New Workspace Here deliberately creates another.",
                        "A folderless team leaves agent panes as stopped placeholders without permission roots. Start asks for the pane folder and then shows the normal permission review.",
                        "Use the plus beside Favourite Folders to bookmark a repository without changing the active workspace. A row shows whether it will create, focus or choose among matching workspaces.",
                        "Cross-workspace handoffs work; qualify an ambiguous target as workspace/pane.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-pane-focus-copy",
                    title: "Pane focus, selection and scrollback",
                    paragraphs: [
                        "The left sidebar is Parley's rich pane navigator: it keeps status, permissions, recovery actions and context menus visible. When you hide the sidebar, a compact pane focus strip remains above the terminals. Every visible leaf has a clear border, and the selected leaf uses the app accent. Clicking a leaf or its focus-strip item makes that exact pane authoritative for typing and actions.",
                        "Each pane row shows its exact working directory and fixed-argument Git branch snapshot. A throttled process inspection may add bounded LISTEN ports only after Parley attributes the owning process tree to that Ghostty pane. The final fact is the latest authoritative attention reason from an official vendor hook or durable handoff. None of these facts comes from terminal scraping.",
                        "SwiftUI owns the visible split tree and each leaf is one retained Ghostty surface. Ghostty owns the real PTY, process, vendor TUI, selection, scrollback and terminal state; Parley's app-resident coordination core owns relay delivery.",
                        "Hiding or closing the main window does not destroy its terminal surfaces. Quitting Parley is the explicit lifetime boundary and ends every pane process and the coordination core.",
                    ],
                    items: [
                        "Normal dragging selects text in the native terminal even when a mouse-aware vendor TUI is active. Releasing a selection copies it to the macOS clipboard.",
                        "Ghostty handles mouse reporting, selection, copy and scrollback directly. Parley does not place another terminal multiplexer between the mouse and the vendor TUI.",
                        "Ghostty retains authoritative terminal modes and scrollback while a leaf is hidden and restores the same surface when it reattaches.",
                        "Moving keyboard focus between leaves does not send DEC focus-out to a background agent. Safe relay readiness stays independent from which leaf receives the person's typing.",
                        "Native divider positions currently reopen balanced; Balance Panes rebuilds an even native split tree.",
                        "The pane focus strip is navigation, not hidden tabs: every leaf remains a real interactive process.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-canvas-dock",
                    title: "Focus Canvas and the Collaboration Dock",
                    paragraphs: [
                        "Use Focus in the workbench toolbar, Navigate > Enter Focus Canvas, or Command-Shift-F to enlarge the selected pane while keeping peers visible. Grid or Return to Pane Grid restores the persisted split proportions. These actions keep the same terminal processes and sessions.",
                        "Navigate > Show Collaboration Dock (Command-Shift-D) opens the side panel for the current workspace’s waiting work, active handoffs, recipes and recent results. It offers a route to Status Center for the full record. Hide Collaboration Dock with the same shortcut to recover the space.",
                        "Command-1…9 focuses an existing pane by its position in the current workspace. Command-Option-T returns keyboard focus to the active terminal. Command-Shift-T opens Task Manager; it does not create a terminal.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-worktrees",
                    title: "Existing Git worktrees",
                    paragraphs: [
                        "Git worktrees are parallel filesystem locations, not Parley workspaces or agents. From the Workspace menu, Open Worktree… reads git worktree list --porcelain without a shell and lets you open one of that repository's existing directories as an ordinary workspace.",
                        "Parley can also create one worktree per feature for a team. Team Session approval offers a new worktree (new branch from a base ref you preview) or an existing one; the worktree browser has the same New Worktree action. Creation is one fixed git worktree add under <repository>/.worktrees/, run natively after your approval and never by an agent. The base is recorded as the exact commit the tree was created from and shown on panes, in Team Sessions and beside a delegation's Git facts. A tree you selected rather than created stays person-owned: Parley records no base and never removes it.",
                        ManagedWorktreeService.CreatePreview.executionNotice,
                        "Removing a Parley-created worktree is a person action in the browser. Parley reads Git again and refuses when the tree contains another registered worktree, when any pane's folder (this runtime's or the other Production/Development runtime's) is inside it, when Git status shows modified or untracked files, when commits are ahead of the upstream's local remote-tracking state or, without an upstream, not contained in the primary worktree's HEAD, when the tree is locked or prunable, or when any of these could not be read. Every ignored entry Git would delete with the folder is listed in full for you to acknowledge (a directory entry means its whole contents); more than 200 refuses. While the removal runs, no pane can start or be created inside the tree. The removal is a single git worktree remove without --force, and the result reports what Git's registry and the filesystem show afterwards: removed, not removed, or uncertain. A tree that already vanished only clears Parley's record. The branch, objects, refs and stashes remain.",
                        "A worktree's shared .git directory lies outside the pane folder. Parley grants no extra permission root for it; whether a vendor CLI may commit, switch or push from the worktree is that vendor's own permission decision and may need its approval or fail. Parley makes no claim that commits need no vendor approval.",
                        "Parley warns when two running agent panes point at the same exact canonical worktree and both have visible permission profiles that explicitly allow project writes. The warning is permission evidence only: Parley does not claim either process changed a file, and a quiet terminal never proves concurrent work is safe.",
                    ],
                    items: [
                        "The list shows the repository, branch or detached commit identity, primary or linked worktree status, exact path, and Git's locked or prunable state.",
                        "Linked worktrees share objects, refs, the stash stack, hooks and configuration with the repository; only HEAD, the index and the working files are separate. Parley never claims isolation beyond that.",
                        "Ordinary folders remain supported. Parley never requires one worktree per agent or silently creates one, and a worktree created for a team must lie inside the requesting pane's working folder.",
                        "Parley never commits, merges, rebases, pushes, stashes, forces or deletes a branch. Everything beyond one approved add or remove stays in your terminal.",
                        "A shared worktree can be intentional—for example, one vendor implements while another reviews the same uncommitted files. Decide whether simultaneous write permission is appropriate for that workflow.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-layouts",
                    title: "Saved layouts",
                    paragraphs: [
                        "A saved layout remembers the split shape, pane kind, pane name, folder, workspace lead and automation policy. It never stores a live process or terminal-surface id.",
                    ],
                    items: [
                        "Restoring a layout starts shell panes automatically.",
                        "Agent panes restore as placeholders. Press Start yourself so reopening Parley never spends a subscription session unexpectedly.",
                        "Opening a layout over live panes asks before replacing them.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-teams",
                    title: "Portable team templates",
                    paragraphs: [
                        "A team template is a reusable blueprint for pane vendors, names, routing roles, permission profiles, workspace lead, automation policy and split layout. Unlike a saved layout, it contains no repository paths or permission roots.",
                        "Save the current configured grid as a team with Save Current as Team Template… in the Workspace menu or Save as Team Template… in a workspace's context menu; the workspace plus menu applies one under From Team Template. Applying a team asks for a folder and binds every pane plus its permission scope to that chosen folder.",
                    ],
                    items: [
                        "Agent panes are created as stopped placeholders. Start each vendor session deliberately.",
                        "Shell panes may start automatically because they do not spend a model subscription session.",
                        "Live pane ids, credentials, terminal history and vendor sessions are never part of a template.",
                        "Deleting a template never changes a workspace already created from it.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-roles",
                    title: "Stable routing roles",
                    paragraphs: [
                        "A routing role such as implementer, reviewer or tester is an optional workspace-scoped address for one agent pane. It is separate from the display name, so renaming a pane does not change how another agent reaches its role.",
                    ],
                    items: [
                        "Set or clear a role from the agent pane's context menu. Roles use lowercase letters, numbers and hyphens.",
                        "A role must be unique inside its workspace. Parley refuses ambiguity rather than silently choosing another live pane.",
                        "Use @reviewer in the same workspace or workspace/@reviewer across workspaces. The @ keeps a stable role separate from mutable pane names.",
                        "lead remains the special address for the explicitly marked Workspace Lead. Vendor names and lead are reserved and cannot be assigned as ordinary roles.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-mobility",
                    title: "Move or clone a pane",
                    paragraphs: [
                        "Right-click a pane and choose Move to Workspace to transfer the exact retained Ghostty surface, or Clone Configuration to Workspace to create a separate pane with the same visible setup. Every action names its destination and shows its process, folder and handoff consequences before it runs.",
                    ],
                    items: [
                        "Move preserves the pane id, running process and vendor session, scrollback, terminal state and pane-local folder. The destination workspace's automation policy applies after the move.",
                        "Parley refuses to move the last pane out of a workspace or a pane participating in active handoffs. It also refuses a destination with the same routing role or a second Workspace Lead.",
                        "Clone leaves the source process and all its handoffs unchanged. It copies vendor, name, folder, permission profile, routing role and lead stamp, but never terminal history, a vendor session or a pane credential.",
                        "An agent clone is a stopped placeholder until you press Start. A cloned shell starts normally.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-safety-summary",
                    title: "Safety summary before disruptive actions",
                    paragraphs: [
                        "Before closing a workspace, replacing it with a saved layout, or moving a pane between workspaces, Parley shows a content-free summary of the affected workspace state. Read it before approving the action; it is evidence for a human decision, not an automatic safety verdict.",
                    ],
                    items: [
                        "Running agents come from processes Parley launched into retained Ghostty surfaces. Stopped placeholders and shell panes are not described as running agents.",
                        "Active handoffs come from the coordination core. If the core is disconnected, the summary says that handoff state is unavailable instead of claiming there are none.",
                        "Dirty repositories come from bounded Git status snapshots and are deduplicated by exact discovered worktree path. A missing snapshot is shown as unavailable, not clean.",
                        "Shared-worktree writers come from exact canonical worktree paths plus visible write-capable permission profiles. Parley does not infer whether an agent is thinking or which process changed a file.",
                        "Prompt bodies, answers and terminal content never enter the safety summary.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-external-open",
                    title: "Open from Terminal or Finder",
                    paragraphs: [
                        "The installed app exposes three person-controlled doors to the same operation: parley open <folder> in Terminal, Open in Parley from Finder's Services menu, and parley://open?folder=<encoded-absolute-folder> for local integrations.",
                        "Each door validates one existing local directory and brings Parley forward. It focuses one matching workspace, asks you to choose when several task workspaces share that home, or creates a workspace containing its ordinary shell when none exists. It cannot carry a prompt, choose an agent or submit work.",
                    ],
                    items: [
                        "The Finder Open With menu also offers Parley for folders. Parley registers as an alternate handler, never the system's default folder viewer.",
                        "parley open is person-only and is refused inside an authenticated agent pane.",
                        "The command and parley:// scheme target the installed Production app. Development remains isolated and does not claim the system-wide URL scheme.",
                        "Opening a workspace never starts a Claude, Codex, Agy or Copilot session. Start agent panes yourself.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley open /absolute/path/to/repository", "Open or focus that folder in the installed app."),
                        ParleyHelpCommand("open 'parley://open?folder=%2Fabsolute%2Fpath'", "Invoke the bounded local URL route from a trusted integration."),
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-pane-menu",
                    title: "Pane context menu",
                    items: [
                        "Rename a pane to give routing a memorable, unique name.",
                        "Make or remove a Workspace Lead.",
                        "Set or clear a stable workspace-scoped routing role.",
                        "Move the exact pane or clone only its visible configuration into another workspace.",
                        "Start Fresh Session and Restart Fresh Session never restore vendor history.",
                        "Resume asks Claude, Codex or Copilot to open its own saved-session picker. Agy instead attempts its documented most recent conversation for this pane's working directory.",
                        "Vendor-owned Resume keeps the pane folder and repeats permission review, but Parley cannot guarantee that a previous conversation resumes. Status Center records RESUME REQUESTED rather than claiming restoration.",
                        "An exited process remains visible with its final scrollback until you close, start fresh or ask the vendor to resume it.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "handoffs",
            title: "Ask, Relay and Paste",
            summary: "Choose whether text is correlated, immediately submitted, or left as an editable draft.",
            symbol: "arrow.left.arrow.right",
            sections: [
                ParleyHelpSection(
                    id: "handoffs-agent-awareness",
                    title: "Recover Parley's instructions in any project",
                    paragraphs: [
                        "Parley supplies one canonical protocol at agent launch, independently of the project folder. Help and protocol are local reference commands; they do not contact the broker, grant permissions or prove that a model absorbed the instructions.",
                        "Every agent gets PARLEY_COMMAND for an absolute-path fallback if its shell rebuilds PATH. Vendor tool approval still applies. A pane marked RESTART FOR PROTOCOL needs an explicit restart to receive changed launch instructions.",
                        "Agy is passed the generated instructions directory, but automatic loading from an added directory remains unverified. If its instructions are missing, ask it to run parley protocol. A fresh/resumed-session smoke check is required before claiming uptake.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley help", "Show the complete command index, including reviewed context, progress and result files."),
                        ParleyHelpCommand("parley protocol", "Read the exact canonical launch instructions and the map of native-only controls."),
                        ParleyHelpCommand("\"$PARLEY_COMMAND\" protocol", "Reach the same runtime-local command when PATH has been rebuilt."),
                    ]
                ),
                ParleyHelpSection(
                    id: "handoffs-discovery",
                    title: "Discover identity, panes and events",
                    paragraphs: [
                        "The managed command authenticates from the calling pane's capability. These read-only commands cannot choose another sender, inject input, start a pane or control a vendor.",
                    ],
                    items: [
                        "Whoami returns this pane's id, vendor, workspace, canonical role, lead flag and app-owned lifecycle facts. It never returns a credential, folder, command, prompt or terminal text.",
                        "Panes returns at most 128 explicit non-self agent targets. Running, stopped, exited, protocol-restart, relay and Ghostty input-path fields report only facts Parley owns; they do not claim a vendor is thinking, idle or ready at its prompt.",
                        "Events returns at most 100 monotonically ordered handoff transitions and native activity records. It omits question, result, terminal and activity-detail content.",
                        "Begin with beginning to replay retained events or now to start at the current edge. Continue with nextCursor while hasMore is true. A cursor removed by retention fails explicitly instead of silently skipping records.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley whoami", "Show the authenticated identity of this exact agent pane as JSON."),
                        ParleyHelpCommand("parley panes", "List bounded explicit agent targets and authoritative lifecycle facts as JSON."),
                        ParleyHelpCommand("parley events --since beginning", "Read the first bounded page of retained content-minimal coordination events."),
                    ]
                ),
                ParleyHelpSection(
                    id: "handoffs-difference",
                    title: "The important difference",
                    items: [
                        "Ask is for a focused question likely to finish within one minute. It submits, blocks the requesting command and returns the exact correlated answer to that same turn.",
                        "After submission, Ask prints its handoff id on stderr. If the calling shell disconnects, parley wait with that explicit id recovers the durable answer only from the same still-running source pane generation.",
                        "Relay submits one attributed message immediately but does not wait for a correlated result.",
                        "Paste places an attributed draft in the target prompt without Enter, so you can inspect or edit it first.",
                        "The native menus let you preview and edit captured text before it crosses to another pane.",
                        "When the exact target pane has a supported authenticated vendor hook report, the reviewed composer shows TARGET SIGNAL with its pane and vendor hook provenance, reported state, official event and live age.",
                        "TARGET SIGNAL is ADVISORY ONLY: it neither blocks nor authorizes Send. A missing strip means no supported official target signal was reported; Parley never fills that gap from terminal text or timing.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley ask codex \"Review this plan and return your concerns.\"", "Submit a focused correlated question, print its recovery id on stderr and wait for Codex's exact answer."),
                        ParleyHelpCommand("parley answer current \"The reviewed answer\"", "Return an answer from the receiving pane to its one waiting Ask."),
                        ParleyHelpCommand("parley relay claude \"The build is ready for review.\"", "Submit an attributed one-way message now."),
                        ParleyHelpCommand("parley paste agy \"Please check this before I send it.\"", "Leave an attributed draft without submitting it."),
                    ]
                ),
                ParleyHelpSection(
                    id: "handoffs-routing",
                    title: "Naming the target",
                    paragraphs: [
                        "Use a unique pane name, an explicit stable role such as @reviewer, vendor name or pane id. A renamed pane is addressed by its new display name while its routing role remains unchanged. The special name lead resolves to the marked lead in the sender's workspace.",
                    ],
                    items: [
                        "Parley refuses ambiguous names instead of guessing.",
                        "Use workspace/pane to disambiguate a pane in another workspace.",
                        "The target must be another agent pane. Same-vendor routes are supported; a pane cannot target itself.",
                        "Shell panes can never receive automatic agent handoffs.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "coordination",
            title: "Compare and delegate",
            summary: "Fan questions out independently or track bounded work that completes later.",
            symbol: "point.3.connected.trianglepath.dotted",
            sections: [
                ParleyHelpSection(
                    id: "coordination-compare",
                    title: "Independent comparison",
                    paragraphs: [
                        "Ask Many sends the same question to explicit agent panes concurrently. They do not see one another's answers, so the result is independent evidence rather than a chain of agreement.",
                        "From an active agent pane, open Ask and choose Compare Independently. Select at least two other panes, review the exact question, then keep the comparison window open or reopen the last comparison from the same menu. The targets may use the same vendor.",
                    ],
                    items: [
                        "Returned answers appear in separate attributed cards. Failures remain visible and are never presented as answers.",
                        "Mark an agent pane in the source workspace as Workspace Lead before forwarding. Forward one answer or several selected answers through the normal editable preview.",
                        "Draft Synthesis opens an edited synthesis preview that preserves every attributed answer and leaves a blank Synthesis field for you to complete. Parley does not generate a consensus or conclusion.",
                        "Cancel Outstanding stops only the tracked waits that have not returned; it does not type Control-C into vendor panes.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley ask-many codex,agy \"Name the largest risk in this plan.\"", "Return one ordered, labelled JSON answer bundle after every named target finishes or times out."),
                    ]
                ),
                ParleyHelpSection(
                    id: "coordination-delegate",
                    title: "Tracked delegation",
                    paragraphs: [
                        "Delegate starts asynchronous agent-to-agent work and immediately returns a tracking id. Use it instead of Ask when work is likely to exceed one minute.",
                        "The receiving agent must report a terminal result through Parley; merely printing the result in its pane does not complete the tracking relationship.",
                        "A substantial UTF-8 result may be returned with `parley done current --file <path>`. The file must stay inside the target pane's working folder. Parley completes the delegation only after a bounded, agent-provided Context Pack draft is durable; it does not forward the file automatically.",
                        "Status Center and the Collaboration dock show three owned facts for each active or recently returned delegation: time since the recorded delivery, the age of the latest agent-declared progress note, and the age of the target pane's last authenticated hook signal. After ten minutes without a note or signal the row states No explicit update for 10 minutes as information only; nothing is inferred from silence.",
                        "Each delegation also records bounded Git facts about the target pane's working folder at delegation and again at done or fail: the HEAD revision, the branch or detached state, and up to 200 dirty paths, read with one fixed-argument git status and never file contents or diffs. The inspector and the Markdown export show N paths changed since delegated under the label shared worktree: not attribution, because other panes and the person edit the same tree. A non-Git folder records nothing, and a missing folder or failed read is informational only.",
                        "A returned file may follow the completion-evidence convention: plain Markdown with the ATX headings ## Implemented, ## Tested (each command and the outcome you observed) and ## Unable to test (with the reason), in any order. Status Center shows those sections as one COMPLETION EVIDENCE block labelled AGENT-DECLARED; unknown headings are ignored, the first occurrence of a duplicate heading wins, an empty recognised heading is shown as declaring nothing, and a file without the headings is shown exactly as before. Parley never runs a command to check a claim and stores no new schema. Copy the template below into the returned file:",
                    ],
                    items: CompletionEvidenceProjection.template.split(separator: "\n").map(String.init),
                    commands: [
                        ParleyHelpCommand("parley delegate codex \"Implement the reviewed fix and verify it.\"", "Assign one bounded task to another vendor."),
                        ParleyHelpCommand("parley status", "List work initiated by this pane as machine-readable JSON."),
                        ParleyHelpCommand("parley wait <id>", "Wait for one explicit delegation or recover a completed Ask from the same source pane generation."),
                        ParleyHelpCommand("parley wait current", "Wait only when exactly one delegation is active; current never selects a completed Ask."),
                        ParleyHelpCommand("parley progress current \"Parser checks are running.\"", "Replace the active delegation's one 200-byte agent-declared progress note; this does not complete the work."),
                        ParleyHelpCommand("parley done current \"Implemented; tests pass.\"", "Complete work from the delegated target pane."),
                        ParleyHelpCommand("parley done current --file reports/result.md", "Complete work with a substantial file staged for explicit human review."),
                        ParleyHelpCommand("parley fail current \"Blocked by a missing fixture.\"", "Return an explicit failed result from the delegated target pane."),
                        ParleyHelpCommand("parley cancel current", "Cancel only tracking initiated by this pane; the target CLI is not interrupted."),
                        ParleyHelpCommand("parley delegate claude --parent <handoff-id> \"Revise: add the recovery check.\"", "Request changes on a returned Delegate this pane initiated or received; Parley records one linked requestChanges child, never a verdict."),
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "context-model",
            title: "How context works",
            summary: "Choose the right scope for reusable guidance, workspace decisions, vendor conversation and one specific handoff.",
            symbol: "square.stack.3d.up",
            sections: [
                ParleyHelpSection(
                    id: "context-model-scopes",
                    title: "Five separate scopes",
                    paragraphs: [
                        "Parley keeps different kinds of context separate so a useful note does not silently become an instruction to every agent. The scope determines where material lives and whether it survives a window.",
                    ],
                    items: [
                        "Pinned Snippet — durable, application-wide reusable context such as architecture rules, test instructions and review criteria.",
                        "Workspace Brief — durable person-owned context for one live workspace: its current goal, constraints, decisions, investigation conclusions, rationale, confidence and open questions.",
                        "Vendor pane — the conversation and session history owned by that vendor CLI. Parley does not manufacture or merge this memory.",
                        "Context Pack — an ephemeral, editable bundle for one handoff. Files, diffs, terminal output and saved references enter as separately attributed snapshots.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-model-explicit",
                    title: "Nothing crosses automatically",
                    paragraphs: [
                        "A Workspace Brief or Pinned Snippet is never attached automatically. Saving either one does not contact an agent or alter any vendor session.",
                        "Adding saved context to a Context Pack creates an attributed snapshot. Edit that copy for the receiving vendor without changing its durable source, then inspect the complete pack before Ask or Compare submits it.",
                    ],
                    items: [
                        "A person-created pack can attach a brief or pinned snippets; an agent-staged draft cannot read either library. During review, a person can add a file, Git diff, current terminal selection or command result through Parley's own bounded capture path.",
                        "A pack includes only visible sources you deliberately add. Hidden terminal history and complete transcripts are not scraped.",
                        "Deleting or updating a saved reference never rewrites a snapshot already placed in a pack.",
                        "Context is evidence and instruction, not credential storage. Keep passwords, API keys and vendor tokens out of briefs and snippets.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-model-drafts",
                    title: "Draft lifetime",
                    paragraphs: [
                        "Parley currently keeps one active person-created Context Pack draft across the app. Creating another pack asks before replacing a non-empty draft, and closing Parley discards that person-created draft.",
                        "Agent-staged review checkpoints are different: they are owner-only durable records because a waiting pane must receive an explicit approval or refusal rather than lose its state when the UI closes.",
                    ],
                    items: [
                        "A draft remains anchored to the pane and folder from which it was created.",
                        "If that source pane is no longer ready, the pack remains inspectable but cannot be sent.",
                        "A future workspace-draft refinement will replace the current app-wide draft slot; this page describes the behavior available now.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-model-choose",
                    title: "Choose the smallest useful scope",
                    items: [
                        "Use a Workspace Brief for the current project goal, boundaries, decisions, investigation conclusions, rationale, person-authored confidence and open questions that should survive later handoffs.",
                        "Use a Pinned Snippet for guidance you expect to reuse across repositories or workspaces.",
                        "Use a Context Pack for the exact evidence and request another vendor needs for one implementation, review or comparison.",
                        "Continue in the same vendor pane when the new instruction depends on that CLI's existing conversation; start another pane when it does not.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-model-example",
                    title: "Example: implementation review",
                    items: [
                        "Maintain the feature goal and constraints in the Workspace Brief.",
                        "Keep the standard verification checklist as a Pinned Snippet.",
                        "From the implementer's pane, create a Context Pack and explicitly add the Workspace Brief, verification snippet and current Git diff.",
                        "Write the receiving pane's review request, inspect every attributed source, then use Ask One Pane or Compare Panes.",
                        "The receiving agent sees the snapshots in that handoff; other panes and later requests receive nothing unless you attach it again.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "context-packs",
            title: "Context packs",
            summary: "Assemble only the local evidence you choose, inspect its provenance and byte size, then send it through Ask or independent Compare.",
            symbol: "shippingbox",
            sections: [
                ParleyHelpSection(
                    id: "context-packs-build",
                    title: "Build an explicit pack",
                    paragraphs: [
                        "From a ready agent pane, open Context and choose New Context Pack. Add selected UTF-8 files, the source pane's current Git diff, a chosen pane's current terminal selection, a captured command result, that workspace's saved brief, or reusable pinned context.",
                        "Every source remains a separate editable part with its exact path or pane/command provenance, captured UTF-8 bytes, current UTF-8 bytes and an EDITED marker when the preview differs from the capture.",
                    ],
                    items: [
                        "Git capture uses read-only argv calls. Untracked files are named by status but their contents are never read implicitly.",
                        "Terminal context means only text the person selected in that exact pane. Hidden scrollback, another pane and the complete transcript are never scraped.",
                        "Command capture requires an absolute executable and treats each non-empty line as one literal argument. It never invokes a shell, expands variables, pipes or redirects.",
                        "Both command stdout and stderr plus the exit status are retained. Time and output bounds prevent a noisy process from creating an unbounded preview.",
                        "A pane agent can stage repository files with `parley context draft --name \"Review\" --file path`, append with `parley context add <draft> --file path`, and abandon its own draft with `parley context discard <draft>`. These files must remain under that pane's working folder and are visibly labelled agent-provided because Parley did not independently capture them.",
                        "A file returned through `parley done current --file <path>` follows the same agent-provided boundary and appears both in the Context menu and on its completed handoff. The person may edit or discard it, add separately captured trusted sources, or choose whether to send the reviewed pack. Its compact completion receipt is never substituted for the file.",
                        "While reviewing an agent draft, a person may add Files, Git Diff, Selection or Capture Command. The app-resident core performs that separate capture, labels its real provenance and retains the original bytes; the agent-provided parts remain claims.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-inspect",
                    title: "Inspect your agent-staged drafts",
                    paragraphs: [
                        "An agent can list and inspect its own staged drafts before asking with them or discarding them. Inspection does not approve a draft, change its agent-provided provenance or send it to another pane.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley context list", "List drafts owned by this agent pane."),
                        ParleyHelpCommand("parley context show <draft-id>", "Inspect one of this pane’s drafts by its exact id."),
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-send",
                    title: "Preview and send",
                    paragraphs: [
                        "Write the request for the receiving pane in the pack itself. Ask One Pane submits it through the usual attributed Ask path. Compare Panes gives the same rendered pack to at least two target panes independently and opens the comparison view for their separate answers.",
                    ],
                    items: [
                        "The live rendered byte total includes provenance, your request and wrapper text—not just source bodies.",
                        "An oversized source or pack stays visibly invalid and cannot be sent; Parley never silently clips the editable preview.",
                        "Person-created context packs remain local in-memory drafts. Agent-staged review records are owner-only and durable so closing the UI cannot silently approve or lose a waiting checkpoint. A workspace-brief attachment is a snapshot: editing it in the pack never rewrites the saved brief.",
                        "The Context menu lists every pending agent review separately. Discard Draft ends an unsubmitted staged draft; Decline Ask releases a pane already blocked in `ask --context`. Abandoned editable agent drafts are discarded after seven days so they cannot permanently consume the bounded review queue.",
                        "Returned delegation files retain their exact handoff lineage, canonical contained path and captured bytes. Opening one from Status Center is review, not delivery; nothing reaches another pane until the person selects a target and confirms the normal Context Pack send.",
                        "`parley ask <vendor> --context <draft> \"question\"` blocks at a visible human-review checkpoint. The Context menu shows the waiting draft; approval sends the edited pack and returns the correlated answer, while Decline submits nothing and releases the waiting pane with an explicit refusal.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-vendor-evidence",
                    title: "Add browser and tool evidence",
                    paragraphs: [
                        "Right-click an agent pane and choose Browser & Tool Capability for Parley's small per-pane summary. Unknown means exactly Unknown: a permission profile may record network intent, but terminal prose is not capability evidence and Parley does not infer browser access from a successful-looking answer.",
                        "In an editable Context Pack, choose Add Browser/Tool Evidence to add a credential-free HTTP or HTTPS URL, person-provided selected text, a browser screenshot or a saved tool artifact. Choose the exact vendor pane you are attributing it to and review the resulting provenance before Ask or Compare.",
                    ],
                    items: [
                        "Parley never opens or scrapes the vendor browser session and never reads browser profiles, cookies or website credentials.",
                        "URLs are shape-validated but not fetched or verified. Selected text stays an explicit person's capture rather than becoming a claim that Parley saw the page.",
                        "A local screenshot must be a readable image. Screenshots and saved artifacts are capped at 25 MB; Parley records the exact path, byte count and SHA-256 after inspecting the selected local bytes.",
                        "Binary bytes are not embedded in the text context pack. The receiving vendor must say when its own tools or granted filesystem scope cannot read the attributed path.",
                        "Every rendered evidence part stamps the vendor, pane, URL or artifact facts, capture basis and browser/tool capability state. Current adapters remain Unknown because none supplies a safe effective per-pane inspection that is credential-free, quota-free and configuration-free.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-workspace-brief",
                    title: "Maintain a workspace brief",
                    paragraphs: [
                        "Open Context and choose Create Workspace Brief or Edit Workspace Brief. Record the current goal, constraints and important decisions plus person-owned investigation conclusions, rationale, person-authored confidence and open questions for that live workspace. Empty investigation fields remain unrecorded; Parley never infers them. Saving is local and does not contact an agent.",
                        "A workspace brief is never attached automatically. Choose New Context Pack with Workspace Brief, or add it from an open pack, then inspect and edit the attributed snapshot before sending.",
                    ],
                    items: [
                        "Only a person-created context pack can attach the saved brief. An agent-staged draft cannot read or add it.",
                        "The saved file is owner-only local application data. Do not place vendor credentials, tokens or other secrets in it.",
                        "A pack carries the workspace name, identity and saved timestamp as provenance. Later brief edits do not rewrite packs already sent.",
                        "Deleting the saved brief does not alter an existing context-pack snapshot or contact any running pane.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-pinned-snippets",
                    title: "Reuse pinned snippets",
                    paragraphs: [
                        "Open Context and choose Manage Pinned Snippets to keep named architecture notes, test instructions and review criteria in one application-wide local library. Managing this library does not contact any agent.",
                        "From a person-created Context Pack, choose Add Pinned Snippets and select one or more entries. Each becomes a separately attributed editable snapshot; it is never attached automatically.",
                    ],
                    items: [
                        "Pinned names are unique without regard to case, and both names and contents have explicit local size bounds.",
                        "An agent-staged context draft cannot read or attach the person's pinned library.",
                        "Editing or removing a pack snapshot never changes its reusable source. Updating or deleting the saved snippet never rewrites an existing pack.",
                        "The owner-only library is not a credential vault. Do not store API keys, vendor tokens, passwords or other secrets in snippets.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "lead",
            title: "Workspace Lead and recipes",
            summary: "Let one agent supervise explicit cross-vendor work while you retain the visible controls.",
            symbol: "person.crop.square.badge.checkmark",
            sections: [
                ParleyHelpSection(
                    id: "lead-mark",
                    title: "Mark the lead",
                    paragraphs: [
                        "Right-click a running agent pane in the sidebar and choose Make Workspace Lead. A workspace has at most one lead, shown with a LEAD badge. The role is routing metadata, not extra filesystem or process authority.",
                    ],
                    items: [
                        "Other agents in that workspace can address it as lead.",
                        "The lead stamp survives saved layouts, while live pane ids do not.",
                        "Changing the lead does not restart either agent.",
                    ]
                ),
                ParleyHelpSection(
                    id: "lead-recipes",
                    title: "Run a recipe",
                    paragraphs: [
                        "Open Recipes in the toolbar, choose Plan Review, Implementation Review, Adversarial Bug Hunt, Compare Recommendations or Review and Correct, select explicit targets, then review the final instruction before Run with Lead.",
                        "A recipe sends one visible instruction to the lead. The lead remains responsible for judging advice and deciding what to adopt; Parley supplies transport and records activity.",
                        "Review and Correct is a prompt template only. It guides the lead through the practice Delegate → milestone Progress → returned Result → review by a different vendor → linked Request Changes → independent verification, and asks the implementer for the completion-evidence headings ## Implemented, ## Tested and ## Unable to test. The practice is guidance, not a required sequence: nothing moves on its own, no phase or workflow record is kept, and every returned note, evidence section and review remains an agent-declared claim for the lead and the person to judge.",
                    ],
                    items: [
                        "Edit Recipes changes the reusable local instruction text. Keep {{targets}} in each template.",
                        "Stop asks for confirmation, then sends Control-C only to the lead's current turn.",
                        "Stopping the lead does not cancel tracked work it already delegated. Cancel those items separately in Status Center.",
                    ]
                ),
                ParleyHelpSection(
                    id: "lead-policy",
                    title: "Automation policy",
                    paragraphs: [
                        "Each workspace tab shows its automation policy. The broker enforces it before every agent-initiated dispatch.",
                    ],
                    items: [
                        "Off blocks automatic Relay, Ask and Delegate. Paste remains a non-submitted draft.",
                        "Ask/Answer permits Relay and correlated consultation but not tracked delegation.",
                        "Ask + Delegation permits all agent coordination commands.",
                        "Native controls remain human controls; agents cannot silently raise the policy themselves.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "settings",
            title: "Settings and appearance",
            summary: "Adjust terminal appearance and agent lifecycle, and understand which window choices are kept.",
            symbol: "gearshape",
            sections: [
                ParleyHelpSection(
                    id: "settings-appearance",
                    title: "Terminal fonts and Ghostty appearance",
                    paragraphs: [
                        "Open Settings > Appearance. Choose an explicit font family or leave the family at Parley Default (or Imported when an import supplies it). Enable the font size Override to choose a size; turn Override off to inherit it. Your explicit font choices take precedence over imported values.",
                        "Import… reads the supported Ghostty configuration and theme locations into an appearance preview. Refresh… rereads those locations when an import already exists. Remove clears the staged import. Only appearance values are imported: font family, font size, theme, palette and colours. Commands, keybindings, shell integration, config-file includes and other behavioural settings are not imported.",
                        "Apply saves your staged font and import choices and updates existing terminal surfaces without restarting running sessions; new panes use the same appearance. Import, Refresh and Remove need Apply before they take effect. Restore Parley Defaults applies immediately: it clears both explicit font overrides and imported appearance.",
                        "Closing Settings discards unapplied appearance edits. Saved settings are retained. General switches take effect when changed; they do not wait for the Appearance Apply button.",
                    ]
                ),
                ParleyHelpSection(
                    id: "settings-idle-agents",
                    title: "Idle agent reaping",
                    paragraphs: [
                        "Settings > General > Agent lifecycle offers Reap idle agents after 30 minutes, off by default. The same switch appears in Tools. When enabled, it can stop a background agent after at least 30 minutes without recorded pane activity. It never reaps the selected pane, a workspace lead, Shell panes or a pane in a live Ask or Delegate.",
                        "Reaping leaves a visible stopped slot; it does not close the pane and does not automatically resume a vendor session. You choose when to start it again. Recorded silence is not proof that a vendor finished: quiet, untracked vendor work may be interrupted, so keep this off when that work needs to continue unattended.",
                    ]
                ),
                ParleyHelpSection(
                    id: "settings-other",
                    title: "Other Settings sections",
                    items: [
                        "General > Agent command runs controls automatic approval and clean Shell pane removal. See Requested command runs for the exact lifetimes and exceptions.",
                        "General > Swift package builds enables the optional compatibility wrapper for newly started agent panes. See CLI permissions and Troubleshooting before retrying a nested-sandbox error.",
                        "General > Software updates controls the opt-in Production stable update checks and the separate manual Stable/Beta release channel. See Compatibility, updates and feedback.",
                        "Notifications controls local attention notifications. They use content-free collaboration facts rather than terminal text; workspace notifications are opt-in.",
                    ]
                ),
                ParleyHelpSection(
                    id: "settings-window-lifetime",
                    title: "Close, minimise and hide",
                    paragraphs: [
                        "When you close Status Center, Task Manager, Settings, Help or About, that window’s content is released. On reopening, window-local filters, search, selections and toggles return to their defaults; unapplied edits are discarded. This does not erase saved settings, workspaces or collaboration history.",
                        "If you minimise one of those windows or hide Parley, its drafts and local controls stay in memory while live refresh pauses. Restore the window or unhide the app to continue. Closing the window is different from minimising it or hiding the app.",
                        "Closing the main window keeps app-resident panes running and coordination alive. Quit and Stop Everything end those processes; auxiliary window closure does not.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "command-runs",
            title: "Requested command runs",
            summary: "Run an agent-proposed command in a new human Shell, review its authority and recover the captured result.",
            symbol: "terminal",
            sections: [
                ParleyHelpSection(
                    id: "cli-permissions-test-runs",
                    title: "Request, review and run",
                    paragraphs: [
                        "An agent can request a noninteractive command with exact argv and a canonical folder inside its working folder. Each approved run opens a new visible Shell in the requesting workspace; existing Shell panes never receive agent input.",
                        "Per-run approval is the default. The notice above the terminals and Review runs and trust open an editable native preview of the command, folder and requester. Choose Run once in new Shell to submit the edited command, or reject it. A matching session grant or the automatic approval switch can instead authorize a request without a preview.",
                        ReviewedCommandRunCoordinator.trustDisclosure,
                        "This executes outside the agent boundary and outside vendor tool enforcement. It does not answer a vendor permission prompt or make captured output a test verdict.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley request-run --cwd /absolute/project -- /absolute/executable arg", "Propose literal argv and a contained folder. Native per-run approval is the default; existing human authorization may allow the run without another preview."),
                    ]
                ),
                ParleyHelpSection(
                    id: "command-runs-session-trust",
                    title: "Exact-command session trust",
                    paragraphs: [
                        "Optional exact-command session trust is off by default, memory-only and granted or revoked by you in Review runs and trust. It matches exact argv, canonical folder and requesting pane generation, including mutable project code edited between runs. Exact argv is not a boundary around the code it executes.",
                        "Active session grants stay visible. Restart, move, folder or policy changes, Stop Everything and quit invalidate them; they do not survive relaunch. Revoke a grant when you want future matching requests to need review again.",
                    ]
                ),
                ParleyHelpSection(
                    id: "command-runs-settings",
                    title: "Persistent Settings switches",
                    paragraphs: [
                        "Settings > General > Agent command runs has two separate switches, both off by default. Unlike exact-command session trust, these choices survive relaunch until you change them. They are stored in Parley’s private application directory, which ordinary agent panes cannot read or write; an untrusted settings file is treated as both off and Settings explains why.",
                        "Approve agent command runs automatically authorizes every eligible request exactly as requested, without a preview or an exact-command session grant. Turning it on also approves eligible waiting requests. The requester must still be a current agent pane, workspace policy must allow runs, and the canonical folder must be inside that pane’s folder. The runs notice, review sheet and run records disclose automatic approval.",
                        "Turning automatic approval off returns queued automatic approvals that have not launched to waiting. It does not revoke manual approvals or exact-command session grants, and does not stop a command already running. Revoke those grants or use Cancel separately when needed.",
                        "Close the Shell pane when a run finishes cleanly is independent of automatic approval. Its choice is fixed when the run starts: switching it later does not change that run. A clean run has exit 0, no signal, was not cancelled and has no truncated output. With clean-close enabled at launch, its worker exits instead of handing over an interactive shell; after the captured result is saved and the worker has exited, Parley removes the run pane automatically.",
                        "Focus returns to the previous surviving pane only if you are still on the run’s pane. An interactive shell is never closed by this option, and a pane you restarted is yours. Failed, cancelled or truncated runs keep their panes for inspection and ordinary shell use. A result that could not be saved does not qualify for automatic pane removal. The captured result remains in Review runs and trust and Status Center.",
                        "If a switch cannot be saved, Settings shows the error. Enabling fails and stays off. Disabling still takes effect for this session, but the previously saved choice may return after relaunch; turn it off again once storage is writable.",
                    ]
                ),
                ParleyHelpSection(
                    id: "command-runs-results",
                    title: "Results, cancellation and recovery",
                    paragraphs: [
                        "The command has closed stdin and separate piped stdout/stderr, bounded to 30 KB each with explicit truncation. Parley returns a captured result with the approved argv/folder, output, exit status or signal and cancellation/truncation flags. Unless clean-close was selected at launch and the run qualifies, the pane becomes an ordinary interactive human Shell afterward.",
                        "One run may be active per requester. Cancel in Review runs and trust stops the owned process group. Stop Everything and quit end tracked runs and revoke session grants; they do not turn off the persistent Settings switches.",
                        "The request prints a Parley Run ID on stderr. If its calling shell disconnects, the same live requesting pane generation can use parley wait with that exact ID to recover the captured result. Do not silently resend a rejected, interrupted or uncertain run. Troubleshooting has the SwiftPM-to-human-Shell test path.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley wait <run-id>", "Recover one captured command result from the same live requesting generation."),
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "team-sessions",
            title: "Team sessions",
            summary: "Approve a bounded team for one objective, monitor members and stop only the panes it created.",
            symbol: "person.3",
            sections: [
                ParleyHelpSection(
                    id: "cli-permissions-team-sessions",
                    title: "Team sessions",
                    paragraphs: [
                        "A requesting agent pane can propose a bounded team for one objective. Team Sessions (Tools menu, or the notice above the terminal) opens an editable preview of the objective, working folder, allowed vendors, permission profile, pane limit and provisioning deadline. Nothing is authorized until you approve.",
                        "A portable team template is a blueprint, not permission to provision agents. A named template can prefill a request, but you still approve its bound folder, vendors, profile, count and deadline here. See Workspaces for applying templates directly from the native UI.",
                        TeamSessionDisclosure.approval,
                        TeamSessionDisclosure.deadline,
                        "After approval the sheet stays open as the session's monitoring surface and never blocks pane creation. It shows every participant with its provenance and created generation, handoffs between participants, decisions that need you and the remaining provisioning time. Each created pane is an ordinary vendor session with that vendor's own permission prompts.",
                        TeamSessionDisclosure.worktree,
                        TeamSessionDisclosure.stop + " " + TeamSessionDisclosure.expiry,
                    ],
                    commands: [
                        ParleyHelpCommand("parley team request --folder /absolute/project --panes 2 --hours 8 \"objective\"", "The requesting pane proposes a team and waits for your editable approval."),
                        ParleyHelpCommand("parley team request --folder /absolute/repo --worktree feat/parser --base main \"objective\"", "Proposes a new worktree on a new branch; you preview the base commit and decide in the approval."),
                        ParleyHelpCommand("parley team add --vendor codex --name Reviewer --role reviewer", "The requesting pane creates one approved pane and receives its id."),
                        ParleyHelpCommand("parley team status", "The requester or a member reads its session as JSON, including structured stop outcomes."),
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "cli-permissions",
            title: "CLI permission decisions",
            summary: "Grant the narrowest access needed by the current task without turning routine source reads into repeated friction.",
            symbol: "checkmark.shield",
            sections: [
                ParleyHelpSection(
                    id: "cli-permissions-profiles",
                    title: "Choose intent before an agent starts",
                    paragraphs: [
                        "Every new, restored or restarted agent pane asks for one vendor-neutral permission profile. The pane badge preserves that choice, while the launch sheet shows the exact folder scope and how much the selected vendor can actually enforce.",
                    ],
                    items: [
                        "Review only supports project reads and Git inspection without project mutation.",
                        "Default keeps routine reads available while writes and execution remain vendor decisions.",
                        "Flexible prepares project-local reads, writes, tests and builds; network, external folders and consequential actions stay explicit.",
                        "Workspace folders keeps Flexible-style project capabilities but can pass several exact, checked workspace attachments to one pane. Right-click a running agent and choose Folder Access to review changes; applying them explicitly restarts that vendor session without changing its working folder.",
                        "Broad workspace applies only to its exact approved roots and is session-scoped by default. It is never host-wide access and never becomes the next pane's default silently.",
                        "Attaching a folder never grants it. A pane keeps its reviewed roots until the person changes them, and adding another attachment later has no effect on a running process.",
                        "Enforced, Partially enforced and Guidance only describe the installed CLI's real launch controls. Model instructions are not a security boundary, and later vendor prompts remain authoritative.",
                        "Clone a built-in to make an editable local custom profile. Built-ins and Parley's hard boundary remain immutable.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-checklist",
                    title: "Check the action, path and purpose",
                    paragraphs: [
                        "A permission prompt comes from Claude Code, Codex, Agy or Copilot, not from Parley's relay. Judge the exact operation and its target rather than trusting or rejecting a command name by itself.",
                    ],
                    items: [
                        "Is the command directly related to the task you gave the agent?",
                        "Is every path inside the intended repository or another folder you deliberately placed in scope?",
                        "Is the operation read-only, a project-local write, code execution, network access or a system change?",
                        "Could the target contain a secret, credential, private key, token or unrelated personal data?",
                        "Choose the narrowest access and shortest duration that lets the task proceed.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-run-and-team-help",
                    title: "Command runs and team approvals",
                    paragraphs: [
                        "For a command that needs human Shell permissions, see the Requested command runs topic, including per-run approval, exact-command session trust and both Settings switches. For bounded creation of agent panes, see Team sessions. These approvals are separate from each vendor CLI’s own permission prompts.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-swiftpm",
                    title: "Swift package builds in agent panes",
                    paragraphs: [
                        SwiftPMCompatibility.explanation,
                        "Enable this in Settings → General → Swift package builds, then explicitly restart an existing agent pane or start a new one. The setting is off by default and is stored separately for Production and Development.",
                        "The runtime-local wrapper preserves your PATH-selected Swift toolchain, including mise. If a vendor rebuilds PATH, use the helper named by PARLEY_SWIFT_COMMAND. Absolute Swift paths and xcrun swift do not use the PATH wrapper. Tests that create their own sandbox may still need a human Shell pane.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-agy-cat",
                    title: "Example: Agy asks to cat a file",
                    paragraphs: [
                        "Allow Once is normally reasonable when Agy asks to cat an ordinary source file inside the intended repository, the file is relevant to the task, and it is not a likely secret. If repeated reads are expected, approving read access to that exact repository can be reasonable when the vendor offers that choice.",
                        "Do not allow cat globally. Reading src/main.swift is not equivalent to reading ~/.ssh, a .env file, another repository or the whole home folder. The path is the permission that matters.",
                    ],
                    commands: [
                        ParleyHelpCommand("cat src/main.swift", "Usually low risk when this exact source file is inside the pane's intended repository."),
                        ParleyHelpCommand("cat .env", "Treat as sensitive. Inspect why it is needed and normally deny rather than exposing credentials."),
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-expected",
                    title: "Usually reasonable with the right scope",
                    items: [
                        "Read ordinary project source, tests and documentation inside the pane's repository.",
                        "Run search and inspection commands such as rg, sed, git status, git diff and git log against that repository.",
                        "Allow project edits when you explicitly asked the agent to implement a change and have reviewed the folder scope.",
                        "Read Parley's exact agent-protocol/AGENTS.md when a vendor needs its injected cross-vendor instructions. Do not broaden that to all of Parley's Application Support directory.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-review",
                    title: "Pause and inspect",
                    items: [
                        "Tests, builds, package scripts and interpreters execute repository-controlled code even when their names look routine.",
                        "Dependency installation, downloads and other network operations can add code or send information away from the Mac.",
                        "Git commit changes local history; Git push, releases, deployments and infrastructure commands change external systems.",
                        "Access outside approved project roots, including another repository, should match an explicit cross-repository task.",
                        "Pipes, redirection, command substitution and shell wrappers can turn a familiar read command into a write or execution path.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-never-blanket",
                    title: "Never grant as a blanket rule",
                    items: [
                        "Passwords, API tokens, private keys, keychains, SSH or cloud credential directories.",
                        "sudo, system configuration, security-setting changes or permission-bypass flags.",
                        "Destructive filesystem or Git operations without a precise target and explicit current instruction.",
                        "Parley's pane credentials or broad Application Support tree.",
                        "The entire home folder merely to avoid future prompts.",
                    ]
                ),
                ParleyHelpSection(
                    id: "cli-permissions-vendors",
                    title: "Vendor controls differ",
                    paragraphs: [
                        "The wording and persistence choices differ between vendor CLIs. Some approvals apply once, some to a command pattern, and some to a directory. Read the prompt's stated scope every time; Parley does not silently approve it or claim a vendor permission is broader or narrower than the CLI reports.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "safety",
            title: "Safety and permissions",
            summary: "Know which decisions Parley makes and which always remain with you or the vendor CLI.",
            symbol: "hand.raised",
            sections: [
                ParleyHelpSection(
                    id: "safety-permissions",
                    title: "Vendor prompts are deliberate stops",
                    paragraphs: [
                        "Claude Code, Codex, Agy or Copilot may ask for permission, folder trust or command approval after Parley submits a handoff. Parley never answers those prompts for you. Focus that pane, inspect the requested action and decide there.",
                        "An Ask can therefore show as waiting even though delivery and Enter both succeeded. Check the target pane before retrying; a second Ask cannot solve a permission prompt.",
                    ]
                ),
                ParleyHelpSection(
                    id: "safety-boundaries",
                    title: "Boundaries that do not move",
                    items: [
                        "Parley uses subscription CLIs only and never stores API keys or model-provider credentials.",
                        "It never launches agents with a dangerously bypass permissions flag.",
                        "Agents receive pane-scoped credentials and cannot address shell panes or operate another pane's terminal through the supported protocol.",
                        "Every cross-vendor message carries its sender and exact target; ambiguity is refused.",
                        "Everything remains local unless the vendor CLI itself communicates with its normal service.",
                    ]
                ),
                ParleyHelpSection(
                    id: "safety-cancel",
                    title: "Cancel versus interrupt",
                    items: [
                        "Cancel Tracking ends Parley's wait and leaves the target process untouched.",
                        "Cancel and Interrupt additionally sends Control-C to the exact target pane after your confirmation.",
                        "An agent can cancel only tracking it initiated and can never interrupt another CLI.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "status",
            title: "Status Center and activity",
            summary: "See what crossed between panes, what is waiting, and where attention is needed.",
            symbol: "waveform.path.ecg.rectangle",
            sections: [
                ParleyHelpSection(
                    id: "status-open",
                    title: "Use Status Center",
                    paragraphs: [
                        "Open Status Center from the toolbar for a detailed local view across workspaces. The compact activity strip in the main window shows the most relevant current handoff; Status Center keeps the broader timeline.",
                    ],
                    items: [
                        "Filter by workspace and inspect active or completed handoffs.",
                        "A pane attention ring marks authoritative permission requests, unread returned results and failed or interrupted handoffs without interpreting terminal text.",
                        "Pane headers show signal age. Official hook state says PERMISSION REPORTED so an old report is never presented as a current fact.",
                        "Command-Shift-J cycles newest-first: it focuses a live permission pane or opens the exact durable result or interruption in Status Center.",
                        "Focus the source or target pane for a selected event.",
                        "Return manually, cancel tracking, interrupt with confirmation, or retry only when the record says retry is safe.",
                        "Dismissed notifications hide locally without deleting the durable handoff record.",
                    ]
                ),
                ParleyHelpSection(
                    id: "status-menu-bar-inbox",
                    title: "Menu-bar attention inbox",
                    paragraphs: [
                        "Parley's bell remains in the macOS menu bar while the app is running, including after the main window is closed. It shows returned answers, completed delegations, permission requests, other known attention states and failures from the same authoritative handoff record as Status Center.",
                        "Selecting an item opens that exact handoff in Status Center. Returned results become read when the record is selected there; the durable handoff itself is not deleted.",
                    ],
                    items: [
                        "The menu shows at most eight recent items and names how many more remain in Status Center.",
                        "Menu labels contain pane and workspace names plus an opaque handoff id behind the action. Prompt and answer bodies, terminal output, folders and credentials never enter the menu-bar contract.",
                        "If the coordination core is disconnected, the inbox says Coordination unavailable and labels retained entries as last known instead of claiming an all-clear.",
                        "Development shows a DEV marker in the menu bar so an isolated test runtime is never confused with Production.",
                        "Per-workspace macOS notifications remain opt-in in Status Center. Their titles and bodies follow the same content-free boundary.",
                    ]
                ),
                ParleyHelpSection(
                    id: "status-history-controls",
                    title: "Search, select, review, export, or ask again",
                    paragraphs: [
                        "Collaboration History searches the bounded local handoff snapshot already loaded by Status Center. It creates no remote index and sends no search text anywhere. Multiple search words are literal, case-insensitive AND terms: every word must appear somewhere in the same handoff's participants, workspaces, question, returned result, status, attention state or delivery details.",
                        "Kind and outcome filters compose with workspace scope and Show Dismissed. They change only this view; counts, durable handoffs and agent sessions are unchanged.",
                    ],
                    items: [
                        "Tick individual records, or use Select Results for the current search. Export Selected writes only that explicit selection to a local owner-only Markdown file.",
                        "Context Pack from Selected Results opens 1–16 explicitly selected returned Ask or Delegate results as separately attributed, editable sources. Each source keeps its handoff id, route, workspaces, question and exact returned result. No handoff is submitted automatically; choosing a receiving pane remains a later human action in the existing Context Pack preview.",
                        "Challenge and Verify are available on a returned Ask or Delegate. Each menu names the original ready source and requires one explicit relay-ready reviewer pane; a busy reviewer cannot be selected.",
                        "The chosen result opens in the main workbench as a complete editable linked-review Ask. Nothing is submitted until Send Challenge or Send Verify, and the resulting handoff retains its parent id and purpose.",
                        "Request Changes is available on a returned Delegate result. It opens one editable linked delegation to an explicit relay-ready pane, marking the original implementer; a busy pane cannot be chosen and the child is never queued. Its handoff carries the parent id and relationship requestChanges. It is a linked delegation, never a human verdict.",
                        "The inspector renders the thread Delegation → Result → Request changes → Revised result from the existing handoffs' receipts, and the Markdown export preserves the same thread and linked children.",
                        "The Human Review editor stores an optional person-owned verdict and note on the same handoff. Agent panes have no command or capability route that can set this state.",
                        "Relationship, verdict, note and review time are searchable and remain visible in selected-result Context Packs and Markdown exports.",
                        "Status Center has a visible Clear history button that follows the selected workspace scope, including All Workspaces. Its confirmation names the scope and explains that clearing includes finished handoffs, their returned or captured results, and lifecycle activity hidden by filters or dismissal. Active work and running panes remain. All Workspaces also clears finished history for removed workspaces. This irreversible action affects only the current local runtime.",
                        "History → Manage history opens search, filters, retention and export together. Command runs has its own kind filter. Export scope writes the loaded handoffs in the selected workspace scope, including dismissed records even in All Workspaces, regardless of search filters; it includes bodies and receipts, not lifecycle activity. Local retention is separate for Production and Development: choose 100, 250 or 500 records, with the same limit applied separately to handoffs and lifecycle events across all workspaces. Lowering the limit irreversibly prunes the oldest eligible records after confirmation; active handoffs remain, and increasing it later cannot restore deleted history.",
                        "The Markdown export deliberately contains complete question, instruction and returned-result bodies plus identities and delivery receipts. Review it before sharing; it is different from Parley's privacy-bounded diagnostics export.",
                        "Ask This Again is available only after an Ask has ended and its original cross-vendor source and target panes are still running, relay-ready and on the current protocol.",
                        "Repeating always opens the recorded question in an editable preview. Ask Again creates a fresh tracked handoff identity and leaves the historical record unchanged; Parley never silently replays it.",
                    ]
                ),
                ParleyHelpSection(
                    id: "status-reviewed-busy-queue",
                    title: "Keep a reviewed Ask while its target is busy",
                    paragraphs: [
                        "When a native Ask or review shortcut finds that its exact target already has tracked work, Parley can keep the text in the Reviewed Busy Queue. This is a durable owner-only draft, not an execution queue: it contains no pane credentials and becoming idle never submits it.",
                        "Open Status Center to inspect the complete text and route. TARGET BUSY means the original target still owns tracked work. READY TO REVIEW means only that a fresh human Review and Send action is now available; it is not permission for Parley to send in the background.",
                    ],
                    items: [
                        "Review and Send opens the whole draft in an editable preview and creates a normal tracked Ask with a fresh identity.",
                        "Discard Draft removes an unsent local draft without touching either terminal.",
                        "Parley keeps at most 32 reviewed busy drafts and refuses extra drafts rather than silently dropping old text.",
                        "If the core stops across the exact terminal-submission boundary, the item becomes SEND UNCERTAIN and DO NOT RESEND. Dismissing that record never claims to cancel or reverse input that may already have reached the target.",
                        "Pane credentials cannot list, create, send or discard this queue. Only the authenticated native UI can operate it.",
                    ]
                ),
                ParleyHelpSection(
                    id: "status-diagnostics",
                    title: "Diagnostics",
                    paragraphs: [
                        "Tools → Export Diagnostics creates a privacy-bounded local archive for troubleshooting. Review it before sharing it. Environment Check verifies local executables and runtime readiness without submitting prompts or spending model quota.",
                    ],
                    items: [
                        "Tools → Task Manager shows Parley's application process and only the processes attributed to live Ghostty panes. It groups resource use by program, workspace and pane; it is not a system-wide Activity Monitor.",
                        "CPU is calculated from two consecutive samples, so the first sample truthfully shows an unavailable value. App RSS and Pane RSS are separate because summing resident memory can count shared pages more than once.",
                        "Process rows are read-only. Focus, diagnostic copy, Control-C, restart and close operate on the owning pane; interruption, restart and close keep their normal confirmations.",
                        "The diagnostics report contains aggregate coordination usage, typed delivery outcomes, retained event-window bounds and authoritative recovery timings. It excludes prompts, results, terminal content, names, folders and raw event bodies, and Parley never uploads it.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "release-lifecycle",
            title: "Compatibility, updates and feedback",
            summary: "Check CLI changes honestly, choose a release channel, verify a DMG and review exactly what beta feedback contains.",
            symbol: "checkmark.shield",
            sections: [
                ParleyHelpSection(
                    id: "release-compatibility",
                    title: "Quota-free vendor compatibility",
                    paragraphs: [
                        "Open Tools → Compatibility & Releases. Parley runs exactly one --version command for each installed Claude, Codex, Agy and Copilot CLI. The probe receives a minimal allowlisted launch environment and closed empty stdin, then Parley retains only the semantic version and reports adapter support for Launch, Submit, Ask/Answer and Permissions. No session is opened, no prompt is submitted, no vendor configuration is inspected and no model quota is spent.",
                        "CLI CHANGED means the semantic version differs from the previous runtime-local check. It is a prompt to review the vendor's release notes, not a claim that runtime behavior passed. Permission support remains Partial because Parley translates only documented safe controls and vendor prompts remain authoritative.",
                    ]
                ),
                ParleyHelpSection(
                    id: "release-runtime-hooks",
                    title: "Runtime state stays Unknown without evidence",
                    paragraphs: [
                        "Parley installs generated, session-scoped hook adapters for Claude and Codex and attaches a generated plugin for Copilot. State changes only after the pane's authenticated capability reports a fixed content-free event. Copilot remains Unknown unless its CLI executes the attached plugin hook; Agy remains Unknown because its documented hooks require persistent user or workspace configuration. Terminal prose, silence, animation and elapsed time never become runtime facts.",
                        "Turn and notification signals update live pane state and a separate bounded in-memory event ring. They do not consume durable human-history retention or appear in the Status Center timeline. Session boundaries and awaiting-permission remain durable for supervision and recovery diagnostics.",
                        "Exited is different: Parley owns the process lifecycle and can report an observed exit and status without reading terminal content.",
                    ]
                ),
                ParleyHelpSection(
                    id: "release-automatic-updates",
                    title: "Automatic stable updates in Production",
                    paragraphs: [
                        "Settings > General > Software updates offers Check for stable updates automatically in configured Production builds. It is off by default. Turning it on allows periodic checks of the signed stable update channel; Check Now… checks that channel immediately without enabling periodic checks.",
                        "The updater requires your consent to install. There is no background installation. An update that needs to quit Parley follows the ordinary pane-aware quit confirmation, because full quit ends app-resident panes and coordination. Finish tracked work before agreeing to quit and install.",
                        "Development does not start the updater or use the Production feed. If the installed build has no configured automatic update channel, Settings shows it as unavailable. Manual GitHub downloads below remain a separate path.",
                    ]
                ),
                ParleyHelpSection(
                    id: "release-updates",
                    title: "Manual Stable and Beta GitHub downloads",
                    paragraphs: [
                        "The Manual release channel in Settings chooses the GitHub downloads shown in Compatibility & Releases. Stable selects published non-prereleases. Beta selects the newest published release including prereleases. This manual path contacts the public GitHub Releases API when you press Check GitHub; choosing Beta does not change the automatic stable update channel.",
                        "Before offering a DMG, Parley requires the GitHub asset list, release manifest and SHA256SUMS to agree on version, repository, architecture, filename, byte count and SHA-256. Download and Verify hashes the complete downloaded DMG before saving it locally. It does not install, relaunch or stop app-resident panes.",
                        "The manual GitHub check is credential-free. A private releases repository returns HTTP 404 and cannot be checked from the app; Open Releases uses your signed-in browser. In-app GitHub checks require a public releases repository.",
                    ],
                    items: [
                        "Release notes are shown before any download.",
                        "An unnotarized beta stays visibly labelled; checksum verification is not code signing or notarization.",
                        "Installation remains a separate human action. Finish tracked work and quit Parley before replacing the app, because full quit ends app-resident panes and coordination.",
                    ]
                ),
                ParleyHelpSection(
                    id: "release-feedback",
                    title: "Review beta feedback before export",
                    paragraphs: [
                        "The Beta Feedback tab opens a field-level review before it can write an owner-only local ZIP. Nothing is uploaded automatically. The archive contains feedback.json, diagnostics.json and a privacy README.",
                    ],
                    items: [
                        "Included: build facts, selected update channel, semantic vendor versions, compatibility states, capability outcomes and structurally redacted diagnostics.",
                        "Excluded by structure: prompts, delegated instructions, answers, result bodies, terminal contents, selections, titles, commands, folders, display names, credentials, tokens, sockets, raw journals, raw logs, browser profiles and subscription data.",
                        "Review the generated files again before attaching the ZIP to an issue or sending it to another person.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "shortcuts",
            title: "Keyboard shortcuts",
            summary: "Move around the workbench without taking your hands away from an agent prompt.",
            symbol: "keyboard",
            sections: [
                ParleyHelpSection(
                    id: "shortcuts-navigation",
                    title: "Navigation",
                    items: [
                        "Command-K — open the command palette.",
                        "Control-Tab / Control-Shift-Tab — next / previous workspace.",
                        "Control-Option-Right / Control-Option-Left — next / previous pane.",
                        "Command-Shift-J — cycle authoritative permission, result and interruption attention.",
                        "Command-1…9 — focus pane 1 through 9 in the current workspace, when that pane exists.",
                        "Command-Shift-F — enter Focus Canvas or return to Pane Grid.",
                        "Command-Shift-D — show or hide the Collaboration Dock.",
                        "Command-Option-T — focus the active terminal.",
                        "Command-Shift-T — open Task Manager.",
                        "Command-? — open this detailed help window.",
                    ]
                ),
                ParleyHelpSection(
                    id: "shortcuts-actions",
                    title: "Creation and handoff",
                    items: [
                        "Command-Shift-N — New Workspace; creates a folderless workspace. Use Workspace > Open Folder… to open an existing folder.",
                        "Command-Shift-1 — new Claude pane.",
                        "Command-Shift-2 — new Codex pane.",
                        "Command-Shift-3 — new Agy pane.",
                        "Command-Shift-4 — new shell pane.",
                        "Command-Shift-5 — new Copilot pane.",
                        "Command-Shift-A — open the exact terminal selection for this source pane's last explicit Ask target; Command-Return remains the separate send confirmation.",
                        "Command-Shift-Return — return an answer through the native pane route.",
                    ]
                ),
            ]
        ),
        ParleyHelpTopic(
            id: "troubleshooting",
            title: "Troubleshooting",
            summary: "Resolve the common cases without starting a second Parley instance or losing terminal state.",
            symbol: "wrench.and.screwdriver",
            sections: [
                ParleyHelpSection(
                    id: "troubleshooting-waiting",
                    title: "A handoff is waiting",
                    items: [
                        "Focus the target pane first. Look for a permission, folder trust, approval or model question.",
                        "Use Status Center to confirm whether delivery was submitted, waiting, completed or failed.",
                        "If the target answered after an Ask was cancelled or timed out, answer current may report an unknown consultation. Start a new Ask only after the pane is back at its prompt.",
                        "Do not repeatedly resend a long consultation; inspect the durable handoff before retrying.",
                        "If the original Ask shell disconnected, use the handoff id it printed on stderr with parley wait from that same still-running pane generation.",
                    ]
                ),
                ParleyHelpSection(
                    id: "troubleshooting-runtime",
                    title: "A pane or the core will not start",
                    items: [
                        "Run Tools → Environment Check. It verifies the embedded terminal, the agent CLIs, Parley's local files and protocol readiness without spending quota.",
                        "If a CLI works in Terminal but not Parley, its install directory may be absent from the GUI login PATH. Environment Check reports the resolved path.",
                        "After a shared protocol upgrade, restart existing agent panes once so they receive the current instructions.",
                        "If the coordination core is unavailable, use the recovery action shown by Parley instead of launching a second app instance.",
                    ]
                ),
                ParleyHelpSection(
                    id: "troubleshooting-test-runs",
                    title: "A test needs a human Shell",
                    items: [
                        "1. If SwiftPM reports sandbox_apply: Operation not permitted in an agent pane, open Settings > General > Swift package builds. Compatibility is off by default; opt in deliberately, then explicitly restart that agent pane or start a new one. This changes SwiftPM’s nested sandbox only; Parley’s outer boundary and vendor approvals remain.",
                        "2. Retry the build or test with the compatibility wrapper. If the vendor rebuilt PATH, the PARLEY_SWIFT_COMMAND helper below reaches the same wrapper. Do not enable compatibility or restart a pane silently on someone else’s behalf.",
                        "3. A remaining GUI test failure such as EPERM spawning /usr/bin/login under AgentProcessBoundary needs a human Shell’s permissions. From the project folder, ask for one reviewed run with request-run. The npm example below resolves the installed npm executable and runs that project’s test script; it requires npm on PATH and a package.json test script.",
                        "4. Review runs and trust shows the exact command and folder for native approval. Run once in new Shell creates a new visible pane. An existing matching session grant or the automatic approval switch can authorize it without another preview; the run record says how it was approved.",
                        "5. Read the returned captured result and exit status. If the request’s shell disconnected, use the Parley Run ID printed on stderr with parley wait from the same live requesting pane generation. Inspect cancellation and truncation flags, and do not resubmit an uncertain command.",
                    ],
                    commands: [
                        ParleyHelpCommand("\"$PARLEY_SWIFT_COMMAND\" build", "Retry a Swift package build after your compatibility opt-in and explicit pane start/restart."),
                        ParleyHelpCommand("parley request-run --cwd \"$PWD\" -- \"$(command -v npm)\" test", "From a project using npm test, resolve the installed executable and request a new human Shell run."),
                        ParleyHelpCommand("parley wait <run-id>", "Replace <run-id> with the exact Parley Run ID to recover the captured result."),
                    ]
                ),
                ParleyHelpSection(
                    id: "troubleshooting-uninstall",
                    title: "Prepare to Uninstall",
                    paragraphs: [
                        "In Production, choose Parley > Prepare to Uninstall… while coordination is available, then review Prepare and Quit. Parley refuses while an Ask or tracked delegation is active: finish or cancel that work first.",
                        "Preparation ends every app-resident pane process, stops coordination and quits. If shutdown cannot be confirmed, Parley reports the error and keeps the app open. This action does not delete the app, workspace layouts or local collaboration history.",
                        "After Parley quits, move the application to Trash to uninstall it. Saved local data remains on disk for a later reinstall; Prepare to Uninstall is not a history-erasure action.",
                    ]
                ),
                ParleyHelpSection(
                    id: "troubleshooting-shutdown",
                    title: "Quit, detach, or reset the runtime",
                    items: [
                        "Press Command-Q to quit the app. Closing the main window with its red button leaves Parley running; closing auxiliary windows releases their local content as described in Settings and appearance.",
                        "An owned Production or Development runtime always offers Keep Running, Stop Everything, or Cancel, even when every agent is stopped or dead.",
                        "Closing the main window keeps panes running while Parley remains open. Quit or Stop Everything ends every pane process and the app-resident coordination core.",
                        "If Parley cannot verify that every pane stopped, it reports the failure and keeps the app open instead of claiming shutdown succeeded.",
                    ]
                ),
                ParleyHelpSection(
                    id: "troubleshooting-find",
                    title: "Find a command or record",
                    items: [
                        "Use the command palette to search actions, workspaces, panes and the durable local record.",
                        "Use Status Center for complete handoff history and safe recovery controls.",
                        "Use Export Diagnostics when the UI cannot explain a repeated core or delivery failure.",
                    ]
                ),
            ]
        ),
    ]

    public static func matching(_ query: String) -> [ParleyHelpTopic] {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return topics }
        return topics.filter { topic in
            let haystack = topic.searchableText.lowercased()
            return tokens.allSatisfy(haystack.contains)
        }
    }
}
