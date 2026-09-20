import Foundation

public enum VoiceError: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { switch self { case let .unavailable(message): message } }
}

/// A human-reviewed destination, never the pane that happens to be active later.
public struct VoiceDestination: Codable, Equatable, Sendable {
    public let paneID: String
    public let generation: Int
    public let workspaceID: String
    public let folder: String
    public let kind: PaneKind
    public let name: String
    public let workspaceName: String

    public init(pane: WorkbenchPane) {
        paneID = pane.id; generation = pane.launchGeneration; workspaceID = pane.workspaceID
        folder = pane.launchWorkingDirectory; kind = pane.kind; name = pane.displayName
        workspaceName = pane.workspaceName ?? "Workspace"
    }

    public func matches(_ pane: WorkbenchPane) -> Bool {
        pane.id == paneID && pane.launchGeneration == generation && pane.workspaceID == workspaceID
            && pane.launchWorkingDirectory == folder && pane.kind == kind
            && pane.kind.isAgent && pane.isStarted && !pane.isDead && pane.inputAvailable
            && pane.relayEnabled && pane.hasCurrentProtocol
    }

    public func resolve(in panes: [WorkbenchPane]) throws -> WorkbenchPane {
        let matches = panes.filter { $0.id == paneID }
        guard matches.count == 1, let pane = matches.first, self.matches(pane) else {
            throw VoiceError.unavailable("The reviewed voice destination changed or is unavailable. Choose a destination again; nothing was sent.")
        }
        return pane
    }

    public var label: String { "\(name) · \(kind.label) · \(workspaceName)" }
}

/// Pure session state shared by native recording, review and deterministic checks.
/// No audio or transcript is Codable or written to preferences.
public struct VoiceSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, preparing, recording, finishing, review, delivering, deliveryUncertain }
    public static let maximumCharacters = 8_000
    public static let maximumRecordingSeconds: Double = 60
    public private(set) var phase: Phase = .idle
    public private(set) var id = UUID()
    public private(set) var destination: VoiceDestination?
    public private(set) var text = ""
    public private(set) var message: String?
    private var prefix = ""
    public init() {}
    public var captureActive: Bool { phase == .preparing || phase == .recording || phase == .finishing }
    public var isPresented: Bool { phase != .idle }

    @discardableResult
    public mutating func begin(target: VoiceDestination, playbackActive: Bool) throws -> UUID {
        guard !playbackActive else { throw VoiceError.unavailable("Stop read-aloud before recording.") }
        guard phase == .idle || phase == .review else { throw VoiceError.unavailable("Finish or discard the current voice draft first.") }
        guard destination == nil || destination == target else { throw VoiceError.unavailable("Choose the new voice destination explicitly before recording more.") }
        id = UUID(); destination = target; prefix = text; message = nil; phase = .preparing
        return id
    }

    public mutating func didStart(_ sessionID: UUID) {
        guard id == sessionID, phase == .preparing else { return }
        phase = .recording
    }

    public mutating func receive(_ transcript: String, sessionID: UUID) {
        guard id == sessionID, phase == .recording || phase == .finishing else { return }
        let combined = prefix.isEmpty ? transcript : prefix + "\n" + transcript
        text = String(combined.prefix(Self.maximumCharacters))
        if combined.count > Self.maximumCharacters { message = "The transcript reached the 8,000-character limit. Review the retained text." }
    }

    public mutating func stop() {
        if phase == .preparing { phase = .review }
        else if phase == .recording { phase = .finishing }
    }

    public mutating func complete(_ sessionID: UUID) {
        guard id == sessionID, captureActive else { return }
        phase = .review
    }

    public mutating func fail(_ message: String, sessionID: UUID) {
        guard id == sessionID, captureActive else { return }
        self.message = message; phase = .review
    }

    public mutating func edit(_ value: String) {
        guard phase == .review else { return }
        text = String(value.prefix(Self.maximumCharacters))
    }

    public mutating func retarget(_ value: VoiceDestination) throws {
        guard phase == .review else { throw VoiceError.unavailable("Stop recording before changing its destination.") }
        destination = value; message = nil
    }

    public func reviewedText(panes: [WorkbenchPane]) throws -> (destination: VoiceDestination, text: String) {
        guard phase == .review, let destination, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.unavailable("Stop recording and review a nonempty transcript before delivery.")
        }
        _ = try destination.resolve(in: panes)
        return (destination, text)
    }

    public mutating func prepareDelivery(panes: [WorkbenchPane]) throws -> (destination: VoiceDestination, text: String) {
        let reviewed = try reviewedText(panes: panes)
        phase = .delivering
        return reviewed
    }

    public mutating func deliveryFailed(_ message: String, mayHaveDelivered: Bool) {
        self.message = message
        phase = mayHaveDelivered ? .deliveryUncertain : .review
    }

    public mutating func discard() { self = Self() }
}

public struct VoicePlaybackItem: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let text: String
    public let label: String
}

public struct VoicePlaybackQueue: Equatable, Sendable {
    public static let maximumItems = 3
    public static let maximumCharacters = 8_000
    public private(set) var items: [VoicePlaybackItem] = []
    public init() {}
    public mutating func enqueue(text: String, label: String, enabled: Bool, captureActive: Bool) throws {
        guard enabled else { throw VoiceError.unavailable("Enable read-aloud in Voice settings first.") }
        guard !captureActive else { throw VoiceError.unavailable("Stop recording before using read-aloud.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= Self.maximumCharacters else {
            throw VoiceError.unavailable("Select between 1 and 8,000 characters to read aloud.")
        }
        guard items.count < Self.maximumItems else { throw VoiceError.unavailable("The speech queue holds three items. Remove an item or stop playback first.") }
        items.append(VoicePlaybackItem(text: text, label: label))
    }
    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }
}

public struct VoiceHandoffRequest: Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case ask, delegate }
    public let source: VoiceDestination
    public let target: VoiceDestination
    public let text: String
    public let kind: Kind
    public let idempotencyKey: String
    public init(source: VoiceDestination, target: VoiceDestination, text: String, kind: Kind, idempotencyKey: String) {
        self.source = source; self.target = target; self.text = text; self.kind = kind; self.idempotencyKey = idempotencyKey
    }
}
