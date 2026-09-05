import Foundation

public enum TeamSessionError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): message } }
}

public enum TeamSessionState: String, Codable, Equatable, Sendable {
    /// Requested by an authenticated lead pane; nothing is authorized yet.
    case pending
    /// Human approved; a memory-only grant permits bounded provisioning.
    case active
    /// The person pressed Stop: grant revoked, team-owned processes stopped.
    case stopped
    /// The deadline passed: grant revoked, running panes untouched.
    case expired
    case rejected
    /// The lead pane or its workspace changed, or Parley stopped.
    case interrupted

    public var isTerminal: Bool { self != .pending && self != .active }

    public var label: String {
        switch self {
        case .pending: "Awaiting approval"
        case .active: "Active"
        case .stopped: "Stopped"
        case .expired: "Expired"
        case .rejected: "Rejected"
        case .interrupted: "Interrupted"
        }
    }
}

/// What the lead asked for. Kept separately from the approved values so the
/// person's edits stay visible beside the original proposal.
public struct TeamSessionProposal: Codable, Equatable, Sendable {
    public static let maximumObjectiveBytes = 4_000
    public static let maximumPaneLimit = 8
    public static let maximumHours = 128
    public static let defaultPaneLimit = 3
    public static let defaultHours = 8

    public let objective: String
    public let folder: String
    public let templateName: String?
    public let paneLimit: Int
    public let hours: Int

    public init(objective: String, folder: String, templateName: String?, paneLimit: Int, hours: Int) {
        self.objective = objective
        self.folder = folder
        self.templateName = templateName
        self.paneLimit = paneLimit
        self.hours = hours
    }

    /// Decodes the shim's NUL-separated literal argument list. Arguments are
    /// never shell-parsed; every value arrives exactly as the agent wrote it.
    public static func decodeArguments(_ body: String) throws -> [String] {
        guard body.utf8.count <= 16_000, body.hasSuffix("\0") else {
            throw TeamSessionError.invalid("Invalid bounded argument payload.")
        }
        let values = body.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        guard !values.isEmpty, values.count <= 64 else { throw TeamSessionError.invalid("Too many arguments.") }
        return values
    }

    /// Parses the literal `parley team request` arguments. Options may appear
    /// in any order; the remaining words form the objective.
    public static func parse(arguments: [String]) throws -> TeamSessionProposal {
        var folder: String?
        var template: String?
        var paneLimit = defaultPaneLimit
        var hours = defaultHours
        var words: [String] = []
        var index = 0
        func value(_ option: String) throws -> String {
            guard index + 1 < arguments.count else { throw TeamSessionError.invalid("\(option) needs a value") }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--folder": folder = try value(argument)
            case "--template": template = try value(argument)
            case "--panes":
                guard let parsed = Int(try value(argument)) else { throw TeamSessionError.invalid("--panes needs a number") }
                paneLimit = parsed
            case "--hours":
                guard let parsed = Int(try value(argument)) else { throw TeamSessionError.invalid("--hours needs a number") }
                hours = parsed
            default:
                words.append(argument)
            }
            index += 1
        }
        guard let folder else { throw TeamSessionError.invalid("team request needs --folder <absolute-folder>") }
        let objective = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { throw TeamSessionError.invalid("team request needs an objective") }
        let proposal = TeamSessionProposal(objective: objective, folder: folder, templateName: template, paneLimit: paneLimit, hours: hours)
        try proposal.validate()
        return proposal
    }

    public func validate() throws {
        guard objective.utf8.count <= Self.maximumObjectiveBytes,
              !objective.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) else {
            throw TeamSessionError.invalid("The objective must be plain text of at most \(Self.maximumObjectiveBytes) bytes.")
        }
        guard folder.hasPrefix("/") else { throw TeamSessionError.invalid("The team folder must be absolute.") }
        guard (1...Self.maximumPaneLimit).contains(paneLimit) else {
            throw TeamSessionError.invalid("The pane limit must be between 1 and \(Self.maximumPaneLimit).")
        }
        guard (1...Self.maximumHours).contains(hours) else {
            throw TeamSessionError.invalid("The deadline must be between 1 and \(Self.maximumHours) hours.")
        }
        if let templateName {
            guard !templateName.isEmpty, templateName.utf8.count <= 64 else {
                throw TeamSessionError.invalid("The template name is invalid.")
            }
        }
    }
}

/// One pane the session created. Provenance is app-owned: the requesting
/// lead, the grant and the time are recorded here, never in the pane's
/// vendor session.
public struct TeamSessionMember: Identifiable, Codable, Equatable, Sendable {
    public let paneID: String
    /// Ownership is the pane id plus the generation Parley assigned at
    /// creation. A pane the person later restarts has a new generation and is
    /// no longer team-owned; a moved pane keeps both and stays owned.
    public let launchGeneration: Int
    public let workspaceID: String
    public let kind: PaneKind
    public let name: String
    public let role: String?
    public let requestedByPaneID: String
    public let grantID: String
    public let createdAt: Date
    /// Set when the pane was created and owned but a later native step
    /// (mounting or selection) failed; the pane still counts and Stop covers it.
    public var warning: String?

