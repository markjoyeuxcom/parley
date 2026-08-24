import Darwin
import Foundation

public enum SupervisedWorkflowPhase: String, CaseIterable, Codable, Equatable, Sendable {
    case planning
    case reviewingPlan
    case awaitingImplementationApproval
    case implementing
    case verifying
    case awaitingCompletionApproval
    case completed
    case interrupted

    public var isTerminal: Bool { self == .completed || self == .interrupted }

    public var label: String {
        switch self {
        case .planning: "Planning"
        case .reviewingPlan: "Independent plan review"
        case .awaitingImplementationApproval: "Implementation approval"
        case .implementing: "Implementation"
        case .verifying: "Independent verification"
        case .awaitingCompletionApproval: "Completion approval"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        }
    }
}

public enum SupervisedWorkflowArtifactKind: String, Codable, Equatable, Sendable {
    case plan
    case planReview
    case implementation
    case verification

    public var label: String {
        switch self {
        case .plan: "Plan"
        case .planReview: "Independent plan review"
        case .implementation: "Implementation evidence"
        case .verification: "Independent verification"
        }
    }
}

public struct SupervisedWorkflowParticipant: Codable, Equatable, Sendable {
    public let paneID: String
    public let name: String
    public let kind: PaneKind
    public let workspaceID: String

    public init(paneID: String, name: String, kind: PaneKind, workspaceID: String) {
        self.paneID = paneID
        self.name = name
        self.kind = kind
        self.workspaceID = workspaceID
    }
}

public struct SupervisedWorkflowArtifact: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let kind: SupervisedWorkflowArtifactKind
    public let text: String
    public let capturedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: SupervisedWorkflowArtifactKind,
        text: String,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.capturedAt = capturedAt
    }
}

public struct SupervisedWorkflowTransition: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let from: SupervisedWorkflowPhase?
    public let to: SupervisedWorkflowPhase
    public let occurredAt: Date
    public let detail: String?
    public let origin: RelayTransitionOrigin

    public init(
        id: String = UUID().uuidString.lowercased(),
        from: SupervisedWorkflowPhase?,
        to: SupervisedWorkflowPhase,
        occurredAt: Date = Date(),
        detail: String? = nil,
        origin: RelayTransitionOrigin = .human
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.occurredAt = occurredAt
        self.detail = detail
        self.origin = origin
    }
}

public struct SupervisedWorkflowRun: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let workspaceID: String
    public let workspaceName: String
    public let lead: SupervisedWorkflowParticipant
    public let reviewer: SupervisedWorkflowParticipant
    public let verifier: SupervisedWorkflowParticipant
    public let planningPrompt: String
    public var phase: SupervisedWorkflowPhase
    public let createdAt: Date
    public var updatedAt: Date
    public var artifacts: [SupervisedWorkflowArtifact]
    public var transitions: [SupervisedWorkflowTransition]

    public var name: String { "Plan → Review → Implement → Verify" }

    public func artifact(_ kind: SupervisedWorkflowArtifactKind) -> SupervisedWorkflowArtifact? {
        artifacts.last { $0.kind == kind }
    }
}

public enum SupervisedWorkflowError: LocalizedError, Equatable {
    case invalid(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(detail), let .unreadable(detail): detail
        }
    }
}

/// Durable, owner-only state for one deliberately small workflow. This store
/// records human-authorized checkpoints; it never dispatches terminal input.
public final class SupervisedWorkflowStore: @unchecked Sendable {
    private struct Document: Codable {
        let version: Int
        let runs: [SupervisedWorkflowRun]
    }

    private let file: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(file: URL, fileManager: FileManager = .default) {
        self.file = file
        self.fileManager = fileManager
    }

    public func runs() throws -> [SupervisedWorkflowRun] {
        try lock.withLock {
            try loadLocked().sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
        }
    }

    public func start(
        workspaceID: String,
        workspaceName: String,
        lead: SupervisedWorkflowParticipant,
        reviewer: SupervisedWorkflowParticipant,
        verifier: SupervisedWorkflowParticipant,
        planningPrompt: String,
        now: Date = Date()
    ) throws -> SupervisedWorkflowRun {
        try lock.withLock {
            let workspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = ContextPackText.normalize(planningPrompt)
            guard !workspaceID.isEmpty, !workspaceName.isEmpty else {
                throw SupervisedWorkflowError.invalid("A supervised workflow needs a workspace id and name.")
            }
            try validate(participant: lead, role: "lead", workspaceID: workspaceID)
            try validate(participant: reviewer, role: "reviewer", workspaceID: workspaceID)
            try validate(participant: verifier, role: "verifier", workspaceID: workspaceID)
            guard reviewer.paneID != lead.paneID, reviewer.kind != lead.kind else {
                throw SupervisedWorkflowError.invalid("The plan reviewer must be a different pane and vendor from the lead.")
            }
            guard verifier.paneID != lead.paneID, verifier.kind != lead.kind else {
                throw SupervisedWorkflowError.invalid("The verifier must be a different pane and vendor from the lead.")
            }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  prompt.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes else {
                throw SupervisedWorkflowError.invalid(
                    "The planning instruction must be non-empty and no larger than \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes."
                )
            }
            var current = try loadLocked()
            guard !current.contains(where: { $0.workspaceID == workspaceID && !$0.phase.isTerminal }) else {
                throw SupervisedWorkflowError.invalid("This workspace already has an active supervised workflow.")
            }
            let transition = SupervisedWorkflowTransition(
                from: nil,
                to: .planning,
                occurredAt: now,
                detail: "The person reviewed and approved the planning instruction for dispatch."
            )
            let run = SupervisedWorkflowRun(
                id: UUID().uuidString.lowercased(),
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                lead: lead,
                reviewer: reviewer,
                verifier: verifier,
                planningPrompt: prompt,
                phase: .planning,
                createdAt: now,
                updatedAt: now,
                artifacts: [],
                transitions: [transition]
            )
            current.append(run)
            try writeLocked(current)
            return run
        }
    }

