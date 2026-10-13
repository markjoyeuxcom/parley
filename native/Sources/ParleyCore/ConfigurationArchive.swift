import Foundation

/// Parley's exportable configuration: one bounded, versioned JSON document
/// assembled from allowlisted typed values, never a copy of Application
/// Support or a preference-domain dump (decision of 13 October 2026). It
/// carries what a person arranged: workspaces with their panes as stopped
/// templates, groups, pins, split layouts, saved layouts, custom permission
/// profiles and default choices, recipes, favourite folders, worktree
/// repositories and preferences. It never carries relay credentials, control
/// tokens, tickets, journals, context captures, container daemon or container
/// ids, worktree receipts, command-run trust, team grants, launch
/// generations, the session-only switches, first-run or trust confirmations,
/// or the automatic recent-folder history.
public struct ConfigurationArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// The most a document may be on disk; a configuration is small, and a
    /// larger file is not one.
    public static let maximumBytes = 4_000_000
    public static let maximumWorkspaces = 200
    public static let maximumPanesPerWorkspace = 32
    public static let maximumFolders = 64
    public static let maximumSavedLayouts = 50
    public static let maximumCustomProfiles = 64

    public var schemaVersion: Int
    public var appVersion: String
    public var runtime: ParleyRuntimeMode
    public var exportedAt: Date
    public var groups: [ArchivedWorkspaceGroup]
    public var workspaces: [ArchivedWorkspace]
    public var savedLayouts: [SavedWorkspaceLayout]
    public var customPermissionProfiles: [PermissionProfileDefinition]
    /// Default profile id per agent vendor (`PaneKind` raw value), a
    /// remembered choice re-reviewed at every launch, never a grant.
    public var defaultProfileIDs: [String: String]
    public var recipes: [HandoffRecipe]
    public var favouriteFolders: [String]
    public var worktreeRepositories: [String]
    public var preferences: ArchivedPreferences
    /// Stores left out because they could not be read when the export was
    /// made, by `ConfigurationStore` raw value; defaults are never exported
    /// as if they were the person's choice.
    public var omittedStores: [String]

    public init(
        schemaVersion: Int = ConfigurationArchive.currentSchemaVersion,
        appVersion: String,
        runtime: ParleyRuntimeMode,
        exportedAt: Date,
        groups: [ArchivedWorkspaceGroup],
        workspaces: [ArchivedWorkspace],
        savedLayouts: [SavedWorkspaceLayout],
        customPermissionProfiles: [PermissionProfileDefinition],
        defaultProfileIDs: [String: String],
        recipes: [HandoffRecipe],
        favouriteFolders: [String],
        worktreeRepositories: [String],
        preferences: ArchivedPreferences,
        omittedStores: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.runtime = runtime
        self.exportedAt = exportedAt
        self.groups = groups
        self.workspaces = workspaces
        self.savedLayouts = savedLayouts
        self.customPermissionProfiles = customPermissionProfiles
        self.defaultProfileIDs = defaultProfileIDs
        self.recipes = recipes
        self.favouriteFolders = favouriteFolders
        self.worktreeRepositories = worktreeRepositories
        self.preferences = preferences
        self.omittedStores = omittedStores
    }

    /// Every folder the archive names, for the missing-folder preview.
    public var referencedFolders: [String] {
        var folders = Set<String>()
        for workspace in workspaces {
            folders.formUnion(workspace.attachedFolders)
            if let folder = workspace.newPaneFolder { folders.insert(folder) }
            for pane in workspace.panes { folders.insert(pane.launchFolder) }
        }
        for layout in savedLayouts {
            folders.insert(layout.defaultFolder)
            for leaf in layout.root.leaves { folders.insert(leaf.folder) }
        }
        folders.formUnion(favouriteFolders)
        folders.formUnion(worktreeRepositories)
        return folders.sorted()
    }

    public var paneCount: Int { workspaces.reduce(0) { $0 + $1.panes.count } }
}

public struct ArchivedWorkspaceGroup: Codable, Equatable, Sendable {
    public var name: String
    public var isCollapsed: Bool

