import Darwin
import Foundation

public struct SavedLayoutLeaf: Codable, Equatable, Sendable {
    public let kind: PaneKind
    public let name: String
    public let folder: String
    public let role: String?
    public let isWorkspaceLead: Bool
    public let permissionSelection: PermissionProfileSelection?

    public init(
        kind: PaneKind,
        name: String,
        folder: String,
        role: String? = nil,
        isWorkspaceLead: Bool = false,
        permissionSelection: PermissionProfileSelection? = nil
    ) {
        self.kind = kind
        self.name = name
        self.folder = folder
        self.role = role
        self.isWorkspaceLead = isWorkspaceLead
        self.permissionSelection = permissionSelection
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case folder
        case role
        case isWorkspaceLead
        case permissionSelection
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decode(PaneKind.self, forKey: .kind),
            name: try values.decode(String.self, forKey: .name),
            folder: try values.decode(String.self, forKey: .folder),
            role: try values.decodeIfPresent(String.self, forKey: .role),
            isWorkspaceLead: try values.decodeIfPresent(Bool.self, forKey: .isWorkspaceLead) ?? false,
            permissionSelection: try values.decodeIfPresent(
                PermissionProfileSelection.self,
                forKey: .permissionSelection
            )
        )
    }
}

/// The persisted grid deliberately contains no live pane or surface
/// identifiers. Those values have meaning only in the process that minted them.
public indirect enum SavedLayoutNode: Codable, Equatable, Sendable {
    case leaf(SavedLayoutLeaf)
    case split(
        direction: SplitDirection,
        ratio: Double,
        first: SavedLayoutNode,
        second: SavedLayoutNode
    )

    private enum NodeKind: String, Codable {
        case leaf
        case split
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case kind
        case name
        case folder
        case role
        case isWorkspaceLead
        case permissionSelection
        case direction
        case ratio
        case first
        case second
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(NodeKind.self, forKey: .type) {
        case .leaf:
            self = .leaf(SavedLayoutLeaf(
                kind: try values.decode(PaneKind.self, forKey: .kind),
                name: try values.decode(String.self, forKey: .name),
                folder: try values.decode(String.self, forKey: .folder),
                role: try values.decodeIfPresent(String.self, forKey: .role),
                isWorkspaceLead: try values.decodeIfPresent(Bool.self, forKey: .isWorkspaceLead) ?? false,
                permissionSelection: try values.decodeIfPresent(
                    PermissionProfileSelection.self,
                    forKey: .permissionSelection
                )
            ))
        case .split:
            self = .split(
                direction: try values.decode(SplitDirection.self, forKey: .direction),
                ratio: try values.decode(Double.self, forKey: .ratio),
                first: try values.decode(SavedLayoutNode.self, forKey: .first),
                second: try values.decode(SavedLayoutNode.self, forKey: .second)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .leaf(leaf):
            try values.encode(NodeKind.leaf, forKey: .type)
            try values.encode(leaf.kind, forKey: .kind)
            try values.encode(leaf.name, forKey: .name)
            try values.encode(leaf.folder, forKey: .folder)
            try values.encodeIfPresent(leaf.role, forKey: .role)
            try values.encode(leaf.isWorkspaceLead, forKey: .isWorkspaceLead)
            try values.encodeIfPresent(leaf.permissionSelection, forKey: .permissionSelection)
        case let .split(direction, ratio, first, second):
            try values.encode(NodeKind.split, forKey: .type)
            try values.encode(direction, forKey: .direction)
            try values.encode(ratio, forKey: .ratio)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }

    public var leaves: [SavedLayoutLeaf] {
        switch self {
        case let .leaf(leaf):
            [leaf]
        case let .split(_, _, first, second):
            first.leaves + second.leaves
        }
    }
}

public struct SavedWorkspaceLayout: Identifiable, Codable, Equatable, Sendable {
    public let name: String
    public let defaultFolder: String
    public let root: SavedLayoutNode
    public let automationPolicy: WorkspaceAutomationPolicy

    /// Names are unique without case in the store and are the durable identity.
    /// No opaque id is persisted into the layout document.
    public var id: String { name.lowercased() }

    public init(
        name: String,
        defaultFolder: String,
        root: SavedLayoutNode,
        automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate
    ) {
        self.name = name
        self.defaultFolder = defaultFolder
        self.root = root
        self.automationPolicy = automationPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case defaultFolder
        case root
        case automationPolicy
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try values.decode(String.self, forKey: .name),
            defaultFolder: try values.decode(String.self, forKey: .defaultFolder),
            root: try values.decode(SavedLayoutNode.self, forKey: .root),
            automationPolicy: try values.decodeIfPresent(WorkspaceAutomationPolicy.self, forKey: .automationPolicy) ?? .askAndDelegate
        )
    }

    /// Mints a new live tree without starting anything. The caller alone owns
    /// the policy that shells may start automatically while agents remain held.
    public func fromSavedLayout() -> RestoredLayoutNode {
        func restore(_ node: SavedLayoutNode) -> RestoredLayoutNode {
            switch node {
            case let .leaf(leaf):
                .slot(RestoredLayoutSlot(
                    id: UUID(),
                    paneID: nil,
                    kind: leaf.kind,
                    name: leaf.name,
                    folder: leaf.folder,
                    role: leaf.role,
                    isStarted: false,
                    isWorkspaceLead: leaf.isWorkspaceLead,
                    permissionSelection: leaf.permissionSelection
                ))
            case let .split(direction, ratio, first, second):
                .split(
                    direction: direction,
                    ratio: ratio,
                    first: restore(first),
                    second: restore(second)
                )
            }
        }
        return restore(root)
    }
}

public struct RestoredLayoutSlot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var paneID: String?
    public let kind: PaneKind
    public let name: String
    public let folder: String
    public let role: String?
    public var isStarted: Bool
    public let isWorkspaceLead: Bool
    public let permissionSelection: PermissionProfileSelection?
}

