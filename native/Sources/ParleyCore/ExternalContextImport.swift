import Darwin
import Foundation

public enum ExternalContextImportKind: String, Codable, Equatable, Sendable {
    case selection
    case currentFile
    case diagnostics
    case gitDiff
    case gitWorkingDiff
    case gitStagedDiff
}

public struct ExternalContextImportItem: Codable, Equatable, Sendable {
    public let kind: ExternalContextImportKind
    public let file: String?
    public let startLine: Int?
    public let endLine: Int?
    public let text: String?

    public init(
        kind: ExternalContextImportKind,
        file: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        text: String? = nil
    ) {
        self.kind = kind
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
    }
}

public struct ExternalContextImportManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let folder: String
    public let items: [ExternalContextImportItem]

    public init(version: Int, folder: String, items: [ExternalContextImportItem]) {
        self.version = version
        self.folder = folder
        self.items = items
    }
}

public struct ExternalContextImportRequest: Equatable, Sendable {
    public let requestID: String
    public let folder: String
    public let parts: [ContextPackPart]

    public init(requestID: String, folder: String, parts: [ContextPackPart]) {
        self.requestID = requestID
        self.folder = folder
        self.parts = parts
    }
}

public enum ExternalContextImportError: LocalizedError, Equatable {
    case unsafeManifest
    case invalidManifest
    case unsupportedVersion
    case invalidItem
    case expiredManifest

    public var errorDescription: String? {
        switch self {
        case .unsafeManifest:
            "Parley accepts editor context only from its private one-shot integration inbox."
        case .invalidManifest:
            "That editor context request is missing, malformed or too large."
        case .unsupportedVersion:
            "That editor context request uses an unsupported contract version. Update Parley and its editor companion together."
        case .invalidItem:
            "That editor context request contains an unsupported source or a path outside its workspace."
        case .expiredManifest:
            "That editor context request expired before Parley could open it. Build the context pack again from VS Code."
        }
    }
}

/// Consumes a one-shot editor manifest and turns it into ordinary context-pack
/// parts. The manifest can prepare an editable preview only: it carries no pane
/// target, prompt, vendor, capability or submit action.
public enum ExternalContextImport {
    public static let currentVersion = 2
    public static let supportedVersions = [1, currentVersion]
    public static let maximumManifestBytes = 200_000
    public static let requestLifetime: TimeInterval = 300

    public static func inboxDirectory(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent("external-context-inbox", isDirectory: true)
    }

    public static func consume(
        file: URL,
        applicationDirectory: URL,
        builder: ContextPackBuilder,
        fileManager: FileManager = .default
    ) throws -> ExternalContextImportRequest {
        guard let requestID = requestIdentifier(
            file: file,
            applicationDirectory: applicationDirectory
        ) else {
            throw ExternalContextImportError.unsafeManifest
        }
        let rawInbox = inboxDirectory(applicationDirectory: applicationDirectory).standardizedFileURL
        let inbox = rawInbox.resolvingSymlinksInPath().standardizedFileURL
        let rawCandidate = file.standardizedFileURL
        let candidate = rawCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard rawInbox.path == inbox.path,
              rawCandidate.path == candidate.path,
              candidate.deletingLastPathComponent().path == inbox.path,
              candidate.pathExtension == "parleycontext" else {
            throw ExternalContextImportError.unsafeManifest
        }

        guard privatePath(inbox.path, directory: true, fileManager: fileManager),
              privatePath(candidate.path, directory: false, fileManager: fileManager) else {
            if candidate.deletingLastPathComponent().path == inbox.path {
                try? fileManager.removeItem(at: candidate)
            }
            throw ExternalContextImportError.unsafeManifest
        }
        defer { try? fileManager.removeItem(at: candidate) }

        let values = try candidate.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumManifestBytes else {
            throw ExternalContextImportError.invalidManifest
        }
        if let modifiedAt = values.contentModificationDate {
            let age = Date().timeIntervalSince(modifiedAt)
            guard age >= -5 else { throw ExternalContextImportError.invalidManifest }
            guard age <= requestLifetime else { throw ExternalContextImportError.expiredManifest }
        }
        let handle = try FileHandle(forReadingFrom: candidate)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw ExternalContextImportError.invalidManifest
        }
        try validateShape(data)
        guard let manifest = try? JSONDecoder().decode(ExternalContextImportManifest.self, from: data) else {
            throw ExternalContextImportError.invalidManifest
        }
        guard supportedVersions.contains(manifest.version) else {
            throw ExternalContextImportError.unsupportedVersion
        }
        guard !manifest.items.isEmpty, manifest.items.count <= ContextPackBuilder.maximumParts else {
            throw ExternalContextImportError.invalidManifest
        }

