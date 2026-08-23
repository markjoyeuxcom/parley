import Darwin
import Foundation

public struct SavedLayoutLeaf: Codable, Equatable, Sendable {
    public let kind: PaneKind
    public let name: String
    public let folder: String

    public init(kind: PaneKind, name: String, folder: String) {
        self.kind = kind
        self.name = name
        self.folder = folder
    }
}

/// The persisted grid deliberately contains no tmux pane, window or live slot
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
                folder: try values.decode(String.self, forKey: .folder)
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

    /// Names are unique without case in the store and are the durable identity.
    /// No opaque id is persisted into the layout document.
    public var id: String { name.lowercased() }

    public init(name: String, defaultFolder: String, root: SavedLayoutNode) {
        self.name = name
        self.defaultFolder = defaultFolder
        self.root = root
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
                    isStarted: false
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
    public var isStarted: Bool
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

public enum TmuxLayoutParser {
    public static func savedNode(layout: String, panes: [TmuxPane]) throws -> SavedLayoutNode {
        let trimmed = layout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let checksumEnd = trimmed.firstIndex(of: ",") else {
            throw SavedWorkspaceLayoutStoreError.invalid("tmux returned a malformed layout")
        }
        let body = String(trimmed[trimmed.index(after: checksumEnd)...])
        var parser = Parser(body: body, panes: panes)
        let parsed = try parser.parse()
        return parsed
    }

    private struct ParsedNode {
        let node: SavedLayoutNode
        let width: Int
        let height: Int
    }

    private struct Parser {
        let bytes: [UInt8]
        let panesByNumber: [String: TmuxPane]
        var index = 0
        var seenPaneIDs: Set<String> = []

        init(body: String, panes: [TmuxPane]) {
            bytes = Array(body.utf8)
            panesByNumber = Dictionary(uniqueKeysWithValues: panes.map {
                (String($0.id.drop(while: { $0 == "%" })), $0)
            })
        }

        mutating func parse() throws -> SavedLayoutNode {
            let parsed = try parseNode(depth: 0)
            guard index == bytes.count else { throw malformed() }
            guard seenPaneIDs.count == panesByNumber.count else {
                throw SavedWorkspaceLayoutStoreError.invalid("tmux layout did not contain every workspace pane")
            }
            return parsed.node
        }

        mutating func parseNode(depth: Int) throws -> ParsedNode {
            guard depth <= 16 else {
                throw SavedWorkspaceLayoutStoreError.invalid("tmux layout is too deeply nested")
            }
            let width = try integer()
            try consume(ascii("x"))
            let height = try integer()
            try consume(ascii(","))
            _ = try integer()
            try consume(ascii(","))
            _ = try integer()

            if peek == ascii("{") || peek == ascii("[") {
                let opener = try requireByte()
                let closer = opener == ascii("{") ? ascii("}") : ascii("]")
                let direction: SplitDirection = opener == ascii("{") ? .horizontal : .vertical
                var children: [ParsedNode] = []
                while true {
                    children.append(try parseNode(depth: depth + 1))
                    if peek == closer {
                        index += 1
                        break
                    }
                    try consume(ascii(","))
                }
                guard children.count >= 2 else { throw malformed() }
                return ParsedNode(
                    node: folded(children, direction: direction),
                    width: width,
                    height: height
                )
            }

            try consume(ascii(","))
            let number = String(try integer())
            guard seenPaneIDs.insert(number).inserted,
                  let pane = panesByNumber[number] else {
                throw SavedWorkspaceLayoutStoreError.invalid("tmux layout referenced an unknown or duplicate pane")
            }
            return ParsedNode(
                node: .leaf(SavedLayoutLeaf(
                    kind: pane.kind,
                    name: pane.displayName,
                    folder: pane.cwd
                )),
                width: width,
                height: height
            )
        }

        func folded(_ children: [ParsedNode], direction: SplitDirection) -> SavedLayoutNode {
            guard children.count > 1 else { return children[0].node }
            let first = children[0]
            let remaining = Array(children.dropFirst())
            let firstSize = direction == .horizontal ? first.width : first.height
            let remainingSize = remaining.reduce(0) {
                $0 + (direction == .horizontal ? $1.width : $1.height)
            }
            return .split(
                direction: direction,
                ratio: Double(firstSize) / Double(firstSize + remainingSize),
                first: first.node,
                second: folded(remaining, direction: direction)
            )
        }

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func integer() throws -> Int {
            let start = index
            while let byte = peek, byte >= ascii("0"), byte <= ascii("9") { index += 1 }
            guard index > start,
                  let value = Int(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw malformed()
            }
            return value
        }

        mutating func consume(_ expected: UInt8) throws {
            guard try requireByte() == expected else { throw malformed() }
        }

        mutating func requireByte() throws -> UInt8 {
            guard let byte = peek else { throw malformed() }
            index += 1
            return byte
        }

        func malformed() -> SavedWorkspaceLayoutStoreError {
            .invalid("tmux returned a malformed layout")
        }

        func ascii(_ character: Character) -> UInt8 {
            character.asciiValue!
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
        func validateNode(_ node: SavedLayoutNode, depth: Int) throws {
            guard depth <= 12 else {
                throw SavedWorkspaceLayoutStoreError.invalid("the split tree is too deep")
            }
            switch node {
            case let .leaf(leaf):
                leaves += 1
                let leafName = leaf.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (1...80).contains(leafName.count), leafName == leaf.name else {
                    throw SavedWorkspaceLayoutStoreError.invalid("pane names must be 1–80 trimmed characters")
                }
                guard leaf.folder.hasPrefix("/") else {
                    throw SavedWorkspaceLayoutStoreError.invalid("every pane folder must be absolute")
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
    }
}