public indirect enum RestoredLayoutNode: Equatable, Sendable {
    case slot(RestoredLayoutSlot)
    case split(
        direction: SplitDirection,
        ratio: Double,
        first: RestoredLayoutNode,
        second: RestoredLayoutNode
    )

    public var slots: [RestoredLayoutSlot] {
        switch self {
        case let .slot(slot):
            [slot]
        case let .split(_, _, first, second):
            first.slots + second.slots
        }
    }
}

public enum SavedWorkspaceLayoutStoreError: LocalizedError {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail):
            "Parley refused an invalid saved layout: \(detail)"
        case let .unreadable(detail):
            "Parley could not read saved layouts: \(detail)"
        }
    }
}

public final class SavedWorkspaceLayoutStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        var layouts: [SavedWorkspaceLayout]
    }

    private static let schemaVersion = 1
    private static let maximumLayouts = 50
    private static let maximumLeaves = 16

    public let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func layouts() throws -> [SavedWorkspaceLayout] {
        try lock.withLock { try readDocument().layouts }
    }

    public func save(_ layout: SavedWorkspaceLayout) throws {
        try lock.withLock {
            try validate(layout)
            var document = try readDocument()
            if let index = document.layouts.firstIndex(where: {
                $0.name.caseInsensitiveCompare(layout.name) == .orderedSame
            }) {
                document.layouts[index] = layout
            } else {
                guard document.layouts.count < Self.maximumLayouts else {
                    throw SavedWorkspaceLayoutStoreError.invalid("at most \(Self.maximumLayouts) layouts may be saved")
                }
                document.layouts.append(layout)
            }
            try write(document)
        }
    }

    public func delete(named name: String) throws {
        try lock.withLock {
            var document = try readDocument()
            document.layouts.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            try write(document)
        }
    }

    private func readDocument() throws -> Document {
        guard fileManager.fileExists(atPath: file.path) else {
            return Document(version: Self.schemaVersion, layouts: [])
        }
        try validateExistingFile()
        do {
            let data = try Data(contentsOf: file)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == Self.schemaVersion else {
                throw SavedWorkspaceLayoutStoreError.unreadable("unsupported schema version \(document.version)")
            }
            for layout in document.layouts { try validate(layout) }
            return document
        } catch let error as SavedWorkspaceLayoutStoreError {
            throw error
        } catch {
            throw SavedWorkspaceLayoutStoreError.unreadable(error.localizedDescription)
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
        let data = try encoder.encode(document)
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw SavedWorkspaceLayoutStoreError.unreadable("the layout file is not an owner-only regular file")
        }
    }

    private func validate(_ layout: SavedWorkspaceLayout) throws {
        let name = layout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(name.count), name == layout.name else {
            throw SavedWorkspaceLayoutStoreError.invalid("layout names must be 1–80 trimmed characters")
        }
        guard layout.defaultFolder.hasPrefix("/") else {
            throw SavedWorkspaceLayoutStoreError.invalid("the default folder must be absolute")
        }
        var leaves = 0
        var leads = 0
        var roles = Set<String>()
        func validateNode(_ node: SavedLayoutNode, depth: Int) throws {
            guard depth <= 12 else {
                throw SavedWorkspaceLayoutStoreError.invalid("the split tree is too deep")
            }
            switch node {
            case let .leaf(leaf):
                leaves += 1
                if leaf.isWorkspaceLead {
                    leads += 1
                    guard leaf.kind.isAgent else {
                        throw SavedWorkspaceLayoutStoreError.invalid("the workspace lead must be an agent pane")
                    }
                }
                let leafName = leaf.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...80).contains(leafName.count), leafName == leaf.name else {
                    throw SavedWorkspaceLayoutStoreError.invalid("pane names must be 1–80 trimmed characters")
                }
                guard leaf.folder.hasPrefix("/") else {
                    throw SavedWorkspaceLayoutStoreError.invalid("every pane folder must be absolute")
                }
                if let role = leaf.role {
                    if let error = PaneRoleRules.validationError(role) {
                        throw SavedWorkspaceLayoutStoreError.invalid(error)
                    }
                    guard leaf.kind.isAgent else {
                        throw SavedWorkspaceLayoutStoreError.invalid("only agent panes may have routing roles")
                    }
                    guard roles.insert(role.lowercased()).inserted else {
                        throw SavedWorkspaceLayoutStoreError.invalid("pane roles must be unique within a workspace")
                    }
                }
            case let .split(_, ratio, first, second):
                guard ratio.isFinite, ratio >= 0.05, ratio <= 0.95 else {
                    throw SavedWorkspaceLayoutStoreError.invalid("split ratios must be between 0.05 and 0.95")
                }
                try validateNode(first, depth: depth + 1)
                try validateNode(second, depth: depth + 1)
            }
        }
        try validateNode(layout.root, depth: 0)
        guard (1...Self.maximumLeaves).contains(leaves) else {
            throw SavedWorkspaceLayoutStoreError.invalid("layouts must contain 1–\(Self.maximumLeaves) panes")
        }
        guard leads <= 1 else {
            throw SavedWorkspaceLayoutStoreError.invalid("a layout may contain only one workspace lead")
        }
    }
}
