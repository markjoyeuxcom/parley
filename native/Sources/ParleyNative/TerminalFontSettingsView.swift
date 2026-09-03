import AppKit
import ParleyCore
import SwiftUI

struct TerminalFontSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedFamily: String
    @State private var size: Double
    @State private var overrideSize: Bool
    @State private var importedAppearance: GhosttyAppearanceImport?
    @State private var errorMessage: String?

    private let availableFamilies: [String]
    private let dismissAfterApply: Bool

    init(model: AppModel, dismissAfterApply: Bool = true) {
        self.model = model
        self.dismissAfterApply = dismissAfterApply
        _selectedFamily = State(initialValue: model.terminalFontPreference.family ?? "")
        _size = State(initialValue: model.terminalFontPreference.size ?? model.terminalAppearanceImport?.fontSize ?? 14)
        _overrideSize = State(initialValue: model.terminalFontPreference.size != nil)
        _importedAppearance = State(initialValue: model.terminalAppearanceImport)
        availableFamilies = Self.installedMonospacedFamilies()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminal Appearance")
                    .font(.title2.weight(.semibold))
                Text("Applies to every current and future shell and agent pane. Running processes and vendor sessions remain unchanged.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Font family")
                        .frame(width: 84, alignment: .leading)
                    Picker("Font family", selection: $selectedFamily) {
                        Text(inheritedFamilyLabel).tag("")
                        ForEach(availableFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, 10)

                Divider()

                HStack(spacing: 8) {
                    Text("Font size")
                        .frame(width: 84, alignment: .leading)
                    Spacer()
                    Toggle("Override", isOn: $overrideSize)
                        .toggleStyle(.checkbox)
                    TextField(
                        "Font size",
                        value: $size,
                        format: .number.precision(.fractionLength(0 ... 1))
                    )
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .fontDesign(.monospaced)
                    .disabled(!overrideSize)
                    Stepper(
                        "points",
                        value: $size,
                        in: TerminalFontPreference.minimumSize ... TerminalFontPreference.maximumSize,
                        step: 1
                    )
                    .labelsHidden()
                    .frame(width: 20)
                    .disabled(!overrideSize)
                    Text("pt")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ghostty appearance")
                            .font(.callout.weight(.medium))
                        Text("Only font, theme, palette and colour values are copied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if importedAppearance != nil {
                        Button("Remove") {
                            importedAppearance = nil
                            errorMessage = nil
                        }
                    }
                    Button(importedAppearance == nil ? "Import…" : "Refresh…") {
                        importGhosttyAppearance()
                    }
                }

                if let importedAppearance {
                    Divider()
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(importedAppearance.importedSettingCount) appearance settings")
                        Spacer()
                        Text("\(importedAppearance.ignoredSettingCount) non-appearance settings ignored")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let theme = importedAppearance.themeDescription {
                        Text("Theme: \(theme)")
                            .font(.caption)
                            .lineLimit(1)
                    }
                    Text(importedSourceSummary(importedAppearance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(importedAppearance.sourceFiles.joined(separator: "\n"))
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Parley relay --help   Aa 0123456789 {} []")
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
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Restore Parley Defaults") {
                    applyReset()
                }
                Spacer()
                if dismissAfterApply {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Apply") { applySelection() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var inheritedFamilyLabel: String {
        if let family = importedAppearance?.fontFamily {
            return "Imported — \(family)"
        }
        return "Parley Default"
    }

    private var previewFont: Font {
        let effectiveSize = overrideSize ? size : (importedAppearance?.fontSize ?? 14)
        let effectiveFamily = selectedFamily.isEmpty
            ? importedAppearance?.fontFamily
            : selectedFamily
        if let effectiveFamily {
            return .custom(effectiveFamily, size: effectiveSize)
        }
        return .system(size: effectiveSize, design: .monospaced)
    }

    private var previewColors: GhosttyAppearanceColors? {
        guard let importedAppearance else { return nil }
        return colorScheme == .dark ? importedAppearance.dark : importedAppearance.light
    }

    private var previewBackground: Color {
        Self.color(from: previewColors?.background) ?? Color(nsColor: .textBackgroundColor)
    }

    private var previewForeground: Color {
        Self.color(from: previewColors?.foreground) ?? Color(nsColor: .textColor)
    }

    private func importedSourceSummary(_ appearance: GhosttyAppearanceImport) -> String {
        let names = appearance.sourceFiles.map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        return "Sources: \(names.joined(separator: ", "))"
    }

    private func importGhosttyAppearance() {
        do {
            let appearance = try model.loadGhosttyAppearanceImport()
            importedAppearance = appearance
            if !overrideSize {
                size = appearance.fontSize ?? 14
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applySelection() {
        do {
            try model.updateTerminalAppearance(
                family: selectedFamily.isEmpty ? nil : selectedFamily,
                size: overrideSize ? size : nil,
                imported: importedAppearance
            )
            if dismissAfterApply {
                dismiss()
            }
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

    private func applyReset() {
        do {
            try model.resetTerminalFont()
            selectedFamily = ""
            size = 14
            overrideSize = false
            importedAppearance = nil
            errorMessage = nil
            if dismissAfterApply {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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