    public init(name: String, isCollapsed: Bool) {
        self.name = name
        self.isCollapsed = isCollapsed
    }
}

public struct ArchivedWorkspace: Codable, Equatable, Sendable {
    public var name: String
    public var attachedFolders: [String]
    public var newPaneFolder: String?
    public var automationPolicy: WorkspaceAutomationPolicy
    public var pinned: Bool
    /// The group by name; ids are minted again on restore.
    public var groupName: String?
    public var panes: [ArchivedPane]
    /// The split structure over `panes` by index, when one was recorded.
    public var layout: ArchivedLayoutNode?
    public var splitFractions: [String: Double]

    public init(
        name: String,
        attachedFolders: [String],
        newPaneFolder: String?,
        automationPolicy: WorkspaceAutomationPolicy,
        pinned: Bool,
        groupName: String?,
        panes: [ArchivedPane],
        layout: ArchivedLayoutNode?,
        splitFractions: [String: Double]
    ) {
        self.name = name
        self.attachedFolders = attachedFolders
        self.newPaneFolder = newPaneFolder
        self.automationPolicy = automationPolicy
        self.pinned = pinned
        self.groupName = groupName
        self.panes = panes
        self.layout = layout
        self.splitFractions = splitFractions
    }
}

/// A pane as a stopped template: what the person set, never what the process
/// was. Approved roots are not carried; the launch review grants them again.
public struct ArchivedPane: Codable, Equatable, Sendable {
    public var kind: PaneKind
    public var name: String?
    public var role: String?
    public var isWorkspaceLead: Bool
    public var launchFolder: String
    public var profileID: String?
    public var profileLifetime: PermissionProfileLifetime?
    public var approvals: PermissionApprovalHandling?
    /// The pane ran in a container; the image, daemon and mounts are chosen
    /// again in a fresh native review, so only the fact is kept.
    public var wasContainer: Bool

    public init(
        kind: PaneKind,
        name: String?,
        role: String?,
        isWorkspaceLead: Bool,
        launchFolder: String,
        profileID: String?,
        profileLifetime: PermissionProfileLifetime?,
        approvals: PermissionApprovalHandling?,
        wasContainer: Bool
    ) {
        self.kind = kind
        self.name = name
        self.role = role
        self.isWorkspaceLead = isWorkspaceLead
        self.launchFolder = launchFolder
        self.profileID = profileID
        self.profileLifetime = profileLifetime
        self.approvals = approvals
        self.wasContainer = wasContainer
    }

    /// The selection the restored pane remembers, re-resolved at its next
    /// launch review; nil when the archive carried none.
    public var permissionSelection: PermissionProfileSelection? {
        guard let profileID else { return nil }
        return PermissionProfileSelection(profileID: profileID, approvedRoots: [], lifetime: profileLifetime ?? .session, approvals: approvals ?? .person)
    }
}

/// `NativeLayoutNode` with pane indices instead of ids, so a restore can mint
/// fresh ids and keep the structure.
public indirect enum ArchivedLayoutNode: Codable, Equatable, Sendable {
    case leaf(Int)
    case split(direction: SplitDirection, first: ArchivedLayoutNode, second: ArchivedLayoutNode)

    public var leaves: [Int] {
        switch self {
        case let .leaf(index): [index]
        case let .split(_, first, second): first.leaves + second.leaves
        }
    }

    /// Indexes the native tree's leaves into `paneIDs`; nil when a leaf names
    /// a pane that is not in the list.
    public static func archiving(_ node: NativeLayoutNode, paneIDs: [String]) -> ArchivedLayoutNode? {
        switch node {
        case let .leaf(paneID):
            guard let index = paneIDs.firstIndex(of: paneID) else { return nil }
            return .leaf(index)
        case let .split(direction, first, second):
            guard let first = archiving(first, paneIDs: paneIDs), let second = archiving(second, paneIDs: paneIDs) else { return nil }
            return .split(direction: direction, first: first, second: second)
        }
    }

    /// The native tree over freshly minted pane ids; nil when an index is out
    /// of range.
    public func restoring(paneIDs: [String]) -> NativeLayoutNode? {
        switch self {
        case let .leaf(index):
            guard paneIDs.indices.contains(index) else { return nil }
            return .leaf(paneIDs[index])
        case let .split(direction, first, second):
            guard let first = first.restoring(paneIDs: paneIDs), let second = second.restoring(paneIDs: paneIDs) else { return nil }
            return .split(direction: direction, first: first, second: second)
        }
    }
}