        let folder = try ExternalWorkspaceOpen.request(folderPath: manifest.folder, fileManager: fileManager).folder
        if manifest.version == 1,
           manifest.items.contains(where: { $0.kind == .gitWorkingDiff || $0.kind == .gitStagedDiff }) {
            throw ExternalContextImportError.invalidItem
        }
        let parts = try manifest.items.map { item in
            try capture(item, folder: folder, builder: builder, fileManager: fileManager)
        }
        _ = try builder.render(ContextPack(name: "VS Code context", parts: parts))
        return ExternalContextImportRequest(requestID: requestID, folder: folder, parts: parts)
    }

    public static func requestIdentifier(
        file: URL,
        applicationDirectory: URL
    ) -> String? {
        let rawInbox = inboxDirectory(applicationDirectory: applicationDirectory).standardizedFileURL
        let inbox = rawInbox.resolvingSymlinksInPath().standardizedFileURL
        let rawCandidate = file.standardizedFileURL
        let candidate = rawCandidate.resolvingSymlinksInPath().standardizedFileURL
        let name = candidate.deletingPathExtension().lastPathComponent
        guard rawInbox.path == inbox.path,
              rawCandidate.path == candidate.path,
              candidate.deletingLastPathComponent().path == inbox.path,
              candidate.pathExtension == "parleycontext",
              let identifier = UUID(uuidString: name),
              identifier.uuidString.lowercased() == name else {
            return nil
        }
        return name
    }

    private static func capture(
        _ item: ExternalContextImportItem,
        folder: String,
        builder: ContextPackBuilder,
        fileManager: FileManager
    ) throws -> ContextPackPart {
        switch item.kind {
        case .selection:
            guard let relative = item.file,
                  let start = item.startLine,
                  let end = item.endLine,
                  start > 0,
                  end >= start,
                  end <= 1_000_000,
                  let text = item.text,
                  item.text != nil,
                  try containedFile(relative, folder: folder, fileManager: fileManager) != nil else {
                throw ExternalContextImportError.invalidItem
            }
            return try builder.editorSelection(
                relativeFile: relative,
                startLine: start,
                endLine: end,
                text: text
            )
        case .currentFile:
            guard item.text == nil, item.startLine == nil, item.endLine == nil,
                  let relative = item.file,
                  let file = try containedFile(relative, folder: folder, fileManager: fileManager) else {
                throw ExternalContextImportError.invalidItem
            }
            return try builder.file(at: file)
        case .diagnostics:
            guard let relative = item.file,
                  let text = item.text,
                  item.startLine == nil,
                  item.endLine == nil,
                  try containedFile(relative, folder: folder, fileManager: fileManager) != nil else {
                throw ExternalContextImportError.invalidItem
            }
            return try builder.editorDiagnostics(relativeFile: relative, text: text)
        case .gitDiff:
            guard item.file == nil, item.text == nil, item.startLine == nil, item.endLine == nil else {
                throw ExternalContextImportError.invalidItem
            }
            return try builder.gitDiff(in: folder)
        case .gitWorkingDiff, .gitStagedDiff:
            guard item.text == nil, item.startLine == nil, item.endLine == nil else {
                throw ExternalContextImportError.invalidItem
            }
            let relative = try item.file.map { try safeGitRelativePath($0) }
            return try builder.gitDiff(
                in: folder,
                scope: item.kind == .gitWorkingDiff ? .workingTree : .staged,
                relativeFile: relative
            )
        }
    }

    private static func validateShape(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["version", "folder", "items"]),
              root["version"] is NSNumber,
              root["folder"] is String,
              let items = root["items"] as? [[String: Any]] else {
            throw ExternalContextImportError.invalidManifest
        }
        for item in items {
            guard let kind = item["kind"] as? String else {
                throw ExternalContextImportError.invalidManifest
            }
            let keys = Set(item.keys)
            let valid = switch kind {
            case ExternalContextImportKind.selection.rawValue:
                keys == Set(["kind", "file", "startLine", "endLine", "text"])
            case ExternalContextImportKind.currentFile.rawValue:
                keys == Set(["kind", "file"])
            case ExternalContextImportKind.diagnostics.rawValue:
                keys == Set(["kind", "file", "text"])
            case ExternalContextImportKind.gitDiff.rawValue:
                keys == Set(["kind"])
            case ExternalContextImportKind.gitWorkingDiff.rawValue,
                 ExternalContextImportKind.gitStagedDiff.rawValue:
                keys == Set(["kind"]) || keys == Set(["kind", "file"])
            default:
                false
            }
            guard valid else { throw ExternalContextImportError.invalidManifest }
        }
    }

    private static func safeGitRelativePath(_ relative: String) throws -> String {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              relative.utf8.count <= 4_096,
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw ExternalContextImportError.invalidItem
        }
        return relative
    }

    private static func containedFile(
        _ relative: String,
        folder: String,
        fileManager: FileManager
    ) throws -> URL? {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              relative.utf8.count <= 4_096 else {
            throw ExternalContextImportError.invalidItem
        }
        let candidate = URL(fileURLWithPath: folder, isDirectory: true)
            .appendingPathComponent(relative)
        guard let resolved = realpath(candidate.path, nil) else {
            throw ExternalContextImportError.invalidItem
        }
        defer { free(resolved) }
        let path = String(cString: resolved)
        guard path.hasPrefix(folder + "/") else {
            throw ExternalContextImportError.invalidItem
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ExternalContextImportError.invalidItem
        }
        return URL(fileURLWithPath: path)
    }

    private static func privatePath(
        _ path: String,
        directory: Bool,
        fileManager: FileManager
    ) -> Bool {
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

public struct ExternalContextImportCapabilities: Codable, Equatable, Sendable {
    public let versions: [Int]
    public let kinds: [ExternalContextImportKind]
    public let maximumManifestBytes: Int
    public let maximumItems: Int
    public let acknowledgementVersion: Int
    public let requestLifetimeSeconds: Int

    public init(
        versions: [Int] = ExternalContextImport.supportedVersions,
        kinds: [ExternalContextImportKind] = [
            .selection,
            .currentFile,
            .diagnostics,
            .gitDiff,
            .gitWorkingDiff,
            .gitStagedDiff,
        ],
        maximumManifestBytes: Int = ExternalContextImport.maximumManifestBytes,
        maximumItems: Int = ContextPackBuilder.maximumParts,
        acknowledgementVersion: Int = ExternalContextAcknowledgement.currentVersion,
        requestLifetimeSeconds: Int = Int(ExternalContextImport.requestLifetime)
    ) {
        self.versions = versions
        self.kinds = kinds
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumItems = maximumItems
        self.acknowledgementVersion = acknowledgementVersion
        self.requestLifetimeSeconds = requestLifetimeSeconds
    }
}

/// Content-free, heartbeat-bound negotiation surface for local editor
/// companions. It advertises only contract shape and hard limits.
public struct ExternalEditorBridgeCapabilities: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let contextImport: ExternalContextImportCapabilities

    public init(
        version: Int = currentVersion,
        generatedAt: Date,
        contextImport: ExternalContextImportCapabilities = ExternalContextImportCapabilities()
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.contextImport = contextImport
    }
}