    public var id: String { paneID }

    public init(paneID: String, launchGeneration: Int, workspaceID: String, kind: PaneKind, name: String, role: String?,
                requestedByPaneID: String, grantID: String, createdAt: Date, warning: String? = nil) {
        self.paneID = paneID
        self.launchGeneration = launchGeneration
        self.workspaceID = workspaceID
        self.kind = kind
        self.name = name
        self.role = role
        self.requestedByPaneID = requestedByPaneID
        self.grantID = grantID
        self.createdAt = createdAt
        self.warning = warning
    }

    /// Whether `pane` is still the exact process generation this session created.
    public func owns(_ pane: WorkbenchPane) -> Bool {
        pane.id == paneID && pane.launchGeneration == launchGeneration
    }
}

/// A pending request from the lead to add one pane. It is fulfilled only by
/// the native app after re-validating the grant.
public struct TeamPaneProvision: Identifiable, Codable, Equatable, Sendable {
    public static let maximumNameLength = 48

    public let id: String
    public let sessionID: String
    public let idempotencyKey: String
    public let kind: PaneKind
    public let name: String
    public let role: String?
    public let createdAt: Date
    public var paneID: String?
    public var failure: String?
    /// The pane exists and is owned, but a later native step failed.
    public var warning: String?

    public var isSettled: Bool { paneID != nil || failure != nil }

    public init(id: String, sessionID: String, idempotencyKey: String = UUID().uuidString, kind: PaneKind, name: String, role: String?,
                createdAt: Date, paneID: String? = nil, failure: String? = nil, warning: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.idempotencyKey = idempotencyKey
        self.kind = kind
        self.name = name
        self.role = role
        self.createdAt = createdAt
        self.paneID = paneID
        self.failure = failure
        self.warning = warning
    }

    public static func parse(arguments: [String]) throws -> (kind: PaneKind, name: String, role: String?) {
        var vendor: String?
        var name: String?
        var role: String?
        var index = 0
        func value(_ option: String) throws -> String {
            guard index + 1 < arguments.count else { throw TeamSessionError.invalid("\(option) needs a value") }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--vendor": vendor = try value("--vendor")
            case "--name": name = try value("--name")
            case "--role": role = try value("--role")
            default: throw TeamSessionError.invalid("unknown team add option: \(arguments[index])")
            }
            index += 1
        }
        guard let vendor, let kind = PaneKind(rawValue: vendor.lowercased()), kind.isAgent else {
            throw TeamSessionError.invalid("team add needs --vendor <claude|codex|agy|copilot>")
        }
        let cleanName = (name ?? kind.label).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maximumNameLength).contains(cleanName.count),
              !cleanName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw TeamSessionError.invalid("The pane name must be 1–\(maximumNameLength) printable characters.")
        }
        if let role, let error = PaneRoleRules.validationError(role) { throw TeamSessionError.invalid(error) }
        return (kind, cleanName, role)
    }
}

/// The exact authority the person approved. It lives only in memory, is
/// keyed to one lead pane generation and one workspace policy, binds the
/// complete approved permission definition and roots, and is re-checked
/// before every provisioning mutation.
public struct TeamSessionGrant: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let leadPaneID: String
    public let leadGeneration: Int
    public let workspaceID: String
    public let automationPolicy: WorkspaceAutomationPolicy
    public let folder: String
    public let allowedVendors: [PaneKind]
    /// The complete definition at approval time. A later edit of the stored
    /// profile under the same id no longer matches and revokes the grant.
    public let approvedProfile: PermissionProfileDefinition
    /// Roots the person approved for exact-root profiles; empty for
    /// pane-folder profiles. Never widened after approval.
    public let approvedRoots: [String]
    public let paneLimit: Int
    /// Provisioning authority ends here. Work already running is not stopped.
    public let provisioningDeadline: Date
    public let approvedAt: Date

    public var permissionProfileID: String { approvedProfile.id }

    public init(id: String, leadPaneID: String, leadGeneration: Int, workspaceID: String, automationPolicy: WorkspaceAutomationPolicy,
                folder: String, allowedVendors: [PaneKind], approvedProfile: PermissionProfileDefinition, approvedRoots: [String],
                paneLimit: Int, provisioningDeadline: Date, approvedAt: Date) {
        self.id = id
        self.leadPaneID = leadPaneID
        self.leadGeneration = leadGeneration
        self.workspaceID = workspaceID
        self.automationPolicy = automationPolicy
        self.folder = folder
        self.allowedVendors = allowedVendors
        self.approvedProfile = approvedProfile
        self.approvedRoots = approvedRoots
        self.paneLimit = paneLimit
        self.provisioningDeadline = provisioningDeadline
        self.approvedAt = approvedAt
    }

    public func matches(lead: WorkbenchPane) -> Bool {
        lead.id == leadPaneID && lead.launchGeneration == leadGeneration
            && lead.workspaceID == workspaceID && lead.automationPolicy == automationPolicy
    }

    /// The effective profile a created pane must carry: the approved
    /// definition, the approved roots and nothing resolved from a newer store.
    public func matches(effective: EffectivePermissionProfile) -> Bool {
        effective.definition == approvedProfile
            && effective.selection.profileID == approvedProfile.id
            && Set(effective.selection.approvedRoots.map(WorkspaceFolderIdentity.matchingKey))
                .isSubset(of: Set((approvedRoots + [folder]).map(WorkspaceFolderIdentity.matchingKey)))
    }
}