public struct ArchivedPreferences: Codable, Equatable, Sendable {
    public var terminalType: String?
    public var font: TerminalFontPreference?
    public var appearanceImport: GhosttyAppearanceImport?
    public var surfaceOptions: TerminalSurfacePreference?
    public var voiceLanguage: String?
    public var readAloud: Bool?
    public var notificationWorkspaces: [String]
    public var collaborationDockVisible: Bool?
    public var swiftPMCompatibility: Bool
    public var releaseChannel: String?
    public var lastAgentVendor: String?
    public var historyRetention: Int?

    public init(
        terminalType: String? = nil,
        font: TerminalFontPreference? = nil,
        appearanceImport: GhosttyAppearanceImport? = nil,
        surfaceOptions: TerminalSurfacePreference? = nil,
        voiceLanguage: String? = nil,
        readAloud: Bool? = nil,
        notificationWorkspaces: [String] = [],
        collaborationDockVisible: Bool? = nil,
        swiftPMCompatibility: Bool = false,
        releaseChannel: String? = nil,
        lastAgentVendor: String? = nil,
        historyRetention: Int? = nil
    ) {
        self.terminalType = terminalType
        self.font = font
        self.appearanceImport = appearanceImport
        self.surfaceOptions = surfaceOptions
        self.voiceLanguage = voiceLanguage
        self.readAloud = readAloud
        self.notificationWorkspaces = notificationWorkspaces
        self.collaborationDockVisible = collaborationDockVisible
        self.swiftPMCompatibility = swiftPMCompatibility
        self.releaseChannel = releaseChannel
        self.lastAgentVendor = lastAgentVendor
        self.historyRetention = historyRetention
    }
}

public enum ConfigurationArchiveError: LocalizedError, Equatable {
    case tooLarge(Int)
    case notAnArchive
    case unsupportedSchema(Int)
    case runtimeMismatch(archive: ParleyRuntimeMode, current: ParleyRuntimeMode)
    case invalid(String)
    case notQuiet([String])
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes):
            "This file is \(bytes) bytes; a Parley configuration is at most \(ConfigurationArchive.maximumBytes). It is not one."
        case .notAnArchive:
            "This file is not a Parley configuration export."
        case let .unsupportedSchema(version):
            "This configuration was written with schema version \(version); this Parley reads version \(ConfigurationArchive.currentSchemaVersion). Export it again from the Parley that wrote it, or update this one."
        case let .runtimeMismatch(archive, current):
            "This configuration was exported from the \(archive.label) runtime; this is the \(current.label) runtime. Production and Development keep separate configuration, so it is not restored here."
        case let .invalid(reason):
            "This configuration cannot be restored: \(reason)"
        case let .notQuiet(blockers):
            "Restore needs a quiet Parley. Still live: \(blockers.joined(separator: "; ")). Stop or finish them, then choose Restore again; nothing was changed."
        case .invalidDestination:
            "Choose a regular .json file location for the export."
        }
    }
}

/// Encodes and decodes the document. Decoding reads the schema version
/// first, so an unknown version is refused by number rather than as a
/// decoding failure.
public enum ConfigurationArchiveCoder {
    public static func encode(_ archive: ConfigurationArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    public static func decode(_ data: Data) throws -> ConfigurationArchive {
        guard data.count <= ConfigurationArchive.maximumBytes else { throw ConfigurationArchiveError.tooLarge(data.count) }
        struct Header: Decodable { let schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw ConfigurationArchiveError.notAnArchive }
        guard let version = header.schemaVersion else { throw ConfigurationArchiveError.notAnArchive }
        guard version == ConfigurationArchive.currentSchemaVersion else { throw ConfigurationArchiveError.unsupportedSchema(version) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ConfigurationArchive.self, from: data)
        } catch {
            throw ConfigurationArchiveError.invalid(error.localizedDescription)
        }
    }

