import Foundation
@preconcurrency import AVFoundation
@preconcurrency import Speech
import ParleyCore

/// Each buffer is copied before the audio tap returns and has one consumer.
private struct VoiceAudioChunk: @unchecked Sendable { let buffer: AVAudioPCMBuffer }

private final class VoiceConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? { lock.withLock { let value = buffer; buffer = nil; return value } }
}

/// Owns engine mutation on one queue, never on the UI or audio callback thread.
private final class VoiceMicrophone: @unchecked Sendable {
    private let queue = DispatchQueue(label: "parley.voice.microphone", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private let stream = AsyncStream<VoiceAudioChunk>.makeStream(bufferingPolicy: .bufferingOldest(32))
    var buffers: AsyncStream<VoiceAudioChunk> { stream.stream }

    func start(failure: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    done.resume(throwing: VoiceError.unavailable("No microphone input is available. Check Sound settings.")); return
                }
                let continuation = stream.continuation
                let overflow: @Sendable () -> Void = { failure("Audio could not be processed quickly enough. Recording stopped; try a shorter dictation.") }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { overflow(); return }
                    copy.frameLength = buffer.frameLength
                    let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
                    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for index in source.indices {
                        guard let from = source[index].mData, let to = destination[index].mData else { continue }
                        memcpy(to, from, Int(source[index].mDataByteSize))
                    }
                    if case .dropped = continuation.yield(VoiceAudioChunk(buffer: copy)) { overflow() }
                }
                do {
                    engine.prepare(); try engine.start(); self.engine = engine
                    configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
                        failure("The microphone configuration changed. Recording stopped; check the input device and try again.")
                    }
                    done.resume()
                } catch {
                    input.removeTap(onBus: 0); engine.stop(); done.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { done in
            queue.async { [self] in
                if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
                configurationObserver = nil
                if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0); engine.reset() }
                engine = nil; stream.continuation.finish(); done.resume()
            }
        }
    }
}

enum VoiceRecognitionEvent: Sendable { case started, transcript(String), finished, failed(String) }

/// One recording has one owner. A cancelled owner is never reused by a later run.
@MainActor final class VoiceRecognition {
    private let microphone = VoiceMicrophone()
    private let report: @MainActor (VoiceRecognitionEvent) -> Void
    private var consumeTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyRecognizer: SFSpeechRecognizer?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var modernFinish: (() async throws -> Void)?
    private var modernCancel: (() async -> Void)?
    private var cancelled = false

    init(report: @escaping @MainActor (VoiceRecognitionEvent) -> Void) { self.report = report }

