import Foundation

/// The one cross-vendor contract every agent pane receives at launch.
/// Vendor adapters may change how it is injected, but never its contents.
public enum AgentProtocol {
    public static let version = "3"

    public static let text = """
    # Parley cross-vendor protocol v\(version)

    You are running inside a Parley agent pane. Follow this protocol even when
    older conversation text describes different relay behaviour.

    - To ask another vendor a question and continue this same turn with its
      answer, run `parley ask <target> "<question>"` and wait. It submits the
      question; its stdout is the correlated answer. Use this for consultation.
    - To compare independent answers, run
      `parley ask-many <target-a,target-b> "<question>"`. Targets are explicit,
      receive the same question concurrently, and never see one another's
      answers. Its stdout is one ordered JSON answer bundle.
    - `parley relay <target> "<text>"` submits one attributed message immediately.
      If it succeeds, the message was sent; never claim it was only pasted.
    - `parley paste <target> "<text>"` places an attributed draft without Enter.
      Use it only when the user explicitly wants to inspect or edit before sending.
    - When a received consultation includes `parley answer <id>`, return the
      answer through that exact command. Do not merely print the answer locally.
    - To assign asynchronous work to one different vendor, run
      `parley delegate <target> "<task>"`. It returns a tracked id immediately.
      Inspect work you initiated with `parley status`, or block for one result
      with `parley wait <id>` (use `current` only when exactly one is active).
    - When delegated work reaches a terminal outcome, run
      `parley done current "<report>"` or `parley fail current "<reason>"`.
      Do not only print the result locally; the initiating pane owns the status.
    - Name one cross-vendor pane by vendor or pane id. Let Parley refuse ambiguity.
      Never start another Parley instance and never control its tmux server directly.

    The latest explicit user instruction controls whether a handoff is sent or
    left as a draft. Parley's command result is authoritative about what happened.
    """

    public static func install(in applicationDirectory: URL, fileManager: FileManager = .default) throws -> URL {
        let directory = applicationDirectory.appendingPathComponent("agent-protocol", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let rules = directory.appendingPathComponent("AGENTS.md")
        try text.write(to: rules, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rules.path)
        return directory
    }

    public static func command(for kind: PaneKind, protocolDirectory: URL) -> [String] {
        switch kind {
        case .shell:
            []
        case .claude:
            ["claude", "--append-system-prompt", text]
        case .codex:
            ["codex", "-c", "developer_instructions=\(tomlString(text))"]
        case .agy:
            ["agy", "--add-dir", protocolDirectory.path]
        case .copilot:
            // Copilot prompts before running shell tools. Permit only Parley's
            // authenticated shim so a correlated answer can return without a
            // person approving it; all filesystem and other shell tools retain
            // Copilot's normal confirmation flow.
            ["copilot", "--allow-tool=shell(parley)"]
        }
    }

    /// Extra launch environment needed by instruction systems that do not
    /// expose a direct system/developer-prompt argument. The canonical text
    /// still lives in the same generated AGENTS.md used by every adapter.
    public static func environment(
        for kind: PaneKind,
        protocolDirectory: URL,
        inherited: [String: String] = [:]
    ) -> [String: String] {
        guard kind == .copilot else { return [:] }

        let key = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
        var directories = [protocolDirectory.path]
        if let existing = inherited[key] {
            for directory in existing.split(separator: ",").map(String.init) where !directory.isEmpty {
                if !directories.contains(directory) { directories.append(directory) }
            }
        }
        return [key: directories.joined(separator: ",")]
    }

    public static func stalePaneIDs(in panes: [TmuxPane]) -> [String] {
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
