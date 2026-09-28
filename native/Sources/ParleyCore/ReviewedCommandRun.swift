import Foundation

/// One requested command run, as a record.
///
/// Declared here with the rest of its family rather than beside the
/// coordinator that manages it: a run is persisted in the handoff journal and
/// read back by callers that have no business knowing how a worker ticket is
/// signed. The coordinator keeps the CryptoKit digest work.

/// Who proposed a run. Trusted code sets this: the transport route always
/// records an agent pane, and only the native app can record the person.
public enum ReviewedCommandRunOrigin: String, Codable, Equatable, Sendable {
    /// Requested by an authenticated agent pane through `parley request-run`.
    case agentPane
    /// Proposed by the person in the native app, for example Integrate… on a
    /// worktree. No pane requested it, so no pane can recover its result, and
    /// it always waits for the person's approval in the editable preview.
    case person
}

public struct ReviewedCommandRun: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let idempotencyKey: String
    public let requestedCommand: ReviewedCommand
    public var revision: String
    /// The requesting agent pane; nil for a run the person proposed.
    public let source: WorkbenchPane?
    public let sourceFolder: String
    public let origin: ReviewedCommandRunOrigin
    /// Where the run's Shell pane opens: the requesting pane's workspace, or
    /// the workspace the person was in when they proposed the run.
    public let workspaceID: String
    public let workspaceName: String?
    public var command: ReviewedCommand
    public var state: ReviewedCommandRunState
    public let createdAt: Date
    public var updatedAt: Date
    /// Reserved by Parley before approval, created only after approval.
    public let shellPaneID: String
    public var autoApprovalGrantID: String?
    /// Approved by the person's Settings switch rather than by a preview or
    /// an exact-command grant. Kept for the life of the record so history
    /// still says how the run was authorized after its detail changes.
    public var approvedAutomatically = false
    public var result: ReviewedCommandRunResult?
    public var detail: String?
    public var cancellationRequested = false
    public var cancellationRequestedAt: Date?
    public var launchedAt: Date?
    public var workerStillRunning = false
    public var resultSaved = false

    public init(id: String, idempotencyKey: String, requestedCommand: ReviewedCommand, revision: String, source: WorkbenchPane?,
                sourceFolder: String, command: ReviewedCommand, state: ReviewedCommandRunState, createdAt: Date, updatedAt: Date,
                shellPaneID: String, autoApprovalGrantID: String?, approvedAutomatically: Bool, result: ReviewedCommandRunResult?, detail: String?,
                origin: ReviewedCommandRunOrigin = .agentPane, workspaceID: String? = nil, workspaceName: String? = nil) {
        self.id = id
        self.idempotencyKey = idempotencyKey
        self.requestedCommand = requestedCommand
        self.revision = revision
        self.source = source
        self.sourceFolder = sourceFolder
        self.origin = origin
        self.workspaceID = workspaceID ?? source?.workspaceID ?? ""
        self.workspaceName = workspaceName ?? source?.workspaceName
        self.command = command
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.shellPaneID = shellPaneID
        self.autoApprovalGrantID = autoApprovalGrantID
        self.approvedAutomatically = approvedAutomatically
        self.result = result
        self.detail = detail
    }

    private enum CodingKeys: String, CodingKey {
        case id, idempotencyKey, requestedCommand, revision, source, sourceFolder, command, state, createdAt, updatedAt
        case shellPaneID, autoApprovalGrantID, approvedAutomatically, result, detail, cancellationRequested, cancellationRequestedAt
        case launchedAt, workerStillRunning, resultSaved, origin, workspaceID, workspaceName
    }

    /// Who asked, as Status Center and the review sheet name it.
    public var requesterName: String { source?.displayName ?? "You" }

    /// Records written before `approvedAutomatically` existed carry no such
    /// key and must still load (the coordination core opens the handoff
    /// journal at startup); a present but non-boolean value is still refused.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
        requestedCommand = try container.decode(ReviewedCommand.self, forKey: .requestedCommand)
        revision = try container.decode(String.self, forKey: .revision)
        // Records written before person-proposed runs existed always carry a
        // source pane and no origin; they decode as agent-pane runs.
        source = try container.decodeIfPresent(WorkbenchPane.self, forKey: .source)
        sourceFolder = try container.decode(String.self, forKey: .sourceFolder)
        origin = try container.decodeIfPresent(ReviewedCommandRunOrigin.self, forKey: .origin) ?? .agentPane
        guard origin == .person || source != nil else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: container, debugDescription: "An agent-pane run must name its requesting pane.")
        }
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID) ?? source?.workspaceID ?? ""
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName) ?? source?.workspaceName
        command = try container.decode(ReviewedCommand.self, forKey: .command)
        state = try container.decode(ReviewedCommandRunState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        shellPaneID = try container.decode(String.self, forKey: .shellPaneID)
        autoApprovalGrantID = try container.decodeIfPresent(String.self, forKey: .autoApprovalGrantID)
        approvedAutomatically = try container.decodeIfPresent(Bool.self, forKey: .approvedAutomatically) ?? false
        result = try container.decodeIfPresent(ReviewedCommandRunResult.self, forKey: .result)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        cancellationRequested = try container.decodeIfPresent(Bool.self, forKey: .cancellationRequested) ?? false
        cancellationRequestedAt = try container.decodeIfPresent(Date.self, forKey: .cancellationRequestedAt)
        launchedAt = try container.decodeIfPresent(Date.self, forKey: .launchedAt)
        workerStillRunning = try container.decodeIfPresent(Bool.self, forKey: .workerStillRunning) ?? false
        resultSaved = try container.decodeIfPresent(Bool.self, forKey: .resultSaved) ?? false
    }
}