    nonisolated static func supportMessage(language: String) async -> String {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return "On-device speech model is ready. Audio stays on this Mac."
            case .supported: return "Download Apple's on-device speech model to enable this language."
            case .downloading: return "Apple's on-device speech model is downloading."
            default: return "On-device recognition is unavailable for this language on this Mac."
            }
        }
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        return recognizer?.supportsOnDeviceRecognition == true
            ? "On-device dictation is available. Audio stays on this Mac."
            : "On-device dictation is unavailable. Enable this language in macOS Keyboard > Dictation and check again. macOS 26 offers downloadable speech models on supported Macs."
    }

    nonisolated static func installModel(language: String, progress: @escaping @MainActor @Sendable (Progress) -> Void) async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw VoiceError.unavailable("On this Mac, manage local dictation languages in macOS Keyboard settings.")
        }
        let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard try await AssetInventory.reserve(locale: locale) else {
            throw VoiceError.unavailable("Apple could not reserve this speech language. Check the installed languages in macOS settings.")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try Task.checkCancellation()
            await progress(request.progress)
            try await request.downloadAndInstall()
        }
    }

    func start(language: String) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw VoiceError.unavailable("Voice needs the packaged Parley app for macOS microphone consent. The unbundled development executable cannot request access.")
        }
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        let allowed: Bool
        if permission == .notDetermined { allowed = await microphonePermission() }
        else { allowed = permission == .authorized }
        guard allowed else { throw VoiceError.unavailable("Microphone access is off. Allow Parley in System Settings > Privacy & Security > Microphone, then try again.") }
        try checkCancellation()
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            try await prepareModern(language: language)
        } else {
            try await prepareLegacy(language: language)
        }
        try checkCancellation()
        try await microphone.start { [weak self] message in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                self.report(.failed(message))
            }
        }
        try checkCancellation()
        report(.started)
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.cancelled else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    self.report(.failed("Microphone access was revoked. Allow Parley in Privacy & Security before recording again."))
                    return
                }
            }
        }
    }

    private func microphonePermission() async -> Bool {
        await withCheckedContinuation { result in AVCaptureDevice.requestAccess(for: .audio) { result.resume(returning: $0) } }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    private func prepareLegacy(language: String) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.unavailable("Local dictation is unavailable for this language. Open Voice settings to check speech support. Audio has not been sent to a server.")
        }
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw VoiceError.unavailable("Speech consent requires the packaged Parley app.")
        }
        let authorized = await withCheckedContinuation { result in SFSpeechRecognizer.requestAuthorization { result.resume(returning: $0 == .authorized) } }
        guard authorized else { throw VoiceError.unavailable("Allow Speech Recognition for Parley in macOS Privacy & Security settings, then try again.") }
        try checkCancellation()
        guard recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { throw VoiceError.unavailable("On-device recognition is currently unavailable.") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.addsPunctuation = true
        legacyRequest = request
        legacyRecognizer = recognizer
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString, final = result?.isFinal == true, failure = error?.localizedDescription
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                if let text { self.report(.transcript(text)) }
                if final { self.report(.finished) }
                else if let failure { self.report(.failed(failure)) }
            }
        }
        let buffers = microphone.buffers
        consumeTask = Task.detached {
            for await chunk in buffers { try Task.checkCancellation(); request.append(chunk.buffer) }
        }
    }

    @available(macOS 26, *)
    private func prepareModern(language: String) async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw VoiceError.unavailable("This language has no on-device speech model on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw VoiceError.unavailable("Install Apple's speech model in Parley > Settings > Voice before recording.")
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.unavailable("The speech model has no supported audio format. Check Voice settings.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let input = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
        modernFinish = { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        modernCancel = { input.continuation.finish(); await analyzer.cancelAndFinishNow() }
        try await analyzer.prepareToAnalyze(in: format)
        try checkCancellation()
        resultsTask = Task { [weak self] in
            var committed = ""
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard let self, !self.cancelled else { return }
                    let text = String(result.text.characters)
                    self.report(.transcript(committed + text))
                    if result.isFinal { committed += text }
                }
            } catch { if !Task.isCancelled { self?.report(.failed(error.localizedDescription)) } }
        }
        let buffers = microphone.buffers
        consumeTask = Task.detached {
            defer { input.continuation.finish() }
            var converter: AVAudioConverter?
            for await chunk in buffers {
                try Task.checkCancellation()
                if converter == nil { converter = AVAudioConverter(from: chunk.buffer.format, to: format) }
                guard let converter,
                      let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(chunk.buffer.frameLength) * format.sampleRate / chunk.buffer.format.sampleRate)) + 32) else {
                    throw VoiceError.unavailable("The microphone format cannot be converted for speech recognition.")
                }
                let feeder = VoiceConverterInput(chunk.buffer)
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    guard let buffer = feeder.take() else { state.pointee = .noDataNow; return nil }
                    state.pointee = .haveData; return buffer
                }
                if let error { throw error }
                guard status != .error else { throw VoiceError.unavailable("Microphone audio conversion failed.") }
                if converted.frameLength > 0, case .dropped = input.continuation.yield(AnalyzerInput(buffer: converted)) {
                    throw VoiceError.unavailable("The speech model fell behind. Try a shorter dictation.")
                }
            }
        }
        let consumer = consumeTask
        Task { [weak self] in
            do { try await consumer?.value }
            catch {
                guard let self, !self.cancelled else { return }
                self.report(.failed(error.localizedDescription))
            }
        }
        try await analyzer.start(inputSequence: input.stream)
    }

    func finish() async throws {
        permissionTask?.cancel()
        await microphone.stop()
        try await consumeTask?.value
        if let modernFinish {
            try await modernFinish(); await resultsTask?.value
            if !cancelled { report(.finished) }
        } else {
            legacyRequest?.endAudio(); legacyTask?.finish()
        }
    }

    func cancel() async {
        cancelled = true; consumeTask?.cancel(); resultsTask?.cancel(); permissionTask?.cancel()
        await microphone.stop()
        legacyTask?.cancel(); legacyRequest?.endAudio(); legacyTask = nil; legacyRequest = nil; legacyRecognizer = nil
        await modernCancel?()
        modernCancel = nil; modernFinish = nil
    }
}
