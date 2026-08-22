import Foundation
import Security

public enum RelayDraft {
    /// Relaying is composition, not transcript trimming. A real selection is
    /// useful context; without one the person starts with an empty editor and
    /// can explicitly insert the visible pane if they want it.
    public static func initialText(selection: String?) -> String {
        guard let selection else { return "" }
        return RelayText.clean(selection)
    }
}

public enum RelayCredentialError: LocalizedError {
    case randomGenerationFailed
    case invalidCredentialFile

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Parley could not create a relay credential."
        case .invalidCredentialFile:
            "Parley's relay credential file is invalid."
        }
    }
}

/// One durable credential per persistent tmux pane. The credential is the
/// sender identity; a caller never gets to claim which pane it came from.
public final class RelayCredentials: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var byPane: [String: String]

    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                throw RelayCredentialError.invalidCredentialFile
            }
            byPane = decoded
        } else {
            byPane = [:]
        }
    }

    public func token(for paneID: String) throws -> String {
        try lock.withLock {
            if let existing = byPane[paneID] { return existing }
            var bytes = [UInt8](repeating: 0, count: 24)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RelayCredentialError.randomGenerationFailed
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            byPane[paneID] = token
            try persistLocked()
            return token
        }
    }

    public func paneID(for presented: String) -> String? {
        lock.withLock {
            var match: String?
            for (paneID, token) in byPane where constantTimeEqual(token, presented) {
                match = paneID
            }
            return match
        }
    }

    public func forget(_ paneID: String) throws {
        try lock.withLock {
            guard byPane.removeValue(forKey: paneID) != nil else { return }
            try persistLocked()
        }
    }

    public func retain(paneIDs: Set<String>) throws {
        try lock.withLock {
            let retained = byPane.filter { paneIDs.contains($0.key) }
            guard retained.count != byPane.count else { return }
            byPane = retained
            try persistLocked()
        }
    }

    private func persistLocked() throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(byPane)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func constantTimeEqual(_ known: String, _ presented: String) -> Bool {
        let left = Array(known.utf8)
        let right = Array(presented.utf8)
        var difference = left.count ^ right.count
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            difference |= Int(lhs ^ rhs)
        }
        return difference == 0
    }
}

public struct RelayRuntime: Sendable {
    public let infoFile: URL
    public let shimDirectory: URL
    public let credentials: RelayCredentials

    public init(infoFile: URL, shimDirectory: URL, credentials: RelayCredentials) {
        self.infoFile = infoFile
        self.shimDirectory = shimDirectory
        self.credentials = credentials
    }
}

public struct RelayResponseBody: Codable, Equatable, Sendable {
    public let ok: Bool
    public let delivered: String?
    public let submitted: Bool?
    public let note: String?
    public let error: String?
}

public struct RelayResponse: Equatable, Sendable {
    public let status: Int
    public let body: RelayResponseBody
}

public struct RelayTextResponse: Equatable, Sendable {
    public let status: Int
    public let text: String

    public init(status: Int, text: String) {
        self.status = status
        self.text = text
    }
}

public enum RelayConsultationState: String, Codable, Equatable, Sendable {
    case awaitingAnswer
}

/// A single correlated question from one live agent pane to another. It is
/// intentionally memory-only: the waiting shell command and its HTTP
/// connection cannot survive the native app stopping, so persisting half of
/// the exchange would create a route that can never complete.
public struct RelayConsultation: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourcePaneID: String
    public let sourceName: String
    public let targetPaneID: String
    public let targetName: String
    public let question: String
    public let state: RelayConsultationState
    public let createdAt: Date
}

public final class RelayBroker: @unchecked Sendable {
    public typealias Panes = () throws -> [TmuxPane]
    public typealias Paste = (_ paneID: String, _ text: String) throws -> Void
    public typealias Submit = (_ paneID: String, _ text: String) throws -> Void

    private let credentials: RelayCredentials
    private let panes: Panes
    private let paste: Paste
    private let submit: Submit
    private let consultationTimeout: TimeInterval
    private let consultationCondition = NSCondition()
    private var consultationRecords: [String: ConsultationRecord] = [:]

    public init(
        credentials: RelayCredentials,
        panes: @escaping Panes,
        paste: @escaping Paste,
        submit: @escaping Submit,
        consultationTimeout: TimeInterval = 30 * 60
    ) {
        self.credentials = credentials
        self.panes = panes
        self.paste = paste
        self.submit = submit
        self.consultationTimeout = consultationTimeout
    }

    public func handle(token: String, target requestedTarget: String, text: String) -> RelayResponse {
        deliver(token: token, target: requestedTarget, text: text, submitted: true, writer: submit)
    }

