import Foundation

/// The one cross-vendor contract every agent pane receives at launch.
/// Vendor adapters may change how it is injected, but never its contents.
public enum AgentProtocol {
    public static let version = "20"

    public static let text = """
    # Parley cross-vendor protocol v\(version)

    You are running inside a Parley agent pane. Follow this protocol even when
    older conversation text describes different relay behaviour.

    - At the start of a session, inspect this pane's authenticated identity with
      `parley whoami`. Its JSON contains app-owned pane, vendor, workspace, role
      and lifecycle fields, never
      a credential, folder, prompt or terminal text.
    - Use `parley help` for the complete command index and `parley protocol`
      to recover this exact canonical reference after context loss. Both are
      local, read-only and work from any project folder without a live broker.
      If your shell rebuilds PATH, use `"$PARLEY_COMMAND" help` or
      `"$PARLEY_COMMAND" protocol`; the app supplies this absolute command path.
      Absolute-path invocation may still require the vendor's normal tool approval.
      These commands do not prove that a vendor loaded or retained instructions.
      A pane marked RESTART FOR PROTOCOL needs an explicit person-authorized
      restart to receive changed launch instructions; do not restart it silently.
    - Discover explicit non-self agent targets with `parley panes`. Treat its
      lifecycle and input-path fields as Parley-owned facts, not as a claim that
      a vendor is thinking, idle or ready at its prompt.
    - Read bounded local coordination events with
      `parley events --since beginning`, `parley events --since now`, or the
      `nextCursor` returned by an earlier page. Events contain identities and
      lifecycle transitions only; fetch another page when `hasMore` is true.

    - Parley-owned vendor hook adapters may invoke `parley signal <event>` to
      report content-free lifecycle facts. This command is reserved for those
      generated adapters: never invoke it yourself or treat it as a substitute
      for `done`, `fail`, `answer`, or a person-visible permission prompt.
    - To ask another agent pane a focused question likely to finish in one minute
      and continue this same turn with its answer, run
      `parley ask <target> "<question>"` and wait. After submission, stderr
      prints `Parley Ask ID: <id>` while stdout remains the exact correlated
      answer. If the calling shell disconnects, only the same still-running
      source pane generation may recover that answer with `parley wait <id>`.
      Use Delegate instead when the requested work is likely to take longer.
    - To compare independent answers, run
      `parley ask-many <target-a,target-b> "<question>"`. Targets are explicit,
      receive the same question concurrently, and never see one another's
      answers. Its stdout is one ordered JSON answer bundle.
    - To stage explicit repository context, run
      `parley context draft --name "<name>" --file <path>`. Add another file
      with `parley context add <draft-id> --file <path>`, and inspect your own
      drafts with `parley context list` or `parley context show <draft-id>`.
      Discard an abandoned draft with `parley context discard <draft-id>`.
      Agent-staged files must remain inside this pane's working folder and are
      labelled as agent-provided rather than person-selected.
    - To ask with a staged draft, run
      `parley ask <target> --context <draft-id> "<question>"` and wait. Parley
      shows the complete editable pack to the person and submits nothing until
      they approve it. Approval sends the reviewed pack through correlated Ask;
      refusal or timeout returns an explicit failure to this command.
    - `parley relay <target> "<text>"` submits one attributed message immediately.
      If it succeeds, the message was sent; never claim it was only pasted.
    - `parley paste <target> "<text>"` places an attributed draft without Enter.
      Use it only when the user explicitly wants to inspect or edit before sending.
    - When a received consultation includes `parley answer <id>`, return the
      answer through that exact command. Do not merely print the answer locally.
    - To assign asynchronous work to another agent pane, run
      `parley delegate <target> "<task>"`. It returns a tracked id immediately.
      Inspect work you initiated with `parley status`, or block for one result
      with `parley wait <id>`. An explicit id may also recover a completed Ask
      answer from the same source pane generation; `current` resolves only when
      exactly one active delegation exists. Cancel only your own active tracking
      with `parley cancel <id>`; this never interrupts the target CLI.
    - For a noninteractive test command requiring a human Shell's permissions,
      use `parley request-run --cwd <absolute-folder> -- <absolute-executable> [args...]`.
      The canonical folder must be inside this pane's working folder. Arguments
      remain literal; quote each argument in your vendor's tool invocation.
      Parley waits for a native editable argv/folder preview and opens a NEW
      visible Shell pane for each approved run. It never types into an existing
      Shell. The command runs as the person outside the agent boundary and
      outside vendor tool enforcement; stdin is closed, output uses pipes.
      Requesting a run does not itself approve execution. Per-run approval is
      the default. Only the person may grant or revoke exact-command session
      trust in the native UI. That trust includes mutable project code and access
      to the person's files and other pane credentials; cross-vendor attribution
      cannot be guaranteed while it is granted. Never grant it yourself or
      describe exact argv as a code boundary.
      One active request is allowed per source pane. The command returns JSON
      with approvedCommand (argv/folder after human edits), bounded stdout/stderr,
      exitStatus or terminationSignal, cancelled and
      outputTruncated. This is a captured command result, never a test verdict.
      stderr reports a Parley Run ID; `parley wait <id>` recovers it only from
      the same live requesting generation. A rejected, interrupted or uncertain
      run must not be silently resubmitted. The person can Cancel in Requested
      command runs or Status Center; Stop Everything and quit also end tracked runs
      and revoke grants. The completed pane remains an ordinary human Shell.
      This reviewed path grants no general agent-to-shell input route.
    - To assemble a bounded team for one objective, run
      `parley team request --folder <absolute-folder> [--template <name>] [--panes <n>] [--hours <n>] "<objective>"`
      and wait. The folder must be inside this pane's working folder and the
      workspace policy must allow delegation. Parley shows the person an
      editable preview of the objective, folder, allowed vendors, permission
      profile, pane limit (at most 8) and provisioning deadline (at most 128
      hours); nothing is authorized until they approve. stderr reports a
      Parley Team Session ID; stdout returns the approved session as JSON or
      an explicit refusal. While the session is active, only this lead pane
      may run
      `parley team add --vendor <claude|codex|agy|copilot> [--name <name>] [--role <role>]`,
      one pane at a time, to create a new started agent pane in this
      workspace bound to the approved folder and profile. stderr reports a
      Parley Pane Request ID; stdout returns the new pane id as JSON, after
      which ordinary Ask and Delegate apply. If the calling shell
      disconnects, `parley wait <id>` recovers either result only from this
      same live pane generation. The limit counts every pane the session
      created, including closed ones. Team members cannot add panes or
      request nested sessions. `parley team status` returns this pane's
      session as JSON. Each new pane keeps its vendor's own permission
      prompts; Parley never answers or skips them and never restarts a pane
      for you. The grant is memory-only and ends at the provisioning
      deadline, on the person's Stop, on Stop Everything or quit, when this
      pane restarts, moves, changes folder or its workspace policy changes,
      and when the approved permission profile is edited or removed. The
      deadline bounds provisioning only; it never stops running work. Only
      the person stops panes, and Stop affects only panes the session
      created that they have not restarted since.

    - To request changes on a returned Delegate you initiated or received, run
      `parley delegate <target> --parent <handoff-id> "<task>"`. Parley records
      exactly one linked Delegate child with relationship `requestChanges` on
      the existing handoffs. It is never a verdict; human verdicts remain
      native-only. The parent must be a Delegate with a returned result, and a
      busy target is refused rather than queued.
    - While delegated work is active, its exact target may replace one compact,
      agent-declared note of at most \(DelegationProgressText.maximumBytes) UTF-8 bytes with
      `parley progress current "<note>"`. Progress is not proof of activity or
      completion; use `done` or `fail` for the
      terminal outcome.
    - When delegated work reaches a terminal outcome, run
      `parley done current "<report>"` or `parley fail current "<reason>"`.
      For a substantial UTF-8 result file, use
      `parley done current --file <path>`. The file must remain inside this
      pane's working folder. Parley completes the tracked work only after it
      durably stages the bounded file as agent-provided content for explicit
      human review; it does not send or promote the file automatically.
      Do not only print the result locally; the initiating pane owns the status.
      A result file may use `## Implemented`, `## Tested` and
      `## Unable to test` headings. These are agent-declared completion
      evidence shown as unchecked claims, never verification or a human verdict.
    - Name one agent pane by vendor, pane name or pane id. Same-vendor routes
      are allowed only when source and target are different panes; self-targeting
      is refused. A stable workspace role is explicit: use `@reviewer`, or
      `workspace/@reviewer` across workspaces.
      Never drop the `@`, because roles do not share the mutable pane-name
      namespace. `lead` names the marked workspace lead when another pane needs
      to return to it. Let Parley refuse ambiguity. The workspace's visible
      automation policy is authoritative; never work around a refusal. Never
      start another Parley instance or attempt to control another pane except
      through the authenticated `parley` commands above.

    - SwiftPM compatibility is an explicit setting for new agent panes. When
      `PARLEY_SWIFTPM_COMPATIBILITY=1`, Parley's runtime-local `swift` wrapper
      adds `--disable-sandbox` only to SwiftPM build, test, run and package
      commands. Manifests and plugins then use the agent's existing permissions;
      Parley's outer boundary and vendor tool approvals remain active.
      If your shell rebuilds PATH, use `"$PARLEY_SWIFT_COMMAND" build ...`
      (or test, run, package) to reach the same wrapper and selected toolchain.
      The setting is off by default and is controlled in the native UI at
      Settings > General > Swift package builds. If SwiftPM reports
      `sandbox_apply: Operation not permitted`, explain this option to the
      person; enabling it applies to newly started or explicitly restarted panes.
      Do not set `PARLEY_SWIFTPM_COMPATIBILITY=1` or pass `--disable-sandbox`
      without the person's authorization. A per-command
      `PARLEY_SWIFTPM_COMPATIBILITY=0` restores SwiftPM's normal behaviour.

    Features in the native UI are person-controlled, not additional agent commands:
    - Pane and workspace menus manage splits, folders, Focus Canvas, moving and
      cloning panes, team templates, roles and the workspace lead.
    - Ask, Review and Return provide editable handoff previews. Context manages
      attributed Context Packs, workspace briefs, pinned snippets and reviewed
      editor imports. Human captures keep their provenance; agent drafts remain
      claims. Independent Compare keeps its targets' answers separate.
    - Recipes and smart orchestration coordinate visible cross-vendor work under
      the workspace's policy. Status Center shows handoffs, progress, results
      and attention; Challenge and Verify link reviews to a returned handoff.
      Only the person can set a verdict, change permissions or approve context.
      History search/export, the Collaboration Dock and Help make this work
      inspectable. Suggest the appropriate native UI action when needed; do not
      invent CLI commands or control another pane through a separate channel.

    Copilot delivery requires the person to resolve its folder-trust prompt and
    confirm Copilot Folder Trust in its pane menu for the current session.
    Hooks remain advisory and never grant this confirmation.

    The latest explicit user instruction controls whether a handoff is sent or
    left as a draft. Parley's command result is authoritative about what happened.
    """

