import Darwin
import Foundation

public enum ExternalContextImportKind: String, Codable, Equatable, Sendable {
    case selection
    case currentFile
    case diagnostics
    case gitDiff
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
    public let folder: String
    public let parts: [ContextPackPart]

    public init(folder: String, parts: [ContextPackPart]) {
        self.folder = folder
        self.parts = parts
    }
}

public enum ExternalContextImportError: LocalizedError, Equatable {
    case unsafeManifest
    case invalidManifest
    case unsupportedVersion
    case invalidItem

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
        }
    }
}

/// Consumes a one-shot editor manifest and turns it into ordinary context-pack
/// parts. The manifest can prepare an editable preview only: it carries no pane
/// target, prompt, vendor, capability or submit action.
public enum ExternalContextImport {
    public static let currentVersion = 1
    public static let maximumManifestBytes = 200_000

    public static func inboxDirectory(applicationDirectory: URL) -> URL {
        applicationDirectory.appendingPathComponent("external-context-inbox", isDirectory: true)
    }

    public static func consume(
        file: URL,
        applicationDirectory: URL,
        builder: ContextPackBuilder,
        fileManager: FileManager = .default
    ) throws -> ExternalContextImportRequest {
        let rawInbox = inboxDirectory(applicationDirectory: applicationDirectory).standardizedFileURL
        let inbox = rawInbox.resolvingSymlinksInPath().standardizedFileURL
        let rawCandidate = file.standardizedFileURL
        let candidate = rawCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard rawInbox.path == inbox.path,
              rawCandidate.path == candidate.path,
              candidate.deletingLastPathComponent().path == inbox.path,
              candidate.pathExtension == "parleycontext",
              let identifier = UUID(uuidString: candidate.deletingPathExtension().lastPathComponent),
              identifier.uuidString.lowercased() == candidate.deletingPathExtension().lastPathComponent else {
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

        let values = try candidate.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumManifestBytes else {
            throw ExternalContextImportError.invalidManifest
        }
        let handle = try FileHandle(forReadingFrom: candidate)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(ExternalContextImportManifest.self, from: data) else {
            throw ExternalContextImportError.invalidManifest
        }
        guard manifest.version == currentVersion else {
            throw ExternalContextImportError.unsupportedVersion
        }
        guard !manifest.items.isEmpty, manifest.items.count <= ContextPackBuilder.maximumParts else {
            throw ExternalContextImportError.invalidManifest
        }

        let folder = try ExternalWorkspaceOpen.request(folderPath: manifest.folder, fileManager: fileManager).folder
        let parts = try manifest.items.map { item in
            try capture(item, folder: folder, builder: builder, fileManager: fileManager)
        }
        _ = try builder.render(ContextPack(name: "VS Code context", parts: parts))
        return ExternalContextImportRequest(folder: folder, parts: parts)
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
        }
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