    /// Writes the document as an owner-only regular file. An existing
    /// symlink or non-regular item at the destination is refused rather than
    /// followed.
    public static func write(_ archive: ConfigurationArchive, to destination: URL, fileManager: FileManager = .default) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "json" else { throw ConfigurationArchiveError.invalidDestination }
        if let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
           let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw ConfigurationArchiveError.invalidDestination
        }
        try OwnerOnlyFile.write(try encode(archive), to: destination, fileManager: fileManager)
    }
}

/// Everything a restore checks before any store is written, so a refusal
/// changes nothing.
public enum ConfigurationArchiveValidator {
    public static func validate(_ archive: ConfigurationArchive) throws {
        guard archive.schemaVersion == ConfigurationArchive.currentSchemaVersion else {
            throw ConfigurationArchiveError.unsupportedSchema(archive.schemaVersion)
        }
        guard !archive.workspaces.isEmpty else { throw ConfigurationArchiveError.invalid("it holds no workspace.") }
        guard archive.workspaces.count <= ConfigurationArchive.maximumWorkspaces else {
            throw ConfigurationArchiveError.invalid("it holds \(archive.workspaces.count) workspaces; at most \(ConfigurationArchive.maximumWorkspaces) are restored.")
        }
        var groupNames: [WorkspaceGroup] = []
        for group in archive.groups {
            switch WorkspaceGroup.validatedName(group.name, among: groupNames) {
            case let .success(name): groupNames.append(WorkspaceGroup(id: "group-\(groupNames.count)", name: name, isCollapsed: group.isCollapsed))
            case let .failure(error): throw ConfigurationArchiveError.invalid("group \"\(group.name)\": \(error.localizedDescription)")
            }
        }
        var workspaceNames = Set<String>()
        for workspace in archive.workspaces {
            let name = workspace.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...64).contains(name.count), name == workspace.name, !name.contains(where: \.isNewline) else {
                throw ConfigurationArchiveError.invalid("workspace names are 1 to 64 characters on one line (\"\(workspace.name)\").")
            }
            guard workspaceNames.insert(name.lowercased()).inserted else {
                throw ConfigurationArchiveError.invalid("two workspaces are named \"\(name)\".")
            }
            guard workspace.attachedFolders.count <= 32 else { throw ConfigurationArchiveError.invalid("workspace \"\(name)\" attaches more than 32 folders.") }
            for folder in workspace.attachedFolders + [workspace.newPaneFolder].compactMap { $0 } {
                try requireAbsolute(folder, "workspace \"\(name)\"")
            }
            if let groupName = workspace.groupName, !groupNames.contains(where: { $0.name.caseInsensitiveCompare(groupName) == .orderedSame }) {
                throw ConfigurationArchiveError.invalid("workspace \"\(name)\" names a group the archive does not define (\"\(groupName)\").")
            }
            guard workspace.panes.count <= ConfigurationArchive.maximumPanesPerWorkspace else {
                throw ConfigurationArchiveError.invalid("workspace \"\(name)\" holds \(workspace.panes.count) panes; at most \(ConfigurationArchive.maximumPanesPerWorkspace) are restored.")
            }
            var roles = Set<String>()
            var leads = 0
            for pane in workspace.panes {
                try requireAbsolute(pane.launchFolder, "a pane in workspace \"\(name)\"")
                if let paneName = pane.name {
                    guard (1...64).contains(paneName.count), !paneName.contains(where: \.isNewline) else {
                        throw ConfigurationArchiveError.invalid("pane names are 1 to 64 characters on one line (\"\(paneName)\").")
                    }
                }
                if let role = pane.role {
                    guard pane.kind.isAgent else { throw ConfigurationArchiveError.invalid("a shell pane in workspace \"\(name)\" carries a role.") }
                    if let problem = PaneRoleRules.validationError(role) { throw ConfigurationArchiveError.invalid("role \"\(role)\": \(problem)") }
                    guard roles.insert(role).inserted else { throw ConfigurationArchiveError.invalid("workspace \"\(name)\" gives two panes the role \"\(role)\".") }
                }
                if pane.isWorkspaceLead {
                    guard pane.kind.isAgent else { throw ConfigurationArchiveError.invalid("a shell pane in workspace \"\(name)\" is marked lead.") }
                    leads += 1
                }
                if let profileID = pane.profileID, profileID.isEmpty { throw ConfigurationArchiveError.invalid("a pane in workspace \"\(name)\" names an empty profile.") }
            }
            guard leads <= 1 else { throw ConfigurationArchiveError.invalid("workspace \"\(name)\" marks two panes as lead.") }
            if let layout = workspace.layout {
                let leaves = layout.leaves
                guard leaves.sorted() == Array(workspace.panes.indices) else {
                    throw ConfigurationArchiveError.invalid("the split layout of workspace \"\(name)\" does not name each of its panes exactly once.")
                }
            }
            guard workspace.splitFractions.count <= NativeSplitGeometry.maximumRecordedSplits else {
                throw ConfigurationArchiveError.invalid("workspace \"\(name)\" records too many split positions.")
            }
            for (path, fraction) in workspace.splitFractions {
                guard NativeSplitGeometry.isValidPath(path), fraction.isFinite, (0.05...0.95).contains(fraction) else {
                    throw ConfigurationArchiveError.invalid("workspace \"\(name)\" records an invalid split position.")
                }
            }
        }
        guard archive.savedLayouts.count <= ConfigurationArchive.maximumSavedLayouts else {
            throw ConfigurationArchiveError.invalid("it holds \(archive.savedLayouts.count) saved layouts; at most \(ConfigurationArchive.maximumSavedLayouts) are restored.")
        }
        var layoutNames = Set<String>()
        for layout in archive.savedLayouts {
            do { try SavedWorkspaceLayoutStore.validate(layout) } catch { throw ConfigurationArchiveError.invalid("saved layout \"\(layout.name)\": \(error.localizedDescription)") }
            guard layoutNames.insert(layout.name.lowercased()).inserted else { throw ConfigurationArchiveError.invalid("two saved layouts are named \"\(layout.name)\".") }
        }
        guard archive.customPermissionProfiles.count <= ConfigurationArchive.maximumCustomProfiles else {
            throw ConfigurationArchiveError.invalid("it holds \(archive.customPermissionProfiles.count) custom profiles; at most \(ConfigurationArchive.maximumCustomProfiles) are restored.")
        }
        var profileIDs = Set<String>()
        var profileNames = Set<String>()
        for profile in archive.customPermissionProfiles {
            guard !profile.isBuiltIn, profile.id.hasPrefix("custom-"), !PermissionProfileDefinition.builtIns.contains(where: { $0.id == profile.id }) else {
                throw ConfigurationArchiveError.invalid("profile \"\(profile.name)\" is not a custom profile; built-ins are never restored from a file.")
            }
            do { try PermissionProfileValidator.validate(profile) } catch { throw ConfigurationArchiveError.invalid("profile \"\(profile.name)\": \(error.localizedDescription)") }
            guard profileIDs.insert(profile.id).inserted, profileNames.insert(profile.name.lowercased()).inserted else {
                throw ConfigurationArchiveError.invalid("two custom profiles share the id or name \"\(profile.name)\".")
            }
        }
        for (vendor, profileID) in archive.defaultProfileIDs {
            guard let kind = PaneKind(rawValue: vendor), kind.isAgent else { throw ConfigurationArchiveError.invalid("a default profile is recorded for \"\(vendor)\", which is not an agent vendor.") }
            guard !profileID.isEmpty, profileID.count <= 80 else { throw ConfigurationArchiveError.invalid("the default profile for \(vendor) is not a profile id.") }
        }
        var recipeIDs = Set<String>()
        for recipe in archive.recipes {
            do { try HandoffRecipeStore.validate(recipe) } catch { throw ConfigurationArchiveError.invalid("recipe \"\(recipe.name)\": \(error.localizedDescription)") }
            guard recipeIDs.insert(recipe.id).inserted else { throw ConfigurationArchiveError.invalid("recipe \"\(recipe.id)\" appears twice.") }
        }
        guard archive.favouriteFolders.count <= ConfigurationArchive.maximumFolders, archive.worktreeRepositories.count <= ConfigurationArchive.maximumFolders else {
            throw ConfigurationArchiveError.invalid("it lists more than \(ConfigurationArchive.maximumFolders) favourite folders or worktree repositories.")
        }
        for folder in archive.favouriteFolders { try requireAbsolute(folder, "the favourites") }
        for folder in archive.worktreeRepositories { try requireAbsolute(folder, "the worktree repositories") }
        try validate(archive.preferences)
        for store in archive.omittedStores where ConfigurationStore(rawValue: store) == nil {
            throw ConfigurationArchiveError.invalid("it names an unknown omitted store \"\(store)\".")
        }
    }

    private static func validate(_ preferences: ArchivedPreferences) throws {
        if let terminalType = preferences.terminalType, TerminalTypePreference(rawValue: terminalType) == nil {
            throw ConfigurationArchiveError.invalid("the terminal type \"\(terminalType)\" is not Ghostty or Compatible.")
        }
        if let font = preferences.font {
            do { _ = try TerminalFontPreference(family: font.family, size: font.size) } catch { throw ConfigurationArchiveError.invalid("the font: \(error.localizedDescription)") }
        }
        if let surface = preferences.surfaceOptions {
            do { try surface.validated() } catch { throw ConfigurationArchiveError.invalid("the Ghostty options: \(error.localizedDescription)") }
        }
        if let language = preferences.voiceLanguage, !["en-GB", "en-US"].contains(language) {
            throw ConfigurationArchiveError.invalid("the voice language \"\(language)\" is not en-GB or en-US.")
        }
        guard preferences.notificationWorkspaces.count <= ConfigurationArchive.maximumWorkspaces,
              preferences.notificationWorkspaces.allSatisfy({ (1...64).contains($0.count) }) else {
            throw ConfigurationArchiveError.invalid("the notification workspace list is malformed.")
        }
        if let channel = preferences.releaseChannel, UpdateChannel(rawValue: channel) == nil {
            throw ConfigurationArchiveError.invalid("the release channel \"\(channel)\" is not stable or beta.")
        }
        if let vendor = preferences.lastAgentVendor, PaneKind(rawValue: vendor)?.isAgent != true {
            throw ConfigurationArchiveError.invalid("the last agent vendor \"\(vendor)\" is not an agent vendor.")
        }
        if let retention = preferences.historyRetention, !CollaborationHistoryRetentionPolicy.allowedMaximumRecords.contains(retention) {
            throw ConfigurationArchiveError.invalid("the history retention \(retention) is not one of \(CollaborationHistoryRetentionPolicy.allowedMaximumRecords).")
        }
    }

    private static func requireAbsolute(_ folder: String, _ owner: String) throws {
        guard folder.hasPrefix("/"), !folder.contains("\0"), folder.count <= 4096 else {
            throw ConfigurationArchiveError.invalid("\(owner) names a folder that is not an absolute path.")
        }
    }
}