public enum ExternalEditorBridgeFileError: LocalizedError, Equatable {
    case unsafeDirectory
    case invalidAcknowledgement
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            "Parley can exchange editor acknowledgements only through its private local integration directories."
        case .invalidAcknowledgement:
            "Parley refused to publish an invalid editor acknowledgement."
        case .tooLarge:
            "Parley's editor integration response exceeded its local safety bound."
        }
    }
}

public enum ExternalEditorBridgeCapabilitiesFile {
    public static let name = "external-editor-capabilities.json"
    public static let maximumBytes = 16_000

    public static func url(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent(name)
    }

    @discardableResult
    public static func write(
        _ capabilities: ExternalEditorBridgeCapabilities,
        applicationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try ExternalEditorBridgePrivatePath.requireApplicationDirectory(
            applicationDirectory,
            fileManager: fileManager
        )
        let file = url(applicationDirectory: directory)
        try ExternalEditorBridgePrivatePath.refuseSymlink(file)
        let data = try ExternalEditorBridgePrivatePath.encode(capabilities)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ExternalEditorBridgeFileError.tooLarge
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func remove(
        applicationDirectory: URL,
        fileManager: FileManager = .default
    ) {
        let file = url(applicationDirectory: applicationDirectory)
        guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            return
        }
        try? fileManager.removeItem(at: file)
    }
}