public enum ReviewedCommandRunError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): message } }
}

/// Exact argv, never a command string to be evaluated by a shell.
public struct ReviewedCommand: Codable, Equatable, Hashable, Sendable {
    public let argv: [String]
    public let folder: String

    public init(argv: [String], folder: String, sourceFolder: String) throws {
        guard !argv.isEmpty, argv.count <= 128,
              argv.reduce(0, { $0 + $1.utf8.count + 1 }) <= 16_000,
              argv.allSatisfy({ !$0.contains("\0") }),
              let executable = argv.first, executable.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable) else {
            throw ReviewedCommandRunError.invalid("Supply an absolute executable and at most 128 literal arguments (16 KB total), without NUL bytes.")
        }
        guard try JSONEncoder().encode(argv).count <= 16_000 else {
            throw ReviewedCommandRunError.invalid("The exact argument preview must fit in 16 KB, including escaped characters.")
        }
        guard folder.hasPrefix("/"), sourceFolder.hasPrefix("/"),
              !folder.contains("\0"), !sourceFolder.contains("\0"),
              folder.utf8.count <= 4_096 else {
            throw ReviewedCommandRunError.invalid("Choose an absolute working folder inside the requesting pane's folder.")
        }
        let root = URL(fileURLWithPath: sourceFolder).resolvingSymlinksInPath().standardizedFileURL.path
        let canonical = URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &directory), directory.boolValue,
              WorkspaceFolderIdentity.contains(canonical, within: root) else {
            throw ReviewedCommandRunError.invalid("The working folder must remain inside the requesting pane's folder, including after resolving symlinks.")
        }
        self.argv = argv
        self.folder = canonical
    }

    /// The POSIX shim writes one NUL-terminated field per argv element. Splitting
    /// words or joining with spaces would lose empty arguments and quote intent.
    public static func decodeArguments(_ body: String) throws -> [String] {
        guard body.utf8.count <= 16_000, body.hasSuffix("\0") else {
            throw ReviewedCommandRunError.invalid("Invalid bounded argv payload.")
        }
        let values = body.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        guard !values.isEmpty, values.count <= 128, values.first?.hasPrefix("/") == true else {
            throw ReviewedCommandRunError.invalid("Supply an absolute executable after --.")
        }
        return values
    }

    public var display: String {
        // JSON array syntax makes argument boundaries, empty values and
        // control characters explicit in previews and durable handoffs.
        // Slashes stay as written: `\/` only made a path harder to check.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(argv)) ?? Data(), as: UTF8.self)
    }

    /// Reads the edited preview back as argv. A typographic quote where JSON
    /// needs a plain one (macOS smart quotes turn `"` into `”`) is named in
    /// the error rather than reported as a bare format failure. It is never
    /// rewritten silently, because an argument may contain one legitimately.
    public static func parseDisplay(_ text: String) throws -> [String] {
        guard let data = text.data(using: .utf8), data.count <= 100_000 else {
            throw ReviewedCommandRunError.invalid("The argument preview is too large.")
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            // Blamed only when straightening them is what makes the array
            // parse; a curly quote inside an argument is data, and an
            // unrelated error is reported as itself.
            let typographic: Set<Character> = ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{FF02}"]
            if let found = text.first(where: { typographic.contains($0) }) {
                let straightened = String(text.map { typographic.contains($0) ? "\"" : $0 })
                if let data = straightened.data(using: .utf8), (try? JSONDecoder().decode([String].self, from: data)) != nil {
                    throw ReviewedCommandRunError.invalid("The arguments contain a typographic quote (\(found)). JSON needs plain straight quotes (\") around each argument; replace it and approve again.")
                }
            }
            throw ReviewedCommandRunError.invalid("The arguments are not a JSON array of strings: \(error.localizedDescription)")
        }
    }
}

