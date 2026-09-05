import Foundation

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
              canonical == root || canonical.hasPrefix(root == "/" ? "/" : root + "/") else {
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
        String(decoding: (try? JSONEncoder().encode(argv)) ?? Data(), as: UTF8.self)
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
        sourceFolder = URL(fileURLWithPath: source.cwd).resolvingSymlinksInPath().standardizedFileURL.path
        sourceName = source.displayName
        self.command = command
        createdAt = Date()
    }

    public func matches(source: WorkbenchPane, command: ReviewedCommand) -> Bool {
        source.kind.isAgent && source.isStarted && !source.isDead
            && source.id == sourcePaneID && source.launchGeneration == sourceGeneration
            && source.automationPolicy == sourcePolicy
            && source.workspaceID == sourceWorkspaceID
            && URL(fileURLWithPath: source.cwd).resolvingSymlinksInPath().standardizedFileURL.path == sourceFolder
            && self.command == command
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