public enum ExternalContextAcknowledgementState: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
    case expired
}

public enum ExternalContextAcknowledgementCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unsupportedVersion
    case invalidSource
    case contextUnavailable
    case noReadyAgent
    case declinedReplacement
    case requestExpired
    case internalError
}

public struct ExternalContextAcknowledgement: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: String
    public let state: ExternalContextAcknowledgementState
    public let acknowledgedAt: Date
    public let workspaceID: String?
    public let sourceCount: Int?
    public let code: ExternalContextAcknowledgementCode?
    public let message: String?

    private init(
        version: Int = currentVersion,
        requestID: String,
        state: ExternalContextAcknowledgementState,
        acknowledgedAt: Date,
        workspaceID: String? = nil,
        sourceCount: Int? = nil,
        code: ExternalContextAcknowledgementCode? = nil,
        message: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.state = state
        self.acknowledgedAt = acknowledgedAt
        self.workspaceID = workspaceID
        self.sourceCount = sourceCount
        self.code = code
        self.message = message
    }

    public static func accepted(
        requestID: String,
        workspaceID: String,
        sourceCount: Int,
        acknowledgedAt: Date = Date()
    ) -> ExternalContextAcknowledgement {
        ExternalContextAcknowledgement(
            requestID: requestID,
            state: .accepted,
            acknowledgedAt: acknowledgedAt,
            workspaceID: workspaceID,
            sourceCount: sourceCount
        )
    }

    public static func rejected(
        requestID: String,
        code: ExternalContextAcknowledgementCode,
        message: String,
        acknowledgedAt: Date = Date()
    ) -> ExternalContextAcknowledgement {
        ExternalContextAcknowledgement(
            requestID: requestID,
            state: .rejected,
            acknowledgedAt: acknowledgedAt,
            code: code,
            message: message
        )
    }

    public static func expired(
        requestID: String,
        acknowledgedAt: Date = Date()
    ) -> ExternalContextAcknowledgement {
        ExternalContextAcknowledgement(
            requestID: requestID,
            state: .expired,
            acknowledgedAt: acknowledgedAt,
            code: .requestExpired,
            message: "That context request expired before Parley could open it. Build the context pack again."
        )
    }
}

public enum ExternalContextAcknowledgementFile {
    public static let directoryName = "external-context-outbox"
    public static let maximumBytes = 4_096

