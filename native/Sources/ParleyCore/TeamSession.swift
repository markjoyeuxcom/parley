import Foundation

public enum TeamSessionError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(message): message } }
}

public enum TeamSessionState: String, Codable, Equatable, Sendable {
    /// Requested by an authenticated requesting pane; nothing is authorized yet.
    case pending
    /// Human approved; a memory-only grant permits bounded provisioning.
    case active
    /// The person pressed Stop: grant revoked, team-owned processes stopped.
    case stopped
    /// The provisioning deadline passed: grant revoked, running panes untouched.
    case expired
    case rejected
    /// The requesting pane or its workspace changed, or Parley stopped.
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

/// Every session lifecycle change, typed so trusted code decides who caused
/// it. An agent payload never chooses an origin: requests, provisioning,
/// expiry and interruption are automation; approval, refusal, Stop and stop
/// attempts are native human decisions.
public enum TeamSessionTransition: String, Codable, Equatable, Sendable {
    case requested
    case approved
    case refused
    case paneCreated
    case stopped
    case stopAttempted
    case expired
    case interrupted

    public var origin: RelayTransitionOrigin {
        switch self {
        case .approved, .refused, .stopped, .stopAttempted: .human
        case .requested, .paneCreated, .expired, .interrupted: .automation
        }
    }

    public var label: String {
        switch self {
        case .requested: "Team session requested"
        case .approved: "Team session approved"
        case .refused: "Team session refused"
        case .paneCreated: "Team pane created"
        case .stopped: "Team session stopped"
        case .stopAttempted: "Team panes stop attempted"
        case .expired: "Team session provisioning expired"
        case .interrupted: "Team session interrupted"
        }
    }
}

/// What the requesting pane asked for. Kept separately from the approved
/// values so the person's edits stay visible beside the original proposal.
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
            throw TeamSessionError.invalid("The provisioning deadline must be between 1 and \(Self.maximumHours) hours.")
        }
        if let templateName {
            guard !templateName.isEmpty, templateName.utf8.count <= 64 else {
                throw TeamSessionError.invalid("The template name is invalid.")
            }
        }
    }
}

/// One pane the session created. Provenance is app-owned: the requesting
/// pane, the grant and the time are recorded here, never in the pane's
/// vendor session. Membership is historical and never removed.
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

    /// The workbench increments a pane's generation when it stops the
    /// process, so a stopped placeholder of the created generation is
    /// `launchGeneration + 1` and not started. Anything else is a person's
    /// restart. This mirrors `WorkbenchController.stopPaneProcess` exactly.
    public func ownership(of pane: WorkbenchPane?) -> TeamPaneOwnership {
        guard let pane, pane.id == paneID else { return .closed }
        if pane.launchGeneration == launchGeneration { return .owned }
        if !pane.isStarted, pane.launchGeneration == launchGeneration &+ 1 { return .stopped }
        return .restartedByPerson
    }
}

/// A pending request from the requesting pane to add one pane. It is
/// fulfilled only by the native app after re-validating the grant.
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
/// keyed to one requesting pane generation and one workspace policy, binds
/// the complete approved permission definition and roots, and is re-checked
/// before every provisioning mutation.
public struct TeamSessionGrant: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    /// The pane that requested the session. It need not be the workspace
    /// lead; the `lead` routing alias keeps meaning the marked workspace lead.
    public let requesterPaneID: String
    public let requesterGeneration: Int
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

    public init(id: String, requesterPaneID: String, requesterGeneration: Int, workspaceID: String, automationPolicy: WorkspaceAutomationPolicy,
                folder: String, allowedVendors: [PaneKind], approvedProfile: PermissionProfileDefinition, approvedRoots: [String],
                paneLimit: Int, provisioningDeadline: Date, approvedAt: Date) {
        self.id = id
        self.requesterPaneID = requesterPaneID
        self.requesterGeneration = requesterGeneration
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

    public func matches(requester: WorkbenchPane) -> Bool {
        requester.id == requesterPaneID && requester.launchGeneration == requesterGeneration
            && requester.workspaceID == workspaceID && requester.automationPolicy == automationPolicy
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

// MARK: - Stop results

public enum TeamMemberStopResult: String, Codable, Equatable, Sendable, CaseIterable {
    /// The owned process generation was asked to stop and the workbench accepted.
    case stopped
    /// The workbench refused or failed and the pane still reports a started
    /// owned generation; it may still be running.
    case failed
    /// The process was terminated and the pane shows stopped, but the
    /// workbench could not record it (credential or persistence failure).
    case stoppedUnrecorded
    /// The stop reported an error and the pane's state could not be read
    /// afterwards; nothing about the process is claimed.
    case unknown
    /// The person restarted this pane since creation; it is no longer team-owned.
    case skippedRestarted
    /// The pane was closed before the attempt.
    case skippedClosed
    /// The owned generation was already stopped.
    case alreadyStopped

    public var label: String {
        switch self {
        case .stopped: "stopped"
        case .stoppedUnrecorded: "stopped, but the workbench could not record it"
        case .unknown: "stop reported an error and the pane state could not be read; it may still be running"
        case .failed: "could not stop"
        case .skippedRestarted: "skipped: restarted by you, no longer team-owned"
        case .skippedClosed: "skipped: already closed"
        case .alreadyStopped: "already stopped"
        }
    }
}

/// Bounded, control-clean diagnostic text. Every stored reason or message
/// passes through here so repeated retries with long path-bearing errors can
/// never grow a session record past the transport cap.
public enum TeamBoundedText {
    public static let maximumMessageBytes = 240
    public static let truncationMarker = " [truncated]"

    public struct Bounded: Equatable, Sendable {
        public let text: String
        public let truncated: Bool
    }

    public static func bounded(_ text: String, maximumBytes: Int = maximumMessageBytes) -> Bounded {
        let scalars = text.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)) || scalar == " "
        }
        var cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf8.count > maximumBytes else { return Bounded(text: cleaned, truncated: false) }
        let budget = max(0, maximumBytes - truncationMarker.utf8.count)
        while cleaned.utf8.count > budget, !cleaned.isEmpty { cleaned.removeLast() }
        return Bounded(text: cleaned + truncationMarker, truncated: true)
    }

    public static func clean(_ text: String, maximumBytes: Int = maximumMessageBytes) -> String {
        bounded(text, maximumBytes: maximumBytes).text
    }
}

