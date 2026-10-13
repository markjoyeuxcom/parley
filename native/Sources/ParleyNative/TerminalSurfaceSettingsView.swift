import ParleyCore
import SwiftUI

/// The curated Ghostty surface options, as Form sections inside Settings ›
/// Terminal. Every change applies at once to every surface and is kept;
/// when Ghostty refuses a value the form says so and keeps what it had. The
/// two options Ghostty reads only when a surface is created say so beside
/// their control.
struct TerminalSurfaceSettingsSections: View {
    @ObservedObject var model: AppModel
    @State private var draft: TerminalSurfacePreference
    @State private var errorMessage: String?
    /// The section whose fields the refused change touched, so the message
    /// appears beside the control that caused it rather than at the bottom
    /// of a long form.
    @State private var errorSection: TerminalSurfaceSection?
    private let themeNames: [String]

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.terminalSurfacePreference)
        themeNames = model.ghosttyThemeNames
    }

    var body: some View {
        Section("Theme and colours") {
            sectionError(.theme)
            themePicker("Light appearance theme", selection: $draft.lightTheme)
            themePicker("Dark appearance theme", selection: $draft.darkTheme)
            Text(model.terminalAppearanceImport == nil
                 ? "A theme from Ghostty's bundled catalogue, chosen separately for the light and dark appearance. Ghostty default keeps the wrapper's own themes."
                 : "An imported Ghostty appearance is in use (Settings > Appearance), so its colours take precedence over these themes until it is removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Minimum contrast") {
                Slider(value: $draft.minimumContrast, in: TerminalSurfacePreference.minimumContrastRange, step: 0.1) {
                    Text("Minimum contrast")
                } minimumValueLabel: { Text("1") } maximumValueLabel: { Text("21") }
                .frame(width: 220)
                .accessibilityLabel("Minimum contrast")
                Text(draft.minimumContrast.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            Text("Ghostty lightens or darkens text that would be too close to its background. 1 leaves colours as the theme sets them; 1.1 avoids invisible text; 3 or more makes faint text black or white.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Font rendering") {
            sectionError(.font)
            Toggle("Thicken glyph strokes", isOn: $draft.fontThicken)
            LabeledContent("Thickening strength") {
                Slider(value: Binding(get: { Double(draft.fontThickenStrength) }, set: { draft.fontThickenStrength = Int($0.rounded()) }),
                       in: Double(TerminalSurfacePreference.thickenStrengthRange.lowerBound) ... Double(TerminalSurfacePreference.thickenStrengthRange.upperBound),
                       step: 1) { Text("Thickening strength") }
                    .frame(width: 220)
                    .disabled(!draft.fontThicken)
                    .accessibilityLabel("Thickening strength")
                Text(String(draft.fontThickenStrength)).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Toggle("Programming ligatures", isOn: $draft.ligatures)
            Text("Off disables the font's calt, liga and dlig features, so sequences such as -> and != stay as separate characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Line height adjustment") {
                Stepper(value: $draft.cellHeightAdjustment, in: TerminalSurfacePreference.cellHeightAdjustmentRange, step: 5) {
                    Text("\(draft.cellHeightAdjustment)%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .accessibilityLabel("Line height adjustment")
            }
        }

        Section("Cursor") {
            sectionError(.cursor)
            Picker("Shape", selection: $draft.cursorShape) {
                ForEach(TerminalCursorShape.allCases) { shape in Text(shape.label).tag(shape) }
            }
            .pickerStyle(.menu)
            Picker("Blink", selection: $draft.cursorBlink) {
                ForEach(TerminalCursorBlink.allCases) { blink in Text(blink.label).tag(blink) }
            }
            .pickerStyle(.menu)
            Text("A program can still change the cursor's shape and blink while it runs; Ghostty restores these when it finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Opacity") {
                Slider(value: $draft.cursorOpacity, in: TerminalSurfacePreference.cursorOpacityRange, step: 0.05) { Text("Cursor opacity") }
                    .frame(width: 220)
                    .accessibilityLabel("Cursor opacity")
                Text(draft.cursorOpacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }

        Section("Background and padding") {
            sectionError(.background)
            LabeledContent("Background opacity") {
                Slider(value: $draft.backgroundOpacity, in: TerminalSurfacePreference.backgroundOpacityRange, step: 0.05) { Text("Background opacity") }
                    .frame(width: 220)
                    .accessibilityLabel("Background opacity")
                Text(draft.backgroundOpacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            LabeledContent("Background blur") {
                Stepper(value: $draft.backgroundBlur, in: TerminalSurfacePreference.backgroundBlurRange, step: 4) {
                    Text(draft.backgroundBlur == 0 ? "Off" : "\(draft.backgroundBlur)").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                .disabled(draft.backgroundOpacity >= 1)
                .accessibilityLabel("Background blur")
            }
            Text("Opacity and blur take effect for panes created afterwards; a running pane keeps the background it was created with. Blur needs an opacity below 100%.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Padding") {
                Stepper(value: $draft.paddingX, in: TerminalSurfacePreference.paddingRange) {
                    Text("Horizontal \(draft.paddingX) px").monospacedDigit()
                }
                .accessibilityLabel("Horizontal padding")
                Stepper(value: $draft.paddingY, in: TerminalSurfacePreference.paddingRange) {
                    Text("Vertical \(draft.paddingY) px").monospacedDigit()
                }
                .accessibilityLabel("Vertical padding")
            }
        }

        Section("Scrollback") {
            sectionError(.scrollback)
            LabeledContent("Scrollback limit") {
                TextField("Scrollback limit", value: $draft.scrollbackLimitMegabytes, format: .number)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .labelsHidden()
                Stepper("MB", value: $draft.scrollbackLimitMegabytes, in: TerminalSurfacePreference.scrollbackMegabytesRange, step: 10)
                    .labelsHidden()
                    .frame(width: 20)
                Text("MB").foregroundStyle(.secondary)
            }
            Text("The uncompressed history each pane keeps, 1 to 1000 MB (Ghostty's default is 50). It is read when a pane is created, so panes created afterwards use the new limit and running panes keep theirs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Mouse and clipboard") {
            sectionError(.mouse)
            Toggle("Hide the pointer while typing", isOn: $draft.hideMouseWhileTyping)
            Toggle("Click moves the cursor at a shell prompt", isOn: $draft.clickToMoveCursor)
            Toggle("Copy selected text to the clipboard", isOn: $draft.copyOnSelect)
            Toggle("Confirm before pasting text with newlines", isOn: $draft.pasteProtection)
            Toggle("Detect URLs under the pointer", isOn: $draft.linkDetection)
            Text("Parley still opens a detected link only when you click it with Command held, and only http or https with a host.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Scroll speed") {
                Toggle("Override", isOn: Binding(get: { draft.scrollMultiplier != nil }, set: { draft.scrollMultiplier = $0 ? 3 : nil }))
                    .toggleStyle(.checkbox)
                Slider(value: Binding(get: { draft.scrollMultiplier ?? 3 }, set: { draft.scrollMultiplier = $0 }),
                       in: 0.1 ... 10, step: 0.1) { Text("Scroll speed") }
                    .frame(width: 160)
                    .disabled(draft.scrollMultiplier == nil)
                    .accessibilityLabel("Scroll speed")
                Text((draft.scrollMultiplier ?? 3).formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 36, alignment: .trailing)
            }
            Text("Lines per wheel step. Left alone, Ghostty uses 3 for a mouse wheel and 1 for a trackpad.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Shell integration") {
            sectionError(.shell)
            Toggle("Cursor shape follows the prompt", isOn: $draft.shellCursor)
            Toggle("Shell integration under sudo", isOn: $draft.shellSudo)
            Toggle("Pane title from the shell", isOn: $draft.shellTitle)
            Toggle("Add Ghostty's scripts to PATH", isOn: $draft.shellPath)
            Text("Features of the shell integration Ghostty installs in new shells. Changes reach shells started afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            HStack {
                if let errorMessage, errorSection == nil {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Restore Ghostty Defaults") {
                    draft = .ghosttyDefault
                }
                .disabled(draft == .ghosttyDefault)
            }
        } footer: {
            Text("Every option here is one of a fixed set Parley writes for Ghostty; none can name a program, a file or an environment variable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: draft) { _, requested in apply(requested) }
        .onChange(of: model.terminalSurfacePreference) { _, stored in
            if stored != draft { draft = stored }
        }
    }

    private func themePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue ?? "" }, set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text("Ghostty default").tag("")
            Divider()
            ForEach(themeNames, id: \.self) { name in Text(name).tag(name) }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func sectionError(_ section: TerminalSurfaceSection) -> some View {
        if let errorMessage, errorSection == section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .accessibilityLabel("Ghostty refused the change: \(errorMessage)")
        }
    }

    private func apply(_ requested: TerminalSurfacePreference) {
        let stored = model.terminalSurfacePreference
        guard requested != stored else { return }
        do {
            try model.updateTerminalSurfacePreference(requested)
            errorMessage = nil
            errorSection = nil
        } catch {
            errorMessage = error.localizedDescription
            errorSection = TerminalSurfaceSection.changed(from: stored, to: requested).first
            draft = stored
        }
    }
}
