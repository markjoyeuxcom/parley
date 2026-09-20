import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

struct VoiceToolbarControl: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceController
    var body: some View {
        HoldToTalkButton(enabled: (voice.canRecord && model.voiceDestinationPane != nil) || voice.session.captureActive,
            recording: voice.session.captureActive, begin: model.beginVoiceRecording, end: voice.stopRecording,
            toggle: model.toggleVoiceRecording)
            .frame(width: 88, height: 24)
            .help("Hold to dictate to an agent pane · ⌃⇧Space")
    }
}

struct VoiceDraftView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var voice: VoiceController
    @FocusState private var editorFocused: Bool
    var body: some View {
        if voice.session.isPresented || voice.playbackActive || voice.error != nil {
            VStack(alignment: .leading, spacing: 7) {
                if voice.session.isPresented {
                    HStack {
                        Label(phaseLabel, systemImage: voice.session.captureActive ? "mic.fill" : "text.bubble")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(voice.session.captureActive ? Color.red : Color.accentColor)
                        if let destination = voice.session.destination {
                            Text(destination.label).font(.system(size: 11)).lineLimit(1)
                                .help("Pane \(destination.paneID) · launch \(destination.generation)")
                        }
                        Spacer()
                        if voice.session.captureActive { Button("Stop Recording") { voice.stopRecording() } }
                        Button("Discard") { voice.discard() }.disabled(voice.session.phase == .delivering)
                    }
                    if model.voiceDestinationPane == nil {
                        Text("This destination changed or is unavailable. Select a running agent pane and choose Use Active Pane.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextEditor(text: Binding(get: { voice.session.text }, set: { voice.session.edit($0) }))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 88).padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                        .disabled(voice.session.phase != .review)
                        .focused($editorFocused)
                        .accessibilityLabel("Editable voice transcript")
                    HStack {
                        Text("\(voice.session.text.count) / 8,000 · audio is not saved")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Use Active Pane") { model.useActiveVoiceDestination() }
                            .disabled(voice.session.phase != .review || model.activePane?.kind.isAgent != true)
                        Button("Copy") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(voice.session.text, forType: .string)
                        }.disabled(voice.session.text.isEmpty)
                        Menu("Handoff Draft") {
                            Button("Ask…") { model.composeVoiceHandoff(.ask) }
                            Button("Delegate…") { model.composeVoiceHandoff(.delegate) }
                        }.disabled(!reviewReady)
                        Button("Paste") { model.deliverVoice(submit: false) }
                            .help("Paste the reviewed text without pressing Enter").disabled(!reviewReady)
                        Button("Send") { model.deliverVoice(submit: true) }
                            .help("Paste the reviewed text, then press Enter in the named pane").disabled(!reviewReady)
                    }
                }
                if let message = voice.session.message { Text(message).font(.caption).foregroundStyle(.orange) }
                if let error = voice.error {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss") { voice.error = nil }
                    }
                }
                if voice.playbackActive { VoicePlaybackView(voice: voice) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .buttonStyle(.bordered).controlSize(.small)
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: voice.session.phase) { _, phase in
                if phase == .review { DispatchQueue.main.async { editorFocused = true } }
            }
            Divider()
        }
    }
    private var reviewReady: Bool {
        voice.session.phase == .review && !voice.session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.voiceDestinationPane != nil && !voice.stoppingCapture
    }
    private var phaseLabel: String {
        switch voice.session.phase {
        case .preparing: "Preparing microphone…"
        case .recording: "Recording · release to review"
        case .finishing: "Finishing transcript…"
        case .delivering: "Delivering reviewed text…"
        case .deliveryUncertain: "Check delivery in the pane"
        default: "Review voice transcript"
        }
    }
}

struct VoicePlaybackView: View {
    @ObservedObject var voice: VoiceController
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("Read-aloud", systemImage: "speaker.wave.2").font(.caption)
                Spacer()
                Button("Stop and Clear Queue") { voice.stopSpeaking() }
            }
            ForEach(voice.playback.items) { item in
                HStack {
                    Text(item.id == voice.speakingID ? "Speaking: \(item.label)" : "Queued: \(item.label)")
                        .font(.caption).lineLimit(1)
                    Spacer()
                    if item.id != voice.speakingID { Button("Remove") { voice.removeQueued(item.id) } }
                }
            }
        }
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var voice: VoiceController
    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Language", selection: $voice.language) {
                    Text("English (United Kingdom)").tag("en-GB")
                    Text("English (United States)").tag("en-US")
                }.disabled(voice.session.captureActive || voice.installingModel)
                Text("Hold Dictate or Control–Shift–Space in the main window. Release to edit; Paste and Send are explicit actions. Keyboard and VoiceOver button activation toggles recording.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Each recording is limited to 60 seconds. Use Dictate again to add to the reviewed draft. No raw audio files are saved; drafts are held in memory until sent, discarded or Parley quits.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("On-device speech") {
                Text(voice.support).font(.caption)
                HStack {
                    Button(voice.checkingSupport ? "Checking…" : "Check Speech Support") { voice.checkSupport() }.disabled(voice.checkingSupport)
                    if #available(macOS 26, *) {
                        Button(voice.installingModel ? "Downloading…" : "Download Speech Model") { voice.installModel() }
                            .disabled(voice.installingModel || voice.session.captureActive)
                        if voice.installingModel { Button("Cancel Request") { voice.cancelModelInstallation() } }
                    }
                }
                Text("On macOS 26, Apple manages downloadable local models. Downloading requires a network connection; recognition stays on this Mac. On macOS 14–15, Voice uses local dictation only when the system reports it available. There is no cloud recognition fallback.")
                    .font(.caption).foregroundStyle(.secondary)
                if voice.installingModel {
                    Text("Cancel Request asks macOS to cancel this request. Check Speech Support afterwards for the state of Apple's shared download.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Microphone access is requested when you start recording. Older macOS versions also request Speech Recognition consent. Change access in System Settings > Privacy & Security.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Read-aloud") {
                Toggle("Enable reading selected text and returned results", isOn: $voice.readAloudEnabled)
                Text("Use Voice > Read Selection or Read Result in Status Center. Nothing is spoken automatically. The queue holds three items of up to 8,000 characters. Stop playback before recording.")
                    .font(.caption).foregroundStyle(.secondary)
                if voice.playbackActive { VoicePlaybackView(voice: voice) }
            }
            if let error = voice.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .onAppear { voice.checkSupport() }
    }
}

/// Status Center can be the only visible window. Keep speech controls and
/// recovery beside the result instead of relying on the main workbench.
struct VoiceResultControls: View {
    @ObservedObject var voice: VoiceController
    var read: () -> Void
    var settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Read Result", action: read)
                    .disabled(!voice.readAloudEnabled || voice.session.captureActive || voice.stoppingCapture)
                    .help("Queue this exact returned result for read-aloud")
                Button("Voice Settings…", action: settings)
            }
            if !voice.readAloudEnabled {
                Text("Enable read-aloud in Voice settings to hear this result.").font(.caption).foregroundStyle(.secondary)
            } else if voice.session.captureActive || voice.stoppingCapture {
                Text("Stop recording before reading a result aloud.").font(.caption).foregroundStyle(.secondary)
            }
            if voice.playbackActive { VoicePlaybackView(voice: voice) }
            if let error = voice.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Dismiss") { voice.error = nil }
                }
            }
        }
    }
}