    public func handlePaste(token: String, target requestedTarget: String, text: String) -> RelayResponse {
        deliver(token: token, target: requestedTarget, text: text, submitted: false, writer: paste)
    }

    private func deliver(
        token: String,
        target requestedTarget: String,
        text: String,
        submitted: Bool,
        writer: (_ paneID: String, _ text: String) throws -> Void
    ) -> RelayResponse {
        do {
            let cleaned = RelayText.clean(text)
            guard !cleaned.isEmpty else { return failure(400, "nothing to relay") }
            guard cleaned.count <= RelayText.maximumCharacters else {
                return failure(400, "text too long")
            }
            let (sender, target) = try route(token: token, requestedTarget: requestedTarget)

            try writer(target.id, "\(sender.displayName) said:\n\n\(cleaned)")
            return RelayResponse(
                status: 200,
                body: RelayResponseBody(
                    ok: true,
                    delivered: target.displayName,
                    submitted: submitted,
                    note: submitted
                        ? "Submitted to \(target.displayName)."
                        : "Pasted into the prompt and NOT sent. The person there presses Enter.",
                    error: nil
                )
            )
        } catch let error as BrokerFailure {
            return failure(error.status, error.message)
        } catch {
            return failure(409, error.localizedDescription)
        }
    }

    /// Submits one attributed question, then waits until its exact target
    /// returns an answer. Unlike relay, Ask also owns the response route.
    public func handleAsk(token: String, target requestedTarget: String, text: String) -> RelayTextResponse {
        let sender: TmuxPane
        let target: TmuxPane
        do {
            (sender, target) = try route(token: token, requestedTarget: requestedTarget)
        } catch let error as BrokerFailure {
            return RelayTextResponse(status: error.status, text: error.message)
        } catch {
            return RelayTextResponse(status: 409, text: error.localizedDescription)
        }

        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to ask") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "question too long")
        }

        let consultation = RelayConsultation(
            id: UUID().uuidString.lowercased(),
            sourcePaneID: sender.id,
            sourceName: sender.displayName,
            targetPaneID: target.id,
            targetName: target.displayName,
            question: cleaned,
            state: .awaitingAnswer,
            createdAt: Date()
        )

