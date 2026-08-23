import Foundation

public enum CoreServiceLaunchMode: Equatable, Sendable {
    case foregroundLauncher
    case loginAgent
}

public struct CoreServiceLaunchConfiguration: Equatable, Sendable {
    public let applicationDirectory: URL
    public let cwd: String
    public let mode: CoreServiceLaunchMode

    public var bootstrapsTmux: Bool { mode == .foregroundLauncher }

    public init(
        applicationDirectory: URL,
        cwd: String,
        mode: CoreServiceLaunchMode
    ) {
        self.applicationDirectory = applicationDirectory
        self.cwd = cwd
        self.mode = mode
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
        return CoreServiceLaunchConfiguration(
            applicationDirectory: applicationDirectory,
            cwd: cwd,
            mode: mode
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
