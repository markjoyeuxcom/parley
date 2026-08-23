import AppKit
import Foundation
import ParleyCore
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class TerminalHandle: ObservableObject {
    weak var terminal: LocalProcessTerminalView?

    var selectedText: String? {
        guard let selected = terminal?.getSelection(), !selected.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selected
    }

    func focus() {
        guard let terminal else { return }
        terminal.window?.makeFirstResponder(terminal)
    }
}

struct WorkspaceAskGroup: Identifiable {
    let workspace: TmuxWorkspace
    let panes: [TmuxPane]

    var id: String { workspace.id }
}

struct ActiveRecipeRun: Identifiable, Equatable {
    let id: String
    let recipeName: String
    let leadPaneID: String
    let leadName: String
    let submittedAt: Date
    let instructions: String
}

struct PaletteCommand: Identifiable, Sendable {
    enum Action: Sendable {
        case openWorkspace
        case openStatusCenter
        case selectWorkspace(TmuxWorkspace)
        case selectPane(TmuxPane)
        case ask(TmuxPane)
        case activity(RelayHandoff)
    }

    let item: CommandPaletteItem
    let action: Action

    var id: String { item.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var panes: [TmuxPane] = []
    @Published private(set) var workspaces: [TmuxWorkspace] = []
    @Published private(set) var consultations: [RelayConsultation] = []
    @Published private(set) var handoffs: [RelayHandoff] = []
    @Published private(set) var unreadHandoffs: [RelayHandoff] = []
    @Published private(set) var statusHandoffs: [RelayHandoff] = []
    @Published private(set) var statusActivityEvents: [RelayActivityEvent] = []
    @Published private(set) var controller: TmuxController?
    @Published private(set) var recentFolders: [String] = []
    @Published private(set) var favouriteFolders: [String] = []
    @Published private(set) var projectContexts: [String: GitProjectContext] = [:]
    @Published private(set) var savedLayouts: [SavedWorkspaceLayout] = []
    @Published private(set) var recipes: [HandoffRecipe] = []
    @Published private(set) var activeRecipeRun: ActiveRecipeRun?
    @Published private(set) var coreAvailable = false
    @Published private(set) var tmuxAvailable = false
    @Published private(set) var coreError: String?
    @Published private(set) var tmuxError: String?
    @Published private(set) var coreUpgradePending = false
    @Published private(set) var coreUpgradeMessage: String?
    @Published private(set) var notificationWorkspaceNames: Set<String> = []
    @Published private(set) var dismissedHandoffIDs: Set<String> = []
    @Published private(set) var runtimeReadiness: RuntimeReadinessSnapshot?
    @Published private(set) var runtimeReadinessChecking = false
    @Published private(set) var diagnosticsExporting = false
    @Published private(set) var coreLoginItemState: CoreLoginItemState = .unavailable
    @Published private(set) var coreLoginItemChanging = false
    @Published private(set) var preparingToUninstall = false
    @Published var commandPalettePresented = false
    @Published var setupPresented = false
    @Published var startupError: String?

    let terminalHandle = TerminalHandle()
    private let fallbackFolder: String
    private let applicationDirectory: URL
    private let layoutStore: SavedWorkspaceLayoutStore
    private let recipeStore: HandoffRecipeStore
    private var workspaceContinuity = WorkspaceContinuityState()
    private let projectContextResolver = GitProjectContextResolver()
    private var projectContextRefreshTask: Task<Void, Never>?
    private var projectContextFolders: Set<String> = []
    private var lastProjectContextRefresh = Date.distantPast
    private var relayClient: RelayCoreClient?
    private var reviewDraftBuilder: ReviewDraftBuilder?
    private let notificationEpoch = Date()
    private var observedNotificationEventIDs: Set<String> = []
    private var runtimeReadinessTask: Task<Void, Never>?
    private var coreUpgradeTask: Task<Void, Never>?
    private var coreUpgradeSettled = false
    private var lastCoreUpgradeAttempt = Date.distantPast
    private let coreLoginItemController = CoreLoginItemController()
    private static let recentFoldersKey = "parley.recentWorkspaceFolders"
    private static let workspaceContinuityKey = "parley.workspaceContinuity"
    private static let notificationWorkspacesKey = "parley.notificationWorkspaces"
    private static let dismissedHandoffsKey = "parley.dismissedStatusHandoffs"
    private static let firstRunCompletedKey = "parley.firstRunReadinessCompleted"
    private static let projectContextRefreshInterval: TimeInterval = 5

    init() {
        let requestedFolder = Self.argument(named: "--cwd")
        let initialFolder = requestedFolder ?? FileManager.default.currentDirectoryPath
        fallbackFolder = URL(fileURLWithPath: initialFolder).standardizedFileURL.path
        applicationDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
        layoutStore = SavedWorkspaceLayoutStore(
            file: applicationDirectory.appendingPathComponent("workspace-layouts.json")
        )
        recipeStore = HandoffRecipeStore(
            file: applicationDirectory.appendingPathComponent("handoff-recipes.json")
        )
        recipes = (try? recipeStore.recipes()) ?? HandoffRecipe.defaults
        UserDefaultsDomainMigration.copyMissing(
            keys: [
                Self.recentFoldersKey,
                Self.workspaceContinuityKey,
                Self.notificationWorkspacesKey,
                Self.dismissedHandoffsKey,
            ],
            from: "parley-native",
            to: .standard
        )
        recentFolders = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.workspaceContinuityKey),
           let decoded = try? JSONDecoder().decode(WorkspaceContinuityState.self, from: data) {
            workspaceContinuity = decoded
        }
        favouriteFolders = workspaceContinuity.favouriteFolders
        notificationWorkspaceNames = Set(
            UserDefaults.standard.stringArray(forKey: Self.notificationWorkspacesKey) ?? []
        )
        dismissedHandoffIDs = Set(
            UserDefaults.standard.stringArray(forKey: Self.dismissedHandoffsKey) ?? []
        )
        setupPresented = !UserDefaults.standard.bool(forKey: Self.firstRunCompletedKey)

        do {
            let controller = try TmuxController()
            try controller.bootstrap(cwd: defaultFolder)
            var livePanes = try controller.listPanes()
            var liveWorkspaces = try controller.listWorkspaces()
            let credentials = try RelayCredentials(
                file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
            )
            try credentials.retain(paneIDs: Set(livePanes.map(\.id)))
            let agentTransportDirectory = RelayFileTransport.runtimeDirectory(
                applicationDirectory: controller.applicationDirectory
            )
            let shimDirectory = try RelayShim.install(
                in: controller.applicationDirectory,
                transportDirectory: agentTransportDirectory
            )
            // Persistent tmux panes retain the PATH they were born with. Put a
            // managed copy in the user's existing stable command directory so
            // reattaching the UI upgrades relay access without killing those
            // agent conversations. A foreign `parley` command is never replaced.
            _ = try RelayShim.installCommand(
                in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
                transportDirectory: agentTransportDirectory
            )
            let infoFile = controller.applicationDirectory.appendingPathComponent("relay-url")
            controller.configureRelay(RelayRuntime(
                infoFile: infoFile,
                shimDirectory: shimDirectory,
                transportDirectory: agentTransportDirectory,
                credentials: credentials
            ))
            let relayClient: RelayCoreClient?
            do {
                relayClient = try RelayCoreLauncher.ensureRunning(
                    applicationDirectory: controller.applicationDirectory,
                    cwd: defaultFolder,
                    environment: controller.environment
                )
                coreAvailable = true
                coreError = nil
            } catch {
                relayClient = nil
                coreAvailable = false
                coreError = error.localizedDescription
                startupError = "The Parley relay is unavailable. Your terminal panes are still available.\n\n\(error.localizedDescription)"
            }
            // This migration is destructive and therefore opt-in at process
            // launch. Normal UI reattachment always preserves conversations.
            if Self.hasArgument("--restart-stale-protocol") {
                for paneID in AgentProtocol.stalePaneIDs(in: livePanes) {
                    try controller.restartPane(paneID)
                }
                livePanes = try controller.listPanes()
            }
            if let previous = workspaceContinuity.selectedWorkspace(in: liveWorkspaces),
               !previous.isActive {
                try controller.selectWorkspace(previous.id)
                liveWorkspaces = try controller.listWorkspaces()
            }
            liveWorkspaces = workspaceContinuity.reconcile(liveWorkspaces)
            if let selected = liveWorkspaces.first(where: \.isActive) {
                workspaceContinuity.markSelected(selected)
            }
            favouriteFolders = workspaceContinuity.favouriteFolders
            saveWorkspaceContinuity()
            self.controller = controller
            self.relayClient = relayClient
            tmuxAvailable = true
            tmuxError = nil
            reviewDraftBuilder = ReviewDraftBuilder(environment: controller.environment)
            panes = livePanes
            workspaces = liveWorkspaces
            savedLayouts = try layoutStore.layouts()
            rememberFolder(defaultFolder)
            scheduleProjectContextRefresh(force: true)
        } catch {
            coreAvailable = false
            tmuxAvailable = false
            tmuxError = error.localizedDescription
            startupError = error.localizedDescription
        }
        refreshCoreLoginItemState()
        refreshRuntimeReadiness()
        scheduleCoreUpgradeCheck(force: true)
    }

