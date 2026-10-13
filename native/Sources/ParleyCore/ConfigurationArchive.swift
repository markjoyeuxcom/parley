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
    public static let maximumPanesPerWorkspace = 64
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
        // What is written must read back: the same validator and the same
        // size bound the reader applies, before the file exists.
        try ConfigurationArchiveValidator.validate(archive)
        let data = try encode(archive)
        guard data.count <= ConfigurationArchive.maximumBytes else { throw ConfigurationArchiveError.tooLarge(data.count) }
        try OwnerOnlyFile.write(data, to: destination, fileManager: fileManager)
    }
}

/// Everything a restore checks before any store is written, so a refusal
/// changes nothing.
public enum ConfigurationArchiveValidator {
    /// `themeExists` answers for the Ghostty theme catalogue, which lives in
    /// the app; the core validator checks every other reference itself.
    public static func validate(_ archive: ConfigurationArchive, themeExists: ((String) -> Bool)? = nil) throws {
        let knownProfileIDs = Set(PermissionProfileDefinition.builtIns.map(\.id) + archive.customPermissionProfiles.map(\.id))
        func requireProfile(_ profileID: String?, _ owner: String) throws {
            guard let profileID else { return }
            guard knownProfileIDs.contains(profileID) else {
                throw ConfigurationArchiveError.invalid("\(owner) names the profile \"\(profileID)\", which is neither built in nor in the archive.")
            }
        }
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
                try requireProfile(pane.profileID, "a pane in workspace \"\(name)\"")
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
            for leaf in layout.root.leaves {
                guard leaf.permissionSelection?.approvedRoots.isEmpty ?? true else {
                    throw ConfigurationArchiveError.invalid("saved layout \"\(layout.name)\" carries approved roots; grants are never in an archive.")
                }
                try requireProfile(leaf.permissionSelection?.profileID, "saved layout \"\(layout.name)\"")
            }
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
            try requireProfile(profileID, "the default profile for \(vendor)")
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
        try validate(archive.preferences, themeExists: themeExists)
        for store in archive.omittedStores where ConfigurationStore(rawValue: store) == nil {
            throw ConfigurationArchiveError.invalid("it names an unknown omitted store \"\(store)\".")
        }
    }

    private static func validate(_ preferences: ArchivedPreferences, themeExists: ((String) -> Bool)?) throws {
        if let imported = preferences.appearanceImport {
            guard imported.sourceFiles.isEmpty else {
                throw ConfigurationArchiveError.invalid("the imported appearance carries its source file paths; an archive holds only the colours.")
            }
            if let theme = imported.themeDescription, theme.contains("/") {
                throw ConfigurationArchiveError.invalid("the imported appearance names a theme by path; an archive holds only its name.")
            }
        }
        if let surface = preferences.surfaceOptions, let themeExists {
            for theme in [surface.lightTheme, surface.darkTheme].compactMap({ $0 }) where !themeExists(theme) {
                throw ConfigurationArchiveError.invalid("the Ghostty theme \"\(theme)\" is not in this Parley's catalogue.")
            }
        }
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
    /// Pane templates that ran in containers; they come back as host
    /// templates until a launch review chooses a container again.
    public let containerTemplateCount: Int
    /// Preferences that would change, one line each, the SwiftPM
    /// compatibility opt-in first because it affects what new panes run with.
    public let settingChanges: [String]
    /// Custom profiles and default profile choices that would change.
    public let profileChanges: [String]
    /// How many restored workspaces allow which automation.
    public let automationSummary: String
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
            && lhs.containerTemplateCount == rhs.containerTemplateCount && lhs.settingChanges == rhs.settingChanges
            && lhs.profileChanges == rhs.profileChanges && lhs.automationSummary == rhs.automationSummary
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
        containerTemplateCount = incoming.workspaces.reduce(0) { $0 + $1.panes.filter(\.wasContainer).count }
        settingChanges = Self.settingChanges(from: current.preferences, to: incoming.preferences)
        profileChanges = Self.profileChanges(from: current, to: incoming)
        automationSummary = Self.automationSummary(incoming)
        exportedAt = incoming.exportedAt
        appVersion = incoming.appVersion
        self.blockers = blockers
    }