/// What the person sees before Replace: counts, what goes, what comes, which
/// folders this Mac does not have, which stores the export left out, and why
/// Apply is not available yet.
public struct ConfigurationRestorePreview: Equatable, Sendable {
    public let incomingWorkspaceNames: [String]
    public let currentWorkspaceNames: [String]
    public let paneCount: Int
    public let groupCount: Int
    public let savedLayoutCount: Int
    public let customProfileCount: Int
    public let customizedRecipeCount: Int
    public let favouriteCount: Int
    public let worktreeRepositoryCount: Int
    public let missingFolders: [String]
    public let omittedStores: [ConfigurationStore]
    public let retentionChange: (from: Int, to: Int)?
    public let exportedAt: Date
    public let appVersion: String
    public let blockers: [String]

    public var canApply: Bool { blockers.isEmpty }

    public static func == (lhs: ConfigurationRestorePreview, rhs: ConfigurationRestorePreview) -> Bool {
        lhs.incomingWorkspaceNames == rhs.incomingWorkspaceNames && lhs.currentWorkspaceNames == rhs.currentWorkspaceNames
            && lhs.paneCount == rhs.paneCount && lhs.groupCount == rhs.groupCount && lhs.savedLayoutCount == rhs.savedLayoutCount
            && lhs.customProfileCount == rhs.customProfileCount && lhs.customizedRecipeCount == rhs.customizedRecipeCount
            && lhs.favouriteCount == rhs.favouriteCount && lhs.worktreeRepositoryCount == rhs.worktreeRepositoryCount
            && lhs.missingFolders == rhs.missingFolders && lhs.omittedStores == rhs.omittedStores
            && lhs.retentionChange?.from == rhs.retentionChange?.from && lhs.retentionChange?.to == rhs.retentionChange?.to
            && lhs.exportedAt == rhs.exportedAt && lhs.appVersion == rhs.appVersion && lhs.blockers == rhs.blockers
    }