    var activeWorkspace: TmuxWorkspace? { workspaces.first(where: \.isActive) }

    var defaultFolder: String { activeWorkspace?.defaultFolder ?? fallbackFolder }

    var visiblePanes: [TmuxPane] {
        guard let workspaceID = activeWorkspace?.id else { return panes }
        return panes.filter { $0.windowID == workspaceID }
    }

    var activePane: TmuxPane? { visiblePanes.first(where: \.isActive) }

    func showEnvironmentCheck() {
        setupPresented = true
        refreshRuntimeReadiness()
    }

    var coreLoginItemRequested: Bool { coreLoginItemState.isRegistered }

    var canChangeCoreLoginItem: Bool {
        coreLoginItemState != .unavailable && !coreLoginItemChanging && !preparingToUninstall
    }

    var canPrepareToUninstall: Bool {
        coreAvailable && relayClient != nil && coreUpgradeTask == nil && !preparingToUninstall
    }

    func refreshCoreLoginItemState() {
        let refreshed = coreLoginItemController.state
        if refreshed != coreLoginItemState { coreLoginItemState = refreshed }
    }

    func setCoreLoginItemRequested(_ requested: Bool) {
        guard !coreLoginItemChanging, !preparingToUninstall else { return }
        if requested == coreLoginItemRequested { return }

        do {
            if !requested {
                guard coreAvailable, let relayClient else {
                    throw RelayUIError.message(
                        "Reconnect Parley's coordination core before turning off launch at login, so active work can be checked safely."
                    )
                }
                let activeConsultationCount = try relayClient.consultations().count
                let history = try relayClient.handoffs(limit: 500)
                guard CoreLoginItemChangePolicy.canDisable(
                    activeConsultationCount: activeConsultationCount,
                    handoffs: history
                ) else {
                    throw RelayUIError.message(
                        "Launch at login cannot be turned off while an Ask or tracked delegation is active. Finish or cancel that work first."
                    )
                }
            }
        } catch {
            NSAlert(error: error).runModal()
            refreshCoreLoginItemState()
            return
        }

        coreLoginItemChanging = true
        Task { [weak self] in
            guard let self else { return }
            do {
                if requested {
                    try self.coreLoginItemController.register()
                } else {
                    try await self.coreLoginItemController.unregister()
                    self.relayClient = nil
                    self.coreAvailable = false
                    try self.reconnectConnections()
                }
                self.refreshCoreLoginItemState()
                self.coreLoginItemChanging = false
            } catch {
                self.refreshCoreLoginItemState()
                self.coreLoginItemChanging = false
                NSAlert(error: error).runModal()
            }
        }
    }

    func openCoreLoginItemSettings() {
        coreLoginItemController.openSystemSettings()
    }

