import Foundation

public enum VendorHookSignal: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case sessionStarted = "session-started"
    case turnStarted = "turn-started"
    case turnEnded = "turn-ended"
    case awaitingPermission = "awaiting-permission"
    case notification
    case sessionEnded = "session-ended"

    public func runtimeState(after previous: VendorRuntimeState?) -> VendorRuntimeState {
        switch self {
        case .sessionStarted, .turnEnded:
            .ready
        case .turnStarted:
            .working
        case .awaitingPermission:
            .awaitingPermission
        case .notification:
            previous ?? .unknown
        case .sessionEnded:
            .unknown
        }
    }

    var isDurableActivity: Bool {
        switch self {
        case .sessionStarted, .awaitingPermission, .sessionEnded: true
        case .turnStarted, .turnEnded, .notification: false
        }
    }

    var activityKind: RelayActivityEventKind {
        switch self {
        case .sessionStarted: .vendorSessionStarted
        case .turnStarted: .vendorTurnStarted
        case .turnEnded: .vendorTurnEnded
        case .awaitingPermission: .vendorAwaitingPermission
        case .notification: .vendorNotification
        case .sessionEnded: .vendorSessionEnded
        }
    }

    init?(activityKind: RelayActivityEventKind) {
        switch activityKind {
        case .vendorSessionStarted: self = .sessionStarted
        case .vendorTurnStarted: self = .turnStarted
        case .vendorTurnEnded: self = .turnEnded
        case .vendorAwaitingPermission: self = .awaitingPermission
        case .vendorNotification: self = .notification
        case .vendorSessionEnded: self = .sessionEnded
        default: return nil
        }
    }
}

/// Installs only runtime-owned, content-free hook definitions. Claude and
/// Copilot accept an additional settings/plugin path for one launch. Codex
/// accepts equivalent inline config values. Agy documents hooks only in user
/// or workspace configuration, so Parley leaves it unsupported rather than
/// mutating either location or claiming an adapter it cannot bind safely.
public enum VendorHookAdapter {
    public static func supportedSignals(for vendor: PaneKind) -> Set<VendorHookSignal> {
        switch vendor {
        case .claude, .copilot:
            Set(VendorHookSignal.allCases)
        case .codex:
            Set(VendorHookSignal.allCases).subtracting([.notification])
        case .agy, .shell:
            []
        }
    }

    public static func install(in protocolDirectory: URL, fileManager: FileManager = .default) throws {
        let shimExecutable = managedShimPath(for: protocolDirectory)
        let claude = protocolDirectory.appendingPathComponent("claude-hooks.json")
        try writeJSON(claudeHooks(shimExecutable: shimExecutable), to: claude, fileManager: fileManager)

        let copilotDirectory = protocolDirectory.appendingPathComponent("copilot-hooks", isDirectory: true)
        try fileManager.createDirectory(
            at: copilotDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: copilotDirectory.path)
        try writeJSON([
            "name": "parley-runtime-hooks",
            "description": "Content-free Parley lifecycle signals.",
            "version": "1.0.0",
            "hooks": "hooks.json",
        ], to: copilotDirectory.appendingPathComponent("plugin.json"), fileManager: fileManager)
        try writeJSON(
            copilotHooks(shimExecutable: shimExecutable),
            to: copilotDirectory.appendingPathComponent("hooks.json"),
            fileManager: fileManager
        )
    }

    public static func launchArguments(for vendor: PaneKind, protocolDirectory: URL) -> [String] {
        let shimExecutable = managedShimPath(for: protocolDirectory)
        return switch vendor {
        case .claude:
            ["--settings", protocolDirectory.appendingPathComponent("claude-hooks.json").path]
        case .codex:
            codexHooks(shimExecutable: shimExecutable).flatMap { ["-c", $0] }
        case .copilot:
            ["--plugin-dir", protocolDirectory.appendingPathComponent("copilot-hooks", isDirectory: true).path]
        case .agy, .shell:
            []
        }
    }

    private static func claudeHooks(shimExecutable: String) -> [String: Any] {
        [
            "hooks": [
                "SessionStart": claudeGroup(.sessionStarted, shimExecutable: shimExecutable),
                "UserPromptSubmit": claudeGroup(.turnStarted, shimExecutable: shimExecutable),
                "Stop": claudeGroup(.turnEnded, shimExecutable: shimExecutable),
                "PermissionRequest": claudeGroup(.awaitingPermission, shimExecutable: shimExecutable),
                "Notification": claudeGroup(.notification, shimExecutable: shimExecutable, matcher: ""),
                "SessionEnd": claudeGroup(.sessionEnded, shimExecutable: shimExecutable),
            ],
        ]
    }

    private static func claudeGroup(
        _ signal: VendorHookSignal,
        shimExecutable: String,
        matcher: String? = nil
    ) -> [[String: Any]] {
        var group: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": hookCommand(shimExecutable: shimExecutable, signal: signal),
                "timeout": 3,
            ]],
        ]
        if let matcher { group["matcher"] = matcher }
        return [group]
    }

    private static func codexHooks(shimExecutable: String) -> [String] {
        [
            codexHook("SessionStart", .sessionStarted, shimExecutable: shimExecutable),
            codexHook("UserPromptSubmit", .turnStarted, shimExecutable: shimExecutable),
            codexHook("Stop", .turnEnded, shimExecutable: shimExecutable),
            codexHook("PermissionRequest", .awaitingPermission, shimExecutable: shimExecutable),
            codexHook("SessionEnd", .sessionEnded, shimExecutable: shimExecutable),
        ]
    }

    private static func codexHook(
        _ event: String,
        _ signal: VendorHookSignal,
        shimExecutable: String
    ) -> String {
        let command = jsonString(hookCommand(shimExecutable: shimExecutable, signal: signal))
        return "hooks.\(event)=[{ hooks = [{ type = \"command\", command = \(command), timeout = 3 }] }]"
    }

    private static func copilotHooks(shimExecutable: String) -> [String: Any] {
        [
            "version": 1,
            "hooks": [
                "sessionStart": copilotGroup(.sessionStarted, shimExecutable: shimExecutable),
                "userPromptSubmitted": copilotGroup(.turnStarted, shimExecutable: shimExecutable),
                "agentStop": copilotGroup(.turnEnded, shimExecutable: shimExecutable),
                "permissionRequest": copilotGroup(.awaitingPermission, shimExecutable: shimExecutable),
                "notification": copilotGroup(.notification, shimExecutable: shimExecutable),
                "sessionEnd": copilotGroup(.sessionEnded, shimExecutable: shimExecutable),
            ],
        ]
    }

    private static func copilotGroup(
        _ signal: VendorHookSignal,
        shimExecutable: String
    ) -> [[String: Any]] {
        [[
            "type": "command",
            "exec": "/bin/sh",
            "args": ["-c", hookCommand(shimExecutable: shimExecutable, signal: signal)],
            "timeoutSec": 3,
        ]]
    }

    private static func managedShimPath(for protocolDirectory: URL) -> String {
        protocolDirectory.deletingLastPathComponent()
            .appendingPathComponent("bin/parley")
            .path
    }

    private static func hookCommand(shimExecutable: String, signal: VendorHookSignal) -> String {
        "\(shellQuote(shimExecutable)) signal \(signal.rawValue) </dev/null >/dev/null 2>&1 || true"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func writeJSON(
        _ object: Any,
        to file: URL,
        fileManager: FileManager
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