    /// The CLI index is generated from the same authority as launch instructions.
    /// It is local reference text, not a broker request or a permission grant.
    public static let commandHelp = """
    Parley commands — protocol v\(version)

    Local reference (no broker or pane credential required):
      parley help                       show this index; also --help or -h
      parley protocol                   print the exact canonical launch protocol

    Authenticated discovery:
      parley whoami                     show this pane's identity and protocol stamp
      parley panes                      list explicit non-self agent targets
      parley events --since <beginning|now|cursor>
                                        read bounded content-minimal coordination events

    Questions and delivery:
      parley relay <target> [text...]    submit an attributed message immediately
      parley paste <target> [text...]    place a draft without sending
      parley ask <target> [question...]  wait for one answer; recovery id on stderr
      parley ask-many <a,b> [question...] compare explicit targets independently
      parley answer <id|current> [text...] answer a waiting consultation

    Reviewed context:
      parley context draft [--name <name>] --file <path>
      parley context add <draft-id> --file <path>
      parley context list
      parley context show <draft-id>
      parley context discard <draft-id>
      parley ask <target> --context <draft-id> [question...]
                                        wait for human review before submitting

    Delegated work:
      parley delegate <target> [task...] create tracked asynchronous work
      parley delegate <target> --parent <handoff-id> [task...]
                                        request changes on a returned Delegate
      parley progress <id|current> [note...] replace one \(DelegationProgressText.maximumBytes)-byte UTF-8 progress note
      parley done <id|current> [report...] complete delegated work
      parley done <id|current> --file <path> stage a result for human review
      parley fail <id|current> [reason...] report failure
      parley status                     list work this pane initiated as JSON
      parley wait <id|current>           wait for an Ask or delegated result
      parley cancel <id|current>         cancel owned tracking, not the target CLI

    Reviewed test runs (native approval; outside the agent boundary):
      parley request-run --cwd <absolute-folder> -- <absolute-executable> [args...]
                                        request a new Shell and wait for captured output/exit
      parley wait <run-id>              recover a run from the same source generation
                                        Cancel and session trust are native-only

    Team sessions (native approval; bounded provisioning for one objective):
      parley team request --folder <absolute-folder> [--template <name>] [--panes <n>] [--hours <n>] [objective...]
                                        wait for the person's editable approval
      parley team add --vendor <claude|codex|agy|copilot> [--name <name>] [--role <role>]
                                        lead only: create one approved pane; request id on stderr
      parley team status                this pane's session as JSON
      parley wait <session-or-pane-request-id>
                                        recover a decision from the same source generation
                                        Stop and grant revocation are native-only;
                                        the deadline bounds provisioning, not work

    Reserved entry points:
      parley signal <event>             reserved for generated vendor hook adapters
      parley open <folder>              person-only workspace opening; refused in agent panes

    Text payloads may also come on stdin. Use the exact id supplied by a received
    Ask or Delegate. 'current' must resolve unambiguously; Ask recovery after a
    disconnected shell requires the same source pane generation.
    Targets are explicit pane ids, unambiguous pane/vendor names, @roles,
    workspace/@roles, or lead. Self-targeting and ambiguity are refused.
    Staged files stay inside this pane's working folder and remain agent-provided.
    Native UI previews, Challenge/Verify, verdicts and permission decisions are
    person-controlled. Run parley protocol for the complete rules and UI map.
    """