        consultationCondition.lock()
        if consultationRecords.values.contains(where: {
            $0.consultation.targetPaneID == target.id && $0.completion == nil
        }) {
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "\(target.displayName) already has a consultation awaiting an answer."
            )
        }
        consultationRecords[consultation.id] = ConsultationRecord(consultation: consultation, completion: nil)
        consultationCondition.broadcast()
        consultationCondition.unlock()

        do {
            try submit(target.id, consultationPrompt(for: consultation))
        } catch {
            consultationCondition.lock()
            consultationRecords.removeValue(forKey: consultation.id)
            consultationCondition.broadcast()
            consultationCondition.unlock()
            return RelayTextResponse(
                status: 409,
                text: "Parley could not submit the question: \(error.localizedDescription)"
            )
        }

        consultationCondition.lock()
        let deadline = Date().addingTimeInterval(consultationTimeout)
        while consultationRecords[consultation.id]?.completion == nil {
            if !consultationCondition.wait(until: deadline) {
                if consultationRecords[consultation.id]?.completion == nil {
                    consultationRecords[consultation.id]?.completion = RelayTextResponse(
                        status: 408,
                        text: "The consultation timed out before \(target.displayName) returned an answer."
                    )
                }
                break
            }
        }
        let result = consultationRecords.removeValue(forKey: consultation.id)?.completion
            ?? RelayTextResponse(status: 409, text: "The consultation stopped without an answer.")
        consultationCondition.broadcast()
        consultationCondition.unlock()
        return result
    }

    public func handleAnswer(token: String, consultationID: String, text: String) -> RelayTextResponse {
        guard let senderID = credentials.paneID(for: token) else {
            return RelayTextResponse(status: 401, text: "bad token")
        }
        let resolvedID: String
        if consultationID.caseInsensitiveCompare("current") == .orderedSame {
            consultationCondition.lock()
            let matches = consultationRecords.values.filter {
                $0.consultation.targetPaneID == senderID && $0.completion == nil
            }
            consultationCondition.unlock()
            guard matches.count == 1, let match = matches.first else {
                return RelayTextResponse(
                    status: matches.isEmpty ? 404 : 409,
                    text: matches.isEmpty
                        ? "this pane has no consultation awaiting an answer"
                        : "this pane has more than one waiting consultation"
                )
            }
            resolvedID = match.consultation.id
        } else {
            resolvedID = consultationID
        }
        return acceptAnswer(from: senderID, consultationID: resolvedID, text: text)
    }

    /// Human fallback for an agent that printed its answer but failed to invoke
    /// `parley answer`. Completing the waiting command is safe: this writes no
    /// terminal input and starts no command in another pane.
    public func answerFromUI(consultationID: String, text: String) -> RelayTextResponse {
        consultationCondition.lock()
        let targetID = consultationRecords[consultationID]?.consultation.targetPaneID
        consultationCondition.unlock()
        guard let targetID else { return RelayTextResponse(status: 404, text: "unknown consultation") }
        return acceptAnswer(from: targetID, consultationID: consultationID, text: text)
    }

    public func consultations() -> [RelayConsultation] {
        consultationCondition.lock()
        let values = consultationRecords.values
            .filter { $0.completion == nil }
            .map(\.consultation)
            .sorted { $0.createdAt < $1.createdAt }
        consultationCondition.unlock()
        return values
    }

    public func cancelAll(reason: String = "Parley stopped before the consultation completed.") {
        consultationCondition.lock()
        for id in Array(consultationRecords.keys) {
            consultationRecords[id]?.completion = RelayTextResponse(status: 409, text: reason)
        }
        consultationCondition.broadcast()
        consultationCondition.unlock()
    }

    private func resolve(_ requested: String, panes: [TmuxPane], sender: TmuxPane) -> [TmuxPane] {
        let available = panes.filter { $0.id != sender.id }
        if let exact = available.first(where: { $0.id == requested }) { return [exact] }

        let parts = requested.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let requestedWorkspace = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedPane = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestedWorkspace.isEmpty, !requestedPane.isEmpty else { return [] }
            return available.filter { pane in
                let workspaceMatches = requestedWorkspace.caseInsensitiveCompare(pane.workspaceName ?? "") == .orderedSame
                    || requestedWorkspace.caseInsensitiveCompare(pane.windowID) == .orderedSame
                return workspaceMatches && paneMatches(requestedPane, pane: pane)
            }
        }

        let local = available.filter { $0.windowID == sender.windowID && paneMatches(requested, pane: $0) }
        if !local.isEmpty { return local }
        return available.filter { paneMatches(requested, pane: $0) }
    }

    private func paneMatches(_ requested: String, pane: TmuxPane) -> Bool {
            requested.caseInsensitiveCompare(pane.displayName) == .orderedSame
                || requested.caseInsensitiveCompare(pane.kind.rawValue) == .orderedSame
                || requested.caseInsensitiveCompare(pane.kind.label) == .orderedSame
    }

    private func route(token: String, requestedTarget: String) throws -> (TmuxPane, TmuxPane) {
        guard let senderID = credentials.paneID(for: token) else {
            throw BrokerFailure(status: 401, message: "bad token")
        }
        let livePanes = try panes()
        guard let sender = livePanes.first(where: { $0.id == senderID }), sender.kind.isAgent else {
            throw BrokerFailure(status: 400, message: "unknown sender pane")
        }
        let requested = requestedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { throw BrokerFailure(status: 400, message: "name a target pane") }
        let candidates = resolve(requested, panes: livePanes, sender: sender)
        guard candidates.count == 1, let target = candidates.first else {
            if candidates.isEmpty { throw BrokerFailure(status: 400, message: "no pane named \(requested)") }
            let names = candidates.map { pane in
                let qualified = pane.workspaceName.map { "\($0)/\(pane.displayName)" } ?? pane.displayName
                return "\(qualified) (\(pane.id))"
            }.joined(separator: ", ")
            throw BrokerFailure(status: 400, message: "ambiguous target; choose \(names)")
        }
        guard target.kind.isAgent else {
            throw BrokerFailure(status: 400, message: "relay target must be an agent pane")
        }
        guard target.kind != sender.kind else {
            throw BrokerFailure(
                status: 400,
                message: "relay is cross-vendor; use the CLI's own delegation for the same vendor"
            )
        }
        return (sender, target)
    }

    private func acceptAnswer(from senderID: String, consultationID: String, text: String) -> RelayTextResponse {
        let cleaned = RelayText.clean(text)
        guard !cleaned.isEmpty else { return RelayTextResponse(status: 400, text: "nothing to return") }
        guard cleaned.count <= RelayText.maximumCharacters else {
            return RelayTextResponse(status: 400, text: "answer too long")
        }

        consultationCondition.lock()
        guard var record = consultationRecords[consultationID] else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 404, text: "unknown consultation")
        }
        guard record.consultation.targetPaneID == senderID else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 403, text: "only the requested pane can answer this consultation")
        }
        guard record.consultation.state == .awaitingAnswer, record.completion == nil else {
            consultationCondition.unlock()
            return RelayTextResponse(status: 409, text: "the consultation is not awaiting an answer")
        }
        record.completion = RelayTextResponse(status: 200, text: cleaned)
        consultationRecords[consultationID] = record
        consultationCondition.broadcast()
        consultationCondition.unlock()
        return RelayTextResponse(status: 200, text: "Answer returned to \(record.consultation.sourceName).")
    }

    private func consultationPrompt(for consultation: RelayConsultation) -> String {
        """
        \(consultation.sourceName) asked:

        \(consultation.question)

        Return the answer to the waiting \(consultation.sourceName) turn by running:
        parley answer current "your answer"

        For a multiline answer, pipe the text to `parley answer current`. Parley identifies the waiting question from this pane's credential, so do not copy or invent an id. Do not only print the answer in this pane; the requester is blocked waiting for that command.
        """
    }

    private func failure(_ status: Int, _ message: String) -> RelayResponse {
        RelayResponse(
            status: status,
            body: RelayResponseBody(ok: false, delivered: nil, submitted: nil, note: nil, error: message)
        )
    }
}

