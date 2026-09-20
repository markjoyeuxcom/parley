import AppKit
import AVFoundation
import Combine
import ParleyCore

@MainActor final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var session = VoiceSession()
    @Published private(set) var playback = VoicePlaybackQueue()
    @Published private(set) var speakingID: UUID?
    @Published private(set) var stoppingCapture = false
    @Published private(set) var support = "Check speech support to see whether this language is ready."
    @Published private(set) var checkingSupport = false
    @Published private(set) var installingModel = false
    @Published var error: String?
    @Published var language: String {
        didSet { preferences.set(language, forKey: "voice.language"); support = "Check speech support for this language." }
    }
    @Published var readAloudEnabled: Bool {
        didSet { preferences.set(readAloudEnabled, forKey: "voice.readAloud"); if !readAloudEnabled { stopSpeaking() } }
    }
    private let preferences: UserDefaults
    private let synthesizer = AVSpeechSynthesizer()
    private var utteranceIdentity: ObjectIdentifier?
    private var recognition: VoiceRecognition?
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var finishDeadline: Task<Void, Never>?
    private var supportGeneration = UUID()
    private var installationTask: Task<Void, Never>?
    private var installationProgress: Progress?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        let saved = preferences.string(forKey: "voice.language")
        language = ["en-GB", "en-US"].contains(saved ?? "") ? saved! : "en-GB"
        readAloudEnabled = preferences.bool(forKey: "voice.readAloud")
        super.init()
        synthesizer.delegate = self
    }

    var playbackActive: Bool { speakingID != nil || !playback.items.isEmpty || synthesizer.isSpeaking }
    var canRecord: Bool { !stoppingCapture && !playbackActive && !installingModel && (session.phase == .idle || session.phase == .review) }

    func begin(pane: WorkbenchPane) {
        do {
            guard canRecord else { throw VoiceError.unavailable("Finish the current voice operation or stop read-aloud before recording.") }
            let target = session.destination ?? VoiceDestination(pane: pane)
            _ = try target.resolve(in: [pane])
            let id = try session.begin(target: target, playbackActive: playbackActive)
            error = nil
            let run = VoiceRecognition { [weak self] event in self?.receive(event, id: id) }
            recognition = run
            let language = language
            startTask = Task { [weak self] in
                do { try await run.start(language: language) }
                catch is CancellationError { await run.cancel() }
                catch {
                    self?.session.fail(error.localizedDescription, sessionID: id)
                    self?.stopHardware(run)
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func receive(_ event: VoiceRecognitionEvent, id: UUID) {
        guard id == session.id else { return }
        switch event {
        case .started:
            session.didStart(id)
            guard session.phase == .recording else { if let recognition { stopHardware(recognition) }; return }
            durationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(VoiceSession.maximumRecordingSeconds))
                guard !Task.isCancelled, let self, self.session.id == id else { return }
                self.stopRecording()
            }
        case let .transcript(text): session.receive(text, sessionID: id)
        case .finished:
            session.complete(id)
            if let recognition { stopHardware(recognition) }
        case let .failed(message):
            session.fail(message, sessionID: id)
            if let recognition { stopHardware(recognition) }
        }
    }

    func stopRecording() {
        guard session.captureActive else { return }
        let preparing = session.phase == .preparing, id = session.id
        session.stop(); durationTask?.cancel()
        guard let recognition else { return }
        if preparing { startTask?.cancel(); stopHardware(recognition); return }
        guard session.phase == .finishing, finishTask == nil else { return }
        finishTask = Task { [weak self] in
            do { try await recognition.finish() }
            catch {
                guard let self, self.session.id == id, self.session.captureActive else { return }
                self.session.fail(error.localizedDescription, sessionID: id); self.stopHardware(recognition)
            }
        }
        finishDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.session.id == id, self.session.phase == .finishing else { return }
            self.session.fail("Speech recognition did not finish in time. Review the partial transcript or discard it.", sessionID: id)
            self.stopHardware(recognition)
        }
    }

    private func stopHardware(_ run: VoiceRecognition) {
        guard !stoppingCapture else { return }
        stoppingCapture = true
        durationTask?.cancel(); finishDeadline?.cancel(); finishTask?.cancel(); startTask?.cancel()
        Task { [weak self] in
            await run.cancel()
            guard let self else { return }
            if self.recognition === run { self.recognition = nil }
            self.stoppingCapture = false; self.startTask = nil; self.finishTask = nil
        }
    }

    func discard() {
        session.discard(); error = nil
        if let recognition { stopHardware(recognition) }
    }

    func reconcile(panes: [WorkbenchPane]) {
        guard session.captureActive, let destination = session.destination,
              (try? destination.resolve(in: panes)) == nil else { return }
        session.fail("The recording destination changed. Review the transcript and explicitly choose a destination again.", sessionID: session.id)
        if let recognition { stopHardware(recognition) }
    }

    func checkSupport() {
        guard !checkingSupport else { return }
        checkingSupport = true
        let selected = language
        let generation = UUID(); supportGeneration = generation
        Task { [weak self] in
            let message = await VoiceRecognition.supportMessage(language: selected)
            guard let self, self.supportGeneration == generation else { return }
            if self.language == selected { self.support = message }
            self.checkingSupport = false
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.checkingSupport, self.supportGeneration == generation else { return }
            self.supportGeneration = UUID(); self.checkingSupport = false
            self.support = "The system did not return speech availability in time. You can check again."
        }
    }

    func installModel() {
        guard !installingModel, !session.captureActive else { return }
        installingModel = true; error = nil
        let selected = language
        installationTask = Task { [weak self] in
            do {
                try await VoiceRecognition.installModel(language: selected) { [weak self] progress in self?.installationProgress = progress }
            }
            catch { self?.error = error.localizedDescription }
            self?.installationProgress = nil; self?.installationTask = nil
            self?.installingModel = false; self?.checkSupport()
        }
    }

    func cancelModelInstallation() {
        installationProgress?.cancel(); installationTask?.cancel()
    }

    func read(_ text: String, label: String) {
        do {
            try playback.enqueue(text: text, label: label, enabled: readAloudEnabled,
                captureActive: session.captureActive || stoppingCapture)
            error = nil; playNext()
        } catch { self.error = error.localizedDescription }
    }

    func removeQueued(_ id: UUID) { if id != speakingID { playback.remove(id) } }

    private func playNext() {
        guard speakingID == nil, let item = playback.items.first, readAloudEnabled, !session.captureActive, !stoppingCapture else { return }
        guard let systemVoice = AVSpeechSynthesisVoice(language: language) else {
            playback.removeAll()
            error = "No system speaking voice is available for this language. Manage voices in macOS Accessibility > Spoken Content."
            return
        }
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.voice = systemVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingID = item.id; utteranceIdentity = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        playback.removeAll()
        if !synthesizer.stopSpeaking(at: .immediate) { speakingID = nil; utteranceIdentity = nil }
    }

    private func speechEnded(_ identity: ObjectIdentifier) {
        guard utteranceIdentity == identity else { return }
        if let speakingID { playback.remove(speakingID) }
        speakingID = nil; utteranceIdentity = nil; playNext()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechEnded(identity) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.speechEnded(identity) }
    }
}
