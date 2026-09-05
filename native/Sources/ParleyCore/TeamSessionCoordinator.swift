import Foundation

/// Native approvals only. The agent transport can request a session, ask for
/// one pane at a time within an approved grant, wait for its own results and
/// read its own status. Grants and pending authority live only in memory and
/// are re-validated against live panes and the current permission store
/// before every mutation.
public final class TeamSessionCoordinator: @unchecked Sendable {
    public static let pendingTimeout: TimeInterval = 30 * 60
    public static let provisionTimeout: TimeInterval = 90

    private let lock = NSRecursiveLock()
    private let authenticate: (String) -> String?
    private let panes: () throws -> [WorkbenchPane]
    private let profiles: () throws -> [PermissionProfileDefinition]
    private let record: (TeamSession, String) throws -> Void
    private var records: [String: TeamSession] = [:]
    private var grants: [String: TeamSessionGrant] = [:]
    private var provisions: [String: TeamPaneProvision] = [:]
    private var stopped = false
    private var storedError: String?
    public var lastError: String? { lock.withLock { storedError } }

    public init(authenticate: @escaping (String) -> String?, panes: @escaping () throws -> [WorkbenchPane],
                profiles: @escaping () throws -> [PermissionProfileDefinition],
                record: @escaping (TeamSession, String) throws -> Void) {
        self.authenticate = authenticate
        self.panes = panes
        self.profiles = profiles
        self.record = record
    }

    // MARK: Agent-facing requests

    public func request(token: String, proposal: TeamSessionProposal, idempotencyKey: String = UUID().uuidString) throws -> TeamSession {
        try lock.withLock {
            guard !stopped else { throw TeamSessionError.invalid("The team session service has stopped.") }
            reconcile()
            guard let id = authenticate(token), let source = try panes().first(where: { $0.id == id }), eligible(source) else {
                throw TeamSessionError.invalid("A live authenticated agent pane in a workspace with Ask + Delegation automation is required.")
            }
            guard !isMember(id) else {
                throw TeamSessionError.invalid("Team members cannot request a nested team session; ask the session lead.")
            }
            try proposal.validate()
            let folder = try Self.canonicalFolder(proposal.folder, within: source.cwd)
            guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 128 else { throw TeamSessionError.invalid("Invalid request identity.") }
            if let previous = records.values.first(where: {
                $0.source.id == id && $0.source.launchGeneration == source.launchGeneration && $0.idempotencyKey == idempotencyKey
            }) {
                guard previous.proposal == proposal else { throw TeamSessionError.invalid("A request identity cannot name different proposals.") }
                return previous
            }
            guard !records.values.contains(where: { $0.source.id == id && !$0.state.isTerminal }) else {
                throw TeamSessionError.invalid("This pane already has a pending or active team session.")
            }
            let now = Date()
            let session = TeamSession(id: UUID().uuidString.lowercased(), idempotencyKey: idempotencyKey, revision: UUID().uuidString,
                source: source, sourceFolder: WorkspaceFolderIdentity.matchingKey(source.cwd), proposal: proposal,
                objective: proposal.objective, folder: folder, allowedVendors: PaneKind.allCases.filter(\.isAgent),
                permissionProfileID: nil, paneLimit: proposal.paneLimit, deadline: nil, state: .pending,
                createdAt: now, updatedAt: now, detail: "Waiting for human approval")
            let stored = try save(session, event: "Team session requested")
            prune()
            return stored
        }
    }