private struct ConsultationRecord {
    var consultation: RelayConsultation
    var completion: RelayTextResponse?
}

private struct BrokerFailure: Error {
    let status: Int
    let message: String
}

public enum RelayShimError: LocalizedError, Equatable {
    case commandCollision

    public var errorDescription: String? {
        switch self {
        case .commandCollision:
            "A different `parley` command already exists in the stable command directory. Parley left it unchanged."
        }
    }
}

public enum RelayShim {
    public static func install(in applicationDirectory: URL) throws -> URL {
        let bin = applicationDirectory.appendingPathComponent("bin", isDirectory: true)
        _ = try installCommand(in: bin)
        return bin
    }

    @discardableResult
    public static func installCommand(in bin: URL) throws -> URL {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("parley")
        if FileManager.default.fileExists(atPath: executable.path) {
            let existing = try String(contentsOf: executable, encoding: .utf8)
            let isManaged = existing.contains("Parley Native managed relay shim")
                || (existing.contains("PARLEY_RELAY_INFO") && existing.contains("parley relay <pane>"))
            guard isManaged else {
                throw RelayShimError.commandCollision
            }
        }
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private static let script = """
    #!/bin/sh
    # Parley Native managed relay shim
    set -eu

    command="${1:-}"
    case "$command" in
      relay|paste|ask)
        target="${2:-}"
        if [ -z "$target" ]; then
          echo "name a pane, for example: parley $command agy \"your question\"" >&2
          exit 2
        fi
        shift 2
        ;;
      answer)
        consultation="${2:-}"
        case "$consultation" in
          "")
            echo "answer needs 'current' or the consultation id included in the question" >&2
            exit 2
            ;;
          current) ;;
          *[!a-f0-9-]*)
            echo "answer needs 'current' or the consultation id included in the question" >&2
            exit 2
            ;;
        esac
        shift 2
        ;;
      *)
        echo "usage:" >&2
        echo "  parley relay <pane> [text...]   submit an attributed message" >&2
        echo "  parley paste <pane> [text...]   paste without sending" >&2
        echo "  parley ask <pane> [question...] wait for its correlated answer" >&2
        echo "  parley answer current [text...] answer this pane's waiting question" >&2
        echo "text may also come on stdin" >&2
        exit 2
        ;;
    esac

    if [ -z "${PARLEY_RELAY_INFO:-}" ] || [ ! -r "$PARLEY_RELAY_INFO" ]; then
      echo "the Parley relay broker is not running" >&2
      exit 2
    fi
    if [ "$#" -eq 0 ] && [ -t 0 ]; then
      echo "nothing to $command: give the text as arguments or pipe it in" >&2
      exit 2
    fi
    locator="$(/bin/cat "$PARLEY_RELAY_INFO")"

    post() {
      path="$1"
      case "$locator" in
        unix:*)
          socket="${locator#unix:}"
          /usr/bin/curl -sS --fail-with-body -X POST \
            --unix-socket "$socket" \
            -H "Authorization: Bearer ${PARLEY_RELAY_TOKEN:-}" \
            -H "X-Parley-To: ${target:-}" \
            -H "Content-Type: text/plain" \
            --data-binary @- \
            "http://parley$path"
          ;;
        http://*|https://*)
          /usr/bin/curl -sS --fail-with-body -X POST \
            -H "Authorization: Bearer ${PARLEY_RELAY_TOKEN:-}" \
            -H "X-Parley-To: ${target:-}" \
            -H "Content-Type: text/plain" \
            --data-binary @- \
            "$locator$path"
          ;;
        *)
          echo "Parley's relay locator is invalid" >&2
          return 2
          ;;
      esac
    }

    case "$command" in
      relay|paste|ask)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post "/$command"
        ;;
      answer)
        if [ "$#" -gt 0 ]; then
          printf '%s' "$*"
        else
          /bin/cat
        fi | post "/answer/$consultation"
        ;;
    esac
    """
}
