import AppKit
import Darwin
import Dispatch
import Foundation
import ParleyCore

private struct Invocation {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let input: Data?
}

private final class RecordingRunner: CommandRunning {
    var calls: [Invocation] = []
    var respond: ([String], Data?) -> CommandOutput

    init(respond: @escaping ([String], Data?) -> CommandOutput = { _, _ in CommandOutput() }) {
        self.respond = respond
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        input: Data?
    ) throws -> CommandOutput {
        calls.append(Invocation(executable: executable, arguments: arguments, environment: environment, input: input))
        return respond(arguments, input)
    }
}

private struct ContextCommandInvocation {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]
}

private final class RecordingContextCommandRunner: ContextCommandRunning {
    var calls: [ContextCommandInvocation] = []
    var output: CommandOutput

    init(output: CommandOutput) {
        self.output = output
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) throws -> CommandOutput {
        calls.append(ContextCommandInvocation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        ))
        return output
    }
}

private final class LockedDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (paneID: String, text: String, submit: Bool)?

    var value: (paneID: String, text: String, submit: Bool)? {
        lock.withLock { storage }
    }

    func set(paneID: String, text: String, submit: Bool) {
        lock.withLock { storage = (paneID, text, submit) }
    }
}

private final class LockedAskResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: RelayTextResponse?

    var value: RelayTextResponse? {
        lock.withLock { storage }
    }

    func set(_ value: RelayTextResponse) {
        lock.withLock { storage = value }
    }
}

private final class LockedRelayResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelayTextResponse] = []

    var values: [RelayTextResponse] {
        lock.withLock { storage }
    }

    func append(_ value: RelayTextResponse) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedAskManyUIResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: RelayAskManyUIResponse?
    private var errorStorage: String?

    var value: RelayAskManyUIResponse? { lock.withLock { storage } }
    var error: String? { lock.withLock { errorStorage } }

    func set(_ value: RelayAskManyUIResponse) {
        lock.withLock { storage = value }
    }

    func set(error: Error) {
        lock.withLock { errorStorage = error.localizedDescription }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedShutdownReasons: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RelayCoreShutdownReason] = []

    var values: [RelayCoreShutdownReason] {
        lock.withLock { storage }
    }

    func append(_ reason: RelayCoreShutdownReason) {
        lock.withLock { storage.append(reason) }
    }
}

private struct RecordedSubmission: Sendable {
    let paneID: String
    let text: String
}

private final class LockedSubmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RecordedSubmission] = []

    var values: [RecordedSubmission] {
        lock.withLock { storage }
    }

    func append(paneID: String, text: String) {
        lock.withLock { storage.append(RecordedSubmission(paneID: paneID, text: text)) }
    }
}

private final class LockedPanes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TmuxPane]

    init(_ panes: [TmuxPane]) {
        storage = panes
    }

    var value: [TmuxPane] {
        lock.withLock { storage }
    }

    func set(_ panes: [TmuxPane]) {
        lock.withLock { storage = panes }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw CheckFailure(description: message) }
    return value
}

private func eventually(
    timeout: TimeInterval = 2,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return predicate()
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func checkRuntimeNamespacesAreExplicitAndDisjoint() throws {
    let home = URL(fileURLWithPath: "/Users/runtime-test", isDirectory: true)
    let production = try ParleyRuntime.resolve(
        arguments: [],
        homeDirectory: home,
        isBundledApplication: true
    )
    let development = try ParleyRuntime.resolve(
        arguments: ["--runtime", "development"],
        homeDirectory: home,
        isBundledApplication: false
    )
    let attached = try ParleyRuntime.resolve(
        arguments: ["--runtime", "attached-production"],
        homeDirectory: home,
        isBundledApplication: false
    )
    let failSafeDevelopment = try ParleyRuntime.resolve(
        arguments: [],
        homeDirectory: home,
        isBundledApplication: false
    )
    let bundledIgnoresDevelopmentOverride = try ParleyRuntime.resolve(
        arguments: ["--runtime", "development"],
        homeDirectory: home,
        isBundledApplication: true
    )

    try expect(production.mode == .production, "the installed app did not resolve to production")
    try expect(development.mode == .development, "the development command did not resolve to development")
    try expect(attached.mode == .attachedProduction, "the explicit attach command did not resolve to attached production")
    try expect(failSafeDevelopment.mode == .development, "an unbundled executable silently fell into production")
    try expect(bundledIgnoresDevelopmentOverride.mode == .production, "an argument moved the installed app out of production")
    try expect(production.applicationDirectory != development.applicationDirectory, "production and development share Application Support")
    try expect(production.tmuxSessionName != development.tmuxSessionName, "production and development share a tmux session")
    try expect(production.preferenceSuiteName != development.preferenceSuiteName, "production and development share preferences")
    try expect(attached.applicationDirectory == production.applicationDirectory, "production attach does not address production data")
    try expect(attached.tmuxSessionName == production.tmuxSessionName, "production attach does not address the production tmux session")
    try expect(production.visibleMarker == nil, "production displays a development marker")
    try expect(development.visibleMarker == "DEV", "development is not permanently marked")
    try expect(attached.visibleMarker == "DEV ATTACHED TO PRODUCTION", "production attach is not permanently marked")
    try expect(production.preparesRuntimeFiles && production.launchesCore && production.upgradesCore, "production lost runtime ownership")
    try expect(development.preparesRuntimeFiles && development.launchesCore && development.upgradesCore, "development cannot own its isolated runtime")
    try expect(!attached.preparesRuntimeFiles && !attached.launchesCore && !attached.upgradesCore, "production attach can mutate the production runtime lifecycle")
    try expect(production.installsStableCommand && !development.installsStableCommand && !attached.installsStableCommand, "a development runtime can replace the stable relay command")
    try expect(production.managesLoginItem && !development.managesLoginItem && !attached.managesLoginItem, "a development runtime can mutate the production login item")
}

private func checkBuildInformationIsUsefulAndCopyable() throws {
    let runtime = ParleyRuntime.make(
        mode: .development,
        homeDirectory: URL(fileURLWithPath: "/Users/build-test", isDirectory: true)
    )
    let packaged = ParleyBuildInformation.resolve(
        infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45",
            "ParleySourceCommit": "0123456789abcdef",
            "ParleySourceBranch": "main",
            "ParleySourceDirty": false,
        ],
        environment: [
            "PARLEY_BUILD_COMMIT": "ignored-development-commit",
            "PARLEY_BUILD_DIRTY": "1",
        ],
        runtime: runtime,
        operatingSystem: "macOS 26.0",
        architecture: "arm64",
        executablePath: "/Applications/Parley.app/Contents/MacOS/parley-native"
    )

    try expect(packaged.applicationVersion == "1.2.3", "About lost the packaged application version")
    try expect(packaged.buildNumber == "45", "About lost the packaged build number")
    try expect(packaged.sourceCommit == "0123456789abcdef", "About did not prefer packaged source metadata")
    try expect(packaged.sourceBranch == "main", "About lost the packaged source branch")
    try expect(packaged.sourceDirty == false, "About changed a clean packaged source state")
    try expect(packaged.sourceSummary == "main @ 0123456789ab · clean", "About source summary is not concise")
    try expect(packaged.copyableText.contains("Parley 1.2.3 (45)"), "copied build information omitted the version")
    try expect(packaged.copyableText.contains("Runtime: Development"), "copied build information omitted the runtime")
    try expect(packaged.copyableText.contains("Agent protocol: v\(AgentProtocol.version)"), "copied build information omitted the agent protocol")
    try expect(packaged.copyableText.contains("Core contract: v\(CoreServiceIdentity.currentContractVersion)"), "copied build information omitted the core contract")
    try expect(packaged.copyableText.contains(runtime.applicationDirectory.path), "copied build information omitted the isolated data path")

    let development = ParleyBuildInformation.resolve(
        infoDictionary: nil,
        environment: [
            "PARLEY_BUILD_VERSION": "0.1.0",
            "PARLEY_BUILD_NUMBER": "99",
            "PARLEY_BUILD_COMMIT": "fedcba9876543210",
            "PARLEY_BUILD_BRANCH": "feat/about",
            "PARLEY_BUILD_DIRTY": "true",
        ],
        runtime: runtime,
        operatingSystem: "macOS 26.0",
        architecture: "arm64",
        executablePath: "/tmp/parley-native"
    )
    try expect(development.applicationVersion == "0.1.0", "development About did not use the injected version")
    try expect(development.buildNumber == "99", "development About did not use the injected build")
    try expect(development.sourceSummary == "feat/about @ fedcba987654 · modified", "development source state is unclear")
}

private func checkPermissionProfilesAreVendorNeutralAndLocal() throws {
    let builtIns = PermissionProfileDefinition.builtIns
    try expect(
        builtIns.map(\.id) == ["review-only", "default", "flexible", "broad-workspace"],
        "permission profile built-ins or their stable order changed"
    )
    try expect(builtIns.allSatisfy(\.isBuiltIn), "a built-in permission profile is editable")

    let review = try require(builtIns.first(where: { $0.id == "review-only" }), "Review Only is missing")
    let standard = try require(builtIns.first(where: { $0.id == "default" }), "Default is missing")
    let flexible = try require(builtIns.first(where: { $0.id == "flexible" }), "Flexible is missing")
    let broad = try require(builtIns.first(where: { $0.id == "broad-workspace" }), "Broad Workspace is missing")

    try expect(review.rule(for: .projectRead) == .allow, "Review Only cannot read the project")
    try expect(review.rule(for: .projectWrite) == .deny, "Review Only can mutate the project")
    try expect(standard.rule(for: .projectWrite) == .requireApproval, "Default silently grants project writes")
    try expect(flexible.rule(for: .projectWrite) == .allow, "Flexible cannot perform approved project writes")
    try expect(flexible.rule(for: .projectToolExecution) == .allow, "Flexible cannot run project tests and builds")
    try expect(flexible.rule(for: .networkAccess) == .requireApproval, "Flexible silently grants network access")
    try expect(broad.rootMode == .exactApprovedRoots, "Broad Workspace is not tied to exact approved roots")
    try expect(broad.rule(for: .localProcessExecution) == .allow, "Broad Workspace does not cover broad local work")
    try expect(broad.defaultLifetime == .session, "Broad Workspace silently persists beyond a session")
    try expect(
        Set(PermissionHardBoundary.allCases) == Set([
            .parleyControlPlane,
            .credentialsAndKeychains,
            .permissionBypass,
            .privilegeEscalation,
            .destructiveHostOperations,
        ]),
        "the non-negotiable permission boundary changed"
    )
    for profile in builtIns {
        try expect(
            Set(profile.rules.keys) == Set(PermissionCapability.allCases),
            "\(profile.name) does not decide every vendor-neutral capability"
        )
    }

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let sibling = root.appendingPathComponent("consumer", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)

    let effective = try PermissionProfileResolver.resolve(
        definition: broad,
        paneFolder: project.path,
        approvedRoots: [sibling.path, project.path, sibling.path]
    )
    try expect(
        effective.approvedRoots == [canonicalPath(sibling.path), canonicalPath(project.path)],
        "effective permission roots are not canonical and deduplicated"
    )
    try expect(effective.hardBoundaries == Set(PermissionHardBoundary.allCases), "a profile weakened hard denials")
    try expect(effective.lifetime == .session, "Broad Workspace stopped being session-scoped")

    let encoded = String(decoding: try JSONEncoder().encode(effective.selection), as: UTF8.self).lowercased()
    try expect(!encoded.contains("token"), "a permission selection contains a token")
    try expect(!encoded.contains("credential"), "a permission selection contains credentials")
    try expect(!encoded.contains("relay"), "a permission selection grants relay authority")

    let storeFile = root.appendingPathComponent("permission-profiles.json")
    let store = PermissionProfileStore(file: storeFile)
    let custom = flexible.clone(id: "custom-team-flexible", name: "Team flexible")
    try store.saveCustom(custom)
    let loaded = try store.profiles()
    try expect(loaded.count == 5, "a saved custom profile was not returned beside built-ins")
    try expect(loaded.last == custom, "a custom permission profile did not round trip")

    let mode = try require(
        (try FileManager.default.attributesOfItem(atPath: storeFile.path)[.posixPermissions] as? NSNumber)?.uint16Value,
        "permission profile store permissions are missing"
    )
    try expect(mode & 0o077 == 0, "permission profile store is readable by another user")

    do {
        try store.saveCustom(review)
        throw CheckFailure(description: "a built-in permission profile was overwritten")
    } catch let error as PermissionProfileError {
        try expect(error == .immutableBuiltIn, "built-in overwrite failed for the wrong reason")
    }

    let incomplete = PermissionProfileDefinition(
        id: "custom-incomplete",
        name: "Incomplete",
        summary: "Missing most capability decisions.",
        isBuiltIn: false,
        rootMode: .paneFolder,
        defaultLifetime: .session,
        rules: [.projectRead: .allow]
    )
    do {
        try store.saveCustom(incomplete)
        throw CheckFailure(description: "an incomplete custom permission profile was saved")
    } catch let error as PermissionProfileError {
        guard case .invalid = error else {
            throw CheckFailure(description: "incomplete profile failed for the wrong reason")
        }
    }
}

private func checkPermissionProfilesReachPaneLifecycleWithoutUnsafeFlags() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    let consumer = root.appendingPathComponent("consumer", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: consumer, withIntermediateDirectories: false)

    let flexibleDefinition = try require(
        PermissionProfileDefinition.builtIns.first(where: { $0.id == "flexible" }),
        "Flexible profile is missing"
    )
    let broadDefinition = try require(
        PermissionProfileDefinition.builtIns.first(where: { $0.id == "broad-workspace" }),
        "Broad Workspace profile is missing"
    )
    let flexible = try PermissionProfileResolver.resolve(
        definition: flexibleDefinition,
        paneFolder: project.path
    )
    let broad = try PermissionProfileResolver.resolve(
        definition: broadDefinition,
        paneFolder: project.path,
        approvedRoots: [project.path, consumer.path]
    )

    for kind in PaneKind.allCases.filter(\.isAgent) {
        let plan = PermissionProfileAdapter.launchPlan(for: kind, profile: broad)
        try expect(plan.enforcement != .enforced, "\(kind.label) overclaimed complete permission enforcement")
        for forbidden in [
            "--dangerously-skip-permissions",
            "--allow-dangerously-skip-permissions",
            "--dangerously-bypass-approvals-and-sandbox",
            "danger-full-access",
            "--allow-all",
            "--yolo",
        ] {
            try expect(!plan.arguments.contains(forbidden), "\(kind.label) permission translation used \(forbidden)")
        }
        try expect(
            plan.arguments.contains(canonicalPath(consumer.path)),
            "\(kind.label) Broad Workspace translation omitted an exact approved root"
        )
        let translatedRoots = plan.arguments.indices.compactMap { index -> String? in
            guard plan.arguments[index] == "--add-dir",
                  plan.arguments.indices.contains(index + 1) else { return nil }
            return plan.arguments[index + 1]
        }
        try expect(
            translatedRoots == broad.approvedRoots,
            "\(kind.label) permission translation granted an unapproved root"
        )
    }

    let source = paneRow(id: "%1", kind: .shell, active: true)
    let created = paneRow(
        id: "%2",
        kind: .claude,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        permissionSelection: flexible.selection,
        permissionEnforcement: .partiallyEnforced
    )
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window":
            return output("%2\n")
        default:
            return output()
        }
    }
    let applicationDirectory = root.appendingPathComponent("application", isDirectory: true)
    let credentials = try RelayCredentials(file: applicationDirectory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: applicationDirectory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: applicationDirectory.appendingPathComponent("relay-url"),
        shimDirectory: applicationDirectory.appendingPathComponent("bin"),
        transportDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: applicationDirectory),
        credentials: credentials
    ))

    let pane = try controller.createPane(
        kind: .claude,
        cwd: project.path,
        direction: .horizontal,
        permissionProfile: flexible
    )
    try expect(pane.permissionSelection == flexible.selection, "new pane lost its effective permission selection")
    try expect(pane.permissionEnforcement == .partiallyEnforced, "new pane lost its honest enforcement state")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option"
            && call.arguments.contains("@parley-permission-selection")
            && call.arguments.contains(flexible.selection.tmuxMetadataValue)
    }, "new pane did not persist permission selection in tmux")
    let respawn = try require(
        runner.calls.first(where: { command($0.arguments) == "respawn-pane" }),
        "permission-profile pane was not spawned"
    )
    try expect(
        respawn.arguments.contains("--permission-mode") && respawn.arguments.contains("acceptEdits"),
        "Flexible Claude profile did not use Claude's supported edit mode"
    )
}

private func checkVendorPermissionStopsBecomeAttentionWithoutAction() throws {
    let decisions: [(PaneKind, String)] = [
        (.claude, "Bash command\nDo you want to proceed?\n1. Yes\n2. No\nEsc to cancel"),
        (.codex, "Would you like to run the following command?\n1. Yes, proceed\n2. No, and tell Codex what to do differently"),
        (.agy, "Allow execution of: cat src/main.swift\n1. Allow once\n2. Deny"),
        (.copilot, "Confirm folder trust\nDo you trust the files in this folder?\nYes\nNo, cancel"),
    ]
    for (kind, visible) in decisions {
        let reason = VendorPromptAttention.detect(kind: kind, visibleText: visible)
        try expect(reason != nil, "\(kind.label) permission/trust stop was not recognised")
    }
    for ordinaryOutput in [
        "The deployment guide says permission required before production changes.",
        "I asked whether you would like to proceed, then continued with the review.",
        "cat: private.txt: Permission denied",
    ] {
        try expect(
            VendorPromptAttention.detect(kind: .claude, visibleText: ordinaryOutput) == nil,
            "ordinary terminal prose was mistaken for a live permission prompt"
        )
    }

    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = TmuxPane(
        id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
        currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil
    )
    let target = TmuxPane(
        id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp",
        currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil
    )
    let submissions = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() },
        visibleText: { paneID in
            guard paneID == target.id else { return "" }
            return decisions[1].1
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(token: sourceToken, target: "codex", text: "Review this change."))
    }

    try expect(eventually {
        broker.handoffs().first?.attention == .permissionRequired
    }, "a visible vendor permission stop did not become durable handoff attention")
    let waiting = try require(broker.handoffs().first, "permission-stop handoff disappeared")
    try expect(waiting.state == .waiting, "permission recognition ended the waiting consultation")
    try expect(submissions.value == 1, "permission recognition typed into or resubmitted the target pane")
    try expect(result.value == nil, "permission recognition released the blocked requester")

    let answered = broker.handleAnswer(
        token: targetToken,
        consultationID: "current",
        text: "The review is complete."
    )
    try expect(answered.status == 200, "permission-attention consultation could not answer normally")
    try expect(eventually { result.value?.status == 200 }, "answer did not release the permission-attention Ask")
    let completed = try require(broker.handoffs().first, "completed permission-stop handoff disappeared")
    try expect(completed.state == .completed && completed.attention == nil, "completed answer retained stale permission attention")
}

private func checkRuntimeUILeaseRefusesDuplicateOwners() throws {
    let home = URL(
        fileURLWithPath: "/private/tmp/pri-\(UUID().uuidString.lowercased().prefix(6))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }
    let production = try ParleyRuntime.resolve(arguments: [], homeDirectory: home, isBundledApplication: true)
    let development = try ParleyRuntime.resolve(
        arguments: ["--runtime", "development"],
        homeDirectory: home,
        isBundledApplication: false
    )
    let attached = try ParleyRuntime.resolve(
        arguments: ["--runtime", "attached-production"],
        homeDirectory: home,
        isBundledApplication: false
    )

    var developmentLease: RuntimeUILease? = try RuntimeUILease.acquire(runtime: development)
    let productionLease = try RuntimeUILease.acquire(runtime: production)
    try expect(FileManager.default.fileExists(atPath: development.uiLeaseFile.path), "development did not publish its UI lease")
    try expect(FileManager.default.fileExists(atPath: production.uiLeaseFile.path), "production did not publish its UI lease")

    do {
        _ = try RuntimeUILease.acquire(runtime: development)
        throw CheckFailure(description: "a second development UI acquired the same runtime")
    } catch let error as RuntimeUILeaseError {
        try expect(error == .alreadyRunning(.development), "duplicate development refusal was not specific")
    }
    do {
        _ = try RuntimeUILease.acquire(runtime: attached)
        throw CheckFailure(description: "production attach bypassed the production UI lease")
    } catch let error as RuntimeUILeaseError {
        try expect(error == .alreadyRunning(.attachedProduction), "production attach refusal was not specific")
    }

    developmentLease = nil
    developmentLease = try RuntimeUILease.acquire(runtime: development)
    try expect(developmentLease != nil, "a released development UI lease stayed stale")
    withExtendedLifetime(productionLease) {}
}

private func checkChildProcessCannotRetainRuntimeUILease() throws {
    let home = URL(
        fileURLWithPath: "/private/tmp/pri-\(UUID().uuidString.lowercased().prefix(6))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    let ready = home.appendingPathComponent("child-ready")
    let group = DispatchGroup()
    defer {
        group.wait()
        try? FileManager.default.removeItem(at: home)
    }
    let runtime = try ParleyRuntime.resolve(
        arguments: [],
        homeDirectory: home,
        isBundledApplication: true
    )
    var lease: RuntimeUILease? = try RuntimeUILease.acquire(runtime: runtime)
    var preparedEnvironment = ProcessInfo.processInfo.environment
    preparedEnvironment["PARLEY_UI_LEASE_CHILD_FIXTURE"] = ready.path
    let environment = preparedEnvironment
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        _ = try? ProcessCommandRunner(timeout: 3).run(
            executable: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: [],
            environment: environment,
            input: nil
        )
        group.leave()
    }
    try expect(eventually { FileManager.default.fileExists(atPath: ready.path) }, "lease child fixture did not start")

    lease = nil
    lease = try RuntimeUILease.acquire(runtime: runtime)
    try expect(lease != nil, "a spawned child retained the UI lease after Parley released it")
}

private func checkReadOnlyRuntimeAttachmentRequiresPreparedFiles() throws {
    let directory = try temporaryDirectory()
    let runner = RecordingRunner()
    do {
        _ = try TmuxController(
            tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            applicationDirectory: directory.appendingPathComponent("missing", isDirectory: true),
            sessionName: "parley",
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
            runner: runner,
            prepareRuntimeFiles: false
        )
        throw CheckFailure(description: "read-only production attach created an unprepared runtime")
    } catch let error as ParleyTmuxError {
        try expect(error.errorDescription?.contains("not prepared") == true, "unprepared attach failed without a useful explanation")
    }

    let owner = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        sessionName: "parley",
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    let configurationBefore = try Data(contentsOf: owner.configPath)
    let protocolBefore = try Data(contentsOf: owner.protocolDirectory.appendingPathComponent("AGENTS.md"))
    _ = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        sessionName: "parley",
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner,
        prepareRuntimeFiles: false
    )
    let configurationAfter = try Data(contentsOf: owner.configPath)
    let protocolAfter = try Data(contentsOf: owner.protocolDirectory.appendingPathComponent("AGENTS.md"))
    try expect(configurationAfter == configurationBefore, "read-only attach rewrote tmux configuration")
    try expect(protocolAfter == protocolBefore, "read-only attach rewrote the agent protocol")

    let absentSessionRunner = RecordingRunner { arguments, _ in
        command(arguments) == "has-session" ? output(status: 1) : output()
    }
    let attachment = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        sessionName: "parley",
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: absentSessionRunner,
        prepareRuntimeFiles: false
    )
    do {
        try attachment.bootstrap(cwd: "/tmp", createIfMissing: false)
        throw CheckFailure(description: "production attach started a missing tmux session")
    } catch let error as ParleyTmuxError {
        try expect(error.errorDescription?.contains("not running") == true, "missing production tmux failed without a useful explanation")
    }
    try expect(
        !absentSessionRunner.calls.contains(where: { command($0.arguments) == "new-session" }),
        "production attach issued tmux new-session"
    )

    let absentCore = directory.appendingPathComponent("absent-core", isDirectory: true)
    try FileManager.default.createDirectory(at: absentCore, withIntermediateDirectories: false)
    do {
        _ = try RelayCoreLauncher.attachExisting(applicationDirectory: absentCore)
        throw CheckFailure(description: "production attach started a missing coordination core")
    } catch {
        try expect(!FileManager.default.fileExists(atPath: absentCore.appendingPathComponent("core-control-token").path), "production attach created a control credential")
        try expect(!FileManager.default.fileExists(atPath: absentCore.appendingPathComponent("core.log").path), "production attach created a core log")
    }
}

private func checkRealProductionAndDevelopmentTmuxIsolation() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "runtime isolation check could not find tmux"
    )
    let home = URL(
        fileURLWithPath: "/private/tmp/pri-\(UUID().uuidString.lowercased().prefix(6))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }
    let production = ParleyRuntime.make(mode: .production, homeDirectory: home)
    let development = ParleyRuntime.make(mode: .development, homeDirectory: home)
    let productionController = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: production.applicationDirectory,
        sessionName: production.tmuxSessionName,
        environment: environment
    )
    let developmentController = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: development.applicationDirectory,
        sessionName: development.tmuxSessionName,
        environment: environment
    )
    let runner = ProcessCommandRunner(timeout: 3)
    defer {
        for controller in [productionController, developmentController] {
            _ = try? runner.run(
                executable: tmux,
                arguments: ["-S", controller.socketPath.path, "kill-server"],
                environment: controller.environment,
                input: nil
            )
        }
    }

    try productionController.bootstrap(cwd: home.path)
    try developmentController.bootstrap(cwd: home.path)
    try expect(productionController.socketPath != developmentController.socketPath, "live runtimes share a tmux socket")
    try expect(productionController.sessionName != developmentController.sessionName, "live runtimes share a tmux session name")
    try expect(FileManager.default.fileExists(atPath: productionController.socketPath.path), "production tmux socket was not created")
    try expect(FileManager.default.fileExists(atPath: developmentController.socketPath.path), "development tmux socket was not created")
    func paneProcessID(_ controller: TmuxController) throws -> Int32? {
        let result = try runner.run(
            executable: tmux,
            arguments: [
                "-S", controller.socketPath.path,
                "-f", controller.configPath.path,
                "list-panes", "-t", controller.sessionName,
                "-F", "#{pane_pid}",
            ],
            environment: controller.environment,
            input: nil
        )
        return Int32(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let productionPanePID = try require(paneProcessID(productionController), "production tmux exposed no pane process")
    let developmentPanePID = try require(paneProcessID(developmentController), "development tmux exposed no pane process")
    try expect(productionPanePID != developmentPanePID, "live runtimes share a pane process")

    let productionShim = try RelayShim.install(in: production.applicationDirectory)
    let developmentShim = try RelayShim.install(
        in: development.applicationDirectory,
        runtimeMarker: development.visibleMarker
    )
    try expect(productionShim != developmentShim, "live runtimes share a relay shim directory")
    let developmentCommand = try String(
        contentsOf: developmentShim.appendingPathComponent("parley"),
        encoding: .utf8
    )
    try expect(developmentCommand.contains("runtime_marker='DEV'"), "development relay command is not marked DEV")
    let productionRecord = production.applicationDirectory.appendingPathComponent("workspace-layouts.json")
    let developmentRecord = development.applicationDirectory.appendingPathComponent("workspace-layouts.json")
    try Data("production-record".utf8).write(to: productionRecord, options: .atomic)
    try Data("development-record".utf8).write(to: developmentRecord, options: .atomic)
    let productionRecordData = try Data(contentsOf: productionRecord)
    let developmentRecordData = try Data(contentsOf: developmentRecord)
    try expect(productionRecordData != developmentRecordData, "live runtimes share durable records")

    var coreEnvironment = environment
    coreEnvironment["PARLEY_CORE_FIXTURE"] = "1"
    let fixtureExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let productionClient = try RelayCoreLauncher.ensureRunning(
        applicationDirectory: production.applicationDirectory,
        cwd: home.path,
        environment: coreEnvironment,
        tmuxSessionName: production.tmuxSessionName,
        executable: fixtureExecutable,
        timeout: 3
    )
    let developmentClient = try RelayCoreLauncher.ensureRunning(
        applicationDirectory: development.applicationDirectory,
        cwd: home.path,
        environment: coreEnvironment,
        tmuxSessionName: development.tmuxSessionName,
        runtimeMarker: development.visibleMarker,
        executable: fixtureExecutable,
        timeout: 3
    )
    let productionPID = try require(
        Int32(try String(contentsOf: production.applicationDirectory.appendingPathComponent("core.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)),
        "production fixture core wrote no PID"
    )
    let developmentPID = try require(
        Int32(try String(contentsOf: development.applicationDirectory.appendingPathComponent("core.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)),
        "development fixture core wrote no PID"
    )
    defer {
        _ = Darwin.kill(productionPID, SIGTERM)
        _ = Darwin.kill(developmentPID, SIGTERM)
    }
    try expect(productionPID != developmentPID, "live runtimes share a coordination core process")
    try expect(productionClient.infoFile != developmentClient.infoFile, "live runtimes share core discovery")
    try expect(productionClient.isHealthy() && developmentClient.isHealthy(), "an isolated fixture core was unhealthy")

    try expect(Darwin.kill(developmentPID, SIGTERM) == 0, "development fixture core could not be stopped independently")
    try expect(eventually(timeout: 3) { !developmentClient.isHealthy() }, "development fixture core did not stop")
    try expect(productionClient.isHealthy(), "stopping the development core also stopped production")

    let stoppedDevelopment = try runner.run(
        executable: tmux,
        arguments: ["-S", developmentController.socketPath.path, "kill-server"],
        environment: developmentController.environment,
        input: nil
    )
    try expect(stoppedDevelopment.status == 0, "development tmux could not be stopped independently")
    let survivingProductionPanes = try productionController.listPanes()
    try expect(survivingProductionPanes.count == 1, "stopping development also stopped production panes")
}

private func checkUTF8LocaleFallbackPreservesExplicitConfiguration() throws {
    let fallback = EnvironmentResolver.applyingUTF8LocaleFallback(to: [
        "PATH": "/usr/bin:/bin",
    ])
    try expect(fallback["LANG"] == "C.UTF-8", "an environment without a character locale did not receive the UTF-8 fallback")

    for explicit in [
        ["LANG": "en_GB.UTF-8"],
        ["LANG": "C"],
        ["LC_CTYPE": "de_DE.UTF-8"],
        ["LC_ALL": "fr_FR.UTF-8"],
    ] {
        let resolved = EnvironmentResolver.applyingUTF8LocaleFallback(to: explicit)
        try expect(resolved == explicit, "the UTF-8 fallback replaced an explicit locale: \(explicit)")
    }

    let blank = EnvironmentResolver.applyingUTF8LocaleFallback(to: [
        "LANG": "",
        "LC_CTYPE": "",
        "LC_ALL": "",
    ])
    try expect(blank["LANG"] == "C.UTF-8", "empty locale variables blocked the UTF-8 fallback")
}

private func argument(named name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

private func output(_ text: String = "", status: Int32 = 0) -> CommandOutput {
    CommandOutput(stdout: Data(text.utf8), status: status)
}

private func command(_ arguments: [String]) -> String {
    let known = [
        "has-session", "new-session", "new-window", "set-option", "select-pane", "select-window", "list-panes", "list-windows",
        "split-window", "join-pane", "capture-pane", "load-buffer", "paste-buffer", "send-keys",
        "respawn-pane", "kill-pane", "kill-window", "rename-window", "resize-pane", "select-layout", "delete-buffer", "display-message",
    ]
    return arguments.first(where: known.contains) ?? ""
}

private func checkAdjacentNavigationOrder() throws {
    let ids = ["workspace-a", "workspace-b", "workspace-c"]

    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-a", offset: 1, orderedIDs: ids) == "workspace-b",
        "next navigation did not select the following item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-b", offset: -1, orderedIDs: ids) == "workspace-a",
        "previous navigation did not select the preceding item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-c", offset: 1, orderedIDs: ids) == "workspace-a",
        "next navigation did not wrap to the first item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "workspace-a", offset: -1, orderedIDs: ids) == "workspace-c",
        "previous navigation did not wrap to the last item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "missing", offset: 1, orderedIDs: ids) == "workspace-a",
        "next navigation did not recover a missing selection at the first item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: nil, offset: -1, orderedIDs: ids) == "workspace-c",
        "previous navigation did not recover a missing selection at the last item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: "only", offset: 1, orderedIDs: ["only"]) == "only",
        "single-item navigation should remain on that item"
    )
    try expect(
        NavigationOrder.adjacentID(currentID: nil, offset: 1, orderedIDs: []) == nil,
        "empty navigation should have no target"
    )
}

private func checkMenuTrackingRefreshPolicy() throws {
    try expect(
        MenuTrackingRefreshPolicy.runLoopMode == .default,
        "periodic UI refresh does not pause while AppKit tracks an open menu"
    )
    try expect(
        MenuTrackingRefreshPolicy.runLoopMode != .common,
        "common-mode refresh can rebuild menu items beneath the pointer"
    )
}

private func checkInAppHelpGuideCoverage() throws {
    let topics = ParleyHelpGuide.topics
    try expect(topics.count >= 8, "the in-app guide is not detailed enough for Parley's primary workflows")
    try expect(Set(topics.map(\.id)).count == topics.count, "the in-app guide contains duplicate topic ids")
    try expect(
        topics.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.sections.isEmpty },
        "an in-app help topic is missing its title, summary, or detailed sections"
    )
    try expect(
        topics.flatMap(\.sections).allSatisfy { !$0.title.isEmpty && (!$0.paragraphs.isEmpty || !$0.items.isEmpty || !$0.commands.isEmpty) },
        "an in-app help section has no useful content"
    )

    let searchable = topics.map(\.searchableText).joined(separator: "\n").lowercased()
    for command in [
        "parley ask", "parley answer", "parley relay", "parley paste",
        "parley ask-many", "parley delegate", "parley status", "parley wait",
        "parley done", "parley fail", "parley cancel",
    ] {
        try expect(searchable.contains(command), "the in-app guide omitted \(command)")
    }
    for concept in [
        "workspace lead", "automation policy", "permission", "status center",
        "saved layout", "command palette", "subscription", "compare independently",
        "edited synthesis", "context pack", "utf-8 bytes", "absolute executable",
        "workspace brief", "pinned context", "never attached automatically",
        "handoff chain", "objection", "human decision", "team template",
        "routing role", "stopped placeholders", "move to workspace",
        "clone configuration", "active handoffs", "parley open",
        "parley://open", "open in parley", "person-only", "vs code companion",
        "editor-provided", "one-shot manifest", "show attention and panes",
        "opaque pane or handoff ids", "stale, malformed, symlinked or non-private",
        "existing git worktrees", "exact canonical worktree", "permission evidence only",
        "safety summary", "handoff state is unavailable", "does not infer whether an agent is thinking",
        "menu-bar attention inbox", "completed delegations", "permission requests",
        "main window is closed", "prompt and answer bodies", "coordination unavailable",
        "collaboration history", "case-insensitive and terms", "select results",
        "owner-only markdown", "ask this again", "fresh tracked handoff identity",
        "never silently replays", "100, 250 or 500", "increasing it later",
        "including dismissed records", "lifecycle activity",
        "reviewed busy queue", "becoming idle never submits", "ready to review",
        "fresh human review and send", "send uncertain", "do not resend",
        "at most 32 reviewed busy drafts", "pane credentials cannot list",
        "browser and tool evidence", "terminal prose is not capability evidence",
        "credential-free http", "25 mb", "sha-256", "binary bytes are not embedded",
        "cookies or website credentials", "person-provided selected text",
        "compatibility & releases", "exactly one --version", "cli changed",
        "runtime state stays unknown", "terminal prose, silence", "run live conformance",
        "stable selects published non-prereleases", "sha256sums", "download and verify",
        "does not install", "review beta feedback", "nothing is uploaded automatically",
        "live conformance check names/outcomes", "excluded by structure",
    ] {
        try expect(searchable.contains(concept), "the in-app guide omitted \(concept)")
    }
    try expect(
        ParleyHelpGuide.matching("ask many independent").map(\.id) == ["coordination"],
        "help search did not narrow multiple literal terms to the relevant topic"
    )
    try expect(ParleyHelpGuide.matching("no-such-help-term").isEmpty, "help search returned an unrelated topic")
    let permissions = try require(
        topics.first(where: { $0.id == "cli-permissions" }),
        "the in-app guide omitted CLI permission best practices"
    ).searchableText.lowercased()
    for guidance in [
        "allow once", "cat", "inside the intended repository", "narrowest access", "secret",
        "review only", "broad workspace", "partially enforced", "exact approved roots",
    ] {
        try expect(permissions.contains(guidance), "CLI permission help omitted \(guidance)")
    }
    let contextModel = try require(
        topics.first(where: { $0.id == "context-model" }),
        "the in-app guide omitted the dedicated context model page"
    ).searchableText.lowercased()
    for guidance in [
        "pinned snippet", "application-wide", "workspace brief", "vendor pane",
        "attributed snapshot", "one active person-created context pack draft",
        "never attached automatically",
    ] {
        try expect(contextModel.contains(guidance), "the context model guide omitted \(guidance)")
    }
}

private func checkWorkbenchStateProjection() throws {
    let readyAgent = TmuxPane(
        id: "%1",
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )

    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: false, coreAvailable: false) == .tmuxDisconnected,
        "tmux loss did not take precedence over core loss"
    )
    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: true, coreAvailable: false) == .coreDisconnected,
        "core loss was not distinguished from terminal loss"
    )
    try expect(
        WorkbenchStateProjection.connection(tmuxAvailable: true, coreAvailable: true) == .connected,
        "healthy services did not project as connected"
    )
    try expect(
        WorkbenchStateProjection.pane(nil) == .empty,
        "an empty workspace projected a running pane"
    )

    let stopped = TmuxPane(
        id: "%2",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        isDead: true,
        exitStatus: 7,
        isStarted: false
    )
    try expect(
        WorkbenchStateProjection.pane(stopped) == .stopped,
        "an intentionally stopped agent placeholder was misreported as exited"
    )
    try expect(
        WorkbenchStateProjection.protocolStatus(stopped) == .notAttached,
        "a stopped agent placeholder claimed to have an injected protocol"
    )

    let exited = TmuxPane(
        id: "%3",
        kind: .codex,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isDead: true,
        exitStatus: 7,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(exited) == .exited(status: 7),
        "a retained dead pane lost its exit status"
    )
    let exitedSnapshot = StatusCenterProjection.snapshot(
        panes: [exited],
        handoffs: [],
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(
        exitedSnapshot.counts.runningAgents == 0 && exitedSnapshot.counts.stoppedAgents == 1,
        "Status Center counted an exited agent as running"
    )

    let stale = TmuxPane(
        id: "%4",
        kind: .agy,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "agy",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: "1",
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(stale) == .protocolStale(reportedVersion: "1"),
        "a stale protocol was hidden by the secondary relay state"
    )
    try expect(
        WorkbenchStateProjection.protocolStatus(stale) == .restartRequired(reportedVersion: "1"),
        "a stale pane did not expose its injected protocol version"
    )

    let unknownProtocol = TmuxPane(
        id: "%6",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "claude",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: nil,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.protocolStatus(unknownProtocol) == .restartRequired(reportedVersion: nil),
        "a running legacy pane without a protocol stamp was not marked for restart"
    )

    let relayUnavailable = TmuxPane(
        id: "%5",
        kind: .copilot,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "copilot",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.pane(relayUnavailable) == .relayUnavailable,
        "a current agent without relay capability projected as ready"
    )
    try expect(
        WorkbenchStateProjection.pane(readyAgent) == .running,
        "a ready agent did not project as running"
    )
    try expect(
        WorkbenchStateProjection.protocolStatus(readyAgent) == .current(version: AgentProtocol.version),
        "a current pane did not expose its injected protocol version"
    )
}

private func checkExitedPaneRetention() throws {
    let retainedRow = paneRow(id: "%9", kind: .shell, active: true, isDead: true, exitStatus: 7)
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output(workspaceRow(id: "@0", windowName: "tmp", active: true) + "\n")
        case "list-panes": output(retainedRow + "\n")
        default: output()
        }
    }
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    let configuration = try String(contentsOf: directory.appendingPathComponent("tmux.conf"), encoding: .utf8)
    try expect(configuration.contains("remain-on-exit on"), "tmux configuration did not retain exited panes")
    try expect(
        runner.calls.contains {
            $0.arguments.contains("set-window-option")
                && $0.arguments.contains("remain-on-exit")
                && $0.arguments.contains("on")
        },
        "reattaching to an existing tmux server did not enable exited-pane retention"
    )
    let pane = try require(controller.listPanes().first, "retained dead pane was not parsed")
    try expect(pane.isDead, "retained pane was not marked dead")
    try expect(pane.exitStatus == 7, "retained pane lost its exit status")
}

private func checkEmbeddedTmuxPresentation() throws {
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output(workspaceRow(id: "@0", windowName: "parley", active: true) + "\n")
        default: output()
        }
    }
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    let configuration = try String(contentsOf: directory.appendingPathComponent("tmux.conf"), encoding: .utf8)
    try expect(configuration.contains("set-option -g status off"), "embedded tmux configuration retained its duplicate status bar")
    try expect(configuration.contains("set-window-option -g pane-border-status off"), "embedded tmux configuration did not suppress duplicate pane titles")
    try expect(configuration.contains("pane-border-style") && configuration.contains("pane-active-border-style"), "embedded tmux configuration removed spatial pane boundaries")
    for redundantOption in ["status-position", "status-style", "status-left", "status-right"] {
        try expect(!configuration.contains(redundantOption), "embedded tmux configuration retained redundant \(redundantOption) chrome")
    }
    try expect(
        runner.calls.contains {
            command($0.arguments) == "set-option"
                && $0.arguments.contains("status")
                && $0.arguments.contains("off")
        },
        "reattaching the native UI did not remove the live tmux status bar"
    )
    try expect(
        runner.calls.contains {
            $0.arguments.contains("set-window-option")
                && $0.arguments.contains("pane-border-status")
                && $0.arguments.contains("off")
        },
        "reattaching the native UI did not suppress live tmux pane titles"
    )
}

private func paneRow(
    id: String,
    kind: PaneKind,
    active: Bool,
    name: String? = nil,
    cwd: String = "/tmp",
    currentCommand: String? = nil,
    returnTo: String = "",
    relayEnabled: Bool = false,
    protocolVersion: String = "",
    windowID: String = "@0",
    workspaceActive: Bool = true,
    workspaceName: String = "parley",
    bracketedPasteActive: Bool = true,
    started: Bool = true,
    isDead: Bool = false,
    exitStatus: Int? = nil,
    isLead: Bool = false,
    automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate,
    permissionSelection: PermissionProfileSelection? = nil,
    permissionEnforcement: PermissionEnforcementLevel? = nil,
    role: String? = nil
) -> String {
    [id, kind.rawValue, name ?? kind.label, name ?? kind.label, cwd, currentCommand ?? kind.rawValue, active ? "1" : "0", windowID, returnTo, relayEnabled ? "1" : "", protocolVersion, workspaceActive ? "1" : "0", workspaceName, bracketedPasteActive ? "1" : "0", started ? "1" : "0", isDead ? "1" : "", exitStatus.map(String.init) ?? "", isLead ? "1" : "", automationPolicy.rawValue, permissionSelection?.tmuxMetadataValue ?? "", permissionEnforcement?.rawValue ?? "", role ?? ""]
        .joined(separator: TmuxController.outputFieldSeparator)
}

private func workspaceRow(
    id: String,
    windowName: String,
    active: Bool,
    name: String = "",
    folder: String = "",
    paneFolder: String = "/tmp",
    automationPolicy: WorkspaceAutomationPolicy = .askAndDelegate
) -> String {
    [id, windowName, active ? "1" : "0", name, folder, paneFolder, automationPolicy.rawValue]
        .joined(separator: TmuxController.outputFieldSeparator)
}

private func unclassifiedPaneRow(
    id: String,
    windowID: String,
    windowName: String,
    cwd: String,
    currentCommand: String,
    isDead: Bool = false,
    kind: String = ""
) -> String {
    [id, windowID, windowName, cwd, currentCommand, isDead ? "1" : "", kind]
        .joined(separator: TmuxController.outputFieldSeparator)
}

private func checkBootstrap() throws {
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output(status: 1)
        case "new-session": output("@0\(TmuxController.outputFieldSeparator)%0\n")
        default: output()
        }
    }
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tmux.conf").path), "tmux.conf was not written")
    let newSession = try require(runner.calls.first(where: { command($0.arguments) == "new-session" }), "new-session was not invoked")
    try expect(newSession.arguments.contains("-d"), "new-session was not detached")
    try expect(newSession.arguments.contains("/tmp"), "new-session lost its cwd")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-kind") && call.arguments.contains("shell")
    }, "initial pane was not stamped as a shell")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("tmp")
    }, "initial tmux window was not stamped with a workspace name")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "initial tmux window was not stamped with its workspace folder")
}

private func checkBootstrapRecoversMissingIdentifiers() throws {
    var pendingName = ""
    var sessionExists = false
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session":
            return output(status: sessionExists ? 0 : 1)
        case "new-session":
            pendingName = arguments.drop(while: { $0 != "-n" }).dropFirst().first ?? ""
            sessionExists = true
            return output()
        case "list-panes" where sessionExists:
            return output(unclassifiedPaneRow(
                id: "%0",
                windowID: "@0",
                windowName: pendingName,
                cwd: "/tmp",
                currentCommand: "zsh"
            ) + "\n")
        default:
            return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(pendingName.hasPrefix("Parley-Pending-"), "first-run bootstrap did not create a recoverable provisional window")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("%0")
            && call.arguments.contains("@parley-kind") && call.arguments.contains("shell")
    }, "first-run bootstrap did not recover its shell after tmux omitted the ids")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "rename-window" && call.arguments.contains("@0") && call.arguments.contains("tmp")
    }, "first-run bootstrap did not commit the recovered workspace name")
    try expect(!runner.calls.contains { command($0.arguments) == "kill-window" }, "successful first-run recovery removed its live window")
}

private func checkExistingSessionAdoptsWorkspaceWithoutRestart() throws {
    let existing = workspaceRow(id: "@0", windowName: "agents", active: true)
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output("\(existing)\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(!runner.calls.contains { command($0.arguments) == "new-session" }, "adoption replaced the existing tmux session")
    try expect(!runner.calls.contains { command($0.arguments) == "respawn-pane" }, "adoption restarted a live pane")
    try expect(!runner.calls.contains { command($0.arguments) == "kill-pane" }, "adoption killed a live pane")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@0")
            && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("tmp")
    }, "adoption did not derive the workspace name from the live pane folder")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@0")
            && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "adoption did not persist the live pane folder")
}

private func checkWorkspaceLifecycle() throws {
    let existing = [
        workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp"),
        workspaceRow(id: "@1", windowName: "client", active: false, name: "client", folder: "/private/tmp"),
    ].joined(separator: "\n") + "\n"
    let panes = [
        paneRow(id: "%1", kind: .shell, active: true, windowID: "@0", workspaceName: "parley"),
        paneRow(id: "%2", kind: .codex, active: true, windowID: "@1", workspaceActive: false, workspaceName: "client"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows": output(existing)
        case "list-panes": output(panes)
        case "new-window": output("@2\(TmuxController.outputFieldSeparator)%9\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    let created = try controller.createWorkspace(folder: "/tmp", name: "Server")
    try expect(created.id == "@2" && created.name == "Server", "new workspace lost its tmux id or name")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "new-window" && call.arguments.contains("/tmp")
            && call.arguments.contains(where: { $0.hasPrefix("Parley-Pending-") })
    }, "workspace creation did not create a recoverable tmux window in its folder")
    try expect(runner.calls.contains { command($0.arguments) == "select-window" && $0.arguments.contains("@2") }, "new workspace was not selected")

    let qualified = try controller.createWorkspace(folder: "/tmp", name: "CLIENT")
    try expect(qualified.name == "CLIENT (2)", "duplicate workspace name was not visibly qualified")

    do {
        try controller.renameWorkspace("@1", name: "PARLEY")
        throw CheckFailure(description: "workspace rename accepted a duplicate name")
    } catch let error as ParleyTmuxError {
        try expect(error.errorDescription?.localizedCaseInsensitiveContains("already exists") == true, "duplicate workspace rename failed without an explanation")
    }

    try controller.renameWorkspace("@1", name: "Website")
    try expect(runner.calls.contains { command($0.arguments) == "rename-window" && $0.arguments.contains("Website") }, "workspace rename did not update the tmux window")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-name") && call.arguments.contains("Website")
    }, "workspace rename did not update durable metadata")

    try controller.setWorkspaceFolder("@1", folder: "/tmp")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-workspace-folder") && call.arguments.contains("/tmp")
    }, "workspace folder change was not persisted")

    try controller.closeWorkspace("@1")
    try expect(runner.calls.contains { command($0.arguments) == "kill-window" && $0.arguments.contains("@1") }, "workspace close did not close its tmux window")
}

private func checkWorkspaceCreationRecoversMissingIdentifiers() throws {
    var pendingName = ""
    var windowExists = false
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows":
            return output(workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp") + "\n")
        case "new-window":
            pendingName = arguments.drop(while: { $0 != "-n" }).dropFirst().first ?? ""
            windowExists = true
            return output()
        case "list-panes" where windowExists:
            return output(unclassifiedPaneRow(
                id: "%9",
                windowID: "@2",
                windowName: pendingName,
                cwd: "/tmp",
                currentCommand: "zsh"
            ) + "\n")
        default:
            return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    let created = try controller.createWorkspace(folder: "/tmp", name: "Recovered")

    try expect(created.id == "@2" && created.name == "Recovered", "workspace creation did not recover the ids from live tmux state")
    try expect(pendingName.hasPrefix("Parley-Pending-"), "workspace creation did not use a uniquely recoverable temporary name")
    try expect(!runner.calls.contains { command($0.arguments) == "kill-window" }, "successful workspace recovery killed the created window")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "rename-window" && call.arguments.contains("@2") && call.arguments.contains("Recovered")
    }, "recovered workspace was not committed under its requested name")
}

private func checkWorkspaceCreationCleansAmbiguousPendingWindow() throws {
    var pendingName = ""
    var windowExists = false
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows":
            return output(workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp") + "\n")
        case "new-window":
            pendingName = arguments.drop(while: { $0 != "-n" }).dropFirst().first ?? ""
            windowExists = true
            return output()
        case "list-panes" where windowExists:
            return output([
                unclassifiedPaneRow(id: "%9", windowID: "@2", windowName: pendingName, cwd: "/tmp", currentCommand: "zsh"),
                unclassifiedPaneRow(id: "%10", windowID: "@2", windowName: pendingName, cwd: "/tmp", currentCommand: "zsh"),
            ].joined(separator: "\n") + "\n")
        default:
            return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    do {
        _ = try controller.createWorkspace(folder: "/tmp", name: "Ambiguous")
        throw CheckFailure(description: "workspace creation accepted an ambiguous pending window")
    } catch let error as ParleyTmuxError {
        try expect(
            error.errorDescription?.localizedCaseInsensitiveContains("safely identify") == true,
            "ambiguous workspace recovery failed without a useful explanation"
        )
    }
    try expect(runner.calls.contains { call in
        command(call.arguments) == "kill-window" && call.arguments.contains("@2")
    }, "failed workspace recovery leaked the exact pending window it created")
}

private func checkWorkspaceCreationRetriesExactPendingTarget() throws {
    var pendingName = ""
    var displayAttempts = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows":
            return output(workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp") + "\n")
        case "new-window":
            pendingName = arguments.drop(while: { $0 != "-n" }).dropFirst().first ?? ""
            return output()
        case "display-message":
            displayAttempts += 1
            return displayAttempts == 3 ? output("@2\(TmuxController.outputFieldSeparator)%9\n") : output()
        case "list-panes":
            return output()
        default:
            return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner,
        pause: { _ in }
    )

    let created = try controller.createWorkspace(folder: "/tmp", name: "Delayed")

    try expect(created.id == "@2", "delayed exact-name reconciliation returned the wrong workspace")
    try expect(displayAttempts == 3, "workspace creation did not retry the exact provisional target")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "display-message"
            && call.arguments.contains(where: { $0.contains(pendingName) })
    }, "workspace recovery enumerated state instead of targeting its unique provisional window")
}

private func checkWorkspaceCreationCleansPendingTargetWithoutCapturedIDs() throws {
    var pendingName = ""
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-windows":
            return output(workspaceRow(id: "@0", windowName: "parley", active: true, name: "parley", folder: "/tmp") + "\n")
        case "new-window":
            pendingName = arguments.drop(while: { $0 != "-n" }).dropFirst().first ?? ""
            return output()
        case "display-message", "list-panes":
            return output()
        default:
            return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner,
        pause: { _ in }
    )

    do {
        _ = try controller.createWorkspace(folder: "/tmp", name: "Uncaptured")
        throw CheckFailure(description: "workspace creation succeeded without recovering any identifiers")
    } catch is ParleyTmuxError {
        // The exact cleanup assertion below is the contract under test.
    }

    try expect(runner.calls.contains { call in
        command(call.arguments) == "kill-window"
            && call.arguments.contains("=parley:=\(pendingName)")
    }, "workspace recovery could not clean its unique provisional target without captured ids")
}

private func checkExistingSessionAdoptsOnlyUnclassifiedShells() throws {
    let workspaces = [
        workspaceRow(id: "@6", windowName: "demo", active: true, paneFolder: "/tmp/demo"),
        workspaceRow(id: "@7", windowName: "agent", active: false, paneFolder: "/tmp/agent"),
    ].joined(separator: "\n") + "\n"
    let unclassified = [
        unclassifiedPaneRow(id: "%27", windowID: "@6", windowName: "demo", cwd: "/tmp/demo", currentCommand: "zsh"),
        unclassifiedPaneRow(id: "%28", windowID: "@7", windowName: "agent", cwd: "/tmp/agent", currentCommand: "codex"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "has-session": output()
        case "list-windows": output(workspaces)
        case "list-panes": output(unclassified)
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.bootstrap(cwd: "/tmp")

    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("%27")
            && call.arguments.contains("@parley-kind") && call.arguments.contains("shell")
    }, "existing single-shell workspace was not recovered with metadata only")
    try expect(!runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("%28")
            && call.arguments.contains("@parley-kind")
    }, "an unclassified agent-looking process was incorrectly adopted as a shell")
    try expect(!runner.calls.contains { command($0.arguments) == "respawn-pane" }, "legacy shell adoption restarted a live process")
    try expect(!runner.calls.contains { command($0.arguments) == "kill-pane" || command($0.arguments) == "kill-window" }, "legacy shell adoption killed live state")
}

private func checkWorkspaceContinuityState() throws {
    let api = TmuxWorkspace(id: "@0", name: "api", defaultFolder: "/tmp/api", isActive: false)
    let renamedWeb = TmuxWorkspace(id: "@1", name: "website", defaultFolder: "/tmp/web", isActive: true)
    let worker = TmuxWorkspace(id: "@2", name: "worker", defaultFolder: "/tmp/worker", isActive: false)
    var state = WorkspaceContinuityState(
        favouriteFolders: ["/tmp/api/", "/tmp/api", "/tmp/web"],
        workspaceOrder: [
            WorkspaceBookmark(name: "web", folder: "/tmp/web"),
            WorkspaceBookmark(name: "closed", folder: "/tmp/closed"),
            WorkspaceBookmark(workspace: api),
        ],
        lastSelected: WorkspaceBookmark(name: "web", folder: "/tmp/web")
    )

    let ordered = state.reconcile([api, worker, renamedWeb])
    try expect(ordered.map(\.id) == ["@1", "@0", "@2"], "continuity did not restore tab order and append a new workspace")
    try expect(state.workspaceOrder.map(\.name) == ["website", "api", "worker"], "continuity did not discard stale bookmarks or refresh a renamed workspace")
    try expect(state.lastSelected == WorkspaceBookmark(workspace: renamedWeb), "continuity did not resolve the last workspace through its stable folder")
    try expect(state.selectedWorkspace(in: ordered)?.id == "@1", "continuity restored the wrong selected workspace")
    try expect(state.favouriteFolders == ["/tmp/api", "/tmp/web"], "favourite folders were not standardized and de-duplicated")

    let moved = state.moveWorkspace(id: "@2", by: -1, in: ordered)
    try expect(moved.map(\.id) == ["@1", "@2", "@0"], "workspace move did not update visual tab order")
    let unchanged = state.moveWorkspace(id: "@1", by: -1, in: moved)
    try expect(unchanged.map(\.id) == moved.map(\.id), "workspace move crossed the first-tab boundary")
    try expect(state.workspaceOrder.map(\.name) == ["website", "worker", "api"], "moved tab order was not retained in continuity state")

    let movedAPI = TmuxWorkspace(id: "@0", name: "backend", defaultFolder: "/tmp/backend", isActive: false)
    state.updateWorkspace(from: api, to: movedAPI)
    try expect(state.workspaceOrder.last == WorkspaceBookmark(workspace: movedAPI), "rename/folder update lost the workspace's tab position")
    let movedWeb = TmuxWorkspace(id: "@1", name: "frontend", defaultFolder: "/tmp/frontend", isActive: true)
    state.updateWorkspace(from: renamedWeb, to: movedWeb)
    try expect(state.lastSelected == WorkspaceBookmark(workspace: movedWeb), "rename/folder update lost the last-selected workspace")

    try expect(!state.toggleFavourite(folder: "/tmp/api/"), "removing an existing favourite reported the wrong state")
    try expect(state.toggleFavourite(folder: "/tmp/consumer"), "adding a favourite reported the wrong state")
    try expect(state.favouriteFolders == ["/tmp/web", "/tmp/consumer"], "favourite toggle did not preserve deterministic order")

    let encoded = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WorkspaceContinuityState.self, from: encoded)
    try expect(decoded == state, "workspace continuity state did not round-trip losslessly")
}

private func checkLegacyPreferencesMigration() throws {
    let currentDomain = "parley-check-current-\(UUID().uuidString)"
    let legacyDomain = "parley-check-legacy-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: currentDomain) else {
        throw CheckFailure(description: "could not create isolated preferences")
    }
    defer {
        defaults.removePersistentDomain(forName: currentDomain)
        defaults.removePersistentDomain(forName: legacyDomain)
    }

    defaults.setPersistentDomain([
        "recent": ["/legacy/project"],
        "continuity": Data("legacy".utf8),
        "unrelated": "do not copy",
    ], forName: legacyDomain)
    defaults.set(["/current/project"], forKey: "recent")

    UserDefaultsDomainMigration.copyMissing(
        keys: ["recent", "continuity"],
        from: legacyDomain,
        to: defaults
    )

    try expect(
        defaults.stringArray(forKey: "recent") == ["/current/project"],
        "migration replaced a preference already written by the packaged app"
    )
    try expect(
        defaults.data(forKey: "continuity") == Data("legacy".utf8),
        "migration did not preserve missing development-build continuity"
    )
    try expect(defaults.object(forKey: "unrelated") == nil, "migration copied an unrelated preference")
}

private func checkRuntimeReadinessProbesAreQuotaFree() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-readiness-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let applicationDirectory = root.appendingPathComponent("application", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for command in ["tmux", "claude", "codex", "agy", "copilot"] {
        let executable = bin.appendingPathComponent(command)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    _ = try AgentProtocol.install(in: applicationDirectory)
    _ = try RelayShim.install(
        in: applicationDirectory,
        transportDirectory: root.appendingPathComponent("transport")
    )

    let runner = RecordingRunner { arguments, _ in
        switch arguments {
        case ["-V"]:
            CommandOutput(stdout: Data("tmux ready\n".utf8))
        case ["auth", "status", "--json"]:
            CommandOutput(stdout: Data(#"{"loggedIn":true}"#.utf8))
        case ["login", "status"]:
            CommandOutput(stderr: Data("Not logged in\n".utf8), status: 1)
        case ["models"]:
            CommandOutput(stdout: Data("available models\n".utf8))
        default:
            CommandOutput(stderr: Data("unexpected probe\n".utf8), status: 2)
        }
    }
    let snapshot = RuntimeReadinessChecker(runner: runner).check(
        environment: ["PATH": bin.path],
        applicationDirectory: applicationDirectory,
        coreHealthy: true,
        panes: []
    )

    try expect(snapshot.item(.tmux)?.state == .ready, "tmux readiness was not confirmed")
    try expect(snapshot.item(.core)?.state == .ready, "healthy core was not projected")
    try expect(snapshot.item(.relay)?.state == .ready, "managed relay shim was not recognized")
    try expect(snapshot.item(.protocolRules)?.state == .ready, "current protocol rules were not recognized")
    try expect(snapshot.item(.claude)?.state == .ready, "Claude authentication JSON was not parsed")
    try expect(snapshot.item(.codex)?.state == .attention, "failed Codex login status was not surfaced")
    try expect(snapshot.item(.agy)?.state == .ready, "Agy's quota-free model listing did not confirm access")
    try expect(snapshot.item(.copilot)?.state == .unchecked, "Copilot invented an authentication result")
    try expect(snapshot.readyVendorCount == 2, "ready vendor count did not use confirmed authentication")
    try expect(snapshot.isOperational, "two authenticated vendors and healthy local services should be operational")

    let calls = runner.calls.map(\.arguments)
    try expect(calls.contains(["-V"]), "tmux executable was not probed")
    try expect(calls.contains(["auth", "status", "--json"]), "Claude auth status was not probed")
    try expect(calls.contains(["login", "status"]), "Codex login status was not probed")
    try expect(calls.contains(["models"]), "Agy models status was not probed")
    try expect(
        calls.allSatisfy { arguments in
            if arguments == ["login", "status"] { return true }
            return !arguments.contains("--print")
                && !arguments.contains("-p")
                && !arguments.contains("login")
        },
        "readiness used a model prompt or interactive login command"
    )
    try expect(runner.calls.count == 4, "Copilot was invoked despite lacking a status-only auth command")

    let tmuxOverride = root.appendingPathComponent("custom-tmux")
    try Data().write(to: tmuxOverride)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmuxOverride.path)
    let stalePane = TmuxPane(
        id: "%9",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "claude",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        protocolVersion: "older",
        isStarted: true
    )
    let overrideSnapshot = RuntimeReadinessChecker(runner: runner).check(
        environment: ["PATH": bin.path, "PARLEY_TMUX": tmuxOverride.path],
        applicationDirectory: applicationDirectory,
        coreHealthy: true,
        panes: [stalePane]
    )
    try expect(
        runner.calls[4].executable == tmuxOverride,
        "readiness ignored the same explicit tmux override used by the workbench"
    )
    try expect(
        overrideSnapshot.item(.protocolRules)?.detail.hasPrefix("1 running agent pane") == true,
        "stale protocol count was not rendered with its numeric value"
    )
}

private func checkVendorCompatibilityAndRuntimeSignalsAreTruthful() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-compatibility-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for command in ["claude", "codex", "agy", "copilot"] {
        let executable = bin.appendingPathComponent(command)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    let runner = RecordingRunner { arguments, _ in
        guard arguments == ["--version"] else {
            return CommandOutput(stderr: Data("unexpected compatibility probe".utf8), status: 2)
        }
        return CommandOutput(stdout: Data("vendor cli 7.8.9 SECRET_TRAILING_OUTPUT\n".utf8))
    }
    let readiness = RuntimeReadinessSnapshot(items: PaneKind.allCases.filter(\.isAgent).map { vendor in
        RuntimeReadinessItem(
            id: RuntimeReadinessID(rawValue: vendor.rawValue)!,
            category: .vendor,
            title: vendor.label,
            state: vendor == .copilot ? .unchecked : .ready,
            detail: "PRIVATE_READINESS_DETAIL",
            required: false
        )
    })
    let misleadingPane = TmuxPane(
        id: "%1",
        kind: .claude,
        customName: "Claude",
        terminalTitle: "Working — allow once — task complete",
        cwd: "/private/project",
        currentCommand: "claude",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        bracketedPasteActive: true,
        isStarted: true
    )
    let exitedPane = TmuxPane(
        id: "%2",
        kind: .codex,
        customName: "Codex",
        terminalTitle: "",
        cwd: "/private/project",
        currentCommand: "codex",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        isDead: true,
        exitStatus: 7,
        isStarted: true
    )
    let snapshot = VendorCompatibilityChecker(runner: runner).check(
        environment: [
            "PATH": bin.path,
            "HOME": root.path,
            "LANG": "en_GB.UTF-8",
            "SECRET_TOKEN": "MUST_NOT_REACH_VERSION_PROBE",
        ],
        readiness: readiness,
        panes: [misleadingPane, exitedPane],
        previous: nil,
        checkedAt: Date(timeIntervalSince1970: 500)
    )

    try expect(snapshot.vendors.count == 4, "compatibility omitted a supported vendor")
    try expect(runner.calls.count == 4, "compatibility did not run exactly one version-only probe per installed vendor")
    try expect(
        runner.calls.allSatisfy { $0.arguments == ["--version"] && $0.input?.isEmpty == true },
        "compatibility did not close stdin with an empty, prompt-free version probe"
    )
    try expect(
        runner.calls.allSatisfy {
            $0.environment["PATH"] == bin.path
                && $0.environment["HOME"] == root.path
                && $0.environment["SECRET_TOKEN"] == nil
        },
        "the version-only probe inherited unrelated credentials instead of a minimal launch environment"
    )
    for result in snapshot.vendors {
        try expect(result.version == "7.8.9", "compatibility retained untrusted version-command prose")
        try expect(result.state == .compatible, "an installed compatible vendor was not reported honestly")
        try expect(result.capability(.launch)?.support == .supported, "launch support was omitted")
        try expect(result.capability(.submit)?.support == .supported, "submit support was omitted")
        try expect(result.capability(.askAnswer)?.support == .supported, "Ask/Answer support was omitted")
        try expect(result.capability(.permissions)?.support == .partial, "permission translation was overstated")
    }
    try expect(
        snapshot.runtimeSignals.first(where: { $0.paneID == "%1" })?.state == .unknown,
        "terminal prose was promoted into an official vendor runtime signal"
    )
    try expect(
        snapshot.runtimeSignals.first(where: { $0.paneID == "%2" })?.state == .exited,
        "Parley's authoritative process exit was not surfaced"
    )
    try expect(snapshot.runtimeSignals.allSatisfy { !$0.detail.contains("PRIVATE") }, "runtime signals copied private terminal or readiness prose")

    let changed = VendorCompatibilityChecker(runner: runner).check(
        environment: ["PATH": bin.path],
        readiness: readiness,
        panes: [],
        previous: VendorCompatibilitySnapshot(
            checkedAt: Date(timeIntervalSince1970: 400),
            vendors: snapshot.vendors.map { $0.replacingVersion("7.8.8") },
            runtimeSignals: []
        ),
        checkedAt: Date(timeIntervalSince1970: 600)
    )
    try expect(changed.vendors.allSatisfy(\.versionChanged), "a CLI upgrade was not made visible")

    let timedOut = VendorCompatibilityChecker(runner: RecordingRunner { _, _ in
        CommandOutput(stderr: Data("Command timed out after 8 seconds".utf8), status: 124)
    }).check(environment: ["PATH": bin.path], readiness: readiness, panes: [], previous: nil)
    try expect(
        timedOut.vendors.allSatisfy { $0.detail.contains("timed out") },
        "a bounded version-probe timeout was not distinguished from unparseable output"
    )

    let exited = VendorCompatibilityChecker(runner: RecordingRunner { _, _ in
        CommandOutput(status: 9)
    }).check(environment: ["PATH": bin.path], readiness: readiness, panes: [], previous: nil)
    try expect(
        exited.vendors.allSatisfy { $0.detail.contains("status 9") },
        "a failed version probe hid its content-free exit status"
    )
}

private func checkReleaseLifecycleUsesExplicitVerifiedChannels() throws {
    try expect(
        ReleaseLifecycleError.httpStatus(404).errorDescription?.contains("private") == true,
        "a private release feed did not produce an actionable credential-free explanation"
    )
    try expect(
        ReleaseLifecycleError.httpStatus(403).errorDescription?.contains("rate limit") == true,
        "a public GitHub rate limit did not produce an actionable explanation"
    )
    let dmgName = "Parley-1.3.0-beta.1-mac-arm64.dmg"
    let dmg = Data("fixture dmg bytes".utf8)
    let digest = ReleaseArtifactVerifier.sha256(data: dmg)
    let releasesJSON = Data("""
    [
      {
        "tag_name": "v1.2.0",
        "name": "Parley 1.2.0",
        "body": "Stable notes",
        "draft": false,
        "prerelease": false,
        "html_url": "https://github.com/markjoyeuxcom/parley/releases/tag/v1.2.0",
        "published_at": "2026-08-20T10:00:00Z",
        "assets": []
      },
      {
        "tag_name": "v1.3.0-beta.1",
        "name": "Parley 1.3.0 beta 1",
        "body": "Beta notes",
        "draft": false,
        "prerelease": true,
        "html_url": "https://github.com/markjoyeuxcom/parley/releases/tag/v1.3.0-beta.1",
        "published_at": "2026-08-21T10:00:00Z",
        "assets": [
          {"name":"\(dmgName)","size":\(dmg.count),"browser_download_url":"https://github.com/markjoyeuxcom/parley/releases/download/v1.3.0-beta.1/\(dmgName)"},
          {"name":"Parley-1.3.0-beta.1-mac-arm64.release.json","size":800,"browser_download_url":"https://github.com/markjoyeuxcom/parley/releases/download/v1.3.0-beta.1/manifest"},
          {"name":"Parley-1.3.0-beta.1-mac-arm64.SHA256SUMS","size":200,"browser_download_url":"https://github.com/markjoyeuxcom/parley/releases/download/v1.3.0-beta.1/checksums"}
        ]
      },
      {
        "tag_name": "v9.9.9",
        "name": "Draft",
        "body": "Never visible",
        "draft": true,
        "prerelease": false,
        "html_url": "https://github.com/markjoyeuxcom/parley/releases/tag/v9.9.9",
        "published_at": "2026-08-22T10:00:00Z",
        "assets": []
      }
    ]
    """.utf8)
    let catalog = try GitHubReleaseCatalog.decode(releasesJSON)
    try expect(catalog.selected(for: .stable)?.version == "1.2.0", "stable channel selected a prerelease or draft")
    let beta = try require(catalog.selected(for: .beta), "beta channel found no release")
    try expect(beta.version == "1.3.0-beta.1", "beta channel did not select the newest eligible version")
    try expect(beta.updateState(currentVersion: "1.2.0") == .available, "newer release was not reported as available")
    try expect(beta.updateState(currentVersion: "development") == .unknown, "development build invented an update ordering")

    let manifest = Data("""
    {
      "schemaVersion": 1,
      "application": {"name":"Parley","bundleIdentifier":"com.markjoyeux.parley","version":"1.3.0-beta.1","build":"103"},
      "platform": {"operatingSystem":"macOS","architecture":"arm64","minimumVersion":"14.0"},
      "trust": {"signing":"ad-hoc","notarized":false,"gatekeeperReady":false},
      "source": {"repository":"https://github.com/markjoyeuxcom/parley","commit":"0123456789abcdef0123456789abcdef01234567"},
      "artifacts": [{"file":"\(dmgName)","bytes":\(dmg.count),"sha256":"\(digest)"}]
    }
    """.utf8)
    let checksums = Data("\(digest)  \(dmgName)\n".utf8)
    let verified = try ReleaseMetadataVerifier.verify(
        release: beta,
        manifestData: manifest,
        checksumData: checksums
    )
    try expect(verified.dmgName == dmgName && verified.sha256 == digest, "release metadata lost the verified DMG identity")

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(dmgName)
    try dmg.write(to: file)
    try ReleaseArtifactVerifier.verify(file: file, expected: verified)
    try Data("tampered".utf8).write(to: file)
    do {
        try ReleaseArtifactVerifier.verify(file: file, expected: verified)
        throw CheckFailure(description: "a tampered update artifact was accepted")
    } catch let error as ReleaseLifecycleError {
        try expect(error.errorDescription?.contains("does not match") == true, "tampered artifact failed unclearly")
    }
}

private func checkBetaFeedbackBundleIsReviewedAndPrivacyBounded() throws {
    let secrets = [
        "PROMPT_SECRET_FEEDBACK",
        "ANSWER_SECRET_FEEDBACK",
        "DETAIL_SECRET_FEEDBACK",
        "PATH_SECRET_FEEDBACK",
    ]
    let compatibility = VendorCompatibilitySnapshot(
        checkedAt: Date(timeIntervalSince1970: 700),
        vendors: [VendorCompatibilityResult(
            vendor: .claude,
            installed: true,
            version: "4.5.6",
            state: .compatible,
            detail: secrets[3],
            versionChanged: false,
            capabilities: VendorCompatibilityCapability.allCases.map {
                VendorCompatibilityCapabilityResult(capability: $0, support: $0 == .permissions ? .partial : .supported)
            }
        )],
        runtimeSignals: []
    )
    let conformance = VendorConformanceReport(results: [
        VendorConformanceResult(vendor: .claude, check: "Ask/Answer", outcome: .failed, detail: secrets[2]),
    ])
    let diagnostics = DiagnosticsReportBuilder.build(
        generatedAt: Date(timeIntervalSince1970: 710),
        application: DiagnosticsApplication(
            bundleIdentifier: "com.markjoyeux.parley",
            version: "1.2.3",
            build: "45",
            runtime: "development"
        ),
        operatingSystem: "macOS fixture",
        architecture: "arm64",
        uiResidentBytes: nil,
        coreResidentBytes: nil,
        tmuxAvailable: true,
        coreAvailable: true,
        workspaceCount: 0,
        panes: [],
        handoffs: [],
        readiness: nil
    )
    let bundle = BetaFeedbackBundleBuilder.build(
        generatedAt: Date(timeIntervalSince1970: 720),
        build: BetaFeedbackBuild(
            applicationVersion: "1.2.3",
            buildNumber: "45",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567",
            runtime: "development"
        ),
        updateChannel: .beta,
        compatibility: compatibility,
        conformance: conformance,
        diagnostics: diagnostics
    )
    try expect(bundle.requiresExplicitReview, "feedback could be exported without an explicit review contract")
    try expect(bundle.conformance.first?.detail == nil, "feedback retained a live conformance answer or failure body")
    let encoded = try BetaFeedbackBundleEncoder.encode(bundle)
    let text = String(decoding: encoded, as: UTF8.self)
    for secret in secrets {
        try expect(!text.contains(secret), "beta feedback leaked private value \(secret)")
    }
    try expect(text.contains("4.5.6") && text.contains("failed"), "beta feedback omitted useful compatibility facts")

    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Parley-Beta-Feedback.zip")
    try BetaFeedbackArchiveWriter().write(bundle: bundle, to: archive)
    let extracted = root.appendingPathComponent("feedback", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
    let unzip = try ProcessCommandRunner(timeout: 10).run(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", archive.path, extracted.path],
        environment: ProcessInfo.processInfo.environment,
        input: nil
    )
    try expect(unzip.status == 0, "feedback ZIP could not be extracted")
    let files = try FileManager.default.subpathsOfDirectory(atPath: extracted.path)
    try expect(files.contains(where: { $0.hasSuffix("feedback.json") }), "feedback archive omitted its reviewed manifest")
    try expect(files.contains(where: { $0.hasSuffix("diagnostics.json") }), "feedback archive omitted redacted diagnostics")
    try expect(files.contains(where: { $0.hasSuffix("README.txt") }), "feedback archive omitted its privacy statement")
    for relativePath in files {
        let file = extracted.appendingPathComponent(relativePath)
        let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        for secret in secrets {
            try expect(!content.contains(secret), "feedback archive leaked private value \(secret)")
        }
    }
}

private func checkGitProjectContextParsing() throws {
    let clean = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head feat/project-context
        # branch.upstream origin/feat/project-context
        # branch.ab +0 -0
        """),
        "clean Git status did not produce project context"
    )
    try expect(clean.branch == "feat/project-context", "Git context lost the current branch")
    try expect(!clean.isDirty, "Git context marked a clean worktree dirty")

    let dirty = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head main
        1 .M N... 100644 100644 100644 abcdef0 abcdef0 native/App.swift
        ? native/NewFile.swift
        """),
        "dirty Git status did not produce project context"
    )
    try expect(dirty.branch == "main", "dirty Git context lost the current branch")
    try expect(dirty.isDirty, "tracked or untracked changes did not mark the worktree dirty")

    let detached = try require(
        GitProjectContextResolver.parseStatus("""
        # branch.oid 0123456789abcdef0123456789abcdef01234567
        # branch.head (detached)
        """),
        "detached Git status did not produce project context"
    )
    try expect(detached.branch == "@01234567", "detached Git context did not show a bounded commit identity")
    try expect(GitProjectContextResolver.parseStatus("") == nil, "empty Git output invented repository state")
}

private func checkGitWorktreeDiscoveryParsing() throws {
    let text = [
        "worktree /Users/example/project",
        "HEAD 0123456789abcdef",
        "branch refs/heads/main",
        "",
        "worktree /Users/example/project-review",
        "HEAD fedcba9876543210",
        "detached",
        "locked review in progress",
        "",
    ].joined(separator: "\0")

    let worktrees = GitWorktreeResolver.parsePorcelain(text)
    try expect(worktrees.count == 2, "worktree porcelain did not produce both records")
    try expect(worktrees[0].path == "/Users/example/project", "primary worktree path changed")
    try expect(worktrees[0].branch == "main", "branch ref was not made human-readable")
    try expect(worktrees[0].isPrimary, "the first porcelain record was not identified as primary")
    try expect(worktrees[1].branch == nil && worktrees[1].isDetached, "detached worktree was mislabelled")
    try expect(worktrees[1].lockReason == "review in progress", "worktree lock reason was lost")
    try expect(worktrees[1].shortIdentity == "@fedcba98", "detached identity did not use the bounded commit id")

    let newlineRecords = GitWorktreeResolver.parsePorcelain(text.replacingOccurrences(of: "\0", with: "\n"))
    try expect(newlineRecords == worktrees, "newline and NUL porcelain formats parsed differently")
}

private func checkSharedWorktreeWriterCollisionProjection() throws {
    func pane(
        _ id: String,
        kind: PaneKind = .codex,
        profileID: String,
        started: Bool = true,
        dead: Bool = false
    ) -> TmuxPane {
        TmuxPane(
            id: id,
            kind: kind,
            customName: "Pane \(id)",
            terminalTitle: "",
            cwd: "/Users/example/project",
            currentCommand: kind.rawValue,
            isActive: false,
            windowID: "@0",
            returnToPaneID: nil,
            isDead: dead,
            isStarted: started,
            permissionSelection: PermissionProfileSelection(
                profileID: profileID,
                approvedRoots: ["/Users/example/project"],
                lifetime: .remembered
            ),
            permissionEnforcement: .partiallyEnforced
        )
    }

    let worktree = GitWorktreeRecord(
        path: "/Users/example/project",
        head: "0123456789abcdef",
        branch: "main",
        isDetached: false,
        lockReason: nil,
        pruneReason: nil,
        isPrimary: true
    )
    let panes = [
        pane("%1", kind: .claude, profileID: "flexible"),
        pane("%2", profileID: "broad-workspace"),
        pane("%3", profileID: "default"),
        pane("%4", profileID: "flexible", started: false),
        pane("%5", kind: .shell, profileID: "flexible"),
    ]
    let collisions = WorktreeWriterCollisionProjection.collisions(
        panes: panes,
        profiles: PermissionProfileDefinition.builtIns,
        worktrees: [worktree],
        paneWorktreePaths: Dictionary(uniqueKeysWithValues: panes.map { ($0.id, worktree.path) })
    )

    try expect(collisions.count == 1, "the shared write-capable worktree was not reported once")
    try expect(collisions[0].writers.map(\.paneID) == ["%1", "%2"], "non-writers or stopped panes entered the warning")
    try expect(collisions[0].writers.map(\.permissionProfileName) == ["Flexible", "Broad workspace"], "visible permission evidence was lost")

    let separate = WorktreeWriterCollisionProjection.collisions(
        panes: Array(panes.prefix(2)),
        profiles: PermissionProfileDefinition.builtIns,
        worktrees: [worktree],
        paneWorktreePaths: ["%1": worktree.path, "%2": "/Users/example/other-worktree"]
    )
    try expect(separate.isEmpty, "different canonical worktrees were reported as a collision")
}

private func checkWorkspaceSafetySummaryUsesOnlyAuthoritativeFacts() throws {
    let flexible = PermissionProfileSelection(
        profileID: "flexible",
        approvedRoots: ["/repo"],
        lifetime: .remembered
    )
    let panes = [
        TmuxPane(
            id: "%1", kind: .claude, customName: "Planner", terminalTitle: "", cwd: "/repo",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            isStarted: true, permissionSelection: flexible, permissionEnforcement: .partiallyEnforced
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Stopped reviewer", terminalTitle: "", cwd: "/repo/subdir",
            currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil,
            isStarted: false, permissionSelection: flexible, permissionEnforcement: .enforced
        ),
        TmuxPane(
            id: "%3", kind: .shell, customName: "Tests", terminalTitle: "", cwd: "/other",
            currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil
        ),
        TmuxPane(
            id: "%4", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/repo",
            currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
            isStarted: true, permissionSelection: flexible, permissionEnforcement: .enforced
        ),
    ]
    let active = try statusHandoff(
        id: "active",
        kind: .ask,
        state: .waiting,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 100,
        text: "PROMPT_MUST_NOT_APPEAR",
        resultText: "RESULT_MUST_NOT_APPEAR",
        sourceName: "Planner",
        targetName: "Builder"
    )
    let completed = try statusHandoff(
        id: "complete",
        kind: .delegate,
        state: .completed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 90,
        text: "COMPLETED_PROMPT_MUST_NOT_APPEAR"
    )
    let worktree = GitWorktreeRecord(
        path: "/repo",
        head: "0123456789abcdef",
        branch: "feat/safety",
        isDetached: false,
        lockReason: nil,
        pruneReason: nil,
        isPrimary: true
    )
    let collisions = WorktreeWriterCollisionProjection.collisions(
        panes: panes,
        profiles: PermissionProfileDefinition.builtIns,
        worktrees: [worktree],
        paneWorktreePaths: ["%1": "/repo", "%2": "/repo", "%4": "/repo"]
    )
    let workspace = TmuxWorkspace(
        id: "@0",
        name: "project",
        defaultFolder: "/repo",
        isActive: true
    )
    let summary = WorkspaceSafetyProjection.summary(
        workspace: workspace,
        panes: panes,
        handoffs: [completed, active],
        projectContextsByPaneID: [
            "%1": GitProjectContext(branch: "feat/safety", isDirty: true),
            "%3": GitProjectContext(branch: "main", isDirty: false),
        ],
        paneWorktreePaths: ["%1": "/repo", "%2": "/repo", "%4": "/repo"],
        writerCollisions: collisions,
        coreAvailable: true
    )

    try expect(summary.totalPaneCount == 3, "workspace safety lost a pane")
    try expect(summary.runningAgents.map(\.name) == ["Planner"], "stopped agents or shells were called running agents")
    try expect(summary.activeHandoffs.count == 1 && summary.activeHandoffs[0].id == "active", "terminal handoffs entered the active safety list")
    try expect(summary.dirtyRepositories.count == 1 && summary.dirtyRepositories[0].path == "/repo", "one dirty worktree was duplicated across panes")
    try expect(summary.unavailableRepositoryPaths.isEmpty, "a second pane without its own probe made a known shared worktree unavailable")
    try expect(summary.sharedWriterWorktrees.count == 1, "a cross-workspace shared writer warning was lost")
    try expect(summary.detailText.contains("Planner → Builder · ASK · WAITING"), "handoff identity was not visible")
    try expect(summary.detailText.contains("/repo") && summary.detailText.contains("Flexible"), "path or permission evidence was not visible")
    try expect(!summary.detailText.contains("PROMPT_MUST_NOT_APPEAR"), "safety summary exposed handoff prompt content")
    try expect(!summary.detailText.contains("RESULT_MUST_NOT_APPEAR"), "safety summary exposed handoff answer content")

    let disconnected = WorkspaceSafetyProjection.summary(
        workspace: workspace,
        panes: panes,
        handoffs: [active],
        projectContextsByPaneID: [:],
        paneWorktreePaths: ["%1": "/repo"],
        writerCollisions: [],
        coreAvailable: false
    )
    try expect(!disconnected.handoffStateAvailable, "a disconnected core was presented as authoritative handoff state")
    try expect(disconnected.detailText.lowercased().contains("unavailable"), "unknown handoff state was presented as an all-clear")
    try expect(disconnected.unavailableRepositoryPaths == ["/repo"], "unavailable Git state was silently presented as clean")
}

private func checkCommandPaletteSearch() throws {
    let items = [
        CommandPaletteItem(
            id: "workspace:parley",
            category: .workspace,
            title: "Parley",
            detail: "/tmp/parley"
        ),
        CommandPaletteItem(
            id: "pane:codex",
            category: .pane,
            title: "Codex",
            detail: "connect4-3d · /tmp/connect4-3d",
            keywords: ["OpenAI"]
        ),
        CommandPaletteItem(
            id: "ask:codex",
            category: .ask,
            title: "Ask Codex",
            detail: "connect4-3d"
        ),
        CommandPaletteItem(
            id: "activity:review",
            category: .activity,
            title: "Agy → Codex",
            detail: "Review authentication retry plan",
            keywords: ["waiting", "auth"]
        ),
    ]

    try expect(
        CommandPaletteSearch.results(query: "", items: items).map(\.id) == items.map(\.id),
        "empty palette query did not preserve intentional command order"
    )
    try expect(
        CommandPaletteSearch.results(query: "CoDeX", items: items).first?.id == "pane:codex",
        "exact case-insensitive title match did not outrank partial titles"
    )
    try expect(
        CommandPaletteSearch.results(query: "codex auth", items: items).map(\.id) == ["activity:review"],
        "palette search did not require every query token across item metadata"
    )
    try expect(
        Set(CommandPaletteSearch.results(query: "connect4", items: items).map(\.id)) == ["pane:codex", "ask:codex"],
        "palette search did not match item detail text"
    )
    try expect(
        CommandPaletteSearch.results(query: "codex", items: items, limit: 2).count == 2,
        "palette search ignored its result bound"
    )
}

private func checkAccessibilityDescriptions() throws {
    let command = CommandPaletteItem(
        id: "activity:review",
        category: .activity,
        title: "Review returned",
        detail: "Codex answered Agy"
    )
    try expect(
        WorkbenchAccessibility.command(command)
            == "Activity: Review returned. Codex answered Agy",
        "command palette accessibility description lost its category or detail"
    )

    let handoff = try statusHandoff(
        id: "audit",
        kind: .ask,
        state: .failed,
        sourceWorkspaceID: "app",
        targetWorkspaceID: "library",
        occurredAt: 50,
        attention: .permissionRequired,
        origin: .human
    )
    try expect(
        WorkbenchAccessibility.handoff(handoff)
            == "Source audit to Target audit. Ask, failed, permission required. Task audit. Human initiated",
        "handoff accessibility description lost authoritative state"
    )
    let longHandoff = try statusHandoff(
        id: "long",
        kind: .delegate,
        state: .completed,
        sourceWorkspaceID: "app",
        targetWorkspaceID: "library",
        occurredAt: 51,
        text: String(repeating: "long instruction ", count: 40)
    )
    let longDescription = WorkbenchAccessibility.handoff(longHandoff)
    try expect(
        longDescription.count < 300 && longDescription.hasSuffix("…"),
        "handoff accessibility description read an unbounded prompt body"
    )

    let counts = StatusCenterCounts(
        runningAgents: 2,
        stoppedAgents: 1,
        outstandingQuestions: 3,
        trackedDelegations: 4,
        failures: 1,
        unreadResults: 2
    )
    try expect(
        WorkbenchAccessibility.counts(counts)
            == "2 running agents, 1 stopped agent, 3 questions, 4 delegations, 2 unread results, 1 failure",
        "Status Center count description was incomplete or grammatically ambiguous"
    )

    let exited = TmuxPane(
        id: "%7", kind: .codex, customName: "Audit", terminalTitle: "", cwd: "/tmp/library",
        currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
        bracketedPasteActive: true, isDead: true, exitStatus: 7, role: "reviewer"
    )
    try expect(
        WorkbenchAccessibility.agent(exited)
            == "Audit, Codex agent. Exited with status 7. Protocol v\(AgentProtocol.version), current. Routing role reviewer. Workspace library",
        "agent accessibility description hid its exited state or workspace"
    )

    let event = StatusTimelineEvent(
        id: "event",
        handoffID: "audit",
        title: "Source audit to Target audit",
        category: "ASK",
        action: "FAILED",
        occurredAt: Date(timeIntervalSince1970: 50),
        detail: "Permission required",
        origin: .human
    )
    try expect(
        WorkbenchAccessibility.timeline(event)
            == "Source audit to Target audit. Ask, failed. Human initiated. Permission required",
        "timeline accessibility description lost origin or failure detail"
    )
}

private func checkSavedWorkspaceLayoutPersistenceAndFreshSlots() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("workspace-layouts.json")
    let flexibleSelection = PermissionProfileSelection(
        profileID: "flexible",
        approvedRoots: ["/tmp/project"],
        lifetime: .remembered
    )
    let layout = SavedWorkspaceLayout(
        name: "Review Pair",
        defaultFolder: "/tmp/project",
        root: .split(
            direction: .horizontal,
            ratio: 0.6,
            first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Tests", folder: "/tmp/project")),
            second: .split(
                direction: .vertical,
                ratio: 0.45,
                first: .leaf(SavedLayoutLeaf(
                    kind: .codex,
                    name: "Reviewer",
                    folder: "/tmp/project",
                    permissionSelection: flexibleSelection
                )),
                second: .leaf(SavedLayoutLeaf(kind: .agy, name: "Second opinion", folder: "/tmp/consumer"))
            )
        )
    )
    let firstRestoration = layout.fromSavedLayout()
    let secondRestoration = layout.fromSavedLayout()
    try expect(firstRestoration.slots.count == 3, "saved layout did not restore every leaf as a slot")
    try expect(firstRestoration.slots.allSatisfy { $0.paneID == nil && !$0.isStarted }, "fromSavedLayout started a process or reused a pane id")
    try expect(
        Set(firstRestoration.slots.map(\.id)).isDisjoint(with: Set(secondRestoration.slots.map(\.id))),
        "restoring the same saved layout reused live slot ids"
    )
    try expect(firstRestoration.slots.map(\.folder) == ["/tmp/project", "/tmp/project", "/tmp/consumer"], "saved layout collapsed per-pane folders into the default")
    try expect(
        firstRestoration.slots.first(where: { $0.kind == .codex })?.permissionSelection == flexibleSelection,
        "saved layout restoration lost the agent permission profile"
    )

    let encoded = try JSONEncoder().encode(layout)
    let json = try require(String(data: encoded, encoding: .utf8), "saved layout JSON was not UTF-8")
    try expect(!json.contains("paneID") && !json.contains("slot") && !json.contains("%"), "persisted layout leaked live identifiers")
    let decoded = try JSONDecoder().decode(SavedWorkspaceLayout.self, from: encoded)
    try expect(decoded == layout, "saved layout did not round-trip losslessly")

    let store = SavedWorkspaceLayoutStore(file: file)
    try store.save(layout)
    let initiallyStored = try store.layouts()
    try expect(initiallyStored == [layout], "layout store did not persist its first layout")
    var metadata = stat()
    try expect(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "saved layout file was not owner-only")

    let replacement = SavedWorkspaceLayout(
        name: "review pair",
        defaultFolder: "/tmp/replacement",
        root: .leaf(SavedLayoutLeaf(kind: .shell, name: "Shell", folder: "/tmp/replacement"))
    )
    try store.save(replacement)
    let replaced = try store.layouts()
    try expect(replaced == [replacement], "case-insensitive layout replacement created a duplicate name")
    try store.delete(named: "REVIEW PAIR")
    let afterDeletion = try store.layouts()
    try expect(afterDeletion.isEmpty, "case-insensitive layout deletion left the saved layout behind")
}

private func checkPortableTeamTemplatePersistenceAndApplication() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("team-templates.json")
    let template = TeamTemplate(
        name: "Implementation Trio",
        root: .split(
            direction: .horizontal,
            ratio: 0.55,
            first: .leaf(TeamTemplateLeaf(
                kind: .claude,
                name: "Planner",
                isWorkspaceLead: true,
                permissionProfile: TeamTemplatePermission(
                    profileID: "review-only",
                    lifetime: .remembered
                )
            )),
            second: .split(
                direction: .vertical,
                ratio: 0.5,
                first: .leaf(TeamTemplateLeaf(
                    kind: .codex,
                    name: "Builder",
                    role: "implementer",
                    permissionProfile: TeamTemplatePermission(
                        profileID: "flexible",
                        lifetime: .remembered
                    )
                )),
                second: .leaf(TeamTemplateLeaf(
                    kind: .agy,
                    name: "Review",
                    role: "reviewer"
                ))
            )
        ),
        automationPolicy: .askAndDelegate
    )

    let applied = try template.workspaceLayout(
        folder: "/tmp/project",
        workspaceName: "Project Team"
    )
    let recaptured = try TeamTemplate.capturing(applied, name: template.name)
    try expect(recaptured == template, "capturing a live workspace did not produce the same portable team definition")
    try expect(applied.name == "Project Team", "applying a team template lost the requested workspace name")
    try expect(
        applied.root.leaves.allSatisfy { $0.folder == "/tmp/project" },
        "a portable team retained a source-machine pane folder"
    )
    try expect(
        applied.root.leaves.map(\.role) == [nil, "implementer", "reviewer"],
        "applying a team template lost its stable pane roles"
    )
    try expect(
        applied.root.leaves.first?.isWorkspaceLead == true,
        "applying a team template lost its workspace lead"
    )
    let builder = try require(
        applied.root.leaves.first(where: { $0.role == "implementer" }),
        "the applied team omitted its implementer"
    )
    try expect(
        builder.permissionSelection == PermissionProfileSelection(
            profileID: "flexible",
            approvedRoots: ["/tmp/project"],
            lifetime: .remembered
        ),
        "a portable permission profile was not rebound to the selected folder"
    )
    try expect(
        applied.fromSavedLayout().slots.allSatisfy { $0.paneID == nil && !$0.isStarted },
        "applying a team template started an agent or reused a live pane id"
    )

    let encoded = try JSONEncoder().encode(template)
    let json = try require(String(data: encoded, encoding: .utf8), "team template JSON was not UTF-8")
    for forbidden in ["/tmp/project", "approvedRoots", "paneID", "windowID", "credential"] {
        try expect(!json.contains(forbidden), "portable team template persisted forbidden state: \(forbidden)")
    }
    let decoded = try JSONDecoder().decode(TeamTemplate.self, from: encoded)
    try expect(decoded == template, "team template did not round-trip")

    let store = TeamTemplateStore(file: file)
    try store.save(template)
    let initiallyStored = try store.templates()
    try expect(initiallyStored == [template], "team template store did not persist its first template")
    var metadata = stat()
    try expect(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "team template file was not owner-only")

    let replacement = TeamTemplate(
        name: "implementation trio",
        root: .leaf(TeamTemplateLeaf(kind: .copilot, name: "Builder", role: "implementer"))
    )
    try store.save(replacement)
    let replaced = try store.templates()
    try expect(replaced == [replacement], "case-insensitive team replacement created a duplicate")

    let ambiguous = TeamTemplate(
        name: "Ambiguous",
        root: .split(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(TeamTemplateLeaf(kind: .claude, name: "One", role: "reviewer")),
            second: .leaf(TeamTemplateLeaf(kind: .codex, name: "Two", role: "reviewer"))
        )
    )
    do {
        try store.save(ambiguous)
        throw CheckFailure(description: "team template store accepted an ambiguous pane role")
    } catch let error as TeamTemplateStoreError {
        try expect(error.localizedDescription.contains("unique"), "duplicate-role refusal was unclear")
    }

    let reserved = TeamTemplate(
        name: "Reserved",
        root: .leaf(TeamTemplateLeaf(kind: .codex, name: "Review", role: "codex"))
    )
    do {
        try store.save(reserved)
        throw CheckFailure(description: "team template store accepted a vendor name as a role")
    } catch let error as TeamTemplateStoreError {
        try expect(error.localizedDescription.contains("reserved"), "reserved-role refusal was unclear")
    }
}

private func checkPaneMobilitySafetyContract() throws {
    let source = TmuxPane(
        id: "%1", kind: .claude, customName: "Planner", terminalTitle: "", cwd: "/tmp/project",
        currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "project",
        bracketedPasteActive: true, isStarted: true, isWorkspaceLead: true, role: "planner"
    )
    let sourcePeer = TmuxPane(
        id: "%2", kind: .shell, customName: "Tests", terminalTitle: "", cwd: "/tmp/project",
        currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil,
        workspaceName: "project"
    )
    let targetPane = TmuxPane(
        id: "%3", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp/consumer",
        currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "consumer",
        bracketedPasteActive: true, isStarted: true, role: "builder"
    )

    let safeMove = PaneMobilityPolicy.assess(
        action: .move,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, sourcePeer, targetPane],
        activeHandoffCount: 0
    )
    try expect(safeMove.isAllowed, "a safe cross-workspace pane move was refused")

    let sameWorkspace = PaneMobilityPolicy.assess(
        action: .move,
        pane: source,
        targetWorkspaceID: "@0",
        panes: [source, sourcePeer, targetPane],
        activeHandoffCount: 0
    )
    try expect(sameWorkspace.blockers == [.sameWorkspace], "same-workspace mobility was not refused explicitly")

    let lastSourcePane = PaneMobilityPolicy.assess(
        action: .move,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, targetPane],
        activeHandoffCount: 0
    )
    try expect(lastSourcePane.blockers == [.lastSourcePane], "moving the last source pane was not refused")

    let activeMove = PaneMobilityPolicy.assess(
        action: .move,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, sourcePeer, targetPane],
        activeHandoffCount: 2
    )
    try expect(activeMove.blockers == [.activeHandoffs(2)], "a move with active handoffs was not refused")

    let cloneWithHandoffs = PaneMobilityPolicy.assess(
        action: .clone,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, sourcePeer, targetPane],
        activeHandoffCount: 2
    )
    try expect(cloneWithHandoffs.isAllowed, "configuration cloning was coupled to source handoff lifecycle")
    try expect(cloneWithHandoffs.activeHandoffCount == 2, "clone preview lost the source handoff count")

    let conflictingRole = TmuxPane(
        id: "%4", kind: .agy, customName: "Other planner", terminalTitle: "", cwd: "/tmp/consumer",
        currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil,
        workspaceName: "consumer", role: "PLANNER"
    )
    let roleConflict = PaneMobilityPolicy.assess(
        action: .clone,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, sourcePeer, targetPane, conflictingRole],
        activeHandoffCount: 0
    )
    try expect(roleConflict.blockers == [.roleConflict("planner")], "duplicate target routing role was not refused")

    let targetLead = TmuxPane(
        id: "%5", kind: .codex, customName: "Lead", terminalTitle: "", cwd: "/tmp/consumer",
        currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
        workspaceName: "consumer", isWorkspaceLead: true
    )
    let leadConflict = PaneMobilityPolicy.assess(
        action: .move,
        pane: source,
        targetWorkspaceID: "@1",
        panes: [source, sourcePeer, targetPane, targetLead],
        activeHandoffCount: 0
    )
    try expect(leadConflict.blockers == [.leadConflict], "duplicate target workspace leads were not refused")

    var moved = false
    let beforeMoveRows = [
        paneRow(
            id: "%1", kind: .claude, active: true, name: "Planner",
            relayEnabled: true, protocolVersion: AgentProtocol.version,
            windowID: "@0", workspaceActive: true, workspaceName: "project",
            isLead: true, role: "planner"
        ),
        paneRow(id: "%2", kind: .shell, active: false, windowID: "@0", workspaceActive: true, workspaceName: "project"),
        paneRow(id: "%3", kind: .codex, active: false, windowID: "@1", workspaceActive: false, workspaceName: "consumer"),
    ].joined(separator: "\n") + "\n"
    let afterMoveRows = [
        paneRow(id: "%2", kind: .shell, active: false, windowID: "@0", workspaceActive: false, workspaceName: "project"),
        paneRow(
            id: "%1", kind: .claude, active: true, name: "Planner",
            relayEnabled: true, protocolVersion: AgentProtocol.version,
            windowID: "@1", workspaceActive: true, workspaceName: "consumer",
            isLead: true, role: "planner"
        ),
        paneRow(id: "%3", kind: .codex, active: false, windowID: "@1", workspaceActive: true, workspaceName: "consumer"),
    ].joined(separator: "\n") + "\n"
    let moveRunner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes": return output(moved ? afterMoveRows : beforeMoveRows)
        case "join-pane":
            moved = true
            return output()
        default: return output()
        }
    }
    let moveController = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: moveRunner
    )
    let movedPane = try moveController.movePane(
        "%1", toWorkspaceID: "@1", direction: .horizontal, activeHandoffCount: 0
    )
    try expect(movedPane.id == "%1" && movedPane.windowID == "@1", "live pane move changed identity or missed its destination")
    try expect(
        moveRunner.calls.contains {
            command($0.arguments) == "join-pane"
                && $0.arguments.contains("-s") && $0.arguments.contains("%1")
                && $0.arguments.contains("-t") && $0.arguments.contains("%3")
                && $0.arguments.contains("-h")
        },
        "live pane move did not use tmux join-pane with explicit source and target ids"
    )
    try expect(
        !moveRunner.calls.contains { command($0.arguments) == "respawn-pane" },
        "live pane move restarted a process instead of preserving it"
    )

    let blockedJoinCount = moveRunner.calls.filter { command($0.arguments) == "join-pane" }.count
    do {
        _ = try moveController.movePane(
            "%1", toWorkspaceID: "@0", direction: .horizontal, activeHandoffCount: 1
        )
        throw CheckFailure(description: "controller moved a pane with an active handoff")
    } catch let error as ParleyTmuxError {
        try expect(error.localizedDescription.contains("handoff"), "controller handoff refusal was unclear")
    }
    try expect(
        moveRunner.calls.filter { command($0.arguments) == "join-pane" }.count == blockedJoinCount,
        "blocked mobility still reached tmux join-pane"
    )

    var cloned = false
    let clonedPermission = PermissionProfileSelection(
        profileID: "flexible",
        approvedRoots: ["/tmp"],
        lifetime: .remembered
    )
    let flexibleDefinition = try require(
        PermissionProfileDefinition.builtIns.first(where: { $0.id == "flexible" }),
        "the Flexible permission profile was unavailable"
    )
    let reboundPermission = try PermissionProfileResolver.resolve(
        definition: flexibleDefinition,
        paneFolder: "/tmp"
    ).selection
    let cloneSourceRows = [
        paneRow(
            id: "%1", kind: .claude, active: true, name: "Planner",
            relayEnabled: true, protocolVersion: AgentProtocol.version,
            windowID: "@0", workspaceActive: true, workspaceName: "project",
            isLead: true, permissionSelection: clonedPermission,
            permissionEnforcement: .partiallyEnforced, role: "planner"
        ),
        paneRow(id: "%2", kind: .shell, active: false, windowID: "@0", workspaceActive: true, workspaceName: "project"),
        paneRow(id: "%3", kind: .codex, active: false, windowID: "@1", workspaceActive: false, workspaceName: "consumer"),
    ].joined(separator: "\n") + "\n"
    let cloneResultRows = cloneSourceRows + paneRow(
        id: "%4", kind: .claude, active: false, name: "Planner", currentCommand: "sleep",
        windowID: "@1", workspaceActive: false, workspaceName: "consumer",
        started: false, isLead: true, permissionSelection: reboundPermission,
        permissionEnforcement: .partiallyEnforced, role: "planner"
    ) + "\n"
    let cloneRunner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes": return output(cloned ? cloneResultRows : cloneSourceRows)
        case "split-window":
            cloned = true
            return output("%4\n")
        default: return output()
        }
    }
    let cloneController = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: cloneRunner
    )
    let clone = try cloneController.clonePaneConfiguration(
        "%1", toWorkspaceID: "@1", direction: .vertical, activeHandoffCount: 2
    )
    try expect(clone.id == "%4" && !clone.isStarted, "agent configuration clone started a vendor session")
    try expect(
        cloneRunner.calls.contains {
            command($0.arguments) == "split-window"
                && $0.arguments.contains("-t") && $0.arguments.contains("%3")
                && $0.arguments.contains("-v")
        },
        "configuration clone did not split the chosen destination workspace"
    )
    try expect(
        cloneRunner.calls.contains {
            command($0.arguments) == "respawn-pane"
                && $0.arguments.contains("%4")
                && $0.arguments.contains("/bin/sleep")
                && $0.arguments.contains("2147483647")
        },
        "agent configuration clone did not become an inert stopped placeholder"
    )
    try expect(
        !cloneRunner.calls.contains {
            command($0.arguments) == "respawn-pane"
                && $0.arguments.contains(where: { $0 == "claude" })
        },
        "configuration clone launched the source vendor CLI"
    )
    try expect(
        cloneRunner.calls.contains { $0.arguments.contains("@parley-role") && $0.arguments.contains("planner") }
            && cloneRunner.calls.contains { $0.arguments.contains("@parley-lead") && $0.arguments.contains("1") }
            && cloneRunner.calls.contains {
                $0.arguments.contains("@parley-permission-selection")
                    && $0.arguments.contains(reboundPermission.tmuxMetadataValue)
            },
        "configuration clone lost its permission profile, stable role or Workspace Lead stamp"
    )
}

private func checkExternalWorkspaceOpenContract() throws {
    let folder = try temporaryDirectory()
    let canonicalFolder = canonicalPath(folder.path)
    let request = try ExternalWorkspaceOpen.request(folderPath: folder.path)
    try expect(
        request == ExternalWorkspaceOpenRequest(folder: canonicalFolder),
        "external folder routing did not canonicalise its one visible input"
    )
    let finderRequest = try ExternalWorkspaceOpen.request(folderPaths: [folder.path])
    try expect(
        finderRequest == request,
        "Finder folder routing did not use the same one-folder contract"
    )

    for invalidSelection in [[], [folder.path, folder.path]] {
        do {
            _ = try ExternalWorkspaceOpen.request(folderPaths: invalidSelection)
            throw CheckFailure(description: "external route accepted \(invalidSelection.count) folders")
        } catch ExternalWorkspaceOpenError.oneFolderRequired {
            // Expected: no entry point can turn one user action into several workspaces.
        }
    }

    let url = try ExternalWorkspaceOpen.url(forFolder: folder.path)
    try expect(url.scheme == "parley" && url.host == "open", "external URL generation used the wrong route")
    let roundTrippedRequest = try ExternalWorkspaceOpen.request(url: url)
    try expect(
        roundTrippedRequest == request,
        "parley URL routing did not round-trip an encoded folder"
    )

    let unicodeFolder = folder.appendingPathComponent("UI review #2", isDirectory: true)
    try FileManager.default.createDirectory(at: unicodeFolder, withIntermediateDirectories: false)
    let unicodeURL = try ExternalWorkspaceOpen.url(forFolder: unicodeFolder.path)
    let unicodeRequest = try ExternalWorkspaceOpen.request(url: unicodeURL)
    try expect(
        unicodeRequest.folder == canonicalPath(unicodeFolder.path),
        "parley URL routing damaged spaces or reserved URL characters"
    )

    let forbiddenURLs = [
        URL(string: "https://open?folder=\(folder.path)")!,
        URL(string: "parley://ask?folder=\(folder.path)")!,
        URL(string: "parley://open?folder=relative")!,
        URL(string: "parley://open?folder=\(folder.path)&prompt=run%20tests")!,
        URL(string: "parley://open?folder=\(folder.path)&folder=\(folder.path)")!,
        URL(string: "parley://open?folder=\(folder.path)#fragment")!,
    ]
    for forbidden in forbiddenURLs {
        do {
            _ = try ExternalWorkspaceOpen.request(url: forbidden)
            throw CheckFailure(description: "external route accepted unsupported authority: \(forbidden.absoluteString)")
        } catch is ExternalWorkspaceOpenError {
            // Expected: the external contract can carry a folder, never work.
        }
    }

    let file = folder.appendingPathComponent("README.md")
    try Data("not a workspace".utf8).write(to: file)
    do {
        _ = try ExternalWorkspaceOpen.request(folderPath: file.path)
        throw CheckFailure(description: "external workspace route accepted a file")
    } catch ExternalWorkspaceOpenError.notDirectory {
        // Expected.
    }
}

private func checkExternalEditorContextImportContract() throws {
    let applicationDirectory = try temporaryDirectory()
    let project = try temporaryDirectory()
    let sourceDirectory = project.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
    let sourceFile = sourceDirectory.appendingPathComponent("Game.swift")
    try Data("let winner = connectFour()\n".utf8).write(to: sourceFile)

    let inbox = ExternalContextImport.inboxDirectory(applicationDirectory: applicationDirectory)
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)

    func write(_ manifest: ExternalContextImportManifest, mode: Int = 0o600) throws -> URL {
        let file = inbox.appendingPathComponent("\(UUID().uuidString.lowercased()).parleycontext")
        try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }

    let manifest = ExternalContextImportManifest(
        version: ExternalContextImport.currentVersion,
        folder: project.path,
        items: [
            ExternalContextImportItem(
                kind: .selection,
                file: "Sources/Game.swift",
                startLine: 1,
                endLine: 1,
                text: "let winner = connectFour()"
            ),
            ExternalContextImportItem(kind: .currentFile, file: "Sources/Game.swift"),
            ExternalContextImportItem(
                kind: .diagnostics,
                file: "Sources/Game.swift",
                text: "Sources/Game.swift:1:5 warning: example diagnostic"
            ),
        ]
    )
    let importFile = try write(manifest)
    let request = try ExternalContextImport.consume(
        file: importFile,
        applicationDirectory: applicationDirectory,
        builder: ContextPackBuilder()
    )
    try expect(request.folder == canonicalPath(project.path), "editor context import lost its canonical workspace")
    try expect(
        request.parts.map(\.source.kind) == [.editorSelection, .file, .editorDiagnostics],
        "editor context import changed explicit source attribution"
    )
    try expect(request.parts[0].source.detail.contains("Sources/Game.swift:1"), "selection range provenance disappeared")
    try expect(request.parts[1].capturedText.contains("connectFour"), "current-file import trusted supplied text instead of recapturing the file")
    try expect(!FileManager.default.fileExists(atPath: importFile.path), "one-shot editor context manifest remained reusable")

    let escaped = try write(ExternalContextImportManifest(
        version: ExternalContextImport.currentVersion,
        folder: project.path,
        items: [ExternalContextImportItem(kind: .currentFile, file: "../outside.txt")]
    ))
    do {
        _ = try ExternalContextImport.consume(
            file: escaped,
            applicationDirectory: applicationDirectory,
            builder: ContextPackBuilder()
        )
        throw CheckFailure(description: "editor context import escaped its declared workspace")
    } catch ExternalContextImportError.invalidItem {
        // Expected.
    }

    let loose = try write(manifest, mode: 0o644)
    do {
        _ = try ExternalContextImport.consume(
            file: loose,
            applicationDirectory: applicationDirectory,
            builder: ContextPackBuilder()
        )
        throw CheckFailure(description: "editor context import accepted a non-private manifest")
    } catch ExternalContextImportError.unsafeManifest {
        // Expected.
    }

    let linkedApplication = try temporaryDirectory()
    let linkedTarget = linkedApplication.appendingPathComponent("inbox-target", isDirectory: true)
    try FileManager.default.createDirectory(at: linkedTarget, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: linkedTarget.path)
    let linkedInbox = ExternalContextImport.inboxDirectory(applicationDirectory: linkedApplication)
    try FileManager.default.createSymbolicLink(at: linkedInbox, withDestinationURL: linkedTarget)
    let linkedFile = linkedInbox.appendingPathComponent("\(UUID().uuidString.lowercased()).parleycontext")
    try JSONEncoder().encode(manifest).write(to: linkedFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: linkedFile.path)
    do {
        _ = try ExternalContextImport.consume(
            file: linkedFile,
            applicationDirectory: linkedApplication,
            builder: ContextPackBuilder()
        )
        throw CheckFailure(description: "editor context import followed a substituted inbox symlink")
    } catch ExternalContextImportError.unsafeManifest {
        // Expected.
    }

    let outside = applicationDirectory.appendingPathComponent("outside.parleycontext")
    try JSONEncoder().encode(manifest).write(to: outside)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    do {
        _ = try ExternalContextImport.consume(
            file: outside,
            applicationDirectory: applicationDirectory,
            builder: ContextPackBuilder()
        )
        throw CheckFailure(description: "editor context import read outside its private inbox")
    } catch ExternalContextImportError.unsafeManifest {
        // Expected.
    }
}

private func checkExternalAttentionAndNavigationContract() throws {
    let workspaces = [
        TmuxWorkspace(id: "@0", name: "Library", defaultFolder: "/tmp/library", isActive: true),
        TmuxWorkspace(id: "@1", name: "Consumer", defaultFolder: "/tmp/consumer", isActive: false),
    ]
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Reviewer", terminalTitle: "SECRET TITLE", cwd: "/tmp/library", currentCommand: "SECRET COMMAND", isActive: true, windowID: "@0", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Library", isStarted: true),
        TmuxPane(id: "%2", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "claude", isActive: false, windowID: "@1", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Consumer", isStarted: true),
        TmuxPane(id: "%3", kind: .shell, customName: "Server", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "zsh", isActive: false, windowID: "@1", returnToPaneID: nil),
    ]
    let resultID = "11111111-1111-4111-8111-111111111111"
    let permissionID = "22222222-2222-4222-8222-222222222222"
    let viewedID = "33333333-3333-4333-8333-333333333333"
    let delegationID = "44444444-4444-4444-8444-444444444444"
    let failedID = "55555555-5555-4555-8555-555555555555"
    let handoffs = [
        try statusHandoff(id: resultID, kind: .ask, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 20, text: "PROMPT SECRET", resultText: "ANSWER SECRET", sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: permissionID, kind: .relay, state: .failed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 30, text: "SECOND SECRET", attention: .permissionRequired, sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: viewedID, kind: .ask, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 10, resultText: "VIEWED SECRET", readAt: 11),
        try statusHandoff(id: delegationID, kind: .delegate, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 40, text: "DELEGATION SECRET", resultText: "COMPLETION SECRET", sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: failedID, kind: .ask, state: .failed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 50, text: "FAILURE SECRET", sourceName: "Reviewer", targetName: "Builder"),
    ]
    let generatedAt = Date(timeIntervalSince1970: 100)
    let snapshot = ExternalAttentionProjection.snapshot(
        workspaces: workspaces,
        panes: panes,
        handoffs: handoffs,
        generatedAt: generatedAt
    )
    try expect(snapshot.version == ExternalAttentionSnapshot.currentVersion, "external attention snapshot lost its contract version")
    try expect(snapshot.generatedAt == generatedAt, "external attention snapshot lost its heartbeat time")
    try expect(snapshot.attentionCount == 4, "external attention count included viewed or routine work")
    try expect(snapshot.workspaces.map(\.attentionCount) == [3, 1], "external attention was attributed to the wrong workspace")
    try expect(snapshot.panes.map(\.id) == ["%1", "%2"], "external pane focus exposed a shell or lost a live agent")
    try expect(snapshot.items.map(\.handoffID) == [failedID, delegationID, permissionID, resultID], "external attention items were not newest-first")
    try expect(snapshot.items.map(\.reason) == [.interrupted, .returnedResult, .humanInputRequired, .returnedResult], "external attention reasons were inferred incorrectly")
    try expect(snapshot.items[0].label == "Reviewer → Builder failed", "failed work lost its specific content-free label")
    try expect(snapshot.items[1].label == "Builder completed a delegation", "a completed delegation was not labelled specifically")
    try expect(snapshot.items[2].label == "Builder needs permission review", "permission attention lost its specific content-free label")
    try expect(snapshot.items[3].label == "Builder returned an answer", "an Ask result was not labelled as an answer")

    let encoded = try JSONEncoder().encode(snapshot)
    let visible = String(decoding: encoded, as: UTF8.self)
    for secret in ["PROMPT SECRET", "ANSWER SECRET", "SECOND SECRET", "VIEWED SECRET", "DELEGATION SECRET", "COMPLETION SECRET", "FAILURE SECRET", "SECRET TITLE", "SECRET COMMAND", "/tmp/library"] {
        try expect(!visible.contains(secret), "external attention snapshot exposed content or process metadata: \(secret)")
    }

    let applicationDirectory = try temporaryDirectory()
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationDirectory.path)
    let file = try ExternalAttentionSnapshotFile.write(snapshot, applicationDirectory: applicationDirectory)
    try expect(file.lastPathComponent == "external-attention.json", "external attention used an unstable discovery path")
    let permissions = try require(
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber,
        "external attention file permissions were unavailable"
    )
    try expect(permissions.intValue & 0o077 == 0, "external attention snapshot was readable outside its owner")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let published = try decoder.decode(ExternalAttentionSnapshot.self, from: Data(contentsOf: file))
    try expect(published == snapshot, "published external attention snapshot did not round-trip")

    let paneRoute = ExternalNavigationRequest.pane("%2")
    let paneURL = try ExternalNavigation.url(for: paneRoute)
    let parsedPaneRoute = try ExternalNavigation.request(url: paneURL)
    try expect(
        parsedPaneRoute == paneRoute,
        "external pane focus did not round-trip its bounded URL"
    )
    let handoffRoute = ExternalNavigationRequest.handoff(permissionID)
    let handoffURL = try ExternalNavigation.url(for: handoffRoute)
    let parsedHandoffRoute = try ExternalNavigation.request(url: handoffURL)
    try expect(
        parsedHandoffRoute == handoffRoute,
        "external Status Center focus did not round-trip its bounded URL"
    )
    let forbidden = [
        "parley://focus?pane=%252&prompt=run",
        "parley://focus?pane=codex",
        "parley://status?handoff=not-an-id",
        "parley://status?handoff=\(permissionID)&submit=1",
        "parley://ask?handoff=\(permissionID)",
    ]
    for value in forbidden {
        do {
            _ = try ExternalNavigation.request(url: try require(URL(string: value), "invalid test URL"))
            throw CheckFailure(description: "external navigation accepted unsupported authority: \(value)")
        } catch is ExternalNavigationError {
            // Expected: these routes can only focus an already-authoritative local record.
        }
    }
}

private func checkMenuBarAttentionInboxProjection() throws {
    let items = (0..<10).map { index in
        ExternalAttentionItem(
            handoffID: String(format: "00000000-0000-4000-8000-%012d", index),
            workspaceID: "@\(index % 2)",
            workspaceName: index.isMultiple(of: 2) ? "Library" : "Consumer",
            label: "Reviewer \(index) returned an answer",
            reason: .returnedResult
        )
    }
    let snapshot = ExternalAttentionSnapshot(
        generatedAt: Date(timeIntervalSince1970: 100),
        attentionCount: 12,
        workspaces: [],
        panes: [],
        items: items
    )

    let connected = MenuBarAttentionProjection.summary(snapshot: snapshot, coreAvailable: true)
    try expect(connected.totalCount == 12, "menu bar inbox lost the authoritative total")
    try expect(connected.items.count == MenuBarAttentionProjection.maximumVisibleItems, "menu bar inbox was not visibly bounded")
    try expect(connected.hiddenItemCount == 4, "menu bar inbox did not disclose hidden attention items")
    try expect(connected.headline == "12 items need attention", "menu bar inbox plural headline changed")

    let disconnected = MenuBarAttentionProjection.summary(snapshot: snapshot, coreAvailable: false)
    try expect(disconnected.headline == "Coordination unavailable", "a disconnected core was presented as current attention state")
    try expect(disconnected.items == connected.items, "last known content-free attention disappeared during disconnection")

    let empty = MenuBarAttentionProjection.summary(
        snapshot: ExternalAttentionSnapshot(
            generatedAt: Date(timeIntervalSince1970: 101),
            attentionCount: 0,
            workspaces: [],
            panes: [],
            items: []
        ),
        coreAvailable: true
    )
    try expect(empty.headline == "No items need attention", "empty menu bar inbox did not state the all-clear")
}

private func checkTmuxLayoutBecomesAnIDFreeSavedTree() throws {
    let panes = [
        TmuxPane(id: "%2", kind: .shell, customName: "Tests", terminalTitle: "", cwd: "/tmp/project", currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .codex, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/project", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%4", kind: .agy, customName: "Second", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let tmux = "8d64,367x99,0,0{201x99,0,0[201x49,0,0,2,201x49,0,50,3],165x99,202,0[165x49,202,0,1,165x49,202,50,4]}"
    let root = try TmuxLayoutParser.savedNode(layout: tmux, panes: panes)

    guard case let .split(direction, ratio, first, second) = root else {
        throw CheckFailure(description: "tmux root did not become a saved split")
    }
    try expect(direction == .horizontal, "tmux braces did not become a horizontal split")
    try expect(abs(ratio - (201.0 / 366.0)) < 0.001, "tmux root ratio was not preserved")
    guard case let .split(firstDirection, firstRatio, _, _) = first else {
        throw CheckFailure(description: "first tmux branch did not remain split")
    }
    try expect(firstDirection == .vertical && abs(firstRatio - 0.5) < 0.001, "tmux brackets did not become a vertical split")
    guard case let .split(secondDirection, _, _, _) = second else {
        throw CheckFailure(description: "second tmux branch did not remain split")
    }
    try expect(secondDirection == .vertical, "second tmux branch changed direction")
    try expect(root.leaves.map(\.kind) == [.shell, .codex, .claude, .agy], "tmux leaf ordering or kinds changed")
    try expect(root.leaves.map(\.name) == ["Tests", "Reviewer", "Lead", "Second"], "tmux pane names were not captured")
    try expect(root.leaves.map(\.folder) == ["/tmp/project", "/tmp/project", "/tmp/consumer", "/tmp/consumer"], "tmux pane folders were not captured independently")

    let encoded = try require(String(data: JSONEncoder().encode(root), encoding: .utf8), "captured tree was not UTF-8")
    try expect(!encoded.contains("%1") && !encoded.contains("paneID"), "captured tree persisted live tmux identity")
}

private func checkActivePaneIsScopedToSelectedWorkspace() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true, windowID: "@0", workspaceActive: false, workspaceName: "api"),
        paneRow(id: "%2", kind: .codex, active: true, windowID: "@1", workspaceActive: true, workspaceName: "web"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    let listed = try controller.listPanes()
    try expect(listed.first(where: { $0.id == "%1" })?.isActive == false, "inactive workspace exposed its selected pane as globally active")
    try expect(listed.first(where: { $0.id == "%2" })?.isActive == true, "selected workspace lost its active pane")
    let active = try controller.activePane()
    try expect(active?.id == "%2", "controller targeted a pane in the wrong workspace")
}

private func checkDirectAgentSpawn() throws {
    let source = paneRow(id: "%1", kind: .shell, active: true)
    let created = paneRow(
        id: "%2",
        kind: .claude,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    )
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window": return output("%2\n")
        default: return output()
        }
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        transportDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory),
        credentials: credentials,
        runtimeMarker: "DEV"
    ))

    let pane = try controller.createPane(kind: .claude, cwd: "/tmp", direction: .horizontal)

    let split = try require(runner.calls.first(where: { command($0.arguments) == "split-window" }), "split-window was not invoked")
    try expect(split.arguments.suffix(2) == ["/bin/sleep", "30"], "split did not use the bounded holding process")
    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "agent pane was not respawned")
    try expect(respawn.arguments.contains("claude"), "Claude was not passed as a direct executable argument")
    try expect(respawn.arguments.contains("--append-system-prompt"), "Claude did not receive Parley's system-prompt adapter")
    try expect(respawn.arguments.contains(AgentProtocol.text), "Claude did not receive the canonical protocol text")
    try expect(respawn.arguments.contains("/usr/bin/env"), "agent environment was not scrubbed directly")
    try expect(respawn.arguments.contains("TMUX"), "agent retained tmux control discovery")
    try expect(respawn.arguments.contains("PARLEY_PANE_ID=%2"), "agent did not receive its pane identity")
    try expect(respawn.arguments.contains(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }), "agent did not receive a relay credential")
    try expect(!respawn.arguments.contains(where: { $0.hasPrefix("PARLEY_RELAY_INFO=") }), "agent retained the UI relay locator")
    try expect(respawn.arguments.contains("/usr/bin/sandbox-exec"), "agent did not receive the mandatory process boundary")
    try expect(respawn.arguments.contains("PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)"), "agent did not receive the protocol version")
    try expect(respawn.arguments.contains("PARLEY_RUNTIME=DEV"), "development agent did not receive its runtime marker")
    let sandboxIndex = try require(respawn.arguments.firstIndex(of: "/usr/bin/sandbox-exec"), "agent boundary position disappeared")
    let protocolIndex = try require(
        respawn.arguments.firstIndex(of: "PARLEY_PROTOCOL_VERSION=\(AgentProtocol.version)"),
        "protocol environment position disappeared"
    )
    try expect(protocolIndex < sandboxIndex, "tmux environment options were placed inside the sandbox command argv")
    try expect(!respawn.arguments.contains("/bin/sh"), "agent spawn invoked /bin/sh")
    try expect(!respawn.arguments.contains(where: { $0.contains("sh -c") }), "agent spawn built a shell command string")
    try expect(pane.relayEnabled, "new agent pane was not stamped relay-ready")
    try expect(pane.protocolVersion == AgentProtocol.version, "new agent pane was not stamped with its injected protocol version")
}

private func checkAgentProcessBoundaryIsMandatoryAndPaneScoped() throws {
    let root = URL(
        fileURLWithPath: "/private/tmp/parley-boundary-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let applicationDirectory = root.appendingPathComponent("application", isDirectory: true)
    let protocolDirectory = applicationDirectory.appendingPathComponent("agent-protocol", isDirectory: true)
    let shimDirectory = applicationDirectory.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = root.appendingPathComponent("agent-transport", isDirectory: true)
    try FileManager.default.createDirectory(at: protocolDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    let token = String(repeating: "a", count: 48)

    let boundary = try AgentProcessBoundary(
        applicationDirectory: applicationDirectory,
        protocolDirectory: protocolDirectory,
        shimDirectory: shimDirectory,
        tmuxSocket: applicationDirectory.appendingPathComponent("tmux.sock"),
        transportDirectory: transportDirectory,
        paneToken: token
    )

    try expect(boundary.arguments.prefix(2) == ["/usr/bin/sandbox-exec", "-p"], "agent boundary did not invoke the macOS sandbox")
    let profile = try require(boundary.arguments.dropFirst(2).first, "agent boundary omitted its sandbox profile")
    try expect(profile.contains("deny file-read* file-write*"), "agent boundary did not protect Parley's private files")
    try expect(
        profile.contains(applicationDirectory.resolvingSymlinksInPath().path),
        "agent boundary did not protect the application directory"
    )
    try expect(profile.contains("deny network-outbound"), "agent boundary did not protect the tmux control socket")
    try expect(
        profile.contains(applicationDirectory.appendingPathComponent("tmux.sock").resolvingSymlinksInPath().path),
        "agent boundary omitted the exact tmux socket"
    )
    try expect(
        profile.contains(transportDirectory.resolvingSymlinksInPath().path),
        "agent boundary did not isolate the relay transport root"
    )
    try expect(
        profile.contains(boundary.endpointDirectory.resolvingSymlinksInPath().path),
        "agent boundary did not reopen only this pane's relay endpoint"
    )
    try expect(
        boundary.endpointDirectory == RelayFileTransport.endpointDirectory(
            runtimeDirectory: transportDirectory,
            paneToken: token
        ),
        "agent boundary and relay transport disagreed about the pane endpoint"
    )
    let shim = try RelayShim.installCommand(
        in: shimDirectory,
        transportDirectory: transportDirectory
    )
    let shimScript = try String(contentsOf: shim, encoding: .utf8)
    try expect(
        shimScript.contains("transport_root='\(transportDirectory.path)'"),
        "relay shim changed the transport path spelling granted by the agent boundary"
    )
    let attributes = try FileManager.default.attributesOfItem(atPath: boundary.endpointDirectory.path)
    try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "pane relay endpoint was not owner-only")

    do {
        _ = try AgentProcessBoundary(
            applicationDirectory: applicationDirectory,
            protocolDirectory: protocolDirectory,
            shimDirectory: shimDirectory,
            tmuxSocket: applicationDirectory.appendingPathComponent("tmux.sock"),
            transportDirectory: transportDirectory,
            paneToken: "not-a-capability"
        )
        throw CheckFailure(description: "agent boundary accepted a malformed pane capability")
    } catch is AgentProcessBoundaryError {
        // Expected: a path component must never be derived from untrusted text.
    }
}

private func checkStoppedAgentStartsOnlyThroughExplicitAction() throws {
    let placeholder = paneRow(
        id: "%2",
        kind: .codex,
        active: true,
        relayEnabled: false,
        protocolVersion: "",
        started: false
    )
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output("\(placeholder)\n") : output()
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        transportDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory),
        credentials: credentials
    ))

    try expect(!runner.calls.contains { command($0.arguments) == "respawn-pane" }, "constructing a stopped placeholder started an agent")
    try controller.startPane("%2")
    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "explicit Start did not launch the stopped agent")
    try expect(respawn.arguments.contains("codex"), "explicit Start launched the wrong vendor")
    try expect(respawn.arguments.contains(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }), "explicit Start omitted the pane credential")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-started") && call.arguments.contains("1")
    }, "explicit Start did not mark the pane running")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-protocol") && call.arguments.contains(AgentProtocol.version)
    }, "explicit Start did not stamp the injected protocol")
}

private func checkShellPaneStartsLoginShell() throws {
    let source = paneRow(id: "%1", kind: .codex, active: true)
    let created = paneRow(id: "%2", kind: .shell, active: true)
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window": return output("%2\n")
        default: return output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "SHELL": "/bin/zsh",
        ],
        runner: runner
    )

    _ = try controller.createPane(kind: .shell, cwd: "/tmp", direction: .horizontal)

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "shell pane was not respawned")
    try expect(respawn.arguments.suffix(2) == ["/bin/zsh", "-l"], "shell pane did not start the configured login shell")
}

private func checkRealTmuxShellLifecycle() throws {
    var environment = EnvironmentResolver.resolved()
    for key in environment.keys where key == "LANG" || key.hasPrefix("LC_") {
        environment.removeValue(forKey: key)
    }
    environment["LANG"] = "C"
    environment["LC_ALL"] = "C"
    try expect(
        TmuxController.outputFieldSeparator.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7e },
        "tmux field separator is not printable ASCII"
    )
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "real tmux integration check could not find tmux"
    )
    let directory = try temporaryDirectory()
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: directory,
        sessionName: "parley-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }

    try controller.bootstrap(cwd: directory.path)
    let workspaces = try controller.listWorkspaces()
    try expect(workspaces.count == 1, "real tmux bootstrap did not create exactly one workspace")
    try expect(workspaces[0].defaultFolder == directory.path, "real tmux bootstrap lost its workspace folder")

    let shell = try controller.createPane(kind: .shell, cwd: directory.path, direction: .horizontal)
    let configuredShell = controller.environment["SHELL"].flatMap { candidate in
        candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    } ?? "/bin/zsh"
    let expectedCommand = URL(fileURLWithPath: configuredShell).lastPathComponent
    try expect(shell.currentCommand == expectedCommand, "real shell pane is running \(shell.currentCommand), expected \(expectedCommand)")
    try expect(shell.currentCommand != "sleep", "real shell pane retained the temporary holding process")

    try controller.restartPane(shell.id)
    try expect(
        eventually(timeout: 2) {
            (try? controller.listPanes().first(where: { $0.id == shell.id })?.currentCommand) == expectedCommand
        },
        "restarted real shell pane did not return to its login shell"
    )

    try controller.closePane(shell.id)
    let remainingPanes = try controller.listPanes()
    try expect(
        !remainingPanes.contains(where: { $0.id == shell.id }),
        "closed real shell pane remained in tmux"
    )
}

private func checkRealTmuxPaneMobility() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "pane-mobility integration check could not find tmux"
    )
    let directory = try temporaryDirectory()
    let folder = canonicalPath(directory.path)
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: directory,
        sessionName: "parley-mobility-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }

    try controller.bootstrap(cwd: folder)
    let sourceWorkspace = try require(
        try controller.listWorkspaces().first,
        "pane-mobility check created no source workspace"
    )
    let movableShell = try controller.createPane(kind: .shell, cwd: folder, direction: .horizontal)
    let runner = ProcessCommandRunner(timeout: 2)
    func panePID(_ paneID: String) throws -> String {
        try runner.run(
            executable: tmux,
            arguments: [
                "-S", controller.socketPath.path, "-f", controller.configPath.path,
                "display-message", "-p", "-t", paneID, "#{pane_pid}",
            ],
            environment: controller.environment,
            input: nil
        ).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let processBeforeMove = try panePID(movableShell.id)
    let destination = try controller.createWorkspace(folder: folder, name: "Destination")
    let moved = try controller.movePane(
        movableShell.id,
        toWorkspaceID: destination.id,
        direction: .horizontal,
        activeHandoffCount: 0
    )
    let processAfterMove = try panePID(movableShell.id)
    try expect(
        moved.id == movableShell.id
            && moved.windowID == destination.id
            && processAfterMove == processBeforeMove
            && !processAfterMove.isEmpty,
        "real tmux move changed pane identity, destination or process id"
    )
    try expect(moved.cwd == folder, "real tmux move changed the pane-local folder")

    let agentWorkspace = try controller.restoreWorkspaceLayout(SavedWorkspaceLayout(
        name: "Stopped Agent Source",
        defaultFolder: folder,
        root: .leaf(SavedLayoutLeaf(
            kind: .codex,
            name: "Reviewer",
            folder: folder,
            role: "reviewer"
        ))
    ))
    let stoppedSource = try require(
        try controller.listPanes().first(where: { $0.windowID == agentWorkspace.id }),
        "real mobility fixture created no stopped agent"
    )
    let clone = try controller.clonePaneConfiguration(
        stoppedSource.id,
        toWorkspaceID: sourceWorkspace.id,
        direction: .vertical,
        activeHandoffCount: 0
    )
    try expect(
        clone.id != stoppedSource.id
            && clone.windowID == sourceWorkspace.id
            && clone.kind == .codex
            && clone.displayName == "Reviewer"
            && clone.role == "reviewer",
        "real agent clone lost its fresh identity, destination or visible configuration"
    )
    try expect(
        !clone.isStarted && !clone.relayEnabled && clone.protocolVersion == nil && clone.currentCommand == "sleep",
        "real agent clone acquired a session, relay credential or protocol context before Start"
    )
    let panesAfterClone = try controller.listPanes()
    try expect(
        panesAfterClone.contains(where: { $0.id == stoppedSource.id }),
        "configuration cloning changed or removed its source pane"
    )
}

private func checkRealAgentProcessBoundary() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "agent process boundary check could not find tmux"
    )
    let root = URL(
        fileURLWithPath: "/private/tmp/parley-live-boundary-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let applicationDirectory = root.appendingPathComponent("application", isDirectory: true)
    let repositoryDirectory = root.appendingPathComponent("repository", isDirectory: true)
    let shimDirectory = applicationDirectory.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = root.appendingPathComponent("transport", isDirectory: true)
    try FileManager.default.createDirectory(at: repositoryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: applicationDirectory,
        sessionName: "parley-boundary-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }
    try controller.bootstrap(cwd: repositoryDirectory.path)

    let credentials = try RelayCredentials(
        file: applicationDirectory.appendingPathComponent("relay-tokens.json")
    )
    let sourceToken = try credentials.token(for: "%1")
    let siblingToken = try credentials.token(for: "%2")
    let boundary = try AgentProcessBoundary(
        applicationDirectory: applicationDirectory,
        protocolDirectory: controller.protocolDirectory,
        shimDirectory: shimDirectory,
        tmuxSocket: controller.socketPath,
        transportDirectory: transportDirectory,
        paneToken: sourceToken
    )
    let siblingEndpoint = try RelayFileTransport.prepareEndpoint(
        runtimeDirectory: transportDirectory,
        paneToken: siblingToken
    )
    let privateControl = applicationDirectory.appendingPathComponent("core-control-token")
    let repositoryProbe = repositoryDirectory.appendingPathComponent("probe")
    let ownProbe = boundary.endpointDirectory.appendingPathComponent("probe")
    let siblingProbe = siblingEndpoint.appendingPathComponent("probe")
    try Data("private".utf8).write(to: privateControl, options: .atomic)
    try Data("repository".utf8).write(to: repositoryProbe, options: .atomic)
    try Data("own-endpoint".utf8).write(to: ownProbe, options: .atomic)
    try Data("sibling-endpoint".utf8).write(to: siblingProbe, options: .atomic)

    let runner = ProcessCommandRunner(timeout: 3)
    func sandboxed(_ command: [String]) throws -> CommandOutput {
        try runner.run(
            executable: URL(fileURLWithPath: boundary.arguments[0]),
            arguments: Array(boundary.arguments.dropFirst()) + command,
            environment: environment,
            input: nil
        )
    }

    let repositoryRead = try sandboxed(["/bin/cat", repositoryProbe.path])
    try expect(
        repositoryRead.status == 0 && repositoryRead.stdoutText == "repository",
        "agent boundary blocked ordinary repository access"
    )
    let ownRead = try sandboxed(["/bin/cat", ownProbe.path])
    try expect(
        ownRead.status == 0 && ownRead.stdoutText == "own-endpoint",
        "agent boundary blocked its own relay endpoint"
    )
    let privateRead = try sandboxed(["/bin/cat", privateControl.path])
    try expect(
        privateRead.status != 0,
        "agent boundary exposed the UI control capability: status=\(privateRead.status) stdout=\(privateRead.stdoutText) stderr=\(privateRead.stderrText) profile=\(boundary.arguments[2])"
    )
    let siblingRead = try sandboxed(["/bin/cat", siblingProbe.path])
    try expect(siblingRead.status != 0, "agent boundary exposed another pane's relay endpoint")
    let tmuxRead = try sandboxed([
        tmux.path,
        "-S", controller.socketPath.path,
        "list-panes", "-s", "-F", "#{pane_id}",
    ])
    try expect(tmuxRead.status != 0, "agent boundary exposed direct tmux control")
    try expect(
        tmuxRead.stderrText.localizedCaseInsensitiveContains("operation not permitted"),
        "tmux denial did not come from the macOS process boundary: \(tmuxRead.stderrText)"
    )
}

private func checkRealTmuxSavedLayoutRestorationPolicy() throws {
    let environment = EnvironmentResolver.resolved()
    let tmux = try require(
        TmuxController.findTmux(environment: environment),
        "saved-layout integration check could not find tmux"
    )
    let directory = try temporaryDirectory()
    let consumer = try temporaryDirectory()
    let projectPath = canonicalPath(directory.path)
    let consumerPath = canonicalPath(consumer.path)
    let controller = try TmuxController(
        tmuxExecutable: tmux,
        applicationDirectory: directory,
        sessionName: "parley-layout-check",
        environment: environment
    )
    defer {
        _ = try? ProcessCommandRunner(timeout: 2).run(
            executable: tmux,
            arguments: ["-S", controller.socketPath.path, "kill-server"],
            environment: controller.environment,
            input: nil
        )
    }

    try controller.bootstrap(cwd: projectPath)
    let originalWorkspace = try require(try controller.listWorkspaces().first, "layout check created no initial workspace")
    let originalPaneIDs = Set(try controller.listPanes().map(\.id))
    let flexibleSelection = PermissionProfileSelection(
        profileID: "flexible",
        approvedRoots: [projectPath],
        lifetime: .remembered
    )
    let layout = SavedWorkspaceLayout(
        name: "Restored Review",
        defaultFolder: projectPath,
        root: .split(
            direction: .horizontal,
            ratio: 0.58,
            first: .leaf(SavedLayoutLeaf(kind: .shell, name: "Tests", folder: projectPath)),
            second: .split(
                direction: .vertical,
                ratio: 0.5,
                first: .leaf(SavedLayoutLeaf(
                    kind: .codex,
                    name: "Reviewer",
                    folder: projectPath,
                    isWorkspaceLead: true,
                    permissionSelection: flexibleSelection
                )),
                second: .leaf(SavedLayoutLeaf(kind: .agy, name: "Second", folder: consumerPath))
            )
        ),
        automationPolicy: .askAnswer
    )

    let restored = try controller.restoreWorkspaceLayout(layout, replacing: originalWorkspace.id)
    let workspaces = try controller.listWorkspaces()
    try expect(workspaces.count == 1 && workspaces[0].id == restored.id, "layout restoration did not transactionally replace the old workspace")
    try expect(workspaces[0].automationPolicy == .askAnswer, "layout restoration lost its automation policy")
    let panes = try controller.listPanes().filter { $0.windowID == restored.id }
    try expect(panes.count == 3, "restored layout created the wrong pane count")
    try expect(Set(panes.map(\.id)).isDisjoint(with: originalPaneIDs), "restored layout reused dead tmux pane ids")
    let shell = try require(panes.first(where: { $0.kind == .shell }), "restored layout lost its shell")
    try expect(shell.isStarted && shell.currentCommand != "sleep", "restored shell was not started automatically")
    let agents = panes.filter { $0.kind.isAgent }
    try expect(agents.count == 2, "restored layout lost an agent placeholder")
    try expect(agents.first(where: { $0.kind == .codex })?.isWorkspaceLead == true, "restored layout lost its workspace lead")
    try expect(
        agents.first(where: { $0.kind == .codex })?.permissionSelection == flexibleSelection,
        "restored agent placeholder lost its permission profile"
    )
    try expect(agents.allSatisfy { $0.automationPolicy == .askAnswer }, "pane routing metadata did not inherit the workspace automation policy")
    try expect(agents.allSatisfy { !$0.isStarted && $0.currentCommand == "sleep" }, "restored layout spent an agent session")
    try expect(agents.allSatisfy { !$0.relayEnabled && $0.protocolVersion == nil }, "stopped agent placeholder received live relay capability")
    let restoredAgyFolder = agents.first(where: { $0.kind == .agy })?.cwd
    try expect(restoredAgyFolder == consumerPath, "restored agent folder was \(restoredAgyFolder ?? "missing"), expected \(consumerPath)")

    let recaptured = try controller.captureWorkspaceLayout(workspaceID: restored.id)
    try expect(recaptured.name == layout.name && recaptured.defaultFolder == layout.defaultFolder, "recaptured workspace lost its durable identity")
    try expect(recaptured.root.leaves.map(\.kind) == layout.root.leaves.map(\.kind), "recaptured workspace changed pane ordering or kind")
    try expect(recaptured.root.leaves.map(\.name) == layout.root.leaves.map(\.name), "recaptured workspace changed pane names")
    try expect(
        recaptured.root.leaves.first(where: { $0.kind == .codex })?.permissionSelection == flexibleSelection,
        "recaptured workspace changed its selected permission profile"
    )
    try expect(
        recaptured.root.leaves.map { canonicalPath($0.folder) } == layout.root.leaves.map { canonicalPath($0.folder) },
        "recaptured workspace changed a pane folder"
    )
    guard case let .split(direction, ratio, _, _) = recaptured.root else {
        throw CheckFailure(description: "recaptured workspace lost its root split")
    }
    try expect(direction == .horizontal && abs(ratio - 0.58) < 0.03, "recaptured workspace lost its root direction or ratio")
}

private func checkInheritedParleyCapabilitiesAreScrubbed() throws {
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "PARLEY_PANE": "1",
            "PARLEY_PANE_ID": "%99",
            "PARLEY_RELAY_INFO": "/tmp/foreign-relay",
            "PARLEY_RELAY_TOKEN": "foreign-token",
            "PARLEY_IDEMPOTENCY_KEY": "foreign-request",
            "PARLEY_PROTOCOL_VERSION": "foreign-version",
            "PARLEY_CORE_SERVICE": "/tmp/parley-core-service",
            "PARLEY_TMUX": "/opt/homebrew/bin/tmux",
        ],
        runner: RecordingRunner()
    )

    for key in ["PARLEY_PANE", "PARLEY_PANE_ID", "PARLEY_RELAY_INFO", "PARLEY_RELAY_TOKEN", "PARLEY_IDEMPOTENCY_KEY", "PARLEY_PROTOCOL_VERSION"] {
        try expect(controller.environment[key] == nil, "controller inherited the foreign capability \(key)")
    }
    try expect(controller.environment["PARLEY_CORE_SERVICE"] == "/tmp/parley-core-service", "dev core executable override was scrubbed")
    try expect(controller.environment["PARLEY_TMUX"] == "/opt/homebrew/bin/tmux", "explicit tmux executable override was scrubbed")
}

private func checkSharedProtocolLaunchAdapters() throws {
    let directory = try temporaryDirectory()
    let protocolDirectory = try AgentProtocol.install(in: directory)
    let rules = try String(contentsOf: protocolDirectory.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    try expect(rules == AgentProtocol.text, "Agy's rules file drifted from the canonical protocol text")
    try expect(AgentProtocol.text.contains("protocol v\(AgentProtocol.version)"), "protocol text does not identify its version")
    try expect(AgentProtocol.version == "7", "the stable-role protocol did not advance the shared protocol version")
    try expect(AgentProtocol.text.contains("@reviewer"), "shared protocol omitted explicit stable-role addressing")
    for command in ["parley ask-many", "parley delegate", "parley done", "parley fail", "parley status", "parley wait", "parley cancel", "parley context draft", "parley context discard", "--context <draft-id>"] {
        try expect(AgentProtocol.text.contains(command), "shared protocol omitted \(command)")
    }
    try expect(AgentProtocol.text.contains("workspace lead"), "shared protocol omitted lead routing")

    let claude = AgentProtocol.command(for: .claude, protocolDirectory: protocolDirectory)
    try expect(claude == ["claude", "--append-system-prompt", AgentProtocol.text], "Claude launch adapter changed the shared protocol")

    let codex = AgentProtocol.command(for: .codex, protocolDirectory: protocolDirectory)
    try expect(codex.first == "codex" && codex.dropFirst().first == "-c", "Codex launch adapter omitted its config override")
    try expect(codex.last?.hasPrefix("developer_instructions=") == true, "Codex launch adapter omitted developer instructions")
    let codexValue = try require(codex.last?.split(separator: "=", maxSplits: 1).last.map(String.init), "Codex protocol value disappeared")
    let decodedCodex = try JSONDecoder().decode(String.self, from: Data(codexValue.utf8))
    try expect(decodedCodex == AgentProtocol.text, "Codex launch adapter changed the shared protocol")

    let agy = AgentProtocol.command(for: .agy, protocolDirectory: protocolDirectory)
    try expect(agy == ["agy", "--add-dir", protocolDirectory.path], "Agy launch adapter did not add the canonical rules workspace")

    let copilot = AgentProtocol.command(for: .copilot, protocolDirectory: protocolDirectory)
    try expect(
        copilot == ["copilot", "--allow-tool=shell(parley)"],
        "Copilot launch adapter did not limit automatic approval to Parley's shim"
    )
    let copilotEnvironment = AgentProtocol.environment(
        for: .copilot,
        protocolDirectory: protocolDirectory,
        inherited: ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/user/rules"]
    )
    try expect(
        copilotEnvironment["COPILOT_CUSTOM_INSTRUCTIONS_DIRS"] == "\(protocolDirectory.path),/user/rules",
        "Copilot did not receive the canonical protocol alongside inherited custom instructions"
    )
    try expect(AgentProtocol.command(for: .shell, protocolDirectory: protocolDirectory).isEmpty, "shell panes received agent instructions")
    try expect(
        AgentProtocol.environment(for: .shell, protocolDirectory: protocolDirectory).isEmpty,
        "shell panes received an agent protocol environment"
    )

    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil, protocolVersion: "0"),
        TmuxPane(id: "%3", kind: .agy, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, protocolVersion: AgentProtocol.version),
        TmuxPane(id: "%4", kind: .shell, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "zsh", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%5", kind: .copilot, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    try expect(AgentProtocol.stalePaneIDs(in: panes) == ["%1", "%2", "%5"], "protocol restart targeting missed Copilot or included a current agent or shell")
    let stoppedPlaceholder = TmuxPane(
        id: "%6",
        kind: .codex,
        customName: "Stopped reviewer",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        isStarted: false
    )
    try expect(
        AgentProtocol.stalePaneIDs(in: panes + [stoppedPlaceholder]) == ["%1", "%2", "%5"],
        "protocol migration would auto-start a restored agent placeholder"
    )
}

private func checkSupervisionMetadataAndRecipesPersistWithoutLiveIDs() throws {
    let lead = SavedLayoutLeaf(
        kind: .claude,
        name: "Planner",
        folder: "/tmp/project",
        isWorkspaceLead: true
    )
    let layout = SavedWorkspaceLayout(
        name: "Supervised",
        defaultFolder: "/tmp/project",
        root: .split(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(lead),
            second: .leaf(SavedLayoutLeaf(kind: .codex, name: "Reviewer", folder: "/tmp/project"))
        ),
        automationPolicy: .askAnswer
    )
    let encoded = try JSONEncoder().encode(layout)
    let json = try require(String(data: encoded, encoding: .utf8), "supervised layout JSON was not UTF-8")
    try expect(json.contains("askAnswer") && json.contains("isWorkspaceLead"), "saved layout omitted supervision metadata")
    try expect(!json.contains("paneID") && !json.contains("%"), "supervised layout persisted a live pane id")
    let decoded = try JSONDecoder().decode(SavedWorkspaceLayout.self, from: encoded)
    try expect(decoded == layout, "supervised layout did not round-trip")
    try expect(decoded.root.leaves.first?.isWorkspaceLead == true, "saved layout lost its lead stamp")

    let legacy = #"{"name":"Legacy","defaultFolder":"/tmp","root":{"type":"leaf","kind":"shell","name":"Shell","folder":"/tmp"}}"#
    let migrated = try JSONDecoder().decode(SavedWorkspaceLayout.self, from: Data(legacy.utf8))
    try expect(migrated.automationPolicy == .askAndDelegate, "legacy layout did not preserve the existing automation workflow")
    try expect(migrated.root.leaves.first?.isWorkspaceLead == false, "legacy layout invented a workspace lead")

    let directory = try temporaryDirectory()
    let layoutStore = SavedWorkspaceLayoutStore(file: directory.appendingPathComponent("layouts.json"))
    let invalidLeads = SavedWorkspaceLayout(
        name: "Two leads",
        defaultFolder: "/tmp",
        root: .split(
            direction: .horizontal,
            ratio: 0.5,
            first: .leaf(SavedLayoutLeaf(kind: .claude, name: "One", folder: "/tmp", isWorkspaceLead: true)),
            second: .leaf(SavedLayoutLeaf(kind: .codex, name: "Two", folder: "/tmp", isWorkspaceLead: true))
        )
    )
    do {
        try layoutStore.save(invalidLeads)
        throw CheckFailure(description: "layout store accepted two workspace leads")
    } catch let error as SavedWorkspaceLayoutStoreError {
        try expect(error.localizedDescription.contains("only one"), "duplicate-lead refusal was unclear")
    }

    let file = directory.appendingPathComponent("handoff-recipes.json")
    let store = HandoffRecipeStore(file: file)
    let defaults = try store.recipes()
    try expect(Set(defaults.map(\.name)) == Set(["Plan review", "Implementation review", "Adversarial bug hunt", "Compare recommendations"]), "recipe store did not provide the four product recipes")
    let plan = try require(defaults.first(where: { $0.id == "plan-review" }), "plan-review recipe was missing")
    let rendered = try plan.render(targets: ["api/Codex"])
    try expect(rendered.contains("api/Codex") && !rendered.contains("{{targets}}"), "recipe did not render its explicit target")
    let edited = HandoffRecipe(id: plan.id, name: plan.name, kind: plan.kind, instructions: "Ask {{targets}} to challenge the plan, evaluate the answer, then continue.")
    try store.save(edited)
    let persisted = try store.recipes()
    try expect(persisted.first(where: { $0.id == plan.id }) == edited, "edited recipe was not persisted")
    var metadata = stat()
    try expect(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "recipe file was not owner-only")

    let paneRows = [
        paneRow(id: "%1", kind: .claude, active: true, isLead: true, automationPolicy: .askAnswer, role: "planner"),
        paneRow(id: "%2", kind: .codex, active: false, automationPolicy: .askAnswer, role: "implementer"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes": output(paneRows)
        case "list-windows": output(workspaceRow(id: "@0", windowName: "app", active: true, name: "app", folder: "/tmp", automationPolicy: .askAnswer) + "\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    let listedPanes = try controller.listPanes()
    let listedWorkspaces = try controller.listWorkspaces()
    try expect(listedPanes.first?.isWorkspaceLead == true, "tmux pane metadata lost the workspace lead")
    try expect(listedPanes.map(\.role) == ["planner", "implementer"], "tmux pane metadata lost stable routing roles")
    try expect(listedWorkspaces.first?.automationPolicy == .askAnswer, "tmux workspace metadata lost its automation policy")
    try controller.setWorkspaceAutomationPolicy("@0", policy: .off)
    try controller.setWorkspaceLead("%2", workspaceID: "@0")
    try controller.setPaneRole("reviewer", paneID: "%2", workspaceID: "@0")
    do {
        try controller.setPaneRole("planner", paneID: "%2", workspaceID: "@0")
        throw CheckFailure(description: "role control accepted a duplicate workspace role")
    } catch let error as ParleyTmuxError {
        try expect(error.localizedDescription.contains("already assigned"), "duplicate role refusal was unclear")
    }
    do {
        try controller.setPaneRole("codex", paneID: "%2", workspaceID: "@0")
        throw CheckFailure(description: "role control accepted a reserved vendor route")
    } catch let error as ParleyTmuxError {
        try expect(error.localizedDescription.contains("reserved"), "reserved role refusal was unclear")
    }
    try controller.interruptPane("%2")
    try expect(runner.calls.contains { $0.arguments.contains("@parley-automation-policy") && $0.arguments.contains("off") }, "policy control did not write tmux workspace metadata")
    try expect(runner.calls.contains { $0.arguments.contains("@parley-lead") && $0.arguments.contains("%2") && $0.arguments.contains("1") }, "lead control did not stamp the selected pane")
    try expect(runner.calls.contains { $0.arguments.contains("@parley-role") && $0.arguments.contains("%2") && $0.arguments.contains("reviewer") }, "role control did not stamp the selected pane")
    try expect(runner.calls.contains { command($0.arguments) == "send-keys" && $0.arguments.contains("%2") && $0.arguments.contains("C-c") }, "explicit Stop did not target the exact lead pane")
}

private func checkBoundedSupervisedWorkflowLifecycle() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("supervised-workflows.json")
    let store = SupervisedWorkflowStore(file: file)
    let lead = SupervisedWorkflowParticipant(
        paneID: "%1",
        name: "Claude lead",
        kind: .claude,
        workspaceID: "@0"
    )
    let reviewer = SupervisedWorkflowParticipant(
        paneID: "%2",
        name: "Codex reviewer",
        kind: .codex,
        workspaceID: "@0"
    )
    let startedAt = Date(timeIntervalSince1970: 100)
    let started = try store.start(
        workspaceID: "@0",
        workspaceName: "parley",
        lead: lead,
        reviewer: reviewer,
        verifier: reviewer,
        planningPrompt: "Create a plan and stop before implementation.",
        now: startedAt
    )
    try expect(started.phase == .planning, "bounded workflow did not begin at planning")
    try expect(started.transitions.map(\.to) == [.planning], "bounded workflow did not record its initial human transition")
    try expect(started.transitions.allSatisfy { $0.origin == .human }, "bounded workflow invented an agent-authorized transition")

    do {
        _ = try store.advance(id: started.id, to: .implementing, artifact: nil)
        throw CheckFailure(description: "bounded workflow skipped review and its human checkpoint")
    } catch let error as SupervisedWorkflowError {
        try expect(error.localizedDescription.contains("cannot move"), "invalid workflow transition refusal was unclear")
    }

    let plan = SupervisedWorkflowArtifact(
        kind: .plan,
        text: "Plan text\n\n    preserve indentation\n",
        capturedAt: Date(timeIntervalSince1970: 110)
    )
    let reviewing = try store.advance(
        id: started.id,
        to: .reviewingPlan,
        artifact: plan,
        detail: "The person reviewed the exact plan before dispatch.",
        now: Date(timeIntervalSince1970: 111)
    )
    try expect(reviewing.artifacts == [plan], "bounded workflow lost its explicitly captured plan")

    let review = SupervisedWorkflowArtifact(kind: .planReview, text: "Independent objections", capturedAt: Date(timeIntervalSince1970: 120))
    _ = try store.advance(id: started.id, to: .awaitingImplementationApproval, artifact: review)
    _ = try store.advance(id: started.id, to: .implementing, artifact: nil)
    let implementation = SupervisedWorkflowArtifact(kind: .implementation, text: "Reviewed diff", capturedAt: Date(timeIntervalSince1970: 130))
    _ = try store.advance(id: started.id, to: .verifying, artifact: implementation)
    let verification = SupervisedWorkflowArtifact(kind: .verification, text: "Tests pass; no blocking findings.", capturedAt: Date(timeIntervalSince1970: 140))
    _ = try store.advance(id: started.id, to: .awaitingCompletionApproval, artifact: verification)
    let completed = try store.advance(id: started.id, to: .completed, artifact: nil)
    try expect(completed.phase == .completed && completed.artifacts.count == 4, "bounded workflow did not preserve all four explicit artifacts")
    try expect(completed.transitions.count == 7, "bounded workflow did not preserve every supervised checkpoint")
    try expect(completed.artifacts.first?.text == plan.text, "bounded workflow changed formatting in an explicitly reviewed artifact")
    try expect(completed.transitions.allSatisfy { $0.origin == .human }, "bounded workflow recorded a non-human checkpoint")

    let restored = try require(
        SupervisedWorkflowStore(file: file).runs().first(where: { $0.id == started.id }),
        "bounded workflow did not survive store reattachment"
    )
    try expect(restored == completed, "bounded workflow changed while being restored")
    var metadata = stat()
    try expect(lstat(file.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "bounded workflow file was not owner-only")

    let second = try store.start(
        workspaceID: "@1",
        workspaceName: "consumer",
        lead: SupervisedWorkflowParticipant(paneID: "%3", name: "Codex lead", kind: .codex, workspaceID: "@1"),
        reviewer: SupervisedWorkflowParticipant(paneID: "%4", name: "Claude reviewer", kind: .claude, workspaceID: "@1"),
        verifier: SupervisedWorkflowParticipant(paneID: "%4", name: "Claude reviewer", kind: .claude, workspaceID: "@1"),
        planningPrompt: "Plan only."
    )
    let interrupted = try store.interrupt(id: second.id, detail: "Stopped by the person.")
    try expect(interrupted.phase == .interrupted, "bounded workflow could not be interrupted deliberately")
    do {
        _ = try store.advance(id: second.id, to: .completed, artifact: nil)
        throw CheckFailure(description: "bounded workflow resumed after a terminal interruption")
    } catch let error as SupervisedWorkflowError {
        try expect(error.localizedDescription.contains("terminal"), "terminal workflow refusal was unclear")
    }
}

private func checkReadableHandoffChainsPreserveEvidence() throws {
    let directory = URL(
        fileURLWithPath: "/private/tmp/parley-handoff-chains-\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("handoff-chains.json")
    let store = HandoffChainStore(file: file)
    let askedAt = Date(timeIntervalSince1970: 100)
    let answer = "Use the actor boundary.\n\nDo not collapse the two failure states."
    let first = HandoffChainEntry(
        handoffID: "ask-1",
        kind: .ask,
        sourceName: "Claude",
        sourceKind: .claude,
        targetName: "Codex",
        targetKind: .codex,
        prompt: "Review the concurrency plan.",
        result: answer,
        state: .completed,
        occurredAt: askedAt
    )
    let chain = try store.create(
        title: "Concurrency review",
        workspaceID: "@1",
        workspaceName: "parley",
        firstEntry: first,
        now: askedAt
    )
    let verification = HandoffChainEntry(
        handoffID: "verify-1",
        kind: .delegate,
        sourceName: "Claude",
        sourceKind: .claude,
        targetName: "Agy",
        targetKind: .agy,
        prompt: "Verify the implementation independently.",
        result: "One regression remains in cancellation handling.",
        state: .completed,
        occurredAt: Date(timeIntervalSince1970: 120)
    )
    _ = try store.add(entry: verification, to: chain.id, now: Date(timeIntervalSince1970: 121))
    _ = try store.bookmark(
        chainID: chain.id,
        entryID: first.id,
        kind: .answer,
        text: answer,
        now: Date(timeIntervalSince1970: 122)
    )
    let objection = "One regression remains in cancellation handling."
    _ = try store.bookmark(
        chainID: chain.id,
        entryID: verification.id,
        kind: .objection,
        text: objection,
        now: Date(timeIntervalSince1970: 123)
    )
    let decision = "Keep the states separate and fix cancellation before release."
    _ = try store.addDecision(
        chainID: chain.id,
        text: decision,
        now: Date(timeIntervalSince1970: 124)
    )

    let reloaded = try require(
        HandoffChainStore(file: file).chains().first(where: { $0.id == chain.id }),
        "the handoff chain did not survive reattachment"
    )
    try expect(reloaded.entries.map(\.handoffID) == ["ask-1", "verify-1"], "explicit handoff order was not preserved")
    try expect(reloaded.bookmarks.map(\.kind) == [.answer, .objection, .decision], "evidence kinds were smoothed into one verdict")
    try expect(reloaded.bookmarks[0].text == answer, "the bookmarked answer was rewritten")
    try expect(reloaded.bookmarks[1].text == objection, "the dissenting objection was rewritten")
    try expect(reloaded.bookmarks[2].text == decision, "the human decision was rewritten")
    try expect(reloaded.bookmarks[0].origin == nil, "an agent answer was misattributed to the human")
    try expect(reloaded.bookmarks[1].origin == nil, "an agent objection was misattributed to the human")
    try expect(reloaded.bookmarks[2].origin == .human, "the decision lost its human origin")
    try expect(
        HandoffChainProjection.chains(reloaded: [reloaded], workspaceID: "@1").map(\.id) == [chain.id],
        "the chain was not visible in its workspace"
    )
    try expect(
        HandoffChainProjection.chains(reloaded: [reloaded], workspaceID: "@2").isEmpty,
        "the chain leaked into an unrelated workspace"
    )
    do {
        _ = try store.add(entry: verification, to: chain.id)
        throw CheckFailure(description: "the same handoff was added to a chain twice")
    } catch let error as HandoffChainError {
        try expect(error.errorDescription?.contains("already") == true, "duplicate membership failed without a useful explanation")
    }
    let permissions = try require(
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber,
        "handoff chain permissions were unavailable"
    )
    try expect(permissions.intValue & 0o077 == 0, "handoff chains are readable outside their owner")

    let retained = try store.create(
        title: "Release verification",
        workspaceID: "@1",
        workspaceName: "parley",
        firstEntry: verification,
        now: Date(timeIntervalSince1970: 130)
    )
    try store.delete(id: chain.id)
    let remaining = try store.chains()
    try expect(remaining.map(\.id) == [retained.id], "deleting one chain removed unrelated curated evidence")

    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    do {
        _ = try HandoffChainStore(file: file).chains()
        throw CheckFailure(description: "an unsafe handoff chain file was accepted")
    } catch let error as HandoffChainError {
        try expect(
            error.errorDescription?.contains("owner-only") == true,
            "unsafe handoff chain permissions failed without a useful explanation"
        )
    }
}

private func checkSupervisedLeadWorkflowPolicyAndCancellation() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let leadToken = try credentials.token(for: "%1")
    let reviewerToken = try credentials.token(for: "%2")
    let implementerToken = try credentials.token(for: "%3")
    let observerToken = try credentials.token(for: "%4")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "app", isWorkspaceLead: true, automationPolicy: .askAndDelegate),
        TmuxPane(id: "%2", kind: .codex, customName: "Reviewer", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "app", automationPolicy: .askAndDelegate),
        TmuxPane(id: "%3", kind: .agy, customName: "Builder", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "app", automationPolicy: .askAndDelegate),
        TmuxPane(id: "%4", kind: .copilot, customName: "Observer", terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "app", automationPolicy: .askAndDelegate),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, text in submissions.append(paneID: paneID, text: text) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let leadRoute = broker.handle(token: observerToken, target: "lead", text: "Give me the current decision.", idempotencyKey: "lead-route-1")
    try expect(leadRoute.status == 200 && submissions.values.last?.paneID == "%1", "lead alias did not resolve to the marked local pane")

    let review = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        review.set(broker.handleAsk(token: leadToken, target: "reviewer", text: "Challenge the plan.", idempotencyKey: "supervised-review-1"))
    }
    try expect(eventually { broker.consultations().count == 1 }, "lead review did not establish a consultation")
    try expect(broker.handleAnswer(token: reviewerToken, consultationID: "current", text: "Add a failure-path test.").status == 200, "reviewer could not return its recommendation")
    try expect(eventually { review.value?.text == "Add a failure-path test." }, "lead did not receive the review answer")

    let delegated = broker.handleDelegate(token: leadToken, target: "builder", text: "Implement the adopted test.", idempotencyKey: "supervised-delegate-1")
    let delegatedID = try require(delegated.body.handoffID, "supervised delegation returned no id")
    try expect(broker.handleDelegationResult(token: implementerToken, handoffID: "current", text: "Implemented; checks pass.", succeeded: true).status == 200, "implementer could not complete the adopted work")
    try expect(broker.waitForDelegation(token: leadToken, handoffID: delegatedID).text == "Implemented; checks pass.", "lead did not receive the completion report")

    let cancellable = broker.handleDelegate(token: leadToken, target: "builder", text: "Investigate another option.", idempotencyKey: "supervised-cancel-1")
    let cancellableID = try require(cancellable.body.handoffID, "cancellable delegation returned no id")
    try expect(broker.cancelHandoff(token: reviewerToken, handoffID: cancellableID).status == 403, "a foreign pane cancelled the lead's work")
    try expect(broker.cancelHandoff(token: leadToken, handoffID: "current").status == 200, "lead could not cancel its current tracked work")
    try expect(broker.handoffs().first(where: { $0.id == cancellableID })?.state == .cancelled, "agent cancellation did not reach a terminal state")

    let offPanes = panes.map { pane in
        TmuxPane(id: pane.id, kind: pane.kind, customName: pane.customName, terminalTitle: pane.terminalTitle, cwd: pane.cwd, currentCommand: pane.currentCommand, isActive: pane.isActive, windowID: pane.windowID, returnToPaneID: pane.returnToPaneID, workspaceName: pane.workspaceName, isWorkspaceLead: pane.isWorkspaceLead, automationPolicy: .off)
    }
    let offBroker = RelayBroker(credentials: credentials, panes: { offPanes }, paste: { _, _ in }, submit: { _, _ in })
    try expect(offBroker.handle(token: leadToken, target: "reviewer", text: "Must not send.").status == 403, "Off policy allowed automatic relay")
    try expect(offBroker.handleAsk(token: leadToken, target: "reviewer", text: "Must not ask.").status == 403, "Off policy allowed Ask")

    let askOnlyPanes = panes.map { pane in
        TmuxPane(id: pane.id, kind: pane.kind, customName: pane.customName, terminalTitle: pane.terminalTitle, cwd: pane.cwd, currentCommand: pane.currentCommand, isActive: pane.isActive, windowID: pane.windowID, returnToPaneID: pane.returnToPaneID, workspaceName: pane.workspaceName, isWorkspaceLead: pane.isWorkspaceLead, automationPolicy: .askAnswer)
    }
    let askOnlyBroker = RelayBroker(credentials: credentials, panes: { askOnlyPanes }, paste: { _, _ in }, submit: { _, _ in })
    try expect(askOnlyBroker.handleDelegate(token: leadToken, target: "builder", text: "Must not delegate.").status == 403, "Ask/Answer policy allowed tracked delegation")
}

private func checkTrackedDelegationCompletesAndWaits() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let wrongToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web"),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submitted = LockedDelivery()
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: prompt, submit: true)
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "web/agy",
        text: "Implement the reviewed UI changes.\nRun the tests and report the result.",
        idempotencyKey: "delegate-ui-1"
    )
    let handoffID = try require(delegated.body.handoffID, "delegate returned no tracked handoff id")
    try expect(delegated.status == 200 && delegated.body.state == .waiting, "delegate did not return a waiting tracked item")
    try expect(submitted.value?.paneID == "%2" && submitted.value?.submit == true, "delegate was not submitted to the exact target")
    try expect(submitted.value?.text.contains("Planner delegated work:") == true, "delegate omitted source attribution")
    try expect(submitted.value?.text.contains("parley done current") == true, "delegate omitted its completion command")
    try expect(submitted.value?.text.contains("parley fail current") == true, "delegate omitted its failure command")

    let statusesResponse = broker.delegationStatus(token: sourceToken)
    try expect(statusesResponse.status == 200, "the initiating pane could not inspect its delegations")
    let statuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: Data(statusesResponse.text.utf8))
    try expect(statuses.count == 1 && statuses[0].id == handoffID, "status did not return the initiating pane's tracked item")
    try expect(statuses[0].state == .waiting && statuses[0].task.contains("Implement the reviewed UI changes"), "status lost the delegation state or task")
    let foreignStatuses = try JSONDecoder().decode(
        [RelayDelegationStatus].self,
        from: Data(broker.delegationStatus(token: wrongToken).text.utf8)
    )
    try expect(foreignStatuses.isEmpty, "status exposed another pane's delegation")

    let waited = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        waited.set(broker.waitForDelegation(token: sourceToken, handoffID: handoffID))
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(waited.value == nil, "wait returned before delegated work reached a terminal state")
    let refused = broker.handleDelegationResult(
        token: wrongToken,
        handoffID: handoffID,
        text: "A different pane must not finish this.",
        succeeded: true
    )
    try expect(refused.status == 403, "a different pane completed delegated work")

    let completion = "Implemented the UI changes.\n46 checks passed."
    let accepted = broker.handleDelegationResult(
        token: targetToken,
        handoffID: "current",
        text: completion,
        succeeded: true
    )
    try expect(accepted.status == 200, "the exact target could not complete its delegated work")
    try expect(eventually { waited.value != nil }, "done did not release the waiting source command")
    try expect(waited.value == RelayTextResponse(status: 200, text: completion), "wait did not return the exact completion report")
    let completed = try require(broker.handoffs().first(where: { $0.id == handoffID }), "completed delegation disappeared")
    try expect(completed.kind == .delegate && completed.state == .completed, "delegation recorded the wrong terminal state")
    try expect(completed.resultText == completion, "delegation lost its completion report")
    try expect(completed.transitions.map(\.state) == [.created, .delivered, .waiting, .completed], "delegation recorded the wrong lifecycle")

    let duplicate = broker.handleDelegate(
        token: sourceToken,
        target: "web/agy",
        text: "Implement the reviewed UI changes.\nRun the tests and report the result.",
        idempotencyKey: "delegate-ui-1"
    )
    try expect(duplicate.body.handoffID == handoffID && duplicate.body.state == .waiting, "idempotent delegate did not return its original receipt")
    try expect(submissionCount.value == 1, "idempotent delegate submitted work twice")
}

private func checkTrackedDelegationFailureAndLiveness() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil)
    let target = TmuxPane(id: "%2", kind: .copilot, customName: "Copilot", terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, windowID: "@0", returnToPaneID: nil)
    let livePanes = LockedPanes([source, target])
    let broker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "copilot",
        text: "Audit the patch.",
        idempotencyKey: "delegate-fail-1"
    )
    let handoffID = try require(delegated.body.handoffID, "failed delegation fixture returned no id")
    let busyAsk = broker.handleAsk(token: sourceToken, target: "copilot", text: "Interrupt it?")
    try expect(busyAsk.status == 409 && busyAsk.text.contains("already has tracked work"), "Ask interrupted a target with active delegated work")
    let failed = broker.handleDelegationResult(
        token: targetToken,
        handoffID: "current",
        text: "Tests fail in the existing fixture.",
        succeeded: false
    )
    try expect(failed.status == 200, "target could not report delegated work failure")
    let failedHandoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "failed delegation disappeared")
    try expect(failedHandoff.state == .failed && failedHandoff.resultText == "Tests fail in the existing fixture.", "failure report was not retained")
    try expect(failedHandoff.retryDisposition == .unsupported && !failedHandoff.canRetrySafely, "delegated work failure exposed unsafe delivery retry")
    let failedWait = broker.waitForDelegation(token: sourceToken, handoffID: handoffID)
    try expect(failedWait.status == 409 && failedWait.text.contains("Tests fail"), "wait disguised a delegated failure as success")

    let second = broker.handleDelegate(
        token: sourceToken,
        target: "copilot",
        text: "Check liveness.",
        idempotencyKey: "delegate-live-1"
    )
    let secondID = try require(second.body.handoffID, "liveness delegation returned no id")
    livePanes.set([source])
    let deadTarget = broker.waitForDelegation(token: sourceToken, handoffID: secondID)
    try expect(deadTarget.status == 410, "closed delegation target returned the wrong status")
    let deadHandoff = try require(broker.handoffs().first(where: { $0.id == secondID }), "dead-target delegation disappeared")
    try expect(deadHandoff.state == .failed && deadHandoff.transitions.last?.detail?.contains("closed") == true, "closed target did not fail delegated work explicitly")
}

private func checkDelegationShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }
    let runner = ProcessCommandRunner(timeout: 5)
    let sourceEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": sourceToken,
        "PARLEY_IDEMPOTENCY_KEY": "shim-delegate-1",
    ]) { _, supplied in supplied }
    let targetEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": targetToken,
    ]) { _, supplied in supplied }
    let executable = shimDirectory.appendingPathComponent("parley").path

    let delegated = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "Implement the selected change."],
        environment: sourceEnvironment,
        input: nil
    )
    try expect(delegated.status == 0, "parley delegate did not reach the local broker")
    let receipt = try JSONDecoder().decode(RelayResponseBody.self, from: delegated.stdout)
    let handoffID = try require(receipt.handoffID, "delegate shim returned no handoff id")
    try expect(receipt.state == .waiting, "delegate shim returned the wrong state")

    let status = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "status"],
        environment: sourceEnvironment,
        input: nil
    )
    let statuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: status.stdout)
    try expect(statuses.first?.id == handoffID && statuses.first?.state == .waiting, "parley status lost the tracked item")

    let waited = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [executable, "wait", handoffID],
                environment: sourceEnvironment,
                input: nil
            )
            waited.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            waited.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(waited.value == nil, "parley wait returned before done")

    let done = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "done", "current", "Implemented and verified."],
        environment: targetEnvironment,
        input: nil
    )
    try expect(done.status == 0 && done.stdoutText.contains("Completion returned"), "parley done did not reach the local broker")
    try expect(eventually { waited.value != nil }, "parley done did not release parley wait")
    try expect(waited.value == RelayTextResponse(status: 0, text: "Implemented and verified."), "shim wait returned the wrong report")

    let cancellable = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "Investigate a second option."],
        environment: sourceEnvironment.merging(["PARLEY_IDEMPOTENCY_KEY": "shim-delegate-cancel-1"]) { _, supplied in supplied },
        input: nil
    )
    let cancellableReceipt = try JSONDecoder().decode(RelayResponseBody.self, from: cancellable.stdout)
    let cancellableID = try require(cancellableReceipt.handoffID, "cancellable shim delegation returned no id")
    let cancelled = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "cancel", "current"],
        environment: sourceEnvironment,
        input: nil
    )
    try expect(cancelled.status == 0 && cancelled.stdoutText.contains("not interrupted"), "parley cancel did not return through the pane-scoped transport")
    try expect(broker.handoffs().first(where: { $0.id == cancellableID })?.state == .cancelled, "shim cancellation did not end tracked work")
}

private func checkCopilotAgentSpawn() throws {
    let source = paneRow(id: "%1", kind: .shell, active: true)
    let created = paneRow(
        id: "%2",
        kind: .copilot,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    )
    var lists = 0
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes":
            lists += 1
            return output(lists == 1 ? "\(source)\n" : "\(source)\n\(created)\n")
        case "split-window": return output("%2\n")
        default: return output()
        }
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/user/rules",
        ],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        transportDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory),
        credentials: credentials
    ))

    let pane = try controller.createPane(kind: .copilot, cwd: "/tmp", direction: .horizontal)

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "Copilot pane was not respawned")
    try expect(
        respawn.arguments.suffix(2) == ["copilot", "--allow-tool=shell(parley)"],
        "Copilot was not launched directly with only its narrow Parley permission"
    )
    try expect(
        respawn.arguments.contains("--allow-tool=shell(parley)"),
        "Copilot still requires approval before it can return a Parley answer"
    )
    try expect(
        respawn.arguments.contains("COPILOT_CUSTOM_INSTRUCTIONS_DIRS=\(controller.protocolDirectory.path),/user/rules"),
        "Copilot did not receive Parley's shared protocol directory"
    )
    try expect(!respawn.arguments.contains("--allow-all"), "Copilot launch bypassed permission prompts")
    try expect(!respawn.arguments.contains("--allow-all-tools"), "Copilot launch automatically approved tools")
    try expect(!respawn.arguments.contains("--yolo"), "Copilot launch used the unsafe yolo alias")
    try expect(pane.relayEnabled, "new Copilot pane was not relay-ready")
    try expect(pane.protocolVersion == AgentProtocol.version, "new Copilot pane was not stamped with its protocol version")
}

private func checkCopilotSubmitUsesEnterAfterTrust() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(
            id: "%4",
            kind: .copilot,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
    ].joined(separator: "\n") + "\n"
    var pauses: [TimeInterval] = []
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner,
        pause: { pauses.append($0) }
    )

    try controller.paste("queued question", into: "%4", submit: true)

    let submit = try require(runner.calls.first(where: { command($0.arguments) == "send-keys" }), "Copilot submission sent no key")
    try expect(submit.arguments.contains("Enter"), "trusted Copilot submission did not start the turn")
    try expect(!submit.arguments.contains("C-q"), "Copilot submission only queued the prompt instead of starting it")
    let focusCalls = runner.calls.filter { command($0.arguments) == "select-pane" }
    try expect(focusCalls.count == 2, "inactive Copilot was not focused and then restored")
    try expect(focusCalls[0].arguments.contains("%4"), "Copilot was not focused before submission")
    try expect(focusCalls[1].arguments.contains("%1"), "the original pane was not restored after Copilot submission")
    let focusIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "select-pane" && $0.arguments.contains("%4")
    }), "Copilot focus call disappeared")
    let submitIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "send-keys" && $0.arguments.contains("Enter")
    }), "Copilot submit call disappeared")
    let restoreIndex = try require(runner.calls.firstIndex(where: {
        command($0.arguments) == "select-pane" && $0.arguments.contains("%1")
    }), "Copilot restore call disappeared")
    try expect(focusIndex < submitIndex && submitIndex < restoreIndex, "Copilot focus handoff happened in the wrong order")
    try expect(pauses == [0.1, 0.25, 0.1], "Copilot focus, paste, and restore were not separated by settling delays")
}

private func checkCopilotTrustPromptRefusesSubmission() throws {
    let panes = paneRow(
        id: "%4",
        kind: .copilot,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    ) + "\n"
    let runner = RecordingRunner { arguments, _ in
        switch command(arguments) {
        case "list-panes": output(panes)
        case "capture-pane": output("Confirm folder trust\nDo you trust the files in this folder?\n")
        default: output()
        }
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    do {
        try controller.paste("do not queue behind trust", into: "%4", submit: true)
        throw CheckFailure(description: "Copilot accepted an Ask behind its folder-trust dialog")
    } catch ParleyTmuxError.copilotTrustRequired {
        // Expected: only the person can grant repository trust.
    }
    try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "a refused Copilot Ask still pasted its prompt")
}

private func checkPasteRequiresRelayReadyBracketedTarget() throws {
    func attempt(relayEnabled: Bool, protocolVersion: String, bracketedPasteActive: Bool) throws {
        let panes = paneRow(
            id: "%2",
            kind: .codex,
            active: true,
            relayEnabled: relayEnabled,
            protocolVersion: protocolVersion,
            bracketedPasteActive: bracketedPasteActive
        ) + "\n"
        let runner = RecordingRunner { arguments, _ in
            command(arguments) == "list-panes" ? output(panes) : output()
        }
        let controller = try TmuxController(
            tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
            applicationDirectory: temporaryDirectory(),
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
            runner: runner
        )
        do {
            try controller.paste("unsafe\nmultiline", into: "%2", submit: false)
            throw CheckFailure(description: "unsafe relay target accepted a multiline paste")
        } catch ParleyTmuxError.unsafeRelayTarget {
            // Expected: no bytes reach a target outside the current protocol.
        }
        try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "refused relay still loaded a tmux buffer")
    }

    try attempt(relayEnabled: true, protocolVersion: AgentProtocol.version, bracketedPasteActive: false)
    try attempt(relayEnabled: false, protocolVersion: AgentProtocol.version, bracketedPasteActive: true)
    try attempt(relayEnabled: true, protocolVersion: "stale", bracketedPasteActive: true)
}

private func checkAsk() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(
            id: "%2",
            kind: .codex,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.ask(from: "%1", to: "%2", text: "Should this cache be per worktree?")

    let load = try require(runner.calls.first(where: { command($0.arguments) == "load-buffer" }), "Ask did not load a tmux buffer")
    let body = String(decoding: try require(load.input, "Ask buffer had no stdin"), as: UTF8.self)
    try expect(body.contains("Claude asked:"), "Ask omitted source attribution")
    try expect(body.contains("per worktree"), "Ask omitted its body")
    let paste = try require(runner.calls.first(where: { command($0.arguments) == "paste-buffer" }), "Ask did not paste the buffer")
    try expect(paste.arguments.contains("-p") && paste.arguments.contains("-r"), "Ask did not use a multiline bracketed paste")
    try expect(paste.arguments.contains("%2"), "Ask targeted the wrong pane")
    try expect(runner.calls.contains { command($0.arguments) == "send-keys" && $0.arguments.contains("Enter") }, "human Ask action did not submit")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("@parley-return-to") && call.arguments.contains("%1")
    }, "Ask did not record its return route")

    let explicitContext = "Review this exact layout:\n\n    indented code\n\n\n┌diagram┐"
    try controller.askWithExplicitContext(from: "%1", to: "%2", text: explicitContext)
    let contextLoad = try require(
        runner.calls.last(where: { command($0.arguments) == "load-buffer" }),
        "context Ask did not load a tmux buffer"
    )
    let contextBody = String(decoding: try require(contextLoad.input, "context Ask buffer had no stdin"), as: UTF8.self)
    try expect(contextBody.contains("    indented code"), "context Ask stripped meaningful indentation")
    try expect(contextBody.contains("code\n\n\n┌diagram┐"), "context Ask collapsed blank lines or stripped Unicode source content")
}

private func checkReturn() throws {
    let panes = [
        paneRow(
            id: "%1",
            kind: .claude,
            active: false,
            relayEnabled: true,
            protocolVersion: AgentProtocol.version
        ),
        paneRow(id: "%2", kind: .codex, active: true, returnTo: "%1"),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    try controller.returnAnswer(from: "%2", text: "No; worktrees can have different state.")

    let load = try require(runner.calls.first(where: { command($0.arguments) == "load-buffer" }), "Return did not load a tmux buffer")
    let body = String(decoding: try require(load.input, "Return buffer had no stdin"), as: UTF8.self)
    try expect(body.contains("Codex answered:"), "Return omitted source attribution")
    let paste = try require(runner.calls.first(where: { command($0.arguments) == "paste-buffer" }), "Return did not paste the buffer")
    try expect(paste.arguments.contains("%1"), "Return targeted the wrong pane")
    try expect(runner.calls.contains { call in
        command(call.arguments) == "set-option" && call.arguments.contains("-u") && call.arguments.contains("@parley-return-to")
    }, "Return did not consume its route")
}

private func checkCrossVendorGuard() throws {
    let panes = [
        paneRow(id: "%1", kind: .claude, active: true),
        paneRow(id: "%2", kind: .claude, active: false),
    ].joined(separator: "\n") + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(panes) : output()
    }
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: temporaryDirectory(),
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )

    do {
        try controller.ask(from: "%1", to: "%2", text: "review this")
        throw CheckFailure(description: "same-vendor Ask was accepted")
    } catch ParleyTmuxError.sameVendor {
        // Expected: Parley only automates the cross-vendor gap.
    }
    try expect(!runner.calls.contains { command($0.arguments) == "load-buffer" }, "rejected Ask still relayed content")
}

private func checkRelayCleaning() throws {
    let cleaned = RelayText.clean("\u{1b}[31m│ - old\r\n│ + new\u{7}\n\n\n")
    try expect(!cleaned.contains("\u{1b}"), "relay preserved an escape control")
    try expect(!cleaned.contains("│"), "relay preserved a terminal frame")
    try expect(cleaned.contains("- old") && cleaned.contains("+ new"), "relay damaged diff markers")
    try expect(!cleaned.hasSuffix("\n"), "relay retained trailing blank lines")
}

private func checkRelayDraftStartsWithSelectionOrNothing() throws {
    try expect(RelayDraft.initialText(selection: nil).isEmpty, "an unselected relay copied pane history")
    try expect(RelayDraft.initialText(selection: "  selected question  ") == "selected question", "relay did not use only the selection")
}

private func checkReviewDraftsAreBoundedShellFreeAndExplicit() throws {
    let repository = try temporaryDirectory()
    let runner = RecordingRunner { arguments, _ in
        if arguments.contains("rev-parse") {
            return CommandOutput(stdout: Data("\(repository.path)\n".utf8))
        }
        if arguments.contains("status") {
            return CommandOutput(stdout: Data(" M Sources/App.swift\n?? PLAN.md\n".utf8))
        }
        if arguments.contains("--cached") {
            return CommandOutput(stdout: Data("diff --git a/staged b/staged\n+staged change\n".utf8))
        }
        return CommandOutput(stdout: Data("diff --git a/worktree b/worktree\n+working change\n".utf8))
    }
    let builder = ReviewDraftBuilder(
        gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
        environment: ["PATH": "/usr/bin:/bin"],
        runner: runner,
        maximumBytes: 4_096
    )

    let changes = try builder.changes(in: repository.path)
    try expect(changes.title == "Review repository changes", "changes draft title drifted")
    try expect(changes.text.contains("Repository: \(repository.path)"), "changes draft omitted its repository")
    try expect(changes.text.contains(" M Sources/App.swift") && changes.text.contains("?? PLAN.md"), "changes draft omitted explicit status")
    try expect(changes.text.contains("+staged change") && changes.text.contains("+working change"), "changes draft did not include both diff surfaces")
    try expect(runner.calls.count == 4, "changes draft ran an unexpected number of git commands")
    try expect(runner.calls.allSatisfy { $0.executable.path == "/usr/bin/git" }, "changes draft invoked something other than git directly")
    try expect(runner.calls.allSatisfy { Array($0.arguments.prefix(2)) == ["-C", repository.path] }, "changes draft did not scope every git command with argv")
    try expect(runner.calls.allSatisfy { $0.arguments.contains("core.fsmonitor=false") }, "changes draft allowed a configured filesystem monitor command")
    try expect(runner.calls.allSatisfy { $0.environment["GIT_OPTIONAL_LOCKS"] == "0" }, "changes draft allowed git to take optional write locks")

    let plan = repository.appendingPathComponent("PLAN.md")
    try "# Plan\n\n1. Preserve the review transport.\n".write(to: plan, atomically: true, encoding: .utf8)
    let file = try builder.file(at: plan)
    try expect(file.title == "Review PLAN.md", "file draft title omitted the selected file")
    try expect(file.text.contains("File: \(plan.path)"), "file draft omitted the exact selected path")
    try expect(file.text.contains("1. Preserve the review transport."), "file draft omitted selected file content")

    let tinyBuilder = ReviewDraftBuilder(
        gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
        environment: [:],
        runner: runner,
        maximumBytes: 24
    )
    do {
        _ = try tinyBuilder.file(at: plan)
        throw CheckFailure(description: "oversized review file was accepted")
    } catch ReviewDraftError.contentTooLarge {
        // Expected: prompts are bounded before they reach tmux.
    }

    let binary = repository.appendingPathComponent("binary.dat")
    try Data([0x41, 0, 0x42]).write(to: binary)
    do {
        _ = try builder.file(at: binary)
        throw CheckFailure(description: "binary review file was accepted")
    } catch ReviewDraftError.notText {
        // Expected: the editable relay preview is text only.
    }

    do {
        _ = try tinyBuilder.changes(in: repository.path)
        throw CheckFailure(description: "oversized changes review was accepted")
    } catch ReviewDraftError.contentTooLarge {
        // Expected: generated diffs use the same handoff ceiling as files.
    }

    let cleanRunner = RecordingRunner { arguments, _ in
        arguments.contains("rev-parse")
            ? CommandOutput(stdout: Data("\(repository.path)\n".utf8))
            : CommandOutput()
    }
    do {
        _ = try ReviewDraftBuilder(runner: cleanRunner).changes(in: repository.path)
        throw CheckFailure(description: "clean repository produced an empty review")
    } catch ReviewDraftError.noChanges {
        // Expected: an explicit empty-state error is more useful than a blank Ask.
    }

    let failedRunner = RecordingRunner { _, _ in
        CommandOutput(stdout: Data("stdout cause".utf8), stderr: Data("stderr cause".utf8), status: 128)
    }
    do {
        _ = try ReviewDraftBuilder(
            gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
            environment: [:],
            runner: failedRunner
        ).changes(in: repository.path)
        throw CheckFailure(description: "failed git command produced a review draft")
    } catch let ReviewDraftError.commandFailed(detail) {
        try expect(detail.contains("stdout cause") && detail.contains("stderr cause"), "git failure hid stdout or stderr")
    }
}

private func checkContextPacksAreExplicitBoundedAndAttributed() throws {
    let repository = try temporaryDirectory()
    let gitRunner = RecordingRunner { arguments, _ in
        if arguments.contains("rev-parse") {
            return CommandOutput(stdout: Data("\(repository.path)\n".utf8))
        }
        if arguments.contains("status") {
            return CommandOutput(stdout: Data(" M Sources/App.swift\n?? PRIVATE-NOTE.txt\n".utf8))
        }
        if arguments.contains("--cached") {
            return CommandOutput(stdout: Data("diff --git a/staged b/staged\n+staged context\n".utf8))
        }
        return CommandOutput(stdout: Data("diff --git a/worktree b/worktree\n+working context\n".utf8))
    }
    let commandRunner = RecordingContextCommandRunner(output: CommandOutput(
        stdout: Data("command stdout\n".utf8),
        stderr: Data("command stderr\n".utf8),
        status: 7
    ))
    let builder = ContextPackBuilder(
        environment: ["PATH": "/usr/bin:/bin"],
        gitRunner: gitRunner,
        commandRunner: commandRunner,
        maximumPartBytes: 4_096,
        maximumRenderedBytes: 20_000
    )

    let fileURL = repository.appendingPathComponent("PLAN.md")
    try "# Plan\n\nKeep every source explicit.\n".write(to: fileURL, atomically: true, encoding: .utf8)
    let file = try builder.file(at: fileURL)
    try expect(file.source.kind == .file, "a selected file lost its source kind")
    try expect(file.source.detail == fileURL.path, "a selected file lost its exact path")
    try expect(file.byteCount == file.text.utf8.count && !file.isEdited, "a selected file reported an inexact byte count")

    let changes = try builder.gitDiff(in: repository.path)
    try expect(changes.source.kind == .gitDiff, "Git changes lost their source kind")
    try expect(changes.source.detail == repository.path, "Git changes lost their repository path")
    try expect(changes.text.contains("+staged context") && changes.text.contains("+working context"), "Git context omitted a diff surface")
    try expect(changes.text.contains("?? PRIVATE-NOTE.txt"), "Git context omitted the explicit untracked filename")
    try expect(!changes.text.contains("secret contents"), "Git context silently read untracked file contents")
    try expect(gitRunner.calls.count == 4, "Git context ran an unexpected command")
    try expect(gitRunner.calls.allSatisfy { $0.executable.path == "/usr/bin/git" }, "Git context invoked a shell or foreign executable")
    try expect(gitRunner.calls.allSatisfy { $0.environment["GIT_OPTIONAL_LOCKS"] == "0" }, "Git context allowed optional index locks")

    let terminal = try builder.visibleTerminal(
        paneID: "%7",
        paneName: "Review shell",
        text: "Only the visible screen\nnot hidden scrollback"
    )
    try expect(terminal.source.kind == .visibleTerminal, "visible terminal context lost its source kind")
    try expect(terminal.source.detail.contains("%7") && terminal.text == "Only the visible screen\nnot hidden scrollback", "visible terminal context changed its explicit capture")

    let command = try builder.commandResult(
        executablePath: "/usr/bin/printf",
        arguments: ["%s", "literal | argument"],
        workingDirectory: repository
    )
    try expect(command.source.kind == .commandResult, "command context lost its source kind")
    try expect(command.text.contains("Exit status: 7"), "command context omitted its exit status")
    try expect(command.text.contains("command stdout") && command.text.contains("command stderr"), "command context hid stdout or stderr")
    let invocation = try require(commandRunner.calls.first, "command context did not execute")
    try expect(invocation.executable.path == "/usr/bin/printf", "command context changed the executable")
    try expect(invocation.arguments == ["%s", "literal | argument"], "command context interpreted an argument as shell syntax")
    try expect(invocation.workingDirectory.path == repository.path, "command context ran in the wrong folder")
    do {
        _ = try builder.commandResult(
            executablePath: "printf",
            arguments: ["must not run"],
            workingDirectory: repository
        )
        throw CheckFailure(description: "a context command resolved a non-absolute executable implicitly")
    } catch ContextPackError.invalidExecutable {
        // Expected: the person must see and approve the exact executable path.
    }
    try expect(commandRunner.calls.count == 1, "a refused relative command still executed")

    let directRunner = ContextProcessCommandRunner(timeout: 2, maximumOutputBytes: 1_024)
    let literal = try directRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: ["%s", "literal | argument"],
        workingDirectory: repository,
        environment: ["PATH": "/usr/bin:/bin"]
    )
    try expect(literal.status == 0 && literal.stdoutText == "literal | argument", "the real context runner interpreted a literal shell metacharacter")
    let pwd = try directRunner.run(
        executable: URL(fileURLWithPath: "/bin/pwd"),
        arguments: [],
        workingDirectory: repository,
        environment: ["PATH": "/usr/bin:/bin"]
    )
    try expect(
        canonicalPath(pwd.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) == canonicalPath(repository.path),
        "the real context runner ignored its exact working directory"
    )
    let boundedRunner = ContextProcessCommandRunner(timeout: 0.1, maximumOutputBytes: 32)
    let noisy = try boundedRunner.run(
        executable: URL(fileURLWithPath: "/usr/bin/yes"),
        arguments: [],
        workingDirectory: repository,
        environment: ["PATH": "/usr/bin:/bin"]
    )
    try expect(noisy.status == 124, "a long-running context command did not reach its bounded timeout")
    try expect(noisy.stdout.count <= 32, "a noisy context command exceeded its capture bound")

    let editedTerminal = terminal.replacingText("Edited visible evidence")
    try expect(editedTerminal.isEdited, "editing a captured part was not disclosed")
    try expect(editedTerminal.capturedByteCount == terminal.byteCount, "editing a part changed its captured byte count")
    try expect(editedTerminal.byteCount == "Edited visible evidence".utf8.count, "editing a part left a stale live byte count")

    let oversizedEditText = String(repeating: "x", count: RelayText.maximumCharacters + 37)
    let oversizedEdit = terminal.replacingText(oversizedEditText)
    try expect(
        oversizedEdit.byteCount == oversizedEditText.utf8.count,
        "an oversized context edit was silently clipped instead of remaining visibly invalid"
    )
    do {
        _ = try builder.render(ContextPack(name: "Oversized edit", parts: [oversizedEdit]))
        throw CheckFailure(description: "an oversized edited part was rendered")
    } catch ContextPackError.partTooLarge {
        // Expected: the preview retains the edit and reports the explicit bound.
    }

    let pack = ContextPack(
        name: "Release review",
        note: "Challenge the upgrade assumptions.",
        parts: [file, changes, editedTerminal, command]
    )
    let rendered = try builder.render(pack)
    try expect(rendered.contains("Context pack: Release review"), "rendered context lost its name")
    try expect(rendered.contains("Challenge the upgrade assumptions."), "rendered context lost the person's note")
    for part in pack.parts {
        try expect(rendered.contains(part.source.detail), "rendered context lost source provenance")
        try expect(rendered.contains("Current UTF-8 bytes: \(part.byteCount)"), "rendered context omitted an exact part byte count")
    }
    try expect(rendered.contains("Edited after capture: yes"), "rendered context hid an edited capture")
    try expect(rendered.utf8.count == builder.renderedByteCount(pack), "context pack total byte count disagreed with its rendered payload")
    let measurement = builder.measure(pack)
    try expect(
        measurement.renderedByteCount == rendered.utf8.count && measurement.isValid,
        "one-pass context measurement disagreed with the exact send payload"
    )

    let binary = repository.appendingPathComponent("binary.dat")
    try Data([0x41, 0, 0x42]).write(to: binary)
    do {
        _ = try builder.file(at: binary)
        throw CheckFailure(description: "a binary file entered a context pack")
    } catch ContextPackError.notText {
        // Expected: context packs carry reviewable text, never opaque bytes.
    }

    let tinyBuilder = ContextPackBuilder(
        environment: [:],
        gitRunner: gitRunner,
        commandRunner: commandRunner,
        maximumPartBytes: 12,
        maximumRenderedBytes: 64
    )
    do {
        _ = try tinyBuilder.file(at: fileURL)
        throw CheckFailure(description: "an oversized file entered a context pack")
    } catch ContextPackError.partTooLarge {
        // Expected: each source is bounded before it reaches the preview.
    }
    let tinyPackBuilder = ContextPackBuilder(
        environment: [:],
        gitRunner: gitRunner,
        commandRunner: commandRunner,
        maximumPartBytes: 4_096,
        maximumRenderedBytes: 64
    )
    do {
        _ = try tinyPackBuilder.render(ContextPack(name: "Too large", parts: [file]))
        throw CheckFailure(description: "an oversized rendered context pack was accepted")
    } catch ContextPackError.packTooLarge {
        // Expected: wrappers and notes count toward the final handoff ceiling.
    }
    let invalidMeasurement = tinyPackBuilder.measure(ContextPack(name: "Too large", parts: [file]))
    try expect(
        !invalidMeasurement.isValid && invalidMeasurement.renderedByteCount > tinyPackBuilder.maximumRenderedBytes,
        "one-pass context measurement hid an oversized editable pack"
    )
}

private func checkVendorToolEvidenceIsCapabilityGatedAndAttributed() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = PermissionProfileDefinition(
        id: "custom-browser-fixture",
        name: "Browser fixture",
        summary: "Network intent is explicit but does not prove a browser exists.",
        isBuiltIn: false,
        rootMode: .paneFolder,
        defaultLifetime: .session,
        rules: Dictionary(uniqueKeysWithValues: PermissionCapability.allCases.map {
            ($0, $0 == .networkAccess ? PermissionRule.allow : PermissionRule.requireApproval)
        })
    )
    let pane = TmuxPane(
        id: "%browser", kind: .claude, customName: "Researcher",
        terminalTitle: "Browser task completed successfully", cwd: directory.path,
        currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version,
        permissionSelection: PermissionProfileSelection(
            profileID: profile.id,
            approvedRoots: [directory.path],
            lifetime: .session
        ),
        permissionEnforcement: .partiallyEnforced
    )
    let capability = PaneToolCapabilityProjection.summary(for: pane, profiles: [profile])
    try expect(capability.toolAccess == .unknown, "network permission was misreported as verified browser/tool access")
    try expect(capability.networkRule == .allow, "the truthful capability summary lost explicit network-policy intent")
    try expect(capability.canCaptureEvidence, "a live agent pane could not receive explicit person-selected evidence")
    try expect(
        capability.detail.localizedCaseInsensitiveContains("terminal")
            && capability.detail.localizedCaseInsensitiveContains("not evidence"),
        "the capability summary did not explain why successful-looking terminal prose proves nothing"
    )

    let stopped = TmuxPane(
        id: "%stopped", kind: .codex, customName: nil, terminalTitle: "", cwd: directory.path,
        currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil,
        isStarted: false
    )
    let stoppedCapability = PaneToolCapabilityProjection.summary(for: stopped, profiles: [])
    try expect(
        stoppedCapability.toolAccess == .unavailable && !stoppedCapability.canCaptureEvidence,
        "a stopped pane advertised live vendor-tool evidence capture"
    )

    let capturedAt = Date(timeIntervalSince1970: 1_787_680_800)
    let builder = ContextPackBuilder(
        maximumPartBytes: 4_096,
        maximumRenderedBytes: 20_000,
        maximumArtifactBytes: 1_024
    )
    let url = try builder.browserURLEvidence(
        from: pane,
        url: "https://example.com/reference?q=parley",
        capturedAt: capturedAt
    )
    try expect(url.source.kind == .browserURL, "a browser URL lost its explicit source kind")
    try expect(url.source.vendorEvidence?.vendor == .claude, "browser evidence lost its vendor attribution")
    try expect(url.source.vendorEvidence?.paneID == pane.id, "browser evidence lost its exact pane attribution")
    try expect(url.source.vendorEvidence?.toolAccess == .unknown, "browser evidence invented an affirmative capability")
    try expect(url.text.localizedCaseInsensitiveContains("did not fetch"), "a URL capture implied Parley had inspected the page")

    let selectionText = "Only this person-selected paragraph is evidence."
    let selection = try builder.browserSelectionEvidence(
        from: pane,
        url: "https://example.com/reference",
        text: selectionText,
        capturedAt: capturedAt
    )
    try expect(selection.source.kind == .browserSelection, "browser-selected text lost its source kind")
    try expect(selection.capturedText == selectionText, "browser-selected text changed during capture")

    for invalidURL in ["file:///tmp/private", "https://person:secret@example.com/private", "javascript:alert(1)"] {
        do {
            _ = try builder.browserURLEvidence(from: pane, url: invalidURL, capturedAt: capturedAt)
            throw CheckFailure(description: "unsafe browser URL entered a context pack: \(invalidURL)")
        } catch ContextPackError.invalidEvidence {
            // Expected: only credential-free HTTP(S) provenance is accepted.
        }
    }

    let png = try require(
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6pWQAAAAASUVORK5CYII="),
        "PNG fixture could not be decoded"
    )
    let screenshotFile = directory.appendingPathComponent("browser-proof.png")
    try png.write(to: screenshotFile)
    let screenshot = try builder.vendorArtifactEvidence(
        kind: .browserScreenshot,
        from: pane,
        file: screenshotFile,
        sourceURL: "https://example.com/reference",
        capturedAt: capturedAt
    )
    let screenshotEvidence = try require(screenshot.source.vendorEvidence, "screenshot lost its typed provenance")
    try expect(screenshot.source.kind == .browserScreenshot, "screenshot lost its source kind")
    try expect(screenshotEvidence.artifactByteCount == png.count, "screenshot provenance reported the wrong byte size")
    try expect(screenshotEvidence.sha256?.count == 64, "screenshot provenance omitted its exact SHA-256 identity")
    try expect(!screenshot.capturedText.contains(png.base64EncodedString()), "binary screenshot bytes were hidden inside a text context pack")

    let artifactFile = directory.appendingPathComponent("tool-output.bin")
    try Data([0, 1, 2, 3, 4]).write(to: artifactFile)
    let artifact = try builder.vendorArtifactEvidence(
        kind: .savedArtifact,
        from: pane,
        file: artifactFile,
        sourceURL: nil,
        capturedAt: capturedAt
    )
    try expect(artifact.source.kind == .toolArtifact, "saved tool artifact lost its source kind")
    try expect(artifact.source.vendorEvidence?.artifactByteCount == 5, "saved artifact lost its byte size")

    let rendered = try builder.render(ContextPack(
        name: "Vendor evidence",
        note: "Review only the attributed evidence.",
        parts: [url, selection, screenshot, artifact]
    ))
    for expected in [
        "Evidence vendor: Claude", "Evidence pane: Researcher (%browser)",
        "Browser/tool capability: Unknown", "Artifact bytes: \(png.count)",
        "Artifact SHA-256:", "Parley did not open, scrape or control the vendor browser session",
    ] {
        try expect(rendered.contains(expected), "rendered vendor evidence omitted \(expected)")
    }
    let roundTrip = try JSONDecoder().decode(
        ContextPackPart.self,
        from: JSONEncoder().encode(screenshot)
    )
    try expect(roundTrip == screenshot, "serialized context evidence lost its provenance")

    let boundedBuilder = ContextPackBuilder(maximumArtifactBytes: 4)
    do {
        _ = try boundedBuilder.vendorArtifactEvidence(
            kind: .savedArtifact,
            from: pane,
            file: artifactFile,
            sourceURL: nil,
            capturedAt: capturedAt
        )
        throw CheckFailure(description: "an oversized local artifact crossed the explicit evidence bound")
    } catch ContextPackError.artifactTooLarge {
        // Expected: metadata capture still has a deliberate source-byte ceiling.
    }
}

private func checkWorkspaceBriefsAreDurableAndExplicitlyAttached() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("workspace-briefs.json")
    let store = WorkspaceBriefStore(file: file)
    let createdAt = Date(timeIntervalSince1970: 100)
    let brief = try store.save(
        workspaceID: "@1",
        workspaceName: "parley",
        goal: "Ship reviewed cross-vendor context.",
        constraints: "No API keys.\nNo implicit agent dispatch.",
        decisions: "Every attachment opens as editable context.",
        now: createdAt
    )
    try expect(brief.createdAt == createdAt && brief.updatedAt == createdAt, "workspace brief timestamps were not stable")

    let builder = ContextPackBuilder()
    let ordinary = try builder.visibleTerminal(paneID: "%1", paneName: "Claude", text: "Visible output only")
    let withoutBrief = try builder.render(ContextPack(
        name: "No brief",
        note: "Review this output.",
        parts: [ordinary]
    ))
    try expect(!withoutBrief.contains(brief.goal), "a workspace brief was injected without an explicit attachment")

    let attached = try builder.workspaceBrief(brief)
    try expect(attached.source.kind == .workspaceBrief, "workspace brief attachment lost its provenance kind")
    try expect(attached.source.detail.contains("parley") && attached.source.detail.contains("@1"), "workspace brief attachment lost its workspace provenance")
    let withBrief = try builder.render(ContextPack(
        name: "With brief",
        note: "Review against the workspace brief.",
        parts: [ordinary, attached]
    ))
    try expect(withBrief.contains("Current goal") && withBrief.contains(brief.goal), "explicitly attached workspace brief was omitted")
    try expect(withBrief.contains("No API keys.\nNo implicit agent dispatch."), "workspace brief formatting was flattened")
    let editedAttachment = attached.replacingText("Edited only for this receiving vendor.")
    try expect(editedAttachment.isEdited, "editing an attached brief was not visible in the preview")
    let unchangedBrief = try store.brief(workspaceID: "@1")
    try expect(unchangedBrief?.goal == brief.goal, "editing a context snapshot rewrote the durable workspace brief")

    let updated = try store.save(
        workspaceID: "@1",
        workspaceName: "parley-renamed",
        goal: "Finish the workspace brief flow.",
        constraints: brief.constraints,
        decisions: brief.decisions,
        now: Date(timeIntervalSince1970: 120)
    )
    try expect(updated.id == brief.id && updated.createdAt == createdAt, "updating a workspace brief created a second identity")
    let updatedBriefs = try store.briefs()
    try expect(updatedBriefs.count == 1, "one workspace acquired multiple briefs")
    let other = try store.save(
        workspaceID: "@2",
        workspaceName: "consumer",
        goal: "Verify the consumer.",
        constraints: "Read only.",
        decisions: "Use an independent vendor."
    )
    try store.delete(workspaceID: "@1")
    let remainingBriefs = try store.briefs()
    try expect(remainingBriefs.map(\.id) == [other.id], "deleting one workspace brief removed an unrelated workspace")

    let permissions = try require(
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber,
        "workspace brief permissions were unavailable"
    )
    try expect(permissions.intValue & 0o077 == 0, "workspace briefs are readable outside their owner")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    do {
        _ = try WorkspaceBriefStore(file: file).briefs()
        throw CheckFailure(description: "an unsafe workspace brief file was accepted")
    } catch let error as WorkspaceBriefError {
        try expect(error.errorDescription?.contains("owner-only") == true, "unsafe workspace brief permissions failed unclearly")
    }
}

private func checkPinnedContextSnippetsAreDurableReusableAndExplicit() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("pinned-context-snippets.json")
    let store = PinnedContextSnippetStore(file: file)
    let createdAt = Date(timeIntervalSince1970: 200)
    let snippet = try store.save(
        title: "Definition of done",
        text: "Run the deterministic suite.\nReport both stdout and stderr.",
        now: createdAt
    )
    try expect(snippet.createdAt == createdAt && snippet.updatedAt == createdAt, "pinned snippet timestamps were not stable")
    let initialSnippets = try store.snippets()
    try expect(initialSnippets == [snippet], "a pinned snippet did not survive a store reload")

    let builder = ContextPackBuilder()
    let ordinary = try builder.visibleTerminal(paneID: "%1", paneName: "Claude", text: "Implementation complete")
    let withoutSnippet = try builder.render(ContextPack(
        name: "No pinned context",
        note: "Review the implementation.",
        parts: [ordinary]
    ))
    try expect(!withoutSnippet.contains(snippet.text), "a pinned snippet was injected without an explicit attachment")

    let attached = try builder.pinnedSnippet(snippet)
    try expect(attached.source.kind == .pinnedSnippet, "pinned snippet attachment lost its provenance kind")
    try expect(attached.source.referenceID == snippet.id, "pinned snippet attachment lost its durable identity")
    let withSnippet = try builder.render(ContextPack(
        name: "With pinned context",
        note: "Review against the attached criteria.",
        parts: [ordinary, attached]
    ))
    try expect(withSnippet.contains("Definition of done") && withSnippet.contains(snippet.text), "explicitly attached pinned snippet was omitted")
    let editedAttachment = attached.replacingText("Use this wording for this handoff only.")
    try expect(editedAttachment.isEdited, "editing an attached snippet was not visible in the preview")
    let unchangedSnippet = try store.snippet(id: snippet.id)
    try expect(unchangedSnippet?.text == snippet.text, "editing a context snapshot rewrote its pinned snippet")

    let updated = try store.save(
        id: snippet.id,
        title: "Verification contract",
        text: "Run tests.\nRun the production build.",
        now: Date(timeIntervalSince1970: 220)
    )
    try expect(updated.id == snippet.id && updated.createdAt == createdAt, "updating a pinned snippet created a second identity")
    do {
        _ = try store.save(title: "verification CONTRACT", text: "Duplicate title")
        throw CheckFailure(description: "pinned snippets accepted a case-insensitive duplicate title")
    } catch let error as PinnedContextSnippetError {
        try expect(error.errorDescription?.contains("already exists") == true, "duplicate snippet title failed unclearly")
    }
    let other = try store.save(title: "Architecture rule", text: "Keep transport shell-free.")
    try store.delete(id: updated.id)
    let remainingSnippetIDs = try store.snippets().map(\.id)
    try expect(remainingSnippetIDs == [other.id], "deleting one pinned snippet removed unrelated context")

    let permissions = try require(
        try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber,
        "pinned snippet permissions were unavailable"
    )
    try expect(permissions.intValue & 0o077 == 0, "pinned snippets are readable outside their owner")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    do {
        _ = try PinnedContextSnippetStore(file: file).snippets()
        throw CheckFailure(description: "an unsafe pinned snippet file was accepted")
    } catch let error as PinnedContextSnippetError {
        try expect(error.errorDescription?.contains("owner-only") == true, "unsafe pinned snippet permissions failed unclearly")
    }
}

private func statusHandoff(
    id: String,
    kind: RelayHandoffKind,
    state: RelayHandoffState,
    sourceWorkspaceID: String,
    targetWorkspaceID: String,
    occurredAt: TimeInterval,
    text: String? = nil,
    resultText: String? = nil,
    readAt: TimeInterval? = nil,
    attention: RelayAttention? = nil,
    origin: RelayTransitionOrigin? = nil,
    sourceName: String? = nil,
    targetName: String? = nil,
    transitionDetail: String? = nil,
    transitionCount: Int = 1
) throws -> RelayHandoff {
    let transitions: [[String: Any]] = (0..<max(1, transitionCount)).map { offset in
        var transition: [String: Any] = [
            "state": state.rawValue,
            "occurredAt": occurredAt + Double(offset),
            "detail": transitionDetail ?? "Detail \(id)",
        ]
        if let origin { transition["origin"] = origin.rawValue }
        return transition
    }
    var object: [String: Any] = [
        "id": id,
        "idempotencyKey": "key-\(id)",
        "kind": kind.rawValue,
        "sourcePaneID": "%source-\(id)",
        "sourceName": sourceName ?? "Source \(id)",
        "sourceKind": "codex",
        "sourceWorkspaceID": sourceWorkspaceID,
        "sourceWorkspaceName": sourceWorkspaceID,
        "targetPaneID": "%target-\(id)",
        "targetName": targetName ?? "Target \(id)",
        "targetKind": "claude",
        "targetWorkspaceID": targetWorkspaceID,
        "targetWorkspaceName": targetWorkspaceID,
        "text": text ?? "Task \(id)",
        "submitted": true,
        "state": state.rawValue,
        "updatedAt": occurredAt,
        "transitions": transitions,
    ]
    if let resultText { object["resultText"] = resultText }
    if let readAt { object["readAt"] = readAt }
    if let attention { object["attention"] = attention.rawValue }
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RelayHandoff.self, from: data)
}

private func checkDiagnosticsExportIsUsefulAndPrivacyBounded() throws {
    let secrets = [
        "PROMPT_SECRET_71A4",
        "ANSWER_SECRET_9BC2",
        "NAME_SECRET_C1D8",
        "TARGET_SECRET_E5F0",
        "FAILURE_SECRET_47AA",
        "FOLDER_SECRET_951B",
        "COMMAND_SECRET_28CC",
        "TITLE_SECRET_137D",
        "READINESS_SECRET_6EF4",
        "RECOVERY_SECRET_F6A0",
    ]
    let handoff = try statusHandoff(
        id: "diagnostic-failure",
        kind: .ask,
        state: .failed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 100,
        text: secrets[0],
        resultText: secrets[1],
        attention: .targetUnavailable,
        sourceName: secrets[2],
        targetName: secrets[3],
        transitionDetail: secrets[4],
        transitionCount: 25
    )
    let pane = TmuxPane(
        id: "%77",
        kind: .codex,
        customName: secrets[2],
        terminalTitle: secrets[7],
        cwd: "/tmp/\(secrets[5])",
        currentCommand: secrets[6],
        isActive: true,
        windowID: "@0",
        returnToPaneID: "%private-return-route",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: secrets[5],
        bracketedPasteActive: true,
        isDead: false,
        exitStatus: nil,
        isStarted: true
    )
    let readiness = RuntimeReadinessSnapshot(
        checkedAt: Date(timeIntervalSince1970: 90),
        items: [RuntimeReadinessItem(
            id: .core,
            category: .localSystem,
            title: secrets[7],
            state: .attention,
            detail: secrets[8],
            recovery: secrets[9],
            required: true
        )]
    )
    let report = DiagnosticsReportBuilder.build(
        generatedAt: Date(timeIntervalSince1970: 120),
        application: DiagnosticsApplication(
            bundleIdentifier: "com.example.parley",
            version: "0.1.0",
            build: "42",
            runtime: "development"
        ),
        operatingSystem: "macOS test",
        architecture: "arm64",
        uiResidentBytes: 12_345,
        coreResidentBytes: 54_321,
        tmuxAvailable: true,
        coreAvailable: false,
        workspaceCount: 2,
        panes: [pane],
        handoffs: [handoff],
        readiness: readiness
    )
    let encoded = try DiagnosticsReportEncoder.encode(report)
    let text = String(decoding: encoded, as: UTF8.self)

    for secret in secrets {
        try expect(!text.contains(secret), "diagnostics leaked private value \(secret)")
    }
    try expect(text.contains("diagnostic-failure"), "diagnostics omitted the failure correlation id")
    try expect(text.contains("targetUnavailable"), "diagnostics omitted the structured attention reason")
    try expect(text.contains("12345") && text.contains("54321"), "diagnostics omitted bounded process memory")
    try expect(text.contains("development"), "diagnostics omitted the runtime namespace")
    try expect(report.failures.count == 1, "diagnostics omitted the recent operational failure")
    try expect(
        report.failures[0].transitions.count == DiagnosticsReportBuilder.maximumTransitionsPerFailure,
        "diagnostics did not bound a pathological failure transition trail"
    )
    try expect(report.panes.count == 1, "diagnostics omitted the pane process state")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-diagnostics-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = root.appendingPathComponent("Parley-Diagnostics.zip")
    try DiagnosticsArchiveWriter().write(report: report, to: archive)
    try expect(FileManager.default.fileExists(atPath: archive.path), "diagnostics ZIP was not created")

    let extracted = root.appendingPathComponent("extracted", isDirectory: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    let unzip = try ProcessCommandRunner(timeout: 10).run(
        executable: URL(fileURLWithPath: "/usr/bin/ditto"),
        arguments: ["-x", "-k", archive.path, extracted.path],
        environment: ProcessInfo.processInfo.environment,
        input: nil
    )
    try expect(unzip.status == 0, "diagnostics ZIP could not be extracted: \(unzip.stderrText)")
    let files = try FileManager.default.subpathsOfDirectory(atPath: extracted.path)
    try expect(files.contains(where: { $0.hasSuffix("diagnostics.json") }), "diagnostics ZIP omitted diagnostics.json")
    try expect(files.contains(where: { $0.hasSuffix("README.txt") }), "diagnostics ZIP omitted its privacy README")
    for relativePath in files where !relativePath.hasSuffix(".DS_Store") {
        let url = extracted.appendingPathComponent(relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for secret in secrets {
            try expect(!content.contains(secret), "diagnostics archive leaked private value \(secret)")
        }
    }
}

private func checkMemoryPlateauAssessment() throws {
    let plateau = MemoryPlateauAssessment.evaluate(
        samples: [20, 80, 140, 158, 162, 159, 164, 161, 160, 163, 162, 161],
        warmupSamples: 3,
        absoluteAllowanceBytes: 8,
        relativeAllowance: 0
    )
    try expect(plateau.verdict == .passed, "a noisy steady-state memory plateau failed")
    try expect(plateau.earlyMedianBytes == 159, "the plateau baseline did not use the early steady-state median")
    try expect(plateau.lateMedianBytes == 162, "the plateau finish did not use the late steady-state median")
    try expect(plateau.growthBytes == 3, "the plateau growth was calculated incorrectly")

    let growth = MemoryPlateauAssessment.evaluate(
        samples: [10, 20, 100, 120, 140, 160, 180, 200, 220, 240],
        warmupSamples: 2,
        absoluteAllowanceBytes: 20,
        relativeAllowance: 0
    )
    try expect(growth.verdict == .failed, "steadily growing memory was misreported as a plateau")
    try expect(
        (growth.growthBytes ?? Int64.min) > Int64(growth.allowanceBytes),
        "failed growth did not exceed its allowance"
    )

    let relative = MemoryPlateauAssessment.evaluate(
        samples: [1, 2, 1_000, 1_010, 1_040, 1_060, 1_080, 1_090, 1_100, 1_110],
        warmupSamples: 2,
        absoluteAllowanceBytes: 10,
        relativeAllowance: 0.15
    )
    try expect(relative.verdict == .passed, "the relative plateau allowance was ignored")
    try expect(relative.allowanceBytes == 151, "the relative plateau allowance was not based on its baseline")

    let insufficient = MemoryPlateauAssessment.evaluate(
        samples: [1, 2, 3],
        warmupSamples: 2,
        absoluteAllowanceBytes: 1,
        relativeAllowance: 0
    )
    try expect(insufficient.verdict == .insufficientSamples, "an under-sampled run produced a confident verdict")
}

private func checkStatusCenterProjectionUsesOnlyAuthoritativeState() throws {
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Lead", terminalTitle: "", cwd: "/tmp/a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        TmuxPane(id: "%2", kind: .agy, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/a", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        TmuxPane(id: "%3", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp/b", currentCommand: "claude", isActive: false, windowID: "@1", returnToPaneID: nil, relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "b", isStarted: true),
        TmuxPane(id: "%4", kind: .copilot, customName: "Stopped", terminalTitle: "", cwd: "/tmp/b", currentCommand: "sleep", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "b", isStarted: false),
    ]
    let handoffs = [
        try statusHandoff(id: "ask", kind: .ask, state: .waiting, sourceWorkspaceID: "@0", targetWorkspaceID: "@0", occurredAt: 30),
        try statusHandoff(id: "delegate", kind: .delegate, state: .delivered, sourceWorkspaceID: "@1", targetWorkspaceID: "@1", occurredAt: 40),
        try statusHandoff(id: "failure", kind: .relay, state: .failed, sourceWorkspaceID: "@1", targetWorkspaceID: "@1", occurredAt: 50, attention: .permissionRequired),
        try statusHandoff(id: "complete", kind: .relay, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 20, origin: .human),
        try statusHandoff(id: "result", kind: .ask, state: .completed, sourceWorkspaceID: "@0", targetWorkspaceID: "@1", occurredAt: 25, resultText: "Returned answer"),
        try statusHandoff(id: "read-result", kind: .delegate, state: .completed, sourceWorkspaceID: "@1", targetWorkspaceID: "@0", occurredAt: 15, resultText: "Already viewed", readAt: 16),
    ]

    let all = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(all.condition == .humanInputRequired, "human attention did not outrank ordinary waiting state")
    try expect(all.counts.runningAgents == 3 && all.counts.stoppedAgents == 1, "agent readiness counts were inferred incorrectly")
    try expect(all.counts.outstandingQuestions == 1 && all.counts.trackedDelegations == 1, "active operation counts were wrong")
    try expect(all.counts.failures == 1, "failed handoff count was wrong")
    try expect(all.counts.unreadResults == 1, "unread returned-result count was wrong")
    try expect(all.activeHandoffs.map(\.id) == ["delegate", "ask"], "active handoffs were not newest-first")
    try expect(all.timeline.first?.handoffID == "failure", "timeline was not newest-first")
    try expect(all.timeline.first?.detail == "Detail failure", "timeline discarded the authoritative transition detail")
    try expect(all.timeline.first(where: { $0.handoffID == "complete" })?.origin == .human, "timeline discarded a human intervention marker")

    let workspace = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: "@0",
        coreAvailable: true
    )
    try expect(workspace.condition == .agentsWaiting, "another workspace's failure contaminated the selected workspace")
    try expect(workspace.counts.runningAgents == 2 && workspace.counts.stoppedAgents == 0, "workspace filter returned foreign agents")
    try expect(workspace.counts.outstandingQuestions == 1 && workspace.counts.trackedDelegations == 0 && workspace.counts.failures == 0, "workspace filter returned foreign activity")
    try expect(workspace.activeHandoffs.map(\.id) == ["ask"], "workspace live collaboration included terminal work")
    try expect(workspace.counts.unreadResults == 1, "cross-workspace result was not attributed to its requesting workspace")
    try expect(Set(workspace.timeline.map(\.handoffID)) == Set(["ask", "complete", "result", "read-result"]), "workspace timeline lost or added handoffs")

    let targetWorkspace = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: "@1",
        coreAvailable: true
    )
    try expect(targetWorkspace.counts.unreadResults == 0, "a returned result was counted in the target workspace instead of its requester workspace")

    let returned = StatusCenterProjection.snapshot(
        panes: [],
        handoffs: [handoffs[4]],
        workspaceID: nil,
        coreAvailable: true
    )
    try expect(returned.condition == .resultsAvailable, "an unread returned result was shown as all clear")

    try expect(StatusCenterVisibility.isDismissible(handoffs[3]), "an ordinary completed handoff could not be dismissed locally")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[0]), "active work could be hidden by local dismissal")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[2]), "failed work could be hidden by local dismissal")
    try expect(!StatusCenterVisibility.isDismissible(handoffs[4]), "an unread returned result could be hidden by local dismissal")
    try expect(StatusCenterVisibility.isDismissible(handoffs[5]), "a viewed completed result could not be dismissed locally")

    let dismissed = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true,
        dismissedHandoffIDs: ["complete", "result", "ask", "failure"],
        includeDismissed: false
    )
    try expect(!dismissed.handoffs.contains(where: { $0.id == "complete" }), "dismissed completed work remained visible")
    try expect(dismissed.handoffs.contains(where: { $0.id == "result" }), "dismissal concealed an unread result")
    try expect(dismissed.handoffs.contains(where: { $0.id == "ask" }), "dismissal concealed active work")
    try expect(dismissed.handoffs.contains(where: { $0.id == "failure" }), "dismissal concealed failed work")
    try expect(!dismissed.timeline.contains(where: { $0.handoffID == "complete" }), "dismissed work remained in the visible timeline")

    let restored = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: true,
        dismissedHandoffIDs: ["complete"],
        includeDismissed: true
    )
    try expect(restored.handoffs.contains(where: { $0.id == "complete" }), "show dismissed did not restore the local record projection")

    try expect(
        StatusCenterVisibility.retainedDismissalIDs(["complete", "missing"], handoffs: handoffs) == ["complete"],
        "stale local dismissal preferences were not pruned against durable history"
    )

    let interruptedNotification = try statusHandoff(
        id: "interrupted-notification",
        kind: .delegate,
        state: .interrupted,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 60,
        text: "NOTIFICATION SECRET",
        sourceName: "Lead",
        targetName: "Builder"
    )
    let notifications = StatusNotificationProjection.events(handoffs: handoffs + [interruptedNotification])
    try expect(notifications.map(\.id) == ["interrupted-notification:failure", "failure:attention:permissionRequired", "result:result"], "notification projection emitted old, duplicate, or non-actionable events")
    try expect(notifications.map(\.kind) == [.failure, .attention, .returnedResult], "notification kinds lost failure or attention meaning")
    try expect(notifications[0].workspaceName == "@0", "failure notification was not routed to the requesting workspace")
    try expect(notifications[1].workspaceName == "@1", "attention notification was not routed to the target workspace")
    try expect(notifications[2].workspaceName == "@0", "returned-result notification was not routed to the requesting workspace")
    try expect(
        notifications.allSatisfy { !$0.title.contains("Task") && !$0.body.contains("Returned answer") && !$0.title.contains("NOTIFICATION SECRET") && !$0.body.contains("NOTIFICATION SECRET") },
        "notification text exposed prompt or result content"
    )

    let unavailable = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: handoffs,
        workspaceID: nil,
        coreAvailable: false
    )
    try expect(unavailable.condition == .coreUnavailable, "core failure did not override secondary status")
}

private func checkCollaborationHistorySearchExportAndRepeat() throws {
    let completedAsk = try statusHandoff(
        id: "ask-complete",
        kind: .ask,
        state: .completed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@0",
        occurredAt: 30,
        text: "Review the retry policy\n```dangerous example```",
        resultText: "Timeout handling is correct.",
        readAt: 31,
        sourceName: "Builder",
        targetName: "Reviewer",
        transitionDetail: "Answer returned exactly"
    )
    let activeDelegate = try statusHandoff(
        id: "delegate-active",
        kind: .delegate,
        state: .waiting,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 40,
        text: "Implement the toolbar",
        sourceName: "Lead",
        targetName: "Builder"
    )
    let failedAsk = try statusHandoff(
        id: "ask-failed",
        kind: .ask,
        state: .failed,
        sourceWorkspaceID: "@1",
        targetWorkspaceID: "@1",
        occurredAt: 60,
        text: "Review timeout recovery",
        attention: .targetUnavailable,
        sourceName: "Planner",
        targetName: "Reviewer"
    )
    let failedRelay = try statusHandoff(
        id: "relay-failed",
        kind: .relay,
        state: .interrupted,
        sourceWorkspaceID: "@1",
        targetWorkspaceID: "@0",
        occurredAt: 50,
        text: "Retry the transport",
        sourceName: "Planner",
        targetName: "Builder"
    )
    let handoffs = [completedAsk, activeDelegate, failedAsk, failedRelay]

    let searched = CollaborationHistoryProjection.filter(
        handoffs,
        using: CollaborationHistoryFilter(query: "REVIEW timeout", kind: .ask, outcome: .all)
    )
    try expect(searched.map(\.id) == ["ask-failed", "ask-complete"], "history search was not case-insensitive AND matching across prompt and result")
    let active = CollaborationHistoryProjection.filter(
        handoffs,
        using: CollaborationHistoryFilter(query: "", kind: .delegate, outcome: .active)
    )
    try expect(active.map(\.id) == ["delegate-active"], "history kind and active filters did not compose")
    let attention = CollaborationHistoryProjection.filter(
        handoffs,
        using: CollaborationHistoryFilter(query: "reviewer", kind: .all, outcome: .needsAttention)
    )
    try expect(attention.map(\.id) == ["ask-failed"], "history attention filter ignored authoritative attention state")
    let failures = CollaborationHistoryProjection.filter(
        handoffs,
        using: CollaborationHistoryFilter(query: "", kind: .all, outcome: .failedOrInterrupted)
    )
    try expect(failures.map(\.id) == ["ask-failed", "relay-failed"], "history failure filter was not newest-first")

    let generatedAt = Date(timeIntervalSince1970: 100)
    let markdown = CollaborationHistoryMarkdown.document(
        handoffs: [completedAsk, failedRelay],
        scopeName: "Workspace Alpha",
        generatedAt: generatedAt
    )
    try expect(markdown.contains("# Parley Collaboration History"), "history export omitted its title")
    try expect(markdown.contains("Workspace Alpha") && markdown.contains("2 selected records"), "history export omitted explicit scope and selection count")
    try expect(markdown.contains("ask-complete") && markdown.contains("relay-failed"), "history export omitted a selected record")
    try expect(markdown.contains(completedAsk.text) && markdown.contains(completedAsk.resultText!), "history export changed selected prompt or result text")
    try expect(markdown.contains("Answer returned exactly"), "history export omitted delivery receipts")
    try expect(!markdown.contains("delegate-active") && !markdown.contains("Implement the toolbar"), "history export included an unselected record")
    try expect(markdown.contains("````text\nReview the retry policy"), "history export did not protect embedded Markdown fences")

    let exportDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: exportDirectory) }
    let destination = exportDirectory.appendingPathComponent("history.md")
    try CollaborationHistoryMarkdownWriter.write(markdown, to: destination)
    let writtenMarkdown = try String(contentsOf: destination, encoding: .utf8)
    try expect(writtenMarkdown == markdown, "history writer changed the reviewed Markdown")
    let permissions = try require(
        try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber,
        "history export permissions were unavailable"
    )
    try expect(permissions.intValue & 0o077 == 0, "history export was readable outside its owner")

    let source = TmuxPane(
        id: completedAsk.sourcePaneID,
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "codex",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        bracketedPasteActive: true,
        isStarted: true
    )
    let target = TmuxPane(
        id: completedAsk.targetPaneID,
        kind: .claude,
        customName: "Reviewer",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "claude",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        bracketedPasteActive: true,
        isStarted: true
    )
    let route = try require(
        CollaborationHistoryRepeat.route(for: completedAsk, panes: [source, target]),
        "a completed Ask with two live cross-vendor panes could not be prepared again"
    )
    try expect(route.sourcePaneID == source.id && route.targetPaneID == target.id, "Ask This Again changed the recorded route")
    try expect(CollaborationHistoryRepeat.route(for: failedRelay, panes: [source, target]) == nil, "Ask This Again accepted a non-Ask handoff")
    let staleTarget = TmuxPane(
        id: target.id,
        kind: target.kind,
        customName: target.customName,
        terminalTitle: target.terminalTitle,
        cwd: target.cwd,
        currentCommand: target.currentCommand,
        isActive: target.isActive,
        windowID: target.windowID,
        returnToPaneID: target.returnToPaneID,
        relayEnabled: target.relayEnabled,
        protocolVersion: "v0",
        workspaceName: target.workspaceName,
        bracketedPasteActive: target.bracketedPasteActive,
        isStarted: target.isStarted
    )
    try expect(CollaborationHistoryRepeat.route(for: completedAsk, panes: [source, staleTarget]) == nil, "Ask This Again bypassed the current-protocol gate")
}

private func checkConfigurableHistoryRetentionAndWorkspaceExport() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let policyFile = directory.appendingPathComponent("history-retention.json")
    let store = CollaborationHistoryRetentionStore(file: policyFile)
    let defaultPolicy = try store.policy()
    try expect(
        defaultPolicy == .defaultPolicy,
        "a new retention store did not use Parley's bounded default"
    )
    let compact = try CollaborationHistoryRetentionPolicy(maximumRecords: 100)
    try store.save(compact)
    let reloadedPolicy = try CollaborationHistoryRetentionStore(file: policyFile).policy()
    try expect(reloadedPolicy == compact, "retention policy did not survive reload")
    let attributes = try FileManager.default.attributesOfItem(atPath: policyFile.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o077 == 0, "retention policy was readable outside its owner")
    do {
        _ = try CollaborationHistoryRetentionPolicy(maximumRecords: 101)
        throw CheckFailure(description: "retention accepted a value outside its explicit choices")
    } catch is CollaborationHistoryRetentionError {
        // Expected: the UI and control route cannot invent an unbounded value.
    }

    let historyFile = directory.appendingPathComponent("bounded-history.jsonl")
    let journal = try RelayHandoffJournal(file: historyFile, maximumHandoffs: 500)
    for index in 0..<3 {
        journal.record(try statusHandoff(
            id: "retained-\(index)",
            kind: .relay,
            state: .completed,
            sourceWorkspaceID: index == 2 ? "@1" : "@0",
            targetWorkspaceID: index == 0 ? "@1" : "@0",
            occurredAt: TimeInterval(index + 1),
            text: "history \(index)"
        ))
    }
    let removed = try journal.updateMaximumHandoffs(2)
    try expect(removed == 1, "lowering durable retention did not report the removed record")
    let retained = journal.handoffs()
    try expect(retained.map(\.id) == ["retained-2", "retained-1"], "lowering retention did not keep the newest terminal records")
    let replayedRetained = try RelayHandoffJournal(file: historyFile, maximumHandoffs: 2).handoffs()
    try expect(
        replayedRetained.map(\.id) == retained.map(\.id),
        "the lowered retention result was not durable"
    )

    let allRecords = [
        try statusHandoff(
            id: "workspace-cross",
            kind: .ask,
            state: .completed,
            sourceWorkspaceID: "@0",
            targetWorkspaceID: "@1",
            occurredAt: 10,
            text: "cross workspace"
        ),
        try statusHandoff(
            id: "workspace-local",
            kind: .delegate,
            state: .completed,
            sourceWorkspaceID: "@1",
            targetWorkspaceID: "@1",
            occurredAt: 20,
            text: "other workspace"
        ),
    ]
    let workspaceRecords = CollaborationHistoryProjection.records(
        allRecords,
        involvingWorkspaceID: "@0"
    )
    try expect(workspaceRecords.map(\.id) == ["workspace-cross"], "workspace export included unrelated history")
    let workspaceMarkdown = CollaborationHistoryMarkdown.document(
        handoffs: workspaceRecords,
        scopeName: "Workspace Zero",
        selectionDescription: "All retained handoffs involving this workspace",
        generatedAt: Date(timeIntervalSince1970: 100)
    )
    try expect(
        workspaceMarkdown.contains("All retained handoffs involving this workspace")
            && workspaceMarkdown.contains("workspace-cross")
            && !workspaceMarkdown.contains("workspace-local"),
        "workspace export did not describe and preserve its exact scope"
    )
}

private func checkHistoryRetentionCoreControlRoute() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%source")
    _ = try credentials.token(for: "%target")
    let panes = [
        TmuxPane(id: "%source", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "app"),
        TmuxPane(id: "%target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "app"),
    ]
    let retentionStore = CollaborationHistoryRetentionStore(
        file: directory.appendingPathComponent("history-retention.json")
    )
    let policy = try retentionStore.policy()
    let handoffJournal = try RelayHandoffJournal(
        file: directory.appendingPathComponent("handoffs.jsonl"),
        maximumHandoffs: policy.maximumRecords
    )
    let activityJournal = try RelayActivityJournal(
        file: directory.appendingPathComponent("activity-events.jsonl"),
        maximumEvents: policy.maximumRecords
    )
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: handoffJournal,
        activityJournal: activityJournal,
        historyRetentionPolicy: policy,
        historyRetentionStore: retentionStore
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: "retention-control")
    try server.start()
    defer { server.stop() }

    for index in 0..<101 {
        let handoff = broker.handle(
            token: sourceToken,
            target: "Reviewer",
            text: "retention control handoff \(index)",
            idempotencyKey: "retention-control-\(index)"
        )
        try expect(handoff.status == 200, "retention control fixture could not create handoff \(index)")
        _ = try broker.recordActivity(RelayActivityEventRequest(
            kind: .paneRestarted,
            workspaceID: "@0",
            workspaceName: "app",
            paneID: "%source",
            paneName: "Builder",
            paneKind: .codex,
            detail: "Retention fixture event \(index)."
        ))
    }

    let client = RelayCoreClient(infoFile: infoFile, controlToken: "retention-control")
    let initialPolicy = try client.historyRetentionPolicy()
    try expect(initialPolicy == .defaultPolicy, "the UI could not read core-owned retention")
    let change = try client.updateHistoryRetention(maximumRecords: 100)
    try expect(change.policy.maximumRecords == 100, "the authenticated retention update did not reach the core")
    try expect(change.removedHandoffs == 1 && change.removedActivityEvents == 1, "retention update did not report both compacted journals")
    let retainedHandoffs = try client.handoffs()
    let retainedActivity = try client.activityEvents()
    try expect(retainedHandoffs.count == 100, "retention update did not compact the live handoff projection")
    try expect(retainedActivity.count == 100, "retention update did not compact the live activity projection")
    let persistedPolicy = try retentionStore.policy()
    try expect(persistedPolicy.maximumRecords == 100, "the core did not persist updated retention")

    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")
    var unauthorizedRejected = false
    do {
        _ = try unauthorized.updateHistoryRetention(maximumRecords: 250)
    } catch let RelayCoreError.response(status, _) where status == 401 {
        unauthorizedRejected = true
    }
    try expect(unauthorizedRejected, "an unauthenticated UI changed local retention")
    let policyAfterRejection = try retentionStore.policy()
    try expect(policyAfterRejection.maximumRecords == 100, "the rejected retention request changed durable policy")

    var invalidRejected = false
    do {
        _ = try client.updateHistoryRetention(maximumRecords: 101)
    } catch let RelayCoreError.response(status, _) where status == 400 {
        invalidRejected = true
    }
    try expect(invalidRejected, "the core accepted an unsupported retention value")
}

private func checkHumanAskAgainUsesTrackedCoreControlRoute() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    _ = try credentials.token(for: "%source")
    let targetToken = try credentials.token(for: "%target")
    let panes = [
        TmuxPane(
            id: "%source", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true, automationPolicy: .off
        ),
        TmuxPane(
            id: "%target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "ask-again-ui-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }

    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")
    let rejected = try unauthorized.askFromUI(
        sourcePaneID: "%source",
        targetPaneID: "%target",
        text: "Do not submit this.",
        idempotencyKey: "repeat-rejected"
    )
    try expect(rejected.status == 401, "an unauthenticated UI repeated an Ask")
    try expect(submissions.values.isEmpty, "the rejected repeated Ask submitted terminal input")

    let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            result.set(try client.askFromUI(
                sourcePaneID: "%source",
                targetPaneID: "%target",
                text: "Review this edited question.",
                idempotencyKey: "repeat-new-identity"
            ))
        } catch {
            result.set(RelayTextResponse(status: 599, text: error.localizedDescription))
        }
    }
    try expect(eventually { broker.consultations().count == 1 }, "Ask This Again did not create a tracked consultation")
    try expect(submissions.values.count == 1 && submissions.values[0].paneID == "%target", "Ask This Again submitted to the wrong pane")
    try expect(submissions.values[0].text.contains("Review this edited question."), "Ask This Again submitted stale history text")
    let repeated = try require(broker.handoffs().first, "Ask This Again did not create durable history")
    try expect(repeated.id != "historic-handoff", "Ask This Again reused a historical identity")
    try expect(repeated.idempotencyKey == "repeat-new-identity", "Ask This Again lost its fresh idempotency identity")
    try expect(repeated.transitions.allSatisfy { $0.origin == .human }, "Ask This Again was not attributed to the person")

    let answer = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Reviewed answer")
    try expect(answer.status == 200, "the repeated Ask target could not return its correlated answer")
    try expect(eventually { result.value != nil }, "Ask This Again remained blocked after its answer returned")
    let completed = try require(result.value, "Ask This Again produced no response")
    try expect(completed.status == 200 && completed.text == "Reviewed answer", "Ask This Again lost its correlated answer")
}

private func checkRecoveryGuidanceProjectsKnownFailures() throws {
    let dead = TmuxPane(
        id: "%dead",
        kind: .codex,
        customName: "Exited Codex",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "codex",
        isActive: false,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        isDead: true,
        exitStatus: 9,
        isStarted: true
    )
    let stale = TmuxPane(
        id: "%stale",
        kind: .agy,
        customName: "Older Agy",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "agy",
        isActive: true,
        windowID: "@0",
        returnToPaneID: nil,
        relayEnabled: false,
        protocolVersion: "1",
        workspaceName: "a",
        isStarted: true
    )
    let missingCodex = RuntimeReadinessItem(
        id: .codex,
        category: .vendor,
        title: "Codex",
        state: .unavailable,
        detail: "Not installed.",
        recovery: "Install Codex and sign in.",
        required: false
    )
    let readiness = RuntimeReadinessSnapshot(items: [missingCodex])
    let interrupted = try statusHandoff(
        id: "interrupted-ask",
        kind: .ask,
        state: .interrupted,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 50
    )
    let unrelated = try statusHandoff(
        id: "failed-relay",
        kind: .relay,
        state: .failed,
        sourceWorkspaceID: "@1",
        targetWorkspaceID: "@1",
        occurredAt: 60
    )

    let issues = RecoveryGuidanceProjection.issues(
        coreAvailable: false,
        readiness: readiness,
        panes: [dead, stale],
        handoffs: [unrelated, interrupted],
        workspaceID: "@0"
    )
    try expect(
        issues.map(\.topic) == [.damagedSocket, .missingCLI, .staleProtocol, .deadPane, .interruptedConsultation],
        "recovery guidance did not cover the five known failure modes in a stable order"
    )
    try expect(issues[0].action == .reconnect, "damaged socket guidance did not offer the safe reconnect path")
    try expect(issues[1].action == .refreshEnvironment, "missing CLI guidance did not offer a quota-free environment check")
    try expect(issues[2].action == .restartPane("%stale"), "stale protocol guidance targeted the wrong pane")
    try expect(issues[3].action == .restartPane("%dead"), "dead-pane guidance targeted the wrong pane")
    try expect(issues[4].action == .inspectHandoff("interrupted-ask"), "interrupted Ask guidance lost its durable record")
    try expect(!issues.contains(where: { $0.id.contains("failed-relay") }), "a failed one-way relay was misreported as an interrupted consultation")

    try expect(
        RecoveryGuidanceProjection.playbook.map(\.topic) == RecoveryGuidanceTopic.allCases,
        "the in-app recovery playbook does not document every known failure mode"
    )
    try expect(
        RecoveryGuidanceProjection.playbook.allSatisfy { !$0.steps.isEmpty },
        "a recovery playbook entry has no actionable steps"
    )
    try expect(
        RecoveryGuidanceProjection.issues(
            coreAvailable: true,
            readiness: RuntimeReadinessSnapshot(items: []),
            panes: [],
            handoffs: [],
            workspaceID: nil
        ).isEmpty,
        "healthy state produced a recovery warning"
    )
}

private func checkOperationalActivityIsDurableAndAuthoritative() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("activity-events.jsonl")
    let journal = try RelayActivityJournal(file: file, maximumEvents: 3)
    let created = RelayActivityEvent(
        id: "workspace-created",
        kind: .workspaceCreated,
        occurredAt: Date(timeIntervalSince1970: 20),
        workspaceID: "@0",
        workspaceName: "api",
        detail: "Opened /tmp/api"
    )
    let restarted = RelayActivityEvent(
        id: "pane-restarted",
        kind: .paneRestarted,
        occurredAt: Date(timeIntervalSince1970: 30),
        workspaceID: "@0",
        workspaceName: "api",
        paneID: "%1",
        paneName: "Codex",
        paneKind: .codex,
        detail: "Codex pane restarted."
    )
    let restored = RelayActivityEvent(
        id: "workspace-restored",
        kind: .workspaceRestored,
        occurredAt: Date(timeIntervalSince1970: 40),
        workspaceID: "@1",
        workspaceName: "web",
        detail: "Opened saved layout Web review."
    )
    try journal.record(created)
    try journal.record(restarted)
    try journal.record(restored)

    let replayed = try RelayActivityJournal(file: file, maximumEvents: 3)
    try expect(replayed.events().map(\.id) == ["workspace-restored", "pane-restarted", "workspace-created"], "activity journal did not replay newest-first")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o777 == 0o600, "activity journal was not owner-only")

    let truncated = try FileHandle(forWritingTo: file)
    try truncated.seekToEnd()
    try truncated.write(contentsOf: Data("{\"incomplete\"".utf8))
    try truncated.close()
    let repaired = try RelayActivityJournal(file: file, maximumEvents: 3)
    try expect(repaired.events().count == 3, "a truncated activity write destroyed valid events")
    let repairedData = try Data(contentsOf: file)
    try expect(repairedData.last == 10, "activity journal startup did not repair its truncated tail")

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [] },
        paste: { _, _ in },
        submit: { _, _ in },
        activityJournal: repaired
    )
    let closed = try broker.recordActivity(RelayActivityEventRequest(
        kind: .workspaceClosed,
        workspaceID: "@2",
        workspaceName: "worker",
        detail: "Closed 2 panes."
    ))
    try expect(closed.origin == .human, "native operational activity was not marked as human")
    try expect(broker.activityEvents(limit: 1).map(\.id) == [closed.id], "broker did not expose newest operational activity")
    try expect(broker.activityEvents().count == 3, "broker activity exceeded its journal bound")

    let status = StatusCenterProjection.snapshot(
        panes: [],
        handoffs: [],
        activityEvents: broker.activityEvents(),
        workspaceID: "@2",
        coreAvailable: true
    )
    let operational = try require(status.timeline.first, "operational activity did not enter the Status Center timeline")
    try expect(operational.handoffID == nil, "operational activity was disguised as a relay handoff")
    try expect(operational.title == "worker", "workspace activity lost its authoritative display name")
    try expect(operational.category == "WORKSPACE" && operational.action == "CLOSED", "workspace activity used the wrong timeline labels")
    try expect(operational.origin == .human, "Status Center discarded the activity origin")

    let deleted = broker.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: "api")
    try expect(deleted.status == 200, "workspace history deletion could not compact operational activity")
    try expect(!broker.activityEvents().contains(where: { $0.workspaceID == "@0" }), "workspace history deletion retained matching operational activity")
    let persistedEvents = try RelayActivityJournal(file: file, maximumEvents: 3).events()
    try expect(persistedEvents == broker.activityEvents(), "operational history deletion was not durable")
}

private func checkAgentRelaySubmitsAndExplicitPasteDoesNot() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let pasted = LockedDelivery()
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { paneID, text in pasted.set(paneID: paneID, text: text, submit: false) },
        submit: { paneID, text in submitted.set(paneID: paneID, text: text, submit: true) }
    )

    let response = broker.handle(token: token, target: "codex", text: "Only send this sentence.")

    try expect(response.status == 200, "valid agent relay was refused")
    try expect(response.body.submitted == true, "agent relay did not report submission")
    try expect(submitted.value?.paneID == "%2", "agent relay targeted the wrong pane")
    try expect(submitted.value?.text == "Agy said:\n\nOnly send this sentence.", "agent relay changed or failed to attribute the explicit text")
    try expect(submitted.value?.submit == true, "agent relay did not press Enter")
    try expect(pasted.value == nil, "agent relay used the unsent paste path")

    let pasteResponse = broker.handlePaste(token: token, target: "codex", text: "Leave this as a draft.")
    try expect(pasteResponse.status == 200, "valid agent paste was refused")
    try expect(pasteResponse.body.submitted == false, "explicit paste claimed it submitted")
    try expect(pasted.value?.text == "Agy said:\n\nLeave this as a draft.", "explicit paste changed the supplied text")
    try expect(pasted.value?.submit == false, "explicit paste pressed Enter")
}

private func checkStableHandoffIdentityAndIdempotentRelay() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() }
    )

    let first = broker.handle(
        token: token,
        target: "codex",
        text: "Review this exact change.",
        idempotencyKey: "relay-check-1"
    )
    let duplicate = broker.handle(
        token: token,
        target: "codex",
        text: "Review this exact change.",
        idempotencyKey: "relay-check-1"
    )

    let handoffID = try require(first.body.handoffID, "successful relay returned no stable handoff id")
    try expect(duplicate.body.handoffID == handoffID, "idempotent retry returned a different handoff id")
    try expect(submissions.value == 1, "idempotent retry submitted the same relay twice")
    try expect(first.body.state == .completed && duplicate.body.state == .completed, "successful relay did not report completion")

    let handoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "completed relay was not observable")
    try expect(handoff.idempotencyKey == "relay-check-1", "handoff lost its idempotency key")
    try expect(handoff.kind == .relay && handoff.state == .completed, "relay handoff recorded the wrong kind or final state")
    try expect(
        handoff.transitions.map(\.state) == [.created, .delivered, .completed],
        "relay handoff lost its delivery state trail"
    )

    let conflict = broker.handle(
        token: token,
        target: "codex",
        text: "A different request must not reuse the key.",
        idempotencyKey: "relay-check-1"
    )
    try expect(conflict.status == 409, "an idempotency key was reused for different relay content")
    try expect(submissions.value == 1, "conflicting idempotency reuse still submitted text")

    let invalid = broker.handle(
        token: token,
        target: "codex",
        text: "This must not be delivered.",
        idempotencyKey: "contains spaces"
    )
    try expect(invalid.status == 400, "an invalid idempotency key was accepted")
    try expect(submissions.value == 1, "invalid idempotency key still submitted text")
}

private func checkCompletedHandoffRetentionIsBounded() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in }
    )

    for index in 0..<510 {
        let response = broker.handle(
            token: token,
            target: "codex",
            text: "retained handoff \(index)",
            idempotencyKey: "retention-\(index)"
        )
        try expect(response.status == 200, "retention fixture could not complete handoff \(index)")
    }

    let retained = broker.handoffs()
    try expect(retained.count == 500, "persistent core retained \(retained.count) completed handoffs instead of its 500-record bound")
    try expect(retained.contains(where: { $0.idempotencyKey == "retention-509" }), "retention discarded the newest handoff")
    try expect(!retained.contains(where: { $0.idempotencyKey == "retention-0" }), "retention kept the oldest handoff")
}

private func checkDurableHandoffJournal() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "repo-a"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "repo-b"),
    ]
    let historyFile = directory.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: historyFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    let relayed = broker.handle(
        token: sourceToken,
        target: "agy",
        text: "Persist this instruction.",
        idempotencyKey: "durable-relay-1"
    )
    try expect(relayed.status == 200, "durable relay fixture failed")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Persist this question and answer.",
            idempotencyKey: "durable-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "durable Ask fixture never started")
    let answer = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Persistent answer.")
    try expect(answer.status == 200, "durable Ask fixture could not answer")
    try expect(eventually { askResult.value?.status == 200 }, "durable Ask requester did not receive its answer")

    let pendingResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        pendingResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "This wait is interrupted by core recovery.",
            idempotencyKey: "durable-pending-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "durable pending Ask never started")

    let recoveredJournal = try RelayHandoffJournal(file: historyFile)
    let recoveredBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: recoveredJournal
    )
    let recovered = recoveredBroker.handoffs()
    try expect(recovered.count == 3, "core recovery lost durable handoff history")
    try expect(
        recovered.first(where: { $0.idempotencyKey == "durable-relay-1" })?.state == .completed,
        "completed relay did not survive core recovery"
    )
    let recoveredAsk = try require(
        recovered.first(where: { $0.idempotencyKey == "durable-ask-1" }),
        "completed Ask did not survive core recovery"
    )
    try expect(recoveredAsk.state == .completed && recoveredAsk.resultText == "Persistent answer.", "durable Ask lost its returned answer")
    try expect(recoveredAsk.hasUnreadResult && recoveredAsk.readAt == nil, "core recovery lost the unread returned-result state")
    try expect(recoveredAsk.sourceKind == .codex && recoveredAsk.targetKind == .agy, "durable Ask lost its vendor identities")
    try expect(recoveredAsk.sourceWorkspaceName == "repo-a" && recoveredAsk.targetWorkspaceName == "repo-b", "durable Ask lost its workspace identities")
    try expect(recoveredBroker.markHandoffRead(recoveredAsk.id).status == 200, "recovered core could not acknowledge a returned result")
    let recoveredPending = try require(
        recovered.first(where: { $0.idempotencyKey == "durable-pending-1" }),
        "pending Ask did not survive core recovery"
    )
    try expect(recoveredPending.state == .interrupted, "recovered in-flight Ask did not become interrupted")
    try expect(recoveredPending.transitions.last?.detail?.contains("core restarted") == true, "recovered Ask lost its interruption reason")

    let attributes = try FileManager.default.attributesOfItem(atPath: historyFile.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o777 == 0o600, "handoff journal was not owner-only")

    broker.cancelAll()
    try expect(eventually { pendingResult.value != nil }, "durable fixture left its original requester blocked")
    let finalJournal = try RelayHandoffJournal(file: historyFile)
    try expect(finalJournal.handoffs().count == 3, "journal replay created duplicate handoffs")
    let finalAsk = try require(
        finalJournal.handoffs().first(where: { $0.id == recoveredAsk.id }),
        "acknowledged Ask disappeared from the durable journal"
    )
    try expect(!finalAsk.hasUnreadResult && finalAsk.readAt != nil, "read acknowledgement did not survive journal replay")

    let truncated = try FileHandle(forWritingTo: historyFile)
    try truncated.seekToEnd()
    try truncated.write(contentsOf: Data("{\"incomplete\"".utf8))
    try truncated.close()
    let repairedJournal = try RelayHandoffJournal(file: historyFile)
    try expect(repairedJournal.handoffs().count == 3, "a truncated final write destroyed valid history")
    let repairedData = try Data(contentsOf: historyFile)
    try expect(repairedData.last == 10, "journal startup did not repair its truncated tail")
    let replayedJournal = try RelayHandoffJournal(file: historyFile)
    try expect(replayedJournal.handoffs().count == 3, "repaired journal did not survive a second replay")

    let boundedFile = directory.appendingPathComponent("bounded-handoffs.jsonl")
    let boundedJournal = try RelayHandoffJournal(file: boundedFile, maximumHandoffs: 2)
    let boundedBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: boundedJournal
    )
    for index in 0..<3 {
        let result = boundedBroker.handle(
            token: sourceToken,
            target: "agy",
            text: "bounded durable handoff \(index)",
            idempotencyKey: "bounded-durable-\(index)"
        )
        try expect(result.status == 200, "bounded journal fixture could not deliver handoff \(index)")
    }
    try expect(boundedJournal.handoffs().count == 2, "live journal projection exceeded its handoff bound")
    let replayedBounded = try RelayHandoffJournal(file: boundedFile, maximumHandoffs: 2).handoffs()
    try expect(replayedBounded.count == 2, "replayed journal exceeded its handoff bound")
    try expect(!replayedBounded.contains(where: { $0.idempotencyKey == "bounded-durable-0" }), "bounded journal retained its oldest terminal handoff")
}

private func checkWorkspaceHandoffHistoryDeletion() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let repoAToken = try credentials.token(for: "%1")
    let repoBToken = try credentials.token(for: "%2")
    let repoCToken = try credentials.token(for: "%3")
    let duplicateNameToken = try credentials.token(for: "%5")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex A", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "repo-a"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy B", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "repo-b"),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "claude", isActive: false, windowID: "@2", returnToPaneID: nil, workspaceName: "repo-c"),
        TmuxPane(id: "%4", kind: .codex, customName: "Codex C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "codex", isActive: false, windowID: "@2", returnToPaneID: nil, workspaceName: "repo-c"),
        TmuxPane(id: "%5", kind: .claude, customName: "Claude Duplicate", terminalTitle: "", cwd: "/tmp/duplicate-a", currentCommand: "claude", isActive: false, windowID: "@3", returnToPaneID: nil, workspaceName: "repo-a"),
        TmuxPane(id: "%6", kind: .codex, customName: "Codex Duplicate", terminalTitle: "", cwd: "/tmp/duplicate-a", currentCommand: "codex", isActive: false, windowID: "@3", returnToPaneID: nil, workspaceName: "repo-a"),
    ]
    let historyFile = directory.appendingPathComponent("handoffs.jsonl")
    let journal = try RelayHandoffJournal(file: historyFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    let crossWorkspace = broker.handle(
        token: repoAToken,
        target: "agy",
        text: "Delete this completed cross-workspace relay.",
        idempotencyKey: "delete-workspace-cross"
    )
    try expect(crossWorkspace.status == 200, "workspace deletion fixture could not create its cross-workspace history")
    let unaffected = broker.handle(
        token: repoCToken,
        target: "Codex C",
        text: "Keep this repo-c relay.",
        idempotencyKey: "delete-workspace-keep"
    )
    try expect(unaffected.status == 200, "workspace deletion fixture could not create unrelated history")
    let sameNameDifferentWorkspace = broker.handle(
        token: duplicateNameToken,
        target: "Codex Duplicate",
        text: "Keep this different workspace with the same display name.",
        idempotencyKey: "delete-workspace-same-name-keep"
    )
    try expect(sameNameDifferentWorkspace.status == 200, "workspace deletion fixture could not create duplicate-name history")

    let pendingResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        pendingResult.set(broker.handleAsk(
            token: repoAToken,
            target: "agy",
            text: "Keep this active Ask even while history is deleted.",
            idempotencyKey: "delete-workspace-active"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "workspace deletion fixture never started its active Ask")

    let invalid = broker.deleteWorkspaceHistory(workspaceID: "", workspaceName: "")
    try expect(invalid.status == 400, "workspace deletion accepted an empty scope")
    let deleted = broker.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: "repo-a")
    try expect(deleted.status == 200, "workspace history deletion failed: \(deleted.text)")

    let remaining = broker.handoffs()
    try expect(!remaining.contains(where: { $0.idempotencyKey == "delete-workspace-cross" }), "workspace deletion retained matching completed history")
    try expect(remaining.contains(where: { $0.idempotencyKey == "delete-workspace-keep" }), "workspace deletion removed another workspace's history")
    try expect(remaining.contains(where: { $0.idempotencyKey == "delete-workspace-same-name-keep" }), "workspace deletion trusted a non-unique display name over the stable workspace id")
    try expect(remaining.contains(where: { $0.idempotencyKey == "delete-workspace-active" }), "workspace deletion removed active work")
    let persisted = try RelayHandoffJournal(file: historyFile).handoffs()
    try expect(!persisted.contains(where: { $0.idempotencyKey == "delete-workspace-cross" }), "workspace deletion did not compact the durable journal")
    try expect(persisted.contains(where: { $0.idempotencyKey == "delete-workspace-keep" }), "durable deletion removed unrelated history")
    try expect(persisted.contains(where: { $0.idempotencyKey == "delete-workspace-same-name-keep" }), "durable deletion removed a duplicate-name workspace with a different id")
    try expect(persisted.contains(where: { $0.idempotencyKey == "delete-workspace-active" }), "durable deletion removed an active handoff")

    try expect(broker.handleAnswer(token: repoBToken, consultationID: "current", text: "Still alive.").status == 200, "the preserved Ask could not be answered")
    try expect(eventually { pendingResult.value?.status == 200 }, "the preserved Ask requester remained blocked")
}

private func checkCrossWorkspaceRelayAddressing() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/api", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil, workspaceName: "api"),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web"),
        TmuxPane(id: "%4", kind: .claude, customName: "Critic", terminalTitle: "", cwd: "/tmp/web", currentCommand: "claude", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web", role: "reviewer"),
    ]
    let submitted = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, text in submitted.set(paneID: paneID, text: text, submit: true) }
    )

    let local = broker.handle(token: token, target: "agy", text: "local question")
    try expect(local.status == 200 && submitted.value?.paneID == "%2", "bare target did not prefer the sender's workspace")

    let qualified = broker.handle(token: token, target: "web/agy", text: "cross-workspace question")
    try expect(qualified.status == 200 && submitted.value?.paneID == "%3", "qualified target did not cross to the named workspace")

    let stableRole = broker.handle(token: token, target: "@reviewer", text: "unique global question")
    try expect(stableRole.status == 200 && submitted.value?.paneID == "%4", "a stable role did not survive an unrelated display name")
    let bareRole = broker.handle(token: token, target: "reviewer", text: "must not retarget")
    try expect(bareRole.status == 400, "a bare name silently resolved through the stable-role namespace")

    let ambiguousPanes = panes + [
        TmuxPane(id: "%5", kind: .copilot, customName: "Second critic", terminalTitle: "", cwd: "/tmp/web", currentCommand: "copilot", isActive: false, windowID: "@1", returnToPaneID: nil, workspaceName: "web", role: "reviewer"),
    ]
    let ambiguousBroker = RelayBroker(
        credentials: credentials,
        panes: { ambiguousPanes },
        paste: { _, _ in },
        submit: { _, _ in }
    )
    let ambiguous = ambiguousBroker.handle(token: token, target: "web/@reviewer", text: "must refuse")
    try expect(
        ambiguous.status == 400 && ambiguous.body.error?.contains("ambiguous") == true,
        "duplicate workspace roles silently retargeted a pane"
    )
}

private func checkRelayCredentialPersistsAndIdentifiesSender() throws {
    let file = try temporaryDirectory().appendingPathComponent("relay-tokens.json")
    let first = try RelayCredentials(file: file)
    let token = try first.token(for: "%7")
    let reopened = try RelayCredentials(file: file)
    try expect(reopened.paneID(for: token) == "%7", "relay credential did not survive UI restart")
    try expect(reopened.paneID(for: "wrong") == nil, "wrong relay credential identified a pane")
}

private func checkRelayCredentialReloadsExternalChanges() throws {
    let file = try temporaryDirectory().appendingPathComponent("relay-tokens.json")
    let core = try RelayCredentials(file: file)
    let reattachedUI = try RelayCredentials(file: file)

    let token = try reattachedUI.token(for: "%12")

    try expect(
        core.paneID(for: token) == "%12",
        "a running coordination core did not observe a pane credential created after it started"
    )
}

private func checkRestartRotatesRelayCredential() throws {
    let pane = paneRow(
        id: "%12",
        kind: .codex,
        active: true,
        relayEnabled: true,
        protocolVersion: AgentProtocol.version
    ) + "\n"
    let runner = RecordingRunner { arguments, _ in
        command(arguments) == "list-panes" ? output(pane) : output()
    }
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let oldToken = try credentials.token(for: "%12")
    let controller = try TmuxController(
        tmuxExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/tmux"),
        applicationDirectory: directory,
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
        runner: runner
    )
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: directory.appendingPathComponent("bin"),
        transportDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory),
        credentials: credentials
    ))

    try controller.restartPane("%12")

    let respawn = try require(runner.calls.first(where: { command($0.arguments) == "respawn-pane" }), "restart did not respawn the pane")
    let field = try require(
        respawn.arguments.first(where: { $0.hasPrefix("PARLEY_RELAY_TOKEN=") }),
        "restarted pane received no relay credential"
    )
    let newToken = String(field.dropFirst("PARLEY_RELAY_TOKEN=".count))
    try expect(newToken != oldToken, "pane restart reused its old relay credential")
    try expect(credentials.paneID(for: oldToken) == nil, "old relay credential survived pane restart")
    try expect(credentials.paneID(for: newToken) == "%12", "new relay credential does not identify the restarted pane")
}

private func checkRelayFilesystemRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let pasted = LockedDelivery()
    let submitted = LockedDelivery()
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { paneID, text in pasted.set(paneID: paneID, text: text, submit: false) },
        submit: { paneID, text in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: text, submit: true)
        }
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    let relayEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": token,
        "PARLEY_IDEMPOTENCY_KEY": "shim-relay-1",
    ]) { _, supplied in supplied }
    let result = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "relay", "codex", "exact body"],
        environment: relayEnvironment,
        input: nil
    )

    try expect(result.status == 0, "relay shim request failed: \(result.stderrText)")
    let response = try JSONDecoder().decode(RelayResponseBody.self, from: result.stdout)
    try expect(response.ok && response.submitted == true, "relay filesystem response did not report submission")
    let relayHandoffID = try require(response.handoffID, "relay filesystem response lost its handoff id")
    try expect(submitted.value?.text == "Agy said:\n\nexact body", "relay filesystem transport changed the explicit body")

    let duplicateResult = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "relay", "codex", "exact body"],
        environment: relayEnvironment,
        input: nil
    )
    try expect(duplicateResult.status == 0, "idempotent relay shim retry failed: \(duplicateResult.stderrText)")
    let duplicateResponse = try JSONDecoder().decode(RelayResponseBody.self, from: duplicateResult.stdout)
    try expect(duplicateResponse.handoffID == relayHandoffID, "shim retry returned a different handoff id")
    try expect(submissionCount.value == 1, "shim retry submitted the relay twice")

    let pasteResult = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "paste", "codex", "draft body"],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_TOKEN": token,
            "PARLEY_IDEMPOTENCY_KEY": "shim-paste-1",
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(pasteResult.status == 0, "paste shim request failed: \(pasteResult.stderrText)")
    let pasteResponse = try JSONDecoder().decode(RelayResponseBody.self, from: pasteResult.stdout)
    try expect(pasteResponse.ok && pasteResponse.submitted == false, "paste filesystem response claimed submission")
    try expect(pasted.value?.text == "Agy said:\n\ndraft body", "paste filesystem transport changed the explicit body")
    try expect(eventually {
        let names = ["inbox", "processing", "outbox"]
        let endpoint = RelayFileTransport.endpointDirectory(
            runtimeDirectory: transportDirectory,
            paneToken: token
        )
        return names.allSatisfy { name in
            let path = endpoint.appendingPathComponent(name)
            return (try? FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty) == true
        }
    }, "completed filesystem exchanges retained request, credential, or response files")
}

private func checkRelayShimUsesPinnedFilesystemTransport() throws {
    let directory = try temporaryDirectory()
    let fakeOpen = directory.appendingPathComponent("open-fixture")
    try """
    #!/bin/sh
    /usr/bin/printf '%s\\n' "$@" > "$PARLEY_OPEN_CAPTURE"
    """.write(to: fakeOpen, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOpen.path)
    let executable = try RelayShim.installCommand(in: directory, openExecutable: fakeOpen)
    let script = try String(contentsOf: executable, encoding: .utf8)
    try expect(!script.contains("/usr/bin/curl"), "relay shim still depends on a sandbox-blocked socket client")
    try expect(script.contains("Parley Native managed filesystem relay"), "relay shim does not use the managed filesystem transport")
    try expect(script.contains("request_id="), "relay shim does not correlate filesystem responses")
    try expect(script.contains("PARLEY_IDEMPOTENCY_KEY"), "relay shim sends no idempotency key")
    try expect(script.contains("parley open <folder>"), "managed parley command omitted its external workspace entry point")

    let folder = try temporaryDirectory()
    let capture = directory.appendingPathComponent("open-arguments")
    var externalEnvironment = ProcessInfo.processInfo.environment
    externalEnvironment.removeValue(forKey: "PARLEY_RELAY_TOKEN")
    externalEnvironment["PARLEY_OPEN_CAPTURE"] = capture.path
    let opened = try ProcessCommandRunner(timeout: 3).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable.path, "open", folder.path],
        environment: externalEnvironment,
        input: nil
    )
    try expect(opened.status == 0, "parley open failed: \(opened.stderrText)")
    let openArguments = try String(contentsOf: capture, encoding: .utf8)
        .split(whereSeparator: \.isNewline).map(String.init)
    try expect(
        openArguments == ["-b", ParleyRuntime.productionBundleIdentifier, canonicalPath(folder.path)],
        "parley open did not use the installed app and one canonical folder argument"
    )

    externalEnvironment["PARLEY_RELAY_TOKEN"] = String(repeating: "a", count: 48)
    try FileManager.default.removeItem(at: capture)
    let agentAttempt = try ProcessCommandRunner(timeout: 3).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable.path, "open", folder.path],
        environment: externalEnvironment,
        input: nil
    )
    try expect(
        agentAttempt.status != 0 && agentAttempt.stderrText.contains("person-only")
            && !FileManager.default.fileExists(atPath: capture.path),
        "an agent pane could invoke the person-only external workspace route"
    )
}

private func checkRelayFilesystemRuntimeIsProtectedAndStopsCleanly() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: runtime)
    try transport.start()
    let endpoint = RelayFileTransport.endpointDirectory(runtimeDirectory: runtime, paneToken: token)

    for path in [runtime, endpoint] + ["inbox", "processing", "outbox"].map({ endpoint.appendingPathComponent($0) }) {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        try expect(attributes[.type] as? FileAttributeType == .typeDirectory, "filesystem relay path is not a directory")
        try expect(attributes[.ownerAccountID] as? NSNumber == NSNumber(value: getuid()), "filesystem relay directory has the wrong owner")
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "filesystem relay directory is not owner-only")
    }
    let heartbeat = endpoint.appendingPathComponent("heartbeat")
    let heartbeatAttributes = try FileManager.default.attributesOfItem(atPath: heartbeat.path)
    try expect((heartbeatAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "filesystem relay heartbeat is not owner-only")
    transport.stop()
    try expect(!FileManager.default.fileExists(atPath: heartbeat.path), "stopped filesystem relay left a live heartbeat")

    let queuedResponse = endpoint
        .appendingPathComponent("outbox", isDirectory: true)
        .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: queuedResponse, withIntermediateDirectories: false)
    try transport.preserveExchangeFilesForNextStart()
    try transport.start()
    try expect(
        FileManager.default.fileExists(atPath: queuedResponse.path),
        "graceful core handover discarded a command response"
    )
    transport.stop()

    try transport.start()
    try expect(
        !FileManager.default.fileExists(atPath: queuedResponse.path),
        "ordinary core startup preserved an uncertain stale response"
    )
    transport.stop()

    let symlinkParent = try temporaryDirectory()
    let symlinkRuntime = symlinkParent.appendingPathComponent("runtime", isDirectory: true)
    let redirected = try temporaryDirectory()
    try FileManager.default.createSymbolicLink(at: symlinkRuntime, withDestinationURL: redirected)
    let redirectedTransport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: symlinkRuntime)
    do {
        try redirectedTransport.start()
        redirectedTransport.stop()
        throw CheckFailure(description: "filesystem relay accepted a symlinked runtime directory")
    } catch RelayFileTransportError.invalidRuntimeDirectory {
        // Expected: an agent cannot redirect the core through a symlink.
    }
}

private func checkLargeCoreActivityResponseIsComplete() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(credentials: credentials, panes: { panes }, paste: { _, _ in }, submit: { _, _ in })
    for index in 0..<40 {
        let body = "handoff-\(index)-" + String(repeating: "x", count: 4_096)
        let response = broker.handle(token: token, target: "codex", text: body, idempotencyKey: "large-response-\(index)")
        try expect(response.status == 200, "large-response fixture could not create a handoff")
    }

    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "large-response-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let handoffs = try client.handoffs(limit: 40)
    try expect(handoffs.count == 40, "large activity response was truncated")
    try expect(handoffs.allSatisfy { $0.text.count > 4_000 }, "large activity response lost handoff bodies")
}

private func checkCoreControlSurvivesClientReattachment() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let retryAttempts = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, text in
            guard text.contains("retry this delivery") else { return }
            retryAttempts.increment()
            if retryAttempts.value == 1 {
                throw ParleyTmuxError.unsafeRelayTarget("Agy")
            }
        },
        consultationTimeout: 3
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "fixture-control-token"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    _ = try server.start()
    defer { server.stop() }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleAsk(token: sourceToken, target: "agy", text: "Can a new UI finish this wait?"))
    }
    try expect(eventually { broker.consultations().count == 1 }, "coordination core did not retain the consultation")

    var attachedClient: RelayCoreClient? = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let attachedCount = try attachedClient?.consultations().count
    try expect(attachedCount == 1, "the first UI client could not inspect core state")
    let attachedHandoffs = try attachedClient?.handoffs()
    try expect(attachedHandoffs?.count == 1 && attachedHandoffs?.first?.state == .waiting, "the first UI client could not inspect handoff state")
    attachedClient = nil

    let reattachedClient = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let pending = try require(try reattachedClient.consultations().first, "a reattached UI lost the active consultation")
    let reattachedHandoff = try require(try reattachedClient.handoffs().first, "a reattached UI lost the active handoff")
    try expect(reattachedHandoff.id == pending.id, "consultation and handoff identities diverged after UI reattachment")
    let activity = try reattachedClient.recordActivity(RelayActivityEventRequest(
        kind: .paneRestarted,
        workspaceID: "@0",
        workspaceName: "fixture",
        paneID: "%2",
        paneName: "Agy",
        paneKind: .agy,
        detail: "Agy pane restarted."
    ))
    try expect(activity.origin == .human, "core activity route did not stamp human origin")
    let recentActivityIDs = try reattachedClient.activityEvents(limit: 1).map(\.id)
    try expect(recentActivityIDs == [activity.id], "reattached UI could not read operational activity")
    var unauthorizedActivityWasRejected = false
    do {
        _ = try RelayCoreClient(infoFile: infoFile, controlToken: "not-the-control-token").recordActivity(
            RelayActivityEventRequest(
                kind: .workspaceCreated,
                workspaceID: "@9",
                workspaceName: "forged"
            )
        )
    } catch RelayCoreError.response(401, _) {
        unauthorizedActivityWasRejected = true
    }
    try expect(unauthorizedActivityWasRejected, "an unauthenticated client recorded native operational activity")
    let returned = try reattachedClient.answerFromUI(
        consultationID: pending.id,
        text: "Yes; the wait belongs to the core."
    )
    try expect(returned.status == 200, "the reattached UI could not complete the consultation")
    try expect(eventually { askResult.value != nil }, "the waiting Ask stayed blocked after UI reattachment")
    try expect(askResult.value?.text == "Yes; the wait belongs to the core.", "the core returned the wrong answer")
    let unread = try require(
        try reattachedClient.handoffs().first(where: { $0.id == pending.id }),
        "the completed Ask disappeared before its result could be viewed"
    )
    try expect(unread.hasUnreadResult && unread.readAt == nil, "a newly returned Ask result was not unread")
    try expect(unread.transitions.suffix(2).allSatisfy { $0.origin == .human }, "manual UI return was not recorded as human intervention")
    let unreadHandoffs = try reattachedClient.unreadHandoffs()
    try expect(unreadHandoffs.map(\.id) == [pending.id], "the unread endpoint omitted the returned Ask")
    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "not-the-control-token")
    let unauthorizedRead = try unauthorized.markHandoffRead(pending.id)
    try expect(unauthorizedRead.status == 401, "an unauthenticated UI marked a result read")
    let stillUnread = try reattachedClient.handoffs().first(where: { $0.id == pending.id })?.hasUnreadResult
    try expect(
        stillUnread == true,
        "the rejected acknowledgement changed the read receipt"
    )
    let firstRead = try reattachedClient.markHandoffRead(pending.id)
    try expect(firstRead.status == 200, "the authenticated UI could not acknowledge a result")
    let repeatedRead = try reattachedClient.markHandoffRead(pending.id)
    try expect(repeatedRead.status == 200, "read acknowledgement was not idempotent")
    let acknowledged = try require(
        try reattachedClient.handoffs().first(where: { $0.id == pending.id }),
        "the acknowledged Ask disappeared"
    )
    try expect(!acknowledged.hasUnreadResult && acknowledged.readAt != nil, "the durable handoff did not record that its result was viewed")
    let remainingUnread = try reattachedClient.unreadHandoffs()
    try expect(remainingUnread.isEmpty, "the unread endpoint retained an acknowledged result")

    let cancelledAskResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        cancelledAskResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Can the reattached UI cancel this wait?",
            idempotencyKey: "ui-cancel-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "the cancellable UI Ask never started")
    let cancellable = try require(try reattachedClient.consultations().first, "the UI could not inspect the cancellable Ask")
    let cancelled = try reattachedClient.cancelHandoff(cancellable.id)
    try expect(cancelled.status == 200, "the authenticated UI could not cancel the Ask")
    try expect(eventually { cancelledAskResult.value != nil }, "UI cancellation left the requester blocked")
    try expect(cancelledAskResult.value?.status == 409, "UI cancellation returned the wrong result to the requester")
    let cancelledHandoff = try require(
        try reattachedClient.handoffs().first(where: { $0.id == cancellable.id }),
        "the cancelled UI handoff disappeared"
    )
    try expect(cancelledHandoff.state == .cancelled, "the UI cancellation did not record a cancelled handoff")
    let recent = try reattachedClient.handoffs(limit: 1)
    try expect(recent.count == 1 && recent.first?.id == cancellable.id, "the activity client did not receive only the newest handoff")

    let failedRelay = broker.handle(
        token: sourceToken,
        target: "agy",
        text: "retry this delivery",
        idempotencyKey: "ui-retry-relay-1"
    )
    let failedRelayID = try require(failedRelay.body.handoffID, "UI retry fixture returned no handoff id")
    let retriedRelay = try reattachedClient.retryHandoff(failedRelayID)
    try expect(retriedRelay.status == 200, "the authenticated UI could not retry a safe failed delivery")
    let retriedHandoff = try require(
        try reattachedClient.handoffs().first(where: { $0.id == failedRelayID }),
        "UI-retried handoff disappeared"
    )
    try expect(retriedHandoff.state == .completed, "UI retry did not complete the original handoff")
    try expect(retryAttempts.value == 2, "UI retry did not run exactly one additional delivery attempt")

    let unauthorizedDeletion = try unauthorized.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: nil)
    try expect(unauthorizedDeletion.status == 401, "an unauthenticated UI deleted workspace history")
    let historyAfterRejectedDeletion = try reattachedClient.handoffs()
    try expect(!historyAfterRejectedDeletion.isEmpty, "rejected workspace deletion changed history")
    let deletion = try reattachedClient.deleteWorkspaceHistory(workspaceID: "@0", workspaceName: nil)
    try expect(deletion.status == 200, "the authenticated UI could not delete workspace history")
    let historyAfterDeletion = try reattachedClient.handoffs()
    try expect(historyAfterDeletion.isEmpty, "workspace deletion route retained terminal history")
    let activityAfterDeletion = try reattachedClient.activityEvents()
    try expect(activityAfterDeletion.isEmpty, "workspace deletion route retained operational activity")
}

private func checkPersistentCoreProcessSurvivesClientExit() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let shimDirectory = try RelayShim.install(in: directory)
    let infoFile = directory.appendingPathComponent("relay-url")
    let uiEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_UI_FIXTURE": "1",
    ]) { _, supplied in supplied }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

    let ui = try ProcessCommandRunner(timeout: 5).run(
        executable: executable,
        arguments: ["--application-directory", directory.path, "--cwd", "/tmp"],
        environment: uiEnvironment,
        input: nil
    )
    try expect(ui.status == 0, "the fixture UI could not launch the core: \(ui.stderrText)")
    let logAttributes = try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("core.log").path
    )
    let logMode = (logAttributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(logMode & 0o777 == 0o600, "core log was not owner-only")
    let pidFile = directory.appendingPathComponent("core.pid")
    defer {
        if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1 {
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let reattachedClient = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(reattachedClient.isHealthy(), "the core exited when its launching UI process exited")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "Will this wait survive UI exit?"],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_INFO": infoFile.path,
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(
        eventually(timeout: 3) { (try? reattachedClient.consultations().count) == 1 },
        "the separate core process did not retain the blocking Ask"
    )
    let pending = try require(try reattachedClient.consultations().first, "the new UI client lost the wait")
    let answer = try reattachedClient.answerFromUI(
        consultationID: pending.id,
        text: "Yes. The service owns the wait."
    )
    try expect(answer.status == 200, "the reattached UI could not answer through the core")
    try expect(eventually(timeout: 3) { askResult.value != nil }, "the separate core left Ask blocked")
    try expect(askResult.value?.status == 0, "the Ask command failed after UI reattachment")
    try expect(askResult.value?.text == "Yes. The service owns the wait.", "the reattached answer was changed")
}

private func checkCoreRestartInterruptsWaitAndRecoversDiscovery() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let shimDirectory = try RelayShim.install(in: directory)
    let infoFile = directory.appendingPathComponent("relay-url")
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let uiEnvironment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_UI_FIXTURE": "1",
    ]) { _, supplied in supplied }

    func launchUI() throws {
        let output = try ProcessCommandRunner(timeout: 5).run(
            executable: executable,
            arguments: ["--application-directory", directory.path, "--cwd", "/tmp"],
            environment: uiEnvironment,
            input: nil
        )
        try expect(output.status == 0, "fixture UI could not start the core: \(output.stderrText)")
    }

    func servicePID() throws -> Int32 {
        let raw = try String(contentsOf: directory.appendingPathComponent("core.pid"), encoding: .utf8)
        guard let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw CheckFailure(description: "fixture core wrote an invalid pid")
        }
        return pid
    }

    try launchUI()
    var activePID = try servicePID()
    defer { _ = Darwin.kill(activePID, SIGTERM) }
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    var client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(
        eventually(timeout: 3) { client.isHealthy() },
        "fixture core did not remain healthy after its launching UI exited"
    )

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 6).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "Will restart strand this wait?"],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_INFO": infoFile.path,
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            let detail = [output.stdoutText, output.stderrText].filter { !$0.isEmpty }.joined(separator: "\n")
            askResult.set(RelayTextResponse(status: Int(output.status), text: detail))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    try expect(
        eventually(timeout: 3) { (try? client.consultations().count) == 1 },
        "restart check never established its blocking Ask"
    )

    try expect(Darwin.kill(activePID, SIGTERM) == 0, "could not stop the fixture core")
    try expect(eventually(timeout: 3) { askResult.value != nil }, "core restart left the Ask command hanging")
    try expect(askResult.value?.status != 0, "core restart pretended the interrupted Ask succeeded")
    try expect(
        askResult.value?.text.localizedCaseInsensitiveContains("stopped before the consultation completed") == true,
        "core restart did not return an explicit interruption reason: \(askResult.value?.text ?? "no response")"
    )
    try expect(eventually(timeout: 3) { !client.isHealthy() }, "stopped core still reported healthy")

    try launchUI()
    activePID = try servicePID()
    client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    try expect(
        eventually(timeout: 3) { client.isHealthy() },
        "a new UI could not restart the core"
    )
    let restartedConsultations = try client.consultations()
    try expect(restartedConsultations.isEmpty, "the restarted core revived an impossible stale wait")
}

private func runUIFixture() throws {
    guard let rawDirectory = argument(named: "--application-directory") else {
        throw CheckFailure(description: "fixture UI needs an application directory")
    }
    var coreEnvironment = ProcessInfo.processInfo.environment
    coreEnvironment.removeValue(forKey: "PARLEY_UI_FIXTURE")
    coreEnvironment["PARLEY_CORE_FIXTURE"] = "1"
    _ = try RelayCoreLauncher.ensureRunning(
        applicationDirectory: URL(fileURLWithPath: rawDirectory, isDirectory: true),
        cwd: argument(named: "--cwd") ?? "/tmp",
        environment: coreEnvironment,
        executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        timeout: 3
    )
}

@MainActor
private func runCoreServiceFixture() throws {
    // The launcher returns as soon as the health endpoint responds, after
    // which its short-lived fixture UI exits. Ignore its parent-exit signal
    // before opening that endpoint so readiness cannot be observed inside a
    // small SIGHUP race.
    signal(SIGHUP, SIG_IGN)
    guard let rawDirectory = argument(named: "--application-directory") else {
        throw CheckFailure(description: "fixture core needs an application directory")
    }
    let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 10
    )
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken,
        identity: ProcessInfo.processInfo.environment["PARLEY_CORE_FIXTURE_BUILD"].map {
            CoreServiceIdentity(
                contractVersion: CoreServiceIdentity.currentContractVersion,
                applicationVersion: "fixture",
                build: $0
            )
        } ?? .resolve(infoDictionary: nil),
        shutdownRequested: { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                _ = Darwin.kill(ProcessInfo.processInfo.processIdentifier, SIGTERM)
            }
        }
    )
    try server.start()
    let agentTransport = RelayFileTransport(
        broker: broker,
        credentials: credentials,
        runtimeDirectory: RelayFileTransport.runtimeDirectory(applicationDirectory: directory)
    )
    try agentTransport.start()
    let pidFile = directory.appendingPathComponent("core.pid")
    try String(ProcessInfo.processInfo.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)

    RelayServiceProcess.waitForTermination { _ in
        server.stop()
        agentTransport.stop()
        try? FileManager.default.removeItem(at: pidFile)
    }
}

private func checkStableRouterSelectsRuntimeAndPreservesForeignCommands() throws {
    let directory = try temporaryDirectory()
    let productionCommand = directory.appendingPathComponent("production-parley")
    let developmentCommand = directory.appendingPathComponent("development-parley")
    for (command, result) in [(productionCommand, "production"), (developmentCommand, "development")] {
        try "#!/bin/sh\nprintf '%s' '\(result)'\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    }

    // A production upgrade replaces Parley's old runtime-pinned managed shim
    // with one neutral router. A foreign command is still never overwritten.
    _ = try RelayShim.installCommand(in: directory)
    let executable = try RelayShim.installStableRouter(
        in: directory,
        productionCommand: productionCommand,
        developmentCommand: developmentCommand
    )
    let installed = try String(contentsOf: executable, encoding: .utf8)
    try expect(installed.contains("Parley Native managed relay router"), "stable relay command was not recognisably managed")

    let runner = ProcessCommandRunner(timeout: 2)
    let production = try runner.run(executable: executable, arguments: [], environment: [:], input: nil)
    let development = try runner.run(
        executable: executable,
        arguments: [],
        environment: ["PARLEY_RUNTIME": "DEV"],
        input: nil
    )
    let attached = try runner.run(
        executable: executable,
        arguments: [],
        environment: ["PARLEY_RUNTIME": "DEV ATTACHED TO PRODUCTION"],
        input: nil
    )
    try expect(production.status == 0 && production.stdoutText == "production", "stable relay router did not default to Production")
    try expect(development.status == 0 && development.stdoutText == "development", "stable relay router did not select Development")
    try expect(attached.status == 0 && attached.stdoutText == "production", "attached Development did not remain on Production")

    let foreign = "#!/bin/sh\necho foreign\n"
    try foreign.write(to: executable, atomically: true, encoding: .utf8)
    do {
        _ = try RelayShim.installStableRouter(
            in: directory,
            productionCommand: productionCommand,
            developmentCommand: developmentCommand
        )
        throw CheckFailure(description: "stable shim overwrote a foreign parley command")
    } catch RelayShimError.commandCollision {
        // Expected: a command Parley does not own is never replaced.
    }
    let preserved = try String(contentsOf: executable, encoding: .utf8)
    try expect(preserved == foreign, "foreign parley command was changed")
}

private func checkAgentAskSubmitsAndBlocksUntilTheTargetAnswers() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let wrongToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submitted = LockedDelivery()
    let submissionCount = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in
            submissionCount.increment()
            submitted.set(paneID: paneID, text: prompt, submit: true)
        },
        consultationTimeout: 2
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Which board representation should the plan use?",
            idempotencyKey: "ask-board-1"
        ))
    }

    try expect(eventually { submitted.value != nil }, "agent Ask did not automatically submit the question")
    try expect(result.value == nil, "agent Ask returned before the target answered")
    let pending = try require(broker.consultations().first, "active consultation disappeared")
    try expect(pending.state == .awaitingAnswer, "automatic Ask did not wait for an answer")
    try expect(pending.sourcePaneID == "%1" && pending.targetPaneID == "%2", "consultation lost its route")
    try expect(submitted.value?.paneID == "%2" && submitted.value?.submit == true, "automatic Ask submitted to the wrong pane")
    try expect(submitted.value?.text.contains("Planner asked:") == true, "automatic Ask omitted source attribution")
    try expect(submitted.value?.text.contains("parley answer current") == true, "target was not given the pane-correlated answer command")
    try expect(submitted.value?.text.contains(pending.id) == false, "target was asked to copy a fragile consultation UUID")
    let waitingHandoff = try require(broker.handoffs().first(where: { $0.id == pending.id }), "Ask created no observable handoff")
    try expect(waitingHandoff.idempotencyKey == "ask-board-1", "Ask handoff lost its idempotency key")
    try expect(waitingHandoff.kind == .ask && waitingHandoff.state == .waiting, "Ask handoff did not enter waiting state")
    try expect(
        waitingHandoff.transitions.map(\.state) == [.created, .delivered, .waiting],
        "Ask handoff recorded the wrong pre-answer state trail"
    )

    let concurrentRetry = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        concurrentRetry.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Which board representation should the plan use?",
            idempotencyKey: "ask-board-1"
        ))
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(concurrentRetry.value == nil, "concurrent idempotent Ask retry returned before the answer")
    try expect(submissionCount.value == 1, "concurrent idempotent Ask retry submitted the question twice")

    let refused = broker.handleAnswer(token: wrongToken, consultationID: "current", text: "I should not be accepted")
    try expect(refused.status == 404, "a different pane resolved somebody else's current consultation")
    try expect(result.value == nil, "a refused answer unblocked the requester")

    let accepted = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Use a flat seven-column array.")
    try expect(accepted.status == 200, "the target pane's answer was refused")
    try expect(eventually { result.value != nil }, "the correlated answer did not unblock agent Ask")
    try expect(eventually { concurrentRetry.value != nil }, "the correlated answer did not unblock the idempotent Ask retry")
    try expect(result.value?.status == 200, "completed agent Ask returned an error")
    try expect(result.value?.text == "Use a flat seven-column array.", "agent Ask did not return the exact answer as command output")
    try expect(concurrentRetry.value == result.value, "concurrent idempotent Ask retry received a different result")
    try expect(broker.consultations().isEmpty, "completed consultation remained in the UI queue")
    let completedHandoff = try require(broker.handoffs().first(where: { $0.id == pending.id }), "completed Ask handoff disappeared")
    try expect(completedHandoff.state == .completed, "answered Ask did not reach completed state")
    try expect(
        completedHandoff.transitions.map(\.state) == [.created, .delivered, .waiting, .answered, .completed],
        "answered Ask lost its lifecycle trail"
    )

    let duplicate = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "Which board representation should the plan use?",
        idempotencyKey: "ask-board-1"
    )
    try expect(duplicate.status == 200 && duplicate.text == result.value?.text, "idempotent Ask retry did not return the original answer")
    try expect(submissionCount.value == 1, "idempotent Ask retry submitted the question twice")

    let conflict = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "A different question cannot reuse this key.",
        idempotencyKey: "ask-board-1"
    )
    try expect(conflict.status == 409, "Ask accepted conflicting reuse of an idempotency key")
    try expect(submissionCount.value == 1, "conflicting Ask reuse submitted another question")
}

private func checkAskManyFansOutIndependentlyAndReturnsAnOrderedBundle() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAskMany(
            token: sourceToken,
            targets: "codex,agy",
            text: "Name the first risk you would investigate.",
            idempotencyKey: "ask-many-audit-1"
        ))
    }

    try expect(eventually { broker.consultations().count == 2 }, "ask-many did not establish both consultations concurrently")
    try expect(result.value == nil, "ask-many returned before every target answered")
    try expect(Set(submissions.values.map(\.paneID)) == Set(["%2", "%3"]), "ask-many did not submit exactly once to every explicit target")
    for submission in submissions.values {
        try expect(submission.text.contains("Name the first risk you would investigate."), "ask-many changed the shared question")
        try expect(!submission.text.contains("Codex answer") && !submission.text.contains("Agy answer"), "ask-many leaked one target's answer into another target's prompt")
    }

    let codexAnswer = broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex answer")
    try expect(codexAnswer.status == 200, "Codex could not answer its ask-many consultation")
    Thread.sleep(forTimeInterval: 0.03)
    try expect(result.value == nil, "ask-many returned before the second target answered")
    let agyAnswer = broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy answer")
    try expect(agyAnswer.status == 200, "Agy could not answer its ask-many consultation")
    try expect(eventually { result.value != nil }, "ask-many stayed blocked after every target answered")

    let completed = try require(result.value, "ask-many produced no response")
    try expect(completed.status == 200, "successful ask-many returned a failure status")
    let data = try require(completed.text.data(using: .utf8), "ask-many response was not UTF-8")
    let json = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "ask-many response was not a JSON object")
    try expect(json["ok"] as? Bool == true, "ask-many bundle did not report success")
    let answers = try require(json["answers"] as? [[String: Any]], "ask-many bundle omitted its answers")
    try expect(answers.count == 2, "ask-many bundle returned the wrong answer count")
    try expect(answers[0]["requestedTarget"] as? String == "codex", "ask-many lost requested target ordering")
    try expect(answers[0]["targetPaneID"] as? String == "%2", "ask-many resolved Codex to the wrong pane")
    try expect(answers[0]["handoffID"] as? String != nil, "ask-many omitted Codex's durable handoff identity")
    try expect(answers[0]["answer"] as? String == "Codex answer", "ask-many lost Codex's exact answer")
    try expect(answers[1]["requestedTarget"] as? String == "agy", "ask-many lost the second requested target")
    try expect(answers[1]["targetPaneID"] as? String == "%3", "ask-many resolved Agy to the wrong pane")
    try expect(answers[1]["handoffID"] as? String != nil, "ask-many omitted Agy's durable handoff identity")
    try expect(answers[1]["answer"] as? String == "Agy answer", "ask-many lost Agy's exact answer")

    let retry = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,agy",
        text: "Name the first risk you would investigate.",
        idempotencyKey: "ask-many-audit-1"
    )
    try expect(retry == completed, "idempotent ask-many retry changed the ordered bundle")
    try expect(submissions.values.count == 2, "idempotent ask-many retry resubmitted a question")

    let invalid = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,missing",
        text: "This must not partially dispatch.",
        idempotencyKey: "ask-many-invalid-1"
    )
    try expect(invalid.status == 400 && invalid.text.contains("missing"), "ask-many did not reject an unresolved target")
    try expect(submissions.values.count == 2, "ask-many partially dispatched before validating every target")

    let duplicate = broker.handleAskMany(
        token: sourceToken,
        targets: "codex,%2",
        text: "This target appears twice.",
        idempotencyKey: "ask-many-duplicate-1"
    )
    try expect(duplicate.status == 400 && duplicate.text.contains("more than once"), "ask-many accepted two names for the same pane")
    try expect(submissions.values.count == 2, "duplicate ask-many target caused a dispatch")

    let failingBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, _ in
            if paneID == "%2" { throw CheckFailure(description: "Codex input unavailable") }
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let partialResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        partialResult.set(failingBroker.handleAskMany(
            token: sourceToken,
            targets: "codex,agy",
            text: "Preserve successful peer answers.",
            idempotencyKey: "ask-many-partial-1"
        ))
    }
    try expect(eventually { failingBroker.consultations().count == 1 }, "ask-many did not preserve the successful consultation after a peer dispatch failed")
    try expect(failingBroker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy survived").status == 200, "surviving ask-many target could not answer")
    try expect(eventually { partialResult.value != nil }, "partially failed ask-many stayed blocked")
    let partial = try require(partialResult.value, "partially failed ask-many produced no bundle")
    try expect(partial.status == 409, "partially failed ask-many did not exit non-zero")
    let partialData = try require(partial.text.data(using: .utf8), "partial ask-many response was not UTF-8")
    let partialJSON = try require(try JSONSerialization.jsonObject(with: partialData) as? [String: Any], "partial ask-many response was not JSON")
    try expect(partialJSON["ok"] as? Bool == false, "partial ask-many bundle claimed success")
    let partialAnswers = try require(partialJSON["answers"] as? [[String: Any]], "partial ask-many bundle omitted its results")
    try expect(partialAnswers[0]["status"] as? Int == 409 && partialAnswers[0]["error"] as? String != nil, "partial ask-many bundle hid the failed first target")
    try expect(partialAnswers[1]["answer"] as? String == "Agy survived", "partial ask-many bundle lost the successful second answer")
}

private func checkAskManyComparisonDraftPreservesIndependentAttribution() throws {
    let answers = [
        RelayAskManyAnswer(
            requestedTarget: "codex",
            targetPaneID: "%2",
            targetName: "Security reviewer",
            status: 200,
            answer: "Validate the trust boundary first.",
            error: nil
        ),
        RelayAskManyAnswer(
            requestedTarget: "agy",
            targetPaneID: "%3",
            targetName: "Product reviewer",
            status: 200,
            answer: "Test whether the workflow is understandable first.",
            error: nil
        ),
        RelayAskManyAnswer(
            requestedTarget: "copilot",
            targetPaneID: "%4",
            targetName: "Implementation reviewer",
            status: 409,
            answer: nil,
            error: "The pane was unavailable."
        ),
    ]

    let one = try AskManyComparisonDraft.forwardingText(
        question: "What should we validate first?",
        answers: answers,
        selectedTargetPaneIDs: ["%3"]
    )
    try expect(one.contains("Product reviewer answered independently:"), "a single forwarded answer lost its source attribution")
    try expect(one.contains("Test whether the workflow is understandable first."), "a single forwarded answer lost its exact text")
    try expect(!one.contains("Security reviewer"), "a single-answer draft included an unselected peer")

    let several = try AskManyComparisonDraft.forwardingText(
        question: "What should we validate first?",
        answers: answers,
        selectedTargetPaneIDs: ["%2", "%3"]
    )
    let securityRange = try require(several.range(of: "Security reviewer answered independently:"), "the first selected answer lost attribution")
    let productRange = try require(several.range(of: "Product reviewer answered independently:"), "the second selected answer lost attribution")
    try expect(securityRange.lowerBound < productRange.lowerBound, "comparison forwarding changed the original independent answer order")
    try expect(!several.localizedCaseInsensitiveContains("consensus"), "comparison forwarding manufactured a consensus label")
    try expect(!several.contains("The pane was unavailable."), "comparison forwarding presented a failure as an answer")

    let synthesis = try AskManyComparisonDraft.synthesisText(
        question: "What should we validate first?",
        answers: answers
    )
    try expect(synthesis.contains("Write an edited synthesis below. The attributed answers above remain unchanged."), "the synthesis draft did not preserve an explicit human editing boundary")
    try expect(synthesis.hasSuffix("Synthesis:\n"), "the synthesis draft pre-filled a manufactured conclusion")

    do {
        _ = try AskManyComparisonDraft.forwardingText(
            question: "What should we validate first?",
            answers: answers,
            selectedTargetPaneIDs: ["%4"]
        )
        throw CheckFailure(description: "a failed comparison result was forwarded as an answer")
    } catch AskManyComparisonDraftError.noSuccessfulAnswers {
        // Expected: failures stay visible in the comparison but are not answers.
    }
}

private func checkHumanAskManyUsesTheTrackedBrokerPath() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    _ = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil, automationPolicy: .off),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAskManyFromUI(
            sourcePaneID: "%1",
            targetPaneIDs: ["%2", "%3"],
            text: "Which risk should the person inspect first?",
            idempotencyKey: "human-compare-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 2 }, "the native comparison did not create two tracked consultations")
    try expect(Set(submissions.values.map(\.paneID)) == Set(["%2", "%3"]), "the native comparison did not submit to exactly the selected panes")
    try expect(broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex answer").status == 200, "Codex could not answer the native comparison")
    try expect(broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy answer").status == 200, "Agy could not answer the native comparison")
    try expect(eventually { result.value != nil }, "the native comparison stayed blocked after both answers")
    let completed = try require(result.value, "the native comparison produced no bundle")
    try expect(completed.status == 200, "the native comparison returned a failure status")
    let bundle = try JSONDecoder().decode(RelayAskManyBundle.self, from: Data(completed.text.utf8))
    try expect(bundle.answers.map(\.targetPaneID) == ["%2", "%3"], "the native comparison changed selected-pane order")

    let invalid = broker.handleAskManyFromUI(
        sourcePaneID: "%404",
        targetPaneIDs: ["%2", "%3"],
        text: "This must not dispatch.",
        idempotencyKey: "human-compare-invalid"
    )
    try expect(invalid.status == 400 && invalid.text.contains("source"), "the native comparison accepted an unknown source pane")
    try expect(submissions.values.count == 2, "an invalid native comparison partially dispatched")

    _ = try credentials.token(for: "%4")
    let sameVendorSubmissions = LockedSubmissions()
    let sameVendorBroker = RelayBroker(
        credentials: credentials,
        panes: {
            panes + [
                TmuxPane(id: "%4", kind: .codex, customName: "Codex Two", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
            ]
        },
        paste: { _, _ in },
        submit: { paneID, prompt in sameVendorSubmissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 0.05,
        livenessPollInterval: 0.01
    )
    let sameVendor = sameVendorBroker.handleAskManyFromUI(
        sourcePaneID: "%1",
        targetPaneIDs: ["%2", "%4"],
        text: "This must remain a cross-vendor comparison.",
        idempotencyKey: "human-compare-same-vendor"
    )
    try expect(
        sameVendor.status == 400 && sameVendor.text.contains("different vendors"),
        "the native comparison accepted two panes from the same target vendor"
    )
    try expect(sameVendorSubmissions.values.isEmpty, "a same-vendor comparison submitted terminal input")
}

private func checkHumanAskManyCoreControlRoute() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    _ = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil, automationPolicy: .off),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedSubmissions()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, prompt in submissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "ask-many-ui-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }

    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")
    do {
        _ = try unauthorized.askManyFromUI(
            sourcePaneID: "%1",
            targetPaneIDs: ["%2", "%3"],
            text: "This must not dispatch.",
            idempotencyKey: "ui-compare-unauthorized"
        )
        throw CheckFailure(description: "an unauthenticated UI started an Ask-many comparison")
    } catch RelayCoreError.response(401, _) {
        // Expected.
    }
    try expect(submissions.values.isEmpty, "the rejected UI comparison submitted terminal input")

    let client = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let result = LockedAskManyUIResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            result.set(try client.askManyFromUI(
                sourcePaneID: "%1",
                targetPaneIDs: ["%2", "%3"],
                text: "Compare exactly:\n\n    indented evidence\n\n\n┌diagram┐",
                idempotencyKey: "ui-compare-authorized",
                preserveFormatting: true
            ))
        } catch {
            result.set(error: error)
        }
    }
    try expect(eventually { broker.consultations().count == 2 }, "the authenticated UI route did not reach both targets")
    try expect(submissions.values.allSatisfy {
        $0.text.contains("    indented evidence") && $0.text.contains("evidence\n\n\n┌diagram┐")
    }, "the formatted native comparison damaged explicit context before submission")
    try expect(broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex result").status == 200, "Codex could not answer the UI route")
    try expect(broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy result").status == 200, "Agy could not answer the UI route")
    try expect(eventually { result.value != nil || result.error != nil }, "the UI route did not complete")
    try expect(result.error == nil, "the UI route failed: \(result.error ?? "unknown")")
    let response = try require(result.value, "the UI route produced no comparison response")
    try expect(response.status == 200 && response.bundle.ok, "the UI route did not preserve the successful bundle")
    try expect(response.bundle.answers.map(\.answer) == ["Codex result", "Agy result"], "the UI route changed the independent answer order or text")
}

private func checkAgentAskRejectsBusyTargetAndTimesOut() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(
            token: token,
            target: "agy",
            text: "Should this plan use minimax?",
            idempotencyKey: "busy-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "busy-target check never started its consultation")
    let interruptedID = try require(broker.consultations().first?.id, "busy-target consultation had no id")
    let busy = broker.handleAsk(token: token, target: "agy", text: "Can I interrupt the first question?")
    try expect(busy.status == 409 && busy.text.contains("already has a consultation"), "a second Ask interrupted a target already answering")
    broker.cancelAll(reason: "Busy-target check complete.")
    try expect(eventually { result.value != nil }, "cancelling the check left the source agent blocked")
    let interrupted = try require(broker.handoffs().first(where: { $0.id == interruptedID }), "interrupted Ask handoff disappeared")
    try expect(interrupted.state == .interrupted, "broker shutdown did not mark the Ask interrupted")
    try expect(interrupted.transitions.last?.detail == "Busy-target check complete.", "interrupted Ask lost its reason")

    let timeoutBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 0.05
    )
    let timedOut = timeoutBroker.handleAsk(
        token: token,
        target: "agy",
        text: "This should expire.",
        idempotencyKey: "timeout-ask-1"
    )
    try expect(timedOut.status == 408, "unanswered agent Ask did not time out")
    try expect(timeoutBroker.consultations().isEmpty, "expired consultation remained in the UI queue")
    let expired = try require(timeoutBroker.handoffs().first, "expired Ask produced no handoff record")
    try expect(expired.state == .failed, "expired Ask did not enter failed state")
    try expect(expired.transitions.last?.detail?.contains("timed out") == true, "expired Ask lost its timeout reason")
}

private func checkReviewedBusyQueueRequiresExplicitHumanSend() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = TmuxPane(
        id: "%1", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp/app",
        currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
        bracketedPasteActive: true, isStarted: true
    )
    let target = TmuxPane(
        id: "%2", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/app",
        currentCommand: "claude", isActive: false, windowID: "@0", returnToPaneID: nil,
        relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
        bracketedPasteActive: true, isStarted: true
    )
    let submissions = LockedCounter()
    let storeFile = directory.appendingPathComponent("reviewed-busy-drafts.json")
    let store = try ReviewedBusyDraftStore(file: storeFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() },
        consultationTimeout: 10,
        livenessPollInterval: 0.01,
        busyDraftStore: store
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: target.id,
        text: "Finish the current implementation.",
        idempotencyKey: "busy-queue-fixture"
    )
    let delegationID = try require(delegated.body.handoffID, "busy-queue fixture produced no delegation")
    try expect(submissions.value == 1, "busy-queue fixture did not submit its initial work")

    let queued = broker.enqueueReviewedBusyAskFromUI(ReviewedBusyDraftCreateRequest(
        sourcePaneID: source.id,
        targetPaneID: target.id,
        text: "Review the finished implementation.\nPreserve this second line.",
        preserveFormatting: true
    ))
    try expect(queued.status == 201, "a reviewed draft could not be queued behind active work")
    let draft = try JSONDecoder().decode(ReviewedBusyDraft.self, from: Data(queued.text.utf8))
    try expect(draft.state == .queued && draft.origin == .human, "the busy draft was not visibly human-reviewed and unsent")
    try expect(submissions.value == 1, "queueing a reviewed draft submitted terminal input")
    try expect(broker.reviewedBusyDrafts().map(\.id) == [draft.id], "the core did not expose the queued draft")

    let reloaded = try ReviewedBusyDraftStore(file: storeFile).drafts()
    try expect(reloaded == [draft], "the reviewed busy queue did not survive UI/core store reattachment")
    let mode = (try FileManager.default.attributesOfItem(atPath: storeFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    try expect(mode & 0o077 == 0, "the reviewed busy queue was readable outside its owner")

    let failedWriteFile = directory.appendingPathComponent("failed-write-busy-drafts.json")
    let failedWriteStore = try ReviewedBusyDraftStore(file: failedWriteFile)
    let failedWriteDraft = ReviewedBusyDraft(
        id: "failed-write-draft",
        sourcePaneID: source.id,
        sourceName: source.displayName,
        sourceKind: source.kind,
        sourceWorkspaceID: source.windowID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.windowID,
        targetWorkspaceName: target.workspaceName,
        text: "Remain visible if a durable discard fails.",
        preserveFormatting: false
    )
    try failedWriteStore.record(failedWriteDraft)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: failedWriteFile.path)
    do {
        try failedWriteStore.remove(id: failedWriteDraft.id)
        throw CheckFailure(description: "an unsafe queue file accepted a supposedly durable discard")
    } catch ReviewedBusyDraftStoreError.unreadable {
        // Expected: reject the write before claiming the draft was discarded.
    }
    try expect(
        failedWriteStore.draft(id: failedWriteDraft.id) == failedWriteDraft,
        "a failed durable discard hid the draft from the live Status Center"
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: failedWriteFile.path)

    let uncertainFile = directory.appendingPathComponent("uncertain-busy-drafts.json")
    let uncertainStore = try ReviewedBusyDraftStore(file: uncertainFile)
    try uncertainStore.record(ReviewedBusyDraft(
        sourcePaneID: source.id,
        sourceName: source.displayName,
        sourceKind: source.kind,
        sourceWorkspaceID: source.windowID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.windowID,
        targetWorkspaceName: target.workspaceName,
        text: "An explicit send crossed the persistence boundary.",
        preserveFormatting: false,
        state: .dispatching,
        detail: "A person explicitly chose Review and Send."
    ))
    let uncertainReload = try ReviewedBusyDraftStore(file: uncertainFile).drafts()
    try expect(
        uncertainReload.first?.state == .dispatching,
        "a restart changed an uncertain explicit send back into a safely resendable queue item"
    )

    let boundedStore = try ReviewedBusyDraftStore(
        file: directory.appendingPathComponent("bounded-busy-drafts.json")
    )
    for index in 0..<ReviewedBusyDraftStore.maximumDrafts {
        try boundedStore.record(ReviewedBusyDraft(
            id: "bounded-\(index)",
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            sourceWorkspaceID: source.windowID,
            sourceWorkspaceName: source.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.windowID,
            targetWorkspaceName: target.workspaceName,
            text: "Bounded draft \(index)",
            preserveFormatting: false
        ))
    }
    do {
        try boundedStore.record(ReviewedBusyDraft(
            id: "bounded-overflow",
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            sourceWorkspaceID: source.windowID,
            sourceWorkspaceName: source.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.windowID,
            targetWorkspaceName: target.workspaceName,
            text: "This draft must be refused.",
            preserveFormatting: false
        ))
        throw CheckFailure(description: "the reviewed busy queue exceeded its explicit bound")
    } catch ReviewedBusyDraftStoreError.tooMany {
        // Expected: no oldest-draft eviction and no invisible loss.
    }

    let raceStore = try ReviewedBusyDraftStore(
        file: directory.appendingPathComponent("racing-busy-drafts.json")
    )
    let raceDraft = ReviewedBusyDraft(
        id: "explicit-send-race",
        sourcePaneID: source.id,
        sourceName: source.displayName,
        sourceKind: source.kind,
        sourceWorkspaceID: source.windowID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.windowID,
        targetWorkspaceName: target.workspaceName,
        text: "Do not let discard race this explicit send.",
        preserveFormatting: false
    )
    try raceStore.record(raceDraft)
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let raceBroker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, _ in },
        submit: { _, _ in
            writerEntered.signal()
            _ = releaseWriter.wait(timeout: .now() + 2)
        },
        consultationTimeout: 10,
        livenessPollInterval: 0.01,
        busyDraftStore: raceStore
    )
    let raceResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        raceResult.set(raceBroker.sendReviewedBusyAskFromUI(ReviewedBusyDraftSendRequest(
            draftID: raceDraft.id,
            expectedUpdatedAt: raceDraft.updatedAt,
            text: raceDraft.text
        )))
    }
    try expect(
        writerEntered.wait(timeout: .now() + 1) == .success,
        "explicit-send race never reached its terminal writer"
    )
    let racedDiscard = raceBroker.cancelReviewedBusyDraftFromUI(raceDraft.id)
    try expect(
        racedDiscard.status == 409,
        "discard claimed success while an explicit terminal send was in progress"
    )
    releaseWriter.signal()
    try expect(eventually { raceBroker.consultations().count == 1 }, "explicit-send race produced no consultation")
    let raceAskID = try require(raceBroker.consultations().first?.id, "explicit-send race lost its consultation")
    try expect(
        raceBroker.handleAnswer(token: targetToken, consultationID: raceAskID, text: "Race review done.").status == 200,
        "explicit-send race could not complete"
    )
    try expect(eventually { raceResult.value?.status == 200 }, "explicit-send race did not return normally")

    let completed = broker.handleDelegationResult(
        token: targetToken,
        handoffID: delegationID,
        text: "Implementation finished.",
        succeeded: true
    )
    try expect(completed.status == 200, "busy-queue fixture could not finish its active work")
    Thread.sleep(forTimeInterval: 0.05)
    try expect(submissions.value == 1, "an idle target automatically received queued text")
    try expect(broker.reviewedBusyDrafts().map(\.id) == [draft.id], "becoming idle silently consumed the reviewed draft")

    let sendResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        sendResult.set(broker.sendReviewedBusyAskFromUI(ReviewedBusyDraftSendRequest(
            draftID: draft.id,
            expectedUpdatedAt: draft.updatedAt,
            text: "Review the finished implementation.\nPreserve this edited second line.",
            preserveFormatting: true
        )))
    }
    try expect(eventually { submissions.value == 2 }, "explicit human authorization did not submit the reviewed draft")
    try expect(broker.reviewedBusyDrafts().isEmpty, "a submitted busy draft remained presented as unsent")
    let activeAsk = try require(broker.consultations().first, "explicit busy-queue send created no tracked Ask")
    try expect(
        broker.handleAnswer(token: targetToken, consultationID: activeAsk.id, text: "Review passed.").status == 200,
        "the explicitly sent queued Ask could not return normally"
    )
    try expect(eventually { sendResult.value?.status == 200 }, "the explicitly sent queued Ask did not complete")

    let noLongerBusy = broker.enqueueReviewedBusyAskFromUI(ReviewedBusyDraftCreateRequest(
        sourcePaneID: source.id,
        targetPaneID: target.id,
        text: "Do not queue this while idle."
    ))
    try expect(noLongerBusy.status == 409, "the core accepted a busy-queue draft for an idle target")
    try expect(submissions.value == 2, "a rejected queue request touched the target terminal")

    let secondDelegation = broker.handleDelegate(
        token: sourceToken,
        target: target.id,
        text: "Hold the target busy for the control-route check.",
        idempotencyKey: "busy-queue-control-fixture"
    )
    try expect(secondDelegation.status == 200, "busy-queue control fixture did not start")
    let infoFile = directory.appendingPathComponent("relay-url")
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: "busy-control")
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(infoFile: infoFile, controlToken: "busy-control")
    let clientDraft = try client.enqueueReviewedBusyDraft(ReviewedBusyDraftCreateRequest(
        sourcePaneID: source.id,
        targetPaneID: target.id,
        text: "Review through the authenticated native route."
    ))
    let clientDrafts = try client.reviewedBusyDrafts()
    try expect(clientDrafts.map(\.id) == [clientDraft.id], "the authenticated UI could not reattach to the durable busy queue")

    let unauthorized = RelayCoreClient(infoFile: infoFile, controlToken: "wrong-control")
    do {
        _ = try unauthorized.reviewedBusyDrafts()
        throw CheckFailure(description: "an unauthenticated client read reviewed busy text")
    } catch RelayCoreError.response(401, _) {
        // Expected: pane credentials and unrelated local clients never receive the queue.
    }
    let cancelled = try client.cancelReviewedBusyDraft(clientDraft.id)
    try expect(cancelled.status == 200, "the authenticated person could not discard an unsent queued draft")
    let afterCancel = try client.reviewedBusyDrafts()
    try expect(afterCancel.isEmpty, "discarding a queued draft left it visible")
    try expect(submissions.value == 3, "listing or discarding a queued draft wrote terminal input")

    let secondDelegationID = try require(secondDelegation.body.handoffID, "control fixture had no id")
    try expect(
        broker.handleDelegationResult(
            token: targetToken,
            handoffID: secondDelegationID,
            text: "Control fixture done.",
            succeeded: true
        ).status == 200,
        "control fixture could not release the target"
    )
    let slowFixture = broker.handleDelegate(
        token: sourceToken,
        target: target.id,
        text: "Hold busy before the slow reviewed Ask.",
        idempotencyKey: "busy-queue-slow-fixture"
    )
    let slowFixtureID = try require(slowFixture.body.handoffID, "slow fixture produced no id")
    let slowDraft = try client.enqueueReviewedBusyDraft(ReviewedBusyDraftCreateRequest(
        sourcePaneID: source.id,
        targetPaneID: target.id,
        text: "Take longer than the ordinary local-control timeout to review this."
    ))
    try expect(
        broker.handleDelegationResult(
            token: targetToken,
            handoffID: slowFixtureID,
            text: "Slow fixture ready.",
            succeeded: true
        ).status == 200,
        "slow fixture could not release the target"
    )
    let slowResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            slowResult.set(try client.sendReviewedBusyDraft(ReviewedBusyDraftSendRequest(
                draftID: slowDraft.id,
                expectedUpdatedAt: slowDraft.updatedAt,
                text: slowDraft.text
            )))
        } catch {
            slowResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    try expect(eventually { broker.consultations().count == 1 }, "slow explicit send never created its tracked Ask")
    Thread.sleep(forTimeInterval: 3.2)
    let slowAskID = try require(broker.consultations().first?.id, "slow explicit send lost its consultation")
    try expect(
        broker.handleAnswer(token: targetToken, consultationID: slowAskID, text: "Slow review passed.").status == 200,
        "slow explicit send could not return its answer"
    )
    try expect(eventually { slowResult.value != nil }, "slow explicit send did not return to the native client")
    try expect(slowResult.value?.status == 200, "native busy-queue send timed out before a normal agent answer")
}

private func checkHumanCancellationUnblocksAsk() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "This question will be cancelled.",
            idempotencyKey: "cancel-ask-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "cancellation check never established its Ask")
    let handoffID = try require(broker.consultations().first?.id, "cancellable Ask had no handoff id")

    let cancelled = broker.cancelHandoff(
        handoffID,
        reason: "Cancelled by the person using Parley."
    )

    try expect(cancelled.status == 200, "human cancellation was refused")
    try expect(eventually { result.value != nil }, "human cancellation left the requesting agent blocked")
    try expect(result.value?.status == 409 && result.value?.text.contains("Cancelled by the person") == true, "requester received no explicit cancellation reason")
    try expect(broker.consultations().isEmpty, "cancelled consultation remained active")
    let handoff = try require(broker.handoffs().first(where: { $0.id == handoffID }), "cancelled handoff disappeared")
    try expect(handoff.state == .cancelled, "human cancellation recorded the wrong terminal state")
    try expect(handoff.transitions.last?.detail == "Cancelled by the person using Parley.", "cancelled handoff lost its reason")
    try expect(handoff.transitions.last?.origin == .human, "human cancellation was indistinguishable from an automatic transition")

    let retry = broker.handleAsk(
        token: sourceToken,
        target: "agy",
        text: "This question will be cancelled.",
        idempotencyKey: "cancel-ask-1"
    )
    try expect(retry == result.value, "idempotent retry did not preserve the cancellation result")
    try expect(submissions.value == 1, "retry resubmitted a cancelled Ask")
}

private func checkSafeFailedDeliveryRetryIsStableAndDeduplicated() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let attempts = LockedCounter()
    let retryStarted = DispatchSemaphore(value: 0)
    let finishRetry = DispatchSemaphore(value: 0)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            attempts.increment()
            if attempts.value == 1 {
                throw ParleyTmuxError.unsafeRelayTarget("Codex")
            }
            retryStarted.signal()
            _ = finishRetry.wait(timeout: .now() + 2)
        }
    )

    let failed = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Review this exact patch.",
        idempotencyKey: "safe-retry-1"
    )
    let handoffID = try require(failed.body.handoffID, "failed relay returned no handoff id")
    let before = try require(broker.handoffs().first(where: { $0.id == handoffID }), "failed relay disappeared")
    try expect(before.state == .failed, "failed relay did not reach failed state")
    try expect(before.retryDisposition == .safe, "pre-input failure was not marked safe to retry")
    try expect(before.attention == .targetNotReady, "unready target did not produce explicit attention state")
    try expect(before.canRetrySafely, "safe failed relay did not expose retry capability")

    let retried = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        retried.set(broker.retryHandoff(handoffID))
    }
    try expect(retryStarted.wait(timeout: .now() + 1) == .success, "retry did not start its second delivery attempt")
    let concurrent = broker.retryHandoff(handoffID)
    try expect(concurrent.status == 409, "concurrent retry was allowed to submit a duplicate")
    finishRetry.signal()
    try expect(eventually { retried.value != nil }, "safe retry did not finish")
    try expect(retried.value?.status == 200, "safe retry returned an error")
    try expect(attempts.value == 2, "safe retry ran more than one additional delivery attempt")

    let after = try require(broker.handoffs().first(where: { $0.id == handoffID }), "retried handoff disappeared")
    try expect(broker.handoffs().count == 1, "retry created a duplicate handoff record")
    try expect(after.state == .completed, "successful retry did not complete the original handoff")
    try expect(after.retryDisposition == nil && after.attention == nil, "successful retry retained stale failure metadata")
    try expect(
        after.transitions.map(\.state) == [.created, .failed, .created, .delivered, .completed],
        "retry did not preserve one observable transition trail"
    )
    try expect(after.transitions.suffix(3).allSatisfy { $0.origin == .human }, "safe UI retry transitions were not marked as human intervention")

    let commandRetry = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Review this exact patch.",
        idempotencyKey: "safe-retry-1"
    )
    try expect(commandRetry.status == 200 && commandRetry.body.handoffID == handoffID, "later idempotent command did not reuse the retried handoff")
    try expect(attempts.value == 2, "later idempotent command submitted after a successful UI retry")
}

private func checkUncertainAndAskFailuresCannotBeRetried() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let attempts = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            attempts.increment()
            throw ParleyTmuxError.commandFailed("submit failed after paste")
        },
        consultationTimeout: 0.05
    )

    let uncertain = broker.handle(
        token: sourceToken,
        target: "codex",
        text: "Do not duplicate this.",
        idempotencyKey: "uncertain-retry-1"
    )
    let uncertainID = try require(uncertain.body.handoffID, "uncertain failure returned no handoff id")
    let uncertainHandoff = try require(broker.handoffs().first(where: { $0.id == uncertainID }), "uncertain handoff disappeared")
    try expect(uncertainHandoff.retryDisposition == .uncertain, "post-paste failure was not marked uncertain")
    try expect(!uncertainHandoff.canRetrySafely, "uncertain delivery exposed a retry capability")
    let refused = broker.retryHandoff(uncertainID)
    try expect(refused.status == 409 && refused.text.contains("cannot safely retry"), "uncertain delivery retry was not clearly refused")
    try expect(attempts.value == 1, "refused uncertain retry invoked delivery again")

    let ask = broker.handleAsk(
        token: sourceToken,
        target: "codex",
        text: "This Ask fails before submission.",
        idempotencyKey: "ask-retry-unsupported-1"
    )
    try expect(ask.status == 409, "failing Ask fixture unexpectedly succeeded")
    let askHandoff = try require(broker.handoffs().first(where: { $0.idempotencyKey == "ask-retry-unsupported-1" }), "failed Ask disappeared")
    try expect(askHandoff.retryDisposition == .unsupported, "failed Ask did not explicitly refuse UI retry")
    try expect(broker.retryHandoff(askHandoff.id).status == 409, "failed Ask was retried without a waiting requester")
}

private func checkAskDetectsDeadAndRestartedPanes() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let source = TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil)
    let target = TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil)
    let livePanes = LockedPanes([source, target])
    let broker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )

    let closedTargetResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        closedTargetResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the target stay open?",
            idempotencyKey: "closed-target-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "dead-target check never established its Ask")
    let closedTargetID = try require(broker.consultations().first?.id, "dead-target Ask had no handoff id")
    livePanes.set([source])
    try expect(eventually(timeout: 1) { closedTargetResult.value != nil }, "closed target left Ask blocked")
    try expect(closedTargetResult.value?.status == 410, "closed target returned the wrong failure status")
    let closedTarget = try require(broker.handoffs().first(where: { $0.id == closedTargetID }), "dead-target handoff disappeared")
    try expect(closedTarget.state == .failed && closedTarget.transitions.last?.detail?.contains("closed") == true, "dead target did not produce an explicit failed state")

    livePanes.set([source, target])
    let restartedTargetResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        restartedTargetResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the target restart?",
            idempotencyKey: "restart-target-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "target-restart check never established its Ask")
    let restartedTargetID = try require(broker.consultations().first?.id, "target-restart Ask had no handoff id")
    _ = try credentials.rotate("%2")
    try expect(eventually(timeout: 1) { restartedTargetResult.value != nil }, "restarted target left Ask blocked")
    try expect(restartedTargetResult.value?.status == 409, "restarted target returned the wrong failure status")
    let restartedTarget = try require(broker.handoffs().first(where: { $0.id == restartedTargetID }), "target-restart handoff disappeared")
    try expect(restartedTarget.state == .failed && restartedTarget.transitions.last?.detail?.contains("restarted") == true, "target restart did not produce an explicit failed state")

    _ = try credentials.token(for: "%2")
    livePanes.set([source, target])
    let restartedSourceResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        restartedSourceResult.set(broker.handleAsk(
            token: sourceToken,
            target: "agy",
            text: "Will the requester restart?",
            idempotencyKey: "restart-source-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "source-restart check never established its Ask")
    let restartedSourceID = try require(broker.consultations().first?.id, "source-restart Ask had no handoff id")
    let liveSourceToken = try credentials.rotate("%1")
    try expect(eventually(timeout: 1) { restartedSourceResult.value != nil }, "restarted requester left Ask blocked")
    try expect(restartedSourceResult.value?.status == 409, "restarted requester returned the wrong interruption status")
    let restartedSource = try require(broker.handoffs().first(where: { $0.id == restartedSourceID }), "source-restart handoff disappeared")
    try expect(restartedSource.state == .interrupted && restartedSource.transitions.last?.detail?.contains("requesting pane restarted") == true, "source restart did not interrupt its Ask explicitly")

    let closedSourceResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        closedSourceResult.set(broker.handleAsk(
            token: liveSourceToken,
            target: "agy",
            text: "Will the requester stay open?",
            idempotencyKey: "closed-source-1"
        ))
    }
    try expect(eventually { broker.consultations().count == 1 }, "dead-source check never established its Ask")
    let closedSourceID = try require(broker.consultations().first?.id, "dead-source Ask had no handoff id")
    livePanes.set([target])
    try expect(eventually(timeout: 1) { closedSourceResult.value != nil }, "closed requester left Ask blocked")
    let closedSource = try require(broker.handoffs().first(where: { $0.id == closedSourceID }), "dead-source handoff disappeared")
    try expect(closedSource.state == .interrupted && closedSource.transitions.last?.detail?.contains("requesting pane closed") == true, "dead requester did not interrupt its Ask explicitly")
}

private func checkConsultationShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "agy", "What should move first?"],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(eventually { broker.consultations().count == 1 }, "parley ask did not reach the local broker")
    let consultation = try require(broker.consultations().first, "shim consultation disappeared")
    try expect(consultation.state == .awaitingAnswer, "shim Ask was not submitted automatically")
    let answerOutput = try ProcessCommandRunner(timeout: 5).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "answer", "current", "Move the rules engine first."],
        environment: ProcessInfo.processInfo.environment.merging([
            "PARLEY_RELAY_TOKEN": targetToken,
        ]) { _, supplied in supplied },
        input: nil
    )
    try expect(answerOutput.status == 0, "parley answer failed: \(answerOutput.stderrText)")
    try expect(eventually { askResult.value != nil }, "parley ask stayed blocked after parley answer")
    try expect(askResult.value?.status == 0, "parley ask command exited unsuccessfully")
    try expect(askResult.value?.text == "Move the rules engine first.", "parley ask stdout did not become the target's exact answer")
}

private func checkAskManyShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01
    )
    let transportDirectory = directory.appendingPathComponent("agent-transport", isDirectory: true)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer {
        broker.cancelAll()
        transport.stop()
    }

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask-many", "codex,agy", "Name one concern."],
                environment: ProcessInfo.processInfo.environment.merging([
                    "PARLEY_RELAY_TOKEN": sourceToken,
                ]) { _, supplied in supplied },
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(eventually { broker.consultations().count == 2 }, "parley ask-many did not reach both targets through the filesystem transport")
    try expect(broker.handleAnswer(token: codexToken, consultationID: "current", text: "Codex concern").status == 200, "Codex shim answer failed")
    try expect(broker.handleAnswer(token: agyToken, consultationID: "current", text: "Agy concern").status == 200, "Agy shim answer failed")
    try expect(eventually { askResult.value != nil }, "parley ask-many stayed blocked after both shim answers")
    let output = try require(askResult.value, "parley ask-many produced no shell output")
    try expect(output.status == 0, "parley ask-many command exited unsuccessfully: \(output.text)")
    try expect(output.text.contains("Codex concern") && output.text.contains("Agy concern"), "parley ask-many stdout omitted an answer")
}

private func checkCommandTimeout() throws {
    let runner = ProcessCommandRunner(timeout: 0.05)
    let started = Date()
    let result = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        environment: ProcessInfo.processInfo.environment,
        input: nil
    )
    try expect(result.status == 124, "timed-out command did not return status 124")
    try expect(result.stderrText.contains("timed out"), "timed-out command did not explain its failure")
    try expect(Date().timeIntervalSince(started) < 2, "command timeout did not bound the wait")
}

private func checkCommandInputAndBothOutputStreams() throws {
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_COMMAND_IO_FIXTURE"] = "1"
    let input = Data(String(repeating: "command-io\n", count: 8_192).utf8)
    let result = try ProcessCommandRunner(timeout: 3).run(
        executable: URL(fileURLWithPath: CommandLine.arguments[0]),
        arguments: [],
        environment: environment,
        input: input
    )
    try expect(result.status == 23, "command runner lost the child exit status: \(result.status)")
    try expect(result.stdout == Data("stdout:".utf8) + input, "command runner lost or truncated stdout")
    try expect(result.stderr == Data("stderr:".utf8) + input, "command runner lost or truncated stderr")
}

private func checkDaemonizingCommandCannotHoldOutputCaptureOpen() throws {
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_DAEMON_OUTPUT_FIXTURE"] = "1"
    let started = Date()
    let result = try ProcessCommandRunner(timeout: 0.5).run(
        executable: URL(fileURLWithPath: CommandLine.arguments[0]),
        arguments: [],
        environment: environment,
        input: nil,
        outputExpectation: .mayArriveAfterClientExit
    )
    try expect(result.status == 0, "daemon-output fixture lost its exit status")
    try expect(result.stdoutText == "daemon-ready", "daemon-output fixture lost stdout")
    try expect(
        Date().timeIntervalSince(started) < 1,
        "a daemon descendant kept the completed command's output capture open"
    )
}

private func checkLaunchServicesCommandOutputCapture() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = directory.appendingPathComponent("CommandCaptureProbe.app", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)

    let executable = executables.appendingPathComponent("command-capture-probe")
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        to: executable
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let result = directory.appendingPathComponent("result.txt")
    let info: [String: Any] = [
        "CFBundleExecutable": executable.lastPathComponent,
        "CFBundleIdentifier": "com.markjoyeux.parley.command-capture-probe.\(UUID().uuidString.lowercased())",
        "CFBundleName": "Parley Command Capture Probe",
        "CFBundlePackageType": "APPL",
        "LSBackgroundOnly": true,
        "LSEnvironment": ["PARLEY_COMMAND_CAPTURE_PROBE_RESULT": result.path],
    ]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

    let launched = try ProcessCommandRunner(timeout: 8).run(
        executable: URL(fileURLWithPath: "/usr/bin/open"),
        arguments: ["-W", "-n", bundle.path],
        environment: ProcessInfo.processInfo.environment,
        input: nil
    )
    try expect(
        launched.status == 0,
        "Launch Services command-output probe did not exit cleanly: \(launched.stdoutText)\(launched.stderrText)"
    )
    let captured = try String(contentsOf: result, encoding: .utf8)
    try expect(
        captured == "status=0\nstdout=PARLEY_GUI_CAPTURE_OK\n",
        "a Launch Services-owned AppKit process lost child stdout: \(captured)"
    )
}

private final class CommandCaptureProbeDelegate: NSObject, NSApplicationDelegate {
    private let resultPath: String

    init(resultPath: String) {
        self.resultPath = resultPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let output = try ProcessCommandRunner(timeout: 2).run(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["PARLEY_GUI_CAPTURE_OK"],
                environment: ProcessInfo.processInfo.environment,
                input: nil
            )
            let result = "status=\(output.status)\nstdout=\(output.stdoutText)\n"
            try result.write(toFile: resultPath, atomically: true, encoding: .utf8)
        } catch {
            try? "error=\(error.localizedDescription)\n".write(
                toFile: resultPath,
                atomically: true,
                encoding: .utf8
            )
        }
        NSApplication.shared.terminate(nil)
    }
}

private func checkCoreStartupTimeoutReportsLastPhase() throws {
    let directory = try temporaryDirectory()
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_CORE_HANG_FIXTURE"] = "1"

    do {
        _ = try RelayCoreLauncher.ensureRunning(
            applicationDirectory: directory,
            cwd: "/tmp",
            environment: environment,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
            timeout: 0.1
        )
        throw CheckFailure(description: "hanging fixture unexpectedly became healthy")
    } catch let error as RelayCoreError {
        let detail = error.localizedDescription
        try expect(detail.contains("startup timed out"), "core timeout lost its failure reason: \(detail)")
        try expect(detail.contains("fixture reached startup"), "core timeout lost its last startup phase: \(detail)")
    }
}

private func checkBundledCoreServiceResolution() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("parley-bundled-core-\(UUID().uuidString)", isDirectory: true)
    let executableDirectory = root.appendingPathComponent("Parley.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let app = executableDirectory.appendingPathComponent("parley-native")
    let core = executableDirectory.appendingPathComponent("parley-core-service")
    try Data().write(to: app)
    try Data().write(to: core)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: core.path)

    let resolved = RelayCoreLauncher.resolveExecutable(
        environment: [:],
        bundleExecutable: app,
        argument0: "/missing/parley-native"
    )
    try expect(resolved == core, "packaged UI did not resolve its sibling core service")
}

private func checkCoreServiceStopsCleanly() throws {
    let directory = try temporaryDirectory()
    let stateFile = directory.appendingPathComponent("service-state")
    let process = Process()
    let finished = DispatchSemaphore(value: 0)
    var environment = ProcessInfo.processInfo.environment
    environment["PARLEY_CORE_LIFECYCLE_FIXTURE"] = stateFile.path
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    guard eventually(timeout: 2, { FileManager.default.fileExists(atPath: stateFile.path) }) else {
        process.terminate()
        throw CheckFailure(description: "lifecycle fixture never became ready")
    }
    let ready = try String(contentsOf: stateFile, encoding: .utf8)
    try expect(ready == "ready", "lifecycle fixture wrote malformed process state")

    try expect(Darwin.kill(process.processIdentifier, SIGTERM) == 0, "could not terminate lifecycle fixture")
    if finished.wait(timeout: .now() + 2) == .timedOut {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 1)
        throw CheckFailure(description: "core service did not handle SIGTERM")
    }
    process.waitUntilExit()
    try expect(process.terminationStatus == 0, "core service shutdown trapped with status \(process.terminationStatus)")
    let stopped = try String(contentsOf: stateFile, encoding: .utf8)
    try expect(stopped == "stopped \(SIGTERM)", "core service did not finish its shutdown handler")
}

private func checkCoreServiceLoginLaunchConfiguration() throws {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let login = CoreServiceLaunchConfiguration.resolve(
        arguments: ["parley-core-service", "--login-agent"],
        homeDirectory: home,
        currentDirectory: "/"
    )
    try expect(login.mode == .loginAgent, "login launch mode was not detected")
    try expect(!login.bootstrapsTmux, "login launch would create a tmux workspace before the UI opens")
    try expect(login.cwd == "/Users/tester", "login launch did not use the user home as its safe fallback folder")
    try expect(login.tmuxSessionName == "parley", "login launch lost the Production tmux session")
    try expect(login.runtimeMarker == nil, "login launch invented a Development marker")
    try expect(
        login.applicationDirectory.path == "/Users/tester/Library/Application Support/Parley Native",
        "login launch did not resolve the standard owner-local application directory"
    )

    let foreground = CoreServiceLaunchConfiguration.resolve(
        arguments: [
            "parley-core-service",
            "--application-directory", "/tmp/parley-app",
            "--cwd", "/tmp/project",
            "--tmux-session", "parley-development",
            "--runtime-marker", "DEV",
        ],
        homeDirectory: home,
        currentDirectory: "/tmp/fallback"
    )
    try expect(foreground.mode == .foregroundLauncher, "ordinary UI launch was mistaken for a login agent")
    try expect(foreground.bootstrapsTmux, "ordinary UI launch stopped bootstrapping tmux")
    try expect(foreground.applicationDirectory.path == "/tmp/parley-app", "explicit application directory was ignored")
    try expect(foreground.cwd == "/tmp/project", "explicit working directory was ignored")
    try expect(foreground.tmuxSessionName == "parley-development", "foreground core lost the isolated tmux session")
    try expect(foreground.runtimeMarker == "DEV", "foreground core lost the Development marker")

    let active = try statusHandoff(
        id: "active-delegation",
        kind: .delegate,
        state: .waiting,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@0",
        occurredAt: 1
    )
    let finished = try statusHandoff(
        id: "finished-relay",
        kind: .relay,
        state: .completed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@0",
        occurredAt: 2
    )
    try expect(
        !CoreLoginItemChangePolicy.canDisable(activeConsultationCount: 0, handoffs: [active]),
        "launch-at-login could be disabled while tracked work was active"
    )
    try expect(
        !CoreLoginItemChangePolicy.canDisable(
            activeConsultationCount: 1,
            handoffs: [finished]
        ),
        "launch-at-login could be disabled while a consultation was waiting"
    )
    try expect(
        CoreLoginItemChangePolicy.canDisable(activeConsultationCount: 0, handoffs: [finished]),
        "completed work unnecessarily blocked disabling launch-at-login"
    )
}

private func checkCoreServiceUpgradeIdentity() throws {
    let packaged = CoreServiceIdentity.resolve(infoDictionary: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "456",
    ])
    let development = CoreServiceIdentity.resolve(infoDictionary: nil)

    try expect(packaged.contractVersion == 6, "packaged core identity has the wrong coordination contract")
    try expect(packaged.applicationVersion == "1.2.3", "packaged core identity lost the app version")
    try expect(packaged.build == "456", "packaged core identity lost the app build")
    try expect(development.applicationVersion == "development", "development core identity invented an app version")
    try expect(development.build == "development", "development core identity invented a build")
    try expect(packaged.requiresHandover(from: development), "a different core build was treated as current")
    try expect(!packaged.requiresHandover(from: packaged), "an identical core build requested a handover")
    try expect(packaged.requiresHandover(from: nil), "a legacy core with no identity was treated as current")

    try expect(
        RelayCoreHandover.validatedLegacyPID(
            pidFileContents: "42\n",
            executablePath: "/Applications/Parley.app/Contents/MacOS/parley-core-service",
            currentPID: 99
        ) == 42,
        "the exact legacy core executable was refused"
    )
    try expect(
        RelayCoreHandover.validatedLegacyPID(
            pidFileContents: "42",
            executablePath: "/tmp/unrelated-service",
            currentPID: 99
        ) == nil,
        "an unrelated process passed legacy-core validation"
    )
    try expect(
        RelayCoreHandover.validatedLegacyPID(
            pidFileContents: "99",
            executablePath: "/tmp/parley-core-service",
            currentPID: 99
        ) == nil,
        "the UI could mistake itself for a legacy core"
    )
}

private func checkCoreUpgradeDrainIsAtomic() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    _ = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let result = LockedAskResult()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            writerEntered.signal()
            _ = releaseWriter.wait(timeout: .now() + 3)
        }
    )

    DispatchQueue.global(qos: .utility).async {
        let response = broker.handle(
            token: sourceToken,
            target: "agy",
            text: "in flight",
            idempotencyKey: "upgrade-drain-in-flight"
        )
        result.set(RelayTextResponse(status: response.status, text: response.body.error ?? response.body.note ?? ""))
    }
    try expect(writerEntered.wait(timeout: .now() + 2) == .success, "upgrade drain fixture never entered delivery")
    let inFlight = broker.prepareForUpgrade()
    try expect(!inFlight.accepted && inFlight.activeDispatches == 1, "upgrade drain ignored an in-flight delivery")
    releaseWriter.signal()
    try expect(eventually { result.value?.status == 200 }, "in-flight delivery did not finish")

    let ready = broker.prepareForUpgrade()
    try expect(ready.accepted, "idle broker refused upgrade drain")
    let refused = broker.handle(
        token: sourceToken,
        target: "agy",
        text: "too late",
        idempotencyKey: "upgrade-drain-refused"
    )
    try expect(refused.status == 409, "draining core accepted a new handoff")
    try expect(refused.body.error?.localizedCaseInsensitiveContains("upgrade") == true, "drain refusal did not explain the upgrade")
}

private func checkCoreUpgradeControlRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let identity = CoreServiceIdentity.resolve(infoDictionary: [
        "CFBundleShortVersionString": "2.0.0",
        "CFBundleVersion": "99",
    ])
    let shutdowns = LockedShutdownReasons()
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken,
        identity: identity,
        shutdownRequested: { shutdowns.append($0) }
    )
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )

    let observedIdentity = try client.coreIdentity()
    try expect(observedIdentity == identity, "core identity round trip changed its fields")
    let response = try client.shutdownIfIdle()
    try expect(response.status == 202, "idle core did not acknowledge graceful handover")
    try expect(eventually { shutdowns.values == [.upgrade] }, "upgrade shutdown callback lost its reason")
}

private func checkCoreUninstallStopControlRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let shutdowns = LockedShutdownReasons()
    let server = RelayHTTPServer(
        broker: broker,
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken,
        shutdownRequested: { shutdowns.append($0) }
    )
    try server.start()
    defer { server.stop() }
    let client = RelayCoreClient(
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )

    let response = try client.stopIfIdle()
    try expect(response.status == 202, "idle core did not acknowledge uninstall preparation")
    try expect(eventually { shutdowns.values == [.uninstall] }, "uninstall shutdown callback lost its reason")
}

private func checkCoreUninstallTransactionRollback() throws {
    try expect(RelayCoreShutdownReason.upgrade.preservesExchangeFiles, "upgrade would discard commands spanning handover")
    try expect(!RelayCoreShutdownReason.uninstall.preservesExchangeFiles, "uninstall would replay stale commands after reinstall")

    var registered = RelayCoreUninstallTransaction(loginItemWasRegistered: true)
    try expect(!registered.requiresLoginItemRollback, "unmodified uninstall transaction requested rollback")
    registered.recordLoginItemDisabled()
    try expect(registered.requiresLoginItemRollback, "failed core stop would leave launch at login disabled")
    registered.recordCoreStopAccepted()
    try expect(registered.requiresLoginItemRollback, "accepted core stop hid a later uninstall failure")
    registered.recordPreparationCompleted()
    try expect(!registered.requiresLoginItemRollback, "completed uninstall transaction still requested rollback")

    var unregistered = RelayCoreUninstallTransaction(loginItemWasRegistered: false)
    unregistered.recordLoginItemDisabled()
    try expect(!unregistered.requiresLoginItemRollback, "uninstall invented a login-item registration")
}

private func checkCoreUpgradeReplacesPersistentFixture() throws {
    let directory = try temporaryDirectory()
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let process = Process()
    var oldEnvironment = ProcessInfo.processInfo.environment
    oldEnvironment["PARLEY_CORE_FIXTURE"] = "1"
    oldEnvironment["PARLEY_CORE_FIXTURE_BUILD"] = "old"
    process.executableURL = executable
    process.arguments = [
        "--application-directory", directory.path,
        "--cwd", "/tmp",
    ]
    process.environment = oldEnvironment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()

    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let client = RelayCoreClient(
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )
    guard eventually(timeout: 3, { client.isHealthy() }) else {
        process.terminate()
        throw CheckFailure(description: "old fixture core never became healthy")
    }
    let oldPID = process.processIdentifier

    var replacementEnvironment = ProcessInfo.processInfo.environment
    replacementEnvironment["PARLEY_CORE_FIXTURE"] = "1"
    replacementEnvironment.removeValue(forKey: "PARLEY_CORE_FIXTURE_BUILD")
    let expectedIdentity = CoreServiceIdentity.resolve(infoDictionary: nil)
    let result = try RelayCoreHandover.reconcile(
        client: client,
        expectedIdentity: expectedIdentity,
        applicationDirectory: directory,
        cwd: "/tmp",
        environment: replacementEnvironment,
        executable: executable,
        timeout: 3
    )
    try expect(result.outcome == .replaced, "mismatched fixture core was not replaced")
    try expect(result.client.isHealthy(), "replacement fixture core was not healthy")
    let newPIDText = try String(contentsOf: directory.appendingPathComponent("core.pid"), encoding: .utf8)
    let newPID = try require(
        Int32(newPIDText.trimmingCharacters(in: .whitespacesAndNewlines)),
        "replacement fixture core wrote an invalid PID"
    )
    try expect(newPID != oldPID, "upgrade reused the old core process")
    let replacementIdentity = try result.client.coreIdentity()
    try expect(replacementIdentity == expectedIdentity, "replacement fixture has the wrong identity")
    _ = Darwin.kill(newPID, SIGTERM)
    try expect(eventually(timeout: 3) { !result.client.isHealthy() }, "replacement fixture did not stop cleanly")
}

private func checkVendorConformancePlanning() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .codex, customName: "Codex active", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Codex inactive", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%4", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp",
            currentCommand: "agy", isActive: false, windowID: "@2", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "docs",
            bracketedPasteActive: true
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex])
    try expect(plan.count == 1, "conformance planner did not return one result per requested vendor")
    guard case let .probe(probe) = plan[0] else {
        throw CheckFailure(description: "ready Codex panes were unexpectedly skipped")
    }
    try expect(probe.target.id == "%2", "conformance planner did not prefer an inactive target")
    try expect(probe.source.id == "%3", "conformance planner did not select the first stable cross-workspace source")
    try expect(probe.testsInactiveTarget, "conformance probe lost inactive-pane coverage")
    try expect(probe.testsCrossWorkspace, "conformance probe lost cross-workspace coverage")
    try expect(probe.source.kind != probe.target.kind, "conformance planner selected a same-vendor source")
}

private func checkVendorConformancePlanningFailsClosed() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Stale Codex", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: "0", workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%3", kind: .agy, customName: "Unready Agy", terminalTitle: "", cwd: "/tmp",
            currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: false
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex, .agy, .copilot])
    try expect(plan.count == 3, "conformance planner omitted requested vendors")
    guard case let .skipped(_, codexReason) = plan[0] else {
        throw CheckFailure(description: "stale Codex pane was accepted for a live probe")
    }
    guard case let .skipped(_, agyReason) = plan[1] else {
        throw CheckFailure(description: "non-bracketed Agy pane was accepted for a live probe")
    }
    guard case let .skipped(_, copilotReason) = plan[2] else {
        throw CheckFailure(description: "missing Copilot pane was accepted for a live probe")
    }
    try expect(codexReason.contains("protocol"), "stale pane skip did not explain its protocol failure")
    try expect(agyReason.contains("bracketed paste"), "unready pane skip did not explain its input failure")
    try expect(copilotReason.contains("No open"), "missing vendor skip did not explain what to open")
}

private func checkVendorConformanceRejectsExitedPanes() throws {
    let panes = [
        TmuxPane(
            id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            bracketedPasteActive: true
        ),
        TmuxPane(
            id: "%2", kind: .codex, customName: "Exited Codex", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: false, windowID: "@1", returnToPaneID: nil,
            relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
            bracketedPasteActive: true, isDead: true, exitStatus: 7
        ),
    ]

    let plan = VendorConformancePlanner.plan(panes: panes, vendors: [.codex])
    guard case let .skipped(_, reason) = plan[0] else {
        throw CheckFailure(description: "exited Codex pane was accepted for a live probe")
    }
    try expect(reason.contains("exited"), "exited pane skip did not explain its process state")
}

private func checkVendorConformanceReport() throws {
    let results = [
        VendorConformanceResult(vendor: .claude, check: "round trip", outcome: .passed, detail: "exact response"),
        VendorConformanceResult(vendor: .codex, check: "cross-workspace", outcome: .notExercised, detail: "one workspace"),
        VendorConformanceResult(vendor: .copilot, check: "trust gate", outcome: .blocked, detail: "folder trust is waiting"),
        VendorConformanceResult(vendor: .agy, check: "round trip", outcome: .failed, detail: "wrong response"),
    ]
    let report = VendorConformanceReport(results: results)
    let rendered = report.rendered()

    try expect(report.hasFailures, "failed conformance result did not fail the report")
    try expect(report.hasBlockedChecks, "blocked conformance result was hidden")
    try expect(rendered.contains("PASS Claude — round trip: exact response"), "report omitted passing evidence")
    try expect(rendered.contains("SKIP Codex — cross-workspace: one workspace"), "report disguised an unexercised check")
    try expect(rendered.contains("BLOCKED Copilot — trust gate: folder trust is waiting"), "report disguised a blocked check")
    try expect(rendered.contains("FAIL Agy — round trip: wrong response"), "report omitted failure detail")
    try expect(rendered.contains("1 passed, 1 failed, 1 blocked, 1 not exercised"), "report summary counts are wrong")
}

private func checkVendorConformanceAttentionGate() throws {
    let trust = VendorConformanceAttention.blockedReason(
        kind: .copilot,
        visibleText: "Confirm folder trust\nDo you trust the files in this folder?"
    )
    let permission = VendorConformanceAttention.blockedReason(
        kind: .claude,
        visibleText: "Would you like to run the following command?\nAllow once"
    )
    let ready = VendorConformanceAttention.blockedReason(
        kind: .codex,
        visibleText: "Ask Codex to do anything"
    )

    try expect(trust?.kind == .trust, "folder trust prompt was not recognized")
    try expect(permission?.kind == .permission, "tool permission prompt was not recognized")
    try expect(ready == nil, "normal agent prompt was incorrectly blocked")
}

private func checkAgentContextDraftsRequireHumanApprovalBeforeAsk() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let claudeToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp/project", currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp/project", currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedDelivery()
    let reviewStore = try AgentContextReviewStore(
        file: directory.appendingPathComponent("context-reviews.json")
    )
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, text in submissions.set(paneID: paneID, text: text, submit: true) },
        contextSubmit: { paneID, text in submissions.set(paneID: paneID, text: text, submit: true) },
        consultationTimeout: 3,
        contextReviewStore: reviewStore
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "context-review-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let control = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)

    let staged = broker.handleContextDraft(
        token: claudeToken,
        name: "Parser review",
        path: "Sources/Parser.swift",
        text: "func parse() { fatalError() }"
    )
    try expect(staged.status == 201, "an authenticated pane could not stage explicit context")
    let stagedSummary = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(staged.text.utf8)
    )
    let stagedReview = try require(
        broker.contextReviews().first(where: { $0.id == stagedSummary.id }),
        "the staged context review was not retained"
    )
    try expect(stagedReview.state == .draft, "a staged context file skipped draft review")
    try expect(stagedReview.sourcePaneID == "%1", "a context draft trusted a claimed source pane")
    try expect(stagedReview.pack.parts.first?.source.kind == .agentFileDraft, "agent-provided context was labelled as person-selected")
    try expect(
        stagedReview.pack.parts.first?.source.detail.contains("not independently read by Parley") == true,
        "agent-provided context omitted its trust boundary"
    )
    let escaped = broker.handleContextDraft(
        token: claudeToken,
        name: "Escaped context",
        path: "/etc/hosts",
        text: "claimed external contents"
    )
    try expect(escaped.status == 403, "an agent could stage a file outside its pane folder")

    let listed = broker.contextDrafts(token: claudeToken)
    try expect(listed.status == 200 && listed.text.contains(stagedReview.id), "the source pane could not list its context drafts")
    let hidden = broker.contextDraft(token: codexToken, draftID: stagedReview.id)
    try expect(hidden.status == 404, "another pane could inspect a source pane's unsent context")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleContextAsk(
            token: claudeToken,
            draftID: stagedReview.id,
            target: "codex",
            text: "Find the concrete failure modes in this parser.",
            idempotencyKey: "context-review-ask-1"
        ))
    }
    try expect(eventually { (try? control.contextReviews().first?.state) == .awaitingReview }, "context Ask did not surface through native control")
    try expect(askResult.value == nil, "context Ask returned before the person reviewed it")
    try expect(submissions.value == nil, "context Ask submitted before human approval")

    let pending = try require(try control.contextReviews().first, "the pending context review disappeared")
    var approvedPack = pending.pack
    approvedPack.note = "Review only correctness and cite exact lines."
    let approved = try control.approveContextReview(
        reviewID: pending.id,
        expectedUpdatedAt: pending.updatedAt,
        pack: approvedPack,
        targetPaneID: "%2"
    )
    try expect(approved.status == 200, "the native control could not approve a context Ask")
    try expect(eventually { submissions.value != nil }, "approval did not dispatch the context Ask")
    try expect(submissions.value?.paneID == "%2", "approved context went to the wrong pane")
    try expect(submissions.value?.text.contains("Review only correctness") == true, "approval dispatched the unreviewed request")
    try expect(submissions.value?.text.contains("not independently read by Parley") == true, "approval stripped context provenance")
    try expect(askResult.value == nil, "approved context Ask stopped waiting before its correlated answer")

    let returned = broker.handleAnswer(token: codexToken, consultationID: "current", text: "The fatal error is unconditional.")
    try expect(returned.status == 200, "the context target could not return its correlated answer")
    try expect(eventually { askResult.value != nil }, "context Ask did not return the correlated answer")
    try expect(askResult.value?.status == 200 && askResult.value?.text.contains("fatal error") == true, "context Ask lost the answer")
    try expect(broker.contextReviews().first?.state == .completed, "the reviewed context did not record completion")

    let persisted = try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    try expect(persisted.reviews().first?.state == .completed, "context review state did not survive store reattachment")
}

private func checkConcurrentContextAddsRetainEveryAcceptedPart() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(
            id: "%1",
            kind: .claude,
            customName: "Claude",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "claude",
            isActive: true,
            windowID: "@0",
            returnToPaneID: nil
        ),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )
    let staged = broker.handleContextDraft(
        token: sourceToken,
        name: "Concurrent review",
        path: "Initial.swift",
        text: String(repeating: "x", count: 55_000)
    )
    let summary = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(staged.text.utf8)
    )

    let additions = 12
    let start = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let responses = LockedRelayResponses()
    for index in 0..<additions {
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            start.wait()
            responses.append(broker.handleContextAdd(
                token: sourceToken,
                draftID: summary.id,
                path: "Part-\(index).swift",
                text: "let acceptedPart\(index) = \(index)"
            ))
            finished.leave()
        }
    }
    for _ in 0..<additions { start.signal() }
    try expect(
        finished.wait(timeout: .now() + 5) == .success,
        "concurrent context additions did not finish"
    )
    try expect(
        responses.values.allSatisfy { $0.status == 200 },
        "a valid concurrent context addition was refused"
    )
    let review = try require(
        broker.contextReviews().first(where: { $0.id == summary.id }),
        "the concurrently edited context draft disappeared"
    )
    try expect(
        review.pack.parts.count == additions + 1,
        "concurrent accepted context additions overwrote one another"
    )
    for index in 0..<additions {
        try expect(
            review.pack.parts.contains { $0.text == "let acceptedPart\(index) = \(index)" },
            "concurrent context addition \(index) was reported successful but lost"
        )
    }
}

private func checkContextAddRacingAskHasOneDurableWinner() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(
            id: "%1",
            kind: .claude,
            customName: "Claude",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "claude",
            isActive: true,
            windowID: "@0",
            returnToPaneID: nil
        ),
        TmuxPane(
            id: "%2",
            kind: .codex,
            customName: "Codex",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "codex",
            isActive: false,
            windowID: "@0",
            returnToPaneID: nil
        ),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )

    for iteration in 0..<8 {
        let staged = broker.handleContextDraft(
            token: sourceToken,
            name: "Ask race \(iteration)",
            path: "Initial-\(iteration).swift",
            text: String(repeating: "x", count: 55_000)
        )
        let summary = try JSONDecoder().decode(
            AgentContextReviewSummary.self,
            from: Data(staged.text.utf8)
        )
        let addedText = "let raceWinner\(iteration) = true"
        let start = DispatchSemaphore(value: 0)
        let addResult = LockedAskResult()
        let askResult = LockedAskResult()
        DispatchQueue.global(qos: .userInitiated).async {
            start.wait()
            addResult.set(broker.handleContextAdd(
                token: sourceToken,
                draftID: summary.id,
                path: "Racing-\(iteration).swift",
                text: addedText
            ))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            start.wait()
            askResult.set(broker.handleContextAsk(
                token: sourceToken,
                draftID: summary.id,
                target: "%2",
                text: "Review iteration \(iteration).",
                idempotencyKey: "context-add-ask-race-\(iteration)"
            ))
        }
        start.signal()
        start.signal()

        try expect(eventually { addResult.value != nil }, "racing context add did not return")
        try expect(
            eventually {
                broker.contextReviews().first(where: { $0.id == summary.id })?.state == .awaitingReview
            },
            "a context add racing Ask rolled the review back from awaiting review"
        )
        let review = try require(
            broker.contextReviews().first(where: { $0.id == summary.id }),
            "the context add/Ask race lost its review"
        )
        if addResult.value?.status == 200 {
            try expect(
                review.pack.parts.contains { $0.text == addedText },
                "the winning context add was missing from the reviewed pack"
            )
        } else {
            try expect(
                addResult.value?.status == 404 && !review.pack.parts.contains { $0.text == addedText },
                "the losing context add did not fail closed"
            )
        }
        try expect(
            broker.rejectContextReview(reviewID: summary.id).status == 200,
            "the add/Ask race could not be resolved explicitly"
        )
        try expect(eventually { askResult.value != nil }, "rejecting the raced review left Ask blocked")
    }
}

private func checkContextAddRacingCompletionHasOneDurableWinner() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        directContextSubmit: { _, _, _ in },
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )

    for iteration in 0..<32 {
        let staged = broker.handleContextDraft(
            token: sourceToken,
            name: "Completion race \(iteration)",
            path: "Initial-\(iteration).swift",
            text: String(repeating: "x", count: 55_000)
        )
        let summary = try JSONDecoder().decode(
            AgentContextReviewSummary.self,
            from: Data(staged.text.utf8)
        )
        let previewReview = try require(
            broker.contextReviews().first(where: { $0.id == summary.id }),
            "completion-race draft disappeared"
        )
        var editableApprovalPack = previewReview.pack
        editableApprovalPack.note = "Review this race."
        let approvalPack = editableApprovalPack
        let approvalRevision = previewReview.updatedAt
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        let addResult = LockedAskResult()
        let completionResult = LockedAskResult()
        let marker = "accepted-add-\(iteration)"

        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            start.wait()
            addResult.set(broker.handleContextAdd(
                token: sourceToken,
                draftID: summary.id,
                path: "Added-\(iteration).swift",
                text: marker
            ))
            finished.leave()
        }
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            start.wait()
            completionResult.set(broker.completeContextDraft(AgentContextReviewApproval(
                reviewID: summary.id,
                expectedUpdatedAt: approvalRevision,
                targetPaneID: "%2",
                pack: approvalPack
            )))
            finished.leave()
        }
        start.signal()
        start.signal()
        try expect(
            finished.wait(timeout: .now() + 3) == .success,
            "add/completion context race did not finish"
        )
        let add = try require(addResult.value, "add/completion race lost its add response")
        let completion = try require(completionResult.value, "add/completion race lost its completion response")
        let final = try require(
            broker.contextReviews().first(where: { $0.id == summary.id }),
            "add/completion race lost its durable record"
        )
        if add.status == 200 {
            try expect(
                completion.status == 409
                    && final.state == .draft
                    && final.pack.parts.contains(where: { $0.capturedText == marker }),
                "a successful context add was overwritten or completed from a stale preview"
            )
        } else {
            try expect(
                add.status == 404 && completion.status == 200 && final.state == .completed,
                "completion did not have one durable winner over a losing context add"
            )
        }
    }

    let staleStage = broker.handleContextDraft(
        token: sourceToken,
        name: "Known stale preview",
        path: "Known.swift",
        text: "let known = true"
    )
    let staleSummary = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(staleStage.text.utf8)
    )
    let stalePreview = try require(
        broker.contextReviews().first(where: { $0.id == staleSummary.id }),
        "known stale preview disappeared"
    )
    try expect(
        broker.handleContextAdd(
            token: sourceToken,
            draftID: stalePreview.id,
            path: "Late.swift",
            text: "let late = true"
        ).status == 200,
        "known stale fixture could not add its later source"
    )
    var stalePack = stalePreview.pack
    stalePack.note = "This preview is now stale."
    let staleCompletion = broker.completeContextDraft(AgentContextReviewApproval(
        reviewID: stalePreview.id,
        expectedUpdatedAt: stalePreview.updatedAt,
        targetPaneID: "%2",
        pack: stalePack
    ))
    try expect(
        staleCompletion.status == 409 && staleCompletion.text.contains("changed after this preview"),
        "a known stale context preview was allowed to overwrite a later source"
    )
}

private func checkContextDraftDiscardIsOwnedReleasesAskAndCleansUpStaleDrafts() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let outsiderToken = try credentials.token(for: "%3")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: directory.path, currentCommand: "agy", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let store = try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        contextReviewStore: store
    )

    let staged = broker.handleContextDraft(
        token: sourceToken,
        name: "Disposable",
        path: "Disposable.swift",
        text: "let disposable = true"
    )
    let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
    try expect(
        broker.discardContextDraft(token: outsiderToken, draftID: summary.id).status == 404,
        "another pane could discard a context draft it did not own"
    )
    try expect(
        broker.discardContextDraft(token: sourceToken, draftID: summary.id).status == 200,
        "the authenticated source pane could not discard its context draft"
    )
    try expect(
        broker.contextReviews().first(where: { $0.id == summary.id })?.state == .discarded,
        "discarding a context draft did not record a terminal discarded state"
    )
    try expect(
        broker.handleContextAdd(
            token: sourceToken,
            draftID: summary.id,
            path: "TooLate.swift",
            text: "let tooLate = true"
        ).status == 404,
        "a discarded context draft remained editable"
    )

    let waiting = broker.handleContextDraft(
        token: sourceToken,
        name: "Waiting",
        path: "Waiting.swift",
        text: "let waiting = true"
    )
    let waitingSummary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(waiting.text.utf8))
    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleContextAsk(
            token: sourceToken,
            draftID: waitingSummary.id,
            target: "%2",
            text: "Review this.",
            idempotencyKey: "discard-waiting-context"
        ))
    }
    try expect(
        eventually { broker.contextReviews().first(where: { $0.id == waitingSummary.id })?.state == .awaitingReview },
        "the discard fixture never reached awaiting review"
    )
    try expect(
        broker.discardContextDraft(token: sourceToken, draftID: waitingSummary.id).status == 200,
        "the source pane could not discard its waiting context Ask"
    )
    try expect(eventually { askResult.value != nil }, "discarding a waiting context Ask left the source blocked")
    try expect(
        askResult.value?.status == 409 && askResult.value?.text.contains("discarded") == true,
        "discarding a waiting context Ask returned an ambiguous outcome"
    )
    try expect(
        broker.handleAnswer(token: targetToken, consultationID: "current", text: "No consultation should exist.").status == 404,
        "discarding review tracking created a target consultation"
    )

    let staleDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: staleDirectory) }
    let staleStore = try AgentContextReviewStore(file: staleDirectory.appendingPathComponent("context-reviews.json"))
    let old = Date(timeIntervalSinceNow: -(8 * 24 * 60 * 60))
    for index in 0..<32 {
        try staleStore.record(AgentContextReview(
            sourcePaneID: "%1",
            sourcePaneName: "Claude",
            sourcePaneKind: .claude,
            sourceFolder: directory.path,
            pack: ContextPack(
                name: "Abandoned \(index)",
                parts: [ContextPackPart(
                    source: ContextPackSource(kind: .agentFileDraft, label: "Old.swift", detail: "agent-provided"),
                    capturedText: "let old\(index) = true"
                )]
            ),
            createdAt: old,
            updatedAt: old
        ))
    }
    let cleanedBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        contextReviewStore: staleStore
    )
    try expect(
        cleanedBroker.contextReviews().allSatisfy { $0.state == .discarded },
        "a core restart did not clean up abandoned editable context drafts"
    )
    try expect(
        cleanedBroker.handleContextDraft(
            token: sourceToken,
            name: "Fresh after cleanup",
            path: "Fresh.swift",
            text: "let fresh = true"
        ).status == 201,
        "abandoned drafts permanently exhausted the pending-review safety bound"
    )
}

private func checkDirectContextDraftCompletionOwnsDeliveryAndFailureState() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let delivered = LockedDelivery()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        directContextSubmit: { _, paneID, text in delivered.set(paneID: paneID, text: text, submit: true) },
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )
    let staged = broker.handleContextDraft(
        token: sourceToken,
        name: "Direct delivery",
        path: "Direct.swift",
        text: "let direct = true"
    )
    let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
    let review = try require(
        broker.contextReviews().first(where: { $0.id == summary.id }),
        "the direct-delivery context draft disappeared"
    )
    var reviewedPack = review.pack
    reviewedPack.note = "Review this direct delivery."
    let completed = broker.completeContextDraft(AgentContextReviewApproval(
        reviewID: review.id,
        expectedUpdatedAt: review.updatedAt,
        targetPaneID: "%2",
        pack: reviewedPack
    ))
    try expect(completed.status == 200, "the core could not complete a direct context delivery")
    try expect(delivered.value?.paneID == "%2", "direct context completion did not own target delivery")
    try expect(
        delivered.value?.text.contains("Review this direct delivery") == true,
        "direct context completion submitted an unreviewed pack"
    )
    try expect(
        broker.contextReviews().first(where: { $0.id == review.id })?.state == .completed,
        "successful direct context delivery did not become durably completed"
    )

    let failingStore = try AgentContextReviewStore(file: directory.appendingPathComponent("failing-context-reviews.json"))
    let failingBroker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        directContextSubmit: { _, _, _ in
            throw RelayFileTransportError.runtime("fixture delivery failed before input")
        },
        contextReviewStore: failingStore
    )
    let failingStaged = failingBroker.handleContextDraft(
        token: sourceToken,
        name: "Failed delivery",
        path: "Failed.swift",
        text: "let failed = true"
    )
    let failingSummary = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(failingStaged.text.utf8)
    )
    let failingReview = try require(
        failingBroker.contextReviews().first(where: { $0.id == failingSummary.id }),
        "the failing direct-delivery draft disappeared"
    )
    var failingPack = failingReview.pack
    failingPack.note = "Attempt this delivery."
    let failed = failingBroker.completeContextDraft(AgentContextReviewApproval(
        reviewID: failingReview.id,
        expectedUpdatedAt: failingReview.updatedAt,
        targetPaneID: "%2",
        pack: failingPack
    ))
    try expect(failed.status == 409 && failed.text.contains("fixture delivery failed"), "direct delivery failure was hidden")
    let failedRecord = try require(
        failingBroker.contextReviews().first(where: { $0.id == failingReview.id }),
        "failed direct delivery lost its durable review"
    )
    try expect(
        failedRecord.state == .failed && failedRecord.detail?.contains("fixture delivery failed") == true,
        "failed direct delivery remained an apparently sendable draft"
    )
}

private func checkTrustedContextCaptureExtendsAgentDraftWithoutTrustingApproval() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        visibleText: { paneID in "visible output from \(paneID)" },
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "trusted-context-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let control = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)
    let staged = broker.handleContextDraft(
        token: sourceToken,
        name: "Trust boundary",
        path: "Claimed.swift",
        text: "let claimed = true"
    )
    let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
    let trustedFile = directory.appendingPathComponent("Trusted.swift")
    try "let trusted = true\n".write(to: trustedFile, atomically: true, encoding: .utf8)

    let captured = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .files,
        paths: [trustedFile.path]
    ))
    try expect(captured.status == 200, "a person-authorized local file could not be captured by the core")
    let capturedParts = try JSONDecoder().decode(
        AgentContextTrustedCaptureResponse.self,
        from: Data(captured.text.utf8)
    ).parts
    let trustedPart = try require(capturedParts.first, "trusted capture returned no context part")
    try expect(trustedPart.source.kind == .file, "core-captured context retained the agent-claim label")
    try expect(trustedPart.source.detail == trustedFile.path, "core-captured context invented its provenance")
    try expect(trustedPart.capturedText == "let trusted = true\n", "core-captured context changed the file contents")

    let browserCapture = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .browserSelection,
        evidencePaneID: "%1",
        sourceURL: "https://example.com/core-review",
        selectedText: "Person-selected browser evidence."
    ))
    try expect(browserCapture.status == 200, "authenticated browser evidence could not extend an agent draft")
    let browserParts = try JSONDecoder().decode(
        AgentContextTrustedCaptureResponse.self,
        from: Data(browserCapture.text.utf8)
    ).parts
    let browserPart = try require(browserParts.first, "core browser capture returned no context part")
    try expect(browserPart.source.kind == .browserSelection, "core browser capture lost its source kind")
    try expect(browserPart.source.vendorEvidence?.paneID == "%1", "core browser capture lost its exact pane attribution")
    try expect(browserPart.source.vendorEvidence?.toolAccess == .unknown, "core browser capture invented tool availability")

    let inventedPane = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .browserURL,
        evidencePaneID: "%invented",
        sourceURL: "https://example.com/invented"
    ))
    try expect(inventedPane.status == 409, "trusted browser capture accepted an invented vendor pane")
    let mixedFile = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .files,
        paths: [trustedFile.path],
        sourceURL: "https://example.com/ignored"
    ))
    try expect(mixedFile.status == 400, "trusted file capture silently ignored browser evidence fields")

    let binary = directory.appendingPathComponent("binary.dat")
    try Data([0, 1, 2, 3]).write(to: binary)
    let binaryResult = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .files,
        paths: [binary.path]
    ))
    try expect(binaryResult.status == 409 && binaryResult.text.localizedCaseInsensitiveContains("text"), "binary trusted context did not fail explicitly")
    let missingResult = try control.captureTrustedContext(AgentContextTrustedCaptureRequest(
        reviewID: summary.id,
        kind: .files,
        paths: [directory.appendingPathComponent("missing.swift").path]
    ))
    try expect(missingResult.status == 409 && missingResult.text.contains("missing.swift"), "missing trusted context did not identify the failed file")

    let review = try require(
        broker.contextReviews().first(where: { $0.id == summary.id }),
        "trusted capture lost the durable agent draft"
    )
    try expect(review.pack.parts.count == 3, "failed trusted captures mutated the durable draft")
    var forgedPack = review.pack
    forgedPack.parts.append(ContextPackPart(
        source: ContextPackSource(kind: .file, label: "Forged", detail: "/tmp/forged"),
        capturedText: "invented by approval"
    ))
    forgedPack.note = "Review the trusted file."
    let forged = broker.completeContextDraft(AgentContextReviewApproval(
        reviewID: review.id,
        expectedUpdatedAt: review.updatedAt,
        targetPaneID: "%2",
        pack: forgedPack
    ))
    try expect(forged.status == 400, "an approval payload invented a trusted context source")
    try expect(
        broker.contextReviews().first(where: { $0.id == summary.id })?.state == .draft,
        "a forged approval changed the durable draft state"
    )
}

private func checkContextReviewTransportBoundsAndEscaping() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        directContextSubmit: { _, _, _ in },
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
    )
    let infoFile = directory.appendingPathComponent("relay-url")
    let controlToken = "context-bounds-control"
    let server = RelayHTTPServer(broker: broker, infoFile: infoFile, controlToken: controlToken)
    try server.start()
    defer { server.stop() }
    let control = RelayCoreClient(infoFile: infoFile, controlToken: controlToken)

    let escapeHeavyText = String(repeating: "\\\"", count: 21_000)
    let staged = broker.handleContextDraft(
        token: sourceToken,
        name: "Escaping boundary",
        path: "First.swift",
        text: escapeHeavyText
    )
    let summary = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.text.utf8))
    let added = broker.handleContextAdd(
        token: sourceToken,
        draftID: summary.id,
        path: "Second.swift",
        text: escapeHeavyText
    )
    try expect(added.status == 200, "near-limit context could not stage its second part")
    let review = try require(
        broker.contextReviews().first(where: { $0.id == summary.id }),
        "near-limit context review disappeared"
    )
    var pack = review.pack
    pack.note = "Review escaping without changing the bytes."
    let renderedBytes = try ContextPackBuilder().render(pack).utf8.count
    let encodedBytes = try JSONEncoder().encode(AgentContextReviewApproval(
        reviewID: review.id,
        expectedUpdatedAt: review.updatedAt,
        targetPaneID: "%2",
        pack: pack
    )).count
    try expect(renderedBytes > 80_000, "escaping fixture did not reach the context-pack boundary")
    try expect(encodedBytes > 160_000 && encodedBytes < 200_000, "escaping fixture did not exercise the transport boundary")
    let completed = try control.completeContextDraft(
        reviewID: review.id,
        expectedUpdatedAt: review.updatedAt,
        pack: pack,
        targetPaneID: "%2"
    )
    try expect(completed.status == 200, "valid near-limit JSON escaping failed across core control")

    let oversizedStage = broker.handleContextDraft(
        token: sourceToken,
        name: "Oversized approval",
        path: "Small.swift",
        text: "let small = true"
    )
    let oversizedSummary = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(oversizedStage.text.utf8)
    )
    let oversizedReview = try require(
        broker.contextReviews().first(where: { $0.id == oversizedSummary.id }),
        "oversized transport draft disappeared"
    )
    var oversizedPack = oversizedReview.pack
    oversizedPack.note = String(repeating: "x", count: 205_000)
    let oversized = try control.completeContextDraft(
        reviewID: oversizedReview.id,
        expectedUpdatedAt: oversizedReview.updatedAt,
        pack: oversizedPack,
        targetPaneID: "%2"
    )
    try expect(
        oversized.status == 413 && oversized.text.contains("Reduce it"),
        "oversized approval payload did not fail explicitly before core delivery"
    )
    try expect(
        broker.contextReviews().first(where: { $0.id == oversizedReview.id })?.state == .draft,
        "rejected oversized approval mutated the durable draft"
    )
}

private func checkContextReviewShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let claudeToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let panes = [
        TmuxPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, windowID: "@0", returnToPaneID: nil),
        TmuxPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, windowID: "@0", returnToPaneID: nil),
    ]
    let submissions = LockedDelivery()
    let reviewStore = try AgentContextReviewStore(file: directory.appendingPathComponent("context-reviews.json"))
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { paneID, text in submissions.set(paneID: paneID, text: text, submit: true) },
        contextSubmit: { paneID, text in submissions.set(paneID: paneID, text: text, submit: true) },
        consultationTimeout: 3,
        contextReviewStore: reviewStore
    )
    let transportDirectory = RelayFileTransport.runtimeDirectory(applicationDirectory: directory)
    let shimDirectory = try RelayShim.install(in: directory, transportDirectory: transportDirectory)
    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: transportDirectory)
    try transport.start()
    defer { transport.stop() }
    let file = directory.appendingPathComponent("Parser.swift")
    try "let parser = Parser()\n".write(to: file, atomically: true, encoding: .utf8)
    let runner = ProcessCommandRunner(timeout: 4)
    let environment = ProcessInfo.processInfo.environment.merging([
        "PARLEY_RELAY_TOKEN": claudeToken,
    ]) { _, supplied in supplied }
    let staged = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "context", "draft", "--name", "Parser review", "--file", file.path],
        environment: environment,
        input: nil
    )
    try expect(staged.status == 0, "parley context draft failed: \(staged.stderrText)")
    let review = try JSONDecoder().decode(AgentContextReviewSummary.self, from: Data(staged.stdoutText.utf8))
    let listed = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "context", "list"],
        environment: environment,
        input: nil
    )
    try expect(listed.status == 0 && listed.stdoutText.contains(review.id), "parley context list omitted the staged draft")
    let shown = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "context", "show", review.id],
        environment: environment,
        input: nil
    )
    try expect(shown.status == 0 && shown.stdoutText.contains("let parser"), "parley context show omitted the staged content")

    let disposable = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "context", "draft", "--name", "Disposable", "--file", file.path],
        environment: environment,
        input: nil
    )
    let disposableReview = try JSONDecoder().decode(
        AgentContextReviewSummary.self,
        from: Data(disposable.stdoutText.utf8)
    )
    let discarded = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shimDirectory.appendingPathComponent("parley").path, "context", "discard", disposableReview.id],
        environment: environment,
        input: nil
    )
    try expect(
        discarded.status == 0,
        "parley context discard failed (\(discarded.status)): \(discarded.stdoutText)\(discarded.stderrText)"
    )
    try expect(
        broker.contextReviews().first(where: { $0.id == disposableReview.id })?.state == .discarded,
        "parley context discard did not reach the authenticated broker"
    )

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            let output = try ProcessCommandRunner(timeout: 5).run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [shimDirectory.appendingPathComponent("parley").path, "ask", "codex", "--context", review.id, "Review this parser."],
                environment: environment,
                input: nil
            )
            askResult.set(RelayTextResponse(status: Int(output.status), text: output.stdoutText + output.stderrText))
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }
    try expect(eventually { broker.contextReviews().first?.state == .awaitingReview }, "shim context Ask did not reach the review queue")
    var approvedPack = try require(broker.contextReviews().first, "shim context review disappeared").pack
    approvedPack.note = "Review this parser for correctness."
    try expect(broker.approveContextReview(reviewID: review.id, pack: approvedPack, targetPaneID: "%2").status == 200, "shim context Ask could not be approved")
    try expect(eventually { submissions.value != nil }, "approved shim context Ask was not submitted")
    try expect(broker.handleAnswer(token: codexToken, consultationID: "current", text: "Parser reviewed.").status == 200, "shim context Ask could not be answered")
    try expect(eventually { askResult.value != nil }, "shim context Ask did not return")
    try expect(askResult.value?.status == 0 && askResult.value?.text.contains("Parser reviewed") == true, "shim context Ask returned the wrong result")
}

let checks: [(String, () throws -> Void)] = [
    ("runtime namespaces are explicit and disjoint", checkRuntimeNamespacesAreExplicitAndDisjoint),
    ("useful copyable build information", checkBuildInformationIsUsefulAndCopyable),
    ("vendor-neutral local permission profiles", checkPermissionProfilesAreVendorNeutralAndLocal),
    ("safe permission profiles reach pane lifecycle", checkPermissionProfilesReachPaneLifecycleWithoutUnsafeFlags),
    ("vendor permission stops become passive attention", checkVendorPermissionStopsBecomeAttentionWithoutAction),
    ("runtime UI lease refuses duplicate owners", checkRuntimeUILeaseRefusesDuplicateOwners),
    ("child process cannot retain runtime UI lease", checkChildProcessCannotRetainRuntimeUILease),
    ("read-only runtime attachment requires prepared files", checkReadOnlyRuntimeAttachmentRequiresPreparedFiles),
    ("real production and development tmux isolation", checkRealProductionAndDevelopmentTmuxIsolation),
    ("UTF-8 locale fallback preserves explicit configuration", checkUTF8LocaleFallbackPreservesExplicitConfiguration),
    ("bootstrap", checkBootstrap),
    ("bootstrap recovers missing tmux identifiers", checkBootstrapRecoversMissingIdentifiers),
    ("existing session workspace adoption", checkExistingSessionAdoptsWorkspaceWithoutRestart),
    ("workspace lifecycle", checkWorkspaceLifecycle),
    ("workspace creation recovers missing tmux identifiers", checkWorkspaceCreationRecoversMissingIdentifiers),
    ("workspace creation cleans ambiguous pending windows", checkWorkspaceCreationCleansAmbiguousPendingWindow),
    ("workspace creation retries its exact pending target", checkWorkspaceCreationRetriesExactPendingTarget),
    ("workspace creation cleans an uncaptured exact target", checkWorkspaceCreationCleansPendingTargetWithoutCapturedIDs),
    ("existing sessions adopt only unclassified shells", checkExistingSessionAdoptsOnlyUnclassifiedShells),
    ("workspace continuity state", checkWorkspaceContinuityState),
    ("legacy packaged-app preferences migration", checkLegacyPreferencesMigration),
    ("quota-free runtime readiness probes", checkRuntimeReadinessProbesAreQuotaFree),
    ("truthful vendor compatibility and runtime signals", checkVendorCompatibilityAndRuntimeSignalsAreTruthful),
    ("explicit verified release lifecycle", checkReleaseLifecycleUsesExplicitVerifiedChannels),
    ("reviewed privacy-bounded beta feedback", checkBetaFeedbackBundleIsReviewedAndPrivacyBounded),
    ("privacy-bounded local diagnostics export", checkDiagnosticsExportIsUsefulAndPrivacyBounded),
    ("robust memory plateau assessment", checkMemoryPlateauAssessment),
    ("Git project context parsing", checkGitProjectContextParsing),
    ("Git worktree discovery parsing", checkGitWorktreeDiscoveryParsing),
    ("shared worktree writer collision projection", checkSharedWorktreeWriterCollisionProjection),
    ("authoritative workspace safety summary", checkWorkspaceSafetySummaryUsesOnlyAuthoritativeFacts),
    ("command palette search", checkCommandPaletteSearch),
    ("workbench accessibility descriptions", checkAccessibilityDescriptions),
    ("adjacent navigation order", checkAdjacentNavigationOrder),
    ("menu-safe periodic refresh", checkMenuTrackingRefreshPolicy),
    ("detailed in-app help coverage", checkInAppHelpGuideCoverage),
    ("workbench state projection", checkWorkbenchStateProjection),
    ("exited pane retention", checkExitedPaneRetention),
    ("embedded tmux presentation", checkEmbeddedTmuxPresentation),
    ("saved workspace layout persistence and fresh slots", checkSavedWorkspaceLayoutPersistenceAndFreshSlots),
    ("portable team template persistence and application", checkPortableTeamTemplatePersistenceAndApplication),
    ("deliberate pane mobility safety contract", checkPaneMobilitySafetyContract),
    ("external workspace open contract", checkExternalWorkspaceOpenContract),
    ("external editor context import contract", checkExternalEditorContextImportContract),
    ("content-free external attention and navigation contract", checkExternalAttentionAndNavigationContract),
    ("bounded menu bar attention inbox", checkMenuBarAttentionInboxProjection),
    ("tmux layout to ID-free saved tree", checkTmuxLayoutBecomesAnIDFreeSavedTree),
    ("active pane workspace scope", checkActivePaneIsScopedToSelectedWorkspace),
    ("direct agent argv", checkDirectAgentSpawn),
    ("mandatory pane-scoped agent process boundary", checkAgentProcessBoundaryIsMandatoryAndPaneScoped),
    ("stopped agent explicit start", checkStoppedAgentStartsOnlyThroughExplicitAction),
    ("shell pane login shell", checkShellPaneStartsLoginShell),
    ("real tmux shell lifecycle", checkRealTmuxShellLifecycle),
    ("real tmux pane mobility", checkRealTmuxPaneMobility),
    ("real macOS agent process boundary", checkRealAgentProcessBoundary),
    ("real tmux saved-layout restoration policy", checkRealTmuxSavedLayoutRestorationPolicy),
    ("inherited Parley capability scrub", checkInheritedParleyCapabilitiesAreScrubbed),
    ("shared protocol launch adapters", checkSharedProtocolLaunchAdapters),
    ("supervision metadata and editable recipes", checkSupervisionMetadataAndRecipesPersistWithoutLiveIDs),
    ("bounded supervised workflow lifecycle", checkBoundedSupervisedWorkflowLifecycle),
    ("readable handoff chains preserve exact evidence", checkReadableHandoffChainsPreserveEvidence),
    ("supervised lead workflow policy and cancellation", checkSupervisedLeadWorkflowPolicyAndCancellation),
    ("tracked delegation completion and wait", checkTrackedDelegationCompletesAndWaits),
    ("tracked delegation failure and liveness", checkTrackedDelegationFailureAndLiveness),
    ("tracked delegation shim round trip", checkDelegationShimRoundTrip),
    ("Copilot agent argv", checkCopilotAgentSpawn),
    ("Copilot trusted submission", checkCopilotSubmitUsesEnterAfterTrust),
    ("Copilot folder trust gate", checkCopilotTrustPromptRefusesSubmission),
    ("safe relay target gate", checkPasteRequiresRelayReadyBracketedTarget),
    ("Ask and route", checkAsk),
    ("Return and consume route", checkReturn),
    ("cross-vendor guard", checkCrossVendorGuard),
    ("relay cleaning", checkRelayCleaning),
    ("selection-or-empty relay draft", checkRelayDraftStartsWithSelectionOrNothing),
    ("bounded shell-free review drafts", checkReviewDraftsAreBoundedShellFreeAndExplicit),
    ("explicit bounded attributed context packs", checkContextPacksAreExplicitBoundedAndAttributed),
    ("vendor tool evidence is capability-gated and attributed", checkVendorToolEvidenceIsCapabilityGatedAndAttributed),
    ("durable explicitly attached workspace briefs", checkWorkspaceBriefsAreDurableAndExplicitlyAttached),
    ("durable reusable explicitly attached pinned context", checkPinnedContextSnippetsAreDurableReusableAndExplicit),
    ("agent context drafts require human approval", checkAgentContextDraftsRequireHumanApprovalBeforeAsk),
    ("concurrent context additions are atomic", checkConcurrentContextAddsRetainEveryAcceptedPart),
    ("context add racing Ask has one durable winner", checkContextAddRacingAskHasOneDurableWinner),
    ("context add racing completion has one durable winner", checkContextAddRacingCompletionHasOneDurableWinner),
    ("context draft discard is owned and bounded", checkContextDraftDiscardIsOwnedReleasesAskAndCleansUpStaleDrafts),
    ("direct context completion owns delivery state", checkDirectContextDraftCompletionOwnsDeliveryAndFailureState),
    ("trusted context capture preserves provenance", checkTrustedContextCaptureExtendsAgentDraftWithoutTrustingApproval),
    ("context review transport bounds and escaping", checkContextReviewTransportBoundsAndEscaping),
    ("context review shim round trip", checkContextReviewShimRoundTrip),
    ("authoritative Status Center projection", checkStatusCenterProjectionUsesOnlyAuthoritativeState),
    ("collaboration history search export and repeat", checkCollaborationHistorySearchExportAndRepeat),
    ("configurable history retention and workspace export", checkConfigurableHistoryRetentionAndWorkspaceExport),
    ("history retention core control route", checkHistoryRetentionCoreControlRoute),
    ("human Ask This Again tracked core-control route", checkHumanAskAgainUsesTrackedCoreControlRoute),
    ("in-app recovery guidance", checkRecoveryGuidanceProjectsKnownFailures),
    ("durable authoritative operational activity", checkOperationalActivityIsDurableAndAuthoritative),
    ("agent relay submits; paste does not", checkAgentRelaySubmitsAndExplicitPasteDoesNot),
    ("stable handoff identity and idempotent relay", checkStableHandoffIdentityAndIdempotentRelay),
    ("completed handoff retention bound", checkCompletedHandoffRetentionIsBounded),
    ("durable handoff journal", checkDurableHandoffJournal),
    ("workspace handoff history deletion", checkWorkspaceHandoffHistoryDeletion),
    ("cross-workspace relay addressing", checkCrossWorkspaceRelayAddressing),
    ("persistent relay identity", checkRelayCredentialPersistsAndIdentifiesSender),
    ("cross-process relay identity refresh", checkRelayCredentialReloadsExternalChanges),
    ("restart rotates relay credential", checkRestartRotatesRelayCredential),
    ("relay filesystem round trip", checkRelayFilesystemRoundTrip),
    ("relay shim filesystem transport", checkRelayShimUsesPinnedFilesystemTransport),
    ("protected filesystem relay runtime", checkRelayFilesystemRuntimeIsProtectedAndStopsCleanly),
    ("complete large core activity response", checkLargeCoreActivityResponseIsComplete),
    ("core control survives UI reattachment", checkCoreControlSurvivesClientReattachment),
    ("persistent core process survives UI exit", checkPersistentCoreProcessSurvivesClientExit),
    ("core restart interrupts wait and recovers", checkCoreRestartInterruptsWaitAndRecoversDiscovery),
    ("runtime-aware stable relay router", checkStableRouterSelectsRuntimeAndPreservesForeignCommands),
    ("agent Ask auto-submits and returns", checkAgentAskSubmitsAndBlocksUntilTheTargetAnswers),
    ("ask-many independent ordered fanout", checkAskManyFansOutIndependentlyAndReturnsAnOrderedBundle),
    ("ask-many comparison preserves independent attribution", checkAskManyComparisonDraftPreservesIndependentAttribution),
    ("human ask-many uses tracked broker path", checkHumanAskManyUsesTheTrackedBrokerPath),
    ("human ask-many core-control route", checkHumanAskManyCoreControlRoute),
    ("agent Ask busy target and timeout", checkAgentAskRejectsBusyTargetAndTimesOut),
    ("reviewed busy queue requires explicit human send", checkReviewedBusyQueueRequiresExplicitHumanSend),
    ("human Ask cancellation", checkHumanCancellationUnblocksAsk),
    ("safe failed-delivery retry", checkSafeFailedDeliveryRetryIsStableAndDeduplicated),
    ("uncertain and Ask retry refusal", checkUncertainAndAskFailuresCannotBeRetried),
    ("Ask dead-pane and target-restart recovery", checkAskDetectsDeadAndRestartedPanes),
    ("consultation shim round trip", checkConsultationShimRoundTrip),
    ("ask-many shim round trip", checkAskManyShimRoundTrip),
    ("Launch Services child-output capture", checkLaunchServicesCommandOutputCapture),
    ("child-process input and both output streams", checkCommandInputAndBothOutputStreams),
    ("daemon child cannot hold output capture open", checkDaemonizingCommandCannotHoldOutputCaptureOpen),
    ("child-process timeout", checkCommandTimeout),
    ("core startup timeout diagnostics", checkCoreStartupTimeoutReportsLastPhase),
    ("bundled core service resolution", checkBundledCoreServiceResolution),
    ("core service lifecycle", checkCoreServiceStopsCleanly),
    ("core service login launch configuration", checkCoreServiceLoginLaunchConfiguration),
    ("core service upgrade identity", checkCoreServiceUpgradeIdentity),
    ("core upgrade drain is atomic", checkCoreUpgradeDrainIsAtomic),
    ("core upgrade control round trip", checkCoreUpgradeControlRoundTrip),
    ("core uninstall stop control round trip", checkCoreUninstallStopControlRoundTrip),
    ("core uninstall transaction rollback", checkCoreUninstallTransactionRollback),
    ("persistent core seamless replacement", checkCoreUpgradeReplacesPersistentFixture),
    ("vendor conformance planning", checkVendorConformancePlanning),
    ("vendor conformance planning fails closed", checkVendorConformancePlanningFailsClosed),
    ("vendor conformance rejects exited panes", checkVendorConformanceRejectsExitedPanes),
    ("vendor conformance reporting", checkVendorConformanceReport),
    ("vendor conformance attention gate", checkVendorConformanceAttentionGate),
]

if let statePath = ProcessInfo.processInfo.environment["PARLEY_CORE_LIFECYCLE_FIXTURE"] {
    do {
        try "ready".write(toFile: statePath, atomically: true, encoding: .utf8)
        RelayServiceProcess.waitForTermination { signalNumber in
            try? "stopped \(signalNumber)".write(toFile: statePath, atomically: true, encoding: .utf8)
            exit(0)
        }
    } catch {
        FileHandle.standardError.write(Data("Lifecycle fixture failed: \(error)\n".utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["PARLEY_CORE_HANG_FIXTURE"] == "1" {
    FileHandle.standardError.write(Data("fixture reached startup\n".utf8))
    Thread.sleep(forTimeInterval: 5)
    exit(0)
}

if let readyPath = ProcessInfo.processInfo.environment["PARLEY_UI_LEASE_CHILD_FIXTURE"] {
    try? "ready".write(toFile: readyPath, atomically: true, encoding: .utf8)
    Thread.sleep(forTimeInterval: 1)
    exit(0)
}

if ProcessInfo.processInfo.environment["PARLEY_COMMAND_IO_FIXTURE"] == "1" {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    FileHandle.standardOutput.write(Data("stdout:".utf8) + input)
    FileHandle.standardError.write(Data("stderr:".utf8) + input)
    exit(23)
}

if ProcessInfo.processInfo.environment["PARLEY_DELAYED_OUTPUT_CHILD"] == "1" {
    usleep(50_000)
    _ = "daemon-ready".withCString { pointer in
        Darwin.write(STDOUT_FILENO, pointer, strlen(pointer))
    }
    sleep(2)
    exit(0)
}

if ProcessInfo.processInfo.environment["PARLEY_DAEMON_OUTPUT_FIXTURE"] == "1" {
    let executable = CommandLine.arguments[0]
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
    var childEnvironment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
        .map { strdup("\($0.key)=\($0.value)") }
    childEnvironment.append(strdup("PARLEY_DELAYED_OUTPUT_CHILD=1"))
    childEnvironment.append(nil)
    defer {
        for argument in arguments.dropLast() {
            if let argument { free(argument) }
        }
        for variable in childEnvironment.dropLast() {
            if let variable { free(variable) }
        }
    }
    var child = pid_t()
    let spawnStatus = executable.withCString { path in
        arguments.withUnsafeMutableBufferPointer { buffer in
            childEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(&child, path, nil, nil, buffer.baseAddress!, environmentBuffer.baseAddress!)
            }
        }
    }
    guard spawnStatus == 0 else { exit(1) }
    exit(0)
}

if let resultPath = ProcessInfo.processInfo.environment["PARLEY_COMMAND_CAPTURE_PROBE_RESULT"] {
    let application = NSApplication.shared
    let delegate = CommandCaptureProbeDelegate(resultPath: resultPath)
    application.delegate = delegate
    application.run()
    exit(FileManager.default.fileExists(atPath: resultPath) ? 0 : 1)
}

if ProcessInfo.processInfo.environment["PARLEY_UI_FIXTURE"] == "1" {
    do {
        try runUIFixture()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Fixture UI failed: \(error)\n".utf8))
        exit(1)
    }
}

if ProcessInfo.processInfo.environment["PARLEY_CORE_FIXTURE"] == "1" {
    do {
        try runCoreServiceFixture()
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Fixture core failed: \(error)\n".utf8))
        exit(1)
    }
}

var failureCount = 0
for (name, check) in checks {
    do {
        try check()
        print("PASS \(name)")
    } catch {
        failureCount += 1
        print("FAIL \(name): \(error)")
    }
}

guard failureCount == 0 else {
    print("\(failureCount) native check(s) failed")
    exit(1)
}
print("All \(checks.count) native checks passed")
