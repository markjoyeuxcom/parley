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

struct AskManyComparisonTarget: Identifiable, Equatable {
    let paneID: String
    let name: String
    let kind: PaneKind
    let workspaceName: String?

    var id: String { paneID }
}

struct AskManyComparisonRun: Identifiable, Equatable {
    let id: String
    let sourcePaneID: String
    let sourceName: String
    let sourceWorkspaceID: String
    let question: String
    let targets: [AskManyComparisonTarget]
    let startedAt: Date
    var response: RelayAskManyUIResponse?
    var error: String?

    var isRunning: Bool { response == nil && error == nil }
}

struct ActiveContextPack: Identifiable, Equatable {
    let id: String
    let sourcePaneID: String
    let sourcePaneKind: PaneKind
    let sourcePaneName: String
    let sourceFolder: String
    var pack: ContextPack
    let reviewID: String?
    var reviewState: AgentContextReviewState?
    var requestedTargetPaneID: String?
    var reviewUpdatedAt: Date?
    var renderedByteCount = 0
    var isValid = false
}

struct ActiveWorkspaceBriefDraft: Identifiable, Equatable {
    let workspaceID: String
    let workspaceName: String
    let existingBriefID: String?
    let goal: String
    let constraints: String
    let decisions: String

    var id: String { workspaceID }
}

enum PanePermissionAction: Equatable {
    case create(SplitDirection)
    case restart(String)
    case start(String)
}