public struct TeamMemberStopOutcome: Codable, Equatable, Sendable {
    public let paneID: String
    public let launchGeneration: Int
    public let name: String
    public let result: TeamMemberStopResult
    /// Bounded and control-clean; truncation is disclosed in the text and in
    /// `messageTruncated`.
    public let message: String?
    public let messageTruncated: Bool

    public init(paneID: String, launchGeneration: Int, name: String, result: TeamMemberStopResult, message: String?) {
        self.paneID = paneID
        self.launchGeneration = launchGeneration
        self.name = TeamBoundedText.clean(name, maximumBytes: TeamPaneProvision.maximumNameLength * 4)
        self.result = result
        let bounded = message.map { TeamBoundedText.bounded($0) }
        self.message = bounded?.text
        self.messageTruncated = bounded?.truncated ?? false
    }
}

/// Executes a stop plan against the workbench and classifies each outcome
/// from what the workbench reports afterwards. `stopPaneProcess` terminates
/// and mutates pane state before it records credentials and persistence, so
/// a thrown error is re-read: a pane that now shows stopped is
/// stopped-but-unrecorded, a pane still started is failed.
public enum TeamStopExecution {
    public static func execute(plan: [TeamStopPlanner.Entry], stop: (String) throws -> Void,
                               currentPane: (String) -> WorkbenchPane?) -> [TeamMemberStopOutcome] {
        plan.map { entry in
            let member = entry.member
            switch entry.action {
            case let .skip(result):
                return TeamMemberStopOutcome(paneID: member.paneID, launchGeneration: member.launchGeneration, name: member.name, result: result, message: nil)
            case .stop:
                do {
                    try stop(member.paneID)
                    return TeamMemberStopOutcome(paneID: member.paneID, launchGeneration: member.launchGeneration, name: member.name, result: .stopped, message: nil)
                } catch {
                    // Only a fresh, successful state read may classify the process.
                    let result: TeamMemberStopResult
                    if let after = currentPane(member.paneID) {
                        result = after.isStarted ? .failed : .stoppedUnrecorded
                    } else {
                        result = .unknown
                    }
                    return TeamMemberStopOutcome(paneID: member.paneID, launchGeneration: member.launchGeneration, name: member.name,
                        result: result, message: error.localizedDescription)
                }
            }
        }
    }
}

