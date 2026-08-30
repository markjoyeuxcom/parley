import Darwin
import Foundation

public struct TeamTemplatePermission: Codable, Equatable, Sendable {
    public let profileID: String
    public let lifetime: PermissionProfileLifetime

    public init(profileID: String, lifetime: PermissionProfileLifetime) {
        self.profileID = profileID
        self.lifetime = lifetime
    }
}

public struct TeamTemplateLeaf: Codable, Equatable, Sendable {
    public let kind: PaneKind
    public let name: String
    public let role: String?
    public let isWorkspaceLead: Bool
    public let permissionProfile: TeamTemplatePermission?

    public init(
        kind: PaneKind,
        name: String,
        role: String? = nil,
        isWorkspaceLead: Bool = false,
        permissionProfile: TeamTemplatePermission? = nil
    ) {
        self.kind = kind
        self.name = name
        self.role = role
        self.isWorkspaceLead = isWorkspaceLead
        self.permissionProfile = permissionProfile
    }
}

public indirect enum TeamTemplateNode: Codable, Equatable, Sendable {
    case leaf(TeamTemplateLeaf)
    case split(
        direction: SplitDirection,
        ratio: Double,
        first: TeamTemplateNode,
        second: TeamTemplateNode
    )

    public var leaves: [TeamTemplateLeaf] {
        switch self {
        case let .leaf(leaf): [leaf]
        case let .split(_, _, first, second): first.leaves + second.leaves
        }
    }
}

public struct TeamTemplate: Identifiable, Codable, Equatable, Sendable {
    public let name: String
    public let root: TeamTemplateNode
    public let automationPolicy: WorkspaceAutomationPolicy

    public var id: String { name.lowercased() }

    public init(
        name: String,
        root: TeamTemplateNode,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate
    ) {
        self.name = name
        self.root = root
        self.automationPolicy = automationPolicy
    }

    public static func capturing(_ layout: SavedWorkspaceLayout, name: String) throws -> TeamTemplate {
        func capture(_ node: SavedLayoutNode) -> TeamTemplateNode {
            switch node {
            case let .leaf(leaf):
                return .leaf(TeamTemplateLeaf(
                    kind: leaf.kind,
                    name: leaf.name,
                    role: leaf.role,
                    isWorkspaceLead: leaf.isWorkspaceLead,
                    permissionProfile: leaf.permissionSelection.map {
                        TeamTemplatePermission(profileID: $0.profileID, lifetime: $0.lifetime)
                    }
                ))
            case let .split(direction, ratio, first, second):
                return .split(
                    direction: direction,
                    ratio: ratio,
                    first: capture(first),
                    second: capture(second)
                )
            }
        }
        let template = TeamTemplate(
            name: name,
            root: capture(layout.root),
            automationPolicy: layout.automationPolicy
        )
        try TeamTemplateValidation.validate(template)
        return template
    }

    /// Materializes this portable definition against one deliberately chosen
    /// local folder. No source path, process id or permission root travels in
    /// the template itself.
    public func workspaceLayout(folder: String, workspaceName: String) throws -> SavedWorkspaceLayout {
        try materializedWorkspaceLayout(
            launchFolder: folder,
            workspaceName: workspaceName,
            bindPermissionRoots: true
        )
    }

    /// Materializes a portable team without attaching or granting its safe
    /// launch fallback. Agent leaves remain stopped and carry no permission
    /// selection, so Start must collect an explicit pane folder and scope.
    public func folderlessWorkspaceLayout(
        launchFolder: String,
        workspaceName: String
    ) throws -> SavedWorkspaceLayout {
        try materializedWorkspaceLayout(
            launchFolder: launchFolder,
            workspaceName: workspaceName,
            bindPermissionRoots: false
        )
    }

    private func materializedWorkspaceLayout(
        launchFolder folder: String,
        workspaceName: String,
        bindPermissionRoots: Bool
    ) throws -> SavedWorkspaceLayout {
        try TeamTemplateValidation.validate(self)
        guard folder.hasPrefix("/") else {
            throw TeamTemplateStoreError.invalid("the selected folder must be absolute")
        }
        let cleanName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(cleanName.count), cleanName == workspaceName else {
            throw TeamTemplateStoreError.invalid("workspace names must be 1–80 trimmed characters")
        }

        func materialize(_ node: TeamTemplateNode) -> SavedLayoutNode {
            switch node {
            case let .leaf(leaf):
                let selection = bindPermissionRoots ? leaf.permissionProfile.map {
                    PermissionProfileSelection(
                        profileID: $0.profileID,
                        approvedRoots: [folder],
                        lifetime: $0.lifetime
                    )
                } : nil
                return .leaf(SavedLayoutLeaf(
                    kind: leaf.kind,
                    name: leaf.name,
                    folder: folder,
                    role: leaf.role,
                    isWorkspaceLead: leaf.isWorkspaceLead,
                    permissionSelection: selection
                ))
            case let .split(direction, ratio, first, second):
                return .split(
                    direction: direction,
                    ratio: ratio,
                    first: materialize(first),
                    second: materialize(second)
                )
            }
        }

        return SavedWorkspaceLayout(
            name: workspaceName,
            defaultFolder: folder,
            root: materialize(root),
            automationPolicy: automationPolicy
        )
    }
}