/// Pure decision for when the native app may create approved panes. The
/// session's own monitoring sheet never blocks creation; any other sheet,
/// modal or an invisible main window does.
public enum TeamProvisioningPresentation {
    public static func allowsCreation(teamSheetPresented: Bool, commandRunsPresented: Bool, otherSheetAttached: Bool,
                                      modalWindowPresent: Bool, mainWindowVisible: Bool) -> Bool {
        guard mainWindowVisible, !modalWindowPresent, !commandRunsPresented else { return false }
        return teamSheetPresented || !otherSheetAttached
    }
}

public struct TeamSession: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let idempotencyKey: String
    public var revision: String
    public let source: WorkbenchPane
    public let sourceFolder: String
    public let proposal: TeamSessionProposal
    public var objective: String
    public var folder: String
    public var allowedVendors: [PaneKind]
    public var permissionProfileID: String?
    public var paneLimit: Int
    public var deadline: Date?
    public var state: TeamSessionState
    public let createdAt: Date
    public var updatedAt: Date
    public var approvedAt: Date?
    public var endedAt: Date?
    public var detail: String?
    public var members: [TeamSessionMember] = []
    public var grantID: String?
    /// The most recent native stop outcome: which owned panes stopped, which
    /// could not, and which were skipped because the person restarted them.
    public var stopOutcome: String?

    public var remainingTime: TimeInterval? {
        guard state == .active, let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    /// Owned members whose exact created generation is still running.
    public func ownedRunningMembers(in live: [WorkbenchPane]) -> [TeamSessionMember] {
        members.filter { member in live.contains { member.owns($0) && $0.isStarted && !$0.isDead } }
    }

    public var leadName: String { source.displayName }

    /// The bounded JSON returned to the lead. It contains identities and
    /// limits, never credentials or terminal text.
    public struct AgentView: Codable, Equatable, Sendable {
        public struct Member: Codable, Equatable, Sendable {
            public let paneID: String
            public let vendor: String
            public let name: String
            public let role: String?
        }
        public let sessionID: String
        public let state: String
        public let objective: String
        public let folder: String
        public let allowedVendors: [String]
        public let paneLimit: Int
        public let panesCreated: Int
        /// Provisioning authority ends here; it is not a work deadline.
        public let provisioningDeadline: Date?
        public let remainingProvisioningSeconds: Int?
        public let leadPaneID: String
        public let members: [Member]
        public let detail: String?
    }

    public var agentView: AgentView {
        AgentView(sessionID: id, state: state.rawValue, objective: objective, folder: folder,
            allowedVendors: allowedVendors.map(\.rawValue), paneLimit: paneLimit, panesCreated: members.count,
            provisioningDeadline: deadline, remainingProvisioningSeconds: remainingTime.map { Int($0) }, leadPaneID: source.id,
            members: members.map { .init(paneID: $0.paneID, vendor: $0.kind.rawValue, name: $0.name, role: $0.role) },
            detail: detail)
    }
}

public enum TeamSessionDisclosure {
    public static let approval = "Approval lets the requesting lead pane create up to the pane limit of new agent panes in this workspace, bound to the approved folder and the exact permission profile shown here, without another approval per pane. Each new pane is an ordinary vendor session with that vendor's own permission prompts; Parley never answers or skips them. The grant lives only in memory and ends at the provisioning deadline, on Stop, on Stop Everything or quit, when the lead pane restarts, moves, changes folder or its workspace policy changes, and when the approved permission profile is edited or removed."
    public static let deadline = "The deadline bounds provisioning only: after it no new panes can be created. It does not stop or pause work already running in created panes; stopping them is always your explicit action."
    public static let stop = "Stop revokes the grant, refuses further provisioning and stops the processes of panes this session created, identified by pane id and the exact generation Parley started; they remain as stopped placeholders you can close. A pane you restarted since creation is no longer team-owned and is skipped; a pane you moved to another workspace stays owned. The lead pane and unrelated panes are not touched. Tracked Ask or Delegate work already in flight is not cancelled; cancel it in Status Center. Any pane that could not be stopped is reported here with a retry."
    public static let expiry = "When provisioning authority expires or is interrupted, new panes are refused. Running panes are not stopped automatically; Stop team panes remains available for still-owned panes until you use it."
}