struct PanePermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: PaneKind
    let folder: String
    let action: PanePermissionAction
    let existingSelection: PermissionProfileSelection?

    var actionLabel: String {
        switch action {
        case .create: "Start Pane"
        case .restart: "Restart Pane"
        case .start: "Start Pane"
        }
    }
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
    @Published private(set) var worktreeScan: GitWorktreeScan = .empty
    @Published private(set) var discoveredWorktreeRepository: GitWorktreeRepository?
    @Published private(set) var worktreeDiscoveryLoading = false
    @Published private(set) var worktreeDiscoveryError: String?
    @Published private(set) var savedLayouts: [SavedWorkspaceLayout] = []
    @Published private(set) var teamTemplates: [TeamTemplate] = []
    @Published private(set) var recipes: [HandoffRecipe] = []
    @Published private(set) var supervisedWorkflowRuns: [SupervisedWorkflowRun] = []
    @Published private(set) var handoffChains: [HandoffChain] = []
    @Published private(set) var permissionProfiles: [PermissionProfileDefinition] = []
    @Published private(set) var activeRecipeRun: ActiveRecipeRun?
    @Published private(set) var askManyComparisonRun: AskManyComparisonRun?
    @Published private(set) var contextPackDraft: ActiveContextPack?
    @Published private(set) var workspaceBriefs: [WorkspaceBrief] = []
    @Published private(set) var workspaceBriefDraft: ActiveWorkspaceBriefDraft?
    @Published private(set) var pinnedContextSnippets: [PinnedContextSnippet] = []
    @Published private(set) var contextReviews: [AgentContextReview] = []
    @Published private(set) var contextCommandCapturing = false
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
    @Published var panePermissionRequest: PanePermissionRequest?
    @Published var askManyComparisonPresented = false
    @Published var contextPackPresented = false
    @Published var workspaceBriefPresented = false
    @Published var pinnedContextSnippetsPresented = false
    @Published var supervisedWorkflowPresented = false
    @Published var worktreeBrowserPresented = false
    @Published private(set) var selectedSupervisedWorkflowID: String?
    @Published private(set) var requestedHelpTopicID: String?
    @Published private(set) var requestedStatusHandoffID: String?
    @Published var startupError: String?
    @Published private(set) var startupRequiresQuit = false

    let runtime: ParleyRuntime
    let terminalHandle = TerminalHandle()
    private let fallbackFolder: String
    private let applicationDirectory: URL
    private let preferences: UserDefaults
    private let runtimeLease: RuntimeUILease?
    private let layoutStore: SavedWorkspaceLayoutStore
    private let teamTemplateStore: TeamTemplateStore
    private let recipeStore: HandoffRecipeStore
    private let supervisedWorkflowStore: SupervisedWorkflowStore
    private let handoffChainStore: HandoffChainStore
    private let workspaceBriefStore: WorkspaceBriefStore
    private let pinnedContextSnippetStore: PinnedContextSnippetStore
    private let permissionProfileStore: PermissionProfileStore
    private var workspaceContinuity = WorkspaceContinuityState()
    private let projectContextResolver = GitProjectContextResolver()
    private let worktreeResolver = GitWorktreeResolver()
    private var projectContextRefreshTask: Task<Void, Never>?
    private var projectContextFolders: Set<String> = []
    private var lastProjectContextRefresh = Date.distantPast
    private var worktreeRefreshTask: Task<Void, Never>?
    private var worktreePaneFolders: [String: String] = [:]
    private var lastWorktreeRefresh = Date.distantPast
    private var worktreeDiscoveryTask: Task<Void, Never>?
    private var worktreeDiscoveryID: UUID?
    private var relayClient: RelayCoreClient?
    private var reviewDraftBuilder: ReviewDraftBuilder?
    private var contextPackBuilder: ContextPackBuilder?
    private let notificationEpoch = Date()
    private var observedNotificationEventIDs: Set<String> = []
    private var runtimeReadinessTask: Task<Void, Never>?
    private var coreUpgradeTask: Task<Void, Never>?
    private var coreUpgradeSettled = false
    private var lastCoreUpgradeAttempt = Date.distantPast
    private var lastExternalAttentionSnapshot: ExternalAttentionSnapshot?
    private var lastExternalAttentionPublishedAt = Date.distantPast
    private let coreLoginItemController = CoreLoginItemController()
    private static let recentFoldersKey = "parley.recentWorkspaceFolders"
    private static let workspaceContinuityKey = "parley.workspaceContinuity"
    private static let notificationWorkspacesKey = "parley.notificationWorkspaces"
    private static let dismissedHandoffsKey = "parley.dismissedStatusHandoffs"
    private static let firstRunCompletedKey = "parley.firstRunReadinessCompleted"
    private static let permissionProfileKeyPrefix = "parley.permissionProfile"
    private static let projectContextRefreshInterval: TimeInterval = 5
    private static let worktreeRefreshInterval: TimeInterval = 15
    private static let externalAttentionHeartbeatInterval: TimeInterval = 10

    init() {
        let requestedFolder = Self.argument(named: "--cwd")
        let initialFolder = requestedFolder ?? FileManager.default.currentDirectoryPath
        fallbackFolder = URL(fileURLWithPath: initialFolder).standardizedFileURL.path
        let resolvedRuntime: ParleyRuntime
        var runtimeResolutionError: String?
        do {
            resolvedRuntime = try ParleyRuntime.resolve(
                arguments: ProcessInfo.processInfo.arguments,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                isBundledApplication: Self.isBundledApplication
            )
        } catch {
            // Invalid development arguments must never fall through to the
            // Production namespace. The startup error below keeps the fallback
            // runtime inert.
            resolvedRuntime = ParleyRuntime.make(
                mode: .development,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            runtimeResolutionError = error.localizedDescription
        }
        runtime = resolvedRuntime
        applicationDirectory = runtime.applicationDirectory
        preferences = UserDefaults(suiteName: runtime.preferenceSuiteName) ?? .standard
        layoutStore = SavedWorkspaceLayoutStore(
            file: applicationDirectory.appendingPathComponent("workspace-layouts.json")
        )
        teamTemplateStore = TeamTemplateStore(
            file: applicationDirectory.appendingPathComponent("team-templates.json")
        )
        recipeStore = HandoffRecipeStore(
            file: applicationDirectory.appendingPathComponent("handoff-recipes.json")
        )
        supervisedWorkflowStore = SupervisedWorkflowStore(
            file: applicationDirectory.appendingPathComponent("supervised-workflows.json")
        )
        handoffChainStore = HandoffChainStore(
            file: applicationDirectory.appendingPathComponent("handoff-chains.json")
        )
        workspaceBriefStore = WorkspaceBriefStore(
            file: applicationDirectory.appendingPathComponent("workspace-briefs.json")
        )
        pinnedContextSnippetStore = PinnedContextSnippetStore(
            file: applicationDirectory.appendingPathComponent("pinned-context-snippets.json")
        )
        permissionProfileStore = PermissionProfileStore(
            file: applicationDirectory.appendingPathComponent("permission-profiles.json")
        )
        do {
            runtimeLease = runtimeResolutionError == nil
                ? try RuntimeUILease.acquire(runtime: runtime)
                : nil
        } catch {
            runtimeLease = nil
            startupError = error.localizedDescription
            startupRequiresQuit = true
        }
        if let runtimeResolutionError {
            startupError = runtimeResolutionError
            startupRequiresQuit = true
        }
        recipes = (try? recipeStore.recipes()) ?? HandoffRecipe.defaults
        teamTemplates = (try? teamTemplateStore.templates()) ?? []
        supervisedWorkflowRuns = (try? supervisedWorkflowStore.runs()) ?? []
        handoffChains = (try? handoffChainStore.chains()) ?? []
        workspaceBriefs = (try? workspaceBriefStore.briefs()) ?? []
        pinnedContextSnippets = (try? pinnedContextSnippetStore.snippets()) ?? []
        permissionProfiles = (try? permissionProfileStore.profiles())
            ?? PermissionProfileDefinition.builtIns
        if runtime.mode == .production {
            UserDefaultsDomainMigration.copyMissing(
                keys: [
                    Self.recentFoldersKey,
                    Self.workspaceContinuityKey,
                    Self.notificationWorkspacesKey,
                    Self.dismissedHandoffsKey,
                ],
                from: "parley-native",
                to: preferences
            )
        }
        recentFolders = preferences.stringArray(forKey: Self.recentFoldersKey) ?? []
        if let data = preferences.data(forKey: Self.workspaceContinuityKey),
           let decoded = try? JSONDecoder().decode(WorkspaceContinuityState.self, from: data) {
            workspaceContinuity = decoded
        }
        favouriteFolders = workspaceContinuity.favouriteFolders
        notificationWorkspaceNames = Set(
            preferences.stringArray(forKey: Self.notificationWorkspacesKey) ?? []
        )
        dismissedHandoffIDs = Set(
            preferences.stringArray(forKey: Self.dismissedHandoffsKey) ?? []
        )
        setupPresented = !preferences.bool(forKey: Self.firstRunCompletedKey)

        guard runtimeLease != nil, startupError == nil else {
            coreAvailable = false
            tmuxAvailable = false
            tmuxError = startupError
            return
        }

        do {
            let controller = try TmuxController(
                applicationDirectory: runtime.applicationDirectory,
                sessionName: runtime.tmuxSessionName,
                prepareRuntimeFiles: runtime.preparesRuntimeFiles
            )
            try controller.bootstrap(
                cwd: defaultFolder,
                createIfMissing: !runtime.requiresExistingTmuxSession
            )
            var livePanes = try controller.listPanes()
            var liveWorkspaces = try controller.listWorkspaces()
            let credentials = try RelayCredentials(
                file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
            )
            if runtime.preparesRuntimeFiles {
                try credentials.retain(paneIDs: Set(livePanes.map(\.id)))
            }
            let agentTransportDirectory = RelayFileTransport.runtimeDirectory(
                applicationDirectory: controller.applicationDirectory
            )
            let shimDirectory: URL
            if runtime.preparesRuntimeFiles {
                shimDirectory = try RelayShim.install(
                    in: controller.applicationDirectory,
                    transportDirectory: agentTransportDirectory,
                    runtimeMarker: runtime.visibleMarker
                )
            } else {
                shimDirectory = controller.applicationDirectory.appendingPathComponent("bin", isDirectory: true)
                guard FileManager.default.isExecutableFile(
                    atPath: shimDirectory.appendingPathComponent("parley").path
                ) else {
                    throw RelayUIError.message(
                        "The Production relay command is not prepared. Start the installed Parley app before attaching Development."
                    )
                }
            }
            // Persistent tmux panes retain the PATH they were born with. Put a
            // managed copy in the user's existing stable command directory so
            // reattaching the UI upgrades relay access without killing those
            // agent conversations. The stable command is a runtime-neutral
            // router because vendor CLIs may rebuild PATH after launch. A
            // foreign `parley` command is never replaced.
            if runtime.installsStableCommand {
                let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
                let developmentRuntime = ParleyRuntime.make(mode: .development, homeDirectory: homeDirectory)
                _ = try RelayShim.installStableRouter(
                    in: homeDirectory.appendingPathComponent(".local/bin"),
                    productionCommand: shimDirectory.appendingPathComponent("parley"),
                    developmentCommand: developmentRuntime.applicationDirectory
                        .appendingPathComponent("bin/parley")
                )
            }
            let infoFile = controller.applicationDirectory.appendingPathComponent("relay-url")
            controller.configureRelay(RelayRuntime(
                infoFile: infoFile,
                shimDirectory: shimDirectory,
                transportDirectory: agentTransportDirectory,
                credentials: credentials,
                runtimeMarker: runtime.visibleMarker
            ))
            let relayClient: RelayCoreClient?
            do {
                if runtime.launchesCore {
                    relayClient = try RelayCoreLauncher.ensureRunning(
                        applicationDirectory: controller.applicationDirectory,
                        cwd: defaultFolder,
                        environment: controller.environment,
                        tmuxSessionName: runtime.tmuxSessionName,
                        runtimeMarker: runtime.visibleMarker
                    )
                } else {
                    relayClient = try RelayCoreLauncher.attachExisting(
                        applicationDirectory: controller.applicationDirectory
                    )
                }
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
            if runtime.preparesRuntimeFiles, Self.hasArgument("--restart-stale-protocol") {
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
            contextPackBuilder = ContextPackBuilder(environment: controller.environment)
            panes = livePanes
            workspaces = liveWorkspaces
            savedLayouts = try layoutStore.layouts()
            rememberFolder(defaultFolder)
            scheduleProjectContextRefresh(force: true)
            scheduleWorktreeRefresh(force: true)
            publishExternalAttentionSnapshot(force: true)
        } catch {
            coreAvailable = false
            tmuxAvailable = false
            tmuxError = error.localizedDescription
            startupError = error.localizedDescription
        }
        refreshCoreLoginItemState()
        refreshRuntimeReadiness()
        if runtime.upgradesCore { scheduleCoreUpgradeCheck(force: true) }
    }

    var activeWorkspace: TmuxWorkspace? { workspaces.first(where: \.isActive) }

    func dismissStartupError() {
        startupError = nil
        if startupRequiresQuit { NSApp.terminate(nil) }
    }

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
        runtime.managesLoginItem
            && coreLoginItemState != .unavailable
            && !coreLoginItemChanging
            && !preparingToUninstall
    }

    var canPrepareToUninstall: Bool {
        runtime.managesLoginItem
            && coreAvailable
            && relayClient != nil
            && coreUpgradeTask == nil
            && !preparingToUninstall
    }

    func refreshCoreLoginItemState() {
        guard runtime.managesLoginItem else {
            coreLoginItemState = .unavailable
            return
        }
        let refreshed = coreLoginItemController.state
        if refreshed != coreLoginItemState { coreLoginItemState = refreshed }
    }

    func setCoreLoginItemRequested(_ requested: Bool) {
        guard runtime.managesLoginItem, !coreLoginItemChanging, !preparingToUninstall else { return }
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
        guard runtime.managesLoginItem, canPrepareToUninstall, let relayClient else { return }

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
        preferences.set(true, forKey: Self.firstRunCompletedKey)
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
            build: info["CFBundleVersion"] as? String ?? "development",
            runtime: runtime.mode.rawValue
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

    func workspaceSafetySummary(for workspace: TmuxWorkspace) -> WorkspaceSafetySummary {
        let workspacePanes = panes.filter { $0.windowID == workspace.id }
        let contextsByPaneID = Dictionary(uniqueKeysWithValues: workspacePanes.compactMap { pane in
            projectContext(for: pane).map { (pane.id, $0) }
        })
        return WorkspaceSafetyProjection.summary(
            workspace: workspace,
            panes: panes,
            handoffs: handoffs,
            projectContextsByPaneID: contextsByPaneID,
            paneWorktreePaths: worktreeScan.paneWorktreePaths,
            writerCollisions: worktreeWriterCollisions,
            coreAvailable: coreAvailable
        )
    }

    var worktreeWriterCollisions: [WorktreeWriterCollision] {
        WorktreeWriterCollisionProjection.collisions(
            panes: panes,
            profiles: permissionProfiles,
            worktrees: worktreeScan.worktrees,
            paneWorktreePaths: worktreeScan.paneWorktreePaths
        )
    }

    var activeWorktreeWriterCollisions: [WorktreeWriterCollision] {
        guard let workspaceID = activeWorkspace?.id else { return [] }
        return worktreeWriterCollisions.filter { collision in
            collision.writers.contains(where: { $0.workspaceID == workspaceID })
        }
    }

    var activeWorktreePath: String? {
        guard let paneID = activePane?.id else { return nil }
        return worktreeScan.paneWorktreePaths[paneID]
    }

    func hasWorktreeWriterCollision(workspaceID: String) -> Bool {
        worktreeWriterCollisions.contains { collision in
            collision.writers.contains(where: { $0.workspaceID == workspaceID })
        }
    }

    func showWorktreeBrowser() {
        showWorktreeBrowser(sourceFolder: activePane?.cwd ?? defaultFolder)
    }

    func showWorktreeBrowser(sourceFolder: String) {
        worktreeBrowserPresented = true
        worktreeDiscoveryLoading = true
        worktreeDiscoveryError = nil
        discoveredWorktreeRepository = nil
        worktreeDiscoveryTask?.cancel()
        let discoveryID = UUID()
        worktreeDiscoveryID = discoveryID
        let resolver = worktreeResolver
        worktreeDiscoveryTask = Task.detached(priority: .utility) { [resolver, sourceFolder, discoveryID] in
            let result = resolver.repository(in: sourceFolder)?.repository
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.worktreeDiscoveryID == discoveryID else { return }
                self.worktreeDiscoveryTask = nil
                self.worktreeDiscoveryID = nil
                self.worktreeDiscoveryLoading = false
                self.discoveredWorktreeRepository = result
                if result == nil {
                    self.worktreeDiscoveryError = "The selected pane folder is not inside a discoverable Git worktree. Ordinary folders remain fully supported."
                }
            }
        }
    }

    func openDiscoveredWorktree(_ worktree: GitWorktreeRecord) {
        perform {
            var isDirectory: ObjCBool = false
            guard worktree.pruneReason == nil,
                  FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw RelayUIError.message("That worktree path is not an existing local directory. Parley did not change Git state.")
            }
            _ = try openWorkspace(folder: worktree.path)
            worktreeBrowserPresented = false
        }
    }

    func canOpenDiscoveredWorktree(_ worktree: GitWorktreeRecord) -> Bool {
        var isDirectory: ObjCBool = false
        return worktree.pruneReason == nil
            && FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
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
                && $0.bracketedPasteActive
        }
    }

    var canCompareAskMany: Bool {
        Set(askTargets.map(\.kind)).count >= 2
            && askManyComparisonRun?.isRunning != true
            && relayClient != nil
    }

    var askManyComparisonLead: TmuxPane? {
        guard let run = askManyComparisonRun else { return nil }
        return panes.first {
            $0.windowID == run.sourceWorkspaceID
                && $0.isWorkspaceLead
                && $0.kind.isAgent
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var askManyOutstandingConsultations: [RelayConsultation] {
        guard let run = askManyComparisonRun, run.isRunning else { return [] }
        let targets = Set(run.targets.map(\.paneID))
        return consultations.filter {
            $0.sourcePaneID == run.sourcePaneID
                && targets.contains($0.targetPaneID)
                && $0.question == run.question
                && $0.createdAt >= run.startedAt
                && $0.state == .awaitingAnswer
        }
    }

    var canCreateContextPack: Bool {
        guard let pane = activePane else { return false }
        return pane.kind.isAgent
            && pane.isStarted
            && !pane.isDead
            && pane.relayEnabled
            && pane.hasCurrentProtocol
            && contextPackBuilder != nil
    }

    var pendingContextReviews: [AgentContextReview] {
        contextReviews.filter(\.state.needsHumanReview)
    }

    var contextPackIsAgentProposed: Bool {
        contextPackDraft?.reviewID != nil
    }

    var activeWorkspaceBrief: WorkspaceBrief? {
        guard let workspaceID = activeWorkspace?.id else { return nil }
        return workspaceBriefs.first(where: { $0.workspaceID == workspaceID })
    }

    var contextPackWorkspaceBrief: WorkspaceBrief? {
        guard let workspaceID = contextPackSourcePane?.windowID else { return nil }
        return workspaceBriefs.first(where: { $0.workspaceID == workspaceID })
    }

    var canAddWorkspaceBriefToContextPack: Bool {
        guard !contextPackIsAgentProposed,
              contextPackWorkspaceBrief != nil,
              let parts = contextPackDraft?.pack.parts else { return false }
        return !parts.contains(where: { $0.source.kind == .workspaceBrief })
    }

    var availablePinnedContextSnippets: [PinnedContextSnippet] {
        guard !contextPackIsAgentProposed,
              let parts = contextPackDraft?.pack.parts else { return [] }
        let attached = Set(parts.compactMap { part in
            part.source.kind == .pinnedSnippet ? part.source.referenceID : nil
        })
        return pinnedContextSnippets.filter { !attached.contains($0.id) }
    }

    var contextPackSourcePane: TmuxPane? {
        guard let draft = contextPackDraft else { return nil }
        return panes.first {
            $0.id == draft.sourcePaneID
                && $0.kind == draft.sourcePaneKind
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var contextPackAskTargets: [TmuxPane] {
        guard let source = contextPackSourcePane else { return [] }
        return panes.filter {
            $0.kind.isAgent
                && $0.kind != source.kind
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var canCompareContextPack: Bool {
        Set(contextPackAskTargets.map(\.kind)).count >= 2
            && askManyComparisonRun?.isRunning != true
            && relayClient != nil
            && contextPackDraft?.reviewID == nil
            && contextPackIsSendable
    }

    var contextPackRenderedByteCount: Int {
        contextPackDraft?.renderedByteCount ?? 0
    }

    var contextPackMaximumBytes: Int {
        contextPackBuilder?.maximumRenderedBytes ?? ContextPackBuilder.defaultMaximumRenderedBytes
    }

    var contextPackMaximumPartBytes: Int {
        contextPackBuilder?.maximumPartBytes ?? ContextPackBuilder.defaultMaximumPartBytes
    }

    var contextPackIsSendable: Bool {
        guard let draft = contextPackDraft,
              !draft.pack.parts.isEmpty,
              !draft.pack.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contextPackSourcePane != nil else { return false }
        return draft.isValid
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
                && $0.bracketedPasteActive
        }
    }

    var activeSupervisedWorkflow: SupervisedWorkflowRun? {
        guard let workspaceID = activeWorkspace?.id else { return nil }
        return supervisedWorkflowRuns.first {
            $0.workspaceID == workspaceID && !$0.phase.isTerminal
        }
    }

    var presentedSupervisedWorkflow: SupervisedWorkflowRun? {
        if let selectedSupervisedWorkflowID,
           let selected = supervisedWorkflowRuns.first(where: { $0.id == selectedSupervisedWorkflowID }) {
            return selected
        }
        return activeSupervisedWorkflow
    }

    var recentSupervisedWorkflows: [SupervisedWorkflowRun] {
        guard let workspaceID = activeWorkspace?.id else { return [] }
        return supervisedWorkflowRuns.filter {
            $0.workspaceID == workspaceID && $0.phase.isTerminal
        }
    }

    var canStartSupervisedWorkflow: Bool {
        guard activeSupervisedWorkflow == nil,
              activeRecipeRun == nil,
              let workspace = activeWorkspace,
              workspace.automationPolicy != .off,
              let lead = workspaceLead,
              lead.isStarted,
              !lead.isDead,
              lead.relayEnabled,
              lead.hasCurrentProtocol,
              lead.bracketedPasteActive else { return false }
        return !recipeTargets.isEmpty
    }

    func pane(for participant: SupervisedWorkflowParticipant) -> TmuxPane? {
        panes.first { $0.id == participant.paneID && $0.windowID == participant.workspaceID }
    }

    func canRun(_ recipe: HandoffRecipe) -> Bool {
        guard let workspace = activeWorkspace,
              activeSupervisedWorkflow == nil,
              let lead = workspaceLead,
              lead.isStarted,
              !lead.isDead,
              lead.relayEnabled,
              lead.hasCurrentProtocol,
              lead.bracketedPasteActive,
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
                let refreshedContextReviews = try relayClient.contextReviews()
                if refreshedContextReviews != contextReviews {
                    contextReviews = refreshedContextReviews
                    if var draft = contextPackDraft,
                       let reviewID = draft.reviewID,
                       let review = refreshedContextReviews.first(where: { $0.id == reviewID }) {
                        draft.reviewState = review.state
                        draft.requestedTargetPaneID = review.requestedTargetPaneID
                        if draft.pack.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           !review.pack.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            draft.pack.note = review.pack.note
                        }
                        updateContextPackMeasurement(&draft)
                        contextPackDraft = draft
                    }
                }
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
        if tmuxAvailable {
            scheduleProjectContextRefresh()
            scheduleWorktreeRefresh()
        }
        publishExternalAttentionSnapshot()
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
            try controller.bootstrap(
                cwd: defaultFolder,
                createIfMissing: !runtime.requiresExistingTmuxSession
            )
        }
        if !coreAvailable {
            if runtime.launchesCore {
                relayClient = try RelayCoreLauncher.ensureRunning(
                    applicationDirectory: controller.applicationDirectory,
                    cwd: defaultFolder,
                    environment: controller.environment,
                    tmuxSessionName: runtime.tmuxSessionName,
                    runtimeMarker: runtime.visibleMarker
                )
            } else {
                relayClient = try RelayCoreLauncher.attachExisting(
                    applicationDirectory: controller.applicationDirectory
                )
            }
        }
        coreUpgradeSettled = false
        if runtime.upgradesCore { scheduleCoreUpgradeCheck(force: true) }
        try refresh()
        startupError = nil
    }

    func refreshQuietly() {
        do { try refresh() } catch { /* the attached client may be between tmux redraws */ }
        scheduleCoreUpgradeCheck()
    }

    private func publishExternalAttentionSnapshot(force: Bool = false) {
        guard runtime.mode == .production else { return }
        let now = Date()
        var byID: [String: RelayHandoff] = [:]
        for handoff in unreadHandoffs + statusHandoffs + handoffs {
            byID[handoff.id] = handoff
        }
        let snapshot = ExternalAttentionProjection.snapshot(
            workspaces: workspaces,
            panes: panes,
            handoffs: Array(byID.values),
            generatedAt: now
        )
        let contentChanged = lastExternalAttentionSnapshot?.hasSameContent(as: snapshot) != true
        let heartbeatDue = now.timeIntervalSince(lastExternalAttentionPublishedAt)
            >= Self.externalAttentionHeartbeatInterval
        guard force || contentChanged || heartbeatDue else { return }
        do {
            try ExternalAttentionSnapshotFile.write(
                snapshot,
                applicationDirectory: applicationDirectory
            )
            lastExternalAttentionSnapshot = snapshot
            lastExternalAttentionPublishedAt = now
        } catch {
            // The editor companion treats a missing or stale snapshot as
            // unavailable. UI refresh must never fail because this optional,
            // read-only integration surface cannot be published safely.
        }
    }

    private func scheduleCoreUpgradeCheck(force: Bool = false) {
        guard runtime.upgradesCore,
              coreUpgradeTask == nil,
              !coreUpgradeSettled,
              !preparingToUninstall,
              let controller else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCoreUpgradeAttempt) >= 2 else { return }
        lastCoreUpgradeAttempt = now

        let client = relayClient
        let expectedIdentity = CoreServiceIdentity.resolve(infoDictionary: Bundle.main.infoDictionary)
        let applicationDirectory = applicationDirectory
        let cwd = defaultFolder
        let environment = controller.environment
        let tmuxSessionName = runtime.tmuxSessionName
        let runtimeMarker = runtime.visibleMarker
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
                            environment: environment,
                            tmuxSessionName: tmuxSessionName,
                            runtimeMarker: runtimeMarker
                        )
                    }
                    return try RelayCoreHandover.reconcile(
                        client: attached,
                        expectedIdentity: expectedIdentity,
                        applicationDirectory: applicationDirectory,
                        cwd: cwd,
                        environment: environment,
                        tmuxSessionName: tmuxSessionName,
                        runtimeMarker: runtimeMarker
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
        // Safety confirmations may describe an inactive workspace, so retain
        // bounded Git snapshots for every live pane rather than only the
        // currently visible workspace.
        let folders = Set(panes.map {
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
                let currentFolders = Set(self.panes.map {
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

    private func scheduleWorktreeRefresh(force: Bool = false) {
        let paneFolders = Dictionary(uniqueKeysWithValues: panes.map { pane in
            (pane.id, URL(fileURLWithPath: pane.cwd).standardizedFileURL.path)
        })
        let foldersChanged = paneFolders != worktreePaneFolders
        let isDue = Date().timeIntervalSince(lastWorktreeRefresh) >= Self.worktreeRefreshInterval
        guard worktreeRefreshTask == nil, force || foldersChanged || isDue else { return }

        worktreePaneFolders = paneFolders
        lastWorktreeRefresh = Date()
        guard !paneFolders.isEmpty else {
            worktreeScan = .empty
            return
        }

        let resolver = worktreeResolver
        worktreeRefreshTask = Task.detached(priority: .utility) { [paneFolders, resolver] in
            let scan = resolver.scan(paneFolders: paneFolders)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.worktreeRefreshTask = nil
                let currentPaneFolders = Dictionary(uniqueKeysWithValues: self.panes.map { pane in
                    (pane.id, URL(fileURLWithPath: pane.cwd).standardizedFileURL.path)
                })
                guard currentPaneFolders == paneFolders else {
                    self.scheduleWorktreeRefresh(force: true)
                    return
                }
                if scan != self.worktreeScan { self.worktreeScan = scan }
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

    func statusHandoffChains(workspaceID: String?) -> [HandoffChain] {
        HandoffChainProjection.chains(reloaded: handoffChains, workspaceID: workspaceID)
    }

    func chains(containing handoff: RelayHandoff) -> [HandoffChain] {
        handoffChains.filter { chain in
            chain.entries.contains(where: { $0.handoffID == handoff.id })
        }
    }

    func chainsAccepting(_ handoff: RelayHandoff) -> [HandoffChain] {
        handoffChains.filter { chain in
            (chain.workspaceID == handoff.sourceWorkspaceID || chain.workspaceID == handoff.targetWorkspaceID)
                && !chain.entries.contains(where: { $0.handoffID == handoff.id })
        }
    }

    func createHandoffChain(from handoff: RelayHandoff) -> HandoffChain? {
        let alert = NSAlert()
        alert.messageText = "Start a Handoff Chain"
        alert.informativeText = "Give this person-curated collaboration history a short title. The selected handoff is snapshotted exactly; no agent is contacted."
        let suggested = Self.paletteSubject(handoff.text)
        let field = NSTextField(string: String(suggested.prefix(160)))
        field.placeholderString = "What this collaboration is about"
        field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create Chain")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        do {
            let workspaceID = handoff.sourceWorkspaceID
            let recordedWorkspaceName = handoff.sourceWorkspaceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName = if let recordedWorkspaceName, !recordedWorkspaceName.isEmpty {
                recordedWorkspaceName
            } else {
                workspaces.first(where: { $0.id == workspaceID })?.name ?? workspaceID
            }
            let chain = try handoffChainStore.create(
                title: field.stringValue,
                workspaceID: workspaceID,
                workspaceName: workspaceName,
                firstEntry: HandoffChainEntry(handoff: handoff)
            )
            try reloadHandoffChains()
            terminalHandle.focus()
            return chain
        } catch {
            NSAlert(error: error).runModal()
            terminalHandle.focus()
            return nil
        }
    }

    func addHandoff(_ handoff: RelayHandoff, to chain: HandoffChain) {
        perform {
            _ = try handoffChainStore.add(entry: HandoffChainEntry(handoff: handoff), to: chain.id)
            try reloadHandoffChains()
            terminalHandle.focus()
        }
    }

    func bookmarkResult(
        from handoff: RelayHandoff,
        in chain: HandoffChain,
        as kind: HandoffChainBookmarkKind
    ) {
        guard kind != .decision,
              let result = handoff.resultText,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let entry = chain.entries.first(where: { $0.handoffID == handoff.id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Bookmark as \(kind.label)?"
        alert.informativeText = "Parley will preserve the complete returned result verbatim in \(chain.title). It will not summarize it or infer agreement."
        alert.addButton(withTitle: "Bookmark \(kind.label)")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            _ = try handoffChainStore.bookmark(
                chainID: chain.id,
                entryID: entry.id,
                kind: kind,
                text: result
            )
            try reloadHandoffChains()
            terminalHandle.focus()
        }
    }

    func addDecision(to chain: HandoffChain) {
        guard let decision = editSupervisedWorkflowText(
            title: "Add Human Decision",
            message: "Record the decision in your own words. It remains attributed to the person using Parley and is never presented as agent consensus.",
            text: "",
            action: "Save Decision",
            insertVisible: { "" }
        ) else { return }
        perform {
            _ = try handoffChainStore.addDecision(chainID: chain.id, text: decision)
            try reloadHandoffChains()
            terminalHandle.focus()
        }
    }

    func deleteHandoffChain(_ chain: HandoffChain) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \(chain.title)?"
        alert.informativeText = "This permanently deletes the curated chain, its exact snapshots, bookmarks and human decisions. The broker's ordinary handoff journal is unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Chain")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try handoffChainStore.delete(id: chain.id)
            try reloadHandoffChains()
            terminalHandle.focus()
            return true
        } catch {
            NSAlert(error: error).runModal()
            terminalHandle.focus()
            return false
        }
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
        preparePane(kind, direction: direction, folder: defaultFolder)
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
        preparePane(kind, direction: direction, folder: url.standardizedFileURL.path)
    }

    private func preparePane(_ kind: PaneKind, direction: SplitDirection, folder: String) {
        let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
        guard kind.isAgent else {
            createPane(kind, direction: direction, folder: standardized, permissionProfile: nil)
            return
        }
        panePermissionRequest = PanePermissionRequest(
            kind: kind,
            folder: standardized,
            action: .create(direction),
            existingSelection: nil
        )
    }

    private func createPane(
        _ kind: PaneKind,
        direction: SplitDirection,
        folder: String,
        permissionProfile: EffectivePermissionProfile?
    ) {
        perform {
            guard let controller else { return }
            let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
            _ = try controller.createPane(
                kind: kind,
                cwd: standardized,
                direction: direction,
                permissionProfile: permissionProfile
            )
            rememberFolder(standardized)
            try refresh()
            terminalHandle.focus()
        }
    }

    func defaultPermissionProfileID(for request: PanePermissionRequest) -> String {
        if let existing = request.existingSelection,
           permissionProfiles.contains(where: { $0.id == existing.profileID }) {
            return existing.profileID
        }
        let key = permissionProfilePreferenceKey(for: request.kind)
        if let stored = preferences.string(forKey: key),
           let profile = permissionProfiles.first(where: { $0.id == stored }),
           profile.defaultLifetime == .remembered {
            return profile.id
        }
        return "default"
    }

    func permissionProfileName(for pane: TmuxPane) -> String? {
        guard let id = pane.permissionSelection?.profileID else { return nil }
        return permissionProfiles.first(where: { $0.id == id })?.name ?? id
    }

    @discardableResult
    func saveCustomPermissionProfile(_ profile: PermissionProfileDefinition) throws -> PermissionProfileDefinition {
        try permissionProfileStore.saveCustom(profile)
        permissionProfiles = try permissionProfileStore.profiles()
        return profile
    }

    func clonePermissionProfile(
        _ source: PermissionProfileDefinition,
        name: String
    ) throws -> PermissionProfileDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RelayUIError.message("Enter a name for the custom permission profile.")
        }
        let stem = trimmed.lowercased().unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            if (97...122).contains(value) || (48...57).contains(value) {
                return Character(String(scalar))
            }
            return "-"
        }
        let compact = String(stem)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let safeStem = String((compact.isEmpty ? "profile" : compact).prefix(48))
        let identifier = "custom-\(safeStem)-\(UUID().uuidString.lowercased().prefix(8))"
        return try saveCustomPermissionProfile(source.clone(id: identifier, name: trimmed))
    }

    func applyPermissionProfile(
        to request: PanePermissionRequest,
        profileID: String,
        approvedRoots: [String]
    ) {
        do {
            guard panePermissionRequest?.id == request.id else { return }
            guard let definition = permissionProfiles.first(where: { $0.id == profileID }) else {
                throw RelayUIError.message("That permission profile is no longer available.")
            }
            let effective = try PermissionProfileResolver.resolve(
                definition: definition,
                paneFolder: request.folder,
                approvedRoots: definition.rootMode == .exactApprovedRoots ? approvedRoots : []
            )
            guard effective.approvedRoots.contains(canonicalFolder(request.folder)) else {
                throw RelayUIError.message("The pane folder must remain one of the approved roots.")
            }

            guard let controller else { return }
            switch request.action {
            case let .create(direction):
                _ = try controller.createPane(
                    kind: request.kind,
                    cwd: request.folder,
                    direction: direction,
                    permissionProfile: effective
                )
                rememberFolder(request.folder)
            case let .restart(paneID):
                try controller.restartPane(paneID, permissionProfile: effective)
                if let pane = panes.first(where: { $0.id == paneID }) {
                    try recordSuccessfulActivity(RelayActivityEventRequest(
                        kind: .paneRestarted,
                        workspaceID: pane.windowID,
                        workspaceName: pane.workspaceName ?? pane.windowID,
                        paneID: pane.id,
                        paneName: pane.displayName,
                        paneKind: pane.kind,
                        detail: "\(pane.kind.label) pane restarted with \(definition.name) permissions."
                    ))
                }
            case let .start(paneID):
                try controller.startPane(paneID, permissionProfile: effective)
            }

            if definition.defaultLifetime == .remembered {
                preferences.set(
                    definition.id,
                    forKey: permissionProfilePreferenceKey(for: request.kind)
                )
            }
            panePermissionRequest = nil
            try refresh()
            terminalHandle.focus()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func cancelPermissionProfileSelection() {
        panePermissionRequest = nil
        terminalHandle.focus()
    }

    func requestHelp(topicID: String) {
        requestedHelpTopicID = topicID
    }

    private func permissionProfilePreferenceKey(for kind: PaneKind) -> String {
        "\(Self.permissionProfileKeyPrefix).\(kind.rawValue)"
    }

    private func canonicalFolder(_ folder: String) -> String {
        URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
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

    func editWorkspaceBrief() {
        guard let workspace = activeWorkspace else { return }
        let existing = workspaceBriefs.first(where: { $0.workspaceID == workspace.id })
        workspaceBriefDraft = ActiveWorkspaceBriefDraft(
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            existingBriefID: existing?.id,
            goal: existing?.goal ?? "",
            constraints: existing?.constraints ?? "",
            decisions: existing?.decisions ?? ""
        )
        workspaceBriefPresented = true
    }

    func presentPinnedContextSnippets() {
        pinnedContextSnippetsPresented = true
    }

    @discardableResult
    func savePinnedContextSnippet(id: String?, title: String, text: String) -> String? {
        do {
            let saved = try pinnedContextSnippetStore.save(id: id, title: title, text: text)
            try reloadPinnedContextSnippets()
            return saved.id
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func deletePinnedContextSnippet(_ snippet: PinnedContextSnippet) {
        let alert = NSAlert()
        alert.messageText = "Delete \(snippet.title)?"
        alert.informativeText = "This removes only the reusable local snippet. Existing context-pack snapshots and agent panes are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Snippet")
        alert.addButton(withTitle: "Keep Snippet")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try pinnedContextSnippetStore.delete(id: snippet.id)
            try reloadPinnedContextSnippets()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func dismissWorkspaceBrief() {
        workspaceBriefPresented = false
        workspaceBriefDraft = nil
        terminalHandle.focus()
    }

    func saveWorkspaceBrief(goal: String, constraints: String, decisions: String) {
        do {
            guard let draft = workspaceBriefDraft else { return }
            _ = try workspaceBriefStore.save(
                workspaceID: draft.workspaceID,
                workspaceName: draft.workspaceName,
                goal: goal,
                constraints: constraints,
                decisions: decisions
            )
            try reloadWorkspaceBriefs()
            workspaceBriefPresented = false
            workspaceBriefDraft = nil
            terminalHandle.focus()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func deleteWorkspaceBrief() {
        guard let draft = workspaceBriefDraft, draft.existingBriefID != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the workspace brief for \(draft.workspaceName)?"
        alert.informativeText = "This removes only the saved local brief. Existing context-pack snapshots and agent panes are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Brief")
        alert.addButton(withTitle: "Keep Brief")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try workspaceBriefStore.delete(workspaceID: draft.workspaceID)
            try reloadWorkspaceBriefs()
            workspaceBriefPresented = false
            workspaceBriefDraft = nil
            terminalHandle.focus()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func newContextPackWithWorkspaceBrief() {
        guard activeWorkspaceBrief != nil else { return }
        let previousDraftID = contextPackDraft?.id
        newContextPack()
        guard let newDraftID = contextPackDraft?.id,
              newDraftID != previousDraftID else { return }
        addWorkspaceBriefContext()
    }

    func newContextPack() {
        guard canCreateContextPack, let source = activePane else { return }
        if let existing = contextPackDraft, !existing.pack.parts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the current context pack?"
            alert.informativeText = "The current pack has \(existing.pack.parts.count) explicit source\(existing.pack.parts.count == 1 ? "" : "s"). Context packs are local drafts; replacing it cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace Draft")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var draft = ActiveContextPack(
            id: UUID().uuidString.lowercased(),
            sourcePaneID: source.id,
            sourcePaneKind: source.kind,
            sourcePaneName: source.displayName,
            sourceFolder: source.cwd,
            pack: ContextPack(name: "\(source.displayName) context"),
            reviewID: nil,
            reviewState: nil,
            requestedTargetPaneID: nil,
            reviewUpdatedAt: nil
        )
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
        contextPackPresented = true
    }

    func presentContextPack() {
        guard contextPackDraft != nil else { return }
        contextPackPresented = true
    }

    func presentContextReview(_ review: AgentContextReview) {
        guard review.state.needsHumanReview else { return }
        if let existing = contextPackDraft,
           existing.reviewID != review.id,
           !existing.pack.parts.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace the current context pack?"
            alert.informativeText = "The current editable pack will be replaced by \(review.sourcePaneName)'s staged context. The staged review remains available in the Context menu until you approve or decline it."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Agent Draft")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var draft = ActiveContextPack(
            id: review.id,
            sourcePaneID: review.sourcePaneID,
            sourcePaneKind: review.sourcePaneKind,
            sourcePaneName: review.sourcePaneName,
            sourceFolder: review.sourceFolder,
            pack: review.pack,
            reviewID: review.id,
            reviewState: review.state,
            requestedTargetPaneID: review.requestedTargetPaneID,
            reviewUpdatedAt: review.updatedAt
        )
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
        contextPackPresented = true
    }

    func rejectCurrentContextReview() {
        perform {
            guard let draft = contextPackDraft,
                  let reviewID = draft.reviewID,
                  let relayClient else { return }
            let isWaitingAsk = draft.reviewState == .awaitingReview
            let alert = NSAlert()
            alert.messageText = isWaitingAsk
                ? "Decline this agent context Ask?"
                : "Discard this agent context draft?"
            alert.informativeText = isWaitingAsk
                ? "Nothing will be submitted. The source pane blocked in `parley ask --context` will receive an explicit refusal."
                : "Nothing will be submitted. The source pane can stage a new draft later."
            alert.alertStyle = .warning
            alert.addButton(withTitle: isWaitingAsk ? "Decline Ask" : "Discard Draft")
            alert.addButton(withTitle: "Keep Reviewing")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let response = try relayClient.rejectContextReview(reviewID)
            guard (200..<300).contains(response.status) else {
                throw RelayUIError.message(response.text)
            }
            contextPackPresented = false
            contextPackDraft = nil
            try refresh()
            terminalHandle.focus()
        }
    }

    func dismissContextPack() {
        contextPackPresented = false
        terminalHandle.focus()
    }

    func updateContextPackName(_ name: String) {
        guard var draft = contextPackDraft else { return }
        draft.pack.name = name
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
    }

    func updateContextPackNote(_ note: String) {
        guard var draft = contextPackDraft else { return }
        draft.pack.note = note
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
    }

    func updateContextPackPart(_ partID: String, text: String) {
        guard var draft = contextPackDraft,
              let index = draft.pack.parts.firstIndex(where: { $0.id == partID }) else { return }
        draft.pack.parts[index] = draft.pack.parts[index].replacingText(text)
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
    }

    func removeContextPackPart(_ partID: String) {
        guard var draft = contextPackDraft else { return }
        draft.pack.parts.removeAll { $0.id == partID }
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
    }

    func addContextFiles() {
        guard let draft = contextPackDraft else { return }
        let panel = NSOpenPanel()
        panel.title = "Add explicit text files to \(draft.pack.name)"
        panel.prompt = "Add Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: draft.sourceFolder)
        guard panel.runModal() == .OK else { return }

        perform {
            if let reviewID = draft.reviewID {
                try captureTrustedContext(
                    AgentContextTrustedCaptureRequest(
                        reviewID: reviewID,
                        kind: .files,
                        paths: panel.urls.map(\.path)
                    ),
                    draftID: draft.id
                )
            } else {
                guard let contextPackBuilder else { return }
                let parts = try panel.urls.map { try contextPackBuilder.file(at: $0) }
                try appendContextPackParts(parts, draftID: draft.id)
            }
        }
    }

    func addContextGitDiff() {
        perform {
            guard let draft = contextPackDraft else { return }
            if let reviewID = draft.reviewID {
                try captureTrustedContext(
                    AgentContextTrustedCaptureRequest(reviewID: reviewID, kind: .gitDiff),
                    draftID: draft.id
                )
            } else {
                guard let contextPackBuilder else { return }
                let part = try contextPackBuilder.gitDiff(in: draft.sourceFolder)
                try appendContextPackParts([part], draftID: draft.id)
            }
        }
    }

    func addVisibleTerminalContext() {
        guard let draft = contextPackDraft else { return }
        let candidates = panes.filter { $0.isStarted && !$0.isDead }
        guard let pane = chooseContextPane(candidates: candidates) else { return }
        perform {
            if let reviewID = draft.reviewID {
                try captureTrustedContext(
                    AgentContextTrustedCaptureRequest(
                        reviewID: reviewID,
                        kind: .visibleTerminal,
                        paneID: pane.id
                    ),
                    draftID: draft.id
                )
            } else {
                guard let controller, let contextPackBuilder else { return }
                let visible = try controller.capturePane(pane.id)
                let part = try contextPackBuilder.visibleTerminal(
                    paneID: pane.id,
                    paneName: pane.displayName,
                    text: visible
                )
                try appendContextPackParts([part], draftID: draft.id)
            }
            terminalHandle.terminal?.selectNone()
        }
    }

    func addWorkspaceBriefContext() {
        perform {
            guard canAddWorkspaceBriefToContextPack,
                  let draft = contextPackDraft,
                  let source = contextPackSourcePane,
                  let savedBrief = contextPackWorkspaceBrief,
                  let contextPackBuilder else {
                throw RelayUIError.message(
                    "Save a brief for this context pack's workspace before attaching it."
                )
            }
            let currentWorkspaceName = source.workspaceName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceName: String
            if let currentWorkspaceName, !currentWorkspaceName.isEmpty {
                workspaceName = currentWorkspaceName
            } else {
                workspaceName = savedBrief.workspaceName
            }
            let brief = WorkspaceBrief(
                id: savedBrief.id,
                workspaceID: savedBrief.workspaceID,
                workspaceName: workspaceName,
                goal: savedBrief.goal,
                constraints: savedBrief.constraints,
                decisions: savedBrief.decisions,
                createdAt: savedBrief.createdAt,
                updatedAt: savedBrief.updatedAt
            )
            let part = try contextPackBuilder.workspaceBrief(brief)
            try appendContextPackParts([part], draftID: draft.id)
        }
    }

    func addPinnedContextSnippets(ids: [String]) {
        perform {
            guard !contextPackIsAgentProposed,
                  let draft = contextPackDraft,
                  let contextPackBuilder else {
                throw RelayUIError.message("Open a person-created context pack before adding pinned context.")
            }
            let uniqueIDs = ids.reduce(into: [String]()) { result, id in
                if !result.contains(id) { result.append(id) }
            }
            guard !uniqueIDs.isEmpty else {
                throw RelayUIError.message("Choose at least one pinned context snippet to add.")
            }
            let available = Dictionary(uniqueKeysWithValues: availablePinnedContextSnippets.map { ($0.id, $0) })
            guard uniqueIDs.allSatisfy({ available[$0] != nil }) else {
                throw RelayUIError.message("One of those snippets is unavailable or already attached.")
            }
            let parts = try uniqueIDs.compactMap { id in
                try available[id].map(contextPackBuilder.pinnedSnippet)
            }
            try appendContextPackParts(parts, draftID: draft.id)
        }
    }

    func captureContextCommand(executablePath: String, argumentLines: String) async throws {
        guard let draft = contextPackDraft else {
            throw RelayUIError.message("Open a context pack before capturing a command result.")
        }
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = argumentLines
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        contextCommandCapturing = true
        defer { contextCommandCapturing = false }
        if let reviewID = draft.reviewID {
            guard let relayClient else {
                throw RelayUIError.message("The persistent core is unavailable, so Parley cannot establish trusted capture provenance.")
            }
            let request = AgentContextTrustedCaptureRequest(
                reviewID: reviewID,
                kind: .commandResult,
                executablePath: path,
                arguments: arguments
            )
            let response = try await Task.detached(priority: .userInitiated) {
                try relayClient.captureTrustedContext(request)
            }.value
            try appendTrustedContextResponse(response, draftID: draft.id)
            return
        }
        guard let contextPackBuilder else {
            throw RelayUIError.message("Context capture is unavailable.")
        }
        let workingDirectory = URL(fileURLWithPath: draft.sourceFolder, isDirectory: true)
        let part = try await Task.detached(priority: .userInitiated) {
            try contextPackBuilder.commandResult(
                executablePath: path,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        }.value
        try appendContextPackParts([part], draftID: draft.id)
    }

    func askWithContextPack() {
        perform {
            guard let draft = contextPackDraft,
                  let source = contextPackSourcePane,
                  let contextPackBuilder,
                  let controller else {
                throw RelayUIError.message("The context pack's source pane is no longer ready.")
            }
            let rendered = try contextPackBuilder.render(draft.pack)
            guard let target = chooseContextTarget(
                candidates: contextPackAskTargets,
                preferredPaneID: draft.requestedTargetPaneID
            ) else { return }
            let isAwaitingAgent = draft.reviewID != nil && draft.reviewState == .awaitingReview
            guard confirmContextSend(
                title: isAwaitingAgent
                    ? "Approve \(source.displayName)'s context Ask to \(target.displayName)?"
                    : "Ask \(target.displayName) with this context pack?",
                detail: "\(draft.pack.parts.count) source\(draft.pack.parts.count == 1 ? "" : "s") · \(rendered.utf8.count) UTF-8 bytes · from \(source.displayName)\(isAwaitingAgent ? " · approval unblocks the waiting source pane" : "")",
                action: isAwaitingAgent ? "Approve and Ask" : "Ask with Context"
            ) else { return }
            if let reviewID = draft.reviewID, draft.reviewState == .awaitingReview {
                guard let relayClient else {
                    throw RelayUIError.message("The persistent core is unavailable, so this agent request cannot be approved.")
                }
                guard let expectedUpdatedAt = draft.reviewUpdatedAt else {
                    throw RelayUIError.message("Reopen this agent review before approving its latest sources.")
                }
                let response = try relayClient.approveContextReview(
                    reviewID: reviewID,
                    expectedUpdatedAt: expectedUpdatedAt,
                    pack: draft.pack,
                    targetPaneID: target.id
                )
                guard (200..<300).contains(response.status) else {
                    throw RelayUIError.message(response.text)
                }
            } else if let reviewID = draft.reviewID {
                guard let relayClient else {
                    throw RelayUIError.message("The persistent core is unavailable, so this agent draft cannot be sent safely.")
                }
                guard let expectedUpdatedAt = draft.reviewUpdatedAt else {
                    throw RelayUIError.message("Reopen this agent review before sending its latest sources.")
                }
                let response = try relayClient.completeContextDraft(
                    reviewID: reviewID,
                    expectedUpdatedAt: expectedUpdatedAt,
                    pack: draft.pack,
                    targetPaneID: target.id
                )
                guard (200..<300).contains(response.status) else {
                    throw RelayUIError.message(response.text)
                }
                if response.status != 200 {
                    let alert = NSAlert()
                    alert.messageText = "Context was sent with a record warning"
                    alert.informativeText = response.text
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            } else {
                try controller.askWithExplicitContext(from: source.id, to: target.id, text: rendered)
            }
            contextPackPresented = false
            contextPackDraft = nil
            try refresh()
            terminalHandle.focus()
        }
    }

    func compareWithContextPack() {
        perform {
            guard canCompareContextPack,
                  let draft = contextPackDraft,
                  let source = contextPackSourcePane,
                  let contextPackBuilder else {
                throw RelayUIError.message("This context pack needs a ready source pane and at least two other target vendors.")
            }
            let rendered = try contextPackBuilder.render(draft.pack)
            guard let targets = chooseAskManyTargets(candidates: contextPackAskTargets) else { return }
            guard confirmContextSend(
                title: "Compare this context across \(targets.count) vendors?",
                detail: "Every selected pane receives the same \(rendered.utf8.count)-byte attributed pack and none sees a peer answer.",
                action: "Compare Independently"
            ) else { return }
            contextPackPresented = false
            DispatchQueue.main.async { [weak self] in
                self?.launchAskMany(
                    source: source,
                    targets: targets,
                    question: rendered,
                    preserveFormatting: true
                )
            }
        }
    }

    func compareAskMany() {
        guard canCompareAskMany,
              let source = activePane else { return }
        guard let targets = chooseAskManyTargets(candidates: askTargets) else { return }
        guard let question = editRelay(
            title: "Compare Independent Answers",
            message: "Only this exact question will be submitted to every selected pane. They answer concurrently and do not see one another's responses.",
            text: RelayDraft.initialText(selection: terminalHandle.selectedText),
            action: "Ask Independently",
            insertVisible: { [weak self] in
                guard let self, let controller = self.controller else { return "" }
                return try controller.capturePane(source.id)
            }
        ) else { return }

        launchAskMany(source: source, targets: targets, question: question)
    }

    private func launchAskMany(
        source: TmuxPane,
        targets: [TmuxPane],
        question: String,
        preserveFormatting: Bool = false
    ) {
        guard let relayClient else { return }
        let run = AskManyComparisonRun(
            id: UUID().uuidString.lowercased(),
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceWorkspaceID: source.windowID,
            question: question,
            targets: targets.map {
                AskManyComparisonTarget(
                    paneID: $0.id,
                    name: $0.displayName,
                    kind: $0.kind,
                    workspaceName: $0.workspaceName
                )
            },
            startedAt: Date(),
            response: nil,
            error: nil
        )
        askManyComparisonRun = run
        askManyComparisonPresented = true
        terminalHandle.terminal?.selectNone()

        let targetPaneIDs = targets.map(\.id)
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.askManyFromUI(
                        sourcePaneID: source.id,
                        targetPaneIDs: targetPaneIDs,
                        text: question,
                        idempotencyKey: run.id,
                        preserveFormatting: preserveFormatting
                    )
                }.value
                guard var current = self.askManyComparisonRun, current.id == run.id else { return }
                current.response = response
                self.askManyComparisonRun = current
                try? self.refresh()
                self.acknowledgeVisibleComparisonResults()
            } catch {
                guard var current = self.askManyComparisonRun, current.id == run.id else { return }
                current.error = error.localizedDescription
                self.askManyComparisonRun = current
                try? self.refresh()
            }
        }
    }

    func presentAskManyComparison() {
        guard askManyComparisonRun != nil else { return }
        askManyComparisonPresented = true
        acknowledgeVisibleComparisonResults()
    }

    func dismissAskManyComparison() {
        askManyComparisonPresented = false
        terminalHandle.focus()
    }

    func cancelAskManyComparison() {
        let outstanding = askManyOutstandingConsultations
        guard !outstanding.isEmpty, let relayClient else { return }
        perform {
            for consultation in outstanding {
                let response = try relayClient.cancelHandoff(consultation.id)
                guard response.status == 200 else { throw RelayUIError.message(response.text) }
            }
            try refresh()
        }
    }

    func forwardComparisonAnswers(_ targetPaneIDs: Set<String>, asSynthesis: Bool) {
        perform {
            guard let run = askManyComparisonRun,
                  let answers = run.response?.bundle.answers,
                  let lead = askManyComparisonLead,
                  let controller else {
                throw RelayUIError.message("Mark a ready agent pane as the workspace lead before forwarding comparison results.")
            }
            let draft = if asSynthesis {
                try AskManyComparisonDraft.synthesisText(question: run.question, answers: answers)
            } else {
                try AskManyComparisonDraft.forwardingText(
                    question: run.question,
                    answers: answers,
                    selectedTargetPaneIDs: targetPaneIDs
                )
            }
            let title = asSynthesis ? "Edit Synthesis for \(lead.displayName)" : "Forward Answers to \(lead.displayName)"
            guard let edited = editRelay(
                title: title,
                message: "Review the exact attributed text before it is submitted to workspace lead \(lead.displayName). Parley does not create a verdict or merge the answers for you.",
                text: draft,
                action: asSynthesis ? "Send Edited Synthesis" : "Forward Selected",
                insertVisible: { "" }
            ) else { return }
            try controller.paste(
                "The person using Parley forwarded an independent cross-vendor comparison:\n\n\(edited)",
                into: lead.id,
                submit: true
            )
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .comparisonForwarded,
                workspaceID: run.sourceWorkspaceID,
                workspaceName: lead.workspaceName ?? "Workspace",
                paneID: lead.id,
                paneName: lead.displayName,
                paneKind: lead.kind,
                detail: asSynthesis
                    ? "Submitted a person-edited synthesis from an independent comparison."
                    : "Forwarded \(targetPaneIDs.count) attributed independent answer\(targetPaneIDs.count == 1 ? "" : "s")."
            ))
            try controller.selectPane(lead.id)
            try refresh()
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

    func startSupervisedWorkflow() {
        perform {
            guard canStartSupervisedWorkflow,
                  let controller,
                  let workspace = activeWorkspace,
                  let lead = workspaceLead else {
                throw RelayUIError.message(
                    "Mark a ready agent pane as workspace lead and open a ready pane from another vendor first."
                )
            }
            guard let participants = chooseSupervisedWorkflowParticipants(candidates: recipeTargets) else { return }
            let selectedContext = lead.isActive ? terminalHandle.selectedText : nil
            var initial = "The person using Parley started a supervised Plan → Review → Implement → Verify workflow. Complete only the planning step below, then stop and wait for the next human-approved checkpoint.\n\n"
            if let selectedContext {
                initial += "Task context explicitly selected by the person:\n\n\(selectedContext)\n\n"
            }
            initial += """
            Create a concrete implementation plan for the current task. Inspect what you need, identify risks and verification, but do not edit files or begin implementation. Stop after presenting the plan and wait for the next human-approved checkpoint.
            """
            guard let edited = editSupervisedWorkflowText(
                title: "Start Supervised Workflow",
                message: "This exact planning instruction will be submitted to \(lead.displayName). Parley will stop at every later transition for human review.",
                text: initial,
                action: "Start Planning",
                insertVisible: { try controller.capturePane(lead.id) }
            ) else { return }

            let leadStamp = workflowParticipant(lead)
            let reviewerStamp = workflowParticipant(participants.reviewer)
            let verifierStamp = workflowParticipant(participants.verifier)
            let run = try supervisedWorkflowStore.start(
                workspaceID: workspace.id,
                workspaceName: workspace.name,
                lead: leadStamp,
                reviewer: reviewerStamp,
                verifier: verifierStamp,
                planningPrompt: edited
            )
            do {
                try controller.pasteExplicitContext(edited, into: lead.id, submit: true)
            } catch {
                _ = try? supervisedWorkflowStore.interrupt(
                    id: run.id,
                    detail: "Planning dispatch failed before the workflow could continue: \(error.localizedDescription)"
                )
                try reloadSupervisedWorkflows()
                throw error
            }
            try reloadSupervisedWorkflows()
            selectedSupervisedWorkflowID = run.id
            supervisedWorkflowPresented = true
            try controller.selectPane(lead.id)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func presentSupervisedWorkflow() {
        guard let run = activeSupervisedWorkflow else { return }
        selectedSupervisedWorkflowID = run.id
        supervisedWorkflowPresented = true
    }

    func presentSupervisedWorkflow(_ run: SupervisedWorkflowRun) {
        guard supervisedWorkflowRuns.contains(where: { $0.id == run.id }) else { return }
        selectedSupervisedWorkflowID = run.id
        supervisedWorkflowPresented = true
    }

    func sendWorkflowPlanForReview() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .planning)
            guard let controller else { return }
            let lead = try requireWorkflowPane(run.lead, role: "lead")
            let reviewer = try requireWorkflowPane(run.reviewer, role: "reviewer")
            let visible = try controller.capturePane(lead.id)
            let initial = """
            \(lead.displayName) produced this proposed plan. Review it independently for correctness, missing risks, unnecessary scope and verification gaps. Do not implement anything. Return a concrete review in this pane, then stop and wait for the person using Parley.

            --- PROPOSED PLAN ---

            \(visible)
            """
            guard let plan = editSupervisedWorkflowText(
                title: "Review the Plan",
                message: "This is the exact payload that will be sent to \(reviewer.displayName). Nothing is implemented at this step.",
                text: initial,
                action: "Send for Independent Review",
                insertVisible: { try controller.capturePane(lead.id) }
            ) else { return }
            try controller.pasteExplicitContext(plan, into: reviewer.id, submit: true)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .reviewingPlan,
                artifact: SupervisedWorkflowArtifact(kind: .plan, text: plan),
                detail: "The person reviewed the captured plan and dispatched it to \(reviewer.displayName)."
            )
            try reloadSupervisedWorkflows()
            try controller.selectPane(reviewer.id)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func captureWorkflowPlanReview() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .reviewingPlan)
            guard let controller else { return }
            let reviewer = try requireWorkflowPane(run.reviewer, role: "reviewer")
            let visible = try controller.capturePane(reviewer.id)
            guard let review = editSupervisedWorkflowText(
                title: "Capture Independent Review",
                message: "Review and edit the exact independent answer. Saving it reaches the implementation checkpoint but submits nothing to the lead.",
                text: visible,
                action: "Save Review",
                insertVisible: { try controller.capturePane(reviewer.id) }
            ) else { return }
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .awaitingImplementationApproval,
                artifact: SupervisedWorkflowArtifact(kind: .planReview, text: review),
                detail: "The person captured the independent plan review. Implementation remains blocked."
            )
            try reloadSupervisedWorkflows()
            supervisedWorkflowPresented = true
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func approveWorkflowImplementation() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .awaitingImplementationApproval)
            guard let controller,
                  let plan = run.artifact(.plan)?.text,
                  let review = run.artifact(.planReview)?.text else {
                throw RelayUIError.message("The workflow is missing its reviewed plan artifacts.")
            }
            let lead = try requireWorkflowPane(run.lead, role: "lead")
            let draft = """
            The person using Parley reviewed the proposed plan and the independent review below. Implement the sound plan, accounting for confirmed review findings. Do not treat reviewer claims as facts without checking them. Run proportionate verification, report the exact results, then stop and wait for the verification checkpoint.

            --- APPROVED PLAN ---

            \(plan)

            --- INDEPENDENT REVIEW ---

            \(review)
            """
            guard let edited = editSupervisedWorkflowText(
                title: "Approve Implementation",
                message: "This is the consequential checkpoint. Only the exact text below will be submitted to \(lead.displayName).",
                text: draft,
                action: "Approve and Implement",
                insertVisible: { "" }
            ) else { return }
            try controller.pasteExplicitContext(edited, into: lead.id, submit: true)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .implementing,
                artifact: nil,
                detail: "The person explicitly approved implementation and submitted the reviewed instruction to \(lead.displayName)."
            )
            try reloadSupervisedWorkflows()
            try controller.selectPane(lead.id)
            try refresh()
            terminalHandle.focus()
        }
    }

    func sendWorkflowImplementationForVerification() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .implementing)
            guard let controller, let reviewDraftBuilder else { return }
            let lead = try requireWorkflowPane(run.lead, role: "lead")
            let verifier = try requireWorkflowPane(run.verifier, role: "verifier")
            let evidence = try reviewDraftBuilder.changes(in: lead.cwd)
            let initial = """
            Independently verify the implementation evidence below. Inspect the repository as permitted, run proportionate checks, and report concrete defects or a clean result with exact command outcomes. Do not modify files. Stop after reporting in this pane and wait for the person using Parley.

            --- IMPLEMENTATION EVIDENCE ---

            \(evidence.text)
            """
            guard let edited = editSupervisedWorkflowText(
                title: "Verify the Implementation",
                message: "This is the exact payload that will be sent to \(verifier.displayName). The verifier is asked only to inspect and report.",
                text: initial,
                action: "Send for Independent Verification",
                insertVisible: { try controller.capturePane(lead.id) }
            ) else { return }
            try controller.pasteExplicitContext(edited, into: verifier.id, submit: true)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .verifying,
                artifact: SupervisedWorkflowArtifact(kind: .implementation, text: edited),
                detail: "The person reviewed the implementation evidence and dispatched it to \(verifier.displayName)."
            )
            try reloadSupervisedWorkflows()
            try controller.selectPane(verifier.id)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func captureWorkflowVerification() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .verifying)
            guard let controller else { return }
            let verifier = try requireWorkflowPane(run.verifier, role: "verifier")
            let visible = try controller.capturePane(verifier.id)
            guard let verification = editSupervisedWorkflowText(
                title: "Capture Independent Verification",
                message: "Review and edit the exact verification result. Saving reaches the completion checkpoint; it does not declare the work complete.",
                text: visible,
                action: "Save Verification",
                insertVisible: { try controller.capturePane(verifier.id) }
            ) else { return }
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .awaitingCompletionApproval,
                artifact: SupervisedWorkflowArtifact(kind: .verification, text: verification),
                detail: "The person captured the independent verification. Completion remains blocked."
            )
            try reloadSupervisedWorkflows()
            supervisedWorkflowPresented = true
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
    }

    func completeSupervisedWorkflow() {
        perform {
            let run = try requireActiveSupervisedWorkflow(phase: .awaitingCompletionApproval)
            let alert = NSAlert()
            alert.messageText = "Mark this workflow complete?"
            alert.informativeText = "You are confirming that you reviewed the independent verification. Parley does not infer success from the verifier's prose."
            alert.addButton(withTitle: "Mark Complete")
            alert.addButton(withTitle: "Keep Open")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .completed,
                artifact: nil,
                detail: "The person reviewed the verification and marked the workflow complete."
            )
            try reloadSupervisedWorkflows()
            terminalHandle.focus()
        }
    }

    func interruptSupervisedWorkflow() {
        guard let run = activeSupervisedWorkflow else { return }
        let alert = NSAlert()
        alert.messageText = "End this supervised workflow?"
        alert.informativeText = "This stops Parley's sequence tracking. It does not send Control-C or cancel work already running in any agent pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Workflow")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            _ = try supervisedWorkflowStore.interrupt(
                id: run.id,
                detail: "The person ended workflow tracking. No agent process was interrupted automatically."
            )
            try reloadSupervisedWorkflows()
            terminalHandle.focus()
        }
    }

    func focusWorkflowParticipant(_ participant: SupervisedWorkflowParticipant) {
        guard let pane = pane(for: participant) else { return }
        select(pane)
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

    private func chooseSupervisedWorkflowParticipants(
        candidates: [TmuxPane]
    ) -> (reviewer: TmuxPane, verifier: TmuxPane)? {
        guard !candidates.isEmpty else { return nil }
        let titles = candidates.map { "\($0.displayName) · \($0.kind.label) (\($0.id))" }
        let reviewerPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        reviewerPicker.addItems(withTitles: titles)
        let verifierPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        verifierPicker.addItems(withTitles: titles)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(NSTextField(labelWithString: "Independent plan reviewer"))
        stack.addArrangedSubview(reviewerPicker)
        stack.addArrangedSubview(NSTextField(labelWithString: "Independent implementation verifier"))
        stack.addArrangedSubview(verifierPicker)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 96)

        let alert = NSAlert()
        alert.messageText = "Choose Workflow Participants"
        alert.informativeText = "Both roles must use a vendor different from the workspace lead. The same pane may review and verify."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (
            candidates[max(0, reviewerPicker.indexOfSelectedItem)],
            candidates[max(0, verifierPicker.indexOfSelectedItem)]
        )
    }

    private func workflowParticipant(_ pane: TmuxPane) -> SupervisedWorkflowParticipant {
        SupervisedWorkflowParticipant(
            paneID: pane.id,
            name: pane.displayName,
            kind: pane.kind,
            workspaceID: pane.windowID
        )
    }

    private func requireActiveSupervisedWorkflow(
        phase: SupervisedWorkflowPhase
    ) throws -> SupervisedWorkflowRun {
        guard let run = activeSupervisedWorkflow else {
            throw RelayUIError.message("There is no active supervised workflow in this workspace.")
        }
        guard run.phase == phase else {
            throw RelayUIError.message(
                "This workflow is at \(run.phase.label), not the expected \(phase.label) checkpoint."
            )
        }
        return run
    }

    private func requireWorkflowPane(
        _ participant: SupervisedWorkflowParticipant,
        role: String
    ) throws -> TmuxPane {
        guard let pane = pane(for: participant),
              pane.kind == participant.kind,
              pane.kind.isAgent,
              pane.isStarted,
              !pane.isDead,
              pane.relayEnabled,
              pane.hasCurrentProtocol,
              pane.bracketedPasteActive else {
            throw RelayUIError.message(
                "The workflow \(role) \(participant.name) is not currently ready. Restart or replace that pane, or end the workflow explicitly."
            )
        }
        return pane
    }

    private func reloadSupervisedWorkflows() throws {
        supervisedWorkflowRuns = try supervisedWorkflowStore.runs()
    }

    private func reloadHandoffChains() throws {
        handoffChains = try handoffChainStore.chains()
    }

    private func reloadWorkspaceBriefs() throws {
        workspaceBriefs = try workspaceBriefStore.briefs()
    }

    private func reloadPinnedContextSnippets() throws {
        pinnedContextSnippets = try pinnedContextSnippetStore.snippets()
    }

    private func chooseAskManyTargets(candidates: [TmuxPane]) -> [TmuxPane]? {
        let alert = NSAlert()
        alert.messageText = "Compare with which panes?"
        alert.informativeText = "Choose at least two panes from different vendors. Every selected pane receives the same question independently."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let buttons = candidates.map { pane in
            let location = pane.workspaceName.map { " · \($0)" } ?? ""
            let button = NSButton(
                checkboxWithTitle: "\(pane.displayName) · \(pane.kind.label)\(location) (\(pane.id))",
                target: nil,
                action: nil
            )
            button.state = .on
            stack.addArrangedSubview(button)
            return button
        }
        stack.frame = NSRect(x: 0, y: 0, width: 460, height: CGFloat(max(1, buttons.count)) * 26)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let selected = zip(candidates, buttons).compactMap { pane, button in
            button.state == .on ? pane : nil
        }
        guard selected.count >= 2, Set(selected.map(\.kind)).count >= 2 else {
            NSAlert(error: RelayUIError.message(
                "Independent comparison needs at least two selected panes from different vendors."
            )).runModal()
            return nil
        }
        return selected
    }

    private func appendContextPackParts(_ parts: [ContextPackPart], draftID: String) throws {
        guard !parts.isEmpty else { throw ContextPackError.emptyPart }
        guard var draft = contextPackDraft, draft.id == draftID, let contextPackBuilder else {
            throw RelayUIError.message("That context pack was replaced while its source was being captured.")
        }
        draft.pack.parts.append(contentsOf: parts)
        let rendered = try contextPackBuilder.render(draft.pack)
        draft.renderedByteCount = rendered.utf8.count
        draft.isValid = true
        contextPackDraft = draft
    }

    private func captureTrustedContext(
        _ request: AgentContextTrustedCaptureRequest,
        draftID: String
    ) throws {
        guard let relayClient else {
            throw RelayUIError.message(
                "The persistent core is unavailable, so Parley cannot establish trusted capture provenance."
            )
        }
        try appendTrustedContextResponse(
            relayClient.captureTrustedContext(request),
            draftID: draftID
        )
    }

    private func appendTrustedContextResponse(
        _ response: RelayTextResponse,
        draftID: String
    ) throws {
        guard (200..<300).contains(response.status) else {
            throw RelayUIError.message(response.text)
        }
        let captured = try JSONDecoder().decode(
            AgentContextTrustedCaptureResponse.self,
            from: Data(response.text.utf8)
        )
        guard !captured.parts.isEmpty else {
            throw RelayUIError.message("The persistent core captured no context sources.")
        }
        guard var draft = contextPackDraft, draft.id == draftID else {
            throw RelayUIError.message("That context pack was replaced while its source was being captured.")
        }
        // The core has already bounded and durably recorded these exact parts.
        // Keep an oversized local edit visible and unsendable instead of hiding
        // a successful capture merely because the person's draft diverged.
        draft.pack.parts.append(contentsOf: captured.parts)
        draft.reviewUpdatedAt = captured.reviewUpdatedAt
        updateContextPackMeasurement(&draft)
        contextPackDraft = draft
    }

    private func updateContextPackMeasurement(_ draft: inout ActiveContextPack) {
        guard let contextPackBuilder else {
            draft.renderedByteCount = 0
            draft.isValid = false
            return
        }
        let measurement = contextPackBuilder.measure(draft.pack)
        draft.renderedByteCount = measurement.renderedByteCount
        draft.isValid = measurement.isValid
    }

    private func chooseContextPane(candidates: [TmuxPane]) -> TmuxPane? {
        guard !candidates.isEmpty else {
            NSAlert(error: RelayUIError.message("There is no running pane whose visible screen can be captured.")).runModal()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "Capture which visible pane?"
        alert.informativeText = "Parley captures only the pane's current visible screen. Hidden scrollback and other panes are not included."
        alert.addButton(withTitle: "Capture Visible Screen")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        picker.addItems(withTitles: candidates.map {
            let workspace = $0.workspaceName.map { " · \($0)" } ?? ""
            return "\($0.displayName) · \($0.kind.label)\(workspace) (\($0.id))"
        })
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return candidates[max(0, picker.indexOfSelectedItem)]
    }

    private func chooseContextTarget(candidates: [TmuxPane], preferredPaneID: String? = nil) -> TmuxPane? {
        guard !candidates.isEmpty else {
            NSAlert(error: RelayUIError.message("Open a ready pane from another vendor before sending this context pack.")).runModal()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "Ask which vendor with this context?"
        alert.informativeText = "The exact pack visible behind this dialog will be submitted through Parley's attributed Ask path."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 460, height: 28))
        picker.addItems(withTitles: candidates.map {
            let workspace = $0.workspaceName.map { " · \($0)" } ?? ""
            return "\($0.displayName) · \($0.kind.label)\(workspace) (\($0.id))"
        })
        if let preferredPaneID,
           let preferredIndex = candidates.firstIndex(where: { $0.id == preferredPaneID }) {
            picker.selectItem(at: preferredIndex)
        }
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return candidates[max(0, picker.indexOfSelectedItem)]
    }

    private func confirmContextSend(title: String, detail: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func acknowledgeVisibleComparisonResults() {
        guard askManyComparisonPresented,
              let answers = askManyComparisonRun?.response?.bundle.answers,
              let relayClient else { return }
        let handoffIDs = answers.compactMap(\.handoffID)
        guard !handoffIDs.isEmpty else { return }
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                for handoffID in handoffIDs {
                    _ = try? relayClient.markHandoffRead(handoffID)
                }
            }.value
            try? self?.refresh()
        }
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

    func setRole(_ pane: TmuxPane) {
        guard pane.kind.isAgent else { return }
        let alert = NSAlert()
        alert.messageText = "Set routing role"
        alert.informativeText = "Enter a role such as reviewer or tester. Agents address it as @reviewer or @tester; renaming the pane does not change it."
        let field = NSTextField(string: pane.role ?? "")
        field.placeholderString = "reviewer"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set Role")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var role = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role.hasPrefix("@") { role.removeFirst() }
        guard !role.isEmpty else { return }
        perform {
            guard let controller else { return }
            try controller.setPaneRole(role, paneID: pane.id, workspaceID: pane.windowID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func clearRole(_ pane: TmuxPane) {
        perform {
            guard let controller else { return }
            try controller.setPaneRole(nil, paneID: pane.id, workspaceID: pane.windowID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func mobilityDestinations(for pane: TmuxPane) -> [TmuxWorkspace] {
        workspaces.filter { $0.id != pane.windowID }
    }

    func movePane(_ pane: TmuxPane, to targetWorkspace: TmuxWorkspace) {
        perform {
            guard let controller else { return }
            try refresh()
            guard let currentPane = panes.first(where: { $0.id == pane.id }) else {
                throw ParleyTmuxError.paneNotFound(pane.id)
            }
            guard let currentTarget = workspaces.first(where: { $0.id == targetWorkspace.id }) else {
                throw ParleyTmuxError.workspaceNotFound(targetWorkspace.id)
            }
            let activeCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            let assessment = PaneMobilityPolicy.assess(
                action: .move,
                pane: currentPane,
                targetWorkspaceID: currentTarget.id,
                panes: panes,
                activeHandoffCount: activeCount
            )
            guard assessment.isAllowed else {
                showPaneMobilityRefusal(
                    pane: currentPane,
                    action: .move,
                    assessment: assessment
                )
                return
            }

            let preservedState: String
            if currentPane.isDead {
                preservedState = "Its exited state and final scrollback stay intact."
            } else if currentPane.kind.isAgent && !currentPane.isStarted {
                preservedState = "It remains a stopped placeholder with no vendor session."
            } else if currentPane.kind.isAgent {
                preservedState = "Its running process and vendor session stay intact."
            } else {
                preservedState = "Its running shell process stays intact."
            }
            let alert = NSAlert()
            alert.messageText = "Move \(currentPane.displayName) to \(currentTarget.name)?"
            alert.informativeText = "Parley will transfer the exact tmux pane. \(preservedState) Its pane id, terminal state and folder (\(currentPane.cwd)) are unchanged. The target workspace’s \(currentTarget.automationPolicy.label) automation policy applies after the move. The source workspace remains open."
            alert.alertStyle = .warning
            let affectedWorkspaces = [
                workspaces.first(where: { $0.id == currentPane.windowID }),
                currentTarget,
            ].compactMap { $0 }
            attachWorkspaceSafetySummaries(
                affectedWorkspaces.map { workspaceSafetySummary(for: $0) },
                to: alert
            )
            alert.addButton(withTitle: "Move Pane")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // The modal may have been open while relay state changed. Query the
            // core again and let TmuxController repeat every structural check
            // against a fresh pane list immediately before join-pane.
            let finalActiveCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            _ = try controller.movePane(
                currentPane.id,
                toWorkspaceID: currentTarget.id,
                direction: .horizontal,
                activeHandoffCount: finalActiveCount
            )
            try refresh()
            terminalHandle.focus()
        }
    }

    func clonePaneConfiguration(_ pane: TmuxPane, to targetWorkspace: TmuxWorkspace) {
        perform {
            guard let controller else { return }
            try refresh()
            guard let currentPane = panes.first(where: { $0.id == pane.id }) else {
                throw ParleyTmuxError.paneNotFound(pane.id)
            }
            guard let currentTarget = workspaces.first(where: { $0.id == targetWorkspace.id }) else {
                throw ParleyTmuxError.workspaceNotFound(targetWorkspace.id)
            }
            let activeCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            let assessment = PaneMobilityPolicy.assess(
                action: .clone,
                pane: currentPane,
                targetWorkspaceID: currentTarget.id,
                panes: panes,
                activeHandoffCount: activeCount
            )
            guard assessment.isAllowed else {
                showPaneMobilityRefusal(
                    pane: currentPane,
                    action: .clone,
                    assessment: assessment
                )
                return
            }

            let activeNote = activeCount > 0
                ? " Its \(activeCount) active \(activeCount == 1 ? "handoff remains" : "handoffs remain") with the source pane."
                : ""
            let processNote = currentPane.kind.isAgent
                ? "The new agent pane stays stopped with no vendor session, pane credential or protocol context until you choose Start."
                : "The new shell starts normally."
            let alert = NSAlert()
            alert.messageText = "Clone \(currentPane.displayName) into \(currentTarget.name)?"
            alert.informativeText = "The source process is unchanged. Parley copies only the visible configuration: vendor, name, folder (\(currentPane.cwd)), permission profile, routing role and Workspace Lead stamp. \(processNote)\(activeNote)"
            alert.addButton(withTitle: "Clone Configuration")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let finalActiveCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            _ = try controller.clonePaneConfiguration(
                currentPane.id,
                toWorkspaceID: currentTarget.id,
                direction: .horizontal,
                activeHandoffCount: finalActiveCount
            )
            try refresh()
            terminalHandle.focus()
        }
    }

    private func verifiedActiveHandoffCount(for pane: TmuxPane, required: Bool) throws -> Int {
        let history: [RelayHandoff]
        if let relayClient {
            history = try relayClient.handoffs(limit: 500)
        } else if required && pane.kind.isAgent {
            throw RelayUIError.message(
                "Parley cannot verify this agent’s active handoffs while the core service is unavailable. Restore the core connection before moving or cloning it."
            )
        } else {
            history = handoffs
        }
        return history.filter {
            ($0.sourcePaneID == pane.id || $0.targetPaneID == pane.id)
                && Self.isActiveMobilityHandoffState($0.state)
        }.count
    }

    private static func isActiveMobilityHandoffState(_ state: RelayHandoffState) -> Bool {
        switch state {
        case .created, .delivered, .waiting, .answered: true
        case .completed, .cancelled, .failed, .interrupted: false
        }
    }

    private func showPaneMobilityRefusal(
        pane: TmuxPane,
        action: PaneMobilityAction,
        assessment: PaneMobilityAssessment
    ) {
        let alert = NSAlert()
        alert.messageText = "\(action == .move ? "Move" : "Clone") unavailable for \(pane.displayName)"
        alert.informativeText = assessment.refusalText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func restart(_ pane: TmuxPane) {
        let alert = NSAlert()
        alert.messageText = "Restart \(pane.displayName)?"
        alert.informativeText = "The current process in this pane will be stopped and relaunched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if pane.kind.isAgent {
            panePermissionRequest = PanePermissionRequest(
                kind: pane.kind,
                folder: pane.cwd,
                action: .restart(pane.id),
                existingSelection: pane.permissionSelection
            )
            return
        }
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
        guard pane.kind.isAgent else { return }
        panePermissionRequest = PanePermissionRequest(
            kind: pane.kind,
            folder: pane.cwd,
            action: .start(pane.id),
            existingSelection: pane.permissionSelection
        )
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
            _ = try openWorkspace(folder: folder)
        }
    }

    func openExternalWorkspace(_ request: ExternalWorkspaceOpenRequest) {
        // External authority ends at one validated local folder. The ordinary
        // workspace path may focus an existing tmux window or create its shell;
        // it never starts an agent pane or submits terminal input.
        perform { _ = try openWorkspace(folder: request.folder) }
    }

    @discardableResult
    func openExternalNavigation(_ request: ExternalNavigationRequest) -> Bool {
        switch request {
        case let .pane(paneID):
            perform {
                guard let controller,
                      let pane = panes.first(where: { $0.id == paneID }) else {
                    throw RelayUIError.message("That Parley pane is no longer open.")
                }
                if activeWorkspace?.id != pane.windowID {
                    try controller.selectWorkspace(pane.windowID)
                }
                try controller.selectPane(pane.id)
                try refresh()
                terminalHandle.focus()
            }
            return false
        case let .handoff(handoffID):
            refreshStatusCenterQuietly()
            let history = statusHandoffs.isEmpty ? handoffs : statusHandoffs
            guard history.contains(where: { $0.id == handoffID }) else {
                NSAlert(error: RelayUIError.message("That Parley handoff is no longer in the local Status Center record.")).runModal()
                return false
            }
            requestedStatusHandoffID = handoffID
            return true
        }
    }

    func consumeRequestedStatusHandoffID() {
        requestedStatusHandoffID = nil
    }

    func importExternalContext(file: URL) {
        perform {
            guard let contextPackBuilder else {
                throw RelayUIError.message("Context capture is unavailable while Parley is starting.")
            }
            let imported = try ExternalContextImport.consume(
                file: file,
                applicationDirectory: applicationDirectory,
                builder: contextPackBuilder
            )
            let workspace = try openWorkspace(folder: imported.folder)
            let candidates = panes.filter {
                $0.windowID == workspace.id
                    && $0.kind.isAgent
                    && $0.isStarted
                    && !$0.isDead
                    && $0.relayEnabled
                    && $0.hasCurrentProtocol
            }
            guard let source = candidates.first(where: \.isActive) ?? candidates.first else {
                throw RelayUIError.message(
                    "Parley opened this workspace, but it has no ready agent pane. Start the pane you want to send from, then run the VS Code command again. Nothing was submitted."
                )
            }
            if let existing = contextPackDraft, !existing.pack.parts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Replace the current context pack?"
                alert.informativeText = "VS Code staged \(imported.parts.count) explicit source\(imported.parts.count == 1 ? "" : "s"). Replacing the current local draft cannot be undone; nothing has been sent."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open VS Code Context")
                alert.addButton(withTitle: "Keep Current Draft")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            var draft = ActiveContextPack(
                id: UUID().uuidString.lowercased(),
                sourcePaneID: source.id,
                sourcePaneKind: source.kind,
                sourcePaneName: source.displayName,
                sourceFolder: imported.folder,
                pack: ContextPack(
                    name: "\(source.displayName) · VS Code context",
                    parts: imported.parts
                ),
                reviewID: nil,
                reviewState: nil,
                requestedTargetPaneID: nil,
                reviewUpdatedAt: nil
            )
            updateContextPackMeasurement(&draft)
            contextPackDraft = draft
            contextPackPresented = true
        }
    }

    @discardableResult
    private func openWorkspace(folder: String) throws -> TmuxWorkspace {
        guard let controller else {
            throw RelayUIError.message("Parley cannot open a workspace while its tmux connection is unavailable.")
        }
        let standardized = URL(fileURLWithPath: folder).standardizedFileURL.path
        let selectedID: String
        if let existing = workspaces.first(where: { $0.defaultFolder == standardized }) {
            try controller.selectWorkspace(existing.id)
            selectedID = existing.id
        } else {
            let created = try controller.createWorkspace(folder: standardized)
            selectedID = created.id
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
        guard let selected = workspaces.first(where: { $0.id == selectedID }) else {
            throw RelayUIError.message("Parley opened the workspace but could not reconcile its live tmux window.")
        }
        return selected
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
        alert.informativeText = "This removes \(paneCount) pane\(paneCount == 1 ? "" : "s") and ends every process still running in them. The workspace cannot be recovered from Parley."
        alert.alertStyle = .warning
        attachWorkspaceSafetySummaries([workspaceSafetySummary(for: workspace)], to: alert)
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

    func saveActiveWorkspaceAsTeamTemplate() {
        guard let workspace = activeWorkspace else { return }
        let alert = NSAlert()
        alert.messageText = "Save team template"
        alert.informativeText = "Saves pane vendors, names, roles, permission profiles, lead, automation policy and layout. Repository paths, permission roots, sessions and live ids are not stored."
        let field = NSTextField(string: workspace.name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Team")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if teamTemplates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let overwrite = NSAlert()
            overwrite.messageText = "Replace team template \(name)?"
            overwrite.informativeText = "The previous portable definition will be replaced. Running panes are unchanged."
            overwrite.alertStyle = .warning
            overwrite.addButton(withTitle: "Replace")
            overwrite.addButton(withTitle: "Cancel")
            guard overwrite.runModal() == .alertFirstButtonReturn else { return }
        }

        perform {
            guard let controller else { return }
            let captured = try controller.captureWorkspaceLayout(workspaceID: workspace.id)
            try teamTemplateStore.save(try TeamTemplate.capturing(captured, name: name))
            teamTemplates = try teamTemplateStore.templates()
            terminalHandle.focus()
        }
    }

    func apply(_ template: TeamTemplate) {
        let panel = NSOpenPanel()
        panel.title = "Apply \(template.name) to a folder"
        panel.prompt = "Create Team Workspace"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.standardizedFileURL.path
        let baseName = url.lastPathComponent.isEmpty ? template.name : url.lastPathComponent
        let workspaceName = availableWorkspaceName(baseName)

        perform {
            guard let controller else { return }
            let layout = try template.workspaceLayout(folder: folder, workspaceName: workspaceName)
            let restored = try controller.restoreWorkspaceLayout(layout)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceRestored,
                workspaceID: restored.id,
                workspaceName: restored.name,
                detail: "Applied team template \(template.name); agent panes left stopped."
            ))
            rememberFolder(folder)
            try refresh()
            terminalHandle.focus()
        }
    }

    func delete(_ template: TeamTemplate) {
        let alert = NSAlert()
        alert.messageText = "Delete team template \(template.name)?"
        alert.informativeText = "Running workspaces and panes are unchanged."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Team")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try teamTemplateStore.delete(named: template.name)
            teamTemplates = try teamTemplateStore.templates()
            terminalHandle.focus()
        }
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
            let alert = NSAlert()
            alert.messageText = "Open \(layout.name) over \(workspace.name)?"
            alert.informativeText = "This removes \(paneCount) current pane\(paneCount == 1 ? "" : "s") and ends every process still running in them. Shell panes in the saved layout start automatically; agent panes remain stopped until you choose Start."
            alert.alertStyle = .warning
            attachWorkspaceSafetySummaries([workspaceSafetySummary(for: workspace)], to: alert)
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
        preferences.set(recentFolders, forKey: Self.recentFoldersKey)
    }

    private func availableWorkspaceName(_ proposed: String) -> String {
        if !workspaces.contains(where: { $0.name.caseInsensitiveCompare(proposed) == .orderedSame }) {
            return proposed
        }
        var suffix = 2
        while workspaces.contains(where: {
            $0.name.caseInsensitiveCompare("\(proposed) \(suffix)") == .orderedSame
        }) {
            suffix += 1
        }
        return "\(proposed) \(suffix)"
    }

    private func saveNotificationWorkspaces() {
        preferences.set(notificationWorkspaceNames.sorted(), forKey: Self.notificationWorkspacesKey)
    }

    private func saveDismissedHandoffs() {
        preferences.set(dismissedHandoffIDs.sorted(), forKey: Self.dismissedHandoffsKey)
    }

    private func saveWorkspaceContinuity() {
        guard let data = try? JSONEncoder().encode(workspaceContinuity) else { return }
        preferences.set(data, forKey: Self.workspaceContinuityKey)
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

    private func editSupervisedWorkflowText(
        title: String,
        message: String,
        text: String,
        action: String,
        insertVisible: @escaping () throws -> String
    ) -> String? {
        var current = ContextPackText.normalize(text)
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = "\(message) Maximum \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes; formatting is preserved."
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Cancel")

            let accessory = RelayEditorAccessory(
                text: current,
                insertVisible: insertVisible,
                normalizeInserted: ContextPackText.normalize
            )
            alert.accessoryView = accessory
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }

            current = ContextPackText.normalize(accessory.text)
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSAlert(error: RelayUIError.message("The supervised workflow text cannot be empty.")).runModal()
                continue
            }
            if current.utf8.count > ContextPackBuilder.defaultMaximumRenderedBytes {
                NSAlert(error: RelayUIError.message(
                    "The supervised workflow text is \(current.utf8.count) bytes. Reduce it to \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes before dispatch."
                )).runModal()
                continue
            }
            return current
        }
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

    private func attachWorkspaceSafetySummaries(
        _ summaries: [WorkspaceSafetySummary],
        to alert: NSAlert
    ) {
        guard !summaries.isEmpty else { return }
        let text = summaries.map(\.detailText).joined(separator: "\n\n")
        let lineCount = text.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        let height = min(320, max(170, CGFloat(lineCount) * 16 + 20))
        let frame = NSRect(x: 0, y: 0, width: 560, height: height)

        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder

        let textView = NSTextView(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 11)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel("Workspace safety summary")
        scroll.documentView = textView
        alert.accessoryView = scroll
    }

    private static func argument(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func hasArgument(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(name)
    }

    private static var isBundledApplication: Bool {
        Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && Bundle.main.bundleIdentifier == ParleyRuntime.productionBundleIdentifier
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
    private let normalizeInserted: (String) -> String

    var text: String { editor.string }

    init(
        text: String,
        insertVisible: @escaping () throws -> String,
        normalizeInserted: @escaping (String) -> String = RelayText.clean
    ) {
        self.insertVisible = insertVisible
        self.normalizeInserted = normalizeInserted
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
            let visible = normalizeInserted(try insertVisible())
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