public enum PaneRoleRules {
    public static let maximumLength = 32
    private static let reserved = Set(
        PaneKind.allCases.flatMap { [$0.rawValue.lowercased(), $0.label.lowercased()] }
            + ["lead"]
    )

    public static func validationError(_ role: String) -> String? {
        guard role == role.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...maximumLength).contains(role.count),
              role == role.lowercased(),
              let first = role.utf8.first,
              (ascii("a")...ascii("z")).contains(first),
              role.utf8.allSatisfy({ byte in
                  (ascii("a")...ascii("z")).contains(byte)
                      || (ascii("0")...ascii("9")).contains(byte)
                      || byte == ascii("-")
              }),
              role.utf8.last != ascii("-") else {
            return "roles must be 1–\(maximumLength) lowercase letters, numbers or hyphens, beginning with a letter"
        }
        if reserved.contains(role) {
            return "the role \(role) is reserved for built-in routing"
        }
        return nil
    }

    private static func ascii(_ character: Character) -> UInt8 { character.asciiValue! }
}

public enum TeamTemplateStoreError: LocalizedError {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail): "Parley refused an invalid team template: \(detail)"
        case let .unreadable(detail): "Parley could not read team templates: \(detail)"
        }
    }
}

private enum TeamTemplateValidation {
    static let maximumTemplates = 50
    static let maximumLeaves = 16

    static func validate(_ template: TeamTemplate) throws {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), name == template.name else {
            throw TeamTemplateStoreError.invalid("template names must be 1–80 trimmed characters")
        }

        var leafCount = 0
        var leadCount = 0
        var roles = Set<String>()
        func visit(_ node: TeamTemplateNode, depth: Int) throws {
            guard depth <= 12 else {
                throw TeamTemplateStoreError.invalid("the split tree is too deep")
            }
            switch node {
            case let .leaf(leaf):
                leafCount += 1
                let paneName = leaf.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...80).contains(paneName.count), paneName == leaf.name else {
                    throw TeamTemplateStoreError.invalid("pane names must be 1–80 trimmed characters")
                }
                if leaf.isWorkspaceLead {
                    leadCount += 1
                    guard leaf.kind.isAgent else {
                        throw TeamTemplateStoreError.invalid("the workspace lead must be an agent pane")
                    }
                }
                if let role = leaf.role {
                    if let error = PaneRoleRules.validationError(role) {
                        throw TeamTemplateStoreError.invalid(error)
                    }
                    guard leaf.kind.isAgent else {
                        throw TeamTemplateStoreError.invalid("only agent panes may have routing roles")
                    }
                    guard roles.insert(role).inserted else {
                        throw TeamTemplateStoreError.invalid("pane roles must be unique within a team")
                    }
                }
                if let permission = leaf.permissionProfile {
                    guard leaf.kind.isAgent else {
                        throw TeamTemplateStoreError.invalid("only agent panes may have permission profiles")
                    }
                    let profileID = permission.profileID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard (1...80).contains(profileID.count), profileID == permission.profileID else {
                        throw TeamTemplateStoreError.invalid("permission profile ids must be 1–80 trimmed characters")
                    }
                }
            case let .split(_, ratio, first, second):
                guard ratio.isFinite, (0.05...0.95).contains(ratio) else {
                    throw TeamTemplateStoreError.invalid("split ratios must be between 0.05 and 0.95")
                }
                try visit(first, depth: depth + 1)
                try visit(second, depth: depth + 1)
            }
        }
        try visit(template.root, depth: 0)
        guard (1...maximumLeaves).contains(leafCount) else {
            throw TeamTemplateStoreError.invalid("templates must contain 1–\(maximumLeaves) panes")
        }
        guard leadCount <= 1 else {
            throw TeamTemplateStoreError.invalid("a template may contain only one workspace lead")
        }
    }
}

public final class TeamTemplateStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        var templates: [TeamTemplate]
    }

    private static let schemaVersion = 1
    public let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func templates() throws -> [TeamTemplate] {
        try lock.withLock { try read().templates }
    }

    public func save(_ template: TeamTemplate) throws {
        try lock.withLock {
            try TeamTemplateValidation.validate(template)
            var document = try read()
            if let index = document.templates.firstIndex(where: {
                $0.name.caseInsensitiveCompare(template.name) == .orderedSame
            }) {
                document.templates[index] = template
            } else {
                guard document.templates.count < TeamTemplateValidation.maximumTemplates else {
                    throw TeamTemplateStoreError.invalid("at most \(TeamTemplateValidation.maximumTemplates) templates may be saved")
                }
                document.templates.append(template)
            }
            try write(document)
        }
    }

    public func delete(named name: String) throws {
        try lock.withLock {
            var document = try read()
            document.templates.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            try write(document)
        }
    }

    private func read() throws -> Document {
        guard fileManager.fileExists(atPath: file.path) else {
            return Document(version: Self.schemaVersion, templates: [])
        }
        try validateExistingFile()
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == Self.schemaVersion else {
                throw TeamTemplateStoreError.unreadable("unsupported schema version \(document.version)")
            }
            for template in document.templates { try TeamTemplateValidation.validate(template) }
            return document
        } catch let error as TeamTemplateStoreError {
            throw error
        } catch {
            throw TeamTemplateStoreError.unreadable(error.localizedDescription)
        }
    }

    private func write(_ document: Document) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw TeamTemplateStoreError.unreadable("the template file is not an owner-only regular file")
        }
    }
}