    /// Every preference is compared by its effective value: nil means the
    /// default, so an archive that never chose one restores the default.
    static func settingChanges(from current: ArchivedPreferences, to incoming: ArchivedPreferences) -> [String] {
        var lines: [String] = []
        if current.swiftPMCompatibility != incoming.swiftPMCompatibility {
            lines.append(incoming.swiftPMCompatibility
                ? "Swift package builds: SwiftPM compatibility turns ON for new agent panes (the wrapper adds --disable-sandbox to SwiftPM build, test, run and package)"
                : "Swift package builds: SwiftPM compatibility turns off")
        }
        let currentTerminal = TerminalTypePreference(rawValue: current.terminalType ?? "") ?? .default
        let incomingTerminal = TerminalTypePreference(rawValue: incoming.terminalType ?? "") ?? .default
        if currentTerminal != incomingTerminal { lines.append("Terminal type: \(currentTerminal.label) → \(incomingTerminal.label) for panes started afterwards") }
        let currentChannel = UpdateChannel(rawValue: current.releaseChannel ?? "") ?? .stable
        let incomingChannel = UpdateChannel(rawValue: incoming.releaseChannel ?? "") ?? .stable
        if currentChannel != incomingChannel { lines.append("Manual release channel: \(currentChannel.label) → \(incomingChannel.label)") }
        if (current.font ?? .ghosttyDefault) != (incoming.font ?? .ghosttyDefault) { lines.append("Terminal font changes") }
        if (current.appearanceImport != nil) != (incoming.appearanceImport != nil) {
            lines.append(incoming.appearanceImport != nil ? "An imported Ghostty appearance is applied" : "The imported Ghostty appearance is removed")
        } else if current.appearanceImport != incoming.appearanceImport {
            lines.append("The imported Ghostty appearance changes")
        }
        if (current.surfaceOptions ?? .ghosttyDefault) != (incoming.surfaceOptions ?? .ghosttyDefault) { lines.append("Ghostty surface options change") }
        if (current.voiceLanguage ?? "en-GB") != (incoming.voiceLanguage ?? "en-GB") { lines.append("Voice language: \(current.voiceLanguage ?? "en-GB") → \(incoming.voiceLanguage ?? "en-GB")") }
        if (current.readAloud ?? false) != (incoming.readAloud ?? false) { lines.append("Read-aloud turns \(incoming.readAloud ?? false ? "on" : "off")") }
        if (current.collaborationDockVisible ?? true) != (incoming.collaborationDockVisible ?? true) { lines.append("Collaboration Dock \(incoming.collaborationDockVisible ?? true ? "shown" : "hidden")") }
        if Set(current.notificationWorkspaces) != Set(incoming.notificationWorkspaces) {
            lines.append(incoming.notificationWorkspaces.isEmpty ? "Workspace notifications: none" : "Workspace notifications for: \(incoming.notificationWorkspaces.joined(separator: ", "))")
        }
        return lines
    }

    static func profileChanges(from current: ConfigurationArchive, to incoming: ConfigurationArchive) -> [String] {
        var lines: [String] = []
        let currentIDs = Set(current.customPermissionProfiles.map(\.id))
        let incomingIDs = Set(incoming.customPermissionProfiles.map(\.id))
        for profile in incoming.customPermissionProfiles where !currentIDs.contains(profile.id) { lines.append("Custom profile added: \(profile.name)") }
        for profile in current.customPermissionProfiles where !incomingIDs.contains(profile.id) { lines.append("Custom profile removed: \(profile.name)") }
        for profile in incoming.customPermissionProfiles {
            if let existing = current.customPermissionProfiles.first(where: { $0.id == profile.id }), existing != profile { lines.append("Custom profile changed: \(profile.name)") }
        }
        let names = Dictionary(uniqueKeysWithValues: (PermissionProfileDefinition.builtIns + incoming.customPermissionProfiles).map { ($0.id, $0.name) })
        for vendor in Set(current.defaultProfileIDs.keys).union(incoming.defaultProfileIDs.keys).sorted() {
            let before = current.defaultProfileIDs[vendor]
            let after = incoming.defaultProfileIDs[vendor]
            guard before != after else { continue }
            let vendorName = PaneKind(rawValue: vendor)?.label ?? vendor
            lines.append("Default profile for \(vendorName): \(before.flatMap { names[$0] ?? $0 } ?? "none") → \(after.flatMap { names[$0] ?? $0 } ?? "none")")
        }
        return lines
    }

    static func automationSummary(_ archive: ConfigurationArchive) -> String {
        let counts = Dictionary(grouping: archive.workspaces, by: \.automationPolicy).mapValues(\.count)
        return WorkspaceAutomationPolicy.allCases
            .compactMap { policy in counts[policy].map { "\($0) \(policy.label)" } }
            .joined(separator: ", ")
    }
}

