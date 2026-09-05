import AppKit
import Darwin
import Dispatch
import Foundation
import GhosttyTerminal
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
private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        lock.withLock { storage }
    }

    func set(_ value: String) {
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
    private var storage: [WorkbenchPane]

    init(_ panes: [WorkbenchPane]) {
        storage = panes
    }

    var value: [WorkbenchPane] {
        lock.withLock { storage }
    }

    func set(_ panes: [WorkbenchPane]) {
        lock.withLock { storage = panes }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func checkTerminalFontPreferenceIsBoundedAndSafe() throws {
    let preference = try TerminalFontPreference(family: "  SF Mono  ", size: 15.5)
    try expect(preference.family == "SF Mono", "terminal font family whitespace was not normalized")
    try expect(preference.size == 15.5, "terminal font size was not preserved")

    let defaults = try TerminalFontPreference()
    try expect(defaults.family == nil && defaults.size == nil, "Ghostty defaults were not representable")
    let encoded = try JSONEncoder().encode(preference)
    let decoded = try JSONDecoder().decode(TerminalFontPreference.self, from: encoded)
    try expect(
        decoded == preference,
        "terminal font preference did not round trip"
    )

    for invalidFamily in ["Line\nBreak", "Control\u{0000}Character"] {
        do {
            _ = try TerminalFontPreference(family: invalidFamily, size: 14)
            throw CheckFailure(description: "an unsafe terminal font family was accepted")
        } catch let error as TerminalFontPreferenceError {
            try expect(error == .invalidFamily, "an unsafe family failed for the wrong reason")
        }
    }
    for invalidSize in [7.9, 72.1, Double.infinity, Double.nan] {
        do {
            _ = try TerminalFontPreference(family: nil, size: invalidSize)
            throw CheckFailure(description: "an unsafe terminal font size was accepted")
        } catch let error as TerminalFontPreferenceError {
            try expect(error == .invalidSize, "an unsafe size failed for the wrong reason")
        }
    }
}

private func checkGhosttyAppearanceImportIsStrictlyAllowlisted() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let xdg = root.appendingPathComponent("xdg", isDirectory: true)
    let xdgGhostty = xdg.appendingPathComponent("ghostty", isDirectory: true)
    let themes = xdgGhostty.appendingPathComponent("themes", isDirectory: true)
    let appSupportGhostty = home
        .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty", isDirectory: true)
    try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appSupportGhostty, withIntermediateDirectories: true)

    let xdgConfig = xdgGhostty.appendingPathComponent("config.ghostty")
    try """
    font-family = \"  JetBrains Mono  \"
    font-size = 13.5
    theme = \"light:Custom Safe,dark:Safe Dark\"
    background = #010203
    palette = 1=#111111
    keybind = global:cmd+x=close_all_windows
    command = /bin/sh -c dangerous
    config-file = included.conf
    background-opacity = 0.5
    cursor-style-blink = false
    """.write(to: xdgConfig, atomically: true, encoding: .utf8)
    try "background = #deadbe\n".write(
        to: xdgGhostty.appendingPathComponent("included.conf"),
        atomically: true,
        encoding: .utf8
    )
    let customTheme = themes.appendingPathComponent("Custom Safe")
    try """
    background = #fefefe
    foreground = #121212
    cursor-color = #232323
    palette = 5=#555555
    command = should-never-enter-parley
    keybind = ctrl+x=close_surface
    """.write(to: customTheme, atomically: true, encoding: .utf8)

    let appConfig = appSupportGhostty.appendingPathComponent("config")
    try """
    font-size = 15
    foreground = #abcdef
    palette = 1=#222222
    palette = 2=#333333
    shell-integration = none
    """.write(to: appConfig, atomically: true, encoding: .utf8)

    let imported = try GhosttyAppearanceImporter.load(
        homeDirectory: home,
        environment: ["XDG_CONFIG_HOME": xdg.path],
        builtInTheme: { name in
            guard name == "Safe Dark" else { return nil }
            return GhosttyAppearanceColors(
                background: "#000000",
                foreground: "#eeeeee",
                cursorColor: "#dddddd",
                palette: [1: "#bbbbbb", 6: "#666666"]
            )
        }
    )

    try expect(imported.fontFamily == "JetBrains Mono", "imported font family was not normalized")
    try expect(imported.fontSize == 15, "later Ghostty font size did not win")
    try expect(
        imported.themeDescription == "light:Custom Safe,dark:Safe Dark",
        "light/dark Ghostty theme selection was not preserved"
    )
    try expect(imported.light.background == "#010203", "direct background did not override the light theme")
    try expect(imported.dark.background == "#010203", "direct background did not override the dark theme")
    try expect(imported.light.foreground == "#abcdef", "later direct foreground did not override the light theme")
    try expect(imported.dark.foreground == "#abcdef", "later direct foreground did not override the dark theme")
    try expect(imported.light.cursorColor == "#232323", "custom theme cursor colour was not imported")
    try expect(imported.dark.cursorColor == "#dddddd", "built-in theme cursor colour was not imported")
    try expect(imported.light.palette[1] == "#222222", "direct palette did not override the custom theme")
    try expect(imported.dark.palette[1] == "#222222", "direct palette did not override the built-in theme")
    try expect(imported.light.palette[2] == "#333333", "direct palette entry was not applied to the light theme")
    try expect(imported.dark.palette[2] == "#333333", "direct palette entry was not applied to the dark theme")
    try expect(imported.light.palette[5] == "#555555", "custom theme palette entry was lost")
    try expect(imported.dark.palette[6] == "#666666", "built-in theme palette entry was lost")
    try expect(imported.ignoredSettingCount >= 7, "excluded behavioral Ghostty settings were not counted")
    try expect(imported.importedSettingCount >= 12, "appearance import did not report its bounded settings")
    try expect(imported.sourceFiles.contains(canonicalPath(xdgConfig.path)), "XDG Ghostty config source was not recorded")
    try expect(imported.sourceFiles.contains(canonicalPath(appConfig.path)), "macOS Ghostty config source was not recorded")
    try expect(imported.sourceFiles.contains(canonicalPath(customTheme.path)), "custom Ghostty theme source was not recorded")
    try expect(
        !imported.sourceFiles.contains(canonicalPath(xdgGhostty.appendingPathComponent("included.conf").path)),
        "appearance import followed a forbidden config-file include"
    )

    let encoded = try JSONEncoder().encode(imported)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    for excluded in ["/bin/sh", "close_all_windows", "should-never-enter-parley", "included.conf"] {
        try expect(!encodedText.contains(excluded), "excluded Ghostty behavior leaked into persisted appearance data")
    }
    let decoded = try JSONDecoder().decode(GhosttyAppearanceImport.self, from: encoded)
    try expect(
        decoded == imported,
        "Ghostty appearance import did not round trip"
    )

    let explicitFamily = try TerminalFontPreference(family: "SF Mono", size: nil)
        .resolving(imported: imported)
    try expect(explicitFamily.family == "SF Mono", "Parley's explicit font family did not override Ghostty")
    try expect(explicitFamily.size == 15, "Ghostty font size did not fill an unset Parley override")
    let explicitSize = try TerminalFontPreference(family: nil, size: 18)
        .resolving(imported: imported)
    try expect(explicitSize.family == "JetBrains Mono", "Ghostty font family did not fill an unset Parley override")
    try expect(explicitSize.size == 18, "Parley's explicit font size did not override Ghostty")

    do {
        _ = try GhosttyAppearanceImporter.load(
            homeDirectory: root.appendingPathComponent("empty-home", isDirectory: true),
            environment: [:],
            builtInTheme: { _ in nil }
        )
        throw CheckFailure(description: "a missing Ghostty configuration was accepted")
    } catch let error as GhosttyAppearanceImportError {
        try expect(error == .configurationNotFound, "a missing Ghostty configuration failed for the wrong reason")
    }
}