    public init(
        incoming: ConfigurationArchive,
        current: ConfigurationArchive,
        currentRetention: Int,
        blockers: [String],
        folderExists: (String) -> Bool
    ) {
        incomingWorkspaceNames = incoming.workspaces.map(\.name)
        currentWorkspaceNames = current.workspaces.map(\.name)
        paneCount = incoming.paneCount
        groupCount = incoming.groups.count
        savedLayoutCount = incoming.savedLayouts.count
        customProfileCount = incoming.customPermissionProfiles.count
        let defaults = Dictionary(uniqueKeysWithValues: HandoffRecipe.defaults.map { ($0.id, $0.instructions) })
        customizedRecipeCount = incoming.recipes.filter { defaults[$0.id] != $0.instructions }.count
        favouriteCount = incoming.favouriteFolders.count
        worktreeRepositoryCount = incoming.worktreeRepositories.count
        missingFolders = incoming.referencedFolders.filter { !folderExists($0) }
        omittedStores = incoming.omittedStores.compactMap(ConfigurationStore.init(rawValue:))
        if let retention = incoming.preferences.historyRetention, retention != currentRetention {
            retentionChange = (currentRetention, retention)
        } else {
            retentionChange = nil
        }
        exportedAt = incoming.exportedAt
        appVersion = incoming.appVersion
        self.blockers = blockers
    }
}