    /// Asks the native app to create one pane. Only the session lead may ask,
    /// one creation is in flight at a time, the approved limit bounds the
    /// total number of creations for the session's lifetime, and a repeated
    /// request identity returns the earlier request instead of a second pane.
    public func requestPane(token: String, kind: PaneKind, name: String, role: String?,
                            idempotencyKey: String = UUID().uuidString) throws -> TeamPaneProvision {
        try lock.withLock {
            guard !stopped else { throw TeamSessionError.invalid("The team session service has stopped.") }
            reconcile()
            guard let id = authenticate(token), let source = try panes().first(where: { $0.id == id }), eligible(source) else {
                throw TeamSessionError.invalid("A live authenticated agent pane is required.")
            }
            guard !isMember(id) else {
                throw TeamSessionError.invalid("Team members cannot provision panes; only the session lead may, within its approved limit.")
            }
            guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 128 else { throw TeamSessionError.invalid("Invalid request identity.") }
            guard let session = records.values.first(where: { $0.state == .active && $0.source.id == id }),
                  let grant = grants[session.id], grant.matches(lead: source), currentLead(session) != nil else {
                throw TeamSessionError.invalid("This pane has no active approved team session.")
            }
            if let previous = provisions.values.first(where: { $0.sessionID == session.id && $0.idempotencyKey == idempotencyKey }) {
                guard previous.kind == kind, previous.name == name, previous.role == role else {
                    throw TeamSessionError.invalid("A request identity cannot name a different pane.")
                }
                return previous
            }
            guard Date() < grant.provisioningDeadline else {
                expire(session.id)
                throw TeamSessionError.invalid("The provisioning deadline passed; no new panes can be created.")
            }
            // Fail closed: the approved profile must still be verifiable and unchanged.
            _ = try verifiedProfile(for: grant)
            guard kind.isAgent, grant.allowedVendors.contains(kind) else {
                throw TeamSessionError.invalid("The approval allows only: \(grant.allowedVendors.map(\.rawValue).joined(separator: ", ")).")
            }
            guard !provisions.values.contains(where: { $0.sessionID == session.id && !$0.isSettled }) else {
                throw TeamSessionError.invalid("A pane is already being created for this session; wait for that result first.")
            }
            guard session.members.count < grant.paneLimit else {
                throw TeamSessionError.invalid("The approved pane limit (\(grant.paneLimit)) is reached. The limit counts every pane this session created, including closed ones.")
            }
            let provision = TeamPaneProvision(id: UUID().uuidString.lowercased(), sessionID: session.id, idempotencyKey: idempotencyKey,
                kind: kind, name: name, role: role, createdAt: Date())
            provisions[provision.id] = provision
            return provision
        }
    }

    // MARK: Native decisions

    public func approve(id: String, revision: String, objective: String, folder: String, allowedVendors: [PaneKind],
                        permissionProfileID: String, paneLimit: Int, hours: Int) throws {
        try lock.withLock {
            guard !stopped, var session = records[id], session.state == .pending, session.revision == revision,
                  let source = currentLead(session) else {
                throw TeamSessionError.invalid("This preview is stale or its requesting pane changed. Refresh before approving.")
            }
            let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            let edited = TeamSessionProposal(objective: cleanObjective, folder: folder, templateName: session.proposal.templateName, paneLimit: paneLimit, hours: hours)
            try edited.validate()
            let canonical = try Self.canonicalFolder(folder, within: source.cwd)
            let vendors = allowedVendors.reduce(into: [PaneKind]()) { if !$0.contains($1) { $0.append($1) } }
            guard !vendors.isEmpty, vendors.allSatisfy(\.isAgent) else {
                throw TeamSessionError.invalid("Choose at least one agent vendor; Shell panes are never team members.")
            }
            guard let definition = try profiles().first(where: { $0.id == permissionProfileID }) else {
                throw TeamSessionError.invalid("That permission profile is no longer available.")
            }
            // Resolving proves the definition is valid for the approved folder now;
            // the snapshot below is what every later creation must still match.
            _ = try PermissionProfileResolver.resolve(definition: definition, paneFolder: canonical,
                approvedRoots: definition.rootMode == .exactApprovedRoots ? [canonical] : [])
            let now = Date()
            let grant = TeamSessionGrant(id: UUID().uuidString.lowercased(), leadPaneID: source.id, leadGeneration: source.launchGeneration,
                workspaceID: source.workspaceID, automationPolicy: source.automationPolicy, folder: canonical, allowedVendors: vendors,
                approvedProfile: definition, approvedRoots: definition.rootMode == .exactApprovedRoots ? [canonical] : [],
                paneLimit: paneLimit, provisioningDeadline: now.addingTimeInterval(TimeInterval(hours) * 3_600), approvedAt: now)
            session.objective = cleanObjective
            session.folder = canonical
            session.allowedVendors = vendors
            session.permissionProfileID = definition.id
            session.paneLimit = paneLimit
            session.deadline = grant.provisioningDeadline
            session.state = .active
            session.approvedAt = now
            session.grantID = grant.id
            session.detail = "Human approved up to \(paneLimit) pane\(paneLimit == 1 ? "" : "s") with the \(definition.name) profile; provisioning until \(Self.timestamp(grant.provisioningDeadline))"
            // Durable record first; a failed record cannot leave authority live.
            try save(session, event: "Team session approved")
            grants[id] = grant
        }
    }

