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
    public var conclusions: String
    public var rationale: String
    public var confidence: String
    public var openQuestions: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        workspaceID: String,
        workspaceName: String,
        goal: String,
        constraints: String,
        decisions: String,
        conclusions: String = "",
        rationale: String = "",
        confidence: String = "",
        openQuestions: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.goal = goal
        self.constraints = constraints
        self.decisions = decisions
        self.conclusions = conclusions
        self.rationale = rationale
        self.confidence = confidence
        self.openQuestions = openQuestions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case workspaceName
        case goal
        case constraints
        case decisions
        case conclusions
        case rationale
        case confidence
        case openQuestions
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        workspaceName = try container.decode(String.self, forKey: .workspaceName)
        goal = try container.decode(String.self, forKey: .goal)
        constraints = try container.decode(String.self, forKey: .constraints)
        decisions = try container.decode(String.self, forKey: .decisions)
        conclusions = try container.decodeIfPresent(String.self, forKey: .conclusions) ?? ""
        rationale = try container.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        confidence = try container.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        openQuestions = try container.decodeIfPresent(String.self, forKey: .openQuestions) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(workspaceName, forKey: .workspaceName)
        try container.encode(goal, forKey: .goal)
        try container.encode(constraints, forKey: .constraints)
        try container.encode(decisions, forKey: .decisions)
        try container.encode(conclusions, forKey: .conclusions)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(openQuestions, forKey: .openQuestions)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public var renderedText: String {
        var sections = [
            "Current goal:\n\(goal)",
            "Constraints:\n\(constraints.isEmpty ? "(none recorded)" : constraints)",
            "Important decisions:\n\(decisions.isEmpty ? "(none recorded)" : decisions)",
        ]
        for (label, value) in [
            ("Investigation conclusions", conclusions),
            ("Rationale", rationale),
            ("Confidence (person-authored)", confidence),
            ("Open questions", openQuestions),
        ] where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("\(label):\n\(value)")
        }
        return ContextPackText.normalize(sections.joined(separator: "\n\n"))
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

/// Owner-only durable workspace reference. A brief is keyed by Parley's
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
        conclusions: String = "",
        rationale: String = "",
        confidence: String = "",
        openQuestions: String = "",
        now: Date = Date()
    ) throws -> WorkspaceBrief {
        try lock.withLock {
            let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = ContextPackText.normalize(goal)
            let constraints = ContextPackText.normalize(constraints)
            let decisions = ContextPackText.normalize(decisions)
            let conclusions = ContextPackText.normalize(conclusions)
            let rationale = ContextPackText.normalize(rationale)
            let confidence = ContextPackText.normalize(confidence)
            let openQuestions = ContextPackText.normalize(openQuestions)
            guard !workspaceID.isEmpty, !workspaceName.isEmpty else {
                throw WorkspaceBriefError.invalid("A workspace brief needs a workspace id and name.")
            }
            guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceBriefError.invalid("A workspace brief needs a current goal.")
            }
            let contentBytes = [
                goal,
                constraints,
                decisions,
                conclusions,
                rationale,
                confidence,
                openQuestions,
            ].reduce(0) { $0 + $1.utf8.count }
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
                current[index].conclusions = conclusions
                current[index].rationale = rationale
                current[index].confidence = confidence
                current[index].openQuestions = openQuestions
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
                    conclusions: conclusions,
                    rationale: rationale,
                    confidence: confidence,
                    openQuestions: openQuestions,
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
