import Darwin
import Foundation

/// Reusable person-authored context. Saving it never dispatches terminal input;
/// a handoff receives only an explicit, separately editable snapshot.
public struct PinnedContextSnippet: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var text: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PinnedContextSnippetError: LocalizedError, Equatable {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        }
    }
}

/// Owner-only application-wide context library. Titles are unique without
/// regard to case so the picker cannot show two apparently identical entries.
public final class PinnedContextSnippetStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let snippets: [PinnedContextSnippet]
    }

    public static let maximumSnippets = 100
    public static let maximumTitleBytes = 200
    public static let maximumContentBytes = 40_000
    private static let maximumDocumentBytes = 8 * 1_024 * 1_024

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func snippets() throws -> [PinnedContextSnippet] {
        try lock.withLock {
            try loadLocked().sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
    }

    public func snippet(id: String) throws -> PinnedContextSnippet? {
        try lock.withLock { try loadLocked().first(where: { $0.id == id }) }
    }

    @discardableResult
    public func save(
        id: String? = nil,
        title: String,
        text: String,
        now: Date = Date()
    ) throws -> PinnedContextSnippet {
        try lock.withLock {
            let title = ContextPackText.normalize(title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = ContextPackText.normalize(text)
            try Self.validate(title: title, text: text)

            var current = try loadLocked()
            guard !current.contains(where: {
                $0.id != id && $0.title.caseInsensitiveCompare(title) == .orderedSame
            }) else {
                throw PinnedContextSnippetError.invalid("A pinned snippet named \"\(title)\" already exists.")
            }

            let saved: PinnedContextSnippet
            if let id {
                guard let index = current.firstIndex(where: { $0.id == id }) else {
                    throw PinnedContextSnippetError.invalid("That pinned snippet no longer exists.")
                }
                current[index].title = title
                current[index].text = text
                current[index].updatedAt = now
                saved = current[index]
            } else {
                guard current.count < Self.maximumSnippets else {
                    throw PinnedContextSnippetError.invalid(
                        "Parley keeps at most \(Self.maximumSnippets) pinned snippets. Delete one before creating another."
                    )
                }
                saved = PinnedContextSnippet(
                    title: title,
                    text: text,
                    createdAt: now,
                    updatedAt: now
                )
                current.append(saved)
            }
            try writeLocked(current)
            return saved
        }
    }

    public func delete(id: String) throws {
        try lock.withLock {
            var current = try loadLocked()
            guard current.contains(where: { $0.id == id }) else { return }
            current.removeAll { $0.id == id }
            try writeLocked(current)
        }
    }

    private func loadLocked() throws -> [PinnedContextSnippet] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        do {
            try validateExistingFile()
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumDocumentBytes,
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1,
                  document.snippets.count <= Self.maximumSnippets,
                  Set(document.snippets.map(\.id)).count == document.snippets.count else {
                throw PinnedContextSnippetError.unreadable("Parley's pinned context file is invalid or unsupported.")
            }
            var titles = Set<String>()
            for snippet in document.snippets {
                try Self.validate(title: snippet.title, text: snippet.text)
                guard titles.insert(snippet.title.lowercased()).inserted else {
                    throw PinnedContextSnippetError.unreadable("Parley's pinned context file contains duplicate titles.")
                }
            }
            return document.snippets
        } catch let error as PinnedContextSnippetError {
            throw error
        } catch {
            throw PinnedContextSnippetError.unreadable("Pinned context could not be read: \(error.localizedDescription)")
        }
    }

    private func writeLocked(_ snippets: [PinnedContextSnippet]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, snippets: snippets))
        guard data.count <= Self.maximumDocumentBytes else {
            throw PinnedContextSnippetError.invalid("Pinned context has reached Parley's 8 MB local safety bound.")
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func validate(title: String, text: String) throws {
        guard !title.isEmpty else {
            throw PinnedContextSnippetError.invalid("A pinned snippet needs a name.")
        }
        guard title.utf8.count <= maximumTitleBytes else {
            throw PinnedContextSnippetError.invalid("That snippet name is too long.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PinnedContextSnippetError.invalid("A pinned snippet needs content.")
        }
        guard text.utf8.count <= maximumContentBytes else {
            throw PinnedContextSnippetError.invalid(
                "This snippet is \(text.utf8.count) bytes. Reduce it to \(maximumContentBytes) bytes before saving."
            )
        }
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw PinnedContextSnippetError.unreadable("The pinned context file is not an owner-only regular file.")
        }
    }
}
