import AppKit
import ParleyCore
import SwiftUI

/// Settings › Appearance: the shared pane font, the imported Ghostty
/// appearance and the Ghostty surface options about how a pane looks (theme
/// and colours, font rendering, background and padding). Every change
/// applies at once to every surface and is saved, the same convention as the
/// rest of Settings; there is no Apply button. Restore Parley Defaults puts
/// the whole tab back: the Parley default font, no import, and Ghostty's
/// defaults for this tab's options. The form is flexible so a wider window
/// gets wider controls.
struct AppearanceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedFamily: String
    @State private var size: Double
    @State private var overrideSize: Bool
    @State private var errorMessage: String?
    @State private var importError: String?

    private let availableFamilies: [String]

    init(model: AppModel) {
        self.model = model
        _selectedFamily = State(initialValue: model.terminalFontPreference.family ?? "")
        _size = State(initialValue: model.terminalFontPreference.size ?? model.terminalAppearanceImport?.fontSize ?? 14)
        _overrideSize = State(initialValue: model.terminalFontPreference.size != nil)
        availableFamilies = Self.installedMonospacedFamilies()
    }

    var body: some View {
        Form {
            fontSection
            importSection
            TerminalSurfaceSettingsSections(model: model, tab: .appearance)
            Section {
                HStack {
                    Spacer()
                    Button("Restore Parley Defaults") { restoreDefaults() }
                        .disabled(isAtDefaults)
                        .help("Parley default font, no imported appearance, and Ghostty's defaults for the options on this tab")
                }
            } footer: {
                Text("Puts the Parley default font back, removes the imported appearance and restores the theme, font rendering, background and padding options to Ghostty's defaults. The cursor, scrollback, mouse and shell integration options are restored from Settings > Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .onChange(of: selectedFamily) { _, _ in applyFont() }
        .onChange(of: overrideSize) { _, _ in applyFont() }
        .onChange(of: size) { _, _ in applyFont() }
        .onChange(of: model.terminalFontPreference) { _, stored in syncFont(stored) }
        .onChange(of: model.terminalAppearanceImport) { _, imported in
            if !overrideSize { size = imported?.fontSize ?? 14 }
        }
    }

    // MARK: Font

    private var fontSection: some View {
        Section {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Picker("Font family", selection: $selectedFamily) {
                Text(inheritedFamilyLabel).tag("")
                ForEach(availableFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .pickerStyle(.menu)
            .help("A fixed-pitch family installed on this Mac; Parley Default follows the imported family or the system monospaced font")
            LabeledContent("Font size") {
                Toggle("Override", isOn: $overrideSize)
                    .toggleStyle(.checkbox)
                TextField("Font size", value: $size, format: .number.precision(.fractionLength(0 ... 1)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .labelsHidden()
                    .disabled(!overrideSize)
                Stepper("Font size", value: $size, in: TerminalFontPreference.minimumSize ... TerminalFontPreference.maximumSize, step: 1)
                    .labelsHidden()
                    .frame(width: 20)
                    .disabled(!overrideSize)
                Text("pt").foregroundStyle(.secondary)
            }
            Text("Your explicit font choices take precedence over imported values. With Override off the size follows the import, or 14 points. Running processes and vendor sessions are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("parley relay --help   Aa 0123456789 {} []")
                    .font(previewFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .foregroundStyle(previewForeground)
                    .background(previewBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel("Font preview")
            }
        } header: {
            HStack {
                Text("Font")
                Spacer()
                Text("Current and new panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inheritedFamilyLabel: String {
        if let family = model.terminalAppearanceImport?.fontFamily {
            return "Imported — \(family)"
        }
        return "Parley Default"
    }

    private var previewFont: Font {
        let effectiveSize = overrideSize ? size : (model.terminalAppearanceImport?.fontSize ?? 14)
        let effectiveFamily = selectedFamily.isEmpty ? model.terminalAppearanceImport?.fontFamily : selectedFamily
        if let effectiveFamily {
            return .custom(effectiveFamily, size: effectiveSize)
        }
        return .system(size: effectiveSize, design: .monospaced)
    }

    private var previewColors: GhosttyAppearanceColors? {
        guard let imported = model.terminalAppearanceImport else { return nil }
        return colorScheme == .dark ? imported.dark : imported.light
    }

    private var previewBackground: Color {
        Self.color(from: previewColors?.background) ?? Color(nsColor: .textBackgroundColor)
    }

    private var previewForeground: Color {
        Self.color(from: previewColors?.foreground) ?? Color(nsColor: .textColor)
    }

    /// The font the controls describe, clamped to the allowed size range so a
    /// typed value out of range is corrected rather than refused.
    private var requestedFont: (family: String?, size: Double?) {
        let family = selectedFamily.isEmpty ? nil : selectedFamily
        guard overrideSize else { return (family, nil) }
        let clamped = min(max(size, TerminalFontPreference.minimumSize), TerminalFontPreference.maximumSize)
        return (family, clamped)
    }

    private func applyFont() {
        let requested = requestedFont
        if let clamped = requested.size, clamped != size {
            size = clamped
            return
        }
        let stored = model.terminalFontPreference
        guard requested.family != stored.family || requested.size != stored.size else { return }
        do {
            try model.updateTerminalAppearance(family: requested.family, size: requested.size, imported: model.terminalAppearanceImport)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            syncFont(stored)
        }
    }

    private func syncFont(_ stored: TerminalFontPreference) {
        let family = stored.family ?? ""
        if selectedFamily != family { selectedFamily = family }
        let override = stored.size != nil
        if overrideSize != override { overrideSize = override }
        let shown = stored.size ?? model.terminalAppearanceImport?.fontSize ?? 14
        if size != shown { size = shown }
    }

    // MARK: Imported Ghostty appearance

    private var importSection: some View {
        Section {
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Text("Only font, theme, palette and colour values are copied from Ghostty's configuration and theme files. Commands, keybindings, shell integration, config-file includes and other behavioural settings are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.terminalAppearanceImport != nil {
                    Button("Remove") { setImport(nil) }
                        .help("Stop using the imported Ghostty appearance")
                }
                Button(model.terminalAppearanceImport == nil ? "Import…" : "Refresh…") { importGhosttyAppearance() }
                    .help("Read the supported Ghostty configuration and theme locations and apply the appearance values at once")
            }
            if let imported = model.terminalAppearanceImport {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(imported.importedSettingCount) appearance settings")
                    Spacer()
                    Text("\(imported.ignoredSettingCount) non-appearance settings ignored")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let theme = imported.themeDescription {
                    Text("Theme: \(theme)")
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(importedSourceSummary(imported))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(imported.sourceFiles.joined(separator: "\n"))
                Text("While an import is in use its colours take precedence over the catalogue themes below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Imported Ghostty appearance")
                Spacer()
                Text("Current and new panes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func importedSourceSummary(_ appearance: GhosttyAppearanceImport) -> String {
        let names = appearance.sourceFiles.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "Sources: \(names.joined(separator: ", "))"
    }

    private func importGhosttyAppearance() {
        do {
            let appearance = try model.loadGhosttyAppearanceImport()
            setImport(appearance)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func setImport(_ imported: GhosttyAppearanceImport?) {
        do {
            try model.updateTerminalAppearance(family: requestedFont.family, size: requestedFont.size, imported: imported)
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Restore

    private var isAtDefaults: Bool {
        model.terminalFontPreference == .ghosttyDefault
            && model.terminalAppearanceImport == nil
            && model.terminalSurfacePreference.resetting(TerminalSurfaceSection.sections(in: .appearance)) == model.terminalSurfacePreference
    }

    private func restoreDefaults() {
        do {
            try model.updateTerminalSurfacePreference(model.terminalSurfacePreference.resetting(TerminalSurfaceSection.sections(in: .appearance)))
            try model.resetTerminalFont()
            errorMessage = nil
            importError = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func color(from value: String?) -> Color? {
        guard let value else { return nil }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt64(hex, radix: 16) else { return nil }
        return Color(
            nsColor: NSColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: 1
            )
        )
    }

    private static func installedMonospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { family in
                let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
                return members.contains { member in
                    guard let name = member.first as? String,
                          let font = NSFont(name: name, size: 14) else { return false }
                    return font.isFixedPitch
                }
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
