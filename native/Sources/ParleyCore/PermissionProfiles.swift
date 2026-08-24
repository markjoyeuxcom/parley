import Darwin
import Foundation

/// Vendor-neutral intent. Adapters may translate these capabilities only
/// through mechanisms their installed CLI actually supports.
public enum PermissionCapability: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case projectRead
    case repositoryInspection
    case projectWrite
    case projectToolExecution
    case localProcessExecution
    case networkAccess
    case externalFileAccess
    case gitRemoteMutation
    case deployment
    case infrastructureMutation
}

public enum PermissionRule: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case allow
    case requireApproval
    case deny
}

public enum PermissionRootMode: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case paneFolder
    case exactApprovedRoots
}

public enum PermissionProfileLifetime: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case session
    case remembered
}

/// These are not editable profile capabilities. Every resolved profile carries
/// the complete set, no adapter translates one into a grant, and Parley's
/// mandatory Seatbelt boundary separately protects its concrete control paths.
public enum PermissionHardBoundary: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case parleyControlPlane
    case credentialsAndKeychains
    case permissionBypass
    case privilegeEscalation
    case destructiveHostOperations
}

public struct PermissionProfileDefinition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let isBuiltIn: Bool
    public let rootMode: PermissionRootMode
    public let defaultLifetime: PermissionProfileLifetime
    public let rules: [PermissionCapability: PermissionRule]

    public init(
        id: String,
        name: String,
        summary: String,
        isBuiltIn: Bool,
        rootMode: PermissionRootMode,
        defaultLifetime: PermissionProfileLifetime,
        rules: [PermissionCapability: PermissionRule]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.isBuiltIn = isBuiltIn
        self.rootMode = rootMode
        self.defaultLifetime = defaultLifetime
        self.rules = rules
    }

    public func rule(for capability: PermissionCapability) -> PermissionRule {
        rules[capability] ?? .deny
    }

    public func clone(id: String, name: String) -> PermissionProfileDefinition {
        PermissionProfileDefinition(
            id: id,
            name: name,
            summary: summary,
            isBuiltIn: false,
            rootMode: rootMode,
            defaultLifetime: defaultLifetime,
            rules: rules
        )
    }

    public static let builtIns: [PermissionProfileDefinition] = [
        PermissionProfileDefinition(
            id: "review-only",
            name: "Review only",
            summary: "Project reads and repository inspection without project mutation.",
            isBuiltIn: true,
            rootMode: .paneFolder,
            defaultLifetime: .remembered,
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
                .projectWrite: .deny,
                .projectToolExecution: .deny,
                .localProcessExecution: .deny,
                .externalFileAccess: .deny,
                .gitRemoteMutation: .deny,
                .deployment: .deny,
                .infrastructureMutation: .deny,
            ])
        ),
        PermissionProfileDefinition(
            id: "default",
            name: "Default",
            summary: "Routine project reads; writes and execution remain explicit vendor decisions.",
            isBuiltIn: true,
            rootMode: .paneFolder,
            defaultLifetime: .remembered,
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
            ])
        ),
        PermissionProfileDefinition(
            id: "flexible",
            name: "Flexible",
            summary: "Project-local reads, writes, tests and builds; broader effects remain explicit.",
            isBuiltIn: true,
            rootMode: .paneFolder,
            defaultLifetime: .remembered,
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
                .projectWrite: .allow,
                .projectToolExecution: .allow,
            ])
        ),
        PermissionProfileDefinition(
            id: "broad-workspace",
            name: "Broad workspace",
            summary: "Broad local work inside exact approved roots; external and consequential actions remain explicit.",
            isBuiltIn: true,
            rootMode: .exactApprovedRoots,
            defaultLifetime: .session,
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
                .projectWrite: .allow,
                .projectToolExecution: .allow,
                .localProcessExecution: .allow,
            ])
        ),
    ]

    private static func completeRules(
        _ overrides: [PermissionCapability: PermissionRule]
    ) -> [PermissionCapability: PermissionRule] {
        Dictionary(uniqueKeysWithValues: PermissionCapability.allCases.map { capability in
            (capability, overrides[capability] ?? .requireApproval)
        })
    }
}

public struct PermissionProfileSelection: Codable, Equatable, Sendable {
    public let profileID: String
    public let approvedRoots: [String]
    public let lifetime: PermissionProfileLifetime

    public init(profileID: String, approvedRoots: [String], lifetime: PermissionProfileLifetime) {
        self.profileID = profileID
        self.approvedRoots = approvedRoots
        self.lifetime = lifetime
    }

