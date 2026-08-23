import ParleyCore
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let snapshot = model.runtimeReadiness {
                    VStack(alignment: .leading, spacing: 20) {
                        readinessSummary(snapshot)
                        readinessSection("LOCAL SYSTEM", items: snapshot.localItems)
                        readinessSection("VENDOR CLIs", items: snapshot.vendorItems)
                        quotaNote
                    }
                    .padding(22)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Checking the local environment…")
                            .font(.system(size: 13, weight: .medium))
                        Text("No model prompt is being sent.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 620, idealHeight: 680)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parley environment check")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Parley Readiness")
                    .font(.system(size: 18, weight: .semibold))
                Text("Local tools and subscription CLIs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.runtimeReadinessChecking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking environment")
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
    }

    private func readinessSummary(_ snapshot: RuntimeReadinessSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: snapshot.isOperational ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(snapshot.isOperational ? Color.accentColor : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.isOperational ? "Ready for cross-vendor work" : "Setup needs attention")
                    .font(.system(size: 14, weight: .semibold))
                Text(summaryDetail(snapshot))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }

    private func readinessSection(_ title: String, items: [RuntimeReadinessItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    readinessRow(item)
                    if index < items.count - 1 { Divider().padding(.leading, 34) }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func readinessRow(_ item: RuntimeReadinessItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: item.state))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color(for: item.state))
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(label(for: item))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color(for: item.state))
                }
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = item.recovery, item.state != .ready {
                    Text(recovery)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(label(for: item)). \(item.detail) \(item.recovery ?? "")")
    }

    private var quotaNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("These checks locate executables, inspect Parley's local files, and use vendor status-only commands. They never submit a prompt or spend model quota. Copilot authentication remains explicitly unchecked because its CLI does not expose a read-only status command.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Check Again") { model.refreshRuntimeReadiness() }
                .disabled(model.runtimeReadinessChecking)
                .accessibilityHint("Repeat the quota-free local readiness checks")
            Spacer()
            Button("Continue") { model.completeEnvironmentCheck() }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Close setup and use Parley")
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    private func summaryDetail(_ snapshot: RuntimeReadinessSnapshot) -> String {
        if snapshot.isOperational {
            return "Parley's local services are ready. Authentication is confirmed for \(snapshot.readyVendorCount) vendor\(snapshot.readyVendorCount == 1 ? "" : "s"); install or sign in to others whenever you need them."
        }
        let localAttention = snapshot.localItems.filter { $0.required && $0.state != .ready }.count
        if localAttention > 0 {
            return "Resolve the local system item\(localAttention == 1 ? "" : "s") below before relying on cross-vendor handoffs. Existing terminal panes remain local and visible."
        }
        return "Parley needs at least two available vendor CLIs for cross-vendor work. You can continue now and return to this check from the Tools menu."
    }

    private func icon(for state: RuntimeReadinessState) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .unavailable: "minus.circle"
        case .unchecked: "questionmark.circle"
        }
    }

    private func color(for state: RuntimeReadinessState) -> Color {
        switch state {
        case .ready: Color.accentColor
        case .attention: Color.orange
        case .unavailable, .unchecked: Color.secondary
        }
    }

    private func label(for item: RuntimeReadinessItem) -> String {
        switch item.state {
        case .ready: "READY"
        case .attention: "ATTENTION"
        case .unavailable: item.required ? "MISSING" : "OPTIONAL"
        case .unchecked: "CHECK ON START"
        }
    }
}
