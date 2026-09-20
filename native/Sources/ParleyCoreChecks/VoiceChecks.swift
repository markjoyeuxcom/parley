import Foundation
import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

private func voiceExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func voiceRefuses(_ operation: () throws -> Void) throws {
    do { try operation() } catch { return }
    throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsafe voice operation accepted"])
}

private func voicePane(_ id: String = "voice-pane") -> WorkbenchPane {
    WorkbenchPane(id: id, kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp/project",
        currentCommand: "", isActive: true, workspaceID: "workspace", relayEnabled: true,
        protocolVersion: AgentProtocol.version, workspaceName: "Workspace", inputAvailable: true, launchGeneration: 1)
}

@MainActor let voiceChecks: [(String, () throws -> Void)] = [
    ("voice native handoffs authenticate and revalidate before correlated Ask or Delegate", {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("voice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens"))
        let source = voicePane("source"), target = voicePane("target")
        let broker = RelayBroker(credentials: credentials, panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in },
            voiceSubmit: { request, _ in
                _ = try request.source.resolve(in: [source, target])
                _ = try request.target.resolve(in: [source, target])
            },
            consultationTimeout: 3, livenessPollInterval: 0.01)
        let info = root.appendingPathComponent("info")
        let server = RelayHTTPServer(broker: broker, infoFile: info, controlToken: "voice-check-control")
        try server.start(); defer { server.stop() }
        func request(_ kind: VoiceHandoffRequest.Kind, target pane: WorkbenchPane? = nil) -> VoiceHandoffRequest {
            VoiceHandoffRequest(source: VoiceDestination(pane: source), target: VoiceDestination(pane: pane ?? target), text: "Reviewed voice text", kind: kind, idempotencyKey: UUID().uuidString)
        }
        let denied = RelayCoreClient(infoFile: info, controlToken: try credentials.token(for: source.id), allowsTrackedRequestsOnMainThread: true)
        try voiceExpect(try denied.voiceHandoffFromUI(request(.delegate)).status == 401, "pane credential entered a native voice route")
        let client = RelayCoreClient(infoFile: info, controlToken: "voice-check-control", allowsTrackedRequestsOnMainThread: true)
        var old = target; old.launchGeneration -= 1
        for kind in VoiceHandoffRequest.Kind.allCases {
            try voiceExpect(try client.voiceHandoffFromUI(request(kind, target: old)).status == 409, "a stale reviewed handoff was sent")
        }
        try voiceExpect(broker.handoffs().isEmpty, "refused voice requests created a handoff")
        let reply = VoiceReplyBox(), ask = request(.ask)
        DispatchQueue.global().async { reply.set(try? client.voiceHandoffFromUI(ask)) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while broker.consultations().isEmpty && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard let consultation = broker.consultations().first else { throw VoiceError.unavailable("voice Ask never entered the correlated path") }
        try voiceExpect(broker.answerFromUI(consultationID: consultation.id, text: "Correlated answer").status == 200, "voice Ask could not be answered")
        while reply.value == nil && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try voiceExpect(reply.value?.text == "Correlated answer", "voice Ask did not return its correlated answer")
        try voiceExpect(try client.voiceHandoffFromUI(request(.delegate)).status == 200, "reviewed voice Delegate failed")
        try voiceExpect(broker.handoffs().contains { $0.kind == .delegate && $0.text == "Reviewed voice text" }, "voice bypassed the delegation journal")
    }),
    ("voice recording button supports accessible start stop and disabled state", {
        var activations = 0
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let host = NSHostingView(rootView: HoldToTalkButton(enabled: true, recording: false,
            begin: {}, end: {}, toggle: { activations += 1 }))
        window.contentView = host; window.orderFront(nil)
        func button(_ view: NSView) -> VoiceHoldButton? {
            if let result = view as? VoiceHoldButton { return result }
            return view.subviews.lazy.compactMap(button).first
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while button(host) == nil && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let control = button(host) else { throw VoiceError.unavailable("Voice button never mounted") }
        try voiceExpect(control.accessibilityPerformPress() && control.accessibilityPerformPress() && activations == 2, "accessible start and stop were not delivered")
        control.isEnabled = false
        try voiceExpect(!control.accessibilityPerformPress() && activations == 2, "disabled voice button activated")
    }),
    ("voice cancellation ignores late permission and recognition callbacks", {
        var session = VoiceSession()
        let first = try session.begin(target: VoiceDestination(pane: voicePane()), playbackActive: false)
        session.discard()
        session.didStart(first)
        session.receive("must not return", sessionID: first)
        try voiceExpect(session.phase == .idle && session.text.isEmpty && session.destination == nil, "cancel revived capture")
        let second = try session.begin(target: VoiceDestination(pane: voicePane()), playbackActive: false)
        session.didStart(second)
        session.receive("new transcript", sessionID: second)
        session.receive("old transcript", sessionID: first)
        try voiceExpect(session.text == "new transcript", "an old session replaced the new transcript")
    }),
    ("voice never starts after push-to-talk was released during preparation", {
        var session = VoiceSession()
        let id = try session.begin(target: VoiceDestination(pane: voicePane()), playbackActive: false)
        session.stop()
        session.didStart(id)
        try voiceExpect(session.phase == .review, "late permission started a released microphone")
    }),
    ("voice destinations refuse restart move close and folder changes", {
        let original = voicePane(), destination = VoiceDestination(pane: voicePane())
        try voiceExpect(try destination.resolve(in: [original]).id == original.id, "live destination refused")
        var changed = original; changed.launchGeneration += 1
        try voiceRefuses { _ = try destination.resolve(in: [changed]) }
        changed = original; changed.workspaceID = "moved"
        try voiceRefuses { _ = try destination.resolve(in: [changed]) }
        changed = original; changed.isDead = true
        try voiceRefuses { _ = try destination.resolve(in: [changed]) }
        changed = original; changed.launchFolder = "/tmp/other"
        try voiceRefuses { _ = try destination.resolve(in: [changed]) }
        try voiceRefuses { _ = try destination.resolve(in: []) }
        try voiceRefuses { _ = try destination.resolve(in: [original, original]) }
    }),
    ("voice requires review and preserves the bound target when selection changes", {
        var session = VoiceSession()
        let original = voicePane(), other = voicePane("other")
        let id = try session.begin(target: VoiceDestination(pane: original), playbackActive: false)
        session.didStart(id); session.receive("dictated", sessionID: id)
        try voiceRefuses { _ = try session.prepareDelivery(panes: [original, other]) }
        session.stop(); session.complete(id)
        session.edit("person edited")
        let delivery = try session.prepareDelivery(panes: [other, original])
        try voiceExpect(delivery.destination.paneID == original.id && delivery.text == "person edited", "voice redirected or ignored edits")
        session.deliveryFailed("submission interrupted", mayHaveDelivered: true)
        try voiceRefuses { _ = try session.prepareDelivery(panes: [original]) }
        try voiceExpect(session.text == "person edited", "uncertain delivery erased the draft")
    }),
    ("voice playback and capture cannot overlap and queues stay bounded", {
        var session = VoiceSession()
        try voiceRefuses { _ = try session.begin(target: VoiceDestination(pane: voicePane()), playbackActive: true) }
        var queue = VoicePlaybackQueue()
        try voiceRefuses { try queue.enqueue(text: "hello", label: "selection", enabled: false, captureActive: false) }
        try voiceRefuses { try queue.enqueue(text: "hello", label: "selection", enabled: true, captureActive: true) }
        for _ in 0..<VoicePlaybackQueue.maximumItems { try queue.enqueue(text: "hello", label: "selection", enabled: true, captureActive: false) }
        try voiceRefuses { try queue.enqueue(text: "excess", label: "selection", enabled: true, captureActive: false) }
        queue.removeAll()
        try voiceExpect(queue.items.isEmpty, "stop left queued speech")
        try voiceRefuses { try queue.enqueue(text: String(repeating: "x", count: VoicePlaybackQueue.maximumCharacters + 1), label: "result", enabled: true, captureActive: false) }
    }),
    ("voice failures preserve bounded partial drafts and recording more preserves edits", {
        let target = VoiceDestination(pane: voicePane())
        var session = VoiceSession()
        let first = try session.begin(target: target, playbackActive: false)
        session.didStart(first); session.receive("partial", sessionID: first)
        session.fail("Microphone access was revoked", sessionID: first)
        try voiceExpect(session.phase == .review && session.text == "partial" && session.message != nil, "failure lost the partial transcript")
        session.edit("corrected")
        let second = try session.begin(target: target, playbackActive: false)
        session.didStart(second); session.receive("more words", sessionID: second)
        try voiceExpect(session.text == "corrected\nmore words", "recording more lost edits")
        session.receive(String(repeating: "a", count: 9_000), sessionID: second)
        try voiceExpect(session.text.count == 8_000 && session.message != nil, "transcript grew without a visible limit")
        session.stop(); session.complete(second)
        try session.retarget(VoiceDestination(pane: voicePane("replacement")))
        try voiceExpect(session.destination?.paneID == "replacement" && session.text.count == 8_000, "explicit reselection lost the draft")
        session.discard()
        let denied = try session.begin(target: target, playbackActive: false)
        session.fail("Microphone access is off", sessionID: denied)
        try voiceRefuses { _ = try session.reviewedText(panes: [voicePane()]) }
    }),
    ("voice handoffs refuse when the reviewed transport is absent", {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("voice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = voicePane("source"), target = voicePane("target")
        var unreviewedSubmissions = 0
        let broker = RelayBroker(credentials: try RelayCredentials(file: root.appendingPathComponent("tokens")),
            panes: { [source, target] }, paste: { _, _ in }, submit: { _, _ in unreviewedSubmissions += 1 })
        for kind in VoiceHandoffRequest.Kind.allCases {
            let request = VoiceHandoffRequest(source: VoiceDestination(pane: source), target: VoiceDestination(pane: target),
                text: "reviewed", kind: kind, idempotencyKey: UUID().uuidString)
            try voiceExpect(broker.handleVoiceHandoffFromUI(request).status == 409, "missing review transport did not refuse")
        }
        try voiceExpect(unreviewedSubmissions == 0, "voice silently used the ordinary submit callback")
    }),
    ("voice controller carries both reviewed generations and preserves Copilot trust", {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("voice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try WorkbenchController(applicationDirectory: root.appendingPathComponent("app"), environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"])
        try controller.bootstrap(cwd: root.path)
        let credentials = try RelayCredentials(file: root.appendingPathComponent("tokens"))
        controller.configureRelay(RelayRuntime(infoFile: root.appendingPathComponent("info"), shimDirectory: root.appendingPathComponent("bin"),
            transportDirectory: root.appendingPathComponent("transport"), credentials: credentials))
        let source = try controller.createPane(kind: .claude, cwd: root.path)
        let target = try controller.createPane(kind: .copilot, cwd: root.path)
        try controller.terminalDidAttach(paneID: source.id); try controller.terminalDidAttach(paneID: target.id)
        let live = try controller.listPanes()
        let sourceSnapshot = VoiceDestination(pane: live.first { $0.id == source.id }!)
        let targetSnapshot = VoiceDestination(pane: live.first { $0.id == target.id }!)
        var ordinary = 0, deliveries: [Bool] = []
        controller.configureTerminalTransport(PaneTerminalTransport(paste: { _, _, _ in ordinary += 1 },
            voicePaste: { paneID, text, submit, reviewed in
                try voiceExpect(paneID == target.id && text == "edited" && reviewed == [targetSnapshot, sourceSnapshot], "transport lost the reviewed participants or text")
                deliveries.append(submit)
            }, interrupt: { _ in }, captureSelectedText: { _ in "" }, terminate: { _ in }, terminateAll: {}))
        try voiceRefuses { try controller.pasteVoice("edited", destination: targetSnapshot, source: sourceSnapshot, submit: true) }
        try voiceExpect(deliveries.isEmpty, "voice bypassed Copilot folder trust")
        try controller.confirmCopilotFolderTrust(paneID: target.id, expectedGeneration: targetSnapshot.generation, expectedFolder: root.path)
        try controller.pasteVoice("edited", destination: targetSnapshot, source: sourceSnapshot, submit: false)
        try controller.pasteVoice("edited", destination: targetSnapshot, source: sourceSnapshot, submit: true)
        try controller.restartPane(source.id)
        try voiceRefuses { try controller.pasteVoice("edited", destination: targetSnapshot, source: sourceSnapshot, submit: true) }
        try voiceExpect(deliveries == [false, true] && ordinary == 0, "voice redirected or used unreviewed delivery")
    }),
]

private final class VoiceReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: RelayTextResponse?
    var value: RelayTextResponse? { lock.withLock { response } }
    func set(_ value: RelayTextResponse?) { lock.withLock { response = value } }
}
