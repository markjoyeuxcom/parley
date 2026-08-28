import Darwin
import Foundation

/// One workspace's durable facts, keyed by @parley-ws-id. Records and native
/// split trees survive UI/core reattachment and temporary absence of the tmux
/// server. Rebinding them to a newly created tmux workspace after server loss
/// requires an explicit, unambiguous recovery transaction; live tmux ids never
/// become registry keys.
public struct WorkspaceRegistryRecord: Codable, Equatable, Sendable {
    public let workspaceID: String
    public var name: String
    public var homeFolder: String
    public var defaultFolder: String
    public var automationPolicy: WorkspaceAutomationPolicy
    public var selectedPaneID: String?
    public var layoutRevision: Int
    public var layout: NativeLayoutNode?
    public var updatedAt: Date

    public init(
        workspaceID: String,
        name: String,
        homeFolder: String,
        defaultFolder: String,
        automationPolicy: WorkspaceAutomationPolicy,
        selectedPaneID: String? = nil,
        layoutRevision: Int = 0,
        layout: NativeLayoutNode? = nil,
        updatedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.homeFolder = homeFolder
        self.defaultFolder = defaultFolder
        self.automationPolicy = automationPolicy
        self.selectedPaneID = selectedPaneID
        self.layoutRevision = layoutRevision
        self.layout = layout
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case name
        case homeFolder
        case defaultFolder
        case automationPolicy
        case selectedPaneID
        case layoutRevision
        case layout
        case updatedAt
    }

    /// Schema 1 predates native layout persistence. Missing presentation
    /// fields therefore mean "no recorded layout", not a corrupt registry.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        name = try values.decode(String.self, forKey: .name)
        homeFolder = try values.decode(String.self, forKey: .homeFolder)
        defaultFolder = try values.decode(String.self, forKey: .defaultFolder)
        automationPolicy = try values.decode(WorkspaceAutomationPolicy.self, forKey: .automationPolicy)
        selectedPaneID = try values.decodeIfPresent(String.self, forKey: .selectedPaneID)
        layoutRevision = try values.decodeIfPresent(Int.self, forKey: .layoutRevision) ?? 0
        layout = try values.decodeIfPresent(NativeLayoutNode.self, forKey: .layout)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }
}

public enum WorkspaceRegistryError: LocalizedError, Equatable {
    case unreadable(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(reason):
            "Parley cannot read its workspace registry: \(reason)"
        case let .invalid(reason):
            "Parley cannot record this workspace: \(reason)"
        }
    }
}

/// Owner-only JSON store for workspace registry records. Records survive a
/// temporarily missing workspace; only an explicit close removes one. A future
/// recovery flow may rebind a record after tmux server loss, but synchronization
/// never guesses between folders or workspace names.
public final class WorkspaceRegistry {
    private struct Document: Codable {
        let version: Int
        var records: [WorkspaceRegistryRecord]
    }

    private static let schemaVersion = 1
    private static let maximumRecords = 200

    public let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func records() throws -> [WorkspaceRegistryRecord] {
        try lock.withLock { try readDocument().records }
    }

    public func record(workspaceID: String) throws -> WorkspaceRegistryRecord? {
        try lock.withLock {
            try readDocument().records.first { $0.workspaceID == workspaceID }
        }
    }

