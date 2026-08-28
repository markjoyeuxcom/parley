import Darwin
import Foundation

public struct ExternalAttentionWorkspace: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let attentionCount: Int

    public init(id: String, name: String, attentionCount: Int) {
        self.id = id
        self.name = name
        self.attentionCount = attentionCount
    }
}

public struct ExternalAttentionPane: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: PaneKind
    public let workspaceID: String
    public let workspaceName: String

    public init(id: String, name: String, kind: PaneKind, workspaceID: String, workspaceName: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

public enum ExternalAttentionReason: String, Codable, Equatable, Sendable {
    case returnedResult
    case humanInputRequired
    case interrupted
}

public struct ExternalAttentionItem: Identifiable, Codable, Equatable, Sendable {
    public let handoffID: String
    public let workspaceID: String
    public let workspaceName: String
    public let label: String
    public let reason: ExternalAttentionReason

    public var id: String { handoffID }

    public init(
        handoffID: String,
        workspaceID: String,
        workspaceName: String,
        label: String,
        reason: ExternalAttentionReason
    ) {
        self.handoffID = handoffID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.label = label
        self.reason = reason
    }
}

/// A deliberately content-free view for local attention surfaces and editor
/// companions. It contains human labels, counts and opaque ids only: never
/// prompts, results, terminal output, process commands, folders, credentials
/// or a dispatch capability.
public struct ExternalAttentionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let attentionCount: Int
    public let workspaces: [ExternalAttentionWorkspace]
    public let panes: [ExternalAttentionPane]
    public let items: [ExternalAttentionItem]

    public init(
        version: Int = currentVersion,
        generatedAt: Date,
        attentionCount: Int,
        workspaces: [ExternalAttentionWorkspace],
        panes: [ExternalAttentionPane],
        items: [ExternalAttentionItem]
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.attentionCount = attentionCount
        self.workspaces = workspaces
        self.panes = panes
        self.items = items
    }

    public func hasSameContent(as other: ExternalAttentionSnapshot) -> Bool {
        attentionCount == other.attentionCount
            && workspaces == other.workspaces
            && panes == other.panes
            && items == other.items
    }
}

public enum ExternalAttentionProjection {
    public static let maximumWorkspaces = 256
    public static let maximumPanes = 512
    public static let maximumItems = 512

    public static func snapshot(
        workspaces: [TmuxWorkspace],
        panes: [TmuxPane],
        handoffs: [RelayHandoff],
        generatedAt: Date = Date()
    ) -> ExternalAttentionSnapshot {
        var canonicalWorkspaceByAlias: [String: String] = [:]
        var workspaceNames: [String: String] = [:]
        for workspace in workspaces {
            canonicalWorkspaceByAlias[workspace.id] = workspace.workspaceID
            canonicalWorkspaceByAlias[workspace.workspaceID] = workspace.workspaceID
            workspaceNames[workspace.workspaceID] = workspace.name
        }
        for pane in panes {
            canonicalWorkspaceByAlias[pane.windowID] = pane.workspaceID
            canonicalWorkspaceByAlias[pane.workspaceID] = pane.workspaceID
            if workspaceNames[pane.workspaceID] == nil, let name = pane.workspaceName {
                workspaceNames[pane.workspaceID] = name
            }
        }
        let actionable = handoffs.compactMap(actionableItem).map { original in
            let canonicalID = canonicalWorkspaceByAlias[original.item.workspaceID]
                ?? original.item.workspaceID
            let item = ExternalAttentionItem(
                handoffID: original.item.handoffID,
                workspaceID: canonicalID,
                workspaceName: workspaceNames[canonicalID] ?? original.item.workspaceName,
                label: original.item.label,
                reason: original.item.reason
            )
            return (item: item, updatedAt: original.updatedAt)
        }.sorted { left, right in
            if left.updatedAt == right.updatedAt { return left.item.handoffID < right.item.handoffID }
            return left.updatedAt > right.updatedAt
        }
        let items = actionable.prefix(maximumItems).map(\.item)
        let counts = Dictionary(grouping: actionable.map(\.item), by: \.workspaceID)
            .mapValues(\.count)

        return ExternalAttentionSnapshot(
            generatedAt: generatedAt,
            attentionCount: actionable.count,
            workspaces: workspaces.prefix(maximumWorkspaces).map {
                ExternalAttentionWorkspace(
                    id: $0.workspaceID,
                    name: $0.name,
                    attentionCount: counts[$0.workspaceID, default: 0]
                )
            },
            panes: panes.lazy
                .filter { $0.kind.isAgent && $0.isStarted && !$0.isDead }
                .prefix(maximumPanes)
                .map {
                    ExternalAttentionPane(
                        id: $0.id,
                        name: $0.displayName,
                        kind: $0.kind,
                        workspaceID: $0.workspaceID,
                        workspaceName: workspaceNames[$0.workspaceID]
                            ?? $0.workspaceName ?? $0.workspaceID
                    )
                },
            items: items
        )
    }