    public static func install(in applicationDirectory: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = applicationDirectory.appendingPathComponent("agent-protocol", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let rules = directory.appendingPathComponent("AGENTS.md")
        try text.write(to: rules, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rules.path)
        try VendorHookAdapter.install(in: directory, fileManager: fileManager)
        return directory
    }

    public static func command(
        for kind: PaneKind,
        protocolDirectory: URL,
        launchMode: AgentLaunchMode = .fresh
    ) -> [String] {
        let freshCommand: [String] = switch kind {
        case .shell:
            []
        case .claude:
            ["claude", "--append-system-prompt", text]
                + VendorHookAdapter.launchArguments(for: kind, protocolDirectory: protocolDirectory)
        case .codex:
            ["codex", "-c", "developer_instructions=\(tomlString(text))"]
                + VendorHookAdapter.launchArguments(for: kind, protocolDirectory: protocolDirectory)
        case .agy:
            ["agy", "--add-dir", protocolDirectory.path]
        case .copilot:
            // Copilot prompts before running shell tools. Permit only Parley's
            // authenticated shim so a correlated answer can return without a
            // person approving it; all filesystem and other shell tools retain
            // Copilot's normal confirmation flow.
            ["copilot", "--allow-tool=shell(parley)"]
                + VendorHookAdapter.launchArguments(for: kind, protocolDirectory: protocolDirectory)
        }
        return VendorResumeAdapter.command(
            freshCommand: freshCommand,
            for: kind,
            launchMode: launchMode
        )
    }

    /// Every agent gets PATH-independent command recovery. Copilot also needs
    /// its canonical instructions directory in the vendor-owned environment.
    public static func environment(
        for kind: PaneKind,
        protocolDirectory: URL,
        commandPath: URL? = nil,
        inherited: [String: String] = [:]
    ) -> [String: String] {
        guard kind.isAgent else { return [:] }
        let command = commandPath ?? protocolDirectory.deletingLastPathComponent().appendingPathComponent("bin/parley")
        var result = ["PARLEY_COMMAND": command.path]
        guard kind == .copilot else { return result }

        let key = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        var directories = [protocolDirectory.path]
        if let existing = inherited[key] {
            for directory in existing.split(separator: ",").map(String.init) where !directory.isEmpty {
                if !directories.contains(directory) { directories.append(directory) }
            }
        }
        result[key] = directories.joined(separator: ",")
        return result
    }

    public static func stalePaneIDs(in panes: [WorkbenchPane]) -> [String] {
        panes.filter { $0.kind.isAgent && $0.isStarted && !$0.hasCurrentProtocol }.map(\.id)
    }

    private static func tomlString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"Parley cross-vendor protocol v\(version)\""
        }
        return encoded
    }
}