    public func reject(id: String, revision: String) throws {
        try lock.withLock {
            guard var session = records[id], session.state == .pending, session.revision == revision else {
                throw TeamSessionError.invalid("This request is no longer awaiting that approval.")
            }
            session.state = .rejected
            session.endedAt = Date()
            session.detail = "The person refused this team session."
            try save(session, event: "Team session refused")
        }
    }

    /// Ends an active session. Returns the owned members (pane id plus the
    /// exact created generation) so the native app can stop exactly those.
    public func stop(id: String, reason: String) throws -> [TeamSessionMember] {
        try lock.withLock {
            guard var session = records[id], session.state == .active else {
                throw TeamSessionError.invalid("This team session is not active.")
            }
            grants[id] = nil
            failProvisions(sessionID: id, reason: "The session was stopped before the pane was created.")
            session.state = .stopped
            session.endedAt = Date()
            session.detail = reason + ". " + TeamSessionDisclosure.stop
            store(session, event: "Team session stopped")
            return session.members
        }
    }

    /// Owned members the person may still stop after authority ended. Any
    /// non-pending session qualifies; provisioning stays revoked.
    public func ownedMembers(id: String) throws -> [TeamSessionMember] {
        try lock.withLock {
            guard let session = records[id], session.state != .pending else {
                throw TeamSessionError.invalid("This team session has not been approved.")
            }
            return session.members
        }
    }

    /// Records the native outcome of a stop attempt for the person to see.
    public func recordStopOutcome(id: String, outcome: String) {
        lock.withLock {
            guard var session = records[id] else { return }
            session.stopOutcome = outcome
            store(session, event: "Team panes stop attempted")
        }
    }

