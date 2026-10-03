import Foundation

/// Whether the person's own Agy settings let Parley's command run without a
/// prompt. Agy has no automatic reviewer, and Parley never writes a vendor's
/// settings, so the launch review used to carry the whole recipe in its
/// approvals caption and could not say whether it had been followed (Agy's and
/// Codex's reviews of 3 October 2026). This only reads.
///
/// It reports entries, not Agy's whole decision: only the exact entry and
/// `command(*)` are recognised, and other prefix or regex rules are said to
/// be there, never evaluated (Codex's review of MR !146).
public enum AgyParleyAllowFact: Equatable, Sendable {
    /// `permissions.allow` holds the entry, or `command(*)`. `otherRules`:
    /// ask or deny also hold rules Parley does not evaluate, which Agy
    /// applies first.
    case allowed(byWildcard: Bool, otherRules: Bool)
    /// `permissions.ask` names it or every command; ask wins over allow.
    case asked
    /// `permissions.deny` names it or every command; Agy refuses to run it.
    case denied
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
        func names(_ list: [String]) -> Bool { list.contains { $0 == allowEntry || $0 == wildcardEntry } }
        // Agy applies Deny > Ask > Allow.
        if names(rules("deny")) { return .denied }
        if names(rules("ask")) { return .asked }
        let otherRules = !(rules("deny") + rules("ask")).filter { $0.hasPrefix("command(") }.isEmpty
        let allow = rules("allow")
        if allow.contains(allowEntry) { return .allowed(byWildcard: false, otherRules: otherRules) }
        if allow.contains(wildcardEntry) { return .allowed(byWildcard: true, otherRules: otherRules) }
        return .absent
    }

    /// One line for the launch review.
    public static func describe(_ fact: AgyParleyAllowFact) -> String {
        switch fact {
        case let .allowed(byWildcard, otherRules):
            (byWildcard
                ? "Agy's allow list holds command(*), which covers Parley's command."
                : "Agy's allow list holds Parley's entry.")
                + (otherRules ? " Its ask or deny lists also hold command rules, which Agy applies first and Parley does not evaluate." : "")
        case .asked:
            "Agy's ask list names Parley's command or every command, and Agy applies ask before allow, so it asks each time."
        case .denied:
            "Agy's deny list names Parley's command or every command, so Agy refuses to run it, and Parley's coordination commands fail in that pane."
        case .absent:
            "Agy's settings have no allow entry for Parley's command, so Agy asks each time an agent runs it."
        case .unknown:
            "Parley could not read Agy's settings, so whether Agy will ask is unknown."
        }
    }
}
