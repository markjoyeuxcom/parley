import Foundation

public enum AgentLaunchMode: String, Codable, Equatable, Sendable {
    case fresh
    case resume
}

public enum VendorResumeSelection: String, Codable, Equatable, Sendable {
    case vendorPicker
    case mostRecentInWorkingDirectory
}

/// Describes only a vendor's documented process-launch continuation surface.
/// Parley never reads vendor session stores, chooses a conversation, or claims
/// that the selected history was restored.
public struct VendorResumePlan: Equatable, Sendable {
    public let vendor: PaneKind
    public let selection: VendorResumeSelection
    public let menuLabel: String
    public let confirmationLabel: String
    public let detail: String

    public init(
        vendor: PaneKind,
        selection: VendorResumeSelection,
        menuLabel: String,
        confirmationLabel: String,
        detail: String
    ) {
        self.vendor = vendor
        self.selection = selection
        self.menuLabel = menuLabel
        self.confirmationLabel = confirmationLabel
        self.detail = detail
    }
}

public enum VendorResumeAdapter {
    public static func plan(for vendor: PaneKind) -> VendorResumePlan? {
        let boundary = "The vendor decides which saved conversations are available; Parley cannot guarantee that a previous conversation resumes."
        return switch vendor {
        case .shell:
            nil
        case .claude:
            VendorResumePlan(
                vendor: vendor,
                selection: .vendorPicker,
                menuLabel: "Resume Claude Session…",
                confirmationLabel: "Open Claude Picker",
                detail: "Claude opens its documented session picker in this pane. \(boundary)"
            )
        case .codex:
            VendorResumePlan(
                vendor: vendor,
                selection: .vendorPicker,
                menuLabel: "Resume Codex Session…",
                confirmationLabel: "Open Codex Picker",
                detail: "Codex opens its documented session picker in this pane. \(boundary)"
            )
        case .agy:
            VendorResumePlan(
                vendor: vendor,
                selection: .mostRecentInWorkingDirectory,
                menuLabel: "Resume Most Recent Agy Session…",
                confirmationLabel: "Resume Most Recent",
                detail: "Agy attempts its documented most recent conversation for this pane's working directory. \(boundary)"
            )
        case .copilot:
            VendorResumePlan(
                vendor: vendor,
                selection: .vendorPicker,
                menuLabel: "Resume Copilot Session…",
                confirmationLabel: "Open Copilot Picker",
                detail: "Copilot opens its documented session picker in this pane. \(boundary)"
            )
        }
    }

    public static func command(
        freshCommand: [String],
        for vendor: PaneKind,
        launchMode: AgentLaunchMode
    ) -> [String] {
        guard launchMode == .resume, plan(for: vendor) != nil else {
            return freshCommand
        }
        switch vendor {
        case .shell:
            return freshCommand
        case .claude:
            return freshCommand + ["--resume"]
        case .codex:
            guard let executable = freshCommand.first else { return freshCommand }
            return [executable, "resume"] + freshCommand.dropFirst()
        case .agy:
            return freshCommand + ["--continue"]
        case .copilot:
            return freshCommand + ["--resume"]
        }
    }
}
