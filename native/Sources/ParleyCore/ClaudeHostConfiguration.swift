import Foundation

/// Whether Claude Code's own sandbox is switched on for a folder, read from
/// the places Claude reads it, in Claude's precedence: managed settings, the
/// environment, the project's local settings, the project's shared settings,
/// the person's settings. `enabled` is nil when nothing sets it or nothing
/// could be read; unknown is never reported as off or on.
public struct ClaudeSandboxFact: Equatable, Sendable {
    public let enabled: Bool?
    /// Where the value came from, for the review and for `whoami`.
    public let source: String?

    public init(enabled: Bool?, source: String?) {
        self.enabled = enabled
        self.source = source
    }

    public static let unset = ClaudeSandboxFact(enabled: nil, source: nil)
}

/// Claude Code's sandbox settings are the person's own configuration.
/// Parley reads one boolean from them and never writes them: whether the
/// sandbox is on decides only how Parley describes and checks a pane's
/// requests. The sandbox denies Unix sockets unless its `allowUnixSockets`
/// list admits one, so a pane under it may not reach the ticket socket.
public enum ClaudeHostConfiguration {
    public static let maximumSettingsBytes = 1 << 20
    public static let managedSettingsFile = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json")
    public static let forceEnvironmentKey = "CLAUDE_CODE_FORCE_SANDBOX"

    public static func sandbox(
        folder: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        managedFile: URL = managedSettingsFile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> ClaudeSandboxFact {
        if let value = enabled(in: managedFile, fileManager: fileManager) {
            return ClaudeSandboxFact(enabled: value, source: managedFile.path)
        }
        if let forced = environment[forceEnvironmentKey], ["1", "true", "yes"].contains(forced.lowercased()) {
            return ClaudeSandboxFact(enabled: true, source: forceEnvironmentKey)
        }
        let project = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(".claude", isDirectory: true)
        for file in [project.appendingPathComponent("settings.local.json"), project.appendingPathComponent("settings.json"),
                     home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("settings.json")] {
            if let value = enabled(in: file, fileManager: fileManager) {
                return ClaudeSandboxFact(enabled: value, source: file.path)
            }
        }
        return .unset
    }

    /// `sandbox.enabled` from one settings file, or nil when the file is
    /// absent, unreadable, too large, not a JSON object, or silent on it.
    static func enabled(in file: URL, fileManager: FileManager) -> Bool? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size <= maximumSettingsBytes,
              let data = fileManager.contents(atPath: file.path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sandbox = object["sandbox"] as? [String: Any],
              let enabled = sandbox["enabled"] as? Bool else { return nil }
        return enabled
    }
}
