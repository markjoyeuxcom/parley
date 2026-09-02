import ParleyCore
import SwiftUI

struct ReleaseLifecycleView: View {
    @ObservedObject var model: AppModel
    @State private var section = Section.compatibility

    private enum Section: String, CaseIterable, Hashable {
        case compatibility = "Compatibility"
        case updates = "Updates"
        case feedback = "Beta Feedback"
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: model.runtime)
            if model.runtime.visibleMarker != nil { Divider() }
            header
            Divider()
            Picker("Release lifecycle section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                Group {
                    switch section {
                    case .compatibility: compatibility
                    case .updates: updates
                    case .feedback: feedback
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(22)
            }
            if let message = model.releaseLifecycleMessage {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { model.clearReleaseLifecycleMessage() }
                        .buttonStyle(.link)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 680, idealHeight: 760)
        .sheet(isPresented: $model.betaFeedbackPresented) {
            BetaFeedbackReviewView(model: model)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Compatibility & Releases")
                    .font(.system(size: 18, weight: .semibold))
                Text("Explicit checks, verified downloads and reviewed local feedback")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 66)
    }

    private var compatibility: some View {
        VStack(alignment: .leading, spacing: 18) {
            lifecycleHeading(
                "Vendor compatibility",
                detail: "Version-only checks report the adapter contracts Parley can support. They submit no prompt, inspect no vendor configuration and spend no model quota."
            )
            HStack {
                Button("Check Again") { model.refreshRuntimeReadiness() }
                    .disabled(model.vendorCompatibilityChecking)
                if model.vendorCompatibilityChecking {
                    ProgressView().controlSize(.small)
                }
            }

            if let snapshot = model.vendorCompatibility {
                VStack(spacing: 8) {
                    ForEach(snapshot.vendors) { result in
                        vendorRow(result)
                    }
                }
                Text("Checked \(snapshot.checkedAt.formatted(date: .abbreviated, time: .standard)). A version-change badge means the installed CLI changed since the previous recorded check; it does not claim runtime behavior passed.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if !snapshot.runtimeSignals.isEmpty {
                    Divider()
                    lifecycleHeading(
                        "Existing pane runtime signals",
                        detail: "Ready, working and awaiting-permission appear only after a pane capability reports a structured signal. Claude and Codex have session-scoped adapters. Copilot attachment is configured, but remains Unknown unless its CLI actually executes the plugin hook. Agy has no verified per-launch hook path. Parley can state an exit because it owns the process lifecycle."
                    )
                    VStack(spacing: 7) {
                        ForEach(snapshot.runtimeSignals) { signal in
                            runtimeSignalRow(signal)
                        }
                    }
                }
            } else {
                ProgressView("Checking installed CLIs without submitting prompts…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

        }
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 18) {
            lifecycleHeading(
                "Signed stable updates",
                detail: "Installed notarized builds use Sparkle with a fixed HTTPS feed, Ed25519-signed feed and archive, and Developer ID verification. Automatic checking is opt-in; download, replacement and restart are never silent."
            )
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if model.automaticUpdatesAvailable {
                        HStack {
                            Toggle(
                                "Check for stable updates automatically",
                                isOn: Binding(
                                    get: { model.automaticUpdateChecksEnabled },
                                    set: { model.setAutomaticUpdateChecksEnabled($0) }
                                )
                            )
                            Spacer()
                            Button("Check Now…") { model.checkForStableAutomaticUpdate() }
                                .disabled(!model.automaticUpdateCanCheck)
                        }
                    } else {
                        Label("Automatic update channel unavailable", systemImage: "lock.shield")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(model.automaticUpdateDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            Divider()
            lifecycleHeading(
                "Manual release browser",
                detail: "Use this explicit GitHub path for beta releases or to save a stable DMG after Parley verifies its published manifest and SHA-256. It never installs or restarts the app."
            )
            HStack(spacing: 12) {
                Picker("Channel", selection: Binding(
                    get: { model.releaseChannel },
                    set: { model.setReleaseChannel($0) }
                )) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.label).tag(channel)
                    }
                }
                .frame(width: 210)
                Text(model.releaseChannel.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Releases") { model.openReleasesPage() }
                Button("Check GitHub") { model.checkForUpdates() }
                    .disabled(model.releaseChecking)
            }
            if model.releaseChecking {
                ProgressView("Reading published release metadata…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let result = model.releaseCheck {
                releaseResult(result)
            } else {
                ContentUnavailableView(
                    "No Update Check Yet",
                    systemImage: "arrow.down.circle",
                    description: Text("Choose Stable or Beta, then check explicitly.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }
            Text("The manual GitHub check uses no credential. A private releases repository is therefore invisible to it; Open Releases uses your signed-in browser instead.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 18) {
            lifecycleHeading(
                "Reviewed beta feedback bundle",
                detail: "Build facts, semantic vendor versions, compatibility outcomes and structurally redacted diagnostics can be exported to a local ZIP after you inspect the exact field list. Nothing is uploaded."
            )

            GroupBox("Included") {
                bulletList([
                    "Application version, build number, source commit, runtime and selected update channel",
                    "Installed vendor semantic versions and quota-free compatibility outcomes",
                    "The existing privacy-bounded diagnostics report",
                ])
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            GroupBox("Excluded by structure") {
                bulletList([
                    "Prompts, delegated instructions, answers and result bodies",
                    "Terminal contents, selections, titles, commands and working folders",
                    "Pane and workspace display names",
                    "Credentials, tokens, sockets, raw journals, raw logs, browser profiles and subscription data",
                ])
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            HStack {
                Spacer()
                Button("Review Exact Bundle…") { model.prepareBetaFeedbackReview() }
                    .disabled(model.vendorCompatibility == nil)
            }
        }
    }

    private func vendorRow(_ result: VendorCompatibilityResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.vendor.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(result.version.map { "v\($0)" } ?? "version unknown")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if result.versionChanged {
                    Text("CLI CHANGED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(result.state.label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(result.state == .compatible ? Color.accentColor : Color.orange)
            }
            HStack(spacing: 6) {
                ForEach(result.capabilities, id: \.capability.rawValue) { capability in
                    Text("\(capability.capability.label) · \(capability.support.label)")
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                        }
                }
            }
            Text(result.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func runtimeSignalRow(_ signal: VendorRuntimeSignal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: signal.state == .exited ? "xmark.circle" : "questionmark.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(signal.vendor.label) · \(signal.paneID)")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(signal.state.label.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(signal.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if let reportedAt = signal.reportedAt {
                    Text("Reported \(reportedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
    }

    private func releaseResult(_ result: ReleaseCheckResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.release.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text("Current: \(result.currentVersion) · Offered: \(result.release.version) · \(updateLabel(result.updateState))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(result.release.prerelease ? "BETA" : "STABLE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(result.release.prerelease ? Color.orange : Color.accentColor)
            }
            GroupBox("Verified artifact metadata") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    verificationRow("DMG", result.verification.dmgName)
                    verificationRow("Bytes", result.verification.byteCount.formatted())
                    verificationRow("SHA-256", result.verification.sha256)
                    verificationRow("Trust", result.verification.trustLabel)
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 6)
            }
            Text("GitHub's release asset list, Parley's release manifest and SHA256SUMS agree. Download and Verify additionally hashes the complete DMG before saving it.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if !result.release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Release notes")
                    .font(.system(size: 12, weight: .semibold))
                Text(result.release.body)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("View on GitHub") { model.openCheckedReleasePage() }
                Spacer()
                if model.releaseDownloading { ProgressView().controlSize(.small) }
                Button("Download and Verify DMG…") { model.downloadCheckedRelease() }
                    .disabled(model.releaseDownloading)
            }
            Text("The download-only action cannot install the app or stop coordination. Finish tracked work and quit Parley before replacing the application.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func lifecycleHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(Color.accentColor)
                    Text(item).font(.system(size: 11))
                }
            }
        }
    }

    @ViewBuilder
    private func verificationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(value).lineLimit(2)
        }
    }

    private func updateLabel(_ state: ReleaseUpdateState) -> String {
        switch state {
        case .available: "update available"
        case .current: "current"
        case .newerThanChannel: "this build is newer"
        case .unknown: "comparison unavailable"
        }
    }
}

private struct BetaFeedbackReviewView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Beta Feedback Bundle")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Nothing leaves this Mac unless you export and then share the ZIP yourself.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            if let bundle = model.betaFeedbackBundle {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        GroupBox("Build") {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                                reviewRow("Version", bundle.manifest.build.applicationVersion)
                                reviewRow("Build", bundle.manifest.build.buildNumber)
                                reviewRow("Commit", bundle.manifest.build.sourceCommit ?? "unavailable")
                                reviewRow("Runtime", bundle.manifest.build.runtime)
                                reviewRow("Channel", bundle.manifest.updateChannel.label)
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                        }
                        GroupBox("Vendor compatibility") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(bundle.manifest.vendors, id: \.vendor.rawValue) { vendor in
                                    Text("\(vendor.vendor.label) · \(vendor.version ?? "unknown") · \(vendor.state.label)")
                                        .font(.system(size: 10, design: .monospaced))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        GroupBox("Excluded by structure") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(bundle.manifest.excludedByDesign, id: \.self) { item in
                                    Text("• \(item)").font(.system(size: 10))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                        Text("The ZIP contains feedback.json, diagnostics.json and README.txt. Review them again before sharing; Parley has no upload or telemetry path.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView("No feedback bundle", systemImage: "doc.badge.gearshape")
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.betaFeedbackExporting { ProgressView().controlSize(.small) }
                Button("Export Reviewed Bundle…") { model.exportReviewedBetaFeedback() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.betaFeedbackBundle == nil || model.betaFeedbackExporting)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 620, idealHeight: 690)
    }

    @ViewBuilder
    private func reviewRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
            Text(value)
        }
    }
}
