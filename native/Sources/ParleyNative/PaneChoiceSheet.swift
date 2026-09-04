import ParleyCore
import SwiftUI

/// A native replacement for the picker-in-alert pattern: one explicit choice
/// of pane or panes, with the same candidates, minimums and labels the alert
/// used. Nothing is sent from here; the completion continues the original
/// flow exactly as the alert's Continue button did.
struct PaneChoiceRequest: Identifiable {
    enum Selection: Equatable {
        case single(preferredPaneID: String?)
        case multiple(minimum: Int)
    }

    let id = UUID()
    let title: String
    let message: String
    let actionLabel: String
    let candidates: [WorkbenchPane]
    let selection: Selection
    let completion: ([WorkbenchPane]) -> Void
}

struct PaneChoiceSheet: View {
    @ObservedObject var model: AppModel
    let request: PaneChoiceRequest
    @State private var chosen: Set<String>

    init(model: AppModel, request: PaneChoiceRequest) {
        self.model = model
        self.request = request
        switch request.selection {
        case let .single(preferredPaneID):
            let preferred = preferredPaneID.flatMap { id in request.candidates.first(where: { $0.id == id })?.id }
            _chosen = State(initialValue: Set([preferred ?? request.candidates.first?.id].compactMap { $0 }))
        case .multiple:
            _chosen = State(initialValue: Set(request.candidates.map(\.id)))
        }
    }

    private var minimum: Int {
        switch request.selection {
        case .single: 1
        case let .multiple(minimum): minimum
        }
    }

    private var isMultiple: Bool {
        if case .multiple = request.selection { return true }
        return false
    }

    private var selectedPanes: [WorkbenchPane] {
        request.candidates.filter { chosen.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(.title3.weight(.semibold))
                Text(request.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(request.candidates) { pane in
                    Button {
                        toggle(pane)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isMultiple
                                ? (chosen.contains(pane.id) ? "checkmark.square.fill" : "square")
                                : (chosen.contains(pane.id) ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(chosen.contains(pane.id) ? Color.accentColor : Color.secondary)
                                .frame(width: 16)
                            ChromeMonogram(kind: pane.kind)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(pane.displayName)
                                        .font(ChromeFont.bodyMedium)
                                    Text(pane.kind.label)
                                        .font(ChromeFont.secondary)
                                        .foregroundStyle(.secondary)
                                    if let role = pane.role {
                                        Text("@\(role)")
                                            .font(ChromeFont.meta)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text([pane.workspaceName, pane.id].compactMap { $0 }.joined(separator: " · "))
                                    .font(ChromeFont.meta)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(pane.displayName), \(pane.kind.label) pane\(pane.workspaceName.map { " in \($0)" } ?? "")")
                    .accessibilityValue(chosen.contains(pane.id) ? "Selected" : "Not selected")
                    .accessibilityAddTraits(chosen.contains(pane.id) ? [.isSelected] : [])
                    if pane.id != request.candidates.last?.id { Divider() }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }

            HStack {
                Text(isMultiple
                    ? "\(selectedPanes.count) selected · at least \(minimum) required"
                    : "One explicit target")
                    .font(ChromeFont.meta)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelPaneChoice() }
                    .keyboardShortcut(.cancelAction)
                Button(request.actionLabel) { model.resolvePaneChoice(selectedPanes) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedPanes.count < minimum)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func toggle(_ pane: WorkbenchPane) {
        if isMultiple {
            if chosen.contains(pane.id) { chosen.remove(pane.id) } else { chosen.insert(pane.id) }
        } else {
            chosen = [pane.id]
        }
    }
}