    /// Called only by the native app on its main actor. `create` commits the
    /// pane in the workbench; ownership is recorded the moment it returns.
    /// `mount` performs later native steps; its failure is reported on the
    /// owned member and never loses the pane from the session's count or Stop.
    public func fulfilProvisions(create: (TeamSession, TeamSessionGrant, TeamPaneProvision) throws -> WorkbenchPane,
                                 mount: (TeamSession, WorkbenchPane) throws -> Void = { _, _ in }) {
        lock.withLock {
            reconcile()
            let pending = provisions.values.filter { !$0.isSettled }.sorted { $0.createdAt < $1.createdAt }
            for var provision in pending {
                guard !stopped, var session = records[provision.sessionID], session.state == .active,
                      let grant = grants[session.id], let lead = currentLead(session), grant.matches(lead: lead),
                      Date() < grant.provisioningDeadline, session.members.count < grant.paneLimit,
                      (try? verifiedProfile(for: grant)) != nil else {
                    provision.failure = "The session is no longer authorized to create panes."
                    provisions[provision.id] = provision
                    continue
                }
                let pane: WorkbenchPane
                do {
                    pane = try create(session, grant, provision)
                } catch {
                    provision.failure = error.localizedDescription
                    provisions[provision.id] = provision
                    continue
                }
                // The pane exists: own it before anything else can fail.
                var member = TeamSessionMember(paneID: pane.id, launchGeneration: pane.launchGeneration, workspaceID: pane.workspaceID,
                    kind: pane.kind, name: provision.name, role: pane.role ?? provision.role, requestedByPaneID: session.source.id,
                    grantID: grant.id, createdAt: Date())
                session.members.append(member)
                session.detail = "Created \(session.members.count) of \(grant.paneLimit) approved pane\(grant.paneLimit == 1 ? "" : "s")"
                provision.paneID = pane.id
                provisions[provision.id] = provision
                records[session.id] = session
                do {
                    try mount(session, pane)
                } catch {
                    member.warning = "Created and owned, but a later native step failed: \(error.localizedDescription)"
                    provision.warning = member.warning
                    provisions[provision.id] = provision
                    if let index = session.members.firstIndex(where: { $0.paneID == pane.id }) { session.members[index] = member }
                    session.detail = (session.detail ?? "") + ". " + member.warning!
                }
                // Keep provenance in memory even if the record fails.
                store(session, event: "Team pane created: \(provision.name) (\(pane.kind.label))")
            }
        }
    }

    public func reconcile(at now: Date = Date()) {
        lock.withLock {
            guard let live = try? panes() else { return }
            let available = try? profiles()
            for id in records.values.filter({ !$0.state.isTerminal }).map(\.id) {
                guard let session = records[id] else { continue }
                if session.state == .pending, now.timeIntervalSince(session.createdAt) > Self.pendingTimeout {
                    interrupt(id, reason: "The unapproved request expired.", at: now)
                    continue
                }
                guard let lead = currentLead(session, in: live) else {
                    interrupt(id, reason: "The lead pane stopped, moved, changed folder or restarted, or its workspace policy changed. Provisioning authority was revoked; created panes were not stopped.", at: now)
                    continue
                }
                guard session.state == .active, let grant = grants[id] else { continue }
                if !grant.matches(lead: lead) {
                    interrupt(id, reason: "The lead pane no longer matches the approved grant. Provisioning authority was revoked; created panes were not stopped.", at: now)
                } else if now >= grant.provisioningDeadline {
                    expire(id, at: now)
                } else if let available, available.first(where: { $0.id == grant.permissionProfileID }) != grant.approvedProfile {
                    interrupt(id, reason: "The approved permission profile was edited or removed. Provisioning authority was revoked; created panes were not stopped.", at: now)
                }
            }
            for var provision in provisions.values where !provision.isSettled {
                if let session = records[provision.sessionID], session.state != .active {
                    provision.failure = "The session ended before the pane was created."
                } else if now.timeIntervalSince(provision.createdAt) > Self.provisionTimeout {
                    provision.failure = "Parley did not create the pane in time. Check that a Parley window is visible, then ask again."
                } else {
                    continue
                }
                provisions[provision.id] = provision
            }
        }
    }

    public func stopAll(reason: String, permanently: Bool = true) {
        lock.withLock {
            if permanently { stopped = true }
            grants.removeAll()
            for id in records.values.filter({ !$0.state.isTerminal }).map(\.id) {
                interrupt(id, reason: reason, at: Date())
            }
        }
    }

    // MARK: Owner-only recovery