    /// tmux user options are strings. Base64 keeps paths and JSON punctuation
    /// out of tmux's format language while retaining a portable durable value.
    public var tmuxMetadataValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return data.base64EncodedString()
    }

    public init?(tmuxMetadataValue: String) {
        guard !tmuxMetadataValue.isEmpty,
              let data = Data(base64Encoded: tmuxMetadataValue),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }
}

public struct EffectivePermissionProfile: Equatable, Sendable {
    public let definition: PermissionProfileDefinition
    public let selection: PermissionProfileSelection
    public let hardBoundaries: Set<PermissionHardBoundary>

    public var approvedRoots: [String] { selection.approvedRoots }
    public var lifetime: PermissionProfileLifetime { selection.lifetime }
}

/// A profile expresses more than any vendor CLI currently enforces. Parley
/// therefore distinguishes exact enforcement from a safe partial translation
/// and from launch guidance that the vendor must still confirm itself.
public enum PermissionEnforcementLevel: String, Codable, Equatable, Sendable {
    case enforced
    case partiallyEnforced
    case guidanceOnly

    public var label: String {
        switch self {
        case .enforced: "Enforced"
        case .partiallyEnforced: "Partially enforced"
        case .guidanceOnly: "Guidance only"
        }
    }
}

public struct PermissionProfileLaunchPlan: Equatable, Sendable {
    public let arguments: [String]
    public let enforcement: PermissionEnforcementLevel
    public let detail: String

    public init(arguments: [String], enforcement: PermissionEnforcementLevel, detail: String) {
        self.arguments = arguments
        self.enforcement = enforcement
        self.detail = detail
    }
}

/// Translate vendor-neutral intent only through documented, non-bypass launch
/// controls exposed by the installed CLIs. These arguments are intentionally
/// conservative: an absent vendor control becomes guidance, never a claim that
/// Parley enforced a capability the CLI does not expose.
public enum PermissionProfileAdapter {
    public static func launchPlan(
        for kind: PaneKind,
        profile: EffectivePermissionProfile
    ) -> PermissionProfileLaunchPlan {
        guard kind.isAgent else {
            return PermissionProfileLaunchPlan(
                arguments: [],
                enforcement: .guidanceOnly,
                detail: "Shell panes use the person's interactive shell permissions."
            )
        }

        let write = profile.definition.rule(for: .projectWrite)
        let rootArguments = profile.definition.rootMode == .exactApprovedRoots
            ? profile.approvedRoots.flatMap { ["--add-dir", $0] }
            : []
        let arguments: [String]
        let detail: String

        switch kind {
        case .shell:
            arguments = []
            detail = "Shell panes use the person's interactive shell permissions."
        case .claude:
            let mode = switch write {
            case .allow: "acceptEdits"
            case .requireApproval: "manual"
            case .deny: "plan"
            }
            arguments = ["--permission-mode", mode] + rootArguments
            detail = "Claude permission mode and exact additional directories are configured at launch."
        case .codex:
            let sandbox = write == .allow ? "workspace-write" : "read-only"
            arguments = ["--sandbox", sandbox, "--ask-for-approval", "on-request"] + rootArguments
            detail = "Codex sandbox and approval policy are configured at launch."
        case .agy:
            let mode = write == .allow ? "accept-edits" : "plan"
            arguments = ["--mode", mode, "--sandbox"] + rootArguments
            detail = "Agy mode, sandbox and exact additional directories are configured at launch."
        case .copilot:
            arguments = (write == .deny ? ["--plan"] : []) + rootArguments
            detail = "Copilot plan mode and exact additional directories are configured where supported."
        }

        return PermissionProfileLaunchPlan(
            arguments: arguments,
            enforcement: arguments.isEmpty ? .guidanceOnly : .partiallyEnforced,
            detail: detail + " Vendor prompts remain authoritative for capabilities the CLI cannot express."
        )
    }
}

public enum PermissionProfileError: LocalizedError, Equatable {
    case immutableBuiltIn
    case invalid(String)
    case invalidRoot(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .immutableBuiltIn:
            "Built-in permission profiles are immutable. Clone one to make a custom profile."
        case let .invalid(detail), let .invalidRoot(detail), let .unreadable(detail):
            detail
        }
    }
}