    private static func actionableItem(_ handoff: RelayHandoff) -> (item: ExternalAttentionItem, updatedAt: Date)? {
        let reason: ExternalAttentionReason
        let workspaceID: String
        let workspaceName: String
        let label: String
        if handoff.hasUnreadResult {
            reason = .returnedResult
            workspaceID = handoff.sourceWorkspaceID
            workspaceName = handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID
            label = handoff.kind == .delegate
                ? "\(handoff.targetName) completed a delegation"
                : "\(handoff.targetName) returned an answer"
        } else if let attention = handoff.attention {
            reason = .humanInputRequired
            workspaceID = handoff.targetWorkspaceID
            workspaceName = handoff.targetWorkspaceName ?? handoff.targetWorkspaceID
            label = switch attention {
            case .permissionRequired: "\(handoff.targetName) needs permission review"
            case .targetNotReady: "\(handoff.targetName) is not ready"
            case .targetUnavailable: "\(handoff.targetName) is unavailable"
            }
        } else if handoff.state == .failed || handoff.state == .interrupted {
            reason = .interrupted
            workspaceID = handoff.sourceWorkspaceID
            workspaceName = handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID
            label = handoff.state == .failed
                ? "\(handoff.sourceName) → \(handoff.targetName) failed"
                : "\(handoff.sourceName) → \(handoff.targetName) was interrupted"
        } else {
            return nil
        }
        return (
            ExternalAttentionItem(
                handoffID: handoff.id,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                label: label,
                reason: reason
            ),
            handoff.updatedAt
        )
    }
}

public struct MenuBarAttentionSummary: Equatable, Sendable {
    public let coreAvailable: Bool
    public let totalCount: Int
    public let items: [ExternalAttentionItem]
    public let hiddenItemCount: Int
    public let headline: String
}

/// A small, content-free slice of the same attention contract published to
/// local editor companions. It never receives a RelayHandoff, so prompt and
/// result bodies cannot accidentally enter menu-bar presentation code.
public enum MenuBarAttentionProjection {
    public static let maximumVisibleItems = 8

    public static func summary(
        snapshot: ExternalAttentionSnapshot,
        coreAvailable: Bool
    ) -> MenuBarAttentionSummary {
        let totalCount = max(0, snapshot.attentionCount)
        let items = Array(snapshot.items.prefix(maximumVisibleItems))
        let headline: String
        if !coreAvailable {
            headline = "Coordination unavailable"
        } else if totalCount == 0 {
            headline = "No items need attention"
        } else if totalCount == 1 {
            headline = "1 item needs attention"
        } else {
            headline = "\(totalCount) items need attention"
        }
        return MenuBarAttentionSummary(
            coreAvailable: coreAvailable,
            totalCount: totalCount,
            items: items,
            hiddenItemCount: max(0, totalCount - items.count),
            headline: headline
        )
    }
}

public enum ExternalAttentionSnapshotFileError: LocalizedError, Equatable {
    case unsafeDirectory
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            "Parley can publish editor attention only inside its private local application directory."
        case .tooLarge:
            "Parley's editor attention snapshot exceeded its local integration bound."
        }
    }
}

public enum ExternalAttentionSnapshotFile {
    public static let name = "external-attention.json"
    public static let maximumBytes = 128_000

    public static func url(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent(name)
    }

    @discardableResult
    public static func write(
        _ snapshot: ExternalAttentionSnapshot,
        applicationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let rawDirectory = applicationDirectory.standardizedFileURL
        let directory = rawDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard rawDirectory.path == directory.path,
              privatePath(directory.path, directory: true, fileManager: fileManager) else {
            throw ExternalAttentionSnapshotFileError.unsafeDirectory
        }
        let file = url(applicationDirectory: directory)
        if let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw ExternalAttentionSnapshotFileError.unsafeDirectory
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ExternalAttentionSnapshotFileError.tooLarge
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private static func privatePath(_ path: String, directory: Bool, fileManager: FileManager) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType,
              type == (directory ? .typeDirectory : .typeRegular),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              owner.uint32Value == getuid(),
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.intValue & 0o077 == 0
    }
}

public enum ExternalNavigationRequest: Equatable, Sendable {
    case pane(String)
    case handoff(String)
}

public enum ExternalNavigationError: LocalizedError, Equatable {
    case invalidURL

    public var errorDescription: String? {
        "Parley focus links can identify exactly one live pane or Status Center handoff and cannot carry work."
    }
}

public enum ExternalNavigation {
    public static func request(url: URL) throws -> ExternalNavigationRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare(ExternalWorkspaceOpen.scheme) == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let items = components.queryItems,
              items.count == 1,
              let value = items[0].value else {
            throw ExternalNavigationError.invalidURL
        }
        switch (components.host?.lowercased(), items[0].name) {
        case ("focus", "pane") where validPaneID(value):
            return .pane(value)
        case ("status", "handoff") where validHandoffID(value):
            return .handoff(value)
        default:
            throw ExternalNavigationError.invalidURL
        }
    }

    public static func url(for request: ExternalNavigationRequest) throws -> URL {
        var components = URLComponents()
        components.scheme = ExternalWorkspaceOpen.scheme
        switch request {
        case let .pane(id):
            guard validPaneID(id) else { throw ExternalNavigationError.invalidURL }
            components.host = "focus"
            components.queryItems = [URLQueryItem(name: "pane", value: id)]
        case let .handoff(id):
            guard validHandoffID(id) else { throw ExternalNavigationError.invalidURL }
            components.host = "status"
            components.queryItems = [URLQueryItem(name: "handoff", value: id)]
        }
        guard let url = components.url else { throw ExternalNavigationError.invalidURL }
        return url
    }

    private static func validPaneID(_ value: String) -> Bool {
        value.count >= 2
            && value.count <= 16
            && value.first == "%"
            && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func validHandoffID(_ value: String) -> Bool {
        guard value == value.lowercased(), let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }
}
