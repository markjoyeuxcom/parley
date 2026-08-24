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
            summary: "Use several subscription CLIs in one grid and move work between vendors without copy and paste.",
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
                    title: "Folders are pane-local",
                    paragraphs: [
                        "Every pane starts with its own working folder and keeps it for the lifetime of that process. The workspace folder control only chooses where the next toolbar-created pane opens.",
                    ],
                    items: [
                        "A split inherits the folder of the pane it grew from.",
                        "Changing the workspace's default folder does not move or restart running panes.",
                        "Use favourite folders in the sidebar for frequently used repositories.",
                        "Cross-workspace handoffs work; qualify an ambiguous target as workspace/pane.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-layouts",
                    title: "Saved layouts",
                    paragraphs: [
                        "A saved layout remembers the split shape, pane kind, pane name, folder, workspace lead and automation policy. It never stores live process or tmux pane ids.",
                    ],
                    items: [
                        "Restoring a layout starts shell panes automatically.",
                        "Agent panes restore as placeholders. Press Start yourself so reopening Parley never spends a subscription session unexpectedly.",
                        "Opening a layout over live panes asks before replacing them.",
                    ]
                ),
                ParleyHelpSection(
                    id: "workspaces-pane-menu",
                    title: "Pane context menu",
                    items: [
                        "Rename a pane to give routing a memorable, unique name.",
                        "Make or remove a Workspace Lead.",
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
                        "Use a unique pane name, vendor name or pane id. A renamed pane is addressed by its new name. The special name lead resolves to the marked lead in the sender's workspace.",
                    ],
                    items: [
                        "Parley refuses ambiguous names instead of guessing.",
                        "Use workspace/pane to disambiguate a pane in another workspace.",
                        "Targets must be a different vendor. Use the vendor CLI's own tools for same-vendor agents.",
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
                        "Ask Many sends the same question to explicit vendors concurrently. They do not see one another's answers, so the result is independent evidence rather than a chain of agreement.",
                        "From an active agent pane, open Ask and choose Compare Independently. Select at least two panes from different vendors, review the exact question, then keep the comparison window open or reopen the last comparison from the same menu.",
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
                        "Delegate starts asynchronous cross-vendor work and immediately returns a tracking id. The receiving agent must report a terminal result through Parley; merely printing the result in its pane does not complete the tracking relationship.",
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
            id: "context-packs",
            title: "Context packs",
            summary: "Assemble only the local evidence you choose, inspect its provenance and byte size, then send it through Ask or independent Compare.",
            symbol: "shippingbox",
            sections: [
                ParleyHelpSection(
                    id: "context-packs-build",
                    title: "Build an explicit pack",
                    paragraphs: [
                        "From a ready agent pane, open Context and choose New Context Pack. Add selected UTF-8 files, the source pane's current Git diff, one chosen pane's visible screen, or a captured command result.",
                        "Every source remains a separate editable part with its exact path or pane/command provenance, captured UTF-8 bytes, current UTF-8 bytes and an EDITED marker when the preview differs from the capture.",
                    ],
                    items: [
                        "Git capture uses read-only argv calls. Untracked files are named by status but their contents are never read implicitly.",
                        "Visible terminal capture means the current visible screen only. Hidden scrollback, another pane and the complete transcript are not scraped.",
                        "Command capture requires an absolute executable and treats each non-empty line as one literal argument. It never invokes a shell, expands variables, pipes or redirects.",
                        "Both command stdout and stderr plus the exit status are retained. Time and output bounds prevent a noisy process from creating an unbounded preview.",
                    ]
                ),
                ParleyHelpSection(
                    id: "context-packs-send",
                    title: "Preview and send",
                    paragraphs: [
                        "Write the request for the receiving vendor in the pack itself. Ask One Vendor submits it through the usual attributed Ask path. Compare Vendors gives the same rendered pack to at least two target vendors independently and opens the comparison view for their separate answers.",
                    ],
                    items: [
                        "The live rendered byte total includes provenance, your request and wrapper text—not just source bodies.",
                        "An oversized source or pack stays visibly invalid and cannot be sent; Parley never silently clips the editable preview.",
                        "Context packs are local in-memory drafts in this release. Workspace briefs and reusable pinned snippets are separate later features.",
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
                    id: "lead-policy",
                    title: "Automation policy",
                    paragraphs: [
                        "Each workspace tab shows its automation policy. The broker enforces it before every agent-initiated dispatch.",
                    ],
                    items: [
                        "Off blocks automatic Relay, Ask and Delegate. Paste remains a non-submitted draft.",
                        "Ask/Answer permits Relay and correlated consultation but not tracked delegation.",
                        "Ask + Delegation permits all cross-vendor coordination commands.",
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
                        "Parley's private tmux socket, pane credentials or broad Application Support tree.",
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
                        "Agents receive pane-scoped credentials and cannot address shell panes or operate Parley's tmux server through the supported protocol.",
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
                    id: "status-diagnostics",
                    title: "Diagnostics",
                    paragraphs: [
                        "Tools → Export Diagnostics creates a privacy-bounded local archive for troubleshooting. Review it before sharing it. Environment Check verifies local executables and runtime readiness without submitting prompts or spending model quota.",
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
                        "Command-Shift-Z — zoom or restore the active pane.",
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
                        "Run Tools → Environment Check. It verifies tmux, the agent CLIs, Parley's local files and protocol readiness without spending quota.",
                        "If a CLI works in Terminal but not Parley, its install directory may be absent from the GUI login PATH. Environment Check reports the resolved path.",
                        "After a shared protocol upgrade, restart existing agent panes once so they receive the current instructions.",
                        "If the coordination core is unavailable, use the recovery action shown by Parley instead of launching a second app instance.",
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
