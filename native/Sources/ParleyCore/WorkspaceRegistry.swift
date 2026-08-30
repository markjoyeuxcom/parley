import Darwin
import Foundation

/// One workspace's durable facts. Records and native split trees survive
/// window hiding and application restart; live process and surface ids never
/// become registry keys.
public struct WorkspaceRegistryRecord: Codable, Equatable, Sendable {
    public let workspaceID: String
    public var name: String
    public var attachedFolders: [String]
    public var newPaneFolder: String?
    public var automationPolicy: WorkspaceAutomationPolicy
    public var selectedPaneID: String?
    public var layoutRevision: Int
    public var layout: NativeLayoutNode?
    public var splitFractions: [String: Double]
    public var updatedAt: Date

    public init(
        workspaceID: String,
        name: String,
        attachedFolders: [String],
        newPaneFolder: String?,
        automationPolicy: WorkspaceAutomationPolicy,
        selectedPaneID: String? = nil,
        layoutRevision: Int = 0,
        layout: NativeLayoutNode? = nil,
        splitFractions: [String: Double] = [:],
        updatedAt: Date = Date()
    ) {
        self.workspaceID = workspaceID
        self.name = name
        self.attachedFolders = attachedFolders
        self.newPaneFolder = newPaneFolder
        self.automationPolicy = automationPolicy
        self.selectedPaneID = selectedPaneID
        self.layoutRevision = layoutRevision
        self.layout = layout
        self.splitFractions = splitFractions
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case name
        case attachedFolders
        case newPaneFolder
        // Legacy schema fields. Decode only; new records never write them.
        case homeFolder
        case defaultFolder
        case automationPolicy
        case selectedPaneID
        case layoutRevision
        case layout
        case splitFractions
        case updatedAt
    }

    /// Schema 1 predates native layout persistence. Missing presentation
    /// fields therefore mean "no recorded layout", not a corrupt registry.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        name = try values.decode(String.self, forKey: .name)
        if values.contains(.attachedFolders) {
            attachedFolders = try values.decode([String].self, forKey: .attachedFolders)
        } else if let legacyHome = try values.decodeIfPresent(String.self, forKey: .homeFolder) {
            attachedFolders = [legacyHome]
        } else if let legacyDefault = try values.decodeIfPresent(String.self, forKey: .defaultFolder) {
            attachedFolders = [legacyDefault]
        } else {
            attachedFolders = []
        }
        if values.contains(.newPaneFolder) {
            newPaneFolder = try values.decodeIfPresent(String.self, forKey: .newPaneFolder)
        } else {
            newPaneFolder = try values.decodeIfPresent(String.self, forKey: .defaultFolder)
        }
        automationPolicy = try values.decode(WorkspaceAutomationPolicy.self, forKey: .automationPolicy)
        selectedPaneID = try values.decodeIfPresent(String.self, forKey: .selectedPaneID)
        layoutRevision = try values.decodeIfPresent(Int.self, forKey: .layoutRevision) ?? 0
        layout = try values.decodeIfPresent(NativeLayoutNode.self, forKey: .layout)
        splitFractions = try values.decodeIfPresent([String: Double].self, forKey: .splitFractions) ?? [:]
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(workspaceID, forKey: .workspaceID)
        try values.encode(name, forKey: .name)
        try values.encode(attachedFolders, forKey: .attachedFolders)
        try values.encodeIfPresent(newPaneFolder, forKey: .newPaneFolder)
        try values.encode(automationPolicy, forKey: .automationPolicy)
        try values.encodeIfPresent(selectedPaneID, forKey: .selectedPaneID)
        try values.encode(layoutRevision, forKey: .layoutRevision)
        try values.encodeIfPresent(layout, forKey: .layout)
        try values.encode(splitFractions, forKey: .splitFractions)
        try values.encode(updatedAt, forKey: .updatedAt)
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
/// recovery flow may rebind a record after process loss, but synchronization
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
        workspaces: [WorkbenchWorkspace],
        selectedPaneIDs: [String: String] = [:]
    ) throws -> Bool {
        try lock.withLock {
            var document = try readDocument()
            var changed = false
            for workspace in workspaces where isDurable(workspace.workspaceID) {
                let selected = selectedPaneIDs[workspace.workspaceID]
                if let index = document.records.firstIndex(where: {
                    $0.workspaceID == workspace.workspaceID
                }) {
                    var updated = document.records[index]
                    updated.name = workspace.name
                    updated.attachedFolders = workspace.attachedFolders
                    updated.newPaneFolder = workspace.newPaneFolder
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
                        attachedFolders: workspace.attachedFolders,
                        newPaneFolder: workspace.newPaneFolder,
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

    /// Stores bounded divider fractions by stable tree path. Invalid or
    /// non-finite values are refused so corrupt UI geometry cannot hide panes.
    public func updateSplitFractions(
        workspaceID: String,
        fractions: [String: Double]
    ) throws {
        guard fractions.count <= NativeSplitGeometry.maximumRecordedSplits,
              fractions.allSatisfy({ path, fraction in
                  NativeSplitGeometry.isValidPath(path)
                      && fraction.isFinite
                      && fraction >= 0.05
                      && fraction <= 0.95
              }) else {
            throw WorkspaceRegistryError.invalid("split geometry is outside its safe bounds")
        }
        try lock.withLock {
            var document = try readDocument()
            guard let index = document.records.firstIndex(where: {
                $0.workspaceID == workspaceID
            }) else { return }
            guard document.records[index].splitFractions != fractions else { return }
            document.records[index].splitFractions = fractions
            document.records[index].layoutRevision += 1
            document.records[index].updatedAt = Date()
            try write(document)
        }
    }

    private func isDurable(_ workspaceID: String) -> Bool {
        !workspaceID.isEmpty && !workspaceID.hasPrefix("@")
    }

    private func equivalent(
        _ left: WorkspaceRegistryRecord,
        _ right: WorkspaceRegistryRecord
    ) -> Bool {
        left.name == right.name
            && left.attachedFolders == right.attachedFolders
            && left.newPaneFolder == right.newPaneFolder
            && left.automationPolicy == right.automationPolicy
            && left.selectedPaneID == right.selectedPaneID
            && left.layoutRevision == right.layoutRevision
            && left.layout == right.layout
            && left.splitFractions == right.splitFractions
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
