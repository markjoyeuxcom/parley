import Darwin
import Foundation

public enum ContainerPaneError: LocalizedError {
    case refused(String)
    public var errorDescription: String? { if case let .refused(message) = self { message } else { nil } }
}

/// Reviewed configuration, never proof that a container or vendor session survived.
public struct ContainerConfiguration: Codable, Equatable, Sendable {
    public var dockerExecutable: String
    public var daemonEndpoint: String
    public var daemonID: String
    public var imageID: String
    public var imageName: String
    public var gitAccess: ContainerGitAccess?
    public var legacyCodexSandbox: Bool
    public var bypassVendorPermissions: Bool
    public var permissionModeLabel: String { bypassVendorPermissions ? "Vendor permissions bypassed" : "Vendor permissions enabled" }

    private enum CodingKeys: String, CodingKey {
        case dockerExecutable, daemonEndpoint, daemonID, imageID, imageName, gitAccess, legacyCodexSandbox, bypassVendorPermissions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dockerExecutable = try values.decode(String.self, forKey: .dockerExecutable)
        daemonEndpoint = try values.decode(String.self, forKey: .daemonEndpoint)
        daemonID = try values.decode(String.self, forKey: .daemonID)
        imageID = try values.decode(String.self, forKey: .imageID)
        imageName = try values.decode(String.self, forKey: .imageName)
        gitAccess = try values.decodeIfPresent(ContainerGitAccess.self, forKey: .gitAccess)
        legacyCodexSandbox = try values.decode(Bool.self, forKey: .legacyCodexSandbox)
        bypassVendorPermissions = try values.decodeIfPresent(Bool.self, forKey: .bypassVendorPermissions) ?? false
    }
    public init(dockerExecutable: String, daemonEndpoint: String, daemonID: String, imageID: String, imageName: String, legacyCodexSandbox: Bool, gitAccess: ContainerGitAccess? = nil, bypassVendorPermissions: Bool = false) {
        self.dockerExecutable = dockerExecutable; self.daemonEndpoint = daemonEndpoint; self.daemonID = daemonID
        self.imageID = imageID; self.imageName = imageName; self.legacyCodexSandbox = legacyCodexSandbox; self.gitAccess = gitAccess
        self.bypassVendorPermissions = bypassVendorPermissions
    }
}

public struct ContainerLaunchFacts: Equatable, Sendable {
    public var paneID: String
    public var generation: Int
    public var vendor: PaneKind
    public var folder: String
    public var endpoint: String
    public var protocolDirectory: String
    public var shimDirectory: String
    public var uid: UInt32
    public var gid: UInt32
    public var volume: String
    public var owner: String
    public var runtime: String
    public init(paneID: String, generation: Int, vendor: PaneKind, folder: String, endpoint: String,
                protocolDirectory: String, shimDirectory: String, uid: UInt32, gid: UInt32, volume: String, owner: String, runtime: String) {
        self.paneID = paneID; self.generation = generation; self.vendor = vendor; self.folder = folder
        self.endpoint = endpoint; self.protocolDirectory = protocolDirectory; self.shimDirectory = shimDirectory
        self.uid = uid; self.gid = gid; self.volume = volume; self.owner = owner; self.runtime = runtime
    }
}

public enum ContainerLaunchProjection {
    public static let ownerLabel = "com.parley.owner"
    public static let runtimeLabel = "com.parley.runtime"
    public static let paneLabel = "com.parley.pane"
    public static let generationLabel = "com.parley.generation"
    public static let home = "/home/parley"

    public static func validate(_ config: ContainerConfiguration) throws {
        guard !config.bypassVendorPermissions || !config.legacyCodexSandbox else {
            throw ContainerPaneError.refused("Choose vendor permissions with legacy Landlock or bypass vendor permissions, not both.")
        }
        guard config.dockerExecutable.hasPrefix("/"), !config.dockerExecutable.contains("\n"),
              config.daemonEndpoint.hasPrefix("unix:///"), !config.daemonEndpoint.contains("\n"),
              !config.daemonID.isEmpty, config.imageID.hasPrefix("sha256:"), isHex(String(config.imageID.dropFirst(7)), length: 64) else {
            throw ContainerPaneError.refused("Choose a running local Unix-socket Docker daemon and a locally installed image. Remote daemons are unsupported.")
        }
    }

    public static func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func path(_ value: String) throws {
        guard value.hasPrefix("/"), value != "/", !value.contains(","), !value.contains("\""),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.split(separator: "/").contains("..") else {
            throw ContainerPaneError.refused("Container mounts require absolute, bounded paths without control characters, commas or quotes.")
        }
    }