public enum PermissionProfileResolver {
    public static func resolve(
        definition: PermissionProfileDefinition,
        paneFolder: String,
        approvedRoots: [String] = [],
        fileManager: FileManager = .default
    ) throws -> EffectivePermissionProfile {
        try PermissionProfileValidator.validate(definition)

        let requestedRoots: [String]
        switch definition.rootMode {
        case .paneFolder:
            guard approvedRoots.isEmpty else {
                throw PermissionProfileError.invalidRoot(
                    "\(definition.name) is scoped to the pane folder; additional roots require an exact-roots profile."
                )
            }
            requestedRoots = [paneFolder]
        case .exactApprovedRoots:
            guard !approvedRoots.isEmpty else {
                throw PermissionProfileError.invalidRoot(
                    "\(definition.name) requires at least one exact approved root."
                )
            }
            requestedRoots = approvedRoots
        }

        var seen = Set<String>()
        var canonicalRoots: [String] = []
        for root in requestedRoots {
            let canonical = try canonicalDirectory(root, fileManager: fileManager)
            if seen.insert(canonical).inserted { canonicalRoots.append(canonical) }
        }

        return EffectivePermissionProfile(
            definition: definition,
            selection: PermissionProfileSelection(
                profileID: definition.id,
                approvedRoots: canonicalRoots,
                lifetime: definition.defaultLifetime
            ),
            hardBoundaries: Set(PermissionHardBoundary.allCases)
        )
    }

    private static func canonicalDirectory(_ path: String, fileManager: FileManager) throws -> String {
        guard path.hasPrefix("/") else {
            throw PermissionProfileError.invalidRoot("Permission roots must be absolute paths: \(path)")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              let resolved = realpath(path, nil) else {
            throw PermissionProfileError.invalidRoot("Permission root is not an existing directory: \(path)")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private enum PermissionProfileValidator {
    static func validate(_ profile: PermissionProfileDefinition) throws {
        let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !profile.id.isEmpty,
              profile.id.count <= 80,
              profile.id.unicodeScalars.allSatisfy(identifierCharacters.contains) else {
            throw PermissionProfileError.invalid("Permission profile ids use lowercase letters, digits and hyphens only.")
        }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw PermissionProfileError.invalid("Permission profile names must be 1–80 characters.")
        }
        let summary = profile.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 300 else {
            throw PermissionProfileError.invalid("Permission profile summaries must be 1–300 characters.")
        }
        guard Set(profile.rules.keys) == Set(PermissionCapability.allCases) else {
            throw PermissionProfileError.invalid("Permission profiles must decide every vendor-neutral capability.")
        }
        for capability in [
            PermissionCapability.gitRemoteMutation,
            .deployment,
            .infrastructureMutation,
        ] where profile.rule(for: capability) == .allow {
            throw PermissionProfileError.invalid(
                "Git push, deployment and infrastructure mutation must remain explicit decisions."
            )
        }
    }
}

public final class PermissionProfileStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let customProfiles: [PermissionProfileDefinition]
    }

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func profiles() throws -> [PermissionProfileDefinition] {
        try lock.withLock { PermissionProfileDefinition.builtIns + (try loadCustomLocked()) }
    }

    public func saveCustom(_ profile: PermissionProfileDefinition) throws {
        try lock.withLock {
            guard !profile.isBuiltIn else { throw PermissionProfileError.immutableBuiltIn }
            guard profile.id.hasPrefix("custom-") else {
                throw PermissionProfileError.invalid("Custom permission profile ids must begin with custom-.")
            }
            try PermissionProfileValidator.validate(profile)
            var profiles = try loadCustomLocked()
            if let conflict = profiles.first(where: {
                $0.id != profile.id && $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
            }) {
                throw PermissionProfileError.invalid("A custom permission profile is already named \(conflict.name).")
            }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            try writeLocked(profiles)
        }
    }

    public func deleteCustom(id: String) throws {
        try lock.withLock {
            guard !PermissionProfileDefinition.builtIns.contains(where: { $0.id == id }) else {
                throw PermissionProfileError.immutableBuiltIn
            }
            var profiles = try loadCustomLocked()
            profiles.removeAll(where: { $0.id == id })
            try writeLocked(profiles)
        }
    }

    private func loadCustomLocked() throws -> [PermissionProfileDefinition] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        do {
            try validateExistingFile()
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else {
                throw PermissionProfileError.unreadable(
                    "Unsupported permission profile version \(document.version)."
                )
            }
            for profile in document.customProfiles {
                guard !profile.isBuiltIn,
                      profile.id.hasPrefix("custom-"),
                      !PermissionProfileDefinition.builtIns.contains(where: { $0.id == profile.id }) else {
                    throw PermissionProfileError.unreadable("The custom permission profile file contains a built-in profile.")
                }
                try PermissionProfileValidator.validate(profile)
            }
            return document.customProfiles
        } catch let error as PermissionProfileError {
            throw error
        } catch {
            throw PermissionProfileError.unreadable(
                "Permission profiles could not be read: \(error.localizedDescription)"
            )
        }
    }

    private func writeLocked(_ profiles: [PermissionProfileDefinition]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, customProfiles: profiles)).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw PermissionProfileError.unreadable(
                "The permission profile file is not an owner-only regular file."
            )
        }
    }
}
