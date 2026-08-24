import Darwin
import Foundation

/// One person-authored local brief for one live workspace. It is reference
/// material only: storing or editing it never dispatches terminal input.
public struct WorkspaceBrief: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let workspaceID: String
    public var workspaceName: String
    public var goal: String
    public var constraints: String
    public var decisions: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        workspaceID: String,
        workspaceName: String,
        goal: String,
        constraints: String,
        decisions: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.goal = goal
        self.constraints = constraints
        self.decisions = decisions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var renderedText: String {
        ContextPackText.normalize("""
        Current goal:
        \(goal)

        Constraints:
        \(constraints.isEmpty ? "(none recorded)" : constraints)

        Important decisions:
        \(decisions.isEmpty ? "(none recorded)" : decisions)
        """)
    }
}

public enum WorkspaceBriefError: LocalizedError, Equatable {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        }
    }
}

/// Owner-only durable workspace reference. A brief is keyed by the tmux
/// workspace identity and never follows a deleted workspace into a new one.
public final class WorkspaceBriefStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let briefs: [WorkspaceBrief]
    }

    public static let maximumBriefs = 100
    public static let maximumContentBytes = 56_000
    private static let maximumDocumentBytes = 8 * 1_024 * 1_024

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func briefs() throws -> [WorkspaceBrief] {
        try lock.withLock {
            try loadLocked().sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
        }
    }

    public func brief(workspaceID: String) throws -> WorkspaceBrief? {
        try lock.withLock {
            try loadLocked().first(where: { $0.workspaceID == workspaceID })
        }
    }

    @discardableResult
    public func save(
        workspaceID: String,
        workspaceName: String,
        goal: String,
        constraints: String,
        decisions: String,
        now: Date = Date()
    ) throws -> WorkspaceBrief {
        try lock.withLock {
            let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = ContextPackText.normalize(goal)
            let constraints = ContextPackText.normalize(constraints)
            let decisions = ContextPackText.normalize(decisions)
            guard !workspaceID.isEmpty, !workspaceName.isEmpty else {
                throw WorkspaceBriefError.invalid("A workspace brief needs a workspace id and name.")
            }
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceBriefError.invalid("A workspace brief needs a current goal.")
            }
            let contentBytes = goal.utf8.count + constraints.utf8.count + decisions.utf8.count
            guard contentBytes <= Self.maximumContentBytes else {
                throw WorkspaceBriefError.invalid(
                    "This workspace brief is \(contentBytes) bytes. Reduce it to \(Self.maximumContentBytes) bytes before saving."
                )
            }

            var current = try loadLocked()
            let saved: WorkspaceBrief
            if let index = current.firstIndex(where: { $0.workspaceID == workspaceID }) {
                current[index].workspaceName = workspaceName
                current[index].goal = goal
                current[index].constraints = constraints
                current[index].decisions = decisions
                current[index].updatedAt = now
                saved = current[index]
            } else {
                guard current.count < Self.maximumBriefs else {
                    throw WorkspaceBriefError.invalid(
                        "Parley keeps at most \(Self.maximumBriefs) workspace briefs. Delete one before creating another."
                    )
                }
                saved = WorkspaceBrief(
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    goal: goal,
                    constraints: constraints,
                    decisions: decisions,
                    createdAt: now,
                    updatedAt: now
                )
                current.append(saved)
            }
            try writeLocked(current)
            return saved
        }
    }

    public func delete(workspaceID: String) throws {
        try lock.withLock {
            var current = try loadLocked()
            guard current.contains(where: { $0.workspaceID == workspaceID }) else { return }
            current.removeAll { $0.workspaceID == workspaceID }
            try writeLocked(current)
        }
    }

    private func loadLocked() throws -> [WorkspaceBrief] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        do {
            try validateExistingFile()
            let data = try Data(contentsOf: file)
            guard data.count <= Self.maximumDocumentBytes,
                  let document = try? JSONDecoder().decode(Document.self, from: data),
                  document.version == 1,
                  document.briefs.count <= Self.maximumBriefs,
                  Set(document.briefs.map(\.id)).count == document.briefs.count,
                  Set(document.briefs.map(\.workspaceID)).count == document.briefs.count else {
                throw WorkspaceBriefError.unreadable("Parley's workspace brief file is invalid or unsupported.")
            }
            return document.briefs
        } catch let error as WorkspaceBriefError {
            throw error
        } catch {
            throw WorkspaceBriefError.unreadable("Workspace briefs could not be read: \(error.localizedDescription)")
        }
    }

    private func writeLocked(_ briefs: [WorkspaceBrief]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, briefs: briefs))
        guard data.count <= Self.maximumDocumentBytes else {
            throw WorkspaceBriefError.invalid("Workspace briefs have reached Parley's 8 MB local safety bound.")
        }
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw WorkspaceBriefError.unreadable("The workspace brief file is not an owner-only regular file.")
        }
    }
}