public struct ReviewedCommandGrant: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourcePolicy: WorkspaceAutomationPolicy
    public let sourceGeneration: Int
    public let sourceWorkspaceID: String
    public let sourceFolder: String
    public let sourceName: String
    public let command: ReviewedCommand
    public let createdAt: Date

    public init(source: WorkbenchPane, command: ReviewedCommand) {
        id = UUID().uuidString.lowercased()
        sourcePaneID = source.id
        sourcePolicy = source.automationPolicy
        sourceGeneration = source.launchGeneration
        sourceWorkspaceID = source.workspaceID
        sourceFolder = URL(fileURLWithPath: source.launchWorkingDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        sourceName = source.displayName
        self.command = command
        createdAt = Date()
    }

    public func matches(source: WorkbenchPane, command: ReviewedCommand) -> Bool {
        source.kind.isAgent && source.isStarted && !source.isDead
            && source.id == sourcePaneID && source.launchGeneration == sourceGeneration
            && source.automationPolicy == sourcePolicy
            && source.workspaceID == sourceWorkspaceID
            && URL(fileURLWithPath: source.launchWorkingDirectory).resolvingSymlinksInPath().standardizedFileURL.path == sourceFolder
            && self.command == command
    }
}

/// The person's optional Settings choice to end a run's pane once the run
/// has nothing left to show. `isClean` is the result rule the worker applies
/// before deciding whether to hand the pane to an interactive shell at all:
/// a clean run's worker exits instead. `shouldClose` is the app-side view of
/// the same run once its clean result is saved and the worker's lease is
/// released; the pane itself is removed only after its process has ended.
/// Every other outcome keeps its pane, with an ordinary shell, for inspection.
public enum ReviewedCommandRunPaneClosePolicy {
    public static let disclosure = "While this is on, a run that starts afterwards and finishes cleanly (exit status 0, no signal, not cancelled, output within the capture limit) ends its pane's process instead of handing the pane to an interactive shell; once its result is saved and the process has ended, Parley removes that pane and returns focus to the pane you were using. The choice is fixed for each run when it starts, so a run already given a shell is never affected. Parley never closes a pane that is running an interactive shell, and a pane you restarted is yours. A failed, cancelled or truncated run keeps its pane, with an ordinary shell, so you can inspect it. The captured result stays available under Review runs and trust and in Status Center. Like automatic approval, this choice applies only to this app session and resets to off when Parley quits."

    /// The result-only part of the rule, applied by the worker before it
    /// decides whether to hand the pane to an interactive shell.
    public static func isClean(_ result: ReviewedCommandRunResult) -> Bool {
        result.exitStatus == 0 && result.terminationSignal == nil && !result.cancelled && !result.outputTruncated
    }

    public static func shouldClose(state: ReviewedCommandRunState, result: ReviewedCommandRunResult?, resultSaved: Bool, workerStillRunning: Bool) -> Bool {
        guard state == .completed, let result, resultSaved, !workerStillRunning else { return false }
        return isClean(result)
    }

    public static func shouldClose(_ run: ReviewedCommandRun) -> Bool {
        shouldClose(state: run.state, result: run.result, resultSaved: run.resultSaved, workerStillRunning: run.workerStillRunning)
    }
}

public enum ReviewedCommandRunState: String, Codable, Sendable {
    case pending, approved, running, completed, rejected, cancelled, interrupted, failed
    public var isTerminal: Bool { ![Self.pending, .approved, .running].contains(self) }
}

public struct ReviewedCommandRunResult: Codable, Equatable, Sendable {
    public private(set) var approvedCommand: ReviewedCommand? = nil
    public let exitStatus: Int32?
    public let terminationSignal: Int32?
    public let stdout: String
    public let stderr: String
    public let outputTruncated: Bool
    public let cancelled: Bool
    public let detail: String?
    public let provenance: String
    public let outsideAgentBoundary: Bool