    public func waitForDecision(token: String, id: String) -> RelayTextResponse {
        while true {
            let response: RelayTextResponse? = lock.withLock {
                reconcile()
                guard let session = records[id], isOriginalLead(token: token, session: session) else {
                    return RelayTextResponse(status: 403, text: "Only the same live requesting pane generation can recover this team session.")
                }
                switch session.state {
                case .pending: return nil
                case .active: return Self.json(session.agentView)
                default: return RelayTextResponse(status: 409, text: session.detail ?? session.state.label)
                }
            }
            if let response { return response }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    public func waitForProvision(token: String, id: String) -> RelayTextResponse {
        while true {
            let response: RelayTextResponse? = lock.withLock {
                reconcile()
                guard let provision = provisions[id], let session = records[provision.sessionID],
                      isOriginalLead(token: token, session: session) else {
                    return RelayTextResponse(status: 403, text: "Only the same live requesting pane generation can recover this pane request.")
                }
                if let failure = provision.failure { return RelayTextResponse(status: 409, text: failure) }
                guard let paneID = provision.paneID else { return nil }
                let member = session.members.first { $0.paneID == paneID }
                return Self.json(ProvisionResult(provisionID: provision.id, paneID: paneID, vendor: provision.kind.rawValue,
                    name: member?.name ?? provision.name, role: member?.role ?? provision.role, sessionID: session.id,
                    panesCreated: session.members.count, paneLimit: session.paneLimit, warning: provision.warning))
            }
            if let response { return response }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// `parley wait <id>` recovery for either a session decision or a pane request.
    public func wait(token: String, id: String) -> RelayTextResponse {
        if lock.withLock({ provisions[id] != nil }) { return waitForProvision(token: token, id: id) }
        return waitForDecision(token: token, id: id)
    }

    public func status(token: String) -> RelayTextResponse {
        lock.withLock {
            reconcile()
            guard let session = session(forToken: token) else {
                return RelayTextResponse(status: 404, text: "This pane has no team session.")
            }
            return Self.json(session.agentView)
        }
    }

    // MARK: Inspection

    public func sessions() -> [TeamSession] { lock.withLock { records.values.sorted { $0.createdAt > $1.createdAt } } }
    public func grant(for sessionID: String) -> TeamSessionGrant? { lock.withLock { grants[sessionID] } }
    public func provision(id: String) -> TeamPaneProvision? { lock.withLock { provisions[id] } }
    public func owns(id: String) -> Bool { lock.withLock { records[id] != nil || provisions[id] != nil } }
    public func pendingProvisions() -> [TeamPaneProvision] {
        lock.withLock { provisions.values.filter { !$0.isSettled }.sorted { $0.createdAt < $1.createdAt } }
    }

    /// The most recent session in which the authenticated pane is the lead or a member.
    public func session(forToken token: String) -> TeamSession? {
        lock.withLock {
            guard let id = authenticate(token) else { return nil }
            return records.values.filter { $0.source.id == id || $0.members.contains { $0.paneID == id } }
                .sorted { $0.createdAt > $1.createdAt }.first
        }
    }

    /// Whether a pane was created by a session that is still pending or active.
    public func isMember(_ paneID: String) -> Bool {
        lock.withLock { records.values.contains { !$0.state.isTerminal && $0.members.contains { $0.paneID == paneID } } }
    }

    // MARK: Helpers

    private struct ProvisionResult: Codable {
        let provisionID: String
        let paneID: String
        let vendor: String
        let name: String
        let role: String?
        let sessionID: String
        let panesCreated: Int
        let paneLimit: Int
        let warning: String?
    }

    static func canonicalFolder(_ folder: String, within sourceFolder: String) throws -> String {
        guard folder.hasPrefix("/") else { throw TeamSessionError.invalid("The team folder must be absolute.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TeamSessionError.invalid("The team folder must be an existing directory.")
        }
        let canonical = WorkspaceFolderIdentity.matchingKey(folder)
        let root = WorkspaceFolderIdentity.matchingKey(sourceFolder)
        guard canonical == root || canonical.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw TeamSessionError.invalid("The team folder must be inside the lead pane's working folder.")
        }
        return canonical
    }

    private static func json<Value: Encodable>(_ value: Value) -> RelayTextResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), data.count <= 200_000 else {
            return RelayTextResponse(status: 500, text: "The team session could not be encoded.")
        }
        return RelayTextResponse(status: 200, text: String(decoding: data, as: UTF8.self))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The current store must still hold the exact approved definition.
    /// A read failure or any difference fails closed.
    private func verifiedProfile(for grant: TeamSessionGrant) throws -> PermissionProfileDefinition {
        let available: [PermissionProfileDefinition]
        do { available = try profiles() } catch {
            throw TeamSessionError.invalid("The approved permission profile could not be verified: \(error.localizedDescription)")
        }
        guard let current = available.first(where: { $0.id == grant.permissionProfileID }), current == grant.approvedProfile else {
            throw TeamSessionError.invalid("The approved permission profile was edited or removed; provisioning is refused.")
        }
        return current
    }

    private func eligible(_ pane: WorkbenchPane) -> Bool {
        pane.kind.isAgent && pane.isStarted && !pane.isDead && pane.relayEnabled && pane.automationPolicy == .askAndDelegate
    }

    private func currentLead(_ session: TeamSession, in live: [WorkbenchPane]? = nil) -> WorkbenchPane? {
        guard let live = live ?? (try? panes()) else { return nil }
        return live.first {
            eligible($0) && $0.id == session.source.id && $0.launchGeneration == session.source.launchGeneration
                && $0.workspaceID == session.source.workspaceID && $0.automationPolicy == session.source.automationPolicy
                && WorkspaceFolderIdentity.matchingKey($0.cwd) == session.sourceFolder
        }
    }

    /// Recovery needs the same pane id and the exact generation that made the
    /// request; a restarted lead is a new generation and gets nothing back.
    private func isOriginalLead(token: String, session: TeamSession) -> Bool {
        guard authenticate(token) == session.source.id, let live = try? panes() else { return false }
        return live.contains { $0.id == session.source.id && $0.launchGeneration == session.source.launchGeneration }
    }

    private func interrupt(_ id: String, reason: String, at now: Date) {
        guard var session = records[id], !session.state.isTerminal else { return }
        grants[id] = nil
        failProvisions(sessionID: id, reason: "The session ended before the pane was created.")
        session.state = .interrupted
        session.endedAt = now
        session.detail = reason
        store(session, event: "Team session interrupted")
    }

    private func expire(_ id: String, at now: Date = Date()) {
        guard var session = records[id], session.state == .active else { return }
        grants[id] = nil
        failProvisions(sessionID: id, reason: "The provisioning deadline passed before the pane was created.")
        session.state = .expired
        session.endedAt = now
        session.detail = TeamSessionDisclosure.expiry
        store(session, event: "Team session provisioning expired")
    }

    private func failProvisions(sessionID: String, reason: String) {
        for var provision in provisions.values where provision.sessionID == sessionID && !provision.isSettled {
            provision.failure = reason
            provisions[provision.id] = provision
        }
    }

    private func changed(_ value: TeamSession) -> TeamSession {
        var session = value
        session.updatedAt = Date()
        session.revision = UUID().uuidString
        return session
    }

    /// Records durably before authority changes; throws so callers fail closed.
    /// Returns the stored value, whose revision callers must use afterwards.
    @discardableResult
    private func save(_ session: TeamSession, event: String) throws -> TeamSession {
        let next = changed(session)
        try record(next, event)
        records[next.id] = next
        storedError = nil
        return next
    }

    /// Keeps a revocation or provenance change in memory even when the record fails.
    private func store(_ session: TeamSession, event: String) {
        let next = changed(session)
        records[next.id] = next
        do {
            try record(next, event)
            storedError = nil
        } catch {
            storedError = error.localizedDescription
        }
    }

    private func prune() {
        let terminal = records.values.filter(\.state.isTerminal).sorted { $0.updatedAt > $1.updatedAt }
        for session in terminal.dropFirst(64) {
            records.removeValue(forKey: session.id)
            for provision in provisions.values where provision.sessionID == session.id { provisions.removeValue(forKey: provision.id) }
        }
    }
}