    /// Upserts every workspace that carries a durable identity; live-window-id
    /// fallbacks are ignored rather than poisoning the registry. Records whose
    /// workspace is absent are kept. Returns true when the file changed.
    @discardableResult
    public func synchronize(
        workspaces: [TmuxWorkspace],
        selectedPaneIDs: [String: String] = [:]
    ) throws -> Bool {
        try lock.withLock {
            var document = try readDocument()
            var changed = false
            for workspace in workspaces where isDurable(workspace.workspaceID, liveID: workspace.id) {
                let selected = selectedPaneIDs[workspace.workspaceID]
                if let index = document.records.firstIndex(where: {
                    $0.workspaceID == workspace.workspaceID
                }) {
                    var updated = document.records[index]
                    updated.name = workspace.name
                    updated.homeFolder = workspace.homeFolder
                    updated.defaultFolder = workspace.defaultFolder
                    updated.automationPolicy = workspace.automationPolicy
                    updated.selectedPaneID = selected ?? updated.selectedPaneID
                    if !equivalent(updated, document.records[index]) {
                        updated.updatedAt = Date()
                        document.records[index] = updated
                        changed = true
                    }
                } else {
                    guard document.records.count < Self.maximumRecords else {
                        throw WorkspaceRegistryError.invalid(
                            "at most \(Self.maximumRecords) workspaces may be recorded"
                        )
                    }
                    document.records.append(WorkspaceRegistryRecord(
                        workspaceID: workspace.workspaceID,
                        name: workspace.name,
                        homeFolder: workspace.homeFolder,
                        defaultFolder: workspace.defaultFolder,
                        automationPolicy: workspace.automationPolicy,
                        selectedPaneID: selected
                    ))
                    changed = true
                }
            }
            if changed { try write(document) }
            return changed
        }
    }

    /// Records focus independently for each durable workspace. Repeating the
    /// same selection is a no-op so periodic refresh does not churn the file.
    @discardableResult
    public func updateSelectedPane(workspaceID: String, paneID: String?) throws -> Bool {
        try lock.withLock {
            var document = try readDocument()
            guard let index = document.records.firstIndex(where: {
                $0.workspaceID == workspaceID
            }) else {
                throw WorkspaceRegistryError.invalid("no registry record for workspace \(workspaceID)")
            }
            guard document.records[index].selectedPaneID != paneID else { return false }
            document.records[index].selectedPaneID = paneID
            document.records[index].updatedAt = Date()
            try write(document)
            return true
        }
    }

    public func remove(workspaceID: String) throws {
        try lock.withLock {
            var document = try readDocument()
            let count = document.records.count
            document.records.removeAll { $0.workspaceID == workspaceID }
            guard document.records.count != count else { return }
            try write(document)
        }
    }

    /// Stores the workspace's native split tree and advances its revision.
    /// A missing record means the workspace never earned durable identity;
    /// the layout is presentation state, so that is a quiet no-op.
    public func updateLayout(workspaceID: String, layout: NativeLayoutNode?) throws {
        try lock.withLock {
            var document = try readDocument()
            guard let index = document.records.firstIndex(where: {
                $0.workspaceID == workspaceID
            }) else { return }
            guard document.records[index].layout != layout else { return }
            document.records[index].layout = layout
            document.records[index].layoutRevision += 1
            document.records[index].updatedAt = Date()
            try write(document)
        }
    }

    private func isDurable(_ workspaceID: String, liveID: String) -> Bool {
        !workspaceID.isEmpty && !workspaceID.hasPrefix("@") && workspaceID != liveID
    }

    private func equivalent(
        _ left: WorkspaceRegistryRecord,
        _ right: WorkspaceRegistryRecord
    ) -> Bool {
        left.name == right.name
            && left.homeFolder == right.homeFolder
            && left.defaultFolder == right.defaultFolder
            && left.automationPolicy == right.automationPolicy
            && left.selectedPaneID == right.selectedPaneID
            && left.layoutRevision == right.layoutRevision
            && left.layout == right.layout
    }

    private func readDocument() throws -> Document {
        guard fileManager.fileExists(atPath: file.path) else {
            return Document(version: Self.schemaVersion, records: [])
        }
        try validateExistingFile()
        do {
            let data = try Data(contentsOf: file)
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == Self.schemaVersion else {
                throw WorkspaceRegistryError.unreadable("unsupported schema version \(document.version)")
            }
            return document
        } catch let error as WorkspaceRegistryError {
            throw error
        } catch {
            throw WorkspaceRegistryError.unreadable(error.localizedDescription)
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
            throw WorkspaceRegistryError.unreadable("the registry file is not an owner-only regular file")
        }
    }
}