    public static func createArguments(configuration: ContainerConfiguration, facts: ContainerLaunchFacts, vendorArguments: [String]) throws -> [String] {
        try validate(configuration)
        guard [.claude, .codex].contains(facts.vendor), facts.uid != 0, facts.generation >= 0 else {
            throw ContainerPaneError.refused("Container panes currently support Claude Code and Codex as a non-root user.")
        }
        for value in [facts.folder, facts.endpoint, facts.protocolDirectory, facts.shimDirectory] { try path(value) }
        let transportRoot = URL(fileURLWithPath: facts.endpoint).deletingLastPathComponent().path
        let mountedFolders = [facts.folder] + (configuration.gitAccess.map { [$0.commonDirectory] } ?? [])
        if let access = configuration.gitAccess {
            try path(access.commonDirectory)
            guard access.folder == facts.folder, !facts.folder.hasPrefix(access.commonDirectory + "/"),
                  !access.commonDirectory.hasPrefix(facts.folder + "/"), access.commonDirectory != facts.folder else {
                throw ContainerPaneError.refused("The reviewed shared Git mount does not match the working folder.")
            }
        }
        for protected in [transportRoot, facts.protocolDirectory, facts.shimDirectory] {
            guard mountedFolders.allSatisfy({ !protected.hasPrefix($0 + "/") && !$0.hasPrefix(protected + "/") && protected != $0 }) else {
                throw ContainerPaneError.refused("The working folder overlaps Parley's container control files.")
            }
        }
        for value in [facts.paneID, facts.owner, facts.volume, facts.runtime] {
            guard !value.isEmpty, value.utf8.count <= 128,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 95].contains($0) }) else {
                throw ContainerPaneError.refused("Invalid container identity.")
            }
        }
        guard !vendorArguments.enumerated().contains(where: { index, argument in
            let compact = argument.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: " ", with: "")
            let previous = index > 0 ? vendorArguments[index - 1] : ""
            return argument.hasPrefix("--dangerously-") || argument.hasPrefix("--allow-dangerously-")
                || ["--yolo", "danger-full-access", "bypassPermissions"].contains(argument)
                || compact == "--sandbox=danger-full-access" || compact == "sandbox_mode=danger-full-access"
                || compact == "--permission-mode=bypassPermissions" || compact == "--ask-for-approval=never"
                || compact == "approval_policy=never" || (argument == "never" && ["-a", "--ask-for-approval"].contains(previous))
        }) else {
            throw ContainerPaneError.refused("Vendor permission bypass is chosen in the native container review, never supplied through command arguments.")
        }
        let name = "parley-\(facts.owner)"
        var args = ["--host", configuration.daemonEndpoint, "create", "--rm", "-it", "--init", "--name", name,
            "--log-driver=none", "--cap-drop=ALL", "--security-opt=no-new-privileges=true", "--network=bridge",
            "--user", "\(facts.uid):\(facts.gid)", "--workdir", facts.folder]
        for (key, value) in [(ownerLabel, facts.owner), (runtimeLabel, facts.runtime), (paneLabel, facts.paneID), (generationLabel, String(facts.generation))] {
            args += ["--label", "\(key)=\(value)"]
        }
        args += ["--mount", "type=bind,source=\(facts.folder),target=\(facts.folder)",
            "--mount", "type=bind,source=\(facts.endpoint),target=\(facts.endpoint)",
            "--mount", "type=bind,source=\(facts.protocolDirectory),target=\(facts.protocolDirectory),readonly",
            "--mount", "type=bind,source=\(facts.shimDirectory),target=\(facts.shimDirectory),readonly",
            "--mount", "type=volume,source=\(facts.volume),target=\(home)",
            "--env", "HOME=\(home)", "--env", "PATH=\(facts.shimDirectory):/usr/local/bin:/usr/bin:/bin",
            "--env", "TERM=xterm-256color", "--env", "COLORTERM=truecolor",
            "--env", "PARLEY_RELAY_TOKEN", "--env", "PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)",
            "--env", "PARLEY_COMMAND=\(facts.shimDirectory)/parley", "--env", "PARLEY_EXECUTION_BOUNDARY=container"]
        if let access = configuration.gitAccess {
            args += ["--mount", "type=bind,source=\(access.commonDirectory),target=\(access.commonDirectory)"]
        }
        if facts.runtime == "DEV" { args += ["--env", "PARLEY_RUNTIME=DEV"] }
        args += ["--entrypoint", "/usr/local/bin/\(facts.vendor.rawValue)", configuration.imageID]
        if configuration.bypassVendorPermissions {
            args += facts.vendor == .codex ? ["--dangerously-bypass-approvals-and-sandbox"] : ["--dangerously-skip-permissions"]
        }
        if configuration.legacyCodexSandbox && facts.vendor == .codex { args += ["-c", "features.use_legacy_landlock=true"] }
        args += vendorArguments
        return args
    }

    public static func attachArguments(configuration: ContainerConfiguration, containerID: String) throws -> [String] {
        try validate(configuration)
        guard isHex(containerID, length: 64) else { throw ContainerPaneError.refused("The container has no verified creation receipt.") }
        return ["--host", configuration.daemonEndpoint, "start", "--attach", "--interactive", containerID]
    }
}