/// One native stop attempt as it actually happened. Recorded by the app
/// after asking the workbench, never inferred from terminal text.
public struct TeamStopAttempt: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let attemptedAt: Date
    /// Stop attempts are always native human actions.
    public let origin: RelayTransitionOrigin
    public let reason: String
    public let reasonTruncated: Bool
    public let outcomes: [TeamMemberStopOutcome]
    /// True when more outcomes were supplied than the pane limit allows.
    public let outcomesTruncated: Bool

    public init(id: String = UUID().uuidString.lowercased(), attemptedAt: Date = Date(), reason: String, outcomes: [TeamMemberStopOutcome]) {
        self.id = id
        self.attemptedAt = attemptedAt
        self.origin = .human
        let bounded = TeamBoundedText.bounded(reason)
        self.reason = bounded.text
        self.reasonTruncated = bounded.truncated
        self.outcomes = Array(outcomes.prefix(TeamSessionProposal.maximumPaneLimit))
        self.outcomesTruncated = outcomes.count > TeamSessionProposal.maximumPaneLimit
    }

    public var affectedPaneIDs: [String] { outcomes.map(\.paneID) }
    public var failedPaneIDs: [String] { outcomes.filter { $0.result == .failed || $0.result == .unknown }.map(\.paneID) }

    /// Content-minimal counts for durable activity records: no messages,
    /// because diagnostics may carry localized paths.
    public var countsSummary: String {
        let counts = Dictionary(grouping: outcomes, by: \.result).mapValues(\.count)
        return TeamMemberStopResult.allCases.compactMap { result in
            counts[result].map { "\($0) \(result.rawValue)" }
        }.joined(separator: ", ")
    }

    /// Display-only summary for the native UI; never parsed.
    public var summary: String {
        var parts: [String] = []
        let stopped = outcomes.filter { $0.result == .stopped }.map(\.name)
        if !stopped.isEmpty { parts.append("Stopped: " + stopped.joined(separator: ", ")) }
        let unrecorded = outcomes.filter { $0.result == .stoppedUnrecorded }
        if !unrecorded.isEmpty {
            parts.append("Stopped but not recorded: " + unrecorded.map { "\($0.name): \($0.message ?? "unknown error")" }.joined(separator: "; "))
        }
        let skipped = outcomes.filter { [.skippedRestarted, .skippedClosed, .alreadyStopped].contains($0.result) }
        if !skipped.isEmpty { parts.append("Skipped: " + skipped.map { "\($0.name) (\($0.result.label))" }.joined(separator: "; ")) }
        let failed = outcomes.filter { $0.result == .failed || $0.result == .unknown }
        if !failed.isEmpty {
            parts.append("Could not confirm a stop: " + failed.map { "\($0.name): \($0.result.label). \($0.message ?? "")" }.joined(separator: "; ") + " Use Stop team panes to retry.")
        }
        if parts.isEmpty { parts.append("No team panes needed stopping.") }
        return parts.joined(separator: ". ")
    }
}

/// Pure planning from current pane facts: which owned generations to stop
/// and why the others are skipped. The native app executes only `.stop`.
/// Eligibility is the baseline rule: an owned, started agent pane is stopped
/// even when its process has already exited, because `stopPaneProcess` is
/// also the cleanup that turns an exited pane into a stopped placeholder.
public enum TeamStopPlanner {
    public enum Action: Equatable, Sendable {
        case stop
        case skip(TeamMemberStopResult)
    }

    public struct Entry: Equatable, Sendable {
        public let member: TeamSessionMember
        public let action: Action
    }

    public static func plan(members: [TeamSessionMember], live: [WorkbenchPane]) -> [Entry] {
        members.map { member in
            let pane = live.first { $0.id == member.paneID }
            switch member.ownership(of: pane) {
            case .closed: return Entry(member: member, action: .skip(.skippedClosed))
            case .restartedByPerson: return Entry(member: member, action: .skip(.skippedRestarted))
            case .stopped: return Entry(member: member, action: .skip(.alreadyStopped))
            case .owned:
                guard let pane, pane.kind.isAgent, pane.isStarted else { return Entry(member: member, action: .skip(.alreadyStopped)) }
                return Entry(member: member, action: .stop)
            }
        }
    }
}

public enum TeamPaneOwnership: String, Codable, Equatable, Sendable {
    /// The exact created generation still exists.
    case owned
    /// The created generation was stopped (by Stop or by the person) and the
    /// pane remains as a stopped placeholder.
    case stopped
    /// The person restarted the pane; a newer generation runs there.
    case restartedByPerson
    /// The pane no longer exists in the workbench.
    case closed
}

/// Current lifecycle facts for one historical member, derived from live
/// pane state at the moment of the query.
public struct TeamPaneState: Codable, Equatable, Sendable {
    public let paneID: String
    public let name: String
    public let vendor: String
    public let role: String?
    public let createdGeneration: Int
    public let currentGeneration: Int?
    public let ownership: TeamPaneOwnership
    /// Whether any process is started in that pane now, whatever generation
    /// owns it; nil when the pane is closed.
    public let processRunning: Bool?
    /// Whether the exact created generation is the one running now. False
    /// for a person-restarted pane even though `processRunning` is true.
    public let ownedRunning: Bool
    public let moved: Bool
    public let currentWorkspaceID: String?
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
    /// Display-only text; machine readers must use the structured fields.
    public var detail: String?
    /// Historical membership: every pane this session created, never removed.
    public var members: [TeamSessionMember] = []
    public var grantID: String?
    /// Native stop attempts in order, as recorded by the app. Bounded so
    /// repeated retries never grow past the transport cap.
    public var stopAttempts: [TeamStopAttempt] = []
    public static let maximumRetainedStopAttempts = 16

