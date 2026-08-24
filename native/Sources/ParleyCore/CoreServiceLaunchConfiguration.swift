import Foundation

public enum CoreServiceLaunchMode: Equatable, Sendable {
    case foregroundLauncher
    case loginAgent
}

public struct CoreServiceLaunchConfiguration: Equatable, Sendable {
    public let applicationDirectory: URL
    public let cwd: String
    public let mode: CoreServiceLaunchMode
    public let tmuxSessionName: String
    public let runtimeMarker: String?

    public var bootstrapsTmux: Bool { mode == .foregroundLauncher }

    public init(
        applicationDirectory: URL,
        cwd: String,
        mode: CoreServiceLaunchMode,
        tmuxSessionName: String = "parley",
        runtimeMarker: String? = nil
    ) {
        self.applicationDirectory = applicationDirectory
        self.cwd = cwd
        self.mode = mode
        self.tmuxSessionName = tmuxSessionName
        self.runtimeMarker = runtimeMarker
    }

    public static func resolve(
        arguments: [String],
        homeDirectory: URL,
        currentDirectory: String
    ) -> CoreServiceLaunchConfiguration {
        let mode: CoreServiceLaunchMode = arguments.contains("--login-agent")
            ? .loginAgent
            : .foregroundLauncher
        let applicationDirectory = value(after: "--application-directory", in: arguments)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? homeDirectory
                .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
                .standardizedFileURL
        let cwd = value(after: "--cwd", in: arguments)
            ?? (mode == .loginAgent ? homeDirectory.standardizedFileURL.path : currentDirectory)
        let tmuxSessionName = value(after: "--tmux-session", in: arguments)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "parley"
        let runtimeMarker = value(after: "--runtime-marker", in: arguments)
            .flatMap { $0.isEmpty ? nil : $0 }
        return CoreServiceLaunchConfiguration(
            applicationDirectory: applicationDirectory,
            cwd: cwd,
            mode: mode,
            tmuxSessionName: tmuxSessionName,
            runtimeMarker: runtimeMarker
        )
    }

    private static func value(after name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

public enum CoreLoginItemChangePolicy {
    private static let activeStates: Set<RelayHandoffState> = [
        .created, .delivered, .waiting, .answered,
    ]

    public static func canDisable(
        activeConsultationCount: Int,
        handoffs: [RelayHandoff]
    ) -> Bool {
        activeConsultationCount == 0
            && !handoffs.contains(where: { activeStates.contains($0.state) })
    }
}
