import AppKit
import ParleyCore
import SwiftUI

struct TerminalFontSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFamily: String
    @State private var size: Double
    @State private var errorMessage: String?

    private let availableFamilies: [String]

    init(model: AppModel) {
        self.model = model
        _selectedFamily = State(initialValue: model.terminalFontPreference.family ?? "")
        _size = State(initialValue: model.terminalFontPreference.size ?? 14)
        availableFamilies = Self.installedMonospacedFamilies()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Terminal Font")
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
                        Text("Ghostty Default").tag("")
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
                    TextField(
                        "Font size",
                        value: $size,
                        format: .number.precision(.fractionLength(0 ... 1))
                    )
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .fontDesign(.monospaced)
                    Stepper(
                        "points",
                        value: $size,
                        in: TerminalFontPreference.minimumSize ... TerminalFontPreference.maximumSize,
                        step: 1
                    )
                    .labelsHidden()
                    .frame(width: 20)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Parley relay --help   Aa 0123456789 {} []")
                    .font(previewFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
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
                Button("Reset to Ghostty Defaults") {
                    applyReset()
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applySelection() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var previewFont: Font {
        if selectedFamily.isEmpty {
            return .system(size: size, design: .monospaced)
        }
        return .custom(selectedFamily, size: size)
    }

    private func applySelection() {
        do {
            try model.updateTerminalFont(
                family: selectedFamily.isEmpty ? nil : selectedFamily,
                size: size
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyReset() {
        do {
            try model.resetTerminalFont()
            dismiss()
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
