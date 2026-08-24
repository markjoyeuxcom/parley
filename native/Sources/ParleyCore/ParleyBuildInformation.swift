import Foundation

/// One projection for the visible About window and copied diagnostic text.
/// Packaged values come from Info.plist; unbundled development values are
/// supplied by the Swift runner so the UI never has to execute Git itself.
public struct ParleyBuildInformation: Equatable, Sendable {
    public let applicationVersion: String
    public let buildNumber: String
    public let sourceCommit: String?
    public let sourceBranch: String?
    public let sourceDirty: Bool?
    public let runtime: ParleyRuntime
    public let operatingSystem: String
    public let architecture: String
    public let executablePath: String

    public var sourceSummary: String {
        let revision = sourceCommit.map { String($0.prefix(12)) } ?? "unavailable"
        let location = sourceBranch.map { "\($0) @ \(revision)" } ?? revision
        switch sourceDirty {
        case true: return "\(location) · modified"
        case false: return "\(location) · clean"
        case nil: return location
        }
    }

    public var copyableText: String {
        [
            "Parley \(applicationVersion) (\(buildNumber))",
            "Source: \(sourceSummary)",
            "Runtime: \(runtime.mode.label)",
            "Runtime data: \(runtime.applicationDirectory.path)",
            "tmux session: \(runtime.tmuxSessionName)",
            "Preferences: \(runtime.preferenceSuiteName)",
            "Architecture: \(architecture)",
            "macOS: \(operatingSystem)",
            "Agent protocol: v\(AgentProtocol.version)",
            "Core contract: v\(CoreServiceIdentity.currentContractVersion)",
            "Executable: \(executablePath)",
        ].joined(separator: "\n")
    }

    public static func current(runtime: ParleyRuntime) -> ParleyBuildInformation {
        resolve(
            infoDictionary: Bundle.main.infoDictionary,
            environment: ProcessInfo.processInfo.environment,
            runtime: runtime,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: processArchitecture,
            executablePath: Bundle.main.executableURL?.path
                ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        )
    }

    public static func resolve(
        infoDictionary: [String: Any]?,
        environment: [String: String],
        runtime: ParleyRuntime,
        operatingSystem: String,
        architecture: String,
        executablePath: String
    ) -> ParleyBuildInformation {
        func string(_ infoKey: String, environment environmentKey: String) -> String? {
            let bundled = (infoDictionary?[infoKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let bundled, !bundled.isEmpty { return bundled }
            let injected = environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let injected, !injected.isEmpty { return injected }
            return nil
        }

        let dirty: Bool? = {
            if let value = infoDictionary?["ParleySourceDirty"] as? Bool { return value }
            guard let raw = environment["PARLEY_BUILD_DIRTY"]?.lowercased() else { return nil }
            if ["1", "true", "yes"].contains(raw) { return true }
            if ["0", "false", "no"].contains(raw) { return false }
            return nil
        }()

        return ParleyBuildInformation(
            applicationVersion: string("CFBundleShortVersionString", environment: "PARLEY_BUILD_VERSION")
                ?? "development",
            buildNumber: string("CFBundleVersion", environment: "PARLEY_BUILD_NUMBER")
                ?? "development",
            sourceCommit: string("ParleySourceCommit", environment: "PARLEY_BUILD_COMMIT"),
            sourceBranch: string("ParleySourceBranch", environment: "PARLEY_BUILD_BRANCH"),
            sourceDirty: dirty,
            runtime: runtime,
            operatingSystem: operatingSystem,
            architecture: architecture,
            executablePath: executablePath
        )
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
