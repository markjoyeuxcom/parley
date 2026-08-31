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
                    id: "workspaces-worktrees",
                    title: "Existing Git worktrees",
                    paragraphs: [
                        "Git worktrees are parallel filesystem locations, not Parley workspaces or agents. From the workspace plus menu, Open Existing Worktree as Workspace reads git worktree list --porcelain without a shell and lets you open one of that repository's existing directories as an ordinary workspace.",
                        "Parley warns when two running agent panes point at the same exact canonical worktree and both have visible permission profiles that explicitly allow project writes. The warning is permission evidence only: Parley does not claim either process changed a file, and a quiet terminal never proves concurrent work is safe.",
                    ],
                    items: [
                        "The list shows the repository, branch or detached commit identity, primary or linked worktree status, exact path, and Git's locked or prunable state.",
                        "Ordinary folders remain supported. Parley never requires one worktree per agent or silently creates one.",
                        "Discovery and opening do not create, move, prune, delete, merge, rebase or switch a worktree.",
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
                        "Use the workspace plus menu to save the current configured grid as a team. Applying a team asks for a folder and binds every pane plus its permission scope to that chosen folder.",
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
                    id: "workspaces-vscode-companion",
                    title: "VS Code Companion",
                    paragraphs: [
                        "The Parley Companion is a thin local VS Code desktop extension. Its commands can open or focus the current workspace, or place an explicit selection, saved current file, current-file diagnostics, Git diff, or selection plus Git diff into Parley's normal editable context preview.",
                        "Current files and Git diffs are recaptured by Parley from the local workspace. Selections and diagnostics are editor-provided captures and stay labelled that way. Inspect the source, byte count and editable text in Parley before deciding whether to send it.",
                    ],
                    items: [
                        "The extension refuses VS Code for the Web and remote workspaces. Its first release uses the local macOS UI extension host and the installed Production app only.",
                        "Each context action uses one private, owner-only, one-shot manifest. Parley consumes it from its fixed integration inbox; the file cannot carry a pane target, vendor, prompt, permission or submit action.",
                        "A ready agent pane in the workspace is required as the eventual source. The extension never starts one implicitly.",
                        "Opening the preview sends nothing. Parley's existing human confirmation is still required to Ask one vendor or compare several independently.",
                    ],
                    commands: [
                        ParleyHelpCommand("Parley: Open or Focus Workspace", "Bring the matching local workspace forward without starting an agent."),
                        ParleyHelpCommand("Parley: Open Selection and Git Diff in Context Preview", "Stage two explicit sources in one editable preview; nothing is sent."),
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
                        "Start a restored placeholder, restart an exited session, or close the pane deliberately.",
                        "An exited process remains visible with its final scrollback until you close or restart it.",
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
                    id: "handoffs-difference",
                    title: "The important difference",
                    items: [
                        "Ask submits a question, blocks the requesting agent's command, and returns the exact correlated answer to that same turn.",
                        "Relay submits one attributed message immediately but does not wait for a correlated result.",
                        "Paste places an attributed draft in the target prompt without Enter, so you can inspect or edit it first.",
                        "The native menus let you preview and edit captured text before it crosses to another pane.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley ask codex \"Review this plan and return your concerns.\"", "Submit a correlated question and wait for Codex's returned answer."),
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
                        "Delegate starts asynchronous agent-to-agent work and immediately returns a tracking id. The receiving agent must report a terminal result through Parley; merely printing the result in its pane does not complete the tracking relationship.",
                    ],
                    commands: [
                        ParleyHelpCommand("parley delegate codex \"Implement the reviewed fix and verify it.\"", "Assign one bounded task to another vendor."),
                        ParleyHelpCommand("parley status", "List work initiated by this pane as machine-readable JSON."),
                        ParleyHelpCommand("parley wait current", "Wait for the result when exactly one delegation is active."),
                        ParleyHelpCommand("parley done current \"Implemented; tests pass.\"", "Complete work from the delegated target pane."),
                        ParleyHelpCommand("parley fail current \"Blocked by a missing fixture.\"", "Return an explicit failed result from the delegated target pane."),
                        ParleyHelpCommand("parley cancel current", "Cancel only tracking initiated by this pane; the target CLI is not interrupted."),
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
                    title: "Four separate scopes",
                    paragraphs: [
                        "Parley keeps different kinds of context separate so a useful note does not silently become an instruction to every agent. The scope determines where material lives and whether it survives a window.",
                    ],
                    items: [
                        "Pinned Snippet — durable, application-wide reusable context such as architecture rules, test instructions and review criteria.",
                        "Workspace Brief — durable context for one live workspace: its current goal, constraints and important decisions.",
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
                        "Use a Workspace Brief for the current project goal, boundaries and decisions that should not be silently reopened.",
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
                        "While reviewing an agent draft, a person may add Files, Git Diff, Selection or Capture Command. The app-resident core performs that separate capture, labels its real provenance and retains the original bytes; the agent-provided parts remain claims.",
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
                        "Open Context and choose Create Workspace Brief or Edit Workspace Brief. Record the current goal, constraints and important decisions once for that live workspace. Saving is local and does not contact an agent.",
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
            id: "vscode-companion",
            title: "VS Code companion",
            summary: "Stage explicit editor evidence, see local attention and jump back to Parley's authoritative pane or record.",
            symbol: "chevron.left.forwardslash.chevron.right",
            sections: [
                ParleyHelpSection(
                    id: "vscode-companion-context",
                    title: "Open editor context for review",
                    paragraphs: [
                        "The optional Parley Companion runs in VS Code's local macOS UI extension host. Its Command Palette and editor menus can open the current workspace or place a selection, saved file, diagnostics, Git diff, or selection plus diff into Parley's ordinary editable Context Pack preview.",
                        "Parley recaptures files and Git diffs from disk. Selection and diagnostic text remain visibly labelled as editor-provided. A ready source pane is required, but the companion never starts an agent or sends the pack.",
                    ],
                    items: [
                        "Web and remote VS Code hosts are refused; a remote path is never treated as a local Mac path.",
                        "The one-shot owner-only manifest cannot name a target pane, vendor, permission, prompt or submit action.",
                        "Review every attributed source in Parley, edit the request, then choose the normal Ask or Compare action yourself.",
                    ]
                ),
                ParleyHelpSection(
                    id: "vscode-companion-attention",
                    title: "Attention and focus",
                    paragraphs: [
                        "The VS Code status bar shows the installed Production app's current attention count. Select it, or run Parley: Show Attention and Panes, to open one durable Status Center handoff or focus one exact live agent pane.",
                    ],
                    items: [
                        "The local snapshot contains human labels, counts and opaque pane or handoff ids only. It never contains prompts, answers, terminal output, commands, folders or pane credentials.",
                        "A stale, malformed, symlinked or non-private snapshot is shown as unavailable rather than trusted.",
                        "Focus links can only identify one existing pane or handoff. They cannot carry context, vendor startup, terminal input or submission.",
                        "Development does not publish into Production's integration file or claim its machine-wide URL scheme.",
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
                        "Open Recipes in the toolbar, choose Plan Review, Implementation Review, Adversarial Bug Hunt or Compare Recommendations, select explicit targets, then review the final instruction before Run with Lead.",
                        "A recipe sends one visible instruction to the lead. The lead remains responsible for judging advice and deciding what to adopt; Parley supplies transport and records activity.",
                    ],
                    items: [
                        "Edit Recipes changes the reusable local instruction text. Keep {{targets}} in each template.",
                        "Stop asks for confirmation, then sends Control-C only to the lead's current turn.",
                        "Stopping the lead does not cancel tracked work it already delegated. Cancel those items separately in Status Center.",
                    ]
                ),
                ParleyHelpSection(
                    id: "lead-bounded-workflow",
                    title: "Run smart orchestration",
                    paragraphs: [
                        "Open Recipes and choose New Plan → Review → Implement → Verify. Choose Supervised or Auto plus explicit reviewer and verifier panes, then enter the exact objective. The same pane may review and verify, and either role may use another pane from the lead's vendor.",
                        "Supervised pauses at every handoff for an editable human preview. Auto advances Plan, Review, Implement and Verify only when each target returns one correlated Parley answer; it never watches terminal prose to guess that a stage finished.",
                    ],
                    items: [
                        "Planning and independent review remain read-only stages.",
                        "Starting Auto explicitly authorizes the lead's implementation stage, but it cannot bypass a vendor permission or folder-trust prompt.",
                        "The verifier receives the attributed implementation report, independently inspects the repository and is instructed not to modify files.",
                        "Auto preserves every answer and stops at Completion Approval. Only you can mark the run complete; verifier prose is evidence, not proof.",
                        "Stop Auto ends further advancement without sending Control-C. Work already running in a pane remains visible and can be interrupted separately.",
                        "The owner-only local record preserves mode, participants, exact artifacts and HUMAN or AUTO attribution for every transition.",
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
                        "Broad workspace applies only to its exact approved roots and is session-scoped by default. It is never host-wide access and never becomes the next pane's default silently.",
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
                    title: "Search, select, export, or ask again",
                    paragraphs: [
                        "Collaboration History searches the bounded local handoff snapshot already loaded by Status Center. It creates no remote index and sends no search text anywhere. Multiple search words are literal, case-insensitive AND terms: every word must appear somewhere in the same handoff's participants, workspaces, question, returned result, status, attention state or delivery details.",
                        "Kind and outcome filters compose with workspace scope and Show Dismissed. They change only this view; counts, durable handoffs and agent sessions are unchanged.",
                    ],
                    items: [
                        "Tick individual records, or use Select Results for the current search. Export Selected writes only that explicit selection to a local owner-only Markdown file.",
                        "With one workspace selected in Status Center, the archive menu can export every retained handoff involving that workspace, including dismissed records. The export contains handoff bodies and receipts, not lifecycle activity. The neighbouring Delete History action removes eligible handoffs and lifecycle activity only after a workspace-specific destructive confirmation; active work remains.",
                        "Local retention is core-owned and separate for Production and Development. Choose a bound of 100, 250 or 500 for both handoffs and lifecycle events. Lowering it immediately and irreversibly removes the oldest eligible records; active handoffs and curated handoff chains are preserved, and increasing it later cannot restore deleted history.",
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
                    ]
                ),
                ParleyHelpSection(
                    id: "status-chains",
                    title: "Curate a handoff chain",
                    paragraphs: [
                        "A handoff chain is a readable, person-curated evidence trail. It groups exact snapshots of related Ask, Relay, Paste and Delegate records without creating a task board, contacting an agent or inventing a consensus.",
                    ],
                    items: [
                        "Select a handoff in Status Center, then use Add to Chain to start a named chain or append it to an existing chain in the same workspace scope.",
                        "For a returned Ask or Delegate result, use Bookmark Result to preserve the complete answer verbatim as either an Answer or an Objection.",
                        "Open a chain and choose Add Human Decision to record what you decided. The decision is explicitly labelled HUMAN and is never attributed to an agent.",
                        "Chains store exact local snapshots, so curated evidence remains readable after Parley's bounded ordinary handoff journal prunes an old record.",
                        "Deleting a chain removes only that curated copy. It never deletes the broker handoff, changes terminal state or interrupts a pane.",
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
                        "Parley shows Ready, Working or Awaiting Permission only if a vendor supplies a trustworthy structured per-session hook. Current vendors do not, so a running pane is Unknown. Terminal prose, silence, animation and elapsed time never become runtime facts.",
                        "Exited is different: Parley owns the process lifecycle and can report an observed exit and status without reading terminal content.",
                    ]
                ),
                ParleyHelpSection(
                    id: "release-updates",
                    title: "Stable and Beta GitHub Releases",
                    paragraphs: [
                        "Stable selects published non-prereleases. Beta selects the newest published release including prereleases. Parley contacts its public GitHub Releases API only after you press Check GitHub; there is no background update check.",
                        "Before offering a DMG, Parley requires the GitHub asset list, release manifest and SHA256SUMS to agree on version, repository, architecture, filename, byte count and SHA-256. Download and Verify hashes the complete downloaded DMG before saving it locally. It does not install, relaunch or stop app-resident panes.",
                        "The automatic check is deliberately credential-free. A private releases repository returns HTTP 404 and cannot be checked from the app; Open Releases uses your signed-in browser, while automatic checks require releases to be published from a public repository.",
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
                        "Command-? — open this detailed help window.",
                    ]
                ),
                ParleyHelpSection(
                    id: "shortcuts-actions",
                    title: "Creation and handoff",
                    items: [
                        "Command-Shift-N — open a workspace.",
                        "Command-Shift-1 — new Claude pane.",
                        "Command-Shift-2 — new Codex pane.",
                        "Command-Shift-3 — new Agy pane.",
                        "Command-Shift-4 — new shell pane.",
                        "Command-Shift-5 — new Copilot pane.",
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
                    id: "troubleshooting-shutdown",
                    title: "Quit, detach, or reset the runtime",
                    items: [
                        "Press Command-Q to quit the app. Closing the last window with its red button leaves Parley running.",
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
                        "Use Status Center for the complete handoff chain and safe recovery controls.",
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