    public var stopOutcome: String? { stopAttempts.last?.summary }

    public var remainingTime: TimeInterval? {
        guard state == .active, let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    public var requesterName: String { source.displayName }

    /// Owned members whose exact created generation is still running.
    public func ownedRunningMembers(in live: [WorkbenchPane]) -> [TeamSessionMember] {
        members.filter { member in live.contains { member.owns($0) && $0.isStarted && !$0.isDead } }
    }

    public func currentPaneStates(in live: [WorkbenchPane]) -> [TeamPaneState] {
        members.map { member in
            let pane = live.first { $0.id == member.paneID }
            let ownership = member.ownership(of: pane)
            return TeamPaneState(paneID: member.paneID, name: member.name, vendor: member.kind.rawValue, role: member.role,
                createdGeneration: member.launchGeneration, currentGeneration: pane?.launchGeneration, ownership: ownership,
                processRunning: pane.map { $0.isStarted && !$0.isDead },
                ownedRunning: pane.map { ownership == .owned && $0.isStarted && !$0.isDead } ?? false,
                moved: pane.map { $0.workspaceID != member.workspaceID } ?? false, currentWorkspaceID: pane?.workspaceID)
        }
    }

    /// The bounded JSON returned to the requesting pane and members. It
    /// contains identities, limits and app-owned lifecycle facts, never
    /// credentials or terminal text. Every time is ISO 8601; `detail` is
    /// display-only.
    public struct AgentView: Codable, Equatable, Sendable {
        public struct Member: Codable, Equatable, Sendable {
            public let paneID: String
            public let vendor: String
            public let name: String
            public let role: String?
            public let createdGeneration: Int
            public let createdAt: Date
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
        public let createdAt: Date
        public let approvedAt: Date?
        public let endedAt: Date?
        /// The pane that requested this session. Members may target it by this
        /// exact id; `lead` still means the marked workspace lead.
        public let requesterPaneID: String
        /// Historical membership in creation order.
        public let members: [Member]
        /// Current lifecycle and ownership per historical member.
        public let currentPanes: [TeamPaneState]
        /// Owned generations that are still running now.
        public let ownedRunningPaneIDs: [String]
        public let stopAttempts: [TeamStopAttempt]
        /// Display-only; never parse. Times inside are local and labelled.
        public let detail: String?
    }

    public func agentView(live: [WorkbenchPane]) -> AgentView {
        let current = currentPaneStates(in: live)
        return AgentView(sessionID: id, state: state.rawValue, objective: objective, folder: folder,
            allowedVendors: allowedVendors.map(\.rawValue), paneLimit: paneLimit, panesCreated: members.count,
            provisioningDeadline: deadline, remainingProvisioningSeconds: remainingTime.map { Int($0) },
            createdAt: createdAt, approvedAt: approvedAt, endedAt: endedAt, requesterPaneID: source.id,
            members: members.map { .init(paneID: $0.paneID, vendor: $0.kind.rawValue, name: $0.name, role: $0.role, createdGeneration: $0.launchGeneration, createdAt: $0.createdAt) },
            currentPanes: current, ownedRunningPaneIDs: current.filter { $0.ownedRunning }.map(\.paneID),
            stopAttempts: stopAttempts, detail: detail)
    }
}

public enum TeamSessionDisclosure {
    public static let approval = "Approval lets the requesting pane create up to the pane limit of new agent panes in this workspace, bound to the approved folder and the exact permission profile shown here, without another approval per pane. Each new pane is an ordinary vendor session with that vendor's own permission prompts; Parley never answers or skips them. The grant lives only in memory and ends at the provisioning deadline, on Stop, on Stop Everything or quit, when the requesting pane restarts, moves, changes folder or its workspace policy changes, and when the approved permission profile is edited or removed."
    public static let deadline = "The deadline bounds provisioning only: after it no new panes can be created. It does not stop or pause work already running in created panes; stopping them is always your explicit action."
    public static let stop = "Stop revokes the grant, refuses further provisioning and stops the processes of panes this session created, identified by pane id and the exact generation Parley started; they remain as stopped placeholders you can close. A pane you restarted since creation is no longer team-owned and is skipped; a pane you moved to another workspace stays owned. The requesting pane and unrelated panes are not touched. Tracked Ask or Delegate work already in flight is not cancelled; cancel it in Status Center. The recorded outcome lists exactly what was stopped, skipped or could not be stopped, with a retry."
    public static let expiry = "When provisioning authority expires or is interrupted, new panes are refused. Running panes are not stopped automatically; Stop team panes remains available for still-owned panes until you use it."
}