/// The pure table of what must be finished before a restore may apply:
/// anything whose process, grant or in-flight work the replacement would
/// pull out from under.
public enum ConfigurationQuietRuntime {
    public static func blockers(
        startedPanes: Int,
        activeHandoffs: Int,
        waitingConsultations: Int,
        liveCommandRuns: Int,
        liveTeamSessions: Int,
        containerWork: Bool,
        voiceActive: Bool,
        recipeRunning: Bool,
        comparisonRunning: Bool,
        terminating: Bool,
        uninstalling: Bool
    ) -> [String] {
        var blockers: [String] = []
        if startedPanes > 0 {
            blockers.append(startedPanes == 1
                ? "1 pane is running (stop an agent from its menu; close a shell)"
                : "\(startedPanes) panes are running (stop agents from their menus; close shells)")
        }
        if activeHandoffs > 0 { blockers.append("\(activeHandoffs) handoff\(activeHandoffs == 1 ? "" : "s") still active (Cancel Tracking or wait for the result)") }
        if waitingConsultations > 0 { blockers.append("\(waitingConsultations) Ask\(waitingConsultations == 1 ? "" : "s") still waiting (Cancel Wait…)") }
        if liveCommandRuns > 0 { blockers.append("\(liveCommandRuns) requested command run\(liveCommandRuns == 1 ? "" : "s") pending or running (Status Center › Live)") }
        if liveTeamSessions > 0 { blockers.append("\(liveTeamSessions) team session\(liveTeamSessions == 1 ? "" : "s") still active (Stop team panes)") }
        if containerWork { blockers.append("a container pane is still being prepared or stopped") }
        if voiceActive { blockers.append("voice dictation or playback is in progress") }
        if recipeRunning { blockers.append("a recipe is running (Stop)") }
        if comparisonRunning { blockers.append("a Compare is still collecting answers") }
        if terminating { blockers.append("a pane is still ending") }
        if uninstalling { blockers.append("Prepare to Uninstall is in progress") }
        return blockers
    }
}