    public static func directory(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func url(requestID: String, applicationDirectory: URL) -> URL {
        directory(applicationDirectory: applicationDirectory)
            .appendingPathComponent("\(requestID).json")
    }

    @discardableResult
    public static func write(
        _ acknowledgement: ExternalContextAcknowledgement,
        applicationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let application = try ExternalEditorBridgePrivatePath.requireApplicationDirectory(
            applicationDirectory,
            fileManager: fileManager
        )
        guard acknowledgement.version == ExternalContextAcknowledgement.currentVersion,
              ExternalEditorBridgePrivatePath.validRequestID(acknowledgement.requestID),
              validShape(acknowledgement) else {
            throw ExternalEditorBridgeFileError.invalidAcknowledgement
        }
        let outbox = directory(applicationDirectory: application)
        if fileManager.fileExists(atPath: outbox.path) {
            guard ExternalEditorBridgePrivatePath.privatePath(
                outbox.path,
                directory: true,
                fileManager: fileManager
            ) else {
                throw ExternalEditorBridgeFileError.unsafeDirectory
            }
        } else {
            try fileManager.createDirectory(at: outbox, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outbox.path)
        }
        let file = url(requestID: acknowledgement.requestID, applicationDirectory: application)
        try ExternalEditorBridgePrivatePath.refuseSymlink(file)
        let data = try ExternalEditorBridgePrivatePath.encode(acknowledgement)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ExternalEditorBridgeFileError.tooLarge
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func removeExpired(
        applicationDirectory: URL,
        olderThan lifetime: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let application = try ExternalEditorBridgePrivatePath.requireApplicationDirectory(
            applicationDirectory,
            fileManager: fileManager
        )
        let outbox = directory(applicationDirectory: application)
        guard fileManager.fileExists(atPath: outbox.path) else { return }
        guard ExternalEditorBridgePrivatePath.privatePath(
            outbox.path,
            directory: true,
            fileManager: fileManager
        ) else {
            throw ExternalEditorBridgeFileError.unsafeDirectory
        }
        let candidates = try fileManager.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates where candidate.pathExtension == "json" {
            let requestID = candidate.deletingPathExtension().lastPathComponent
            guard ExternalEditorBridgePrivatePath.validRequestID(requestID),
                  let values = try? candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > max(1, lifetime),
                  ExternalEditorBridgePrivatePath.privatePath(
                    candidate.path,
                    directory: false,
                    fileManager: fileManager
                  ) else {
                continue
            }
            try fileManager.removeItem(at: candidate)
        }
    }

    private static func validShape(_ acknowledgement: ExternalContextAcknowledgement) -> Bool {
        switch acknowledgement.state {
        case .accepted:
            guard let workspaceID = acknowledgement.workspaceID,
                  !workspaceID.isEmpty,
                  workspaceID.utf8.count <= 256,
                  !workspaceID.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
                  let sourceCount = acknowledgement.sourceCount,
                  (1...ContextPackBuilder.maximumParts).contains(sourceCount) else {
                return false
            }
            return acknowledgement.code == nil && acknowledgement.message == nil
        case .rejected, .expired:
            guard acknowledgement.workspaceID == nil,
                  acknowledgement.sourceCount == nil,
                  acknowledgement.code != nil,
                  let message = acknowledgement.message,
                  !message.isEmpty,
                  message.utf8.count <= 512,
                  !message.contains(where: { $0.isNewline || $0.asciiValue == 0 }) else {
                return false
            }
            return true
        }
    }
}

private enum ExternalEditorBridgePrivatePath {
    static func requireApplicationDirectory(
        _ value: URL,
        fileManager: FileManager
    ) throws -> URL {
        let raw = value.standardizedFileURL
        let resolved = raw.resolvingSymlinksInPath().standardizedFileURL
        guard raw.path == resolved.path,
              privatePath(resolved.path, directory: true, fileManager: fileManager) else {
            throw ExternalEditorBridgeFileError.unsafeDirectory
        }
        return resolved
    }

    static func privatePath(_ path: String, directory: Bool, fileManager: FileManager) -> Bool {
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

    static func refuseSymlink(_ file: URL) throws {
        if let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw ExternalEditorBridgeFileError.unsafeDirectory
        }
    }

    static func validRequestID(_ value: String) -> Bool {
        guard let identifier = UUID(uuidString: value) else { return false }
        return identifier.uuidString.lowercased() == value
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