    public init(exitStatus: Int32?, terminationSignal: Int32? = nil, stdout: Data, stderr: Data,
                outputTruncated: Bool = false, cancelled: Bool = false, detail: String? = nil) {
        self.exitStatus = exitStatus
        self.terminationSignal = terminationSignal
        // Reserve room for command metadata inside existing 90 KB rendered
        // and 200 KB transport limits. Strip terminal controls before capture.
        let out = Self.sanitize(String(decoding: stdout, as: UTF8.self))
        let err = Self.sanitize(String(decoding: stderr, as: UTF8.self))
        self.stdout = Self.prefix(out, bytes: 30_000)
        self.stderr = Self.prefix(err, bytes: 30_000)
        self.outputTruncated = outputTruncated || out.utf8.count > 30_000 || err.utf8.count > 30_000
        self.cancelled = cancelled
        self.detail = detail.map { Self.prefix($0, bytes: 2_000) }
        provenance = "capturedCommandResult"
        outsideAgentBoundary = true
    }

    public func attributed(to command: ReviewedCommand) -> Self {
        var result = self
        result.approvedCommand = command
        return result
    }

    public var text: String {
        """
        CAPTURED COMMAND RESULT — ran as the person outside the agent boundary
        \(approvedCommand.map { "Approved argv: \($0.display)\nApproved folder: \($0.folder)" } ?? "")
        Exit status: \(exitStatus.map(String.init) ?? "unavailable")
        Termination signal: \(terminationSignal.map(String.init) ?? "none")
        Cancelled: \(cancelled)
        Output truncated: \(outputTruncated)
        \(detail ?? "")

        Standard output:
        \(stdout)

        Standard error:
        \(stderr)
        """
    }

    private static func sanitize(_ text: String) -> String {
        enum State { case text, escape, csi, osc, controlString, oscEscape, stringEscape }
        var state = State.text
        var output = String.UnicodeScalarView()
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").unicodeScalars {
            let code = scalar.value
            switch state {
            case .text:
                if code == 0x1b { state = .escape }
                else if code == 0x9b { state = .csi }
                else if code == 0x9d { state = .osc }
                else if scalar == "\n" || scalar == "\t" || (code >= 0x20 && code != 0x7f && !(0x80...0x9f).contains(code)) {
                    output.append(scalar)
                }
            case .escape:
                if scalar == "[" { state = .csi }
                else if scalar == "]" { state = .osc }
                else if ["P", "^", "_"].contains(scalar) { state = .controlString }
                else if !(0x20...0x2f).contains(code) { state = .text }
            case .csi:
                if (0x40...0x7e).contains(code) { state = .text }
            case .osc:
                if code == 7 || code == 0x9c { state = .text }
                else if code == 0x1b { state = .oscEscape }
            case .controlString:
                if code == 0x9c { state = .text }
                else if code == 0x1b { state = .stringEscape }
            case .oscEscape:
                state = scalar == "\\" ? .text : .osc
            case .stringEscape:
                state = scalar == "\\" ? .text : .controlString
            }
        }
        return String(output)
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        var data = Data(text.utf8.prefix(bytes))
        while String(data: data, encoding: .utf8) == nil && !data.isEmpty { data.removeLast() }
        return String(decoding: data, as: UTF8.self)
    }
}


/// Session-only presentation bookkeeping; it never approves or starts a run.
public struct ReviewedCommandRunAttention: Sendable {
    public struct Decision: Equatable, Sendable {
        public let presentRunID: String?
        public let requestDockAttention: Bool
    }

    private var observedIDs: Set<String> = []
    private var presentedIDs: Set<String> = []

    public init() {}

    public mutating func didPresent(runID: String) {
        presentedIDs.insert(runID)
        observedIDs.insert(runID)
    }

    /// Explicit Done/Escape defers all currently pending prompts. Approving or
    /// rejecting one request never calls this, so unseen requests still open.
    public mutating func didDismiss(pendingIDs: [String]) {
        presentedIDs.formUnion(pendingIDs)
        observedIDs.formUnion(pendingIDs)
    }

    public mutating func update(pendingIDs: [String], reviewPresented: Bool,
                                canPresent: Bool, applicationActive: Bool) -> Decision {
        let pending = Set(pendingIDs)
        let newlyObserved = pending.subtracting(observedIDs)
        observedIDs = pending
        presentedIDs.formIntersection(pending)
        // Preserve the open selection and edits. A different pending request
        // remains unseen until selected or automatically opened after a decision.
        if !reviewPresented, applicationActive, canPresent,
           let id = pendingIDs.first(where: { !presentedIDs.contains($0) }) {
            didPresent(runID: id)
            return Decision(presentRunID: id, requestDockAttention: false)
        }
        return Decision(presentRunID: nil,
                        requestDockAttention: !applicationActive && !newlyObserved.isEmpty)
    }
}
