import Darwin
import Foundation

/// The complete authority carried by an external Parley entry point. It can
/// identify one local folder; it cannot carry text, a pane kind or a submit
/// action, so parsing a URL never becomes an implicit model turn.
public struct ExternalWorkspaceOpenRequest: Equatable, Sendable {
    public let folder: String

    public init(folder: String) {
        self.folder = folder
    }
}

public enum ExternalWorkspaceOpenError: LocalizedError, Equatable {
    case invalidURL
    case oneFolderRequired
    case invalidFolder(String)
    case notDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Parley links must use parley://open?folder=<absolute-folder> and cannot contain any other instruction."
        case .oneFolderRequired:
            "Choose exactly one local folder to open in Parley."
        case let .invalidFolder(path):
            "Parley can open only one absolute local folder: \(path)"
        case let .notDirectory(path):
            "The requested Parley workspace folder does not exist or is not a directory: \(path)"
        }
    }
}

public enum ExternalWorkspaceOpen {
    public static let scheme = "parley"
    public static let action = "open"
    public static let maximumFolderBytes = 4_096

    public static func request(
        url: URL,
        fileManager: FileManager = .default
    ) throws -> ExternalWorkspaceOpenRequest {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
              components.host?.caseInsensitiveCompare(action) == .orderedSame,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "folder",
              let folder = items[0].value else {
            throw ExternalWorkspaceOpenError.invalidURL
        }
        return try request(folderPath: folder, fileManager: fileManager)
    }

    public static func request(
        folderPaths: [String],
        fileManager: FileManager = .default
    ) throws -> ExternalWorkspaceOpenRequest {
        guard folderPaths.count == 1, let folderPath = folderPaths.first else {
            throw ExternalWorkspaceOpenError.oneFolderRequired
        }
        return try request(folderPath: folderPath, fileManager: fileManager)
    }

    public static func request(
        folderPath: String,
        fileManager: FileManager = .default
    ) throws -> ExternalWorkspaceOpenRequest {
        let trimmed = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.contains(where: { $0.isNewline || $0.asciiValue == 0 }),
              !trimmed.isEmpty,
              trimmed.utf8.count <= maximumFolderBytes else {
            throw ExternalWorkspaceOpenError.invalidFolder(folderPath)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExternalWorkspaceOpenError.notDirectory(trimmed)
        }
        guard let resolved = realpath(trimmed, nil) else {
            throw ExternalWorkspaceOpenError.notDirectory(trimmed)
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return ExternalWorkspaceOpenRequest(folder: canonical)
    }

    public static func url(
        forFolder folderPath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let request = try request(folderPath: folderPath, fileManager: fileManager)
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.queryItems = [URLQueryItem(name: "folder", value: request.folder)]
        guard let url = components.url else { throw ExternalWorkspaceOpenError.invalidURL }
        return url
    }
}
