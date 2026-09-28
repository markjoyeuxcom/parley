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

public extension PermissionCapability {
    /// Plain wording for a person reading a launch review, so a capability is
    /// never shown only as a camel-cased identifier.
    var label: String {
        switch self {
        case .projectRead: "reading the project"
        case .repositoryInspection: "inspecting the repository"
        case .projectWrite: "writing in the project"
        case .projectToolExecution: "running project tools"
        case .localProcessExecution: "running local processes"
        case .networkAccess: "network access"
        case .externalFileAccess: "reading files outside the project"
        case .gitRemoteMutation: "changing Git remotes"
        case .deployment: "deploying"
        case .infrastructureMutation: "changing infrastructure"
        }
    }

    static func sentence(_ capabilities: [PermissionCapability]) -> String {
        let labels = capabilities.map(\.label)
        guard let last = labels.last else { return "" }
        return labels.count == 1 ? last : labels.dropLast().joined(separator: ", ") + " and " + last
    }
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


/// These are not editable profile capabilities. Every resolved profile carries
/// the complete set and no adapter translates one into a grant. Host agents
/// use vendor controls; these intentions are not an independent OS boundary.
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
            summary: "Project-local reads, writes, tests, builds and local processes; network and broader effects remain explicit.",
            isBuiltIn: true,
            rootMode: .paneFolder,
            defaultLifetime: .remembered,
            // Both execution rules allow, so no vendor receives a shell
            // restriction from Flexible: Claude gets no ask rule for Bash
            // (only the allow rules for Parley's command) and its prompts are
            // its own. Mark chose this on 13 September 2026 after Flexible had
            // been asking before every Bash command, parley included.
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
                .projectWrite: .allow,
                .projectToolExecution: .allow,
                .localProcessExecution: .allow,
            ])
        ),
        PermissionProfileDefinition(
            id: "flexible-network",
            name: "Flexible + network",
            summary: "Flexible, plus network access: package fetches and HTTP checks run without a prompt where the vendor can enforce it.",
            isBuiltIn: true,
            rootMode: .paneFolder,
            defaultLifetime: .remembered,
            // Codex carries this into its sandbox (network.enabled). Claude,
            // Agy and Copilot have no network sandbox Parley controls, so for
            // them the row is the vendor's own prompt and the plan says so.
            rules: completeRules([
                .projectRead: .allow,
                .repositoryInspection: .allow,
                .projectWrite: .allow,
                .projectToolExecution: .allow,
                .localProcessExecution: .allow,
                .networkAccess: .allow,
            ])
        ),
        PermissionProfileDefinition(
            id: "workspace-folders",
            name: "Workspace folders",
            summary: "Project reads, writes, tests and builds across exact folders chosen from this workspace.",
            isBuiltIn: true,
            rootMode: .exactApprovedRoots,
            defaultLifetime: .session,
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


public struct WorkspaceFolderAccessOption: Identifiable, Equatable, Sendable {
    public let path: String
    public let isPaneFolder: Bool
    public let isApproved: Bool

    public var id: String { path }

    public init(path: String, isPaneFolder: Bool, isApproved: Bool) {
        self.path = path
        self.isPaneFolder = isPaneFolder
        self.isApproved = isApproved
    }
}

public struct WorkspaceFolderAccessSnapshot: Equatable, Sendable {
    public let workspaceFolders: [WorkspaceFolderAccessOption]
    public let otherApprovedRoots: [String]

    public init(workspaceFolders: [WorkspaceFolderAccessOption], otherApprovedRoots: [String]) {
        self.workspaceFolders = workspaceFolders
        self.otherApprovedRoots = otherApprovedRoots
    }
}

/// Projects a pane's reviewed permission roots onto the workspace's current
/// attachment list. Attachments are descriptive until their exact paths occur
/// in the pane selection; manually chosen roots remain visible separately.
public enum WorkspaceFolderAccessProjection {
    public static func project(
        paneFolder: String,
        workspaceFolders: [String],
        approvedRoots: [String]
    ) -> WorkspaceFolderAccessSnapshot {
        let normalizedPaneFolder = WorkspaceFolderIdentity.normalized(paneFolder)
        let normalizedApprovedRoots = normalizedUnique(approvedRoots)
        let normalizedWorkspaceFolders = normalizedUnique(workspaceFolders)

        let options = normalizedWorkspaceFolders.map { folder in
            let isPaneFolder = WorkspaceFolderIdentity.matches(folder, normalizedPaneFolder)
            return WorkspaceFolderAccessOption(
                path: folder,
                isPaneFolder: isPaneFolder,
                isApproved: isPaneFolder || normalizedApprovedRoots.contains {
                    WorkspaceFolderIdentity.matches($0, folder)
                }
            )
        }
        let otherRoots = normalizedApprovedRoots.filter { root in
            !WorkspaceFolderIdentity.matches(root, normalizedPaneFolder)
                && !normalizedWorkspaceFolders.contains {
                    WorkspaceFolderIdentity.matches($0, root)
                }
        }
        return WorkspaceFolderAccessSnapshot(
            workspaceFolders: options,
            otherApprovedRoots: otherRoots
        )
    }

    private static func normalizedUnique(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        return folders.compactMap { folder in
            guard folder.hasPrefix("/") else { return nil }
            let normalized = WorkspaceFolderIdentity.normalized(folder)
            let key = WorkspaceFolderIdentity.matchingKey(normalized)
            guard seen.insert(key).inserted else { return nil }
            return normalized
        }
    }
}

public struct EffectivePermissionProfile: Equatable, Sendable {
    public let definition: PermissionProfileDefinition
    public let selection: PermissionProfileSelection
    public let hardBoundaries: Set<PermissionHardBoundary>

    public var approvedRoots: [String] { selection.approvedRoots }
    public var lifetime: PermissionProfileLifetime { selection.lifetime }
    public var approvals: PermissionApprovalHandling { selection.approvals }
}


/// One sentence of a launch plan, and whether the launch carries the rule it
/// describes or leaves it to the vendor's own prompts.
public struct PermissionLaunchPlanNote: Equatable, Sendable {
    public let text: String
    public let carried: Bool

    public init(text: String, carried: Bool) {
        self.text = text
        self.carried = carried
    }
}

public struct PermissionProfileLaunchPlan: Equatable, Sendable {
    public let arguments: [String]
    public let enforcement: PermissionEnforcementLevel
    /// Every part below joined into one text, for callers that show one line.
    public let detail: String
    /// What the launch arguments configure.
    public let mode: String
    /// The vendor's automatic reviewer, when the selection asks for one.
    public let reviewer: String?
    /// The profile's execution rules: carried as a rule (Claude) or left to
    /// the vendor's prompts (every other vendor). Nil when the profile
    /// restricts nothing there.
    public let execution: PermissionLaunchPlanNote?
    /// The profile's network rule: carried by Codex's sandbox, a vendor
    /// decision everywhere else. Nil when nothing needs saying.
    public let network: PermissionLaunchPlanNote?

    public init(arguments: [String], enforcement: PermissionEnforcementLevel, detail: String,
                mode: String? = nil, reviewer: String? = nil,
                execution: PermissionLaunchPlanNote? = nil, network: PermissionLaunchPlanNote? = nil) {
        self.arguments = arguments
        self.enforcement = enforcement
        self.detail = detail
        self.mode = mode ?? detail
        self.reviewer = reviewer
        self.execution = execution
        self.network = network
    }
}

/// Translate vendor-neutral intent only through documented, non-bypass launch
/// controls exposed by the installed CLIs. These arguments are intentionally
/// conservative: an absent vendor control becomes guidance, never a claim that
/// Parley enforced a capability the CLI does not expose.
public enum PermissionProfileAdapter {
    /// The rule that should govern running a shell command, taken as the
    /// stricter of the two execution capabilities. One vendor tool covers both,
    /// so the narrower intent has to win rather than be averaged away.
    public static func shellCommandRule(_ profile: EffectivePermissionProfile) -> PermissionRule {
        let rules = [profile.definition.rule(for: .projectToolExecution),
                     profile.definition.rule(for: .localProcessExecution)]
        if rules.contains(.deny) { return .deny }
        if rules.contains(.requireApproval) { return .requireApproval }
        return .allow
    }

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
        // Only projectWrite reaches a vendor today. The execution capabilities
        // are recorded, shown in the review, and not translated into any launch
        // argument, so the detail has to say so rather than let a reader assume
        // the whole profile was applied.
        let execution = [PermissionCapability.projectToolExecution, .localProcessExecution]
            .filter { profile.definition.rule(for: $0) != .allow }
        let rootArguments = profile.definition.rootMode == .exactApprovedRoots
            ? profile.approvedRoots.flatMap { ["--add-dir", $0] }
            : []
        let arguments: [String]
        let mode: String
        let reviewerText: String?
        // The vendor's own automatic reviewer, where it has one. Every form
        // keeps the sandbox and the deny and ask rules and can still refuse;
        // none is a skip-all flag, which stays forbidden on the host.
        let reviewer = profile.approvals == .vendorReviewer

        switch kind {
        case .shell:
            arguments = []
            mode = "Shell panes use the person's interactive shell permissions."
            reviewerText = nil
        case .claude:
            let permissionMode = switch write {
            case .allow: reviewer ? "auto" : "acceptEdits"
            case .requireApproval: reviewer ? "auto" : "default"
            case .deny: "plan"
            }
            arguments = ["--permission-mode", permissionMode] + rootArguments
            mode = "Claude permission mode and exact additional directories are configured at launch."
            reviewerText = reviewer
                ? (write == .deny
                    ? "Plan mode leaves nothing for Claude's auto mode classifier to approve, so it is not enabled."
                    : "Auto mode: Claude's classifier approves routine actions and blocks irreversible, destructive or outward-aimed ones; deny and ask rules still apply first.")
                : nil
        case .codex:
            let sandbox = write == .allow ? "workspace-write" : "read-only"
            arguments = ["--sandbox", sandbox, "--ask-for-approval", "on-request"]
                + (reviewer ? ["-c", "approvals_reviewer=auto_review"] : [])
                + rootArguments
            mode = "Codex sandbox and approval policy are configured at launch."
            reviewerText = reviewer ? "Auto review: Codex's reviewer agent decides escalation requests inside the same sandbox; it grants no network or extra roots and can refuse." : nil
        case .agy:
            let agyMode = write == .allow ? "accept-edits" : "plan"
            arguments = ["--mode", agyMode, "--sandbox"] + rootArguments
            mode = "Agy mode, sandbox and exact additional directories are configured at launch."
            reviewerText = reviewer ? "Agy has no automatic reviewer, only a skip-all-permissions flag Parley never passes on the host, so Agy still asks; to stop it asking for Parley's command, add command(\"$PARLEY_COMMAND\") to the allow list in ~/.gemini/antigravity-cli/settings.json yourself. Allow that absolute form, not a bare parley: Agy runs commands through a login shell whose PATH can put ~/.local/bin first, and its sandbox refuses the router there while it admits the runtime shim." : nil
        case .copilot:
            arguments = (write == .deny ? ["--plan"] : [])
                + (reviewer ? ["--assisted-approval"] : [])
                + rootArguments
            mode = "Copilot plan mode and exact additional directories are configured where supported."
            reviewerText = reviewer ? "Assisted approval: Copilot's judge reviews tool permission requests; it needs Copilot's AUTO_APPROVAL feature flag, and Copilot reports if that is off." : nil
        }

        // Claude now carries the execution rule as a permission rule in its
        // settings, so the disclosure has to narrow with the behaviour rather
        // than keep claiming the restriction is dropped.
        let carriesExecution = kind == .claude
        let executionNote: PermissionLaunchPlanNote? = execution.isEmpty ? nil : carriesExecution
            ? PermissionLaunchPlanNote(text: "It also restricts \(PermissionCapability.sentence(execution)), carried as a rule that asks before a shell command and outranks the permission mode.", carried: true)
            : PermissionLaunchPlanNote(text: "This profile restricts \(PermissionCapability.sentence(execution)), which is not translated into a launch argument: only project write is. Those remain the vendor's own prompts to make.", carried: false)
        // Only Codex has a network sandbox Parley can set. Everywhere else an
        // allowed network rule is the vendor's own prompt, and a restricted one
        // is enforced by Codex's sandbox alone.
        let networkRule = profile.definition.rule(for: .networkAccess)
        let networkNote: PermissionLaunchPlanNote? = switch (kind, networkRule) {
        case (.codex, .allow): PermissionLaunchPlanNote(text: "Network access is enabled in Codex's sandbox.", carried: true)
        case (.codex, _): PermissionLaunchPlanNote(text: "Network access stays off in Codex's sandbox; a command that needs it escalates.", carried: true)
        case (_, .allow): PermissionLaunchPlanNote(text: "This profile allows network access, which only Codex's sandbox can carry; \(kind.label) decides network use itself.", carried: false)
        default: nil
        }
        // `detail` is the same joined text as before this split; checks pin
        // phrases in it, and every other caller shows it as one line.
        let detail = mode
            + (reviewerText.map { " " + $0 } ?? "")
            + " Vendor prompts remain authoritative for capabilities the CLI cannot express."
            + (executionNote.map { " " + $0.text } ?? "")
            + (networkNote.map { " " + $0.text } ?? "")
        return PermissionProfileLaunchPlan(
            arguments: arguments,
            enforcement: arguments.isEmpty ? .guidanceOnly : .partiallyEnforced,
            detail: detail,
            mode: mode,
            reviewer: reviewerText,
            execution: executionNote,
            network: networkNote
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
        approvals: PermissionApprovalHandling = .person,
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
                lifetime: definition.defaultLifetime,
                approvals: approvals
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
    /// Times the profile file was actually read and decoded. Diagnostics only.
    public private(set) var fileReads = 0
    /// Last decoded custom profiles with the file identity they came from; an
    /// unchanged file is answered from memory after one `lstat`.
    private struct FileStamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }
    private var cache: (stamp: FileStamp, profiles: [PermissionProfileDefinition])?

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
        guard fileManager.fileExists(atPath: file.path) else {
            cache = nil
            return []
        }
        let stamp = try validateExistingFile()
        if let cache, cache.stamp == stamp { return cache.profiles }
        do {
            fileReads += 1
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
            cache = (stamp, document.customProfiles)
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
        try OwnerOnlyFile.write(try encoder.encode(Document(version: 1, customProfiles: profiles)), to: file, fileManager: fileManager)
        cache = nil // see WorkspaceRegistry.write: never pair our bytes with a post-write pathname stamp
    }

    @discardableResult
    private func validateExistingFile() throws -> FileStamp {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw PermissionProfileError.unreadable("The permission profile file is not an owner-only regular file.")
        }
        return FileStamp(inode: UInt64(metadata.st_ino), size: Int64(metadata.st_size),
            modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec)
    }
}