private func checkPaneStateUsesDurableWorkspaceAndGhosttyInputIdentity() throws {
    let pane = WorkbenchPane(
        id: "pane-current",
        kind: .codex,
        customName: "Reviewer",
        terminalTitle: "Codex",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        workspaceID: "workspace-current",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        inputAvailable: true,
        isStarted: true
    )
    let encoded = try JSONEncoder().encode(pane)
    let encodedText = String(decoding: encoded, as: UTF8.self)
    try expect(encodedText.contains("workspaceID"), "pane state omitted durable workspace identity")
    try expect(encodedText.contains("inputAvailable"), "pane state omitted Ghostty input availability")
    try expect(!encodedText.contains("windowID"), "new pane state still writes the tmux window alias")
    try expect(!encodedText.contains("returnToPaneID"), "new pane state still writes the pre-broker return route")
    try expect(!encodedText.contains("bracketedPasteActive"), "new pane state still writes tmux paste readiness")

    let legacy = Data(#"""
    {
        "id":"pane-legacy",
        "kind":"codex",
        "customName":null,
        "terminalTitle":"Codex",
        "cwd":"/tmp",
        "currentCommand":"codex",
        "isActive":true,
        "windowID":"workspace-legacy",
        "returnToPaneID":"pane-source",
        "relayEnabled":true,
        "protocolVersion":"old",
        "workspaceName":"Legacy",
        "bracketedPasteActive":true,
        "isDead":false,
        "exitStatus":null,
        "isStarted":true,
        "isWorkspaceLead":false,
        "role":null,
        "automationPolicy":"askAndDelegate",
        "permissionSelection":null,
        "permissionEnforcement":null,
        "launchGeneration":0
    }
    """#.utf8)
    let migrated = try JSONDecoder().decode(WorkbenchPane.self, from: legacy)
    try expect(migrated.workspaceID == "workspace-legacy", "legacy window identity was not migrated once")
    try expect(!migrated.inputAvailable, "persisted tmux paste state was trusted as live Ghostty input state")
}

private func checkAutomaticUpdatesAreProductionSignedAndOptIn() throws {
    let home = URL(fileURLWithPath: "/tmp/parley-update-check-home", isDirectory: true)
    let production = ParleyRuntime.make(mode: .production, homeDirectory: home)
    let development = ParleyRuntime.make(mode: .development, homeDirectory: home)
    let publicKey = Data(repeating: 7, count: 32).base64EncodedString()
    let signedInfo: [String: Any] = [
        "SUFeedURL": AutomaticUpdateConfiguration.expectedFeedURL.absoluteString,
        "SUPublicEDKey": publicKey,
        "SURequireSignedFeed": true,
        "SUVerifyUpdateBeforeExtraction": true,
        "SUAllowsAutomaticUpdates": false,
        "SUEnableAutomaticChecks": false,
        "SUAutomaticallyUpdate": false,
        "SUEnableSystemProfiling": false,
    ]

    let configuration = AutomaticUpdateConfiguration.resolve(
        runtime: production,
        infoDictionary: signedInfo
    )
    try expect(configuration?.publicKey == publicKey, "signed Production update configuration was unavailable")
    try expect(
        configuration?.checksEnabledByDefault == false,
        "automatic update checks were not opt-in"
    )
    try expect(
        AutomaticUpdateConfiguration.resolve(runtime: development, infoDictionary: signedInfo) == nil,
        "Development runtime exposed Production automatic updates"
    )
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"] {
        var weakened = signedInfo
        weakened[key] = false
        try expect(
            AutomaticUpdateConfiguration.resolve(runtime: production, infoDictionary: weakened) == nil,
            "automatic updates accepted weakened \(key)"
        )
    }
    var silentInstall = signedInfo
    silentInstall["SUAllowsAutomaticUpdates"] = true
    try expect(
        AutomaticUpdateConfiguration.resolve(runtime: production, infoDictionary: silentInstall) == nil,
        "automatic updates accepted background download and installation"
    )
    var profiled = signedInfo
    profiled["SUEnableSystemProfiling"] = true
    try expect(
        AutomaticUpdateConfiguration.resolve(runtime: production, infoDictionary: profiled) == nil,
        "automatic updates accepted system profiling"
    )
    var wrongFeed = signedInfo
    wrongFeed["SUFeedURL"] = "https://example.invalid/appcast.xml"
    try expect(
        AutomaticUpdateConfiguration.resolve(runtime: production, infoDictionary: wrongFeed) == nil,
        "automatic updates accepted a different feed origin"
    )
}

private func checkApplicationSettingsSectionsAreComplete() throws {
    try expect(
        ApplicationSettingsSection.allCases.map(\.rawValue) == [
            "general",
            "appearance",
            "notifications",
        ],
        "the native Settings window lost or reordered a required section"
    )
    try expect(
        ApplicationSettingsSection.allCases.map(\.title) == [
            "General",
            "Appearance",
            "Notifications",
        ],
        "the native Settings sections lost their user-facing labels"
    )
}

private func checkNativeAskRequestCarriesFormattingIntent() throws {
    let request = RelayUIAskRequest(
        sourcePaneID: "pane-source",
        targetPaneID: "pane-target",
        text: "line one\n  line two",
        idempotencyKey: "ask-key",
        preserveFormatting: true
    )
    let decoded = try JSONDecoder().decode(
        RelayUIAskRequest.self,
        from: JSONEncoder().encode(request)
    )
    try expect(decoded.preserveFormatting == true, "native tracked Ask lost reviewed formatting intent")
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
    try expect(failSafeDevelopment.mode == .development, "an unbundled executable silently fell into production")
    try expect(bundledIgnoresDevelopmentOverride.mode == .production, "an argument moved the installed app out of production")
    try expect(production.applicationDirectory != development.applicationDirectory, "production and development share Application Support")
    try expect(production.preferenceSuiteName != development.preferenceSuiteName, "production and development share preferences")
    try expect(production.visibleMarker == nil, "production displays a development marker")
    try expect(development.visibleMarker == "DEV", "development is not permanently marked")
    try expect(production.installsStableCommand && !development.installsStableCommand, "a development runtime can replace the stable relay command")
}

private func checkRuntimeTerminationChoiceSurvivesDeadAgents() throws {
    let home = URL(fileURLWithPath: "/Users/runtime-termination-test", isDirectory: true)
    let production = ParleyRuntime.make(mode: .production, homeDirectory: home)
    let development = ParleyRuntime.make(mode: .development, homeDirectory: home)

    try expect(
        RuntimeTerminationPolicy.shouldOfferChoice(
            runtime: production,
            controllerAvailable: true
        ),
        "Production hid Stop Everything when no live agent remained"
    )
    try expect(
        RuntimeTerminationPolicy.shouldOfferChoice(
            runtime: development,
            controllerAvailable: true
        ),
        "Development hid Stop Everything when every agent was dead"
    )
    try expect(
        !RuntimeTerminationPolicy.shouldOfferChoice(
            runtime: development,
            controllerAvailable: false
        ),
        "Development offered a runtime action without a controller"
    )
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
        builtIns.map(\.id) == ["review-only", "default", "flexible", "workspace-folders", "broad-workspace"],
        "permission profile built-ins or their stable order changed"
    )
    try expect(builtIns.allSatisfy(\.isBuiltIn), "a built-in permission profile is editable")

    let review = try require(builtIns.first(where: { $0.id == "review-only" }), "Review Only is missing")
    let standard = try require(builtIns.first(where: { $0.id == "default" }), "Default is missing")
    let flexible = try require(builtIns.first(where: { $0.id == "flexible" }), "Flexible is missing")
    let workspaceFolders = try require(
        builtIns.first(where: { $0.id == "workspace-folders" }),
        "Workspace Folders is missing"
    )
    let broad = try require(builtIns.first(where: { $0.id == "broad-workspace" }), "Broad Workspace is missing")

    try expect(review.rule(for: .projectRead) == .allow, "Review Only cannot read the project")
    try expect(review.rule(for: .projectWrite) == .deny, "Review Only can mutate the project")
    try expect(standard.rule(for: .projectWrite) == .requireApproval, "Default silently grants project writes")
    try expect(flexible.rule(for: .projectWrite) == .allow, "Flexible cannot perform approved project writes")
    try expect(flexible.rule(for: .projectToolExecution) == .allow, "Flexible cannot run project tests and builds")
    try expect(flexible.rule(for: .networkAccess) == .requireApproval, "Flexible silently grants network access")
    try expect(workspaceFolders.rootMode == .exactApprovedRoots, "Workspace Folders does not require exact roots")
    try expect(workspaceFolders.rule(for: .projectWrite) == .allow, "Workspace Folders cannot perform project writes")
    try expect(workspaceFolders.rule(for: .projectToolExecution) == .allow, "Workspace Folders cannot run project tools")
    try expect(
        workspaceFolders.rule(for: .localProcessExecution) == .requireApproval,
        "Workspace Folders silently gained Broad Workspace process authority"
    )
    try expect(workspaceFolders.defaultLifetime == .session, "Workspace Folders silently persists as a vendor default")
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
    let external = root.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)

    let folderAccess = WorkspaceFolderAccessProjection.project(
        paneFolder: project.path,
        workspaceFolders: [project.path, sibling.path, "\(sibling.path)/"],
        approvedRoots: [project.path, sibling.path, external.path]
    )
    try expect(
        folderAccess.workspaceFolders == [
            WorkspaceFolderAccessOption(path: WorkspaceFolderIdentity.normalized(project.path), isPaneFolder: true, isApproved: true),
            WorkspaceFolderAccessOption(path: WorkspaceFolderIdentity.normalized(sibling.path), isPaneFolder: false, isApproved: true),
        ],
        "workspace attachment access did not preserve exact ordered checked state"
    )
    try expect(
        folderAccess.otherApprovedRoots == [WorkspaceFolderIdentity.normalized(external.path)],
        "manually approved roots were confused with workspace attachments"
    )

    let workspaceEffective = try PermissionProfileResolver.resolve(
        definition: workspaceFolders,
        paneFolder: project.path,
        approvedRoots: [project.path, sibling.path]
    )
    let workspaceLaunch = PermissionProfileAdapter.launchPlan(
        for: .codex,
        profile: workspaceEffective
    )
    try expect(
        workspaceLaunch.arguments == [
            "--sandbox", "workspace-write", "--ask-for-approval", "on-request",
            "--add-dir", canonicalPath(project.path),
            "--add-dir", canonicalPath(sibling.path),
        ],
        "reviewed workspace folders did not become exact vendor launch roots"
    )

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
    try expect(loaded.count == 6, "a saved custom profile was not returned beside built-ins")
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

private func checkTaskManagerProjectionIsPaneOwnedAndTruthful() throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let sampledAt = Date(timeIntervalSince1970: 200)
    let raw = [
        TaskManagerRawProcess(
            pid: 1, parentPID: 0, processGroupID: 1, ttyDevice: nil,
            name: "Parley", residentBytes: 100, totalCPUTimeNanoseconds: 4_000_000_000,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 10, parentPID: 1, processGroupID: 10, ttyDevice: 42,
            name: "zsh", residentBytes: 20, totalCPUTimeNanoseconds: 2_000_000_000,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 11, parentPID: 10, processGroupID: 10, ttyDevice: 42,
            name: "codex", residentBytes: 30, totalCPUTimeNanoseconds: 3_000_000_000,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 20, parentPID: 1, processGroupID: 20, ttyDevice: 43,
            name: "claude", residentBytes: 40, totalCPUTimeNanoseconds: 5_000_000_000,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 99, parentPID: 1, processGroupID: 99, ttyDevice: 99,
            name: "unrelated", residentBytes: 9_999, totalCPUTimeNanoseconds: 99_000_000_000,
            startedAt: startedAt
        ),
    ]
    let panes = [
        TaskManagerPaneDescriptor(
            paneID: "%1", workspaceID: "workspace-a", workspaceName: "Build",
            paneName: "Codex", kind: .codex, workingDirectory: "/repo",
            isSelected: true, isStarted: true, foregroundPID: 10,
            ttyName: "/dev/ttys001", ttyDevice: 42
        ),
        TaskManagerPaneDescriptor(
            paneID: "%2", workspaceID: "workspace-a", workspaceName: "Build",
            paneName: "Claude", kind: .claude, workingDirectory: "/repo",
            isSelected: false, isStarted: true, foregroundPID: 20,
            ttyName: "/dev/ttys002", ttyDevice: 43
        ),
        TaskManagerPaneDescriptor(
            paneID: "%3", workspaceID: "workspace-b", workspaceName: "Review",
            paneName: "Stopped", kind: .agy, workingDirectory: "/review",
            isSelected: false, isStarted: false, foregroundPID: nil,
            ttyName: nil, ttyDevice: nil
        ),
    ]
    let previousCPU = Dictionary(uniqueKeysWithValues: [
        (TaskManagerProcessIdentity(pid: 1, startedAt: startedAt), UInt64(3_000_000_000)),
        (TaskManagerProcessIdentity(pid: 10, startedAt: startedAt), UInt64(1_500_000_000)),
        (TaskManagerProcessIdentity(pid: 11, startedAt: startedAt), UInt64(2_500_000_000)),
        (TaskManagerProcessIdentity(pid: 20, startedAt: startedAt), UInt64(4_000_000_000)),
    ])

    let snapshot = TaskManagerProjection.project(
        applicationPID: 1,
        paneDescriptors: panes,
        rawProcesses: raw,
        previousCPUTimeByProcess: previousCPU,
        elapsedSeconds: 2,
        sampledAt: sampledAt
    )
    try expect(snapshot.application?.residentBytes == 100, "Task Manager lost the app RSS sample")
    try expect(snapshot.application?.cpuPercent == 50, "Task Manager app CPU did not use a time delta")
    try expect(snapshot.childResidentBytes == 90, "Task Manager child RSS included unrelated processes or lost owned ones")
    try expect(snapshot.processCount == 4, "Task Manager process count was not app plus unique pane processes")
    try expect(snapshot.workspaces.map(\.name) == ["Build", "Review"], "Task Manager lost durable workspace grouping")

    let build = try require(snapshot.workspaces.first, "Task Manager omitted the first workspace")
    let codex = try require(build.panes.first, "Task Manager omitted the first pane")
    try expect(codex.residentBytes == 50 && codex.cpuPercent == 50, "pane totals were not the sum of its exact TTY processes")
    try expect(
        codex.processes.map(\.pid) == [10, 11] && codex.processes.map(\.depth) == [0, 1],
        "Task Manager process hierarchy did not follow parent-child ownership"
    )
    try expect(build.panes[1].processes.map(\.pid) == [20], "a second pane did not retain its exact process")
    try expect(snapshot.workspaces[1].panes[0].processes.isEmpty, "a stopped pane invented a process")
    try expect(!snapshot.programTotals.contains(where: { $0.name == "unrelated" }), "unowned host work entered program totals")
    try expect(
        snapshot.programTotals.first(where: { $0.name == "codex" })?.residentBytes == 30,
        "program totals lost an owned process"
    )

    let firstSample = TaskManagerProjection.project(
        applicationPID: 1,
        paneDescriptors: panes,
        rawProcesses: raw,
        previousCPUTimeByProcess: [:],
        elapsedSeconds: nil,
        sampledAt: sampledAt
    )
    try expect(firstSample.totalCPUPercent == nil, "a first sample invented instantaneous CPU usage")

    let liveSample = TaskManagerSampler().sample(
        applicationPID: ProcessInfo.processInfo.processIdentifier,
        paneDescriptors: []
    )
    try expect(liveSample.application?.pid == ProcessInfo.processInfo.processIdentifier, "the macOS sampler could not read its own process")
    try expect(liveSample.processCount == 1, "a sampler without panes included unrelated host processes")
}

private func checkSidebarWorkspaceFactsAreOwnedBoundedAndThrottled() throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let sampledAt = Date(timeIntervalSince1970: 200)
    let raw = [
        TaskManagerRawProcess(
            pid: 10, parentPID: 1, processGroupID: 10, ttyDevice: 42,
            name: "zsh", residentBytes: 20, totalCPUTimeNanoseconds: 0,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 11, parentPID: 10, processGroupID: 10, ttyDevice: 42,
            name: "node", residentBytes: 30, totalCPUTimeNanoseconds: 0,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 20, parentPID: 1, processGroupID: 20, ttyDevice: 43,
            name: "python", residentBytes: 40, totalCPUTimeNanoseconds: 0,
            startedAt: startedAt
        ),
        TaskManagerRawProcess(
            pid: 99, parentPID: 1, processGroupID: 99, ttyDevice: 99,
            name: "unrelated", residentBytes: 50, totalCPUTimeNanoseconds: 0,
            startedAt: startedAt
        ),
    ]
    let descriptors = [
        TaskManagerPaneDescriptor(
            paneID: "%1", workspaceID: "workspace-a", workspaceName: "Build",
            paneName: "Codex", kind: .codex, workingDirectory: "/repo/api",
            isSelected: true, isStarted: true, foregroundPID: 10,
            ttyName: "/dev/ttys001", ttyDevice: 42
        ),
        TaskManagerPaneDescriptor(
            paneID: "%2", workspaceID: "workspace-a", workspaceName: "Build",
            paneName: "Claude", kind: .claude, workingDirectory: "/repo/web",
            isSelected: false, isStarted: true, foregroundPID: 20,
            ttyName: "/dev/ttys002", ttyDevice: 43
        ),
    ]
    let processIDs = TaskManagerProjection.ownedProcessIDs(
        applicationPID: 1,
        paneDescriptors: descriptors,
        rawProcesses: raw
    )
    try expect(processIDs["%1"] == Set([10, 11]), "sidebar port ownership lost a pane child process")
    try expect(processIDs["%2"] == Set([20]), "sidebar port ownership lost the second pane")
    try expect(!processIDs.values.contains(where: { $0.contains(99) }), "sidebar port ownership admitted an unrelated process")
    let ownedProcesses = TaskManagerProjection.ownedProcesses(
        applicationPID: 1,
        paneDescriptors: descriptors,
        rawProcesses: raw
    )

    let arguments = try require(
        PaneListeningPortProjection.commandArguments(ownedProcesses: ownedProcesses),
        "owned process ids produced no fixed lsof arguments"
    )
    try expect(
        arguments == ["-nP", "-a", "-p", "20,11,10", "-iTCP", "-sTCP:LISTEN", "-Fpn"],
        "sidebar listening-port inspection drifted from its bounded fixed-argument command"
    )
    try expect(!arguments.contains(where: { $0.contains("/bin/sh") || $0.contains("\n") }), "sidebar port inspection introduced a shell or multiline argument")

    let lsof = """
    p10
    n*:3000
    n127.0.0.1:3000
    p11
    n[::1]:8080
    n*:70000
    p20
    n*:4173
    p99
    n*:9999
    """
    let snapshot = PaneListeningPortProjection.snapshot(
        ownedProcesses: ownedProcesses,
        lsofOutput: lsof,
        sampledAt: sampledAt
    )
    try expect(snapshot.portsByPaneID["%1"] == [3000, 8080], "sidebar ports were not deduplicated and attributed to the exact pane tree")
    try expect(snapshot.portsByPaneID["%2"] == [4173], "sidebar ports lost the second pane's listener")
    try expect(!snapshot.portsByPaneID.values.contains(where: { $0.contains(9999) }), "an unrelated host listener entered sidebar facts")

    let pane = WorkbenchPane(
        id: "%1", kind: .codex, customName: "Codex", terminalTitle: "",
        cwd: "/repo/api", currentCommand: "codex", isActive: true,
        workspaceID: "workspace-a"
    )
    let older = PaneAttentionItem(
        id: "older", paneID: "%1", handoffID: "handoff-a",
        reason: .returnedResult, source: .durableHandoff,
        occurredAt: Date(timeIntervalSince1970: 180)
    )
    let latest = PaneAttentionItem(
        id: "latest", paneID: "%1", handoffID: nil,
        reason: .permissionRequest, source: .vendorOfficialHook,
        occurredAt: Date(timeIntervalSince1970: 190)
    )
    let unrelated = PaneAttentionItem(
        id: "unrelated", paneID: "%2", handoffID: nil,
        reason: .interruptedHandoff, source: .durableHandoff,
        occurredAt: Date(timeIntervalSince1970: 195)
    )
    let facts = PaneSidebarFactsProjection.facts(
        for: pane,
        projectContext: GitProjectContext(branch: "feat/sidebar-facts", isDirty: true),
        listeningPortSnapshot: snapshot,
        attentionItems: [older, unrelated, latest]
    )
    try expect(facts.workingDirectory == "/repo/api", "sidebar facts did not use the pane-owned cwd")
    try expect(facts.gitContext?.branch == "feat/sidebar-facts" && facts.gitContext?.isDirty == true, "sidebar facts lost fixed-argument Git state")
    try expect(facts.listeningPorts == [3000, 8080], "sidebar facts lost attributed listener ports")
    try expect(facts.latestAttention == latest, "sidebar facts did not select the latest exact-pane authoritative attention reason")

    let manyPorts = (1...20).map { "n*:\($0)" }.joined(separator: "\n")
    let bounded = PaneListeningPortProjection.snapshot(
        ownedProcesses: ["%1": [raw[0]]],
        lsofOutput: "p10\n\(manyPorts)",
        sampledAt: sampledAt
    )
    try expect(
        bounded.portsByPaneID["%1"]?.count == PaneListeningPortProjection.maximumPortsPerPane,
        "sidebar facts did not bound the number of rendered listeners"
    )
    try expect(
        !PaneListeningPortRefreshPolicy.shouldRefresh(
            lastSampledAt: Date(timeIntervalSince1970: 195),
            now: sampledAt,
            inputsChanged: false,
            isRefreshing: false
        ),
        "sidebar facts ignored their refresh throttle"
    )
    try expect(
        PaneListeningPortRefreshPolicy.shouldRefresh(
            lastSampledAt: Date(timeIntervalSince1970: 195),
            now: sampledAt,
            inputsChanged: true,
            isRefreshing: false
        ),
        "sidebar facts did not refresh when pane process ownership changed"
    )
    try expect(
        !PaneListeningPortRefreshPolicy.shouldRefresh(
            lastSampledAt: .distantPast,
            now: sampledAt,
            inputsChanged: true,
            isRefreshing: true
        ),
        "sidebar facts started overlapping process inspection"
    )
}

private func checkVendorPermissionStateIsNotInferredFromTerminalText() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = WorkbenchPane(
        id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp",
        currentCommand: "claude", isActive: true, workspaceID: "@0"
    )
    let target = WorkbenchPane(
        id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp",
        currentCommand: "codex", isActive: false, workspaceID: "@0"
    )
    let submissions = LockedCounter()
    let terminalReads = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { [source, target] },
        paste: { _, _ in },
        submit: { _, _ in submissions.increment() },
        selectedText: { _ in
            terminalReads.increment()
            return "Would you like to run the following command?\nAllow once"
        },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let result = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        result.set(broker.handleAsk(token: sourceToken, target: "codex", text: "Review this change."))
    }

    try expect(eventually { submissions.value == 1 }, "the Ask was not submitted")
    Thread.sleep(forTimeInterval: 0.05)
    let waiting = try require(broker.handoffs().first, "waiting handoff disappeared")
    try expect(waiting.state == .waiting, "terminal prose ended the waiting consultation")
    try expect(waiting.attention == nil, "terminal prose was presented as authoritative permission state")
    try expect(terminalReads.value == 0, "the broker scraped terminal text to infer permission state")
    try expect(result.value == nil, "terminal prose released the blocked requester")

    let answered = broker.handleAnswer(
        token: targetToken,
        consultationID: "current",
        text: "The review is complete."
    )
    try expect(answered.status == 200, "consultation could not answer normally")
    try expect(eventually { result.value?.status == 200 }, "answer did not release the Ask")
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
        "split-window", "join-pane", "capture-pane", "copy-mode", "bind-key", "load-buffer", "paste-buffer", "send-keys",
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
        "parley whoami", "parley panes", "parley events --since beginning",
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
        "investigation conclusions", "person-authored confidence",
        "authenticated identity", "content-minimal coordination events",
        "cursor removed by retention",
        "context pack from selected results", "no handoff is submitted automatically",
        "human decision", "team template",
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
        "folderless workspaces", "attached folders", "new pane folder", "split right here", "open new workspace here",
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
        "runtime state stays unknown", "terminal prose, silence", "vendor's release notes",
        "stable selects published non-prereleases", "sha256sums", "download and verify",
        "does not install", "review beta feedback", "nothing is uploaded automatically",
        "app-resident panes", "excluded by structure",
        "command-shift-a", "last explicit ask target",
        "command-shift-j", "pane attention ring", "permission reported",
        "start fresh session", "vendor-owned resume", "resume requested",
        "target signal", "advisory only", "neither blocks nor authorizes",
        "exact working directory", "bounded listen ports", "owning process tree",
        "latest authoritative attention reason", "none of these facts comes from terminal scraping",
        "parley done current --file", "compact completion receipt", "returned delegation files",
        "review, not delivery",
        "pane focus strip", "native terminal", "macos clipboard", "mouse-aware", "shift",
    ] {
        try expect(searchable.contains(concept), "the in-app guide omitted \(concept)")
    }
    try expect(
        !searchable.contains("handoff chain"),
        "the in-app guide still advertises the superseded Handoff Chains workflow"
    )
    try expect(
        ParleyHelpGuide.matching("ask many independent").map(\.id) == ["coordination"],
        "help search did not narrow multiple literal terms to the relevant topic"
    )
    // Hyphenated queries split into ordinary words that valid help may contain.
    try expect(ParleyHelpGuide.matching("zzzxqvnomatch98417").isEmpty, "help search returned an unrelated topic")
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
    let readyAgent = WorkbenchPane(
        id: "%1",
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        workspaceID: "@0",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )

    try expect(
        WorkbenchStateProjection.connection(terminalAvailable: false, coreAvailable: false) == .terminalDisconnected,
        "terminal loss did not take precedence over core loss"
    )
    try expect(
        WorkbenchStateProjection.connection(terminalAvailable: true, coreAvailable: false) == .coreDisconnected,
        "core loss was not distinguished from terminal loss"
    )
    try expect(
        WorkbenchStateProjection.connection(terminalAvailable: true, coreAvailable: true) == .connected,
        "healthy services did not project as connected"
    )
    try expect(
        WorkbenchStateProjection.pane(nil) == .empty,
        "an empty workspace projected a running pane"
    )

    let stopped = WorkbenchPane(
        id: "%2",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: true,
        workspaceID: "@0",
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

    let exited = WorkbenchPane(
        id: "%3",
        kind: .codex,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "codex",
        isActive: true,
        workspaceID: "@0",
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

    let stale = WorkbenchPane(
        id: "%4",
        kind: .agy,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "agy",
        isActive: true,
        workspaceID: "@0",
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

    let unknownProtocol = WorkbenchPane(
        id: "%6",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "claude",
        isActive: false,
        workspaceID: "@0",
                relayEnabled: false,
        protocolVersion: nil,
        isStarted: true
    )
    try expect(
        WorkbenchStateProjection.protocolStatus(unknownProtocol) == .restartRequired(reportedVersion: nil),
        "a running legacy pane without a protocol stamp was not marked for restart"
    )

    let relayUnavailable = WorkbenchPane(
        id: "%5",
        kind: .copilot,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "copilot",
        isActive: true,
        workspaceID: "@0",
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

    let currentLifecycle = RuntimeLifecycleProjection.snapshot(
        coreAvailable: true,
        coreMessage: "The coordination core matches this Parley build.",
        panes: [readyAgent, stopped]
    )
    try expect(
        currentLifecycle.core == .current(detail: "The coordination core matches this Parley build."),
        "a matching coordination core was not projected as current"
    )
    try expect(
        currentLifecycle.protocol == .current(version: AgentProtocol.version, runningPaneCount: 1),
        "current protocol coverage included a stopped placeholder or lost a running pane"
    )

    let staleLifecycle = RuntimeLifecycleProjection.snapshot(
        coreAvailable: true,
        coreMessage: "The app-resident coordination core is current.",
        panes: [stale, unknownProtocol, stopped]
    )
    try expect(
        staleLifecycle.core == .current(detail: "The app-resident coordination core is current."),
        "a current app-resident core was not projected honestly"
    )
    try expect(
        staleLifecycle.protocol == .restartRequired(
            version: AgentProtocol.version,
            paneIDs: ["%4", "%6"]
        ),
        "the lifecycle summary did not identify exactly the running stale panes"
    )

    let disconnectedLifecycle = RuntimeLifecycleProjection.snapshot(
        coreAvailable: false,
        coreMessage: "stale detail",
        panes: []
    )
    try expect(
        disconnectedLifecycle.core == .unavailable,
        "a disconnected core displayed stale upgrade state"
    )

}

private func checkPrecisionGridChromeUsesOwnedState() throws {
    let running = WorkbenchPane(
        id: "pane-running",
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp/parley",
        currentCommand: "codex",
        isActive: true,
        workspaceID: "window-running",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        isStarted: true
    )
    let stopped = WorkbenchPane(
        id: "pane-stopped",
        kind: .claude,
        customName: "Reviewer",
        terminalTitle: "",
        cwd: "/tmp/parley",
        currentCommand: "claude",
        isActive: false,
        workspaceID: "window-stopped",
                isDead: true,
        isStarted: false
    )

    try expect(
        WorkbenchChromeProjection.selectionLabel(running) == "SELECTED",
        "the active Precision Grid pane was not labelled as the owned selection"
    )
    try expect(
        WorkbenchChromeProjection.processLabel(running) == "RUNNING",
        "the Precision Grid inferred readiness instead of reporting a live process"
    )
    try expect(
        WorkbenchChromeProjection.processLabel(stopped) == "STOPPED",
        "the Precision Grid hid a stopped placeholder"
    )
    try expect(
        WorkbenchChromeProjection.connectionLabel(.connected) == "Core healthy",
        "the healthy footer label did not come from authoritative connection state"
    )
    try expect(
        WorkbenchChromeProjection.connectionLabel(.coreDisconnected) == "Core disconnected",
        "the footer hid a disconnected coordination core"
    )
    try expect(
        WorkbenchChromeProjection.connectionLabel(.terminalDisconnected) == "Terminal unavailable",
        "the footer hid a terminal stack failure"
    )
}

private func checkWorkspaceContinuityState() throws {
    try expect(WorkspaceFolderIdentity.displayName(for: "/") == "/", "root workspace folder rendered with a blank name")
    try expect(
        WorkspaceFolderIdentity.normalized("/tmp/reviewer/../reviewer/") == "/tmp/reviewer",
        "workspace folder identity did not remove equivalent path spelling"
    )
    try expect(
        WorkspaceFolderIdentity.matches("/tmp/reviewer/", "/tmp/reviewer"),
        "equivalent workspace folders did not match"
    )

    let api = WorkbenchWorkspace(id: "@0", name: "api", defaultFolder: "/tmp/api", isActive: false)
    let renamedWeb = WorkbenchWorkspace(id: "@1", name: "website", defaultFolder: "/tmp/web", isActive: true)
    let worker = WorkbenchWorkspace(id: "@2", name: "worker", defaultFolder: "/tmp/worker", isActive: false)
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

    let movedAPI = WorkbenchWorkspace(id: "@0", name: "backend", defaultFolder: "/tmp/backend", isActive: false)
    state.updateWorkspace(from: api, to: movedAPI)
    try expect(state.workspaceOrder.last == WorkspaceBookmark(workspace: movedAPI), "rename/folder update lost the workspace's tab position")
    let movedWeb = WorkbenchWorkspace(id: "@1", name: "frontend", defaultFolder: "/tmp/frontend", isActive: true)
    state.updateWorkspace(from: renamedWeb, to: movedWeb)
    try expect(state.lastSelected == WorkspaceBookmark(workspace: movedWeb), "rename/folder update lost the last-selected workspace")

    try expect(!state.toggleFavourite(folder: "/tmp/api/"), "removing an existing favourite reported the wrong state")
    try expect(state.toggleFavourite(folder: "/tmp/consumer"), "adding a favourite reported the wrong state")
    try expect(state.favouriteFolders == ["/tmp/web", "/tmp/consumer"], "favourite toggle did not preserve deterministic order")
    try expect(state.addFavourite(folder: "/tmp/reviewer/"), "explicit favourite addition did not report a new folder")
    try expect(!state.addFavourite(folder: "/tmp/reviewer"), "explicit favourite addition was not idempotent")
    try expect(
        state.favouriteFolders == ["/tmp/web", "/tmp/consumer", "/tmp/reviewer"],
        "explicit favourite addition changed or duplicated the existing order"
    )

    let encoded = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(WorkspaceContinuityState.self, from: encoded)
    try expect(decoded == state, "workspace continuity state did not round-trip losslessly")

    // Durable identity: a bookmark carrying the workspace's @parley-ws-id must
    // follow the workspace through a simultaneous rename and folder retarget,
    // and must disambiguate two workspaces sharing one folder.
    let alphaID = "11111111-1111-1111-1111-111111111111"
    let betaID = "22222222-2222-2222-2222-222222222222"
    let alpha = WorkbenchWorkspace(
        id: "@7", name: "alpha", defaultFolder: "/tmp/shared", isActive: false, workspaceID: alphaID
    )
    let beta = WorkbenchWorkspace(
        id: "@8", name: "beta", defaultFolder: "/tmp/shared", isActive: false, workspaceID: betaID
    )
    var identityState = WorkspaceContinuityState(
        workspaceOrder: [WorkspaceBookmark(workspace: beta), WorkspaceBookmark(workspace: alpha)],
        lastSelected: WorkspaceBookmark(workspace: beta)
    )
    let relocatedBeta = WorkbenchWorkspace(
        id: "@9", name: "renamed-beta", defaultFolder: "/tmp/elsewhere", isActive: false, workspaceID: betaID
    )
    let identityOrdered = identityState.reconcile([alpha, relocatedBeta])
    try expect(
        identityOrdered.map(\.id) == ["@9", "@7"],
        "identity bookmarks did not keep tab order through a rename plus folder retarget"
    )
    try expect(
        identityState.selectedWorkspace(in: identityOrdered)?.id == "@9",
        "identity selection did not follow the workspace through rename and retarget"
    )
    let identityEncoded = try JSONEncoder().encode(identityState)
    let identityDecoded = try JSONDecoder().decode(WorkspaceContinuityState.self, from: identityEncoded)
    try expect(identityDecoded == identityState, "identity bookmarks did not round-trip losslessly")
    let unstamped = WorkbenchWorkspace(id: "@3", name: "plain", defaultFolder: "/tmp/plain", isActive: false)
    try expect(
        WorkspaceBookmark(workspace: unstamped).workspaceID == nil,
        "a live window id leaked into a durable bookmark identity"
    )
    let legacyPayload = Data(#"{"name":"web","folder":"/tmp/web"}"#.utf8)
    let legacyBookmark = try JSONDecoder().decode(WorkspaceBookmark.self, from: legacyPayload)
    try expect(
        legacyBookmark.workspaceID == nil && legacyBookmark.name == "web",
        "a pre-identity bookmark payload did not decode as a legacy fallback"
    )
}

private func checkWorkspaceRegistryDurability() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("workspace-registry.json")
    let registry = WorkspaceRegistry(file: file)
    let empty = try registry.records()
    try expect(empty.isEmpty, "a missing registry file did not read as empty")

    // The first registry schema shipped before native split fields existed.
    // Adding presentation state must not make those durable records unreadable.
    let legacyFile = directory.appendingPathComponent("legacy-workspace-registry.json")
    let legacyJSON = #"{"version":1,"records":[{"workspaceID":"legacy-durable-id","name":"Legacy","homeFolder":"/tmp/legacy","defaultFolder":"/tmp/legacy","automationPolicy":"askAndDelegate","selectedPaneID":"%7","updatedAt":0}]}"#
    try Data(legacyJSON.utf8).write(to: legacyFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFile.path)
    let migratedLegacy = try require(
        try WorkspaceRegistry(file: legacyFile).record(workspaceID: "legacy-durable-id"),
        "a pre-layout registry record did not decode"
    )
    try expect(
        migratedLegacy.layout == nil && migratedLegacy.layoutRevision == 0
            && migratedLegacy.attachedFolders == ["/tmp/legacy"]
            && migratedLegacy.newPaneFolder == "/tmp/legacy",
        "a pre-layout registry record did not receive honest layout defaults"
    )

    let stamped = WorkbenchWorkspace(
        id: "@1", name: "api", homeFolder: "/tmp/api", defaultFolder: "/tmp/api/feature",
        isActive: true, workspaceID: "aaaaaaaa-1111-1111-1111-111111111111"
    )
    let unstamped = WorkbenchWorkspace(id: "@2", name: "legacy", defaultFolder: "/tmp/legacy", isActive: false)
    let recorded = try registry.synchronize(
        workspaces: [stamped, unstamped],
        selectedPaneIDs: [stamped.workspaceID: "%4"]
    )
    try expect(recorded, "recording a stamped workspace reported no change")
    let records = try registry.records()
    try expect(records.count == 1, "a live-window-id fallback workspace was recorded")
    let record = try require(records.first, "registry lost its only record")
    try expect(
        record.workspaceID == stamped.workspaceID && record.name == "api"
            && record.attachedFolders == ["/tmp/api"] && record.newPaneFolder == "/tmp/api/feature"
            && record.selectedPaneID == "%4" && record.layoutRevision == 0,
        "registry record did not capture the workspace's durable facts"
    )
    let unchanged = try registry.synchronize(
        workspaces: [stamped],
        selectedPaneIDs: [stamped.workspaceID: "%4"]
    )
    try expect(!unchanged, "an unchanged workspace rewrote the registry")
    let changedSelectedPane = try registry.updateSelectedPane(
        workspaceID: stamped.workspaceID, paneID: "%8"
    )
    try expect(
        changedSelectedPane,
        "changing the workspace's selected pane reported no durable change"
    )
    let selectedRecord = try registry.record(workspaceID: stamped.workspaceID)
    try expect(
        selectedRecord?.selectedPaneID == "%8",
        "the selected pane was not recorded per durable workspace"
    )
    let unchangedSelectedPane = try registry.updateSelectedPane(
        workspaceID: stamped.workspaceID, paneID: "%8"
    )
    try expect(
        !unchangedSelectedPane,
        "recording the same selected pane rewrote the registry"
    )
    let absentSet = try registry.synchronize(workspaces: [])
    let afterAbsent = try registry.records()
    try expect(
        !absentSet && afterAbsent.count == 1,
        "an absent workspace changed or lost its record; transient process loss is not a close"
    )

    let renamed = WorkbenchWorkspace(
        id: "@9", name: "api-renamed", homeFolder: "/tmp/api", defaultFolder: "/tmp/api",
        isActive: true, workspaceID: stamped.workspaceID
    )
    let renameChanged = try registry.synchronize(workspaces: [renamed])
    let renamedRecord = try registry.record(workspaceID: stamped.workspaceID)
    try expect(
        renameChanged && renamedRecord?.name == "api-renamed"
            && renamedRecord?.newPaneFolder == "/tmp/api"
            && renamedRecord?.selectedPaneID == "%8",
        "a renamed workspace did not update its record while keeping the selected pane"
    )
    let tree = NativeLayoutNode.split(
        direction: .vertical, first: .leaf("%1"), second: .leaf("%2")
    )
    try registry.updateLayout(workspaceID: stamped.workspaceID, layout: tree)
    let storedLayout = try registry.record(workspaceID: stamped.workspaceID)
    try expect(
        storedLayout?.layout == tree && storedLayout?.layoutRevision == 1,
        "the native layout tree was not stored with an advanced revision"
    )
    try registry.updateLayout(workspaceID: stamped.workspaceID, layout: tree)
    let unchangedLayout = try registry.record(workspaceID: stamped.workspaceID)
    try expect(
        unchangedLayout?.layoutRevision == 1,
        "an identical layout rewrite advanced the revision"
    )

    let reloaded = try WorkspaceRegistry(file: file).record(workspaceID: stamped.workspaceID)
    try expect(
        reloaded?.layoutRevision == 1 && reloaded?.name == "api-renamed"
            && reloaded?.layout != nil,
        "registry records did not persist across instances"
    )

    try registry.remove(workspaceID: stamped.workspaceID)
    let afterRemove = try registry.records()
    try expect(afterRemove.isEmpty, "an explicit remove kept the record")

    _ = try registry.synchronize(workspaces: [renamed])
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    do {
        _ = try registry.records()
        throw CheckFailure(description: "a group-readable registry file was accepted")
    } catch let error as WorkspaceRegistryError {
        try expect(
            error.errorDescription?.contains("owner-only") == true,
            "registry permission failure lacked a useful explanation"
        )
    }
}

private func checkWorkspaceFolderAttachmentModel() throws {
    let folderless = WorkbenchWorkspace(
        id: "@folderless",
        name: "Unbound review",
        attachedFolders: [],
        newPaneFolder: nil,
        isActive: false,
        workspaceID: "folderless-durable-id"
    )
    try expect(folderless.isFolderless, "a workspace with no attachments was not represented explicitly")
    try expect(folderless.primaryAttachedFolder == nil, "a folderless workspace invented a primary folder")
    try expect(folderless.newPaneFolder == nil, "a folderless workspace invented a New Pane Folder")
    try expect(
        WorkspaceBookmark(workspace: folderless).workspaceID == folderless.workspaceID,
        "a folderless workspace did not keep its durable continuity identity"
    )

    let multiRepository = WorkbenchWorkspace(
        id: "@multi",
        name: "Release train",
        attachedFolders: ["/tmp/api", "/tmp/web", "/tmp/api/"],
        newPaneFolder: "/tmp/scratch",
        isActive: true,
        workspaceID: "multi-durable-id"
    )
    try expect(
        multiRepository.attachedFolders == ["/tmp/api", "/tmp/web"],
        "workspace attachments were not normalized and de-duplicated"
    )
    try expect(
        multiRepository.newPaneFolder == "/tmp/scratch",
        "the New Pane Folder was not independent of attached folders"
    )
    try expect(
        WorkspaceFolderRouting.resolve(folder: "/tmp/web", in: [folderless, multiRepository]) == .focus("@multi"),
        "folder opening did not match every explicit workspace attachment"
    )
    try expect(
        WorkspaceFolderRouting.resolve(folder: "/tmp/scratch", in: [folderless, multiRepository]) == .create,
        "the New Pane Folder was incorrectly treated as a workspace attachment"
    )

    let folderlessRoundTrip = try JSONDecoder().decode(
        WorkbenchWorkspace.self,
        from: JSONEncoder().encode(folderless)
    )
    try expect(folderlessRoundTrip == folderless, "a folderless workspace did not round-trip losslessly")

    let legacyWorkspaceJSON = Data(
        #"{"id":"@migrated","name":"Migrated","homeFolder":"/tmp/project","defaultFolder":"/tmp/project/feature","isActive":false,"automationPolicy":"askAndDelegate","workspaceID":"migrated-durable-id"}"#.utf8
    )
    let migratedWorkspace = try JSONDecoder().decode(WorkbenchWorkspace.self, from: legacyWorkspaceJSON)
    try expect(
        migratedWorkspace.attachedFolders == ["/tmp/project"]
            && migratedWorkspace.newPaneFolder == "/tmp/project/feature",
        "a legacy workspace did not migrate its home and New Pane Folder losslessly"
    )

    let controllerDirectory = try temporaryDirectory()
    let controller = try WorkbenchController(
        applicationDirectory: controllerDirectory,
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    )
    try controller.bootstrap(cwd: controllerDirectory.path)
    let initialWorkspace = try require(
        try controller.listWorkspaces().first,
        "folderless bootstrap did not create a workspace"
    )
    let initialPane = try require(
        try controller.listPanes().first,
        "folderless bootstrap did not create its safe shell"
    )
    try expect(
        initialWorkspace.isFolderless && initialWorkspace.newPaneFolder == nil,
        "bootstrap silently attached its safe shell working directory"
    )
    try expect(
        initialPane.kind == .shell && initialPane.cwd == controllerDirectory.path,
        "a folderless workspace did not retain a usable shell working directory"
    )
    let secondAttachment = controllerDirectory.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: secondAttachment, withIntermediateDirectories: true)
    try controller.attachFolder(controllerDirectory.path, toWorkspace: initialWorkspace.id)
    try controller.attachFolder(secondAttachment.path, toWorkspace: initialWorkspace.id)
    try controller.moveAttachedFolder(
        secondAttachment.path,
        inWorkspace: initialWorkspace.id,
        by: -1
    )
    let attachedWorkspace = try controller.listWorkspaces().first
    try expect(
        attachedWorkspace?.attachedFolders == [secondAttachment.path, controllerDirectory.path],
        "attaching and reordering folders did not update workspace metadata"
    )
    try controller.detachFolder(secondAttachment.path, fromWorkspace: initialWorkspace.id)
    try controller.detachFolder(controllerDirectory.path, fromWorkspace: initialWorkspace.id)
    let detachedWorkspace = try controller.listWorkspaces().first
    let unchangedPane = try controller.listPanes().first
    try expect(
        detachedWorkspace?.isFolderless == true,
        "removing the final attachment did not restore a normal folderless state"
    )
    try expect(
        unchangedPane?.cwd == initialPane.cwd,
        "attachment removal changed a running pane's working directory"
    )

    let legacy = WorkbenchWorkspace(
        id: "@legacy",
        name: "Legacy",
        defaultFolder: "/tmp/legacy",
        isActive: false
    )
    try expect(
        legacy.attachedFolders == ["/tmp/legacy"] && legacy.newPaneFolder == "/tmp/legacy",
        "legacy workspace did not migrate its New Pane Folder into an attachment"
    )

    let implementation = WorkbenchWorkspace(
        id: "@implementation",
        name: "Implementation",
        homeFolder: "/tmp/project",
        defaultFolder: "/tmp/project/feature",
        isActive: true
    )
    try expect(
        implementation.attachedFolders == ["/tmp/project"]
            && implementation.newPaneFolder == "/tmp/project/feature",
        "workspace attachments and New Pane Folder were not independent"
    )

    let review = WorkbenchWorkspace(
        id: "@review",
        name: "Security Review",
        homeFolder: "/tmp/project",
        defaultFolder: "/tmp/project",
        isActive: false
    )
    try expect(
        WorkspaceFolderRouting.resolve(folder: "/tmp/project", in: [implementation, review])
            == .choose(["@implementation", "@review"]),
        "two task workspaces sharing one attachment were not presented as an explicit choice"
    )
    try expect(
        WorkspaceFolderRouting.resolve(folder: "/tmp/legacy", in: [legacy, implementation])
            == .focus("@legacy"),
        "one workspace attachment did not resolve directly"
    )
    try expect(
        WorkspaceFolderRouting.resolve(folder: "/tmp/new", in: [legacy, implementation]) == .create,
        "an unopened folder did not resolve to workspace creation"
    )

    var continuity = WorkspaceContinuityState(
        workspaceOrder: [WorkspaceBookmark(workspace: implementation)],
        lastSelected: WorkspaceBookmark(workspace: implementation)
    )
    let retargeted = WorkbenchWorkspace(
        id: implementation.id,
        name: implementation.name,
        attachedFolders: implementation.attachedFolders,
        newPaneFolder: "/tmp/project/docs",
        isActive: true
    )
    continuity.updateWorkspace(from: implementation, to: retargeted)
    try expect(
        continuity.lastSelected == WorkspaceBookmark(workspace: implementation),
        "changing the New Pane Folder changed the workspace continuity identity"
    )

    let directory = try temporaryDirectory()
    let real = directory.appendingPathComponent("real", isDirectory: true)
    let alias = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    try expect(
        WorkspaceFolderIdentity.matches(real.path, alias.path),
        "workspace lookup treated a symlinked spelling as a different directory"
    )
    try expect(
        WorkspaceFolderIdentity.normalized(alias.path) == alias.standardizedFileURL.path,
        "workspace display storage rewrote the person's chosen path"
    )
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

    for command in ["claude", "codex", "agy", "copilot"] {
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

    try expect(snapshot.item(.terminal)?.state == .ready, "embedded terminal readiness was not confirmed")
    try expect(snapshot.item(.core)?.state == .ready, "healthy core was not projected")
    try expect(snapshot.item(.relay)?.state == .ready, "managed relay shim was not recognized")
    try expect(snapshot.item(.protocolRules)?.state == .ready, "current protocol rules were not recognized")
    try expect(snapshot.item(.claude)?.state == .ready, "Claude authentication JSON was not parsed")
    try expect(snapshot.item(.codex)?.state == .attention, "failed Codex login status was not surfaced")
    try expect(snapshot.item(.agy)?.state == .ready, "Agy's quota-free model listing did not confirm access")
    try expect(snapshot.item(.copilot)?.state == .unchecked, "Copilot invented an authentication result")
    try expect(snapshot.readyVendorCount == 2, "ready vendor count did not use confirmed authentication")
    try expect(snapshot.isOperational, "two authenticated vendors and healthy local services should be operational")

    let oneVendor = RuntimeReadinessSnapshot(items: snapshot.items.map { item in
        guard item.category == .vendor, item.id != .claude else { return item }
        return RuntimeReadinessItem(
            id: item.id,
            category: item.category,
            title: item.title,
            state: .unavailable,
            detail: "Unavailable in one-vendor fixture.",
            required: item.required
        )
    })
    try expect(
        oneVendor.availableVendorCount == 1 && oneVendor.isOperational,
        "one available CLI did not support a same-vendor multi-pane workspace"
    )

    let calls = runner.calls.map(\.arguments)
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
    try expect(runner.calls.count == 3, "Copilot was invoked despite lacking a status-only auth command")

    let stalePane = WorkbenchPane(
        id: "%9",
        kind: .claude,
        customName: nil,
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "claude",
        isActive: true,
        workspaceID: "@0",
                protocolVersion: "older",
        isStarted: true
    )
    let overrideSnapshot = RuntimeReadinessChecker(runner: runner).check(
        environment: ["PATH": bin.path],
        applicationDirectory: applicationDirectory,
        coreHealthy: true,
        panes: [stalePane]
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
    let misleadingPane = WorkbenchPane(
        id: "%1",
        kind: .claude,
        customName: "Claude",
        terminalTitle: "Working — allow once — task complete",
        cwd: "/private/project",
        currentCommand: "claude",
        isActive: true,
        workspaceID: "@0",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        inputAvailable: true,
        isStarted: true
    )
    let exitedPane = WorkbenchPane(
        id: "%2",
        kind: .codex,
        customName: "Codex",
        terminalTitle: "",
        cwd: "/private/project",
        currentCommand: "codex",
        isActive: false,
        workspaceID: "@0",
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
        terminalAvailable: true,
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
        diagnostics: diagnostics
    )
    try expect(bundle.requiresExplicitReview, "feedback could be exported without an explicit review contract")
    let encoded = try BetaFeedbackBundleEncoder.encode(bundle)
    let text = String(decoding: encoded, as: UTF8.self)
    for secret in secrets {
        try expect(!text.contains(secret), "beta feedback leaked private value \(secret)")
    }
    try expect(text.contains("4.5.6") && text.contains("compatible"), "beta feedback omitted useful compatibility facts")

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
    ) -> WorkbenchPane {
        WorkbenchPane(
            id: id,
            kind: kind,
            customName: "Pane \(id)",
            terminalTitle: "",
            cwd: "/Users/example/project",
            currentCommand: kind.rawValue,
            isActive: false,
            workspaceID: "@0",
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
        WorkbenchPane(
            id: "%1", kind: .claude, customName: "Planner", terminalTitle: "", cwd: "/repo",
            currentCommand: "claude", isActive: true, workspaceID: "durable-project",
            isStarted: true, permissionSelection: flexible, permissionEnforcement: .partiallyEnforced
        ),
        WorkbenchPane(
            id: "%2", kind: .codex, customName: "Stopped reviewer", terminalTitle: "", cwd: "/repo/subdir",
            currentCommand: "codex", isActive: false, workspaceID: "durable-project",
            isStarted: false, permissionSelection: flexible, permissionEnforcement: .enforced
        ),
        WorkbenchPane(
            id: "%3", kind: .shell, customName: "Tests", terminalTitle: "", cwd: "/other",
            currentCommand: "zsh", isActive: false, workspaceID: "durable-project"
        ),
        WorkbenchPane(
            id: "%4", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/repo",
            currentCommand: "codex", isActive: false, workspaceID: "durable-consumer",
            isStarted: true, permissionSelection: flexible, permissionEnforcement: .enforced
        ),
    ]
    let active = try statusHandoff(
        id: "active",
        kind: .ask,
        state: .waiting,
        sourceWorkspaceID: "durable-project",
        targetWorkspaceID: "durable-consumer",
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
        sourceWorkspaceID: "durable-project",
        targetWorkspaceID: "durable-consumer",
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
    let workspace = WorkbenchWorkspace(
        id: "@0",
        name: "project",
        defaultFolder: "/repo",
        isActive: true,
        workspaceID: "durable-project"
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

    try expect(summary.workspaceID == "durable-project", "workspace safety published a transient member-window id")
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

    let exited = WorkbenchPane(
        id: "%7", kind: .codex, customName: "Audit", terminalTitle: "", cwd: "/tmp/library",
        currentCommand: "codex", isActive: false, workspaceID: "@1",         relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "library",
        inputAvailable: true, isDead: true, exitStatus: 7, role: "reviewer"
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

    let folderlessLayout = try template.folderlessWorkspaceLayout(
        launchFolder: directory.path,
        workspaceName: "Unbound Team"
    )
    try expect(
        folderlessLayout.root.leaves.allSatisfy {
            $0.folder == directory.path && $0.permissionSelection == nil
        },
        "a folderless team silently retained permission roots or lost its safe launch fallback"
    )
    let controllerDirectory = directory.appendingPathComponent("workbench", isDirectory: true)
    try FileManager.default.createDirectory(at: controllerDirectory, withIntermediateDirectories: true)
    let controller = try WorkbenchController(
        applicationDirectory: controllerDirectory,
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    )
    try controller.bootstrap(cwd: directory.path)
    let restoredFolderless = try controller.restoreWorkspaceLayout(folderlessLayout, folderless: true)
    let restoredAgents = try controller.listPanes().filter {
        $0.workspaceID == restoredFolderless.workspaceID
    }
    try expect(
        restoredFolderless.isFolderless && restoredFolderless.newPaneFolder == nil,
        "a folderless team application attached its launch fallback"
    )
    try expect(
        restoredAgents.allSatisfy { !$0.isStarted && $0.permissionSelection == nil },
        "a folderless team application started or pre-authorized an agent"
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
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationDirectory.path)
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

    func writeRaw(_ object: [String: Any]) throws -> URL {
        let file = inbox.appendingPathComponent("\(UUID().uuidString.lowercased()).parleycontext")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
    try expect(request.requestID == importFile.deletingPathExtension().lastPathComponent, "editor import lost its correlated request id")

    let legacy = try write(ExternalContextImportManifest(
        version: 1,
        folder: project.path,
        items: [ExternalContextImportItem(kind: .currentFile, file: "Sources/Game.swift")]
    ))
    _ = try ExternalContextImport.consume(
        file: legacy,
        applicationDirectory: applicationDirectory,
        builder: ContextPackBuilder()
    )

    let injectedAuthority = try writeRaw([
        "version": ExternalContextImport.currentVersion,
        "folder": project.path,
        "items": [[
            "kind": "currentFile",
            "file": "Sources/Game.swift",
            "prompt": "submit this without review",
        ]],
    ])
    do {
        _ = try ExternalContextImport.consume(
            file: injectedAuthority,
            applicationDirectory: applicationDirectory,
            builder: ContextPackBuilder()
        )
        throw CheckFailure(description: "editor context import ignored an unsupported authority field")
    } catch ExternalContextImportError.invalidManifest {
        // Expected.
    }

    let scopedRunner = RecordingRunner { arguments, _ in
        if arguments.contains("rev-parse") {
            return CommandOutput(stdout: Data("\(project.path)\n".utf8))
        }
        if arguments.contains("status") {
            return CommandOutput(stdout: Data(" M Sources/Game.swift\n".utf8))
        }
        if arguments.contains("--cached") {
            return CommandOutput(stdout: Data("diff --git a/Sources/Game.swift b/Sources/Game.swift\n+staged\n".utf8))
        }
        return CommandOutput(stdout: Data("diff --git a/Sources/Game.swift b/Sources/Game.swift\n+working\n".utf8))
    }
    let scoped = try write(ExternalContextImportManifest(
        version: ExternalContextImport.currentVersion,
        folder: project.path,
        items: [
            ExternalContextImportItem(kind: .gitWorkingDiff, file: "Sources/Game.swift"),
            ExternalContextImportItem(kind: .gitStagedDiff, file: "Sources/Game.swift"),
        ]
    ))
    let scopedRequest = try ExternalContextImport.consume(
        file: scoped,
        applicationDirectory: applicationDirectory,
        builder: ContextPackBuilder(gitRunner: scopedRunner)
    )
    try expect(scopedRequest.parts[0].text.contains("+working") && !scopedRequest.parts[0].text.contains("+staged"), "working-tree SCM import captured the wrong Git surface")
    try expect(scopedRequest.parts[1].text.contains("+staged") && !scopedRequest.parts[1].text.contains("+working"), "staged SCM import captured the wrong Git surface")
    try expect(
        scopedRunner.calls.filter { $0.arguments.contains("diff") }.allSatisfy {
            Array($0.arguments.suffix(2)) == ["--", "Sources/Game.swift"]
        },
        "SCM import did not pass the explicit relative file as a fixed Git argv pathspec"
    )

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

    let generatedAt = Date(timeIntervalSince1970: 1_788_256_810)
    let capabilitiesFile = try ExternalEditorBridgeCapabilitiesFile.write(
        ExternalEditorBridgeCapabilities(generatedAt: generatedAt),
        applicationDirectory: applicationDirectory
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let capabilities = try decoder.decode(
        ExternalEditorBridgeCapabilities.self,
        from: Data(contentsOf: capabilitiesFile)
    )
    try expect(capabilities.contextImport.versions == [1, 2], "editor bridge omitted its compatible import contracts")
    try expect(capabilities.contextImport.kinds.contains(.gitStagedDiff), "editor bridge omitted staged SCM capability")
    var metadata = stat()
    try expect(lstat(capabilitiesFile.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "editor bridge capabilities were not owner-only")

    let acknowledgement = ExternalContextAcknowledgement.accepted(
        requestID: request.requestID,
        workspaceID: "workspace-11111111-1111-4111-8111-111111111111",
        sourceCount: request.parts.count,
        acknowledgedAt: generatedAt
    )
    let acknowledgementFile = try ExternalContextAcknowledgementFile.write(
        acknowledgement,
        applicationDirectory: applicationDirectory
    )
    let decodedAcknowledgement = try decoder.decode(
        ExternalContextAcknowledgement.self,
        from: Data(contentsOf: acknowledgementFile)
    )
    try expect(decodedAcknowledgement == acknowledgement, "editor context acknowledgement did not round-trip")
    try expect(lstat(acknowledgementFile.path, &metadata) == 0 && metadata.st_mode & 0o077 == 0, "editor acknowledgement was not owner-only")
    try FileManager.default.setAttributes(
        [.modificationDate: generatedAt.addingTimeInterval(-1_000)],
        ofItemAtPath: acknowledgementFile.path
    )
    try ExternalContextAcknowledgementFile.removeExpired(
        applicationDirectory: applicationDirectory,
        olderThan: 600,
        now: generatedAt
    )
    try expect(!FileManager.default.fileExists(atPath: acknowledgementFile.path), "expired editor acknowledgement was left behind")
}

private func checkExternalAttentionAndNavigationContract() throws {
    let workspaces = [
        WorkbenchWorkspace(id: "@0", name: "Library", defaultFolder: "/tmp/library", isActive: true, workspaceID: "library"),
        WorkbenchWorkspace(id: "@1", name: "Consumer", defaultFolder: "/tmp/consumer", isActive: false, workspaceID: "consumer"),
    ]
    let panes = [
        WorkbenchPane(id: "%1", kind: .codex, customName: "Reviewer", terminalTitle: "SECRET TITLE", cwd: "/tmp/library", currentCommand: "SECRET COMMAND", isActive: true, workspaceID: "library", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Library", isStarted: true),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "claude", isActive: false, workspaceID: "consumer", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "Consumer", isStarted: true),
        WorkbenchPane(id: "%3", kind: .shell, customName: "Server", terminalTitle: "", cwd: "/tmp/consumer", currentCommand: "zsh", isActive: false, workspaceID: "consumer"),
    ]
    let resultID = "11111111-1111-4111-8111-111111111111"
    let permissionID = "22222222-2222-4222-8222-222222222222"
    let viewedID = "33333333-3333-4333-8333-333333333333"
    let delegationID = "44444444-4444-4444-8444-444444444444"
    let failedID = "55555555-5555-4555-8555-555555555555"
    let handoffs = [
        try statusHandoff(id: resultID, kind: .ask, state: .completed, sourceWorkspaceID: "library", targetWorkspaceID: "consumer", occurredAt: 20, text: "PROMPT SECRET", resultText: "ANSWER SECRET", sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: permissionID, kind: .relay, state: .failed, sourceWorkspaceID: "library", targetWorkspaceID: "consumer", occurredAt: 30, text: "SECOND SECRET", attention: .permissionRequired, sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: viewedID, kind: .ask, state: .completed, sourceWorkspaceID: "library", targetWorkspaceID: "consumer", occurredAt: 10, resultText: "VIEWED SECRET", readAt: 11),
        try statusHandoff(id: delegationID, kind: .delegate, state: .completed, sourceWorkspaceID: "library", targetWorkspaceID: "consumer", occurredAt: 40, text: "DELEGATION SECRET", resultText: "COMPLETION SECRET", sourceName: "Reviewer", targetName: "Builder"),
        try statusHandoff(id: failedID, kind: .ask, state: .failed, sourceWorkspaceID: "library", targetWorkspaceID: "consumer", occurredAt: 50, text: "FAILURE SECRET", sourceName: "Reviewer", targetName: "Builder"),
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
    try expect(snapshot.panes.map(\.workspaceID) == ["library", "consumer"], "external pane focus published transient member-window ids")
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
            transportDirectory: transportDirectory,
            paneToken: "not-a-capability"
        )
        throw CheckFailure(description: "agent boundary accepted a malformed pane capability")
    } catch is AgentProcessBoundaryError {
        // Expected: a path component must never be derived from untrusted text.
    }
}

private func checkNativeWorkspaceLayoutTree() throws {
    // Split Below must stack; Split Right must sit beside; Balance retiles.
    let single = NativeLayoutNode.leaf("%1")
    let below = try require(
        single.inserting("%2", after: "%1", direction: .vertical),
        "splitting below the only leaf failed"
    )
    try expect(
        below == .split(direction: .vertical, first: .leaf("%1"), second: .leaf("%2")),
        "Split Below did not stack the new leaf under its target"
    )
    let right = try require(
        below.inserting("%3", after: "%2", direction: .horizontal),
        "splitting right of a nested leaf failed"
    )
    try expect(
        right.leaves == ["%1", "%2", "%3"],
        "insertion changed the leaf order"
    )
    try expect(
        right.inserting("%9", after: "%404", direction: .horizontal) == nil,
        "insertion invented a target leaf"
    )

    let collapsed = try require(right.removing("%2"), "removing a nested leaf failed")
    try expect(
        collapsed == .split(direction: .vertical, first: .leaf("%1"), second: .leaf("%3")),
        "removing a leaf did not collapse its parent split into the sibling"
    )
    try expect(NativeLayoutNode.leaf("%1").removing("%1") == nil, "removing the only leaf did not empty the tree")

    let reconciled = try require(
        NativeLayoutNode.reconciled(right, with: ["%1", "%3", "%5"]),
        "reconciliation emptied a live tree"
    )
    try expect(
        reconciled.leaves == ["%1", "%3", "%5"],
        "reconciliation did not drop the dead leaf and append the new one"
    )
    try expect(
        NativeLayoutNode.reconciled(nil, with: ["%7"]) == .leaf("%7"),
        "reconciliation did not seed a tree from live leaves"
    )
    let saved = SavedLayoutNode.split(
        direction: .vertical,
        ratio: 0.7,
        first: .leaf(SavedLayoutLeaf(kind: .shell, name: "One", folder: "/tmp")),
        second: .split(
            direction: .horizontal,
            ratio: 0.4,
            first: .leaf(SavedLayoutLeaf(kind: .codex, name: "Two", folder: "/tmp")),
            second: .leaf(SavedLayoutLeaf(kind: .claude, name: "Three", folder: "/tmp"))
        )
    )
    try expect(
        NativeLayoutNode.mirroring(saved, paneIDs: ["%1", "%2", "%3"])
            == .split(
                direction: .vertical,
                first: .leaf("%1"),
                second: .split(
                    direction: .horizontal,
                    first: .leaf("%2"),
                    second: .leaf("%3")
                )
            ),
        "a saved split tree did not rebind to fresh pane ids without changing structure"
    )
    try expect(
        NativeLayoutNode.mirroring(saved, paneIDs: ["%1", "%2"]) == nil,
        "saved split rebinding silently accepted a pane-count mismatch"
    )
    try expect(
        WorkbenchIdentifierOrder.sorted(["%10", "%2", "%1"]) == ["%1", "%2", "%10"],
        "live pane ids were ordered lexicographically instead of naturally"
    )
    try expect(
        NativeLayoutNode.reconciled(right, with: []) == nil,
        "reconciliation kept leaves no live pane backs"
    )

    let tiled = try require(
        NativeLayoutNode.tiled(["%1", "%2", "%3", "%4"]),
        "tiling four leaves failed"
    )
    try expect(
        tiled.leaves == ["%1", "%2", "%3", "%4"],
        "tiling lost or reordered leaves"
    )
    guard case let .split(direction, first, second) = tiled,
          direction == .horizontal,
          case .split(direction: .vertical, _, _) = first,
          case .split(direction: .vertical, _, _) = second else {
        throw CheckFailure(description: "Balance did not produce an alternating tiled arrangement")
    }

    let encoded = try JSONEncoder().encode(tiled)
    let decoded = try JSONDecoder().decode(NativeLayoutNode.self, from: encoded)
    try expect(decoded == tiled, "the native layout tree did not round-trip losslessly")
}

private func checkWindowAndSplitGeometryRecovery() throws {
    let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let secondary = CGRect(x: 1_440, y: 0, width: 1_200, height: 800)
    let recovered = WindowFrameRecovery.recoveredFrame(
        CGRect(x: -6_016, y: -271, width: 1_500, height: 900),
        visibleFrames: [primary, secondary]
    )
    try expect(primary.contains(recovered), "an off-screen Parley window was not recovered onto a connected display")
    try expect(recovered.width == 1_400 && recovered.height == 860, "window recovery did not fit an oversized frame with a usable inset")

    let alreadyVisible = CGRect(x: 80, y: 60, width: 1_200, height: 760)
    try expect(
        WindowFrameRecovery.recoveredFrame(alreadyVisible, visibleFrames: [primary]) == alreadyVisible,
        "window recovery moved an already visible window"
    )

    try expect(
        abs(NativeSplitGeometry.clampedFraction(0.001, availableLength: 1_000, minimumLeafLength: 180) - 0.18) < 0.000_001,
        "a collapsed leading pane was not restored to the minimum usable width"
    )
    try expect(
        abs(NativeSplitGeometry.clampedFraction(0.999, availableLength: 1_000, minimumLeafLength: 180) - 0.82) < 0.000_001,
        "a collapsed trailing pane was not restored to the minimum usable width"
    )
    try expect(
        NativeSplitGeometry.clampedFraction(0.4, availableLength: 1_000, minimumLeafLength: 180) == 0.4,
        "a valid split ratio was changed"
    )
    try expect(
        NativeSplitGeometry.proportionalFraction(firstLeafCount: 1, secondLeafCount: 3) == 0.25,
        "fresh nested horizontal splits did not distribute space evenly by leaf count"
    )
    try expect(
        NativeSplitGeometry.proportionalFraction(firstLeafCount: 2, secondLeafCount: 1) == (2.0 / 3.0),
        "fresh split geometry did not reserve proportional space for each subtree"
    )

    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = WorkspaceRegistry(file: directory.appendingPathComponent("workspace-registry.json"))
    let workspace = WorkbenchWorkspace(
        id: "window",
        name: "Geometry",
        defaultFolder: directory.path,
        isActive: true,
        workspaceID: "workspace-geometry"
    )
    _ = try registry.synchronize(workspaces: [workspace])
    try registry.updateSplitFractions(
        workspaceID: workspace.workspaceID,
        fractions: ["root": 0.37, "root.first": 0.62]
    )
    let stored = try require(
        registry.record(workspaceID: workspace.workspaceID),
        "the split geometry workspace record disappeared"
    )
    try expect(
        stored.splitFractions == ["root": 0.37, "root.first": 0.62],
        "split ratios did not persist with the workspace"
    )
}

private func checkPaneAttentionProjectionIsAuthoritativeAndAged() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let hookPane = WorkbenchPane(
        id: "%hook",
        kind: .claude,
        customName: "Implementer",
        terminalTitle: "",
        cwd: "/tmp/project",
        currentCommand: "claude",
        isActive: true,
        workspaceID: "workspace-a",
        workspaceName: "Project",
        inputAvailable: true,
        vendorRuntimeState: .awaitingPermission,
        vendorRuntimeSignal: .awaitingPermission,
        vendorRuntimeSignaledAt: Date(timeIntervalSinceReferenceDate: 905)
    )
    let deadHookPane = WorkbenchPane(
        id: "%dead",
        kind: .codex,
        customName: "Stopped Reviewer",
        terminalTitle: "",
        cwd: "/tmp/project",
        currentCommand: "codex",
        isActive: false,
        workspaceID: "workspace-a",
        vendorRuntimeState: .awaitingPermission,
        vendorRuntimeSignal: .awaitingPermission,
        vendorRuntimeSignaledAt: Date(timeIntervalSinceReferenceDate: 990),
        isDead: true
    )
    let result = try statusHandoff(
        id: "11111111-1111-4111-8111-111111111111",
        kind: .ask,
        state: .completed,
        sourceWorkspaceID: "workspace-a",
        targetWorkspaceID: "workspace-b",
        occurredAt: 940,
        resultText: "A reviewed answer"
    )
    let permission = try statusHandoff(
        id: "22222222-2222-4222-8222-222222222222",
        kind: .relay,
        state: .failed,
        sourceWorkspaceID: "workspace-a",
        targetWorkspaceID: "workspace-b",
        occurredAt: 960,
        attention: .permissionRequired
    )
    let interrupted = try statusHandoff(
        id: "33333333-3333-4333-8333-333333333333",
        kind: .delegate,
        state: .interrupted,
        sourceWorkspaceID: "workspace-a",
        targetWorkspaceID: "workspace-b",
        occurredAt: 970
    )
    let viewed = try statusHandoff(
        id: "44444444-4444-4444-8444-444444444444",
        kind: .ask,
        state: .completed,
        sourceWorkspaceID: "workspace-a",
        targetWorkspaceID: "workspace-b",
        occurredAt: 980,
        resultText: "Already reviewed",
        readAt: 990
    )

    let items = PaneAttentionProjection.items(
        panes: [hookPane, deadHookPane],
        handoffs: [result, permission, interrupted, viewed],
        now: now
    )
    try expect(
        items.map(\.reason) == [.interruptedHandoff, .permissionRequest, .returnedResult, .permissionRequest],
        "pane attention did not retain newest-first authoritative reasons"
    )
    try expect(items[0].paneID == interrupted.sourcePaneID, "interrupted work did not return attention to its source pane")
    try expect(items[1].paneID == permission.targetPaneID, "permission attention did not focus its target pane")
    try expect(items[2].paneID == result.sourcePaneID, "a returned result did not focus its source pane")
    try expect(items[3].paneID == hookPane.id, "an official permission hook did not focus its emitting pane")
    try expect(items[3].source == .vendorOfficialHook, "hook attention lost its authoritative source")
    try expect(
        items[3].label(at: now) == "PERMISSION REPORTED · 1m ago",
        "an aged hook report was presented as a current permission fact"
    )
    try expect(items[2].label(at: now) == "RESULT · 1m ago", "returned-result attention lost its age")
    try expect(!items.contains { $0.paneID == deadHookPane.id }, "a dead pane retained live hook attention")
    try expect(!items.contains { $0.handoffID == viewed.id }, "a reviewed result remained in pane attention")
    try expect(
        PaneAttentionProjection.primary(forPaneID: permission.targetPaneID, in: items)?.handoffID == permission.id,
        "pane attention could not resolve the primary ring item"
    )
}

private func checkComposerSignalProvenanceIsExactAgedAndAdvisory() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let target = WorkbenchPane(
        id: "%target",
        kind: .claude,
        customName: "Reviewer",
        terminalTitle: "",
        cwd: "/tmp/project",
        currentCommand: "claude",
        isActive: false,
        workspaceID: "workspace-a",
        workspaceName: "Project",
        vendorRuntimeState: .working,
        vendorRuntimeSignal: .turnStarted,
        vendorRuntimeSignaledAt: Date(timeIntervalSinceReferenceDate: 981),
        isStarted: true
    )
    let advisory = try require(
        HandoffComposerSignalProjection.advisory(for: target),
        "an authenticated target hook signal disappeared from the composer projection"
    )
    try expect(
        advisory.paneID == target.id
            && advisory.paneName == target.displayName
            && advisory.vendor == .claude
            && advisory.signal == .turnStarted,
        "composer signal provenance lost the exact emitting target pane or vendor hook"
    )
    try expect(advisory.sourceLabel == "CLAUDE HOOK · Reviewer", "composer signal source was not visible")
    try expect(advisory.stateLabel == "WORKING REPORTED", "composer promoted or obscured the reported state")
    try expect(advisory.signalLabel == "TURN STARTED", "composer hid the exact official hook event")
    try expect(advisory.ageLabel(at: now) == "19s ago", "composer signal age was not derived from the hook timestamp")
    try expect(!advisory.blocksDelivery, "an advisory hook signal became a delivery gate")
    let explanation = advisory.accessibilityDescription(at: now).lowercased()
    try expect(
        explanation.contains("authenticated")
            && explanation.contains("advisory only")
            && explanation.contains("neither blocks nor authorizes"),
        "composer signal guidance did not preserve its trust and delivery boundaries"
    )

    var unsupported = target
    unsupported.kind = .agy
    unsupported.vendorRuntimeState = .ready
    unsupported.vendorRuntimeSignal = .turnEnded
    try expect(
        HandoffComposerSignalProjection.advisory(for: unsupported) == nil,
        "an unsupported vendor fabricated authenticated composer provenance"
    )

    var dead = target
    dead.isDead = true
    try expect(
        HandoffComposerSignalProjection.advisory(for: dead) == nil,
        "a dead target retained a live official-hook advisory in the composer"
    )

    var unsigned = target
    unsigned.vendorRuntimeSignal = nil
    try expect(
        HandoffComposerSignalProjection.advisory(for: unsigned) == nil,
        "runtime state without its authenticated hook signal entered the composer"
    )
}

private func checkWorkbenchKeyboardShortcuts() throws {
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "j", command: true, shift: true, option: false, control: false
        ) == .nextAttention,
        "Command-Shift-J did not resolve to the next attention item"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "a", command: true, shift: true, option: false, control: false
        ) == .quickRelaySelection,
        "Command-Shift-A did not resolve to the reviewed selection handoff"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "f", command: true, shift: true, option: false, control: false
        ) == .toggleFocusCanvas,
        "Command-Shift-F did not resolve to Focus Canvas"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "3", command: true, shift: false, option: false, control: false
        ) == .selectPane(2),
        "Command-3 did not resolve to the third pane"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "d", command: true, shift: true, option: false, control: false
        ) == .toggleCollaborationDock,
        "Command-Shift-D did not resolve to the Collaboration Dock"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "f", command: false, shift: false, option: false, control: false
        ) == nil,
        "an unmodified terminal key was stolen by application navigation"
    )
    try expect(
        WorkbenchKeyboardShortcut.resolve(
            key: "c", command: true, shift: false, option: false, control: false
        ) == nil,
        "a standard terminal copy shortcut was stolen by application navigation"
    )

    var history = QuickRelayTargetHistory()
    history.record(sourcePaneID: "%1", targetPaneID: "%2")
    history.record(sourcePaneID: "%3", targetPaneID: "%4")
    try expect(
        history.targetPaneID(for: "%1", eligibleTargetPaneIDs: ["%2", "%4"]) == "%2",
        "quick relay did not retain the last explicit target for the source pane"
    )
    try expect(
        history.targetPaneID(for: "%3", eligibleTargetPaneIDs: ["%2", "%4"]) == "%4",
        "quick relay target history leaked between source panes"
    )
    try expect(
        history.targetPaneID(for: "%1", eligibleTargetPaneIDs: ["%4"]) == nil,
        "quick relay reused a target that is no longer eligible"
    )
    history.record(sourcePaneID: "%1", targetPaneID: "%1")
    try expect(
        history.targetPaneID(for: "%1", eligibleTargetPaneIDs: ["%2"]) == "%2",
        "a refused self-target overwrote the last valid quick relay route"
    )

    for index in 0 ... 128 {
        history.record(sourcePaneID: "source-\(index)", targetPaneID: "target-\(index)")
    }
    try expect(
        history.targetPaneID(for: "source-0", eligibleTargetPaneIDs: ["target-0"]) == nil,
        "quick relay target history exceeded its 128-source session bound"
    )
    try expect(
        history.targetPaneID(for: "source-128", eligibleTargetPaneIDs: ["target-128"]) == "target-128",
        "quick relay target history evicted the newest route instead of the oldest"
    )
}

private func checkIdleAgentReaperGates() throws {
    let now = Date()
    let idle = now.addingTimeInterval(-IdleAgentReaper.defaultIdleInterval - 1)
    let recent = now.addingTimeInterval(-60)
    func pane(
        kind: PaneKind = .claude,
        active: Bool = false,
        started: Bool = true,
        dead: Bool = false,
        lead: Bool = false
    ) -> WorkbenchPane {
        WorkbenchPane(
            id: "%9", kind: kind, customName: nil, terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: active, workspaceID: "@1",             isDead: dead, isStarted: started, isWorkspaceLead: lead
        )
    }
    try expect(
        IdleAgentReaper.shouldReap(pane: pane(), lastActivity: idle, now: now, hasLiveCollaboration: false),
        "an idle background agent was not considered reapable"
    )
    let kept: [(String, Bool)] = [
        ("shell pane", IdleAgentReaper.shouldReap(pane: pane(kind: .shell), lastActivity: idle, now: now, hasLiveCollaboration: false)),
        ("active pane", IdleAgentReaper.shouldReap(pane: pane(active: true), lastActivity: idle, now: now, hasLiveCollaboration: false)),
        ("stopped pane", IdleAgentReaper.shouldReap(pane: pane(started: false), lastActivity: idle, now: now, hasLiveCollaboration: false)),
        ("dead pane", IdleAgentReaper.shouldReap(pane: pane(dead: true), lastActivity: idle, now: now, hasLiveCollaboration: false)),
        ("workspace lead", IdleAgentReaper.shouldReap(pane: pane(lead: true), lastActivity: idle, now: now, hasLiveCollaboration: false)),
        ("collaborating pane", IdleAgentReaper.shouldReap(pane: pane(), lastActivity: idle, now: now, hasLiveCollaboration: true)),
        ("recently active pane", IdleAgentReaper.shouldReap(pane: pane(), lastActivity: recent, now: now, hasLiveCollaboration: false)),
        ("unknown activity", IdleAgentReaper.shouldReap(pane: pane(), lastActivity: nil, now: now, hasLiveCollaboration: false)),
    ]
    for (label, reaped) in kept {
        try expect(!reaped, "the reaper would stop a protected pane: \(label)")
    }
}

private func checkVendorOwnedResumePlansAreExplicitAndSafe() throws {
    let directory = try temporaryDirectory()
    let protocolDirectory = try AgentProtocol.install(in: directory)

    let claudePlan = try require(VendorResumeAdapter.plan(for: .claude), "Claude resume support disappeared")
    let codexPlan = try require(VendorResumeAdapter.plan(for: .codex), "Codex resume support disappeared")
    let agyPlan = try require(VendorResumeAdapter.plan(for: .agy), "Agy resume support disappeared")
    let copilotPlan = try require(VendorResumeAdapter.plan(for: .copilot), "Copilot resume support disappeared")
    try expect(claudePlan.selection == .vendorPicker, "Claude resume did not remain vendor-selected")
    try expect(codexPlan.selection == .vendorPicker, "Codex resume did not remain vendor-selected")
    try expect(copilotPlan.selection == .vendorPicker, "Copilot resume did not remain vendor-selected")
    try expect(agyPlan.selection == .mostRecentInWorkingDirectory, "Agy resume invented a picker it does not launch with")
    try expect(VendorResumeAdapter.plan(for: .shell) == nil, "a human shell was offered agent-session resume")

    let claude = AgentProtocol.command(
        for: .claude,
        protocolDirectory: protocolDirectory,
        launchMode: .resume
    )
    try expect(claude.last == "--resume", "Claude resume omitted its documented interactive picker")

    let codex = AgentProtocol.command(
        for: .codex,
        protocolDirectory: protocolDirectory,
        launchMode: .resume
    )
    try expect(Array(codex.prefix(2)) == ["codex", "resume"], "Codex resume used the wrong subcommand order")
    try expect(
        codex.contains(where: { $0.hasPrefix("developer_instructions=") }),
        "Codex resume lost the canonical Parley protocol"
    )

    let agy = AgentProtocol.command(
        for: .agy,
        protocolDirectory: protocolDirectory,
        launchMode: .resume
    )
    try expect(agy.last == "--continue", "Agy resume omitted its documented directory-scoped continuation")

    let copilot = AgentProtocol.command(
        for: .copilot,
        protocolDirectory: protocolDirectory,
        launchMode: .resume
    )
    try expect(copilot.last == "--resume", "Copilot resume omitted its documented interactive picker")
    try expect(copilot.contains("--plugin-dir"), "Copilot resume lost Parley's official hook adapter")

    let fresh = PaneKind.allCases.map {
        AgentProtocol.command(for: $0, protocolDirectory: protocolDirectory, launchMode: .fresh)
    }
    try expect(
        !fresh.contains(where: { command in
            command.last == "--resume" || command.last == "--continue"
                || Array(command.prefix(2)) == ["codex", "resume"]
        }),
        "an ordinary pane launch silently resumed vendor history"
    )

    let resumeCommands = [claude, codex, agy, copilot].flatMap { $0 }
    try expect(
        !resumeCommands.contains(where: {
            $0.contains("dangerously") || $0 == "--allow-all" || $0 == "--yolo"
        }),
        "vendor resume introduced an approval bypass"
    )
    try expect(
        [claudePlan, codexPlan, agyPlan, copilotPlan].allSatisfy {
            $0.detail.lowercased().contains("vendor")
                && $0.detail.lowercased().contains("cannot guarantee")
        },
        "resume guidance did not state the vendor-owned recovery boundary"
    )
}

private func checkSharedProtocolLaunchAdapters() throws {
    let directory = try temporaryDirectory()
    let protocolDirectory = try AgentProtocol.install(in: directory)
    let rules = try String(contentsOf: protocolDirectory.appendingPathComponent("AGENTS.md"), encoding: .utf8)
    try expect(rules == AgentProtocol.text, "Agy's rules file drifted from the canonical protocol text")
    try expect(AgentProtocol.text.contains("protocol v\(AgentProtocol.version)"), "protocol text does not identify its version")
    try expect(AgentProtocol.version == "18", "the shared protocol version drifted from cross-project agent awareness")
    try expect(
        AgentProtocol.text.contains("parley delegate <target> --parent <handoff-id>")
            && AgentProtocol.text.contains("requestChanges")
            && AgentProtocol.text.contains("never a verdict"),
        "shared protocol did not describe the parent-naming Delegate form as a linked child, not a verdict"
    )
    try expect(
        AgentProtocol.text.contains("one minute") && AgentProtocol.text.contains("parley delegate"),
        "shared protocol did not steer longer work toward Delegate"
    )
    try expect(
        AgentProtocol.text.contains("stderr") && AgentProtocol.text.contains("parley wait <id>"),
        "shared protocol omitted the recoverable Ask receipt"
    )
    try expect(AgentProtocol.text.contains("@reviewer"), "shared protocol omitted explicit stable-role addressing")
    try expect(
        AgentProtocol.text.lowercased().contains("same-vendor") && AgentProtocol.text.contains("different pane"),
        "shared protocol omitted the same-vendor, distinct-pane routing rule"
    )
    for command in ["parley whoami", "parley panes", "parley events --since", "parley signal", "parley ask-many", "parley delegate", "parley progress", "parley done", "parley fail", "parley status", "parley wait", "parley cancel", "parley context draft", "parley context discard", "--context <draft-id>"] {
        try expect(AgentProtocol.text.contains(command), "shared protocol omitted \(command)")
    }
    try expect(
        AgentProtocol.text.contains("parley done current --file <path>")
            && AgentProtocol.text.contains("does not send or promote"),
        "shared protocol omitted the reviewed delegation-file boundary"
    )
    try expect(
        !AgentProtocol.text.contains("parley research"),
        "the shared protocol still exposes the retired Research Board namespace"
    )
    let shimDirectory = try RelayShim.install(in: directory)
    let shimText = try String(
        contentsOf: shimDirectory.appendingPathComponent("parley"),
        encoding: .utf8
    )
    try expect(!shimText.contains("research"), "the relay shim still exposes the retired Research Board namespace")
    try expect(AgentProtocol.text.contains("workspace lead"), "shared protocol omitted lead routing")

    let claude = AgentProtocol.command(for: .claude, protocolDirectory: protocolDirectory)
    try expect(
        Array(claude.prefix(3)) == ["claude", "--append-system-prompt", AgentProtocol.text],
        "Claude launch adapter changed the shared protocol"
    )
    try expect(claude.contains("--settings"), "Claude launch adapter omitted its generated hook settings")

    let codex = AgentProtocol.command(for: .codex, protocolDirectory: protocolDirectory)
    try expect(codex.first == "codex" && codex.dropFirst().first == "-c", "Codex launch adapter omitted its config override")
    let codexProtocolArgument = try require(
        codex.first(where: { $0.hasPrefix("developer_instructions=") }),
        "Codex launch adapter omitted developer instructions"
    )
    let codexValue = try require(
        codexProtocolArgument.split(separator: "=", maxSplits: 1).last.map(String.init),
        "Codex protocol value disappeared"
    )
    let decodedCodex = try JSONDecoder().decode(String.self, from: Data(codexValue.utf8))
    try expect(decodedCodex == AgentProtocol.text, "Codex launch adapter changed the shared protocol")

    let agy = AgentProtocol.command(for: .agy, protocolDirectory: protocolDirectory)
    try expect(agy == ["agy", "--add-dir", protocolDirectory.path], "Agy launch adapter did not add the canonical rules workspace")

    let copilot = AgentProtocol.command(for: .copilot, protocolDirectory: protocolDirectory)
    try expect(
        copilot.contains("--allow-tool=shell(parley)"),
        "Copilot launch adapter did not limit automatic approval to Parley's shim"
    )
    try expect(copilot.contains("--plugin-dir"), "Copilot launch adapter omitted its generated hook plugin")
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
        WorkbenchPane(id: "%1", kind: .claude, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0", protocolVersion: "0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0", protocolVersion: AgentProtocol.version),
        WorkbenchPane(id: "%4", kind: .shell, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "zsh", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%5", kind: .copilot, customName: nil, terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, workspaceID: "@0"),
    ]
    try expect(AgentProtocol.stalePaneIDs(in: panes) == ["%1", "%2", "%5"], "protocol restart targeting missed Copilot or included a current agent or shell")
    let stoppedPlaceholder = WorkbenchPane(
        id: "%6",
        kind: .codex,
        customName: "Stopped reviewer",
        terminalTitle: "",
        cwd: "/tmp",
        currentCommand: "sleep",
        isActive: false,
        workspaceID: "@0",
                isStarted: false
    )
    try expect(
        AgentProtocol.stalePaneIDs(in: panes + [stoppedPlaceholder]) == ["%1", "%2", "%5"],
        "protocol migration would auto-start a restored agent placeholder"
    )
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
        name: "Claude reviewer",
        kind: .claude,
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

private func checkSmartOrchestrationModesAndBoundaries() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("smart-orchestration.json")
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
    let verifier = SupervisedWorkflowParticipant(
        paneID: "%3",
        name: "Agy verifier",
        kind: .agy,
        workspaceID: "@0"
    )
    let started = try store.start(
        workspaceID: "@0",
        workspaceName: "parley",
        lead: lead,
        reviewer: reviewer,
        verifier: verifier,
        planningPrompt: "Design the bounded change.",
        mode: .automatic,
        now: Date(timeIntervalSince1970: 200)
    )
    try expect(started.mode == .automatic, "smart orchestration did not persist Auto mode")
    try expect(started.transitions.first?.origin == .human, "Auto mode was not explicitly started by a person")

    let plan = SupervisedWorkflowArtifact(kind: .plan, text: "Plan with evidence")
    let reviewing = try store.advance(
        id: started.id,
        to: .reviewingPlan,
        artifact: plan,
        detail: "The lead returned a correlated plan.",
        origin: .automation
    )
    try expect(reviewing.transitions.last?.origin == .automation, "automatic advancement was not visibly attributed")

    let review = SupervisedWorkflowArtifact(kind: .planReview, text: "Independent objection")
    _ = try store.advance(
        id: started.id,
        to: .awaitingImplementationApproval,
        artifact: review,
        origin: .automation
    )
    _ = try store.advance(id: started.id, to: .implementing, artifact: nil, origin: .automation)
    _ = try store.advance(
        id: started.id,
        to: .verifying,
        artifact: SupervisedWorkflowArtifact(kind: .implementation, text: "Lead report and trusted Git evidence"),
        origin: .automation
    )
    _ = try store.advance(
        id: started.id,
        to: .awaitingCompletionApproval,
        artifact: SupervisedWorkflowArtifact(kind: .verification, text: "Verifier report"),
        origin: .automation
    )
    do {
        _ = try store.advance(id: started.id, to: .completed, artifact: nil, origin: .automation)
        throw CheckFailure(description: "Auto mode declared its own result complete")
    } catch let error as SupervisedWorkflowError {
        try expect(error.localizedDescription.contains("person"), "automatic completion refusal did not identify the human boundary")
    }
    let completed = try store.advance(id: started.id, to: .completed, artifact: nil, origin: .human)
    try expect(completed.phase == .completed, "a person could not approve an Auto workflow's final result")

    let supervised = try store.start(
        workspaceID: "@1",
        workspaceName: "legacy",
        lead: SupervisedWorkflowParticipant(paneID: "%4", name: "Lead", kind: .claude, workspaceID: "@1"),
        reviewer: SupervisedWorkflowParticipant(paneID: "%5", name: "Reviewer", kind: .codex, workspaceID: "@1"),
        verifier: SupervisedWorkflowParticipant(paneID: "%6", name: "Verifier", kind: .agy, workspaceID: "@1"),
        planningPrompt: "Plan only."
    )
    try expect(supervised.mode == .supervised, "existing call sites did not retain supervised mode by default")
    do {
        _ = try store.advance(
            id: supervised.id,
            to: .reviewingPlan,
            artifact: SupervisedWorkflowArtifact(kind: .plan, text: "Unreviewed plan"),
            origin: .automation
        )
        throw CheckFailure(description: "Supervised mode accepted an automatic transition")
    } catch let error as SupervisedWorkflowError {
        try expect(error.localizedDescription.contains("supervised"), "Supervised mode automation refusal was unclear")
    }
    let encoded = try String(contentsOf: file, encoding: .utf8)
    let withoutMode = encoded.replacingOccurrences(
        of: "          \"mode\" : \"supervised\",\n",
        with: ""
    )
    try withoutMode.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let restored = try require(
        SupervisedWorkflowStore(file: file).runs().first(where: { $0.id == supervised.id }),
        "legacy supervised workflow was not restored"
    )
    try expect(restored.mode == .supervised, "legacy workflow without a mode did not migrate safely")

    let prompts = SmartOrchestrationPromptBuilder(
        task: "Fix the coordination race without broadening scope."
    )
    let planPrompt = try prompts.planning()
    let reviewPrompt = try prompts.planReview(plan: "Use one mutation lock.")
    let implementationPrompt = try prompts.implementation(
        plan: "Use one mutation lock.",
        review: "Also cover stale revisions."
    )
    let verificationPrompt = try prompts.verification(
        implementationEvidence: "Changed Relay.swift; focused checks passed."
    )
    try expect(planPrompt.contains("do not edit files"), "planning prompt did not preserve the read-only boundary")
    try expect(reviewPrompt.contains("Use one mutation lock."), "review prompt lost the exact proposed plan")
    try expect(implementationPrompt.contains("Also cover stale revisions."), "implementation prompt lost independent critique")
    try expect(verificationPrompt.lowercased().contains("do not modify files"), "verification prompt did not preserve the read-only boundary")
    do {
        _ = try SmartOrchestrationPromptBuilder(
            task: String(repeating: "x", count: ContextPackBuilder.defaultMaximumRenderedBytes)
        ).planning()
        throw CheckFailure(description: "smart orchestration accepted an oversized stage")
    } catch let error as SupervisedWorkflowError {
        try expect(error.localizedDescription.contains("no larger"), "oversized smart-orchestration refusal was unclear")
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0", workspaceName: "app", isWorkspaceLead: true, automationPolicy: .askAndDelegate),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Reviewer", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0", workspaceName: "app", automationPolicy: .askAndDelegate),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Builder", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0", workspaceName: "app", automationPolicy: .askAndDelegate),
        WorkbenchPane(id: "%4", kind: .copilot, customName: "Observer", terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, workspaceID: "@0", workspaceName: "app", automationPolicy: .askAndDelegate),
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
        WorkbenchPane(id: pane.id, kind: pane.kind, customName: pane.customName, terminalTitle: pane.terminalTitle, cwd: pane.cwd, currentCommand: pane.currentCommand, isActive: pane.isActive, workspaceID: pane.workspaceID, workspaceName: pane.workspaceName, inputAvailable: pane.inputAvailable, isWorkspaceLead: pane.isWorkspaceLead, automationPolicy: .off)
    }
    let offBroker = RelayBroker(credentials: credentials, panes: { offPanes }, paste: { _, _ in }, submit: { _, _ in })
    try expect(offBroker.handle(token: leadToken, target: "reviewer", text: "Must not send.").status == 403, "Off policy allowed automatic relay")
    try expect(offBroker.handleAsk(token: leadToken, target: "reviewer", text: "Must not ask.").status == 403, "Off policy allowed Ask")

    let askOnlyPanes = panes.map { pane in
        WorkbenchPane(id: pane.id, kind: pane.kind, customName: pane.customName, terminalTitle: pane.terminalTitle, cwd: pane.cwd, currentCommand: pane.currentCommand, isActive: pane.isActive, workspaceID: pane.workspaceID, workspaceName: pane.workspaceName, inputAvailable: pane.inputAvailable, isWorkspaceLead: pane.isWorkspaceLead, automationPolicy: .askAnswer)
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, workspaceID: "@0", workspaceName: "api"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, workspaceID: "@1", workspaceName: "web"),
        WorkbenchPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, workspaceID: "@0"),
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
    try expect(submitted.value?.text.contains("parley done current --file <path>") == true, "delegate omitted its reviewed file-result command")
    try expect(submitted.value?.text.contains("parley fail current") == true, "delegate omitted its failure command")
    try expect(submitted.value?.text.contains("parley progress current") == true, "delegate omitted its optional progress command")
    try expect(submitted.value?.text.contains("\(DelegationProgressText.maximumBytes) UTF-8 bytes") == true, "delegate omitted the actual progress bound")
    try expect(submitted.value?.text.contains("\(ContextPackBuilder.defaultMaximumPartBytes) UTF-8 bytes") == true, "delegate omitted the result-file bound")
    try expect(submitted.value?.text.contains("parley protocol") == true, "delegate omitted protocol recovery")

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

private func checkTrackedDelegationProgressIsBoundedOwnedAndDurable() throws {
    let directory = try temporaryDirectory()
    let historyFile = directory.appendingPathComponent("handoffs.jsonl")
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let foreignToken = try credentials.token(for: "%3")
    let panes = [
        WorkbenchPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Observer", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
    ]
    let journal = try RelayHandoffJournal(file: historyFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: journal
    )

    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "builder",
        text: "Implement the parser fix.",
        idempotencyKey: "delegate-progress-1"
    )
    let handoffID = try require(delegated.body.handoffID, "progress fixture returned no delegation id")
    let before = try require(broker.handoffs().first(where: { $0.id == handoffID }), "progress fixture lost its handoff")
    try expect(
        broker.handleDelegationProgress(token: sourceToken, handoffID: handoffID, text: "Source must not report progress.").status == 403,
        "the initiating pane reported progress for its target"
    )
    try expect(
        broker.handleDelegationProgress(token: foreignToken, handoffID: handoffID, text: "Foreign progress.").status == 403,
        "an unrelated pane reported delegation progress"
    )
    let first = broker.handleDelegationProgress(
        token: targetToken,
        handoffID: "current",
        text: "Reviewing\tparser\nfixtures\u{7}"
    )
    try expect(first.status == 200, "the exact target could not report delegation progress")
    let afterFirst = try require(broker.handoffs().first(where: { $0.id == handoffID }), "recorded progress disappeared")
    try expect(afterFirst.progressNote == "Reviewing parser fixtures", "progress was not normalized to one control-free line")
    try expect(afterFirst.progressUpdatedAt != nil, "progress did not record when the target reported it")
    try expect(afterFirst.updatedAt == before.updatedAt, "progress changed the delegation lifecycle timestamp")
    try expect(afterFirst.transitions == before.transitions, "progress invented a handoff lifecycle transition")

    let maximumNote = String(repeating: "é", count: 100)
    try expect(maximumNote.utf8.count == 200, "progress byte-bound fixture drifted")
    try expect(
        broker.handleDelegationProgress(token: targetToken, handoffID: handoffID, text: maximumNote).status == 200,
        "a 200-byte progress note was refused"
    )
    let oversizedNote = String(repeating: "a", count: 199) + "é"
    try expect(oversizedNote.utf8.count == 201, "oversized progress fixture drifted")
    try expect(
        broker.handleDelegationProgress(token: targetToken, handoffID: handoffID, text: oversizedNote).status == 400,
        "a progress note over 200 UTF-8 bytes was accepted"
    )
    try expect(
        broker.handoffs().first(where: { $0.id == handoffID })?.progressNote == maximumNote,
        "a refused progress update replaced the last accepted note"
    )

    let statusResponse = broker.delegationStatus(token: sourceToken)
    let statuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: Data(statusResponse.text.utf8))
    try expect(
        statuses.first?.progressNote == maximumNote && statuses.first?.progressUpdatedAt != nil,
        "the initiating pane's structured status omitted the latest progress note"
    )
    let reloaded = try RelayHandoffJournal(file: historyFile).handoffs()
    try expect(
        reloaded.first(where: { $0.id == handoffID })?.progressNote == maximumNote,
        "the latest progress note did not survive journal replay"
    )

    try expect(
        broker.handleDelegationResult(token: targetToken, handoffID: handoffID, text: "Implemented and verified.", succeeded: true).status == 200,
        "progress fixture could not complete"
    )
    try expect(
        broker.handleDelegationProgress(token: targetToken, handoffID: handoffID, text: "Too late.").status == 404,
        "a terminal delegation accepted another progress update"
    )
    let completed = try require(broker.handoffs().first(where: { $0.id == handoffID }), "completed progress fixture disappeared")
    try expect(completed.progressNote == maximumNote, "completion erased the last reported progress note")
}

private func checkDelegationFileResultsAreBoundedOwnedAndReviewed() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    let handoffFile = directory.appendingPathComponent("handoffs.jsonl")
    let reviewFile = directory.appendingPathComponent("context-reviews.json")
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let foreignToken = try credentials.token(for: "%3")
    let panes = [
        WorkbenchPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Builder", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Observer", terminalTitle: "", cwd: directory.path, currentCommand: "agy", isActive: false, workspaceID: "@0"),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: try RelayHandoffJournal(file: handoffFile),
        contextReviewStore: try AgentContextReviewStore(file: reviewFile)
    )
    let delegated = broker.handleDelegate(
        token: sourceToken,
        target: "builder",
        text: "Produce the implementation report.",
        idempotencyKey: "delegate-file-result-1"
    )
    let handoffID = try require(delegated.body.handoffID, "file-result fixture returned no delegation id")
    let reportPath = directory.appendingPathComponent("reports/final.md").path
    let outsidePath = outsideDirectory.appendingPathComponent("escaped.md").path
    let report = "# Result\n\n    preserved indentation\n\n- 46 checks passed\n"

    try expect(
        broker.handleDelegationFileResult(token: foreignToken, handoffID: handoffID, path: reportPath, text: report).status == 403,
        "an unrelated pane returned a delegation file"
    )
    try expect(
        broker.handleDelegationFileResult(token: targetToken, handoffID: handoffID, path: outsidePath, text: report).status == 403,
        "a delegation file outside the target pane folder was accepted"
    )
    try expect(
        broker.handleDelegationFileResult(
            token: targetToken,
            handoffID: handoffID,
            path: reportPath,
            text: String(repeating: "x", count: ContextPackBuilder.defaultMaximumPartBytes + 1)
        ).status == 413,
        "an oversized delegation file was accepted"
    )
    try expect(broker.contextReviews().isEmpty, "a refused delegation file created a review")
    try expect(
        broker.handoffs().first(where: { $0.id == handoffID })?.state == .waiting,
        "a refused delegation file completed the tracked work"
    )

    let accepted = broker.handleDelegationFileResult(
        token: targetToken,
        handoffID: "current",
        path: reportPath,
        text: report
    )
    try expect(
        accepted.status == 200 && accepted.text.contains("staged for explicit review"),
        "the exact target could not return a bounded file for review"
    )
    let completed = try require(
        broker.handoffs().first(where: { $0.id == handoffID }),
        "completed file-result delegation disappeared"
    )
    let reviewID = try require(completed.resultContextReviewID, "file result was not linked to its durable review")
    try expect(completed.state == .completed, "reviewed file return did not complete the delegation")
    try expect(
        completed.resultText?.contains("final.md") == true
            && completed.resultText?.contains(reviewID) == true
            && completed.resultText?.contains("preserved indentation") == false,
        "the delegation receipt did not stay compact and point to the exact review"
    )
    let review = try require(
        broker.contextReviews().first(where: { $0.id == reviewID }),
        "the linked delegation result review disappeared"
    )
    try expect(review.state == .draft, "a returned file skipped explicit human review")
    try expect(review.sourcePaneID == "%2" && review.sourceFolder == directory.path, "the file review lost its authenticated pane provenance")
    try expect(review.pack.parts.count == 1, "the file result created an unexpected context shape")
    let part = try require(review.pack.parts.first, "the file result review has no part")
    try expect(part.source.kind == .agentFileDraft, "the agent-returned file was promoted to trusted provenance")
    try expect(part.source.referenceID == handoffID, "the file review lost its delegation lineage")
    try expect(part.source.detail.contains(reportPath), "the file review omitted the contained canonical path")
    try expect(part.capturedText == report && part.text == report, "the file review damaged multiline formatting")

    let status = try JSONDecoder().decode(
        [RelayDelegationStatus].self,
        from: Data(broker.delegationStatus(token: sourceToken).text.utf8)
    )
    try expect(status.first?.resultContextReviewID == reviewID, "structured status omitted the linked result review")
    let reloadedHandoff = try RelayHandoffJournal(file: handoffFile)
        .handoffs()
        .first(where: { $0.id == handoffID })
    try expect(
        reloadedHandoff?.resultContextReviewID == reviewID,
        "the handoff journal lost the linked result review"
    )
    let reloadedReview = try AgentContextReviewStore(file: reviewFile)
        .reviews()
        .first(where: { $0.id == reviewID })
    try expect(
        reloadedReview?.pack.parts.first?.capturedText == report,
        "the result review did not survive durable replay"
    )
}

private func checkDetachedAskRecoveryIsDurableAndGenerationBound() throws {
    let directory = try temporaryDirectory()
    let journalFile = directory.appendingPathComponent("handoffs.jsonl")
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let foreignToken = try credentials.token(for: "%3")
    let source = WorkbenchPane(
        id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api",
        currentCommand: "codex", isActive: true, workspaceID: "@0", launchGeneration: 4
    )
    let target = WorkbenchPane(
        id: "%2", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/api",
        currentCommand: "claude", isActive: false, workspaceID: "@0", launchGeneration: 2
    )
    let foreign = WorkbenchPane(
        id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/api",
        currentCommand: "agy", isActive: false, workspaceID: "@0", launchGeneration: 1
    )
    let livePanes = LockedPanes([source, target, foreign])
    let journal = try RelayHandoffJournal(file: journalFile)
    let broker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 2,
        livenessPollInterval: 0.01,
        handoffJournal: journal
    )

    let acceptedID = LockedString()
    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleAsk(
            token: sourceToken,
            target: "reviewer",
            text: "Which failure path is missing?",
            idempotencyKey: "recoverable-ask-1",
            onAccepted: { acceptedID.set($0) }
        ))
    }
    try expect(eventually { acceptedID.value != nil }, "Ask did not publish its handoff id after submission")
    let handoffID = try require(acceptedID.value, "submitted Ask published no handoff id")
    try expect(broker.consultations().first?.id == handoffID, "the early Ask receipt did not name the live consultation")

    let waitingRecovery = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        waitingRecovery.set(broker.waitForTrackedWork(token: sourceToken, handoffID: handoffID))
    }
    Thread.sleep(forTimeInterval: 0.05)
    try expect(waitingRecovery.value == nil, "detached Ask recovery returned before the exact answer")

    let answer = "The interrupted-source recovery path needs a generation check."
    try expect(
        broker.handleAnswer(token: targetToken, consultationID: handoffID, text: answer).status == 200,
        "the exact Ask target could not return its answer"
    )
    try expect(eventually { askResult.value?.text == answer }, "the original Ask command did not receive its answer")
    try expect(eventually { waitingRecovery.value?.text == answer }, "parley wait did not recover the completed Ask answer")
    let completed = try require(
        broker.handoffs().first(where: { $0.id == handoffID }),
        "recoverable Ask disappeared"
    )
    try expect(completed.sourceLaunchGeneration == 4, "Ask did not retain its source credential generation")

    let recoveredBroker = RelayBroker(
        credentials: credentials,
        panes: { livePanes.value },
        paste: { _, _ in },
        submit: { _, _ in },
        handoffJournal: try RelayHandoffJournal(file: journalFile)
    )
    try expect(
        recoveredBroker.waitForTrackedWork(token: sourceToken, handoffID: handoffID)
            == RelayTextResponse(status: 200, text: answer),
        "a reloaded broker could not recover the durable completed Ask answer"
    )
    try expect(
        recoveredBroker.waitForTrackedWork(token: foreignToken, handoffID: handoffID).status == 403,
        "a foreign pane recovered another pane's Ask answer"
    )
    try expect(
        recoveredBroker.waitForTrackedWork(token: sourceToken, handoffID: "current").status == 404,
        "wait current selected a completed Ask instead of remaining delegation-only"
    )

    let restartedToken = try credentials.rotate("%1")
    var restartedSource = source
    restartedSource.launchGeneration += 1
    livePanes.set([restartedSource, target, foreign])
    let restartedRecovery = recoveredBroker.waitForTrackedWork(token: restartedToken, handoffID: handoffID)
    try expect(
        restartedRecovery.status == 409 && restartedRecovery.text.contains("earlier run"),
        "a restarted source generation recovered an older Ask answer"
    )
}

private func checkTrackedDelegationFailureAndLiveness() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let source = WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0")
    let target = WorkbenchPane(id: "%2", kind: .copilot, customName: "Copilot", terminalTitle: "", cwd: "/tmp", currentCommand: "copilot", isActive: false, workspaceID: "@0")
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: false, workspaceID: "@0"),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        consultationTimeout: 3,
        livenessPollInterval: 0.01,
        contextReviewStore: try AgentContextReviewStore(
            file: directory.appendingPathComponent("context-reviews.json")
        )
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

    let progress = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "progress", "current", "Implementation\nchecks are running."],
        environment: targetEnvironment,
        input: nil
    )
    try expect(
        progress.status == 0 && progress.stdoutText.contains("Progress recorded"),
        "parley progress did not reach the local broker: status \(progress.status), stdout \(progress.stdoutText), stderr \(progress.stderrText)"
    )
    let statusWithProgress = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "status"],
        environment: sourceEnvironment,
        input: nil
    )
    let progressStatuses = try JSONDecoder().decode([RelayDelegationStatus].self, from: statusWithProgress.stdout)
    try expect(
        progressStatuses.first?.progressNote == "Implementation checks are running.",
        "parley status did not return progress recorded through the shim"
    )

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

    let fileDelegation = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "delegate", "claude", "Return the detailed report as a reviewed file."],
        environment: sourceEnvironment.merging(["PARLEY_IDEMPOTENCY_KEY": "shim-delegate-file-1"]) { _, supplied in supplied },
        input: nil
    )
    let fileReceipt = try JSONDecoder().decode(RelayResponseBody.self, from: fileDelegation.stdout)
    let fileHandoffID = try require(fileReceipt.handoffID, "file delegation shim returned no handoff id")
    let resultFile = directory.appendingPathComponent("delegation-result.md")
    let resultText = "# Detailed result\n\n    formatting survives\n"
    try resultText.write(to: resultFile, atomically: true, encoding: .utf8)
    let invalidFileForm = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "done", "current", "--file", resultFile.path, "unexpected"],
        environment: targetEnvironment,
        input: nil
    )
    try expect(invalidFileForm.status == 2, "parley done --file accepted trailing report text")
    let binaryFile = directory.appendingPathComponent("delegation-result.bin")
    try Data([0xff, 0xfe, 0x00]).write(to: binaryFile)
    let binaryResult = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "done", "current", "--file", binaryFile.path],
        environment: targetEnvironment,
        input: nil
    )
    try expect(binaryResult.status != 0, "parley done --file accepted non-UTF-8 bytes")
    try expect(
        broker.handoffs().first(where: { $0.id == fileHandoffID })?.state == .waiting,
        "a rejected binary file completed the delegation"
    )
    let doneFile = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "done", "current", "--file", resultFile.path],
        environment: targetEnvironment,
        input: nil
    )
    try expect(
        doneFile.status == 0 && doneFile.stdoutText.contains("staged for explicit review"),
        "parley done --file did not reach the local broker: status \(doneFile.status), stdout \(doneFile.stdoutText), stderr \(doneFile.stderrText)"
    )
    let fileHandoff = try require(
        broker.handoffs().first(where: { $0.id == fileHandoffID }),
        "shim file-result handoff disappeared"
    )
    let fileReviewID = try require(fileHandoff.resultContextReviewID, "shim file result was not linked to review")
    let fileReview = try require(
        broker.contextReviews().first(where: { $0.id == fileReviewID }),
        "shim did not create the returned-file review"
    )
    try expect(
        fileReview.state == .draft
            && fileReview.pack.parts.first?.capturedText == resultText
            && fileReview.pack.parts.first?.source.kind == .agentFileDraft,
        "shim file result bypassed review or changed its source"
    )
    let waitedFile = try runner.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [executable, "wait", fileHandoffID],
        environment: sourceEnvironment,
        input: nil
    )
    try expect(
        waitedFile.status == 0
            && waitedFile.stdoutText.contains(fileReviewID)
            && !waitedFile.stdoutText.contains("formatting survives"),
        "parley wait did not return the compact linked review receipt"
    )

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
        // Expected: prompts are bounded before they reach a terminal.
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

    let terminal = try builder.terminalSelection(
        paneID: "%7",
        paneName: "Review shell",
        text: "Only the selected terminal text"
    )
    try expect(terminal.source.kind == .visibleTerminal, "terminal-selection context lost its source kind")
    try expect(terminal.source.detail.contains("%7") && terminal.text == "Only the selected terminal text", "terminal-selection context changed its explicit capture")
    let reviewedHandoff = try statusHandoff(
        id: "reviewed-result",
        kind: .ask,
        state: .completed,
        sourceWorkspaceID: "@source",
        targetWorkspaceID: "@target",
        occurredAt: 80,
        text: "Review the exact cancellation behavior.",
        resultText: "Cancellation remains distinct from interruption.",
        sourceName: "Claude",
        targetName: "Codex"
    )
    let handoffResult = try builder.handoffResult(reviewedHandoff)
    try expect(handoffResult.source.kind == .handoffResult, "a selected handoff result lost its provenance kind")
    try expect(handoffResult.source.referenceID == reviewedHandoff.id, "a selected handoff result lost its durable handoff identity")
    try expect(
        handoffResult.source.detail.contains("Claude") && handoffResult.source.detail.contains("Codex"),
        "a selected handoff result lost its exact route"
    )
    try expect(
        handoffResult.text.contains(reviewedHandoff.text)
            && handoffResult.text.contains(reviewedHandoff.resultText ?? ""),
        "a selected handoff result omitted its question or returned result"
    )

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
    let pane = WorkbenchPane(
        id: "%browser", kind: .claude, customName: "Researcher",
        terminalTitle: "Browser task completed successfully", cwd: directory.path,
        currentCommand: "claude", isActive: true, workspaceID: "@0",         relayEnabled: true, protocolVersion: AgentProtocol.version,
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

    let stopped = WorkbenchPane(
        id: "%stopped", kind: .codex, customName: nil, terminalTitle: "", cwd: directory.path,
        currentCommand: "codex", isActive: false, workspaceID: "@0",         isStarted: false
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
        conclusions: "The authenticated handoff is the durable evidence primitive.",
        rationale: "It preserves the real source, target and lifecycle without a parallel board.",
        confidence: "High, based on the completed cross-vendor checks.",
        openQuestions: "How should official vendor hooks report turn completion?",
        now: createdAt
    )
    try expect(brief.createdAt == createdAt && brief.updatedAt == createdAt, "workspace brief timestamps were not stable")

    let concise = WorkspaceBrief(
        workspaceID: "@concise",
        workspaceName: "concise",
        goal: "Keep attached briefs focused.",
        constraints: "",
        decisions: ""
    ).renderedText
    try expect(
        !concise.contains("Investigation conclusions:")
            && !concise.contains("Rationale:")
            && !concise.contains("Confidence (person-authored):")
            && !concise.contains("Open questions:"),
        "empty investigation fields added noise to a concise workspace brief"
    )

    let builder = ContextPackBuilder()
    let ordinary = try builder.terminalSelection(paneID: "%1", paneName: "Claude", text: "Selected output only")
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
    try expect(
        withBrief.contains("Investigation conclusions")
            && withBrief.contains(brief.conclusions)
            && withBrief.contains(brief.rationale)
            && withBrief.contains(brief.confidence)
            && withBrief.contains(brief.openQuestions),
        "an explicitly attached workspace brief omitted its durable investigation record"
    )
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
        conclusions: brief.conclusions,
        rationale: brief.rationale,
        confidence: brief.confidence,
        openQuestions: brief.openQuestions,
        now: Date(timeIntervalSince1970: 120)
    )
    try expect(updated.id == brief.id && updated.createdAt == createdAt, "updating a workspace brief created a second identity")
    let updatedBriefs = try store.briefs()
    try expect(updatedBriefs.count == 1, "one workspace acquired multiple briefs")
    let legacyFile = directory.appendingPathComponent("legacy-workspace-briefs.json")
    let legacyJSON = """
    {"version":1,"briefs":[{"id":"legacy","workspaceID":"@legacy","workspaceName":"Legacy","goal":"Keep the old brief readable.","constraints":"","decisions":"Existing decision.","createdAt":0,"updatedAt":0}]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyFile.path)
    let legacy = try require(
        try WorkspaceBriefStore(file: legacyFile).brief(workspaceID: "@legacy"),
        "a legacy workspace brief did not survive the investigation-field migration"
    )
    try expect(
        legacy.conclusions.isEmpty
            && legacy.rationale.isEmpty
            && legacy.confidence.isEmpty
            && legacy.openQuestions.isEmpty,
        "missing investigation fields were invented while loading a legacy workspace brief"
    )
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
    let ordinary = try builder.terminalSelection(paneID: "%1", paneName: "Claude", text: "Implementation complete")
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
    var handoff = try statusHandoff(
        id: "diagnostic-failure",
        kind: .ask,
        state: .failed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 100,
        text: secrets[0],
        resultText: nil,
        attention: .targetUnavailable,
        sourceName: secrets[2],
        targetName: secrets[3],
        transitionDetail: secrets[4],
        transitionCount: 25
    )
    handoff.retryDisposition = .safe
    var reviewed = try statusHandoff(
        id: "diagnostic-review",
        kind: .ask,
        state: .completed,
        sourceWorkspaceID: "@0",
        targetWorkspaceID: "@1",
        occurredAt: 105,
        text: "PRIVATE_REVIEW_QUESTION",
        resultText: secrets[1]
    )
    reviewed.inReplyToHandoffID = handoff.id
    reviewed.relationship = .challenge
    reviewed.humanVerdict = .accepted
    reviewed.humanReviewNote = secrets[4]
    reviewed.reviewedAt = Date(timeIntervalSince1970: 108)
    let recoverySignal = RelayActivityEvent(
        kind: .vendorSessionStarted,
        occurredAt: Date(timeIntervalSinceReferenceDate: 110),
        workspaceID: "@1",
        workspaceName: secrets[5],
        paneID: handoff.targetPaneID,
        paneName: secrets[3],
        paneKind: .claude,
        detail: secrets[9],
        origin: .automation
    )
    let pane = WorkbenchPane(
        id: "%77",
        kind: .codex,
        customName: secrets[2],
        terminalTitle: secrets[7],
        cwd: "/tmp/\(secrets[5])",
        currentCommand: secrets[6],
        isActive: true,
        workspaceID: "@0",
        relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: secrets[5],
        inputAvailable: true,
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
        terminalAvailable: true,
        coreAvailable: false,
        workspaceCount: 2,
        panes: [pane],
        handoffs: [handoff, reviewed],
        activityEvents: [recoverySignal],
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
    try expect(report.schemaVersion == 3, "coordination diagnostics did not advance their schema")
    try expect(report.coordination.usage.askHandoffs == 2, "diagnostics lost Ask usage")
    try expect(report.coordination.usage.challengeHandoffs == 1, "diagnostics lost Challenge usage")
    try expect(report.coordination.usage.verifyHandoffs == 0, "diagnostics invented Verify usage")
    try expect(report.coordination.usage.reviewedResults == 1, "diagnostics lost person-owned review usage")
    try expect(report.coordination.usage.vendorSignals == 1, "diagnostics lost authoritative vendor signals")
    try expect(report.coordination.delivery.totalHandoffs == 2, "delivery quality used the wrong population")
    try expect(report.coordination.delivery.preDeliveryFailures == 1, "delivery quality lost a safe failed attempt")
    try expect(report.coordination.delivery.returnedResults == 1, "delivery quality miscounted returned results")
    try expect(
        report.coordination.eventReplay.retainedHandoffTransitions == 26
            && report.coordination.eventReplay.retainedActivityEvents == 1
            && report.coordination.eventReplay.retainedVendorSignals == 1,
        "diagnostics did not measure the content-free replay window"
    )
    try expect(
        report.coordination.recovery.authoritativeSamples == 1
            && report.coordination.recovery.medianMilliseconds == 10_000
            && report.coordination.recovery.maximumMilliseconds == 10_000,
        "diagnostics did not measure authoritative failure-to-session recovery"
    )
    try expect(
        report.coordination.eventReplay.oldestEventAt == Date(timeIntervalSinceReferenceDate: 100)
            && report.coordination.eventReplay.newestEventAt == Date(timeIntervalSinceReferenceDate: 124),
        "diagnostics reported the wrong retained replay window"
    )


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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Lead", terminalTitle: "", cwd: "/tmp/a", currentCommand: "codex", isActive: true, workspaceID: "@0", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Reviewer", terminalTitle: "", cwd: "/tmp/a", currentCommand: "agy", isActive: false, workspaceID: "@0", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "a", isStarted: true),
        WorkbenchPane(id: "%3", kind: .claude, customName: "Builder", terminalTitle: "", cwd: "/tmp/b", currentCommand: "claude", isActive: false, workspaceID: "@1", relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "b", isStarted: true),
        WorkbenchPane(id: "%4", kind: .copilot, customName: "Stopped", terminalTitle: "", cwd: "/tmp/b", currentCommand: "sleep", isActive: false, workspaceID: "@1", workspaceName: "b", isStarted: false),
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
    let resumeActivity = RelayActivityEvent(
        id: "resume-requested",
        kind: .paneResumeRequested,
        occurredAt: Date(timeIntervalSince1970: 70),
        workspaceID: "@0",
        workspaceName: "a",
        paneID: "%1",
        paneName: "Lead",
        paneKind: .codex,
        detail: "Codex owns the session picker."
    )
    let resumed = StatusCenterProjection.snapshot(
        panes: panes,
        handoffs: [],
        activityEvents: [resumeActivity],
        workspaceID: "@0",
        coreAvailable: true
    )
    try expect(
        resumed.timeline.first?.category == "PANE"
            && resumed.timeline.first?.action == "RESUME REQUESTED",
        "Status Center claimed vendor-owned Resume had restored a conversation"
    )

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

    let source = WorkbenchPane(
        id: completedAsk.sourcePaneID,
        kind: .codex,
        customName: "Builder",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "codex",
        isActive: false,
        workspaceID: "@0",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        inputAvailable: true,
        isStarted: true
    )
    let target = WorkbenchPane(
        id: completedAsk.targetPaneID,
        kind: .codex,
        customName: "Codex Reviewer",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "codex",
        isActive: false,
        workspaceID: "@0",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        inputAvailable: true,
        isStarted: true
    )
    let route = try require(
        CollaborationHistoryRepeat.route(for: completedAsk, panes: [source, target]),
        "a completed Ask with two live distinct panes could not be prepared again"
    )
    try expect(route.sourcePaneID == source.id && route.targetPaneID == target.id, "Ask This Again changed the recorded route")
    try expect(CollaborationHistoryRepeat.route(for: failedRelay, panes: [source, target]) == nil, "Ask This Again accepted a non-Ask handoff")
    let staleTarget = WorkbenchPane(
        id: target.id,
        kind: target.kind,
        customName: target.customName,
        terminalTitle: target.terminalTitle,
        cwd: target.cwd,
        currentCommand: target.currentCommand,
        isActive: target.isActive,
        workspaceID: target.workspaceID,
        relayEnabled: target.relayEnabled,
        protocolVersion: "v0",
        workspaceName: target.workspaceName,
        inputAvailable: target.inputAvailable,
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
        WorkbenchPane(id: "%source", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0", workspaceName: "app"),
        WorkbenchPane(id: "%target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, workspaceID: "@0", workspaceName: "app"),
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
        WorkbenchPane(
            id: "%source", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp",
            currentCommand: "codex", isActive: true, workspaceID: "@0",             relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            inputAvailable: true, automationPolicy: .off
        ),
        WorkbenchPane(
            id: "%target", kind: .claude, customName: "Reviewer", terminalTitle: "", cwd: "/tmp",
            currentCommand: "claude", isActive: false, workspaceID: "@0",             relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
            inputAvailable: true
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

    let automaticResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        do {
            automaticResult.set(try client.askFromUI(
                sourcePaneID: "%source",
                targetPaneID: "%target",
                text: "Return one explicit Auto-stage result.",
                idempotencyKey: "smart-origin-check",
                origin: .automation
            ))
        } catch {
            automaticResult.set(RelayTextResponse(status: 599, text: error.localizedDescription))
        }
    }
    try expect(eventually { broker.handoffs().contains { $0.idempotencyKey == "smart-origin-check" } }, "Auto Ask did not create durable history")
    let automatic = try require(
        broker.handoffs().first { $0.idempotencyKey == "smart-origin-check" },
        "Auto Ask history disappeared"
    )
    try expect(
        automatic.transitions.prefix(3).allSatisfy { $0.origin == .automation },
        "Auto Ask was presented as a human-dispatched handoff"
    )
    let automaticAnswer = broker.handleAnswer(token: targetToken, consultationID: "current", text: "Explicit Auto result")
    try expect(automaticAnswer.status == 200, "the Auto Ask target could not return its correlated answer")
    try expect(eventually { automaticResult.value != nil }, "Auto Ask remained blocked after its answer returned")
}

private func checkRecoveryGuidanceProjectsKnownFailures() throws {
    let dead = WorkbenchPane(
        id: "%dead",
        kind: .codex,
        customName: "Exited Codex",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "codex",
        isActive: false,
        workspaceID: "@0",
                relayEnabled: true,
        protocolVersion: AgentProtocol.version,
        workspaceName: "a",
        isDead: true,
        exitStatus: 9,
        isStarted: true
    )
    let stale = WorkbenchPane(
        id: "%stale",
        kind: .agy,
        customName: "Older Agy",
        terminalTitle: "",
        cwd: "/tmp/a",
        currentCommand: "agy",
        isActive: true,
        workspaceID: "@0",
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
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
    try expect(retained.count == 500, "app-resident core retained \(retained.count) completed handoffs instead of its 500-record bound")
    try expect(retained.contains(where: { $0.idempotencyKey == "retention-509" }), "retention discarded the newest handoff")
    try expect(!retained.contains(where: { $0.idempotencyKey == "retention-0" }), "retention kept the oldest handoff")
}

private func checkDurableHandoffJournal() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let targetToken = try credentials.token(for: "%2")
    let panes = [
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, workspaceID: "@0", workspaceName: "repo-a"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, workspaceID: "@1", workspaceName: "repo-b"),
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex A", terminalTitle: "", cwd: "/tmp/repo-a", currentCommand: "codex", isActive: true, workspaceID: "@0", workspaceName: "repo-a"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy B", terminalTitle: "", cwd: "/tmp/repo-b", currentCommand: "agy", isActive: false, workspaceID: "@1", workspaceName: "repo-b"),
        WorkbenchPane(id: "%3", kind: .claude, customName: "Claude C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "claude", isActive: false, workspaceID: "@2", workspaceName: "repo-c"),
        WorkbenchPane(id: "%4", kind: .codex, customName: "Codex C", terminalTitle: "", cwd: "/tmp/repo-c", currentCommand: "codex", isActive: false, workspaceID: "@2", workspaceName: "repo-c"),
        WorkbenchPane(id: "%5", kind: .claude, customName: "Claude Duplicate", terminalTitle: "", cwd: "/tmp/duplicate-a", currentCommand: "claude", isActive: false, workspaceID: "@3", workspaceName: "repo-a"),
        WorkbenchPane(id: "%6", kind: .codex, customName: "Codex Duplicate", terminalTitle: "", cwd: "/tmp/duplicate-a", currentCommand: "codex", isActive: false, workspaceID: "@3", workspaceName: "repo-a"),
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp/api", currentCommand: "codex", isActive: true, workspaceID: "@0", workspaceName: "api"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/api", currentCommand: "agy", isActive: false, workspaceID: "@0", workspaceName: "api"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp/web", currentCommand: "agy", isActive: false, workspaceID: "@1", workspaceName: "web"),
        WorkbenchPane(id: "%4", kind: .claude, customName: "Critic", terminalTitle: "", cwd: "/tmp/web", currentCommand: "claude", isActive: false, workspaceID: "@1", workspaceName: "web", role: "reviewer"),
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
        WorkbenchPane(id: "%5", kind: .copilot, customName: "Second critic", terminalTitle: "", cwd: "/tmp/web", currentCommand: "copilot", isActive: false, workspaceID: "@1", workspaceName: "web", role: "reviewer"),
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

private func checkRelayFilesystemRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
    try transport.start()
    try expect(
        !FileManager.default.fileExists(atPath: queuedResponse.path),
        "app-resident transport startup preserved an uncertain stale response"
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

private func checkRelayFilesystemStartupRemovesOrphanedEndpoints() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    _ = try credentials.token(for: "%1")
    let broker = RelayBroker(credentials: credentials, panes: { [] }, paste: { _, _ in }, submit: { _, _ in })
    let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    let orphanedEndpoint = RelayFileTransport.endpointDirectory(
        runtimeDirectory: runtime,
        paneToken: String(repeating: "a", count: 48)
    )
    try FileManager.default.createDirectory(at: orphanedEndpoint, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: orphanedEndpoint.path
    )

    let transport = RelayFileTransport(broker: broker, credentials: credentials, runtimeDirectory: runtime)
    try transport.start()
    defer { transport.stop() }

    try expect(
        !FileManager.default.fileExists(atPath: orphanedEndpoint.path),
        "filesystem relay startup retained an endpoint whose credential was revoked"
    )
}

private func checkLargeCoreActivityResponseIsComplete() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let token = try credentials.token(for: "%1")
    let panes = [
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
                throw ParleyWorkbenchError.unsafeRelayTarget("Agy")
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Planner", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0", automationPolicy: .off),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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

    let codexTwoToken = try credentials.token(for: "%4")
    let sameVendorSubmissions = LockedSubmissions()
    let sameVendorBroker = RelayBroker(
        credentials: credentials,
        panes: {
            panes + [
                WorkbenchPane(id: "%4", kind: .codex, customName: "Codex Two", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
            ]
        },
        paste: { _, _ in },
        submit: { paneID, prompt in sameVendorSubmissions.append(paneID: paneID, text: prompt) },
        consultationTimeout: 2,
        livenessPollInterval: 0.01
    )
    let sameVendorResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        sameVendorResult.set(sameVendorBroker.handleAskManyFromUI(
            sourcePaneID: "%1",
            targetPaneIDs: ["%2", "%4"],
            text: "Compare these recommendations independently.",
            idempotencyKey: "human-compare-same-vendor"
        ))
    }
    try expect(
        eventually { sameVendorBroker.consultations().count == 2 },
        "same-vendor comparison did not establish two independent consultations"
    )
    try expect(
        Set(sameVendorSubmissions.values.map(\.paneID)) == Set(["%2", "%4"]),
        "same-vendor comparison did not submit to both distinct panes"
    )
    try expect(
        sameVendorBroker.handleAnswer(token: codexToken, consultationID: "current", text: "First Codex answer").status == 200,
        "the first same-vendor comparison target could not answer"
    )
    try expect(
        sameVendorBroker.handleAnswer(token: codexTwoToken, consultationID: "current", text: "Second Codex answer").status == 200,
        "the second same-vendor comparison target could not answer"
    )
    try expect(eventually { sameVendorResult.value?.status == 200 }, "same-vendor comparison did not return its ordered bundle")
}

private func checkHumanAskManyCoreControlRoute() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    _ = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        WorkbenchPane(id: "%1", kind: .claude, customName: "Lead", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0", automationPolicy: .off),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
    let source = WorkbenchPane(
        id: "%1", kind: .codex, customName: "Builder", terminalTitle: "", cwd: "/tmp/app",
        currentCommand: "codex", isActive: true, workspaceID: "@0",         relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
        inputAvailable: true, isStarted: true
    )
    let target = WorkbenchPane(
        id: "%2", kind: .codex, customName: "Codex Reviewer", terminalTitle: "", cwd: "/tmp/app",
        currentCommand: "codex", isActive: false, workspaceID: "@0",         relayEnabled: true, protocolVersion: AgentProtocol.version, workspaceName: "app",
        inputAvailable: true, isStarted: true
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
        sourceWorkspaceID: source.workspaceID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.workspaceID,
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
        sourceWorkspaceID: source.workspaceID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.workspaceID,
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
            sourceWorkspaceID: source.workspaceID,
            sourceWorkspaceName: source.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.workspaceID,
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
            sourceWorkspaceID: source.workspaceID,
            sourceWorkspaceName: source.workspaceName,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            targetWorkspaceID: target.workspaceID,
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
        sourceWorkspaceID: source.workspaceID,
        sourceWorkspaceName: source.workspaceName,
        targetPaneID: target.id,
        targetName: target.displayName,
        targetKind: target.kind,
        targetWorkspaceID: target.workspaceID,
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
                throw ParleyWorkbenchError.unsafeRelayTarget("Codex")
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
        WorkbenchPane(id: "%1", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
    ]
    let attempts = LockedCounter()
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in
            attempts.increment()
            throw ParleyWorkbenchError.commandFailed("submit failed after paste")
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
    let source = WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0")
    let target = WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0")
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
        WorkbenchPane(id: "%1", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
    let askStderr = LockedString()
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
            askStderr.set(output.stderrText)
        } catch {
            askResult.set(RelayTextResponse(status: -1, text: error.localizedDescription))
        }
    }

    try expect(eventually { broker.consultations().count == 1 }, "parley ask did not reach the local broker")
    let consultation = try require(broker.consultations().first, "shim consultation disappeared")
    try expect(consultation.state == .awaitingAnswer, "shim Ask was not submitted automatically")
    let outbox = transportDirectory
        .appendingPathComponent(sourceToken, isDirectory: true)
        .appendingPathComponent("outbox", isDirectory: true)
    func earlyReceiptID() -> String? {
        guard let responses = try? FileManager.default.contentsOfDirectory(
            at: outbox,
            includingPropertiesForKeys: nil
        ) else { return nil }
        for response in responses {
            let receipt = response.appendingPathComponent("handoff-id")
            if let value = try? String(contentsOf: receipt, encoding: .utf8) {
                return value
            }
        }
        return nil
    }
    try expect(
        eventually { earlyReceiptID() == consultation.id },
        "filesystem transport did not publish the Ask id before the answer"
    )
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
    try expect(
        askStderr.value == "Parley Ask ID: \(consultation.id)\n",
        "parley ask did not print its recoverable id once on stderr"
    )
}

private func checkAskManyShimRoundTrip() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let sourceToken = try credentials.token(for: "%1")
    let codexToken = try credentials.token(for: "%2")
    let agyToken = try credentials.token(for: "%3")
    let panes = [
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp", currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: "/tmp", currentCommand: "codex", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: "/tmp", currentCommand: "agy", isActive: false, workspaceID: "@0"),
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

 private func checkAgentContextDraftsRequireHumanApprovalBeforeAsk() throws {
    let directory = try temporaryDirectory()
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let claudeToken = try credentials.token(for: "%1")
    let reviewerToken = try credentials.token(for: "%2")
    let panes = [
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: "/tmp/project", currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Claude Reviewer", terminalTitle: "", cwd: "/tmp/project", currentCommand: "claude", isActive: false, workspaceID: "@0"),
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
    let hidden = broker.contextDraft(token: reviewerToken, draftID: stagedReview.id)
    try expect(hidden.status == 404, "another pane could inspect a source pane's unsent context")

    let askResult = LockedAskResult()
    DispatchQueue.global(qos: .utility).async {
        askResult.set(broker.handleContextAsk(
            token: claudeToken,
            draftID: stagedReview.id,
            target: "%2",
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

    let returned = broker.handleAnswer(token: reviewerToken, consultationID: "current", text: "The fatal error is unconditional.")
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
        WorkbenchPane(
            id: "%1",
            kind: .claude,
            customName: "Claude",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "claude",
            isActive: true,
            workspaceID: "@0"
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
        WorkbenchPane(
            id: "%1",
            kind: .claude,
            customName: "Claude",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "claude",
            isActive: true,
            workspaceID: "@0"
        ),
        WorkbenchPane(
            id: "%2",
            kind: .codex,
            customName: "Codex",
            terminalTitle: "",
            cwd: directory.path,
            currentCommand: "codex",
            isActive: false,
            workspaceID: "@0"
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, workspaceID: "@0"),
        WorkbenchPane(id: "%3", kind: .agy, customName: "Agy", terminalTitle: "", cwd: directory.path, currentCommand: "agy", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .claude, customName: "Claude Reviewer", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, workspaceID: "@0"),
    ]
    let broker = RelayBroker(
        credentials: credentials,
        panes: { panes },
        paste: { _, _ in },
        submit: { _, _ in },
        selectedText: { paneID in "selected output from \(paneID)" },
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, workspaceID: "@0"),
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
        WorkbenchPane(id: "%1", kind: .claude, customName: "Claude", terminalTitle: "", cwd: directory.path, currentCommand: "claude", isActive: true, workspaceID: "@0"),
        WorkbenchPane(id: "%2", kind: .codex, customName: "Codex", terminalTitle: "", cwd: directory.path, currentCommand: "codex", isActive: false, workspaceID: "@0"),
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

private func checkGhosttyAppResidentLifecycleContract() throws {
    try expect(
        AppResidentPaneLifecycle.effect(of: .closeWindow) == .keepRunning,
        "closing Parley's window must keep Ghostty pane processes alive"
    )
    try expect(
        AppResidentPaneLifecycle.effect(of: .quitApplication) == .terminate,
        "quitting Parley must terminate Ghostty pane processes"
    )
    try expect(
        AppResidentPaneLifecycle.effect(of: .stopEverything) == .terminate,
        "Stop Everything must terminate every Ghostty pane process"
    )
}

private func checkGhosttyLaunchCommandEncoding() throws {
    let rendered = GhosttyLaunchCommand.render([
        "/usr/bin/env",
        "plain",
        "folder with spaces",
        "single'quote",
        "$HOME",
        "line\nbreak",
    ])
    try expect(
        rendered == "'/usr/bin/env' 'plain' 'folder with spaces' 'single'\\''quote' '$HOME' 'line\nbreak'",
        "Ghostty launch argv was not encoded as literal shell words: \(rendered)"
    )
}

private func checkVendorSubmissionTiming() throws {
    let copilot = PaneSubmissionTiming.forKind(.copilot, submit: true)
    try expect(
        copilot == PaneSubmissionTiming(
            afterFocus: 0.1,
            afterPaste: 0.25,
            beforeRestoringFocus: 0.1
        ),
        "Copilot submission lost its focus/paste settling intervals"
    )
    for kind in [PaneKind.claude, .codex, .agy, .shell] {
        let timing = PaneSubmissionTiming.forKind(kind, submit: true)
        try expect(
            timing.afterFocus == 0 && timing.afterPaste == 0 && timing.beforeRestoringFocus == 0,
            "\(kind.label) inherited Copilot-only submission delays"
        )
    }
    let copilotPaste = PaneSubmissionTiming.forKind(.copilot, submit: false)
    try expect(
        copilotPaste.afterFocus == 0 && copilotPaste.afterPaste == 0,
        "review-only Copilot paste was delayed like a submitted handoff"
    )
}

private func checkAppResidentWorkbenchStateRoundTrip() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try WorkbenchController(
        applicationDirectory: directory,
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    )
    try first.bootstrap(cwd: directory.path)
    _ = try first.createWorkspace(folder: directory.path, name: "Second")
    let expectedWorkspaces = try first.listWorkspaces()
    let expectedPanes = try first.listPanes()

    let stateFile = directory.appendingPathComponent("workbench-state.json")
    var stored = try require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any],
        "the app-resident workbench state was not a JSON object"
    )
    var legacyPanes = try require(
        stored["panes"] as? [[String: Any]],
        "the app-resident workbench state omitted panes"
    )
    for index in legacyPanes.indices { legacyPanes[index]["windowID"] = "legacy-shared-slot" }
    stored["panes"] = legacyPanes
    stored["ownerPID"] = 0
    try JSONSerialization.data(withJSONObject: stored, options: [.prettyPrinted, .sortedKeys])
        .write(to: stateFile, options: .atomic)

    let reopened = try WorkbenchController(
        applicationDirectory: directory,
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    )
    try reopened.bootstrap(cwd: directory.path)
    let reopenedWorkspaces = try reopened.listWorkspaces()
    let reopenedPanes = try reopened.listPanes()
    try expect(
        reopenedWorkspaces.map(\.workspaceID) == expectedWorkspaces.map(\.workspaceID),
        "reopening the app-resident workbench changed durable workspace identities"
    )
    try expect(
        reopenedPanes.map(\.id) == expectedPanes.map(\.id),
        "reopening the app-resident workbench changed durable pane identities"
    )
    try expect(
        reopenedPanes.map(\.workspaceID) == expectedPanes.map(\.workspaceID),
        "reopening changed durable pane-to-workspace routing"
    )
}

private final class RecordingPaneTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputs: [(String, String, Bool)] = []
    private var recordedTerminations: [String] = []
    private var recordedTerminateAll = false

    var inputs: [(String, String, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedInputs
    }

    var terminations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTerminations
    }

    var didTerminateAll: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordedTerminateAll
    }

    func transport() -> PaneTerminalTransport {
        PaneTerminalTransport(
            paste: { [weak self] paneID, text, submit in
                guard let self else { return }
                lock.lock()
                recordedInputs.append((paneID, text, submit))
                lock.unlock()
            },
            interrupt: { _ in },
            captureSelectedText: { _ in "selected context" },
            terminate: { [weak self] paneID in
                guard let self else { return }
                lock.lock()
                recordedTerminations.append(paneID)
                lock.unlock()
            },
            terminateAll: { [weak self] in
                guard let self else { return }
                lock.lock()
                recordedTerminateAll = true
                lock.unlock()
            }
        )
    }
}

private func checkAppResidentWorkbenchRelayAndShutdown() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = try WorkbenchController(
        applicationDirectory: directory,
        environment: ["PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"]
    )
    try controller.bootstrap(cwd: directory.path)
    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let shimDirectory = directory.appendingPathComponent("bin", isDirectory: true)
    let transportDirectory = directory.appendingPathComponent("relay", isDirectory: true)
    try FileManager.default.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: transportDirectory, withIntermediateDirectories: true)
    controller.configureRelay(RelayRuntime(
        infoFile: directory.appendingPathComponent("relay-url"),
        shimDirectory: shimDirectory,
        transportDirectory: transportDirectory,
        credentials: credentials,
        runtimeMarker: "DEV"
    ))
    let recorder = RecordingPaneTransport()
    controller.configureTerminalTransport(recorder.transport())

    _ = try controller.createPane(kind: .claude, cwd: directory.path)
    let codex = try controller.createPane(kind: .codex, cwd: directory.path)
    let beforeAttach = try controller.listPanes()
    try expect(
        beforeAttach.first(where: { $0.id == codex.id })?.inputAvailable == false,
        "a new pane claimed input availability before its Ghostty surface attached"
    )
    try controller.terminalDidAttach(paneID: codex.id)
    let afterAttach = try controller.listPanes()
    try expect(
        afterAttach.first(where: { $0.id == codex.id })?.inputAvailable == true,
        "a live Ghostty attachment did not enable pane input"
    )
    try controller.terminalDidDetach(paneID: codex.id)
    let afterDetach = try controller.listPanes()
    try expect(
        afterDetach.first(where: { $0.id == codex.id })?.inputAvailable == false,
        "a detached Ghostty surface remained advertised as input-capable"
    )
    try controller.terminalDidAttach(paneID: codex.id)
    try controller.paste("review before send", into: codex.id, submit: false)
    try controller.paste("submit exactly once", into: codex.id, submit: true)

    let inputs = recorder.inputs
    try expect(inputs.count == 2, "the app-resident workbench did not deliver every relay input")
    try expect(
        inputs[0].0 == codex.id && inputs[0].1 == "review before send" && !inputs[0].2,
        "paste unexpectedly submitted or targeted the wrong Ghostty pane"
    )
    try expect(
        inputs[1].0 == codex.id && inputs[1].1 == "submit exactly once" && inputs[1].2,
        "relay did not preserve its separate submit event"
    )
    let generationBeforeRestart = codex.launchGeneration
    let tokenBeforeRestart = try credentials.token(for: codex.id)
    try controller.restartPane(codex.id)
    let restarted = try require(
        controller.listPanes().first(where: { $0.id == codex.id }),
        "the restarted pane disappeared"
    )
    try expect(restarted.launchGeneration == generationBeforeRestart + 1, "restart did not replace the Ghostty surface generation")
    try expect(!restarted.inputAvailable, "restart trusted input state from the replaced Ghostty surface")
    try expect(recorder.terminations == [codex.id], "restart did not terminate exactly the selected pane surface")
    let tokenAfterRestart = try credentials.token(for: codex.id)
    try expect(tokenAfterRestart != tokenBeforeRestart, "restart did not rotate the pane relay identity")
    let freshLaunch = try controller.launchConfiguration(for: codex.id)
    try expect(!freshLaunch.command.contains("'codex' 'resume'"), "plain restart silently resumed a Codex session")

    try controller.restartPane(codex.id, launchMode: .resume)
    let resumeLaunch = try controller.launchConfiguration(for: codex.id)
    try expect(
        resumeLaunch.command.contains("'codex' 'resume'"),
        "controller restart did not carry Resume into the replacement Ghostty generation"
    )
    try expect(
        resumeLaunch.generation == restarted.launchGeneration + 1,
        "Resume did not create a distinct replacement surface generation"
    )

    try controller.restartPane(codex.id)
    let freshAgain = try controller.launchConfiguration(for: codex.id)
    try expect(
        !freshAgain.command.contains("'codex' 'resume'"),
        "a later plain restart inherited stale Resume intent"
    )
    try controller.stopPaneProcess(codex.id)
    try controller.startPane(codex.id, launchMode: .resume)
    let stoppedResumeLaunch = try controller.launchConfiguration(for: codex.id)
    try expect(
        stoppedResumeLaunch.command.contains("'codex' 'resume'"),
        "a stopped placeholder could not launch the vendor-owned Resume path"
    )

    try controller.stopPaneProcess(codex.id)
    try controller.startPane(codex.id)
    let stoppedFreshLaunch = try controller.launchConfiguration(for: codex.id)
    try expect(
        !stoppedFreshLaunch.command.contains("'codex' 'resume'"),
        "a fresh start inherited stale Resume intent from an earlier generation"
    )

    try controller.shutdown()
    try expect(recorder.didTerminateAll, "full shutdown did not terminate every retained Ghostty surface")
    let stoppedPanes = try controller.listPanes()
    try expect(
        stoppedPanes.allSatisfy { !$0.isStarted && !$0.relayEnabled },
        "full shutdown left a pane advertised as running"
    )
}

private func checkRealGhosttyAppResidentPaneLifecycle() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let beforeHide = directory.appendingPathComponent("before-hide")
        let whileHidden = directory.appendingPathComponent("while-hidden")
        let processFile = directory.appendingPathComponent("shell-pid")

        let controller = TerminalController { builder in
            builder.withBackgroundOpacity(1)
        }
        let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        terminal.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: directory.path,
            command: GhosttyLaunchCommand.render(["/bin/zsh", "-f"]),
            waitAfterCommand: true
        )
        terminal.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = terminal
        window.orderFront(nil)

        func pump(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }

        try expect(
            terminal.paste(text: GhosttyLaunchCommand.render(["/usr/bin/touch", beforeHide.path])),
            "Ghostty refused bracketed text input"
        )
        try expect(terminal.sendKey(.enter), "Ghostty refused the separate Enter key event")
        try expect(
            pump(until: { FileManager.default.fileExists(atPath: beforeHide.path) }),
            "the visible Ghostty shell did not execute input"
        )
        try expect(
            terminal.paste(text: "echo $$ > \(GhosttyLaunchCommand.render([processFile.path]))"),
            "Ghostty refused its process-id probe"
        )
        try expect(terminal.sendKey(.enter), "Ghostty refused the process-id probe Enter")
        var reportedProcessID: pid_t?
        try expect(
            pump(until: {
                guard let text = try? String(contentsOf: processFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      let processID = pid_t(text),
                      processID > 0 else { return false }
                reportedProcessID = processID
                return true
            }),
            "the Ghostty shell did not report a valid process id"
        )
        let processID = try require(reportedProcessID, "the Ghostty shell reported an invalid process id")

        window.orderOut(nil)
        try expect(terminal.window === window, "hiding the window detached the retained Ghostty surface")
        try expect(
            terminal.paste(text: GhosttyLaunchCommand.render(["/usr/bin/touch", whileHidden.path])),
            "the hidden app-resident Ghostty surface refused input"
        )
        try expect(terminal.sendKey(.enter), "the hidden Ghostty surface refused Enter")
        try expect(
            pump(until: { FileManager.default.fileExists(atPath: whileHidden.path) }),
            "the Ghostty pane stopped when its window was hidden"
        )

        terminal.controller = nil
        try expect(
            pump(until: {
                errno = 0
                return Darwin.kill(processID, 0) != 0 && errno == ESRCH
            }),
            "tearing down the Ghostty surface did not terminate its pane process"
        )
        window.close()
    }
}

private func checkRealGhosttySixPaneInputIsolation() throws {
    try MainActor.assumeIsolated {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = TerminalController { builder in
            builder.withBackgroundOpacity(1)
        }
        var terminals: [AppTerminalView] = []
        var windows: [NSWindow] = []
        var processIDs: [pid_t] = []

        func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }

        for index in 0..<6 {
            let terminal = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
            terminal.configuration = TerminalSurfaceOptions(
                backend: .exec,
                workingDirectory: directory.path,
                command: GhosttyLaunchCommand.render(["/bin/zsh", "-f"]),
                waitAfterCommand: true
            )
            let window = NSWindow(
                contentRect: NSRect(x: 20 * index, y: 20 * index, width: 360, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentView = terminal
            terminal.controller = controller
            window.orderFront(nil)
            terminals.append(terminal)
            windows.append(window)
        }

        for index in terminals.indices {
            let marker = directory.appendingPathComponent("pane-\(index)-marker")
            let pidFile = directory.appendingPathComponent("pane-\(index)-pid")
            try expect(
                terminals[index].paste(text: "echo $$ > \(GhosttyLaunchCommand.render([pidFile.path])); /usr/bin/touch \(GhosttyLaunchCommand.render([marker.path]))"),
                "Ghostty pane \(index) refused bracketed input"
            )
            try expect(terminals[index].sendKey(.enter), "Ghostty pane \(index) refused its separate Enter event")
        }
        try expect(
            pump(until: {
                (0..<6).allSatisfy {
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent("pane-\($0)-marker").path)
                }
            }),
            "one or more Ghostty panes stopped accepting input beyond the four-pane boundary"
        )
        for index in 0..<6 {
            let pidText = try String(
                contentsOf: directory.appendingPathComponent("pane-\(index)-pid"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            processIDs.append(try require(pid_t(pidText), "Ghostty pane \(index) reported an invalid process id"))
        }

        for terminal in terminals { terminal.controller = nil }
        try expect(
            pump(until: {
                processIDs.allSatisfy {
                    errno = 0
                    return Darwin.kill($0, 0) != 0 && errno == ESRCH
                }
            }),
            "tearing down six Ghostty panes left one or more child processes alive"
        )
        for window in windows { window.close() }
    }
}

let checks: [(String, () throws -> Void)] = [
    ("complete native Settings sections", checkApplicationSettingsSectionsAreComplete),
    ("Production-only signed opt-in automatic updates", checkAutomaticUpdatesAreProductionSignedAndOptIn),
    ("bounded safe terminal font preference", checkTerminalFontPreferenceIsBoundedAndSafe),
    ("strictly allowlisted Ghostty appearance import", checkGhosttyAppearanceImportIsStrictlyAllowlisted),
    ("pane state uses durable workspace and Ghostty input identity", checkPaneStateUsesDurableWorkspaceAndGhosttyInputIdentity),
    ("native tracked Ask preserves formatting intent", checkNativeAskRequestCarriesFormattingIntent),
    ("Ghostty app-resident lifecycle", checkGhosttyAppResidentLifecycleContract),
    ("Ghostty launch command encoding", checkGhosttyLaunchCommandEncoding),
    ("vendor submission timing", checkVendorSubmissionTiming),
    ("app-resident workbench state round-trip", checkAppResidentWorkbenchStateRoundTrip),
    ("app-resident workbench relay and shutdown", checkAppResidentWorkbenchRelayAndShutdown),
    ("real Ghostty app-resident pane lifecycle", checkRealGhosttyAppResidentPaneLifecycle),
    ("real Ghostty six-pane input isolation", checkRealGhosttySixPaneInputIsolation),
    ("runtime namespaces are explicit and disjoint", checkRuntimeNamespacesAreExplicitAndDisjoint),
    ("runtime termination choice survives dead agents", checkRuntimeTerminationChoiceSurvivesDeadAgents),
    ("useful copyable build information", checkBuildInformationIsUsefulAndCopyable),
    ("vendor-neutral local permission profiles", checkPermissionProfilesAreVendorNeutralAndLocal),
    ("pane-owned truthful Task Manager projection", checkTaskManagerProjectionIsPaneOwnedAndTruthful),
    ("owned bounded throttled sidebar workspace facts", checkSidebarWorkspaceFactsAreOwnedBoundedAndThrottled),
    ("pane root resolver owns only marked app-owned launch trees", checkPaneRootResolverOwnsOnlyMarkedLaunchTrees),
    ("pane anchor fallback feeds Task Manager and ports", checkPaneAnchorFallbackFeedsTaskManagerAndPorts),
    ("listening-port sampling is honest about failures", checkListeningPortSamplingIsHonestAboutFailures),
    ("listening-port refresh state retains and forces", checkListeningPortRefreshStateRetainsAndForces),
    ("soak pane evidence fails closed", checkSoakPaneEvidenceFailsClosed),
    ("vendor permission state is never inferred from terminal text", checkVendorPermissionStateIsNotInferredFromTerminalText),
    ("runtime UI lease refuses duplicate owners", checkRuntimeUILeaseRefusesDuplicateOwners),
    ("child process cannot retain runtime UI lease", checkChildProcessCannotRetainRuntimeUILease),
    ("UTF-8 locale fallback preserves explicit configuration", checkUTF8LocaleFallbackPreservesExplicitConfiguration),
    ("workspace continuity state", checkWorkspaceContinuityState),
    ("durable workspace registry", checkWorkspaceRegistryDurability),
    ("workspace folder attachment model", checkWorkspaceFolderAttachmentModel),
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
    ("chrome chip case is sentence case", checkChromeChipCaseIsSentenceCaseForStateLabels),
    ("workbench notice lane is prioritised and never hides facts", checkWorkbenchNoticeLaneIsPrioritisedAndNeverHidesFacts),
    ("workbench notice lane represents every worktree collision", checkWorkbenchNoticeLaneRepresentsEveryWorktreeCollision),
    ("status center segments map handoffs and counts", checkStatusCenterSegmentsMapHandoffsAndCounts),
    ("delegation visibility uses owned timestamps only", checkDelegationVisibilityIsComputedFromOwnedTimestampsOnly),
    ("delegation visibility requires an exact delivered transition", checkDelegationVisibilityRequiresAnExactDeliveredTransition),
    ("delegate recipe guidance requests milestones and file results", checkDelegateRecipeGuidanceRequestsMilestonesAndFileResults),
    ("request changes is one linked delegate child", checkRequestChangesIsOneLinkedDelegateChild),
    ("request changes shim form names its parent", checkRequestChangesShimFormNamesItsParent),
    ("handoff thread projection orders lineage chronologically", checkHandoffThreadProjectionOrdersLineageChronologically),
    ("request changes copy is title case and names a linked delegate", checkRequestChangesCopyIsTitleCaseAndNamesALinkedDelegate),
    ("delegation git snapshot is bounded paths only", checkDelegationGitSnapshotIsBoundedPathsOnly),
    ("delegation git capture failures are informational", checkDelegationGitCaptureFailuresAreInformational),
    ("delegation git comparison derives changed paths honestly", checkDelegationGitComparisonDerivesChangedPathsHonestly),
    ("delegation git facts are recorded without changing outcomes", checkDelegationGitFactsAreRecordedWithoutChangingOutcomes),
    ("delegation git facts export preserves paths only", checkDelegationGitFactsExportPreservesPathsOnly),
    ("delegation cancelled during git capture is never submitted", checkDelegationCancelledDuringGitCaptureIsNeverSubmitted),
    ("delegation git path display escapes control characters", checkDelegationGitPathDisplayEscapesControlCharacters),
    ("delegation git facts survive fast completion during submit", checkDelegationGitFactsSurviveFastCompletionDuringSubmit),
    ("delegation git path display escapes unicode format controls", checkDelegationGitPathDisplayEscapesUnicodeFormatControls),
    ("completion evidence parses three headings in any order", checkCompletionEvidenceParsesThreeHeadingsInAnyOrder),
    ("completion evidence ignores unknown headings and preserves bodies", checkCompletionEvidenceIgnoresUnknownHeadingsAndPreservesBodies),
    ("completion evidence duplicate empty missing and bounds", checkCompletionEvidenceDuplicateEmptyMissingAndBounds),
    ("completion evidence only reads the exact returned file", checkCompletionEvidenceOnlyReadsTheExactReturnedFile),
    ("completion evidence wording is agent-declared", checkCompletionEvidenceWordingIsAgentDeclared),
    ("review and correct recipe is a prompt template only", checkReviewAndCorrectRecipeIsAPromptTemplateOnly),
    ("handoff recipe store migrates older documents additively", checkHandoffRecipeStoreMigratesOlderDocumentsAdditively),
    ("review and correct guidance is documented as practice", checkReviewAndCorrectGuidanceIsDocumentedAsPractice),
    ("review and correct requires two targets from different vendors", checkReviewAndCorrectRequiresTwoTargetsFromDifferentVendors),
    ("adjacent navigation order", checkAdjacentNavigationOrder),
    ("menu-safe periodic refresh", checkMenuTrackingRefreshPolicy),
    ("Pane menu remains stable during live updates", checkPaneMenuSurvivesUpdatesWhileTracking),
    ("Ask toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Ask") }),
    ("Review toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Review") }),
    ("Context toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Context") }),
    ("Recipes toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Recipes") }),
    ("Return toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Return") }),
    ("Actions toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Actions") }),
    ("Waiting toolbar menu remains stable during live updates", { try checkToolbarMenuSurvivesUpdatesWhileTracking("Waiting") }),
    ("detailed in-app help coverage", checkInAppHelpGuideCoverage),
    ("workbench state projection", checkWorkbenchStateProjection),
    ("Precision Grid chrome uses owned state", checkPrecisionGridChromeUsesOwnedState),
    ("saved workspace layout persistence and fresh slots", checkSavedWorkspaceLayoutPersistenceAndFreshSlots),
    ("portable team template persistence and application", checkPortableTeamTemplatePersistenceAndApplication),
    ("external workspace open contract", checkExternalWorkspaceOpenContract),
    ("external editor context import contract", checkExternalEditorContextImportContract),
    ("content-free external attention and navigation contract", checkExternalAttentionAndNavigationContract),
    ("bounded menu bar attention inbox", checkMenuBarAttentionInboxProjection),
    ("mandatory pane-scoped agent process boundary", checkAgentProcessBoundaryIsMandatoryAndPaneScoped),
    ("native workspace layout tree", checkNativeWorkspaceLayoutTree),
    ("window and split geometry recovery", checkWindowAndSplitGeometryRecovery),
    ("pane attention is authoritative and aged", checkPaneAttentionProjectionIsAuthoritativeAndAged),
    ("composer signal provenance is exact, aged and advisory", checkComposerSignalProvenanceIsExactAgedAndAdvisory),
    ("workbench keyboard shortcut routing", checkWorkbenchKeyboardShortcuts),
    ("idle agent reaper gates", checkIdleAgentReaperGates),
    ("vendor-owned resume plans are explicit and safe", checkVendorOwnedResumePlansAreExplicitAndSafe),
    ("shared protocol launch adapters", checkSharedProtocolLaunchAdapters),
    ("agent awareness local reference across projects", checkAgentAwarenessReferenceAcrossProjects),
    ("agent awareness boundaries and command recovery", checkAgentAwarenessBoundariesAndRecovery),
    ("SwiftPM compatibility is installed only for agent launches", checkSwiftPMCompatibilityLaunchScope),
    ("SwiftPM compatibility preserves argv and selected toolchain", checkSwiftPMCompatibilityArgumentsAndToolchain),
    ("SwiftPM compatibility requires opt-in and snapshots each launch", checkSwiftPMCompatibilityOptInAndRestart),
    ("SwiftPM compatibility loads an unrelated real package manifest", checkSwiftPMCompatibilityWithRealManifest),
    ("authenticated agent discovery and resumable events", checkAuthenticatedAgentDiscoveryAndResumableEvents),
    ("official vendor hook adapters and authenticated signals", checkOfficialVendorHookAdaptersAndSignals),
    ("linked handoff review primitives", checkLinkedHandoffReviewPrimitives),
    ("bounded supervised workflow lifecycle", checkBoundedSupervisedWorkflowLifecycle),
    ("smart orchestration modes and safety boundaries", checkSmartOrchestrationModesAndBoundaries),
    ("supervised lead workflow policy and cancellation", checkSupervisedLeadWorkflowPolicyAndCancellation),
    ("tracked delegation completion and wait", checkTrackedDelegationCompletesAndWaits),
    ("bounded target-owned delegation progress", checkTrackedDelegationProgressIsBoundedOwnedAndDurable),
    ("bounded owned reviewed delegation file results", checkDelegationFileResultsAreBoundedOwnedAndReviewed),
    ("detached Ask recovery is durable and generation-bound", checkDetachedAskRecoveryIsDurableAndGenerationBound),
    ("tracked delegation failure and liveness", checkTrackedDelegationFailureAndLiveness),
    ("tracked delegation shim round trip", checkDelegationShimRoundTrip),
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
    ("relay filesystem round trip", checkRelayFilesystemRoundTrip),
    ("relay shim filesystem transport", checkRelayShimUsesPinnedFilesystemTransport),
    ("protected filesystem relay runtime", checkRelayFilesystemRuntimeIsProtectedAndStopsCleanly),
    ("orphaned filesystem relay endpoint cleanup", checkRelayFilesystemStartupRemovesOrphanedEndpoints),
    ("complete large core activity response", checkLargeCoreActivityResponseIsComplete),
    ("core control survives UI reattachment", checkCoreControlSurvivesClientReattachment),
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
]

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

if ProcessInfo.processInfo.environment["PARLEY_ANCHOR_SLEEP_CHILD"] == "1" {
    // A long-lived, non-platform child for the pane anchor checks: platform
    // binaries such as /bin/sleep hide their environment from other processes.
    sleep(120)
    exit(0)
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

// `--only <substring>` runs the matching checks alone during local iteration.
let onlyFilter = argument(named: "--only")?.lowercased()
let selectedChecks = (checks + reviewRegressionChecks).filter { name, _ in
    onlyFilter.map { name.lowercased().contains($0) } ?? true
}
var failureCount = 0
for (name, check) in selectedChecks {
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
print("All \(selectedChecks.count) native checks passed")