/// The exact bytes and preference values of the stores a restore rewrites,
/// taken before it starts, so a failure part-way puts back precisely what was
/// there rather than a lossy re-import of an archive. The workbench document
/// is not here: `WorkbenchController.replaceWorkspaces` is its own commit.
public struct ConfigurationStoreSnapshot {
    /// A store as it was: absent, a regular file with these bytes, or
    /// something that existed but could not be read (a non-regular item or an
    /// unreadable file), which a rollback leaves exactly alone.
    public enum FileState: Equatable {
        case absent
        case bytes(Data)
        case unreadable
    }

    public struct FileRecord { public let url: URL; public let state: FileState }
    public let files: [FileRecord]
    public let preferences: [(key: String, value: Any?)]

    public static func capture(files: [URL], preferenceKeys: [String], defaults: UserDefaults, fileManager: FileManager = .default) -> ConfigurationStoreSnapshot {
        ConfigurationStoreSnapshot(
            files: files.map { url in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return FileRecord(url: url, state: .absent) }
                guard !isDirectory.boolValue,
                      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      (attributes[.type] as? FileAttributeType) == .typeRegular,
                      let data = try? Data(contentsOf: url) else { return FileRecord(url: url, state: .unreadable) }
                return FileRecord(url: url, state: .bytes(data))
            },
            preferences: preferenceKeys.map { ($0, defaults.object(forKey: $0)) }
        )
    }

    /// Puts every captured file and value back: bytes are rewritten, a file
    /// that was absent is removed, and one that existed but could not be read
    /// is left as it is. Files go through OwnerOnlyFile, so each is atomic on
    /// its own; the snapshot itself is memory-only, so a crash between the
    /// phases is not recovered by it.
    public func restore(defaults: UserDefaults, fileManager: FileManager = .default) throws {
        var firstError: Error?
        for file in files {
            do {
                switch file.state {
                case let .bytes(data):
                    try OwnerOnlyFile.write(data, to: file.url, fileManager: fileManager)
                case .absent:
                    if fileManager.fileExists(atPath: file.url.path) { try fileManager.removeItem(at: file.url) }
                case .unreadable:
                    break
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        for (key, value) in preferences {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        if let firstError { throw firstError }
    }
}

extension SavedWorkspaceLayout {
    /// The layout without any approved roots: a grant is never in an archive,
    /// and the launch review grants roots again.
    public func strippingApprovedRoots() -> SavedWorkspaceLayout {
        func strip(_ node: SavedLayoutNode) -> SavedLayoutNode {
            switch node {
            case let .leaf(leaf):
                let selection = leaf.permissionSelection.map {
                    PermissionProfileSelection(profileID: $0.profileID, approvedRoots: [], lifetime: $0.lifetime, approvals: $0.approvals)
                }
                return .leaf(SavedLayoutLeaf(kind: leaf.kind, name: leaf.name, folder: leaf.folder, role: leaf.role,
                                             isWorkspaceLead: leaf.isWorkspaceLead, permissionSelection: selection))
            case let .split(direction, ratio, first, second):
                return .split(direction: direction, ratio: ratio, first: strip(first), second: strip(second))
            }
        }
        return SavedWorkspaceLayout(name: name, defaultFolder: defaultFolder, root: strip(root), automationPolicy: automationPolicy)
    }
}

extension GhosttyAppearanceImport {
    /// The import without where it came from: the colours and fonts travel,
    /// the source file paths and a theme named by path do not.
    public var forArchive: GhosttyAppearanceImport {
        GhosttyAppearanceImport(
            sourceFiles: [],
            themeDescription: themeDescription.flatMap { $0.contains("/") ? nil : $0 },
            fontFamily: fontFamily,
            fontSize: fontSize,
            light: light,
            dark: dark,
            ignoredSettingCount: ignoredSettingCount
        )
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
        uninstalling: Bool,
        launchReviewOpen: Bool = false,
        launchApplying: Bool = false,
        coordinationUnreadable: Bool = false
    ) -> [String] {
        var blockers: [String] = []
        if coordinationUnreadable { blockers.append("the coordination core could not be read just now; try Restore again") }
        if launchReviewOpen { blockers.append("a launch review is open (Start it or cancel it)") }
        if launchApplying { blockers.append("a pane launch is being applied") }
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