    public func advance(
        id: String,
        to next: SupervisedWorkflowPhase,
        artifact: SupervisedWorkflowArtifact?,
        detail: String? = nil,
        now: Date = Date()
    ) throws -> SupervisedWorkflowRun {
        try lock.withLock {
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == id }) else {
                throw SupervisedWorkflowError.invalid("Unknown supervised workflow.")
            }
            var run = current[index]
            guard !run.phase.isTerminal else {
                throw SupervisedWorkflowError.invalid("A terminal supervised workflow cannot move again.")
            }
            let expected = Self.allowedTransition[run.phase]
            guard expected == next else {
                throw SupervisedWorkflowError.invalid("A supervised workflow cannot move from \(run.phase.label) to \(next.label).")
            }
            let requiredArtifact = Self.requiredArtifact[next]
            guard artifact?.kind == requiredArtifact else {
                if let requiredArtifact {
                    throw SupervisedWorkflowError.invalid("Moving to \(next.label) requires an explicit \(requiredArtifact.label.lowercased()) artifact.")
                }
                throw SupervisedWorkflowError.invalid("Moving to \(next.label) does not accept a new artifact.")
            }
            if let artifact {
                let normalized = ContextPackText.normalize(artifact.text)
                guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      normalized.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes else {
                    throw SupervisedWorkflowError.invalid(
                        "Workflow artifacts must be non-empty and no larger than \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes."
                    )
                }
                run.artifacts.append(SupervisedWorkflowArtifact(
                    id: artifact.id,
                    kind: artifact.kind,
                    text: normalized,
                    capturedAt: artifact.capturedAt
                ))
            }
            let previous = run.phase
            run.phase = next
            run.updatedAt = now
            run.transitions.append(SupervisedWorkflowTransition(
                from: previous,
                to: next,
                occurredAt: now,
                detail: detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ))
            current[index] = run
            try writeLocked(current)
            return run
        }
    }

    public func interrupt(
        id: String,
        detail: String,
        now: Date = Date()
    ) throws -> SupervisedWorkflowRun {
        try lock.withLock {
            var current = try loadLocked()
            guard let index = current.firstIndex(where: { $0.id == id }) else {
                throw SupervisedWorkflowError.invalid("Unknown supervised workflow.")
            }
            var run = current[index]
            guard !run.phase.isTerminal else {
                throw SupervisedWorkflowError.invalid("A terminal supervised workflow cannot be interrupted.")
            }
            let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                throw SupervisedWorkflowError.invalid("An interrupted workflow needs a visible reason.")
            }
            let previous = run.phase
            run.phase = .interrupted
            run.updatedAt = now
            run.transitions.append(SupervisedWorkflowTransition(
                from: previous,
                to: .interrupted,
                occurredAt: now,
                detail: cleaned
            ))
            current[index] = run
            try writeLocked(current)
            return run
        }
    }

    private static let allowedTransition: [SupervisedWorkflowPhase: SupervisedWorkflowPhase] = [
        .planning: .reviewingPlan,
        .reviewingPlan: .awaitingImplementationApproval,
        .awaitingImplementationApproval: .implementing,
        .implementing: .verifying,
        .verifying: .awaitingCompletionApproval,
        .awaitingCompletionApproval: .completed,
    ]

    private static let requiredArtifact: [SupervisedWorkflowPhase: SupervisedWorkflowArtifactKind] = [
        .reviewingPlan: .plan,
        .awaitingImplementationApproval: .planReview,
        .verifying: .implementation,
        .awaitingCompletionApproval: .verification,
    ]

    private func validate(
        participant: SupervisedWorkflowParticipant,
        role: String,
        workspaceID: String
    ) throws {
        guard participant.kind.isAgent,
              !participant.paneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !participant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              participant.workspaceID == workspaceID else {
            throw SupervisedWorkflowError.invalid("The supervised workflow \(role) must be an agent pane in the selected workspace.")
        }
    }

    private func loadLocked() throws -> [SupervisedWorkflowRun] {
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        do {
            try validateExistingFile()
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else {
                throw SupervisedWorkflowError.unreadable("Unsupported supervised workflow version \(document.version).")
            }
            return document.runs
        } catch let error as SupervisedWorkflowError {
            throw error
        } catch {
            throw SupervisedWorkflowError.unreadable("Supervised workflows could not be read: \(error.localizedDescription)")
        }
    }

    private func writeLocked(_ runs: [SupervisedWorkflowRun]) throws {
        let directory = file.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if fileManager.fileExists(atPath: file.path) { try validateExistingFile() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(version: 1, runs: runs)).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateExistingFile() throws {
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw SupervisedWorkflowError.unreadable("The supervised workflow file is not an owner-only regular file.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
