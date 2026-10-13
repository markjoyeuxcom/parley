import ParleyCore
import SwiftUI

/// The curated Ghostty surface options as Form sections. Settings › Appearance
/// shows the sections about how a pane looks (theme and colours, font
/// rendering, background and padding) beside the font and the imported
/// colours; Settings › Terminal shows how a pane behaves (cursor, scrollback,
/// mouse and clipboard, shell integration) beside the terminal type. Every
/// change applies at once to every surface and is kept; when Ghostty refuses
/// a value the message appears beside the section that caused it and the
/// form keeps what it had. Each section's header says when a change reaches
/// a pane.
struct TerminalSurfaceSettingsSections: View {
    @ObservedObject var model: AppModel
    let tab: ApplicationSettingsSection
    /// The title of a footer button that puts this tab's sections back to
    /// Ghostty's defaults; nil when the tab's own footer does that.
    let restoreTitle: String?
    @State private var draft: TerminalSurfacePreference
    @State private var errorMessage: String?
    /// The section whose fields the refused change touched, so the message
    /// appears beside the control that caused it rather than at the bottom
    /// of a long form.
    @State private var errorSection: TerminalSurfaceSection?
    private let themeNames: [String]

    init(model: AppModel, tab: ApplicationSettingsSection, restoreTitle: String? = nil) {
        self.model = model
        self.tab = tab
        self.restoreTitle = restoreTitle
        _draft = State(initialValue: model.terminalSurfacePreference)
        themeNames = model.ghosttyThemeNames
    }

    private var sections: [TerminalSurfaceSection] { TerminalSurfaceSection.sections(in: tab) }

    var body: some View {
        Group {
            if sections.contains(.theme) { themeSection }
            if sections.contains(.font) { fontSection }
            if sections.contains(.cursor) { cursorSection }
            if sections.contains(.background) { backgroundSection }
            if sections.contains(.scrollback) { scrollbackSection }
            if sections.contains(.mouse) { mouseSection }
            if sections.contains(.shell) { shellSection }
            if let restoreTitle { restoreSection(restoreTitle) }
        }
        .onChange(of: draft) { _, requested in apply(requested) }
        .onChange(of: model.terminalSurfacePreference) { _, stored in
            if stored != draft { draft = stored }
        }
    }

    private var themeSection: some View {
        surfaceSection(.theme) {
            let imported = model.terminalAppearanceImport != nil
            themePicker("Light appearance theme", selection: $draft.lightTheme)
                .disabled(imported)
            themePicker("Dark appearance theme", selection: $draft.darkTheme)
                .disabled(imported)
            if imported {
                HStack {
                    Text("An imported Ghostty appearance supplies the colours, so these catalogue themes are not applied until it is removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Imported Appearance") {
                        removeImportedAppearance()
                    }
                    .help("Stop using the imported Ghostty colours; the catalogue themes apply again")
                }
            } else {
                Text("A theme from Ghostty's bundled catalogue, chosen separately for the light and dark appearance. Ghostty default keeps the wrapper's own themes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    }

    private var fontSection: some View {
        surfaceSection(.font) {
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
    }

    private var cursorSection: some View {
        surfaceSection(.cursor) {
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
    }

    private var backgroundSection: some View {
        surfaceSection(.background) {
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
    }

    private var scrollbackSection: some View {
        surfaceSection(.scrollback) {
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
    }

    private var mouseSection: some View {
        surfaceSection(.mouse) {
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
                Text(draft.scrollMultiplier.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Device")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private var shellSection: some View {
        surfaceSection(.shell) {
            Toggle("Cursor shape follows the prompt", isOn: $draft.shellCursor)
            Toggle("Shell integration under sudo", isOn: $draft.shellSudo)
            Toggle("Pane title from the shell", isOn: $draft.shellTitle)
            Toggle("Add Ghostty's scripts to PATH", isOn: $draft.shellPath)
            Text("Features of the shell integration Ghostty installs in new shells. Changes reach shells started afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func restoreSection(_ title: String) -> some View {
        Section {
            HStack {
                if let errorMessage, errorSection == nil {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(title) {
                    draft = draft.resetting(sections)
                }
                .disabled(draft.resetting(sections) == draft)
            }
        } footer: {
            Text("Puts the options above back to Ghostty's defaults. Every option here is one of a fixed set Parley writes for Ghostty; none can name a program, a file or an environment variable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A section whose header names when a change reaches a pane, and whose
    /// first row is the refusal Ghostty gave for a change to its fields.
    private func surfaceSection<Content: View>(_ section: TerminalSurfaceSection, @ViewBuilder content: () -> Content) -> some View {
        Section {
            sectionError(section)
            content()
        } header: {
            HStack {
                Text(section.title)
                Spacer()
                Text(section.scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(section.title) applies to \(section.scope.lowercased())")
            }
        }
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

    private func themePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue ?? "" }, set: { selection.wrappedValue = $0.isEmpty ? nil : $0 })) {
            Text("Ghostty default").tag("")
            Divider()
            ForEach(themeNames, id: \.self) { name in Text(name).tag(name) }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(title)
    }

    private func removeImportedAppearance() {
        do {
            try model.updateTerminalAppearance(
                family: model.terminalFontPreference.family,
                size: model.terminalFontPreference.size,
                imported: nil
            )
            errorMessage = nil
            errorSection = nil
        } catch {
            errorMessage = error.localizedDescription
            errorSection = .theme
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
