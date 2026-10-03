import Foundation

/// Whether the person's own Agy settings let Parley's command run without a
/// prompt. Agy has no automatic reviewer, and Parley never writes a vendor's
/// settings, so the launch review used to carry the whole recipe in its
/// approvals caption and could not say whether it had been followed (Agy's and
/// Codex's reviews of 3 October 2026). This only reads.
public enum AgyParleyAllowFact: Equatable, Sendable {
    /// `permissions.allow` holds the entry, or `command(*)`.
    case allowed(byWildcard: Bool)
    /// An ask or deny rule names it too; Agy evaluates Deny > Ask > Allow.
    case overridden(list: String)
    /// No settings file, or no entry for Parley's command in it.
    case absent
    /// The file exists but could not be read as JSON settings.
    case unknown
}

public enum AgyHostConfiguration {
    /// The rule Parley recommends. Agy matches `command(...)` rules against
    /// the command line as the agent types it, word by word, and the protocol
    /// teaches agents to type `"$PARLEY_COMMAND" ...`; a bare `parley` can
    /// resolve to the router in `~/.local/bin`, which Agy's sandbox refuses
    /// (5873d31, 21 September 2026).
    public static let allowEntry = "command(\"$PARLEY_COMMAND\")"
    static let wildcardEntry = "command(*)"

    /// Agy's user settings, its documented location for permission rules.
    public static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    public static func parleyAllowFact(settingsFile: URL = settingsFile) -> AgyParleyAllowFact {
        guard FileManager.default.fileExists(atPath: settingsFile.path) else { return .absent }
        return parleyAllowFact(settingsData: ClaudeHostConfiguration.boundedRegularFile(
            settingsFile, maximumBytes: ClaudeHostConfiguration.maximumSettingsBytes
        ))
    }

    /// The decision on bytes already read; nil means they could not be read.
    public static func parleyAllowFact(settingsData: Data?) -> AgyParleyAllowFact {
        guard let settingsData,
              let object = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any] else { return .unknown }
        guard let permissions = object["permissions"] as? [String: Any] else { return .absent }
        func rules(_ key: String) -> [String] { (permissions[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        for list in ["deny", "ask"] where rules(list).contains(where: { $0 == allowEntry || $0 == wildcardEntry }) {
            return .overridden(list: list)
        }
        let allow = rules("allow")
        if allow.contains(allowEntry) { return .allowed(byWildcard: false) }
        if allow.contains(wildcardEntry) { return .allowed(byWildcard: true) }
        return .absent
    }

    /// One line for the launch review.
    public static func describe(_ fact: AgyParleyAllowFact) -> String {
        switch fact {
        case .allowed(byWildcard: false):
            "Agy's settings allow Parley's command, so Agy should not ask before running it."
        case .allowed(byWildcard: true):
            "Agy's settings allow every command (command(*)), Parley's included."
        case let .overridden(list):
            "Agy's settings also list Parley's command under \(list), which Agy applies before allow, so it still asks."
        case .absent:
            "Agy's settings have no allow entry for Parley's command, so Agy asks each time an agent runs it."
        case .unknown:
            "Parley could not read Agy's settings, so whether Agy will ask is unknown."
        }
    }
}