    func prepareToUninstall() {
        guard canPrepareToUninstall, let relayClient else { return }

        let confirmation = NSAlert()
        confirmation.messageText = "Prepare Parley for Uninstallation?"
        confirmation.informativeText = "Parley will refuse if Ask or delegated work is active, turn off launch at login, stop only the coordination core, and quit. Your tmux panes, workspace layouts, and local collaboration history will not be deleted."
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Prepare and Quit")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        preparingToUninstall = true
        coreUpgradeSettled = true
        var transaction = RelayCoreUninstallTransaction(
            loginItemWasRegistered: coreLoginItemRequested
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let eligible = try await Task.detached(priority: .utility) {
                    let consultations = try relayClient.consultations()
                    let handoffs = try relayClient.handoffs(limit: 500)
                    return CoreLoginItemChangePolicy.canDisable(
                        activeConsultationCount: consultations.count,
                        handoffs: handoffs
                    )
                }.value
                guard eligible else {
                    throw RelayUIError.message(
                        "Parley cannot prepare for uninstallation while an Ask or tracked delegation is active. Finish or cancel that work first."
                    )
                }

                let response = try await Task.detached(priority: .utility) {
                    try relayClient.stopIfIdle()
                }.value
                guard response.status == 202 else {
                    throw RelayUIError.message(Self.uninstallBlockedMessage(response.readiness))
                }
                transaction.recordCoreStopAccepted()

                if transaction.loginItemWasRegistered {
                    try await self.coreLoginItemController.unregister()
                    transaction.recordLoginItemDisabled()
                    self.refreshCoreLoginItemState()
                }
                transaction.recordPreparationCompleted()
                self.relayClient = nil
                self.coreAvailable = false
                self.coreError = nil

                let ready = NSAlert()
                ready.messageText = "Parley Is Ready to Remove"
                ready.informativeText = "The launch item and coordination core are stopped. After Parley quits, move Parley.app to Trash. Your running tmux panes and local data remain untouched."
                ready.addButton(withTitle: "Quit Parley")
                ready.runModal()
                NSApp.terminate(nil)
            } catch {
                self.refreshCoreLoginItemState()
                if transaction.loginItemWasRegistered && !self.coreLoginItemRequested {
                    transaction.recordLoginItemDisabled()
                }
                var rollbackFailure: Error?
                if transaction.requiresLoginItemRollback {
                    do {
                        try self.coreLoginItemController.register()
                        self.refreshCoreLoginItemState()
                    } catch {
                        rollbackFailure = error
                    }
                }
                self.preparingToUninstall = false
                self.coreUpgradeSettled = false
                self.scheduleCoreUpgradeCheck(force: true)

                let alert = NSAlert()
                alert.messageText = "Parley Was Not Prepared for Uninstallation"
                if let rollbackFailure {
                    alert.informativeText = "\(error.localizedDescription)\n\nLaunch at login could not be restored automatically: \(rollbackFailure.localizedDescription). Check System Settings → General → Login Items before removing Parley."
                } else {
                    alert.informativeText = error.localizedDescription
                }
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private static func uninstallBlockedMessage(_ readiness: RelayUpgradeReadiness) -> String {
        let active = readiness.activeConsultations + readiness.activeDelegations
        if active > 0 {
            return "Parley cannot stop its coordination core while \(active) Ask or delegated item\(active == 1 ? " is" : "s are") active. Finish or cancel that work first."
        }
        return "Parley could not stop its coordination core because a handoff began during the uninstall check. Launch at login has been restored; try again when the handoff finishes."
    }

    func refreshRuntimeReadiness() {
        runtimeReadinessTask?.cancel()
        runtimeReadinessChecking = true
        let environment = controller?.environment ?? EnvironmentResolver.resolved()
        let applicationDirectory = applicationDirectory
        let coreHealthy = coreAvailable
        let paneSnapshot = panes
        let checker = RuntimeReadinessChecker()
        runtimeReadinessTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                checker.check(
                    environment: environment,
                    applicationDirectory: applicationDirectory,
                    coreHealthy: coreHealthy,
                    panes: paneSnapshot
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.runtimeReadiness = snapshot
            self?.runtimeReadinessChecking = false
        }
    }

    func completeEnvironmentCheck() {
        UserDefaults.standard.set(true, forKey: Self.firstRunCompletedKey)
        setupPresented = false
        terminalHandle.focus()
    }

    func exportDiagnostics() {
        guard !diagnosticsExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Parley Diagnostics"
        panel.message = "Saves local health and process-state facts. Prompts, answers, terminal contents, names, folders, credentials, journals, and logs are excluded."
        panel.prompt = "Export"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.diagnosticsFilename()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var history = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        if let relayClient, let refreshed = try? relayClient.handoffs(limit: 500) {
            history = refreshed
            if refreshed != statusHandoffs { statusHandoffs = refreshed }
        }
        let report = makeDiagnosticsReport(handoffs: history)
        diagnosticsExporting = true
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try DiagnosticsArchiveWriter().write(report: report, to: destination)
                }.value
                guard let self else { return }
                self.diagnosticsExporting = false
                let alert = NSAlert()
                alert.messageText = "Diagnostics Exported"
                alert.informativeText = "Parley saved a privacy-bounded diagnostics ZIP to \(destination.lastPathComponent). Nothing was uploaded."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } catch {
                guard let self else { return }
                self.diagnosticsExporting = false
                NSAlert(error: error).runModal()
            }
        }
    }

    private func makeDiagnosticsReport(handoffs: [RelayHandoff]) -> DiagnosticsReport {
        let info = Bundle.main.infoDictionary ?? [:]
        let application = DiagnosticsApplication(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unbundled-development-build",
            version: info["CFBundleShortVersionString"] as? String ?? "development",
            build: info["CFBundleVersion"] as? String ?? "development"
        )
        let corePID = (try? String(
            contentsOf: applicationDirectory.appendingPathComponent("core.pid"),
            encoding: .utf8
        ))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        return DiagnosticsReportBuilder.build(
            application: application,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.processArchitecture,
            uiResidentBytes: DiagnosticsProcessMemory.residentBytes(
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            coreResidentBytes: corePID.flatMap(DiagnosticsProcessMemory.residentBytes),
            tmuxAvailable: tmuxAvailable,
            coreAvailable: coreAvailable,
            workspaceCount: workspaces.count,
            panes: panes,
            handoffs: handoffs,
            readiness: runtimeReadiness
        )
    }

    private static func diagnosticsFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return "Parley-Diagnostics-\(formatter.string(from: date)).zip"
    }

    private static var processArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    var connectionState: WorkbenchConnectionState {
        WorkbenchStateProjection.connection(
            tmuxAvailable: tmuxAvailable,
            coreAvailable: coreAvailable
        )
    }

    var activePaneState: WorkbenchPaneState {
        WorkbenchStateProjection.pane(activePane)
    }

    var canNavigateWorkspaces: Bool { workspaces.count > 1 }

    var canNavigatePanes: Bool { visiblePanes.count > 1 }

    func projectContext(for pane: TmuxPane) -> GitProjectContext? {
        let folder = URL(fileURLWithPath: pane.cwd).standardizedFileURL.path
        return projectContexts[folder]
    }

    var paletteCommands: [PaletteCommand] {
        var commands = [
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "action:open-workspace",
                    category: .action,
                    title: "Open Workspace…",
                    detail: "Choose a folder and open or select its workspace",
                    keywords: ["folder", "project", "new"]
                ),
                action: .openWorkspace
            ),
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "action:status-center",
                    category: .action,
                    title: "Open Status Center",
                    detail: "Inspect live collaboration, agents, results and activity",
                    keywords: ["handoff", "history", "health"]
                ),
                action: .openStatusCenter
            ),
        ]

        commands += workspaces.map { workspace in
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "workspace:\(workspace.id)",
                    category: .workspace,
                    title: workspace.name,
                    detail: workspace.defaultFolder,
                    keywords: [workspace.isActive ? "current selected" : "open"]
                ),
                action: .selectWorkspace(workspace)
            )
        }

        commands += panes.map { pane in
            let workspace = workspaces.first(where: { $0.id == pane.windowID })?.name
                ?? pane.workspaceName
                ?? pane.windowID
            let context = projectContext(for: pane)
            let git = context.map { "\($0.branch) \($0.isDirty ? "dirty" : "clean")" } ?? ""
            return PaletteCommand(
                item: CommandPaletteItem(
                    id: "pane:\(pane.id)",
                    category: .pane,
                    title: pane.displayName,
                    detail: "\(workspace) · \(pane.cwd)",
                    keywords: [pane.kind.label, pane.currentCommand, git, pane.isStarted ? "running" : "stopped"]
                ),
                action: .selectPane(pane)
            )
        }

        commands += askTargets.map { pane in
            let workspace = workspaces.first(where: { $0.id == pane.windowID })?.name
                ?? pane.workspaceName
                ?? pane.windowID
            return PaletteCommand(
                item: CommandPaletteItem(
                    id: "ask:\(pane.id)",
                    category: .ask,
                    title: "Ask \(pane.displayName)",
                    detail: "\(workspace) · \(pane.kind.label)",
                    keywords: [pane.cwd, "question", "consult"]
                ),
                action: .ask(pane)
            )
        }

        let activity = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        commands += activity.prefix(30).map { handoff in
            let subject = Self.paletteSubject(handoff.text)
            return PaletteCommand(
                item: CommandPaletteItem(
                    id: "activity:\(handoff.id)",
                    category: .activity,
                    title: "\(handoff.sourceName) → \(handoff.targetName)",
                    detail: "\(handoff.kind.rawValue.uppercased()) · \(handoff.state.rawValue.uppercased()) · \(subject)",
                    keywords: [
                        handoff.sourceWorkspaceName ?? "",
                        handoff.targetWorkspaceName ?? "",
                        handoff.resultText ?? "",
                    ]
                ),
                action: .activity(handoff)
            )
        }
        return commands
    }

    func showCommandPalette() {
        commandPalettePresented = true
    }

    func performPaletteCommand(_ command: PaletteCommand) {
        switch command.action {
        case .openWorkspace:
            createWorkspace()
        case .openStatusCenter:
            break
        case let .selectWorkspace(workspace):
            select(workspace)
        case let .selectPane(pane):
            select(pane)
        case let .ask(target):
            ask(target)
        case let .activity(handoff):
            let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
            let preferTarget = activeStates.contains(handoff.state) || !handoff.hasReturnedResult
            if canFocus(preferTarget ? handoff.targetPaneID : handoff.sourcePaneID) {
                focus(handoff, target: preferTarget)
            } else {
                focus(handoff, target: !preferTarget)
            }
        }
    }

    var askTargets: [TmuxPane] {
        guard let source = activePane,
              source.kind.isAgent,
              source.isStarted,
              !source.isDead,
              source.relayEnabled,
              source.hasCurrentProtocol else { return [] }
        return panes.filter {
            $0.kind.isAgent
                && $0.kind != source.kind
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var localAskTargets: [TmuxPane] {
        guard let workspaceID = activeWorkspace?.id else { return [] }
        return askTargets.filter { $0.windowID == workspaceID }
    }

    var workspaceLead: TmuxPane? {
        guard let workspaceID = activeWorkspace?.id else { return nil }
        return panes.first { $0.windowID == workspaceID && $0.isWorkspaceLead }
    }

    var recipeTargets: [TmuxPane] {
        guard let lead = workspaceLead else { return [] }
        return panes.filter {
            $0.windowID == lead.windowID
                && $0.id != lead.id
                && $0.kind.isAgent
                && $0.kind != lead.kind
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    func canRun(_ recipe: HandoffRecipe) -> Bool {
        guard let workspace = activeWorkspace,
              let lead = workspaceLead,
              lead.isStarted,
              !lead.isDead,
              lead.relayEnabled,
              lead.hasCurrentProtocol,
              recipe.kind.isAllowed(by: workspace.automationPolicy) else { return false }
        return recipeTargets.count >= (recipe.kind == .askMany ? 2 : 1)
    }

    var otherWorkspaceAskGroups: [WorkspaceAskGroup] {
        workspaces.compactMap { workspace in
            guard !workspace.isActive else { return nil }
            let targets = askTargets.filter { $0.windowID == workspace.id }
            return targets.isEmpty ? nil : WorkspaceAskGroup(workspace: workspace, panes: targets)
        }
    }

    var activePaneConsultations: [RelayConsultation] {
        guard let activePane else { return [] }
        return consultations.filter {
            $0.targetPaneID == activePane.id && $0.state == .awaitingAnswer
        }
    }

    var legacyReturnTarget: TmuxPane? {
        guard let requesterID = activePane?.returnToPaneID else { return nil }
        return panes.first(where: { $0.id == requesterID })
    }

    var canReturn: Bool { !activePaneConsultations.isEmpty || legacyReturnTarget != nil }

    var workspaceHandoffs: [RelayHandoff] {
        guard let workspaceID = activeWorkspace?.id else { return handoffs }
        return handoffs.filter {
            $0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID
        }
    }

    var primaryActivity: RelayHandoff? {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return workspaceHandoffs.first(where: { activeStates.contains($0.state) })
            ?? workspaceHandoffs.first
    }

    var activeDelegations: [RelayHandoff] {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting]
        return handoffs.filter { $0.kind == .delegate && activeStates.contains($0.state) }
    }

    func awaitingAnswerCount(for paneID: String) -> Int {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return handoffs.count { $0.targetPaneID == paneID && activeStates.contains($0.state) }
    }

    func latestFailure(for paneID: String) -> RelayHandoff? {
        handoffs.first {
            $0.targetPaneID == paneID && ($0.state == .failed || $0.state == .interrupted)
        }
    }

    func unreadResultCount(forPane paneID: String) -> Int {
        unreadHandoffs.count { $0.sourcePaneID == paneID }
    }

    func unreadResultCount(forWorkspace workspaceID: String) -> Int {
        unreadHandoffs.count { $0.sourceWorkspaceID == workspaceID }
    }

    func waitingCount(for workspaceID: String) -> Int {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return handoffs.count {
            activeStates.contains($0.state)
                && ($0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID)
        }
    }

    func failureCount(for workspaceID: String) -> Int {
        handoffs.count {
            ($0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID)
                && ($0.state == .failed || $0.state == .interrupted)
        }
    }

    func requiresHumanAttention(_ workspaceID: String) -> Bool {
        handoffs.contains {
            ($0.sourceWorkspaceID == workspaceID || $0.targetWorkspaceID == workspaceID)
                && $0.state == .failed
                && $0.attention != nil
        }
    }

    func notificationsEnabled(for workspace: TmuxWorkspace) -> Bool {
        notificationWorkspaceNames.contains(workspace.name)
    }

    func setNotificationsEnabled(_ enabled: Bool, for workspace: TmuxWorkspace) {
        if !enabled {
            notificationWorkspaceNames.remove(workspace.name)
            saveNotificationWorkspaces()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    showNotificationAlert("Notifications are disabled for Parley in System Settings.")
                    return
                }
                notificationWorkspaceNames.insert(workspace.name)
                saveNotificationWorkspaces()
            } catch {
                showNotificationAlert("Parley could not enable notifications: \(error.localizedDescription)")
            }
        }
    }

    var attachConfiguration: AttachConfiguration? {
        guard let controller else { return nil }
        var environment = controller.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return AttachConfiguration(
            executable: controller.tmuxExecutable.path,
            arguments: controller.attachArguments(),
            environment: environment.map { "\($0.key)=\($0.value)" },
            cwd: defaultFolder
        )
    }

    func refresh() throws {
        var firstError: Error?
        if let controller {
            do {
                var refreshedWorkspaces = try controller.listWorkspaces()
                let previousContinuity = workspaceContinuity
                refreshedWorkspaces = workspaceContinuity.reconcile(refreshedWorkspaces)
                if let selected = refreshedWorkspaces.first(where: \.isActive) {
                    workspaceContinuity.markSelected(selected)
                }
                if workspaceContinuity != previousContinuity {
                    favouriteFolders = workspaceContinuity.favouriteFolders
                    saveWorkspaceContinuity()
                }
                if refreshedWorkspaces != workspaces { workspaces = refreshedWorkspaces }
                let refreshedPanes = try controller.listPanes()
                if refreshedPanes != panes { panes = refreshedPanes }
                tmuxAvailable = true
                tmuxError = nil
            } catch {
                tmuxAvailable = false
                tmuxError = error.localizedDescription
                firstError = error
            }
        } else {
            tmuxAvailable = false
        }
        if let relayClient {
            do {
                let refreshedConsultations = try relayClient.consultations()
                if refreshedConsultations != consultations { consultations = refreshedConsultations }
                let refreshedHandoffs = try relayClient.handoffs(limit: 24)
                if refreshedHandoffs != handoffs { handoffs = refreshedHandoffs }
                let refreshedUnread = try relayClient.unreadHandoffs()
                if refreshedUnread != unreadHandoffs { unreadHandoffs = refreshedUnread }
                processNotifications(from: refreshedHandoffs + refreshedUnread)
                coreAvailable = true
                coreError = nil
            } catch {
                coreAvailable = false
                coreError = error.localizedDescription
                if firstError == nil { firstError = error }
            }
        } else {
            coreAvailable = false
        }
        if tmuxAvailable { scheduleProjectContextRefresh() }
        if let firstError { throw firstError }
    }

    var canRetryConnections: Bool { controller != nil && !preparingToUninstall }

    func retryConnections() {
        perform {
            try reconnectConnections()
        }
    }

    private func reconnectConnections() throws {
        guard let controller else {
            throw RelayUIError.message("Parley could not initialise tmux. Quit and reopen the app after resolving the startup error.")
        }
        if !tmuxAvailable {
            try controller.bootstrap(cwd: defaultFolder)
        }
        if !coreAvailable {
            relayClient = try RelayCoreLauncher.ensureRunning(
                applicationDirectory: controller.applicationDirectory,
                cwd: defaultFolder,
                environment: controller.environment
            )
        }
        coreUpgradeSettled = false
        scheduleCoreUpgradeCheck(force: true)
        try refresh()
        startupError = nil
    }

    func refreshQuietly() {
        do { try refresh() } catch { /* the attached client may be between tmux redraws */ }
        scheduleCoreUpgradeCheck()
    }

    private func scheduleCoreUpgradeCheck(force: Bool = false) {
        guard coreUpgradeTask == nil, !coreUpgradeSettled, !preparingToUninstall, let controller else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCoreUpgradeAttempt) >= 2 else { return }
        lastCoreUpgradeAttempt = now

        let client = relayClient
        let expectedIdentity = CoreServiceIdentity.resolve(infoDictionary: Bundle.main.infoDictionary)
        let applicationDirectory = applicationDirectory
        let cwd = defaultFolder
        let environment = controller.environment
        coreUpgradeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Task.detached(priority: .utility) {
                    let attached: RelayCoreClient
                    if let client, client.isHealthy() {
                        attached = client
                    } else {
                        attached = try RelayCoreLauncher.ensureRunning(
                            applicationDirectory: applicationDirectory,
                            cwd: cwd,
                            environment: environment
                        )
                    }
                    return try RelayCoreHandover.reconcile(
                        client: attached,
                        expectedIdentity: expectedIdentity,
                        applicationDirectory: applicationDirectory,
                        cwd: cwd,
                        environment: environment
                    )
                }.value
                self.relayClient = result.client
                self.coreAvailable = true
                self.coreError = nil
                switch result.outcome {
                case .current:
                    self.coreUpgradePending = false
                    self.coreUpgradeMessage = "The coordination core matches this Parley build."
                    self.coreUpgradeSettled = true
                case .replaced:
                    self.coreUpgradePending = false
                    self.coreUpgradeMessage = "The coordination core was upgraded without restarting any panes."
                    self.coreUpgradeSettled = true
                    if self.startupError?.hasPrefix("The Parley relay is unavailable") == true {
                        self.startupError = nil
                    }
                case let .deferred(readiness):
                    self.coreUpgradePending = true
                    self.coreUpgradeMessage = Self.coreUpgradePendingMessage(readiness)
                }
            } catch {
                self.coreUpgradePending = true
                self.coreUpgradeMessage = "Automatic core upgrade will retry: \(error.localizedDescription)"
                self.coreError = error.localizedDescription
            }
            self.coreUpgradeTask = nil
        }
    }

    private static func coreUpgradePendingMessage(_ readiness: RelayUpgradeReadiness) -> String {
        var work: [String] = []
        if readiness.activeConsultations > 0 {
            work.append("\(readiness.activeConsultations) active Ask")
        }
        if readiness.activeDelegations > 0 {
            work.append("\(readiness.activeDelegations) active delegation")
        }
        if readiness.activeDispatches > 0 {
            work.append("a handoff currently being delivered")
        }
        let detail = work.isEmpty ? "coordination work" : work.joined(separator: ", ")
        return "Upgrade pending until \(detail) finishes. Agent panes and tmux sessions remain running."
    }

    func refreshStatusCenterQuietly() {
        refreshCoreLoginItemState()
        do {
            try refresh()
            guard let relayClient else { return }
            let history = try relayClient.handoffs(limit: 500)
            if history != statusHandoffs { statusHandoffs = history }
            let activity = try relayClient.activityEvents(limit: 500)
            if activity != statusActivityEvents { statusActivityEvents = activity }
            let retainedDismissals = StatusCenterVisibility.retainedDismissalIDs(
                dismissedHandoffIDs,
                handoffs: history
            )
            if retainedDismissals != dismissedHandoffIDs {
                dismissedHandoffIDs = retainedDismissals
                saveDismissedHandoffs()
            }
            processNotifications(from: history)
        } catch {
            // Availability flags are updated by refresh; the last authoritative
            // snapshot stays visible instead of being replaced with guessed state.
        }
    }

    private func scheduleProjectContextRefresh(force: Bool = false) {
        let folders = Set(visiblePanes.map {
            URL(fileURLWithPath: $0.cwd).standardizedFileURL.path
        })
        let foldersChanged = folders != projectContextFolders
        let isDue = Date().timeIntervalSince(lastProjectContextRefresh) >= Self.projectContextRefreshInterval
        guard projectContextRefreshTask == nil, force || foldersChanged || isDue else { return }

        projectContextFolders = folders
        lastProjectContextRefresh = Date()
        guard !folders.isEmpty else {
            projectContexts = [:]
            return
        }

        let resolver = projectContextResolver
        projectContextRefreshTask = Task.detached(priority: .utility) { [folders, resolver] in
            let contexts = resolver.contexts(for: folders)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.projectContextRefreshTask = nil
                let currentFolders = Set(self.visiblePanes.map {
                    URL(fileURLWithPath: $0.cwd).standardizedFileURL.path
                })
                guard currentFolders == folders else {
                    self.scheduleProjectContextRefresh(force: true)
                    return
                }
                if contexts != self.projectContexts {
                    self.projectContexts = contexts
                }
            }
        }
    }

    func statusSnapshot(workspaceID: String?, includeDismissed: Bool = false) -> StatusCenterSnapshot {
        StatusCenterProjection.snapshot(
            panes: panes,
            handoffs: statusHandoffs.isEmpty ? handoffs : statusHandoffs,
            activityEvents: statusActivityEvents,
            workspaceID: workspaceID,
            coreAvailable: coreAvailable,
            dismissedHandoffIDs: dismissedHandoffIDs,
            includeDismissed: includeDismissed
        )
    }

    func isDismissed(_ handoff: RelayHandoff) -> Bool {
        dismissedHandoffIDs.contains(handoff.id)
            && StatusCenterVisibility.isDismissible(handoff)
    }

    func dismissFromStatusCenter(_ handoff: RelayHandoff) {
        guard StatusCenterVisibility.isDismissible(handoff) else { return }
        dismissedHandoffIDs.insert(handoff.id)
        saveDismissedHandoffs()
    }

    func restoreToStatusCenter(_ handoff: RelayHandoff) {
        dismissedHandoffIDs.remove(handoff.id)
        saveDismissedHandoffs()
    }

    func restoreAllStatusCenterDismissals() {
        dismissedHandoffIDs.removeAll()
        saveDismissedHandoffs()
    }

    func deleteStatusHistory(for workspace: TmuxWorkspace) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete collaboration history for \(workspace.name)?"
        alert.informativeText = "This permanently deletes completed, cancelled, failed, and interrupted Ask, Delegate, Relay, and Paste records involving this workspace, plus its recorded pane and workspace lifecycle events. Active work is preserved. Returned answers are included, and this cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            guard let relayClient else {
                throw RelayUIError.message("The Parley coordination core is unavailable.")
            }
            let response = try relayClient.deleteWorkspaceHistory(
                workspaceID: workspace.id,
                workspaceName: workspace.name
            )
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            refreshStatusCenterQuietly()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func markRead(_ handoff: RelayHandoff) {
        guard handoff.hasUnreadResult, let relayClient else { return }
        do {
            let response = try relayClient.markHandoffRead(handoff.id)
            guard response.status == 200 else { return }
            refreshStatusCenterQuietly()
        } catch {
            // The regular refresh owns connection health. A persistent core
            // from the previous UI build may not know this control route yet;
            // leave the result unread instead of misreporting the core as down.
            refreshQuietly()
        }
    }

    func create(_ kind: PaneKind, direction: SplitDirection) {
        create(kind, direction: direction, folder: defaultFolder)
    }

    func createInChosenFolder(_ kind: PaneKind, direction: SplitDirection) {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the new \(kind.label) pane"
        panel.prompt = direction == .horizontal ? "Split Right" : "Split Below"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: activePane?.cwd ?? defaultFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        create(kind, direction: direction, folder: url.standardizedFileURL.path)
    }

    private func create(_ kind: PaneKind, direction: SplitDirection, folder: String) {
        perform {
            guard let controller else { return }
            let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
            _ = try controller.createPane(kind: kind, cwd: standardized, direction: direction)
            rememberFolder(standardized)
            try refresh()
            terminalHandle.focus()
        }
    }

    func select(_ pane: TmuxPane) {
        perform {
            try controller?.selectPane(pane.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func select(_ workspace: TmuxWorkspace) {
        perform {
            try controller?.selectWorkspace(workspace.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func selectAdjacentWorkspace(by offset: Int) {
        guard let targetID = NavigationOrder.adjacentID(
            currentID: activeWorkspace?.id,
            offset: offset,
            orderedIDs: workspaces.map(\.id)
        ), let target = workspaces.first(where: { $0.id == targetID }) else { return }
        select(target)
    }

    func selectAdjacentPane(by offset: Int) {
        guard let targetID = NavigationOrder.adjacentID(
            currentID: activePane?.id,
            offset: offset,
            orderedIDs: visiblePanes.map(\.id)
        ), let target = visiblePanes.first(where: { $0.id == targetID }) else { return }
        select(target)
    }

    func ask(_ target: TmuxPane) {
        perform {
            guard let controller, let source = activePane else { return }
            guard let edited = editRelay(
                title: "Ask \(target.displayName)",
                message: "Only this text will be submitted to \(target.displayName). Select terminal text first, type here, or explicitly insert the visible pane.",
                text: RelayDraft.initialText(selection: terminalHandle.selectedText),
                action: "Ask",
                insertVisible: { try controller.capturePane(source.id) }
            ) else { return }
            try controller.ask(from: source.id, to: target.id, text: edited)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func reviewChanges(with target: TmuxPane) {
        perform {
            guard let source = activePane, let reviewDraftBuilder else { return }
            let draft = try reviewDraftBuilder.changes(in: source.cwd)
            try sendReview(draft, from: source, to: target)
        }
    }

    func reviewFile(with target: TmuxPane) {
        guard let source = activePane else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a plan or text file for \(target.displayName) to review"
        panel.prompt = "Review File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: source.cwd)
        guard panel.runModal() == .OK, let file = panel.url else { return }

        perform {
            guard let reviewDraftBuilder else { return }
            let draft = try reviewDraftBuilder.file(at: file)
            try sendReview(draft, from: source, to: target)
        }
    }

    func run(_ recipe: HandoffRecipe) {
        perform {
            guard let controller,
                  let workspace = activeWorkspace,
                  let lead = workspaceLead else {
                throw RelayUIError.message("Mark a running agent pane as this workspace's lead first.")
            }
            guard recipe.kind.isAllowed(by: workspace.automationPolicy) else {
                throw RelayUIError.message(
                    "\(workspace.automationPolicy.label) does not allow this recipe. Change the workspace automation policy first."
                )
            }
            let targets = try chooseRecipeTargets(for: recipe, candidates: recipeTargets)
            guard !targets.isEmpty else { return }
            let rendered = try recipe.render(targets: targets.map(\.id))
            guard let edited = editRelay(
                title: recipe.name,
                message: "This exact instruction will be submitted to workspace lead \(lead.displayName). Every cross-vendor prompt it sends remains attributed and visible in Activity.",
                text: rendered,
                action: "Run with Lead",
                insertVisible: { try controller.capturePane(lead.id) }
            ) else { return }
            try controller.paste("The person using Parley requested this supervised workflow:\n\n\(edited)", into: lead.id, submit: true)
            let run = ActiveRecipeRun(
                id: UUID().uuidString.lowercased(),
                recipeName: recipe.name,
                leadPaneID: lead.id,
                leadName: lead.displayName,
                submittedAt: Date(),
                instructions: edited
            )
            activeRecipeRun = run
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .recipeSubmitted,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                paneID: lead.id,
                paneName: lead.displayName,
                paneKind: lead.kind,
                detail: edited
            ))
            try controller.selectPane(lead.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func edit(_ recipe: HandoffRecipe) {
        guard let edited = editRelay(
            title: "Edit \(recipe.name)",
            message: "Keep {{targets}} where the explicit pane names should be inserted. The text remains local and can still be changed before each run.",
            text: recipe.instructions,
            action: "Save Recipe",
            insertVisible: { "" }
        ) else { return }
        perform {
            let updated = HandoffRecipe(
                id: recipe.id,
                name: recipe.name,
                kind: recipe.kind,
                instructions: edited
            )
            try recipeStore.save(updated)
            recipes = try recipeStore.recipes()
            terminalHandle.focus()
        }
    }

    func restoreDefaultRecipes() {
        let alert = NSAlert()
        alert.messageText = "Restore default recipes?"
        alert.informativeText = "This replaces edits to all four local handoff recipes. Running panes and collaboration history are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try recipeStore.restoreDefaults()
            recipes = try recipeStore.recipes()
            terminalHandle.focus()
        }
    }

    func dismissActiveRecipeRun() {
        activeRecipeRun = nil
        terminalHandle.focus()
    }

    func interruptActiveRecipeRun() {
        guard let run = activeRecipeRun,
              let workspace = workspaces.first(where: { $0.id == panes.first(where: { $0.id == run.leadPaneID })?.windowID }) else {
            activeRecipeRun = nil
            return
        }
        let alert = NSAlert()
        alert.messageText = "Interrupt \(run.leadName)?"
        alert.informativeText = "This sends Control-C to the lead's current terminal turn. It does not cancel cross-vendor work the lead already dispatched; cancel those tracked items separately."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Interrupt Lead")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let controller else { return }
            try controller.interruptPane(run.leadPaneID)
            activeRecipeRun = nil
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .recipeInterrupted,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                paneID: run.leadPaneID,
                paneName: run.leadName,
                paneKind: panes.first(where: { $0.id == run.leadPaneID })?.kind,
                detail: "Interrupted \(run.recipeName) after explicit human confirmation."
            ))
            terminalHandle.focus()
        }
    }

    private func chooseRecipeTargets(
        for recipe: HandoffRecipe,
        candidates: [TmuxPane]
    ) throws -> [TmuxPane] {
        let required = recipe.kind == .askMany ? 2 : 1
        guard candidates.count >= required else {
            throw RelayUIError.message(
                required == 2
                    ? "Open at least two ready agent panes from vendors different to the lead."
                    : "Open a ready agent pane from a vendor different to the lead."
            )
        }

        let alert = NSAlert()
        alert.messageText = "Targets for \(recipe.name)"
        alert.informativeText = recipe.kind == .askMany
            ? "Choose at least two explicit panes. They will answer independently."
            : "Choose the exact cross-vendor pane the lead should use."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        if recipe.kind == .askMany {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            let buttons = candidates.map { pane in
                let button = NSButton(
                    checkboxWithTitle: "\(pane.displayName) · \(pane.kind.label) (\(pane.id))",
                    target: nil,
                    action: nil
                )
                button.state = .on
                stack.addArrangedSubview(button)
                return button
            }
            stack.frame = NSRect(x: 0, y: 0, width: 420, height: CGFloat(max(1, buttons.count)) * 26)
            alert.accessoryView = stack
            guard alert.runModal() == .alertFirstButtonReturn else { return [] }
            let selected = zip(candidates, buttons).compactMap { pane, button in
                button.state == .on ? pane : nil
            }
            guard selected.count >= 2 else {
                throw RelayUIError.message("Compare needs at least two selected panes.")
            }
            return selected
        }

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        picker.addItems(withTitles: candidates.map {
            "\($0.displayName) · \($0.kind.label) (\($0.id))"
        })
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        return [candidates[max(0, picker.indexOfSelectedItem)]]
    }

    func returnAnswer() {
        perform {
            guard let controller, let source = activePane, let requesterID = source.returnToPaneID else { return }
            let requester = panes.first(where: { $0.id == requesterID })
            guard let edited = editRelay(
                title: "Return answer",
                message: "Only this text will be submitted to \(requester?.displayName ?? "the requester"). Select the answer first, type here, or explicitly insert the visible pane.",
                text: RelayDraft.initialText(selection: terminalHandle.selectedText),
                action: "Return",
                insertVisible: { try controller.capturePane(source.id) }
            ) else { return }
            try controller.returnAnswer(from: source.id, text: edited)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func returnConsultation(_ consultation: RelayConsultation) {
        perform {
            guard let controller, let relayClient else { return }
            guard let edited = editRelay(
                title: "Answer \(consultation.sourceName)",
                message: "Use this only if \(consultation.targetName) printed its answer without running `parley answer`. This completes the waiting command directly; it does not paste or press Enter in \(consultation.sourceName).",
                text: RelayDraft.initialText(selection: terminalHandle.selectedText),
                action: "Return",
                insertVisible: { try controller.capturePane(consultation.targetPaneID) }
            ) else { return }
            let response = try relayClient.answerFromUI(consultationID: consultation.id, text: edited)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            try controller.selectPane(consultation.sourcePaneID)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func cancel(_ consultation: RelayConsultation) {
        cancelTracked(
            id: consultation.id,
            kind: "Ask",
            sourceName: consultation.sourceName,
            targetPaneID: consultation.targetPaneID,
            targetName: consultation.targetName
        )
    }

    func cancel(_ handoff: RelayHandoff) {
        cancelTracked(
            id: handoff.id,
            kind: handoff.kind == .delegate ? "delegation" : "Ask",
            sourceName: handoff.sourceName,
            targetPaneID: handoff.targetPaneID,
            targetName: handoff.targetName
        )
    }

    private func cancelTracked(
        id: String,
        kind: String,
        sourceName: String,
        targetPaneID: String,
        targetName: String
    ) {
        let alert = NSAlert()
        alert.messageText = "Cancel this \(kind)?"
        alert.informativeText = "Cancel Tracking releases \(sourceName)'s wait and leaves \(targetName)'s CLI undisturbed. Cancel and Interrupt also sends Control-C to the target's current terminal turn."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Tracking")
        alert.addButton(withTitle: "Cancel and Interrupt Target")
        alert.addButton(withTitle: "Keep Waiting")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        perform {
            guard let relayClient else { return }
            let response = try relayClient.cancelHandoff(id)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            if choice == .alertSecondButtonReturn {
                guard let controller else { return }
                try controller.interruptPane(targetPaneID)
            }
            try refresh()
            terminalHandle.focus()
        }
    }

    func retry(_ handoff: RelayHandoff) {
        guard handoff.canRetrySafely else { return }
        let alert = NSAlert()
        alert.messageText = "Retry delivery to \(handoff.targetName)?"
        alert.informativeText = "Parley recorded that no terminal input began. This sends the original attributed text once, reuses the same handoff record, and cannot be edited as a different request."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry Delivery")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let relayClient else { return }
            let response = try relayClient.retryHandoff(handoff.id)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            try refresh()
            terminalHandle.focus()
        }
    }

    func focus(_ handoff: RelayHandoff, target: Bool) {
        perform {
            guard let controller else { return }
            let paneID = target ? handoff.targetPaneID : handoff.sourcePaneID
            guard let pane = panes.first(where: { $0.id == paneID }) else {
                throw RelayUIError.message("That pane is no longer open.")
            }
            if activeWorkspace?.id != pane.windowID {
                try controller.selectWorkspace(pane.windowID)
            }
            try controller.selectPane(pane.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func canFocus(_ paneID: String) -> Bool {
        panes.contains(where: { $0.id == paneID })
    }

    func consultation(for handoff: RelayHandoff) -> RelayConsultation? {
        consultations.first(where: { $0.id == handoff.id })
    }

    func rename(_ pane: TmuxPane) {
        let alert = NSAlert()
        alert.messageText = "Rename pane"
        alert.informativeText = "This is Parley metadata; it does not change the agent or its session."
        let field = NSTextField(string: pane.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try controller?.renamePane(pane.id, name: field.stringValue)
            try refresh()
        }
    }

    func restart(_ pane: TmuxPane) {
        let alert = NSAlert()
        alert.messageText = "Restart \(pane.displayName)?"
        alert.informativeText = "The current process in this pane will be stopped and relaunched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let controller else { return }
            try controller.restartPane(pane.id)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .paneRestarted,
                workspaceID: pane.windowID,
                workspaceName: pane.workspaceName ?? pane.windowID,
                paneID: pane.id,
                paneName: pane.displayName,
                paneKind: pane.kind,
                detail: "\(pane.kind.label) pane restarted."
            ))
            try refresh()
        }
    }

    func start(_ pane: TmuxPane) {
        perform {
            try controller?.startPane(pane.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func close(_ pane: TmuxPane) {
        let alert = NSAlert()
        alert.messageText = "Close \(pane.displayName)?"
        alert.informativeText = "This ends the process in tmux. It cannot be recovered from Parley."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try controller?.closePane(pane.id)
            try refresh()
        }
    }

    func zoom() {
        perform {
            try controller?.zoomActivePane()
            terminalHandle.focus()
        }
    }

    func balance() {
        perform {
            try controller?.balancePanes()
            terminalHandle.focus()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the default folder for \(activeWorkspace?.name ?? "this workspace")"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
        if panel.runModal() == .OK, let url = panel.url {
            setWorkspaceFolder(url.standardizedFileURL.path)
        }
    }

    func setWorkspaceFolder(_ folder: String) {
        perform {
            guard let controller, let workspace = activeWorkspace else { return }
            let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
            try controller.setWorkspaceFolder(workspace.id, folder: standardized)
            workspaceContinuity.updateWorkspace(
                from: workspace,
                to: TmuxWorkspace(
                    id: workspace.id,
                    name: workspace.name,
                    defaultFolder: standardized,
                    isActive: workspace.isActive
                )
            )
            saveWorkspaceContinuity()
            rememberFolder(folder)
            try refresh()
        }
    }

    func isFavouriteFolder(_ folder: String) -> Bool {
        let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
        return favouriteFolders.contains(standardized)
    }

    func toggleFavouriteFolder(_ folder: String) {
        _ = workspaceContinuity.toggleFavourite(folder: folder)
        favouriteFolders = workspaceContinuity.favouriteFolders
        saveWorkspaceContinuity()
    }

    func canMove(_ workspace: TmuxWorkspace, by offset: Int) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return false }
        return workspaces.indices.contains(index + offset)
    }

    func move(_ workspace: TmuxWorkspace, by offset: Int) {
        let moved = workspaceContinuity.moveWorkspace(id: workspace.id, by: offset, in: workspaces)
        guard moved != workspaces else { return }
        workspaces = moved
        saveWorkspaceContinuity()
    }

    func createWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Open a folder as a workspace"
        panel.prompt = "Open Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        createWorkspace(folder: url.standardizedFileURL.path)
    }

    func createWorkspace(folder: String) {
        perform {
            guard let controller else { return }
            let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
            if let existing = workspaces.first(where: { $0.defaultFolder == standardized }) {
                try controller.selectWorkspace(existing.id)
            } else {
                let created = try controller.createWorkspace(folder: standardized)
                try recordSuccessfulActivity(RelayActivityEventRequest(
                    kind: .workspaceCreated,
                    workspaceID: created.id,
                    workspaceName: created.name,
                    detail: "Opened \(created.defaultFolder)"
                ))
            }
            rememberFolder(standardized)
            try refresh()
            terminalHandle.focus()
        }
    }

    func rename(_ workspace: TmuxWorkspace) {
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        alert.informativeText = "The folder and running panes are unchanged."
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let renamed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            guard let controller else { return }
            try controller.renameWorkspace(workspace.id, name: renamed)
            workspaceContinuity.updateWorkspace(
                from: workspace,
                to: TmuxWorkspace(
                    id: workspace.id,
                    name: renamed,
                    defaultFolder: workspace.defaultFolder,
                    isActive: workspace.isActive,
                    automationPolicy: workspace.automationPolicy
                )
            )
            saveWorkspaceContinuity()
            if notificationWorkspaceNames.remove(workspace.name) != nil {
                notificationWorkspaceNames.insert(renamed)
                saveNotificationWorkspaces()
            }
            try refresh()
        }
    }

    func setAutomationPolicy(_ policy: WorkspaceAutomationPolicy, for workspace: TmuxWorkspace) {
        guard policy != workspace.automationPolicy else { return }
        perform {
            guard let controller else { return }
            try controller.setWorkspaceAutomationPolicy(workspace.id, policy: policy)
            try refresh()
            terminalHandle.focus()
        }
    }

    func setWorkspaceLead(_ pane: TmuxPane) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceLead(pane.id, workspaceID: pane.windowID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func clearWorkspaceLead(_ workspace: TmuxWorkspace) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceLead(nil, workspaceID: workspace.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func close(_ workspace: TmuxWorkspace) {
        let paneCount = panes.filter { $0.windowID == workspace.id }.count
        let alert = NSAlert()
        alert.messageText = "Close \(workspace.name)?"
        alert.informativeText = "This ends \(paneCount) running pane\(paneCount == 1 ? "" : "s") in this workspace. It cannot be recovered from Parley."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Workspace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let controller else { return }
            try controller.closeWorkspace(workspace.id)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceClosed,
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                detail: "Closed \(paneCount) pane\(paneCount == 1 ? "" : "s")."
            ))
            try refresh()
            terminalHandle.focus()
        }
    }

    func saveActiveWorkspaceLayout() {
        guard let workspace = activeWorkspace else { return }
        saveLayout(of: workspace)
    }

    func saveLayout(of workspace: TmuxWorkspace) {
        let alert = NSAlert()
        alert.messageText = "Save workspace layout"
        alert.informativeText = "Saves pane kinds, names, folders, split directions and ratios. Running sessions and tmux ids are never stored."
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if savedLayouts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let overwrite = NSAlert()
            overwrite.messageText = "Replace saved layout \(name)?"
            overwrite.informativeText = "The previous saved definition will be replaced. Running panes are unchanged."
            overwrite.alertStyle = .warning
            overwrite.addButton(withTitle: "Replace")
            overwrite.addButton(withTitle: "Cancel")
            guard overwrite.runModal() == .alertFirstButtonReturn else { return }
        }

        perform {
            guard let controller else { return }
            let captured = try controller.captureWorkspaceLayout(workspaceID: workspace.id)
            try layoutStore.save(SavedWorkspaceLayout(
                name: name,
                defaultFolder: captured.defaultFolder,
                root: captured.root,
                automationPolicy: captured.automationPolicy
            ))
            savedLayouts = try layoutStore.layouts()
            terminalHandle.focus()
        }
    }

    func open(_ layout: SavedWorkspaceLayout) {
        let workspace = activeWorkspace
        let paneCount = workspace.map { selected in panes.count { $0.windowID == selected.id } } ?? 0
        if let workspace, paneCount > 0 {
            let pending = handoffs.count { handoff in
                let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
                return activeStates.contains(handoff.state)
                    && (handoff.sourceWorkspaceID == workspace.id || handoff.targetWorkspaceID == workspace.id)
            }
            let alert = NSAlert()
            alert.messageText = "Open \(layout.name) over \(workspace.name)?"
            alert.informativeText = "This ends \(paneCount) running pane\(paneCount == 1 ? "" : "s") in the current workspace\(pending == 0 ? "." : " and interrupts \(pending) active handoff\(pending == 1 ? "" : "s").") Shell panes in the saved layout start automatically; agent panes remain stopped until you choose Start."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace Workspace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        perform {
            guard let controller else { return }
            let restored = try controller.restoreWorkspaceLayout(layout, replacing: workspace?.id)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceRestored,
                workspaceID: restored.id,
                workspaceName: restored.name,
                detail: "Opened saved layout \(layout.name); shells started and agent panes left stopped."
            ))
            rememberFolder(layout.defaultFolder)
            try refresh()
            terminalHandle.focus()
        }
    }

    func delete(_ layout: SavedWorkspaceLayout) {
        let alert = NSAlert()
        alert.messageText = "Delete saved layout \(layout.name)?"
        alert.informativeText = "Running workspaces and panes are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Layout")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try layoutStore.delete(named: layout.name)
            savedLayouts = try layoutStore.layouts()
            terminalHandle.focus()
        }
    }

    private func rememberFolder(_ folder: String) {
        let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
        recentFolders.removeAll { $0 == standardized }
        recentFolders.insert(standardized, at: 0)
        if recentFolders.count > 8 { recentFolders.removeLast(recentFolders.count - 8) }
        UserDefaults.standard.set(recentFolders, forKey: Self.recentFoldersKey)
    }

    private func saveNotificationWorkspaces() {
        UserDefaults.standard.set(notificationWorkspaceNames.sorted(), forKey: Self.notificationWorkspacesKey)
    }

    private func saveDismissedHandoffs() {
        UserDefaults.standard.set(dismissedHandoffIDs.sorted(), forKey: Self.dismissedHandoffsKey)
    }

    private func saveWorkspaceContinuity() {
        guard let data = try? JSONEncoder().encode(workspaceContinuity) else { return }
        UserDefaults.standard.set(data, forKey: Self.workspaceContinuityKey)
    }

    private func processNotifications(from handoffs: [RelayHandoff]) {
        let events = StatusNotificationProjection.events(handoffs: handoffs)
        for event in events where observedNotificationEventIDs.insert(event.id).inserted {
            guard event.occurredAt >= notificationEpoch,
                  notificationWorkspaceNames.contains(event.workspaceName),
                  !NSApp.isActive else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.userInfo = ["handoffID": event.handoffID]
            let request = UNNotificationRequest(
                identifier: "parley.status.\(event.id)",
                content: content,
                trigger: nil
            )
            Task {
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }

    private func recordSuccessfulActivity(_ request: RelayActivityEventRequest) throws {
        do {
            guard let relayClient else {
                throw RelayUIError.message("The Parley coordination core is unavailable.")
            }
            let event = try relayClient.recordActivity(request)
            statusActivityEvents.removeAll { $0.id == event.id }
            statusActivityEvents.append(event)
            statusActivityEvents.sort {
                if $0.occurredAt == $1.occurredAt { return $0.id < $1.id }
                return $0.occurredAt > $1.occurredAt
            }
            if statusActivityEvents.count > 500 {
                statusActivityEvents.removeLast(statusActivityEvents.count - 500)
            }
        } catch {
            throw RelayUIError.message(
                "The operation succeeded, but Parley could not save its activity record: \(error.localizedDescription)"
            )
        }
    }

    private func showNotificationAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Parley notifications"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func editRelay(
        title: String,
        message: String,
        text: String,
        action: String,
        insertVisible: @escaping () throws -> String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")

        let accessory = RelayEditorAccessory(text: text, insertVisible: insertVisible)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let cleaned = RelayText.clean(accessory.text)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func sendReview(_ draft: ReviewDraft, from source: TmuxPane, to target: TmuxPane) throws {
        guard let controller else { return }
        guard let edited = editRelay(
            title: "\(draft.title) with \(target.displayName)",
            message: "Review exactly what will be submitted. This uses Parley's normal attributed Ask path; nothing else from the terminal or repository is copied automatically.",
            text: draft.text,
            action: "Ask for Review",
            insertVisible: { try controller.capturePane(source.id) }
        ) else { return }
        try controller.ask(from: source.id, to: target.id, text: edited)
        try refresh()
        terminalHandle.terminal?.selectNone()
        terminalHandle.focus()
    }

    private static func paletteSubject(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? "No message text"
        if line.count <= 100 { return line }
        return String(line.prefix(99)) + "…"
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private static func argument(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func hasArgument(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(name)
    }
}

private enum RelayUIError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

@MainActor
private final class RelayEditorAccessory: NSView {
    private let editor: NSTextView
    private let insertVisible: () throws -> String

    var text: String { editor.string }

    init(text: String, insertVisible: @escaping () throws -> String) {
        self.insertVisible = insertVisible
        let frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 36, width: 560, height: 264))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.string = text
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        scroll.documentView = editor
        self.editor = editor

        super.init(frame: frame)
        addSubview(scroll)

        let insert = NSButton(title: "Insert Visible Pane", target: self, action: #selector(insertVisiblePane))
        insert.bezelStyle = .rounded
        insert.controlSize = .small
        insert.frame = NSRect(x: 0, y: 0, width: 145, height: 28)
        insert.toolTip = "Insert only what tmux is currently displaying, not its scrollback history."
        addSubview(insert)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func insertVisiblePane() {
        do {
            let visible = RelayText.clean(try insertVisible())
            guard !visible.isEmpty else { return }
            editor.insertText(visible, replacementRange: editor.selectedRange())
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

struct AttachConfiguration: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let cwd: String
}
