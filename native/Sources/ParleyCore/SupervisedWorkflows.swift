import Darwin
import Foundation

public enum SmartOrchestrationMode: String, CaseIterable, Codable, Equatable, Sendable {
    case supervised
    case automatic

    public var label: String {
        switch self {
        case .supervised: "Supervised"
        case .automatic: "Auto"
        }
    }

    public var detail: String {
        switch self {
        case .supervised:
            "Pause at every handoff so the person can inspect and edit the exact payload."
        case .automatic:
            "Advance correlated Plan, Review, Implement and Verify handoffs automatically, then stop for the person's final decision."
        }
    }
}

public enum SmartOrchestrationPolicy {
    public static func allowsAutomaticTransition(
        from: SupervisedWorkflowPhase,
        to: SupervisedWorkflowPhase
    ) -> Bool {
        switch (from, to) {
        case (.planning, .reviewingPlan),
             (.reviewingPlan, .awaitingImplementationApproval),
             (.awaitingImplementationApproval, .implementing),
             (.implementing, .verifying),
             (.verifying, .awaitingCompletionApproval):
            true
        default:
            false
        }
    }
}

/// Builds the bounded, stage-specific prompts used by Auto orchestration.
/// Completion still belongs to the person; these prompts never ask a model to
/// approve its own result or infer another pane's hidden state.
public struct SmartOrchestrationPromptBuilder: Sendable {
    public let task: String

    public init(task: String) {
        self.task = ContextPackText.normalize(task)
    }

    public func planning() throws -> String {
        try bounded("""
        The person using Parley started a smart orchestration run for this task:

        --- TASK ---

        \(task)

        Produce a concrete implementation plan. Inspect the repository as permitted and identify scope, risks and proportionate verification, but do not edit files or begin implementation. Return only the proposed plan with useful evidence.
        """)
    }

    public func planReview(plan: String) throws -> String {
        try bounded("""
        Independently review the proposed plan below for correctness, missing risks, unnecessary scope and verification gaps. Do not implement anything and do not modify files. Return concrete objections, corrections and any evidence needed by the implementer.

        --- TASK ---

        \(task)

        --- PROPOSED PLAN ---

        \(plan)
        """)
    }

    public func implementation(plan: String, review: String) throws -> String {
        try bounded("""
        The person using Parley authorized this Auto workflow to proceed through implementation. Implement the sound plan while accounting for confirmed review findings. Do not treat reviewer claims as facts without checking them. Preserve every vendor permission prompt and stop rather than bypassing a refusal. Run proportionate verification and return a concise implementation report with exact command outcomes.

        --- TASK ---

        \(task)

        --- PROPOSED PLAN ---

        \(plan)

        --- INDEPENDENT PLAN REVIEW ---

        \(review)
        """)
    }

    public func verification(implementationEvidence: String) throws -> String {
        try bounded("""
        Independently verify the implementation evidence below. Inspect the repository as permitted, run proportionate checks and report concrete defects or a clean result with exact command outcomes. Do not modify files. Your report is evidence for the person using Parley; it does not automatically declare the workflow successful.

        --- TASK ---

        \(task)

        --- IMPLEMENTATION EVIDENCE ---

        \(implementationEvidence)
        """)
    }

    private func bounded(_ text: String) throws -> String {
        let normalized = ContextPackText.normalize(text)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= ContextPackBuilder.defaultMaximumRenderedBytes else {
            throw SupervisedWorkflowError.invalid(
                "A smart orchestration stage must be non-empty and no larger than \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes."
            )
        }
        return normalized
    }
}

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
    public let mode: SmartOrchestrationMode
    public var phase: SupervisedWorkflowPhase
    public let createdAt: Date
    public var updatedAt: Date
    public var artifacts: [SupervisedWorkflowArtifact]
    public var transitions: [SupervisedWorkflowTransition]

    public var name: String { "Plan → Review → Implement → Verify" }

    public func artifact(_ kind: SupervisedWorkflowArtifactKind) -> SupervisedWorkflowArtifact? {
        artifacts.last { $0.kind == kind }
    }

    public init(
        id: String,
        workspaceID: String,
        workspaceName: String,
        lead: SupervisedWorkflowParticipant,
        reviewer: SupervisedWorkflowParticipant,
        verifier: SupervisedWorkflowParticipant,
        planningPrompt: String,
        mode: SmartOrchestrationMode = .supervised,
        phase: SupervisedWorkflowPhase,
        createdAt: Date,
        updatedAt: Date,
        artifacts: [SupervisedWorkflowArtifact],
        transitions: [SupervisedWorkflowTransition]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.lead = lead
        self.reviewer = reviewer
        self.verifier = verifier
        self.planningPrompt = planningPrompt
        self.mode = mode
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.artifacts = artifacts
        self.transitions = transitions
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case workspaceID
        case workspaceName
        case lead
        case reviewer
        case verifier
        case planningPrompt
        case mode
        case phase
        case createdAt
        case updatedAt
        case artifacts
        case transitions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        workspaceID = try values.decode(String.self, forKey: .workspaceID)
        workspaceName = try values.decode(String.self, forKey: .workspaceName)
        lead = try values.decode(SupervisedWorkflowParticipant.self, forKey: .lead)
        reviewer = try values.decode(SupervisedWorkflowParticipant.self, forKey: .reviewer)
        verifier = try values.decode(SupervisedWorkflowParticipant.self, forKey: .verifier)
        planningPrompt = try values.decode(String.self, forKey: .planningPrompt)
        mode = try values.decodeIfPresent(SmartOrchestrationMode.self, forKey: .mode) ?? .supervised
        phase = try values.decode(SupervisedWorkflowPhase.self, forKey: .phase)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        artifacts = try values.decode([SupervisedWorkflowArtifact].self, forKey: .artifacts)
        transitions = try values.decode([SupervisedWorkflowTransition].self, forKey: .transitions)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(workspaceID, forKey: .workspaceID)
        try values.encode(workspaceName, forKey: .workspaceName)
        try values.encode(lead, forKey: .lead)
        try values.encode(reviewer, forKey: .reviewer)
        try values.encode(verifier, forKey: .verifier)
        try values.encode(planningPrompt, forKey: .planningPrompt)
        try values.encode(mode, forKey: .mode)
        try values.encode(phase, forKey: .phase)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(artifacts, forKey: .artifacts)
        try values.encode(transitions, forKey: .transitions)
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
/// records the initial human authorization plus explicitly attributed human or
/// bounded Auto transitions; it never dispatches terminal input itself.
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
        mode: SmartOrchestrationMode = .supervised,
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
            guard reviewer.paneID != lead.paneID else {
                throw SupervisedWorkflowError.invalid("The plan reviewer must be a different pane from the lead.")
            }
            guard verifier.paneID != lead.paneID else {
                throw SupervisedWorkflowError.invalid("The verifier must be a different pane from the lead.")
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
                mode: mode,
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
        origin: RelayTransitionOrigin = .human,
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
            if origin == .automation {
                guard run.mode == .automatic else {
                    throw SupervisedWorkflowError.invalid("A supervised workflow cannot advance through automation.")
                }
                guard SmartOrchestrationPolicy.allowsAutomaticTransition(from: run.phase, to: next) else {
                    throw SupervisedWorkflowError.invalid(
                        "Auto mode stops for the person at \(run.phase.label); it cannot advance to \(next.label)."
                    )
                }
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
                detail: detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                origin: origin
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
