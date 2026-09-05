import AppKit
import Foundation
import GhosttyTerminal
import ParleyCore
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class TerminalHandle: ObservableObject {
    private let selectedTextResolver: () -> String?
    private let focusAction: () -> Void
    private let clearSelectionAction: () -> Void

    init(
        selectedText: @escaping () -> String?,
        focus: @escaping () -> Void,
        clearSelection: @escaping () -> Void
    ) {
        selectedTextResolver = selectedText
        focusAction = focus
        clearSelectionAction = clearSelection
    }

    var selectedText: String? {
        guard let selected = selectedTextResolver(),
              !selected.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return selected
    }

    func focus() { focusAction() }
    func clearSelection() { clearSelectionAction() }
}

private enum WorkspaceOpenChoice {
    case existing(String)
    case create
}

struct WorkspaceAskGroup: Identifiable {
    let workspace: WorkbenchWorkspace
    let panes: [WorkbenchPane]

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
    let conclusions: String
    let rationale: String
    let confidence: String
    let openQuestions: String

    var id: String { workspaceID }
}

enum PanePermissionAction: Equatable {
    case create(SplitDirection)
    case restart(String)
    case resume(paneID: String, replacingRunningProcess: Bool)
    case start(String)
    case folderAccess(String)
}

struct PanePermissionRequest: Identifiable, Equatable {
    let id = UUID()
    let kind: PaneKind
    let folder: String
    let workspaceName: String
    let workspaceFolders: [String]
    let action: PanePermissionAction
    let existingSelection: PermissionProfileSelection?

    var actionLabel: String {
        switch action {
        case .create: "Start Pane"
        case .restart: "Restart Pane"
        case .resume: VendorResumeAdapter.plan(for: kind)?.confirmationLabel ?? "Resume"
        case .start: "Start Pane"
        case .folderAccess: "Restart with Access"
        }
    }

    var isFolderAccessReview: Bool {
        if case .folderAccess = action { true } else { false }
    }

    var resumeDetail: String? {
        guard case .resume = action else { return nil }
        return VendorResumeAdapter.plan(for: kind)?.detail
    }
}

struct HandoffComposerDraft: Identifiable, Equatable {
    let id: UUID
    let sourcePaneID: String
    let sourceName: String
    let sourceKind: PaneKind
    let targetPaneID: String
    let targetName: String
    let targetKind: PaneKind
    let inReplyToHandoffID: String?
    let relationship: RelayHandoffRelationship?
    var text: String
    var includesTerminalSelection: Bool

    init(
        sourcePaneID: String,
        sourceName: String,
        sourceKind: PaneKind,
        targetPaneID: String,
        targetName: String,
        targetKind: PaneKind,
        text: String,
        includesTerminalSelection: Bool,
        inReplyToHandoffID: String? = nil,
        relationship: RelayHandoffRelationship? = nil
    ) {
        id = UUID()
        self.sourcePaneID = sourcePaneID
        self.sourceName = sourceName
        self.sourceKind = sourceKind
        self.targetPaneID = targetPaneID
        self.targetName = targetName
        self.targetKind = targetKind
        self.inReplyToHandoffID = inReplyToHandoffID
        self.relationship = relationship
        self.text = text
        self.includesTerminalSelection = includesTerminalSelection
    }
}

struct PaletteCommand: Identifiable, Sendable {
    enum Action: Sendable {
        case newWorkspace
        case openWorkspace
        case openStatusCenter
        case terminalAppearance
        case selectWorkspace(WorkbenchWorkspace)
        case selectPane(WorkbenchPane)
        case ask(WorkbenchPane)
        case activity(RelayHandoff)
    }

    let item: CommandPaletteItem
    let action: Action

    var id: String { item.id }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var panes: [WorkbenchPane] = []
    @Published private(set) var workspaces: [WorkbenchWorkspace] = []
    @Published private(set) var commandRuns: [ReviewedCommandRun] = []
    @Published private(set) var commandRunGrants: [ReviewedCommandGrant] = []
    @Published private(set) var commandRunError: String?
    @Published private(set) var commandRunsPresented = false
    @Published private(set) var selectedCommandRunID: String?
    private var commandRunAttention = ReviewedCommandRunAttention()
    private var pendingCommandRunIDs: [String] {
        commandRuns.filter { $0.state == .pending }.map(\.id)
    }
    @Published private(set) var consultations: [RelayConsultation] = []
    @Published private(set) var handoffs: [RelayHandoff] = []
    @Published private(set) var unreadHandoffs: [RelayHandoff] = []
    @Published private(set) var statusHandoffs: [RelayHandoff] = []
    @Published private(set) var statusActivityEvents: [RelayActivityEvent] = []
    @Published private(set) var reviewedBusyDrafts: [ReviewedBusyDraft] = []
    @Published private(set) var controller: WorkbenchController?
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
    @Published private(set) var terminalAvailable = false
    @Published private(set) var coreError: String?
    @Published private(set) var historyPersistenceError: String?
    @Published private(set) var terminalError: String?
    @Published private(set) var notificationWorkspaceNames: Set<String> = []
    @Published private(set) var dismissedHandoffIDs: Set<String> = []
    @Published private(set) var runtimeReadiness: RuntimeReadinessSnapshot?
    @Published private(set) var runtimeReadinessChecking = false
    @Published private(set) var vendorCompatibility: VendorCompatibilitySnapshot?
    @Published private(set) var vendorCompatibilityChecking = false
    @Published private(set) var releaseChannel: UpdateChannel = .stable
    @Published private(set) var releaseCheck: ReleaseCheckResult?
    @Published private(set) var releaseChecking = false
    @Published private(set) var releaseDownloading = false
    @Published private(set) var releaseLifecycleMessage: String?
    @Published private(set) var swiftPMCompatibilityEnabled = false
    @Published private(set) var automaticUpdatesAvailable = false
    @Published private(set) var automaticUpdateChecksEnabled = false
    @Published private(set) var automaticUpdateCanCheck = false
    @Published private(set) var automaticUpdateDetail = "Automatic updates require an installed, notarized Production build."
    @Published private(set) var selectedSettingsSection = ApplicationSettingsSection.general
    @Published private(set) var settingsOpenRequestID: UUID?
    @Published private(set) var betaFeedbackBundle: BetaFeedbackBundle?
    @Published private(set) var betaFeedbackExporting = false
    @Published private(set) var diagnosticsExporting = false
    @Published private(set) var repeatingAskHandoffID: String?
    @Published private(set) var sendingReviewedBusyDraftID: String?
    @Published private(set) var submittingHandoffComposer = false
    /// One pending pane choice presented as a native sheet instead of a
    /// picker inside an alert. Resolving it continues the original flow.
    @Published var paneChoiceRequest: PaneChoiceRequest?
    @Published private(set) var historyRetentionPolicy: CollaborationHistoryRetentionPolicy = .defaultPolicy
    @Published private(set) var terminalFontPreference = TerminalFontPreference.ghosttyDefault
    @Published private(set) var terminalAppearanceImport: GhosttyAppearanceImport?
    @Published private(set) var taskManagerSnapshot: TaskManagerSnapshot?
    @Published private(set) var paneListeningPortSnapshot = PaneListeningPortSnapshot.empty
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
    @Published var releaseLifecyclePresented = false
    @Published var betaFeedbackPresented = false
    @Published var focusCanvasPaneID: String?
    @Published var collaborationDockVisible = true
    @Published var handoffComposerDraft: HandoffComposerDraft?
    @Published private(set) var selectedSupervisedWorkflowID: String?
    @Published private(set) var requestedHelpTopicID: String?
    @Published private(set) var requestedStatusHandoffID: String?
    @Published var startupError: String?
    @Published private(set) var startupRequiresQuit = false

    let runtime: ParleyRuntime
    let ghosttyRegistry = GhosttyPaneRegistry()
    lazy var terminalHandle = TerminalHandle(
        selectedText: { [weak self] in self?.ghosttyRegistry.selectedText() },
        focus: { [weak self] in _ = self?.ghosttyRegistry.focusSelected() },
        clearSelection: { [weak self] in
            _ = self?.ghosttyRegistry.selectedView?.performBindingAction("clear_selection")
        }
    )
    private let fallbackFolder: String
    private let applicationDirectory: URL
    private let preferences: UserDefaults
    private let runtimeLease: RuntimeUILease?
    private let layoutStore: SavedWorkspaceLayoutStore
    private let workspaceRegistry: WorkspaceRegistry
    private let teamTemplateStore: TeamTemplateStore
    private let recipeStore: HandoffRecipeStore
    private let supervisedWorkflowStore: SupervisedWorkflowStore
    private let workspaceBriefStore: WorkspaceBriefStore
    private let pinnedContextSnippetStore: PinnedContextSnippetStore
    private let permissionProfileStore: PermissionProfileStore
    private var workspaceContinuity = WorkspaceContinuityState()
    private let projectContextResolver = GitProjectContextResolver()
    private let paneListeningPortResolver = PaneListeningPortResolver()
    private let worktreeResolver = GitWorktreeResolver()
    private var projectContextRefreshTask: Task<Void, Never>?
    private var projectContextFolders: Set<String> = []
    private var lastProjectContextRefresh = Date.distantPast
    private var paneListeningPortRefreshState = PaneListeningPortRefreshState()
    private var worktreeRefreshTask: Task<Void, Never>?
    private var worktreePaneFolders: [String: String] = [:]
    private var lastWorktreeRefresh = Date.distantPast
    private var worktreeDiscoveryTask: Task<Void, Never>?
    private var worktreeDiscoveryID: UUID?
    private var automaticOrchestrationTasks: [String: Task<Void, Never>] = [:]
    private var relayClient: RelayCoreClient?
    private var residentCore: AppResidentCoordinationCore?
    private var reviewDraftBuilder: ReviewDraftBuilder?
    private var contextPackBuilder: ContextPackBuilder?
    private let notificationEpoch = Date()
    private var observedNotificationEventIDs: Set<String> = []
    private var runtimeReadinessTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var automaticUpdater: ParleyAutomaticUpdater?
    private var preparedForUninstall = false
    private var lastExternalAttentionSnapshot: ExternalAttentionSnapshot?
    private var lastExternalAttentionPublishedAt = Date.distantPast
    private var lastExternalEditorCapabilitiesPublishedAt = Date.distantPast
    private var periodicRefreshTimer: Timer?
    private let taskManagerSampler = TaskManagerSampler()
    private var quickRelayTargetHistory = QuickRelayTargetHistory()
    private var attentionCycleCursorID: String?
    private static let recentFoldersKey = "parley.recentWorkspaceFolders"
    private static let workspaceIdentityRecentResetKey = "parley.workspaceIdentityRecentResetV1"
    private static let workspaceContinuityKey = "parley.workspaceContinuity"
    private static let notificationWorkspacesKey = "parley.notificationWorkspaces"
    private static let dismissedHandoffsKey = "parley.dismissedStatusHandoffs"
    private static let firstRunCompletedKey = "parley.firstRunReadinessCompleted"
    private static let vendorCompatibilityKey = "parley.vendorCompatibility"
    private static let releaseChannelKey = "parley.releaseChannel"
    private static let permissionProfileKeyPrefix = "parley.permissionProfile"
    private static let collaborationDockVisibleKey = "parley.collaborationDockVisible"
    private static let swiftPMCompatibilityKey = "parley.swiftPMCompatibilityEnabled"
    private static let terminalFontPreferenceKey = "parley.terminalFontPreference"
    private static let terminalAppearanceImportKey = "parley.terminalAppearanceImport"
    private static let projectContextRefreshInterval: TimeInterval = 5
    private static let worktreeRefreshInterval: TimeInterval = 15
    private static let externalAttentionHeartbeatInterval: TimeInterval = 10
    private static let periodicRefreshInterval: TimeInterval = 1

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
        if let data = preferences.data(forKey: Self.terminalFontPreferenceKey) {
            if let stored = try? JSONDecoder().decode(TerminalFontPreference.self, from: data) {
                terminalFontPreference = stored
            } else {
                preferences.removeObject(forKey: Self.terminalFontPreferenceKey)
            }
        }
        if let data = preferences.data(forKey: Self.terminalAppearanceImportKey) {
            if let stored = try? JSONDecoder().decode(GhosttyAppearanceImport.self, from: data) {
                terminalAppearanceImport = stored
            } else {
                preferences.removeObject(forKey: Self.terminalAppearanceImportKey)
            }
        }
        if preferences.object(forKey: Self.collaborationDockVisibleKey) != nil {
            collaborationDockVisible = preferences.bool(forKey: Self.collaborationDockVisibleKey)
        }
        idleAgentReaperEnabled = preferences.bool(forKey: Self.idleAgentReaperKey)
        swiftPMCompatibilityEnabled = preferences.bool(forKey: Self.swiftPMCompatibilityKey)
        layoutStore = SavedWorkspaceLayoutStore(
            file: applicationDirectory.appendingPathComponent("workspace-layouts.json")
        )
        workspaceRegistry = WorkspaceRegistry(
            file: applicationDirectory.appendingPathComponent("workspace-registry.json")
        )
        let workspaceRecords = (try? workspaceRegistry.records()) ?? []
        nativeLayouts = workspaceRecords.reduce(into: [:]) { $0[$1.workspaceID] = $1.layout }
        nativeSplitFractions = workspaceRecords.reduce(into: [:]) {
            $0[$1.workspaceID] = $1.splitFractions
        }
        teamTemplateStore = TeamTemplateStore(
            file: applicationDirectory.appendingPathComponent("team-templates.json")
        )
        recipeStore = HandoffRecipeStore(
            file: applicationDirectory.appendingPathComponent("handoff-recipes.json")
        )
        supervisedWorkflowStore = SupervisedWorkflowStore(
            file: applicationDirectory.appendingPathComponent("supervised-workflows.json")
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
        let restoredWorkflows = (try? supervisedWorkflowStore.runs()) ?? []
        for run in restoredWorkflows where run.mode == .automatic && !run.phase.isTerminal {
            _ = try? supervisedWorkflowStore.interrupt(
                id: run.id,
                detail: "Auto orchestration stopped because the previous Parley application process ended. No pane or vendor session is assumed to have survived."
            )
        }
        supervisedWorkflowRuns = (try? supervisedWorkflowStore.runs()) ?? restoredWorkflows
        workspaceBriefs = (try? workspaceBriefStore.briefs()) ?? []
        pinnedContextSnippets = (try? pinnedContextSnippetStore.snippets()) ?? []
        permissionProfiles = (try? permissionProfileStore.profiles())
            ?? PermissionProfileDefinition.builtIns
        do {
            try ghosttyRegistry.applyTerminalAppearance(
                font: terminalFontPreference,
                imported: terminalAppearanceImport
            )
        } catch {
            terminalFontPreference = .ghosttyDefault
            terminalAppearanceImport = nil
            preferences.removeObject(forKey: Self.terminalFontPreferenceKey)
            preferences.removeObject(forKey: Self.terminalAppearanceImportKey)
            try? ghosttyRegistry.applyTerminalFont(.ghosttyDefault)
        }
        if runtime.mode == .production {
            UserDefaultsDomainMigration.copyMissing(
                keys: [
                    Self.recentFoldersKey,
                    Self.workspaceContinuityKey,
                    Self.notificationWorkspacesKey,
                    Self.dismissedHandoffsKey,
                    Self.vendorCompatibilityKey,
                    Self.releaseChannelKey,
                ],
                from: "parley-native",
                to: preferences
            )
        }
        if !preferences.bool(forKey: Self.workspaceIdentityRecentResetKey) {
            preferences.removeObject(forKey: Self.recentFoldersKey)
            preferences.set(true, forKey: Self.workspaceIdentityRecentResetKey)
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
        if let data = preferences.data(forKey: Self.vendorCompatibilityKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            vendorCompatibility = try? decoder.decode(VendorCompatibilitySnapshot.self, from: data)
        }
        releaseChannel = preferences.string(forKey: Self.releaseChannelKey)
            .flatMap(UpdateChannel.init(rawValue:))
            ?? .stable
        automaticUpdater = ParleyAutomaticUpdater(runtime: runtime)
        automaticUpdatesAvailable = automaticUpdater != nil
        if automaticUpdater != nil {
            automaticUpdateDetail = "Stable checks use Parley's signed feed. Downloads and installation always require a visible decision."
        } else if runtime.mode == .development {
            automaticUpdateDetail = "Development builds never attach to the Production update channel."
        }
        setupPresented = !preferences.bool(forKey: Self.firstRunCompletedKey)

        guard runtimeLease != nil, startupError == nil else {
            coreAvailable = false
            terminalAvailable = false
            terminalError = startupError
            return
        }

        do {
            let controller = try WorkbenchController(
                applicationDirectory: runtime.applicationDirectory,
                swiftPMCompatibilityEnabled: swiftPMCompatibilityEnabled
            )
            try controller.bootstrap(
                cwd: defaultFolder,
                createIfMissing: true
            )
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
                transportDirectory: agentTransportDirectory,
                runtimeMarker: runtime.visibleMarker
            )
            // Vendor CLIs may rebuild PATH after launch. Put a managed copy in
            // the user's existing stable command directory so an app-resident
            // pane can still reach the relay. The stable command is a runtime-neutral
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
                let core = try AppResidentCoordinationCore(
                    controller: controller,
                    credentials: credentials,
                    applicationDirectory: controller.applicationDirectory,
                    transportDirectory: agentTransportDirectory
                )
                residentCore = core
                relayClient = core.client
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
            terminalAvailable = true
            terminalError = nil
            reviewDraftBuilder = ReviewDraftBuilder(environment: controller.environment)
            contextPackBuilder = ContextPackBuilder(environment: controller.environment)
            workspaces = liveWorkspaces
            panes = livePanes
            ghosttyRegistry.bind(controller)
            ghosttyRegistry.select(paneID: livePanes.first(where: \.isActive)?.id)
            ghosttyRegistry.onPaneFocused = { [weak self] paneID in
                guard let self,
                      panes.first(where: { $0.id == paneID })?.isActive != true else { return }
                selectNativePane(paneID)
            }
            ghosttyRegistry.onPaneStateChanged = { [weak self] in
                try? self?.refresh()
            }
            controller.configureTerminalTransport(makeGhosttyTerminalTransport())
            reconcileNativeLayouts(workspaces: liveWorkspaces, panes: livePanes)
            savedLayouts = try layoutStore.layouts()
            rememberFolder(defaultFolder)
            scheduleProjectContextRefresh(force: true)
            schedulePaneListeningPortRefresh(force: true)
            scheduleWorktreeRefresh(force: true)
            publishExternalAttentionSnapshot(force: true)
        } catch {
            coreAvailable = false
            terminalAvailable = false
            terminalError = error.localizedDescription
            startupError = error.localizedDescription
        }
        refreshRuntimeReadiness()
        startPeriodicRefresh()
    }

    var activeWorkspace: WorkbenchWorkspace? { workspaces.first(where: \.isActive) }

    func dismissStartupError() {
        startupError = nil
        if startupRequiresQuit { NSApp.terminate(nil) }
    }

    var defaultFolder: String {
        activeWorkspace?.newPaneFolder
            ?? activePane?.cwd
            ?? activeWorkspace?.primaryAttachedFolder
            ?? fallbackFolder
    }

    var visiblePanes: [WorkbenchPane] {
        guard let workspaceID = activeWorkspace?.workspaceID else { return panes }
        return panes.filter { $0.workspaceID == workspaceID }
    }

    var activePane: WorkbenchPane? { visiblePanes.first(where: \.isActive) }

    /// One native leaf per retained Ghostty exec surface.
    struct NativePaneSurface: Identifiable, Equatable {
        let representativePaneID: String
        let containsActivePane: Bool
        var id: String { representativePaneID }
    }

    var nativePaneSurfaces: [NativePaneSurface] {
        let byID = Dictionary(uniqueKeysWithValues: visiblePanes.map { ($0.id, $0) })
        return WorkbenchIdentifierOrder.sorted(Array(byID.keys)).compactMap { paneID in
            guard let pane = byID[paneID] else { return nil }
            return NativePaneSurface(
                representativePaneID: pane.id,
                containsActivePane: pane.isActive
            )
        }
    }

    /// Native split trees per durable workspace id, loaded from the registry
    /// and persisted through it whenever the structure changes.
    @Published private var nativeLayouts: [String: NativeLayoutNode] = [:]
    @Published private var nativeSplitFractions: [String: [String: Double]] = [:]

    var nativeLayoutTree: NativeLayoutNode? {
        guard let workspace = activeWorkspace else { return nil }
        let leaves = nativePaneSurfaces.map(\.representativePaneID)
        return NativeLayoutNode.reconciled(nativeLayouts[workspace.workspaceID], with: leaves)
    }

    var layoutOrderedVisiblePanes: [WorkbenchPane] {
        let paneByID = Dictionary(uniqueKeysWithValues: visiblePanes.map { ($0.id, $0) })
        var ordered = (nativeLayoutTree?.leaves ?? []).compactMap { paneByID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: visiblePanes.filter { !orderedIDs.contains($0.id) })
        return ordered
    }

    func nativeSplitFraction(path: String) -> Double? {
        guard let workspaceID = activeWorkspace?.workspaceID else {
            return nil
        }
        return nativeSplitFractions[workspaceID]?[path]
    }

    func persistNativeSplitFraction(_ fraction: Double, path: String) {
        guard let workspaceID = activeWorkspace?.workspaceID,
              NativeSplitGeometry.isValidPath(path),
              fraction.isFinite else { return }
        var fractions = nativeSplitFractions[workspaceID] ?? [:]
        fractions[path] = min(max(fraction, 0.05), 0.95)
        nativeSplitFractions[workspaceID] = fractions
        try? workspaceRegistry.updateSplitFractions(
            workspaceID: workspaceID,
            fractions: fractions
        )
    }

    private func resetNativeSplitFractions(workspaceID: String) {
        guard nativeSplitFractions[workspaceID]?.isEmpty != true else { return }
        nativeSplitFractions[workspaceID] = [:]
        try? workspaceRegistry.updateSplitFractions(workspaceID: workspaceID, fractions: [:])
    }

    private func representativeLeaves(workspaceID: String, in allPanes: [WorkbenchPane]) -> [String] {
        WorkbenchIdentifierOrder.sorted(
            allPanes.filter { $0.workspaceID == workspaceID }.map(\.id)
        )
    }

    private func reconcileNativeLayouts(workspaces: [WorkbenchWorkspace], panes allPanes: [WorkbenchPane]) {
        for workspace in workspaces {
            let leaves = representativeLeaves(workspaceID: workspace.workspaceID, in: allPanes)
            let reconciled = NativeLayoutNode.reconciled(nativeLayouts[workspace.workspaceID], with: leaves)
            guard reconciled != nativeLayouts[workspace.workspaceID] else { continue }
            nativeLayouts[workspace.workspaceID] = reconciled
            try? workspaceRegistry.updateLayout(workspaceID: workspace.workspaceID, layout: reconciled)
            resetNativeSplitFractions(workspaceID: workspace.workspaceID)
        }
    }

    /// Records where a new own-window pane sits: split from its target in the
    /// requested direction. A failed insert falls back to reconciliation.
    private func recordNativeSplit(created: WorkbenchPane, target: WorkbenchPane?, direction: SplitDirection) {
        guard let target, created.id != target.id else { return }
        let workspaceID = created.workspaceID
        let targetLeaf = target.id
        let liveBefore = representativeLeaves(workspaceID: workspaceID, in: panes)
        let current = NativeLayoutNode.reconciled(nativeLayouts[workspaceID], with: liveBefore)
        let updated: NativeLayoutNode?
        if let current {
            updated = current.inserting(created.id, after: targetLeaf, direction: direction)
        } else {
            updated = .split(
                direction: direction,
                first: .leaf(targetLeaf),
                second: .leaf(created.id)
            )
        }
        guard let updated else { return }
        nativeLayouts[workspaceID] = updated
        try? workspaceRegistry.updateLayout(workspaceID: workspaceID, layout: updated)
        resetNativeSplitFractions(workspaceID: workspaceID)
    }

    func ghosttyView(paneID: String) throws -> AppTerminalView {
        try ghosttyRegistry.view(for: paneID)
    }

    func setGhosttyPaneVisible(_ visible: Bool, paneID: String) {
        ghosttyRegistry.setVisible(visible, paneID: paneID)
    }

    func focusNativeTerminalIfSelected(_ paneID: String, in window: NSWindow?) {
        guard activePane?.id == paneID else { return }
        _ = ghosttyRegistry.focusSelected(in: window)
    }

    func repairNativeTerminalFocus(for event: NSEvent) {
        guard event.type == .keyDown, let window = event.window else { return }
        _ = ghosttyRegistry.repairFocusIfNeeded(
            in: window,
            modifierFlags: event.modifierFlags
        )
    }

    private func makeGhosttyTerminalTransport() -> PaneTerminalTransport {
        PaneTerminalTransport(
            paste: { [weak self] paneID, text, submit in
                try Self.onMainActorSync {
                    guard let self else {
                        throw ParleyWorkbenchError.commandFailed("Parley is shutting down.")
                    }
                    try self.ghosttyRegistry.paste(text, into: paneID, submit: submit)
                }
            },
            interrupt: { [weak self] paneID in
                try Self.onMainActorSync {
                    guard let self else {
                        throw ParleyWorkbenchError.commandFailed("Parley is shutting down.")
                    }
                    try self.ghosttyRegistry.interrupt(paneID: paneID)
                }
            },
            captureSelectedText: { [weak self] paneID in
                try Self.onMainActorSync {
                    guard let self else {
                        throw ParleyWorkbenchError.commandFailed("Parley is shutting down.")
                    }
                    return try self.ghosttyRegistry.captureSelectedText(paneID: paneID)
                }
            },
            terminate: { [weak self] paneID in
                Self.onMainActorSync { self?.ghosttyRegistry.stop(paneID: paneID) }
            },
            terminateAll: { [weak self] in
                Self.onMainActorSync { self?.ghosttyRegistry.stopAll() }
            }
        )
    }

    private nonisolated static func onMainActorSync<T: Sendable>(
        _ operation: @escaping @MainActor () throws -> T
    ) rethrows -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try operation() }
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { try operation() }
        }
    }

    // MARK: Idle agent reaper (opt-in)

    func showSettings(_ section: ApplicationSettingsSection = .general) {
        selectedSettingsSection = section
        settingsOpenRequestID = UUID()
    }

    func selectSettingsSection(_ section: ApplicationSettingsSection) {
        selectedSettingsSection = section
    }

    func showTerminalFontSettings() {
        showSettings(.appearance)
    }

    func loadGhosttyAppearanceImport() throws -> GhosttyAppearanceImport {
        try ghosttyRegistry.loadGhosttyAppearanceImport()
    }

    func updateTerminalAppearance(
        family: String?,
        size: Double?,
        imported appearance: GhosttyAppearanceImport?
    ) throws {
        let preference = try TerminalFontPreference(family: family, size: size)
        try ghosttyRegistry.applyTerminalAppearance(font: preference, imported: appearance)
        if preference == .ghosttyDefault {
            preferences.removeObject(forKey: Self.terminalFontPreferenceKey)
        } else {
            preferences.set(
                try JSONEncoder().encode(preference),
                forKey: Self.terminalFontPreferenceKey
            )
        }
        if let appearance {
            preferences.set(
                try JSONEncoder().encode(appearance),
                forKey: Self.terminalAppearanceImportKey
            )
        } else {
            preferences.removeObject(forKey: Self.terminalAppearanceImportKey)
        }
        terminalFontPreference = preference
        terminalAppearanceImport = appearance
    }

    func updateTerminalFont(family: String?, size: Double?) throws {
        try updateTerminalAppearance(
            family: family,
            size: size,
            imported: terminalAppearanceImport
        )
    }

    func resetTerminalFont() throws {
        try updateTerminalAppearance(family: nil, size: nil, imported: nil)
    }

    @Published var idleAgentReaperEnabled = false {
        didSet {
            guard oldValue != idleAgentReaperEnabled else { return }
            preferences.set(idleAgentReaperEnabled, forKey: Self.idleAgentReaperKey)
        }
    }
    private static let idleAgentReaperKey = "ParleyIdleAgentReaper"
    private var lastReapSweep = Date.distantPast

    private func reapIdleAgentsIfEnabled(controller: WorkbenchController, panes: [WorkbenchPane]) {
        guard idleAgentReaperEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReapSweep) >= 60 else { return }
        lastReapSweep = now
        guard let stamps = try? controller.paneActivityTimestamps() else { return }
        for pane in panes {
            let collaborating = consultations.contains {
                $0.sourcePaneID == pane.id || $0.targetPaneID == pane.id
            } || activeDelegations.contains {
                $0.sourcePaneID == pane.id || $0.targetPaneID == pane.id
            } || awaitingAnswerCount(for: pane.id) > 0
            guard IdleAgentReaper.shouldReap(
                pane: pane,
                lastActivity: stamps[pane.id],
                now: now,
                hasLiveCollaboration: collaborating
            ) else { continue }
            do {
                try controller.stopPaneProcess(pane.id)
                try recordSuccessfulActivity(RelayActivityEventRequest(
                    kind: .paneReaped,
                    workspaceID: pane.workspaceID,
                    workspaceName: pane.workspaceName ?? pane.workspaceID,
                    paneID: pane.id,
                    paneName: pane.displayName,
                    paneKind: pane.kind,
                    detail: "Stopped after \(Int(IdleAgentReaper.defaultIdleInterval / 60)) idle minutes. Start revives the seat."
                ))
            } catch {
                // The seat is untouched on failure; the next sweep retries.
            }
        }
    }

    // MARK: Quit-time choice

    /// Returns true when quitting may proceed. An owned runtime always offers
    /// an explicit choice to detach or stop, even when every agent is dead.
    /// Closing the main window is handled by AppDelegate and only hides it.
    /// Full application termination is the deliberate lifetime boundary for
    /// every retained Ghostty exec surface.
    func resolveTermination() -> Bool {
        if preparedForUninstall { return true }
        guard RuntimeTerminationPolicy.shouldOfferChoice(
            runtime: runtime,
            controllerAvailable: controller != nil
        ), let controller else {
            residentCore?.stop()
            ghosttyRegistry.stopAll()
            removeExternalEditorCapabilities()
            return true
        }

        let runningAgents = panes.filter { $0.kind.isAgent && $0.isStarted && !$0.isDead }
        let livePanes = panes.filter { !$0.isDead }
        let alert = NSAlert()
        if !runningAgents.isEmpty {
            alert.messageText = "Quit and end \(runningAgents.count) agent\(runningAgents.count == 1 ? "" : "s")?"
        } else if !livePanes.isEmpty {
            alert.messageText = "Quit and end \(livePanes.count) pane\(livePanes.count == 1 ? "" : "s")?"
        } else {
            alert.messageText = "Quit Parley?"
        }
        alert.informativeText = "Closing the Parley window keeps these app-resident Ghostty panes running. Quitting the application ends their processes and the local coordination broker."
        alert.addButton(withTitle: "Quit Parley")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try interruptAutomaticOrchestrationForShutdown(
                    reason: "Auto orchestration stopped because the person quit Parley."
                )
                residentCore?.stop()
                try controller.shutdown()
                removeExternalEditorCapabilities()
                return true
            } catch {
                let failure = NSAlert()
                failure.alertStyle = .critical
                failure.messageText = "Parley could not stop everything"
                failure.informativeText = "\(error.localizedDescription)\n\nThe app will stay open so the runtime is not silently left behind."
                failure.addButton(withTitle: "OK")
                failure.runModal()
                return false
            }
        case .alertSecondButtonReturn:
            return false
        default:
            return false
        }
    }

    func showEnvironmentCheck() {
        setupPresented = true
        refreshRuntimeReadiness()
    }

    func refreshTaskManager() {
        let descriptors = taskManagerPaneDescriptors()
        taskManagerSnapshot = taskManagerSampler.sample(
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            paneDescriptors: descriptors
        )
    }

    /// The Task Manager's Refresh button: resample processes now and force one
    /// listener inspection past the sidebar throttle. The automatic timer uses
    /// `refreshTaskManager()` alone.
    func refreshTaskManagerManually() {
        refreshTaskManager()
        schedulePaneListeningPortRefresh(force: true)
    }

    private func taskManagerPaneDescriptors() -> [TaskManagerPaneDescriptor] {
        let workspaceNames = Dictionary(
            uniqueKeysWithValues: workspaces.map { ($0.workspaceID, $0.name) }
        )
        return panes.map { pane in
            let anchor = ghosttyRegistry.processAnchor(for: pane.id)
            return TaskManagerPaneDescriptor(
                paneID: pane.id,
                workspaceID: pane.workspaceID,
                workspaceName: workspaceNames[pane.workspaceID] ?? pane.workspaceName ?? pane.workspaceID,
                paneName: pane.displayName,
                kind: pane.kind,
                workingDirectory: pane.cwd,
                isSelected: pane.isActive,
                isStarted: pane.isStarted,
                foregroundPID: anchor.foregroundPID,
                ttyName: anchor.ttyName,
                ttyDevice: anchor.ttyName.flatMap(TaskManagerTTY.deviceID(for:))
            )
        }
    }

    func interruptFromTaskManager(_ paneID: String) {
        guard let pane = panes.first(where: { $0.id == paneID }), pane.isStarted else { return }
        let alert = NSAlert()
        alert.messageText = "Send Control-C to \(pane.displayName)?"
        alert.informativeText = "This interrupts the current foreground command in that pane. Parley will not end or restart the pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Send Control-C")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            try controller?.interruptPane(paneID)
            refreshTaskManager()
        }
    }

    func copyTaskManagerDiagnostics(_ paneSnapshot: TaskManagerPaneSnapshot) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        let cpu = paneSnapshot.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
        var lines = [
            "Parley pane diagnostics",
            "Pane: \(paneSnapshot.paneName) (\(paneSnapshot.paneID))",
            "Kind: \(paneSnapshot.kind.label)",
            "State: \(paneSnapshot.isStarted ? "started" : "stopped")",
            "Working folder: \(paneSnapshot.workingDirectory)",
            "TTY: \(paneSnapshot.ttyName ?? "unavailable")",
            "Foreground PID: \(paneSnapshot.foregroundPID.map(String.init) ?? "unavailable")",
            "CPU: \(cpu)",
            "Resident memory: \(formatter.string(fromByteCount: Int64(clamping: paneSnapshot.residentBytes)))",
            "Processes: \(paneSnapshot.processCount)",
        ]
        for process in paneSnapshot.processes {
            let processCPU = process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
            lines.append(
                "- PID \(process.pid) \(process.name): CPU \(processCPU), RSS \(formatter.string(fromByteCount: Int64(clamping: process.residentBytes)))"
            )
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    var canPrepareToUninstall: Bool {
        runtime.mode == .production
            && coreAvailable
            && relayClient != nil
            && !preparingToUninstall
    }

    func prepareToUninstall() {
        guard canPrepareToUninstall, let relayClient, let controller else { return }

        let confirmation = NSAlert()
        confirmation.messageText = "Prepare Parley for Uninstallation?"
        confirmation.informativeText = "Parley will refuse while Ask or delegated work is active. It will end every app-resident Ghostty pane, stop coordination, and quit. Workspace layouts and local collaboration history remain on disk."
        confirmation.alertStyle = .warning
        confirmation.addButton(withTitle: "Prepare and Quit")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        preparingToUninstall = true

        Task { [weak self] in
            guard let self else { return }
            do {
                let eligible = try await Task.detached(priority: .utility) {
                    let consultations = try relayClient.consultations()
                    let handoffs = try relayClient.handoffs(limit: 500)
                    return CoordinationShutdownPolicy.canStop(
                        activeConsultationCount: consultations.count,
                        handoffs: handoffs
                    )
                }.value
                guard eligible else {
                    throw RelayUIError.message(
                        "Parley cannot prepare for uninstallation while an Ask or tracked delegation is active. Finish or cancel that work first."
                    )
                }
                try self.interruptAutomaticOrchestrationForShutdown(
                    reason: "Auto orchestration stopped because Parley was prepared for uninstallation."
                )
                self.residentCore?.stop()
                try controller.shutdown()
                self.relayClient = nil
                self.coreAvailable = false
                self.coreError = nil
                self.preparedForUninstall = true
                self.removeExternalEditorCapabilities()

                let ready = NSAlert()
                ready.messageText = "Parley Is Ready to Remove"
                ready.informativeText = "The app-resident panes and coordination broker are stopped. After Parley quits, move Parley.app to Trash. Local layouts and history remain available for a reinstall."
                ready.addButton(withTitle: "Quit Parley")
                ready.runModal()
                NSApp.terminate(nil)
            } catch {
                self.preparingToUninstall = false

                let alert = NSAlert()
                alert.messageText = "Parley Was Not Prepared for Uninstallation"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    private func interruptAutomaticOrchestrationForShutdown(reason: String) throws {
        for task in automaticOrchestrationTasks.values { task.cancel() }
        automaticOrchestrationTasks.removeAll()
        for run in try supervisedWorkflowStore.runs()
            where run.mode == .automatic && !run.phase.isTerminal {
            _ = try supervisedWorkflowStore.interrupt(id: run.id, detail: reason)
        }
        try reloadSupervisedWorkflows()
    }

    func refreshRuntimeReadiness() {
        runtimeReadinessTask?.cancel()
        runtimeReadinessChecking = true
        vendorCompatibilityChecking = true
        let environment = controller?.environment ?? EnvironmentResolver.resolved()
        let applicationDirectory = applicationDirectory
        let coreHealthy = coreAvailable
        let paneSnapshot = panes
        let previousCompatibility = vendorCompatibility
        let readinessChecker = RuntimeReadinessChecker()
        let compatibilityChecker = VendorCompatibilityChecker()
        runtimeReadinessTask = Task { [weak self] in
            let (readiness, compatibility) = await Task.detached(priority: .utility) {
                let readiness = readinessChecker.check(
                    environment: environment,
                    applicationDirectory: applicationDirectory,
                    coreHealthy: coreHealthy,
                    panes: paneSnapshot
                )
                let compatibility = compatibilityChecker.check(
                    environment: environment,
                    readiness: readiness,
                    panes: paneSnapshot,
                    previous: previousCompatibility
                )
                return (readiness, compatibility)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.runtimeReadiness = readiness
            self.vendorCompatibility = compatibility
            self.runtimeReadinessChecking = false
            self.vendorCompatibilityChecking = false
            self.saveVendorCompatibility()
        }
    }

    func completeEnvironmentCheck() {
        preferences.set(true, forKey: Self.firstRunCompletedKey)
        setupPresented = false
        terminalHandle.focus()
    }

    func showReleaseLifecycle() {
        releaseLifecyclePresented = true
        refreshRuntimeReadiness()
    }

    func setReleaseChannel(_ channel: UpdateChannel) {
        guard channel != releaseChannel else { return }
        releaseChannel = channel
        preferences.set(channel.rawValue, forKey: Self.releaseChannelKey)
        releaseCheck = nil
        releaseLifecycleMessage = nil
    }

    func checkForUpdates() {
        guard !releaseChecking else { return }
        releaseTask?.cancel()
        releaseChecking = true
        releaseLifecycleMessage = nil
        let channel = releaseChannel
        let currentVersion = ParleyBuildInformation.current(runtime: runtime).applicationVersion
        let service = GitHubReleaseService()
        releaseTask = Task { [weak self] in
            do {
                let result = try await service.check(channel: channel, currentVersion: currentVersion)
                guard !Task.isCancelled, let self else { return }
                self.releaseCheck = result
                self.releaseChecking = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.releaseChecking = false
                self.releaseLifecycleMessage = error.localizedDescription
            }
        }
    }

    func startAutomaticUpdater() {
        guard let automaticUpdater else { return }
        automaticUpdater.start()
        refreshAutomaticUpdateState()
    }

    func checkForStableAutomaticUpdate() {
        automaticUpdater?.checkForUpdates()
        refreshAutomaticUpdateState()
    }

    func setSwiftPMCompatibilityEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: Self.swiftPMCompatibilityKey)
        swiftPMCompatibilityEnabled = enabled
        controller?.setSwiftPMCompatibilityEnabled(enabled)
    }

    func setAutomaticUpdateChecksEnabled(_ enabled: Bool) {
        automaticUpdater?.setAutomaticallyChecksForUpdates(enabled)
        refreshAutomaticUpdateState()
    }

    private func refreshAutomaticUpdateState() {
        automaticUpdateChecksEnabled = automaticUpdater?.automaticallyChecksForUpdates ?? false
        automaticUpdateCanCheck = automaticUpdater?.canCheckForUpdates ?? false
    }

    func openCheckedReleasePage() {
        guard let url = releaseCheck?.release.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(GitHubReleaseService.releasesPageURL)
    }

    func downloadCheckedRelease() {
        guard let verification = releaseCheck?.verification, !releaseDownloading else { return }
        let panel = NSSavePanel()
        panel.title = "Download Verified Parley DMG"
        panel.message = "Parley downloads the published DMG, verifies its byte count and SHA-256, and saves it. It does not install or restart anything."
        panel.prompt = "Download and Verify"
        panel.allowedContentTypes = [.diskImage]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = verification.dmgName
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        releaseDownloading = true
        releaseLifecycleMessage = nil
        let service = GitHubReleaseService()
        Task { [weak self] in
            do {
                try await service.downloadVerifiedDMG(verification, to: destination)
                guard let self else { return }
                self.releaseDownloading = false
                self.releaseLifecycleMessage = "Verified \(verification.dmgName) and saved it locally. Parley did not install or restart anything."
            } catch {
                guard let self else { return }
                self.releaseDownloading = false
                self.releaseLifecycleMessage = error.localizedDescription
            }
        }
    }

    func prepareBetaFeedbackReview() {
        guard let compatibility = vendorCompatibility else {
            releaseLifecycleMessage = "Run the quota-free compatibility check before reviewing a feedback bundle."
            return
        }
        var history = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        var activity = statusActivityEvents
        if let relayClient, let refreshed = try? relayClient.handoffs(limit: 500) {
            history = refreshed
            if refreshed != statusHandoffs { statusHandoffs = refreshed }
        }
        if let relayClient, let refreshed = try? relayClient.activityEvents(limit: 500) {
            activity = refreshed
            if refreshed != statusActivityEvents { statusActivityEvents = refreshed }
        }
        let information = ParleyBuildInformation.current(runtime: runtime)
        betaFeedbackBundle = BetaFeedbackBundleBuilder.build(
            build: BetaFeedbackBuild(
                applicationVersion: information.applicationVersion,
                buildNumber: information.buildNumber,
                sourceCommit: information.sourceCommit,
                runtime: runtime.mode.rawValue
            ),
            updateChannel: releaseChannel,
            compatibility: compatibility,
            diagnostics: makeDiagnosticsReport(handoffs: history, activityEvents: activity)
        )
        betaFeedbackPresented = true
    }

    func exportReviewedBetaFeedback() {
        guard let bundle = betaFeedbackBundle, !betaFeedbackExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Reviewed Beta Feedback"
        panel.message = "Creates an owner-only local ZIP containing only the fields shown in this review. Nothing is uploaded."
        panel.prompt = "Export Reviewed Bundle"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.betaFeedbackFilename()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        betaFeedbackExporting = true
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try BetaFeedbackArchiveWriter().write(bundle: bundle, to: destination)
                }.value
                guard let self else { return }
                self.betaFeedbackExporting = false
                self.betaFeedbackPresented = false
                self.releaseLifecycleMessage = "Saved reviewed beta feedback to \(destination.lastPathComponent). Nothing was uploaded."
            } catch {
                guard let self else { return }
                self.betaFeedbackExporting = false
                NSAlert(error: error).runModal()
            }
        }
    }

    func clearReleaseLifecycleMessage() {
        releaseLifecycleMessage = nil
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
        var activity = statusActivityEvents
        if let relayClient, let refreshed = try? relayClient.handoffs(limit: 500) {
            history = refreshed
            if refreshed != statusHandoffs { statusHandoffs = refreshed }
        }
        if let relayClient, let refreshed = try? relayClient.activityEvents(limit: 500) {
            activity = refreshed
            if refreshed != statusActivityEvents { statusActivityEvents = refreshed }
        }
        let report = makeDiagnosticsReport(handoffs: history, activityEvents: activity)
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

    private func makeDiagnosticsReport(
        handoffs: [RelayHandoff],
        activityEvents: [RelayActivityEvent]
    ) -> DiagnosticsReport {
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
            terminalAvailable: terminalAvailable,
            coreAvailable: coreAvailable,
            workspaceCount: workspaces.count,
            panes: panes,
            handoffs: handoffs,
            activityEvents: activityEvents,
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

    private func saveVendorCompatibility() {
        guard let vendorCompatibility else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(vendorCompatibility) {
            preferences.set(data, forKey: Self.vendorCompatibilityKey)
        }
    }

    private static func betaFeedbackFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return "Parley-Beta-Feedback-\(formatter.string(from: date)).zip"
    }

    private static func collaborationHistoryFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return "Parley-Collaboration-History-\(formatter.string(from: date)).md"
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
            terminalAvailable: terminalAvailable,
            coreAvailable: coreAvailable
        )
    }

    var activePaneState: WorkbenchPaneState {
        WorkbenchStateProjection.pane(activePane)
    }

    var menuBarAttentionSummary: MenuBarAttentionSummary {
        MenuBarAttentionProjection.summary(
            snapshot: externalAttentionSnapshot(generatedAt: Date()),
            coreAvailable: coreAvailable
        )
    }

    var canNavigateWorkspaces: Bool { workspaces.count > 1 }

    var canNavigatePanes: Bool { visiblePanes.count > 1 }

    func projectContext(for pane: WorkbenchPane) -> GitProjectContext? {
        let folder = URL(fileURLWithPath: pane.cwd).standardizedFileURL.path
        return projectContexts[folder]
    }

    func sidebarFacts(for pane: WorkbenchPane) -> PaneSidebarFacts {
        PaneSidebarFactsProjection.facts(
            for: pane,
            projectContext: projectContext(for: pane),
            listeningPortSnapshot: paneListeningPortSnapshot,
            attentionItems: paneAttentionItems
        )
    }

    func workspaceSafetySummary(for workspace: WorkbenchWorkspace) -> WorkspaceSafetySummary {
        let workspacePanes = panes.filter { $0.workspaceID == workspace.workspaceID }
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
        guard let workspaceID = activeWorkspace?.workspaceID else { return [] }
        let aliases = workspaceAliases(for: workspaceID)
        return worktreeWriterCollisions.filter { collision in
            collision.writers.contains(where: { aliases.contains($0.workspaceID) })
        }
    }

    var activeWorktreePath: String? {
        guard let paneID = activePane?.id else { return nil }
        return worktreeScan.paneWorktreePaths[paneID]
    }

    func hasWorktreeWriterCollision(workspaceID: String) -> Bool {
        let aliases = workspaceAliases(for: workspaceID)
        return worktreeWriterCollisions.contains { collision in
            collision.writers.contains(where: { aliases.contains($0.workspaceID) })
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
                    id: "action:new-workspace",
                    category: .action,
                    title: "New Workspace",
                    detail: "Create a folderless collaboration workspace",
                    keywords: ["new", "folderless", "collaboration"]
                ),
                action: .newWorkspace
            ),
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "action:open-workspace",
                    category: .action,
                    title: "Open Folder…",
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
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "action:terminal-appearance",
                    category: .action,
                    title: "Terminal Appearance…",
                    detail: "Set a shared pane font or import allowlisted Ghostty colours",
                    keywords: ["font", "size", "theme", "palette", "color", "colour", "settings"]
                ),
                action: .terminalAppearance
            ),
        ]

        commands += workspaces.map { workspace in
            PaletteCommand(
                item: CommandPaletteItem(
                    id: "workspace:\(workspace.id)",
                    category: .workspace,
                    title: workspace.name,
                    detail: workspace.newPaneFolder
                        ?? workspace.primaryAttachedFolder
                        ?? "No folders attached",
                    keywords: [workspace.isActive ? "current selected" : "open"]
                ),
                action: .selectWorkspace(workspace)
            )
        }

        commands += panes.map { pane in
            let workspace = workspaces.first(where: { $0.workspaceID == pane.workspaceID })?.name
                ?? pane.workspaceName
                ?? pane.workspaceID
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
            let workspace = workspaces.first(where: { $0.workspaceID == pane.workspaceID })?.name
                ?? pane.workspaceName
                ?? pane.workspaceID
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
        case .newWorkspace:
            createWorkspace()
        case .openWorkspace:
            openWorkspacePicker()
        case .openStatusCenter:
            break
        case .terminalAppearance:
            showTerminalFontSettings()
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

    var askTargets: [WorkbenchPane] {
        guard let source = activePane,
              source.kind.isAgent,
              source.isStarted,
              !source.isDead,
              source.relayEnabled,
              source.hasCurrentProtocol,
              source.inputAvailable else { return [] }
        return panes.filter {
            $0.kind.isAgent
                && $0.id != source.id
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
                && $0.inputAvailable
        }
    }

    var canCompareAskMany: Bool {
        askTargets.count >= 2
            && askManyComparisonRun?.isRunning != true
            && relayClient != nil
    }

    var askManyComparisonLead: WorkbenchPane? {
        guard let run = askManyComparisonRun else { return nil }
        return panes.first {
            $0.workspaceID == run.sourceWorkspaceID
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
        guard let workspaceID = activeWorkspace?.workspaceID else { return nil }
        let aliases = workspaceAliases(for: workspaceID)
        return workspaceBriefs.first(where: { aliases.contains($0.workspaceID) })
    }

    var contextPackWorkspaceBrief: WorkspaceBrief? {
        guard let workspaceID = contextPackSourcePane?.workspaceID else { return nil }
        let aliases = workspaceAliases(for: workspaceID)
        return workspaceBriefs.first(where: { aliases.contains($0.workspaceID) })
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

    var contextPackSourcePane: WorkbenchPane? {
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

    var contextPackAskTargets: [WorkbenchPane] {
        guard let source = contextPackSourcePane else { return [] }
        return panes.filter {
            $0.kind.isAgent
                && $0.id != source.id
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var vendorToolEvidencePanes: [WorkbenchPane] {
        panes.filter {
            $0.kind.isAgent && $0.isStarted && !$0.isDead
        }.sorted {
            let left = ($0.workspaceName ?? "", $0.displayName, $0.id)
            let right = ($1.workspaceName ?? "", $1.displayName, $1.id)
            return left < right
        }
    }

    func paneToolCapabilitySummary(for pane: WorkbenchPane) -> PaneToolCapabilitySummary {
        PaneToolCapabilityProjection.summary(for: pane, profiles: permissionProfiles)
    }

    func showPaneToolCapabilitySummary(_ pane: WorkbenchPane) {
        let summary = paneToolCapabilitySummary(for: pane)
        let alert = NSAlert()
        alert.messageText = "Browser & Tool Access · \(pane.displayName)"
        alert.informativeText = """
        Browser/tool access: \(summary.toolAccess.label)
        Network policy: \(summary.networkLabel)
        Evidence capture: \(summary.canCaptureEvidence ? "Available through explicit Context Pack review" : "Unavailable while this pane is stopped")

        \(summary.detail)

        Parley does not inspect browser profiles, cookies, website credentials or vendor MCP configuration. Network permission is not proof that a browser tool exists.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    var canCompareContextPack: Bool {
        contextPackAskTargets.count >= 2
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

    var localAskTargets: [WorkbenchPane] {
        guard let workspaceID = activeWorkspace?.workspaceID else { return [] }
        return askTargets.filter { $0.workspaceID == workspaceID }
    }

    var workspaceLead: WorkbenchPane? {
        guard let workspaceID = activeWorkspace?.workspaceID else { return nil }
        return panes.first { $0.workspaceID == workspaceID && $0.isWorkspaceLead }
    }

    var recipeTargets: [WorkbenchPane] {
        guard let lead = workspaceLead else { return [] }
        return panes.filter {
            $0.workspaceID == lead.workspaceID
                && $0.id != lead.id
                && $0.kind.isAgent
                && $0.isStarted
                && !$0.isDead
                && $0.relayEnabled
                && $0.hasCurrentProtocol
                && $0.inputAvailable
        }
    }

    var activeSupervisedWorkflow: SupervisedWorkflowRun? {
        guard let workspaceID = activeWorkspace?.workspaceID else { return nil }
        let aliases = workspaceAliases(for: workspaceID)
        return supervisedWorkflowRuns.first {
            aliases.contains($0.workspaceID) && !$0.phase.isTerminal
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
        guard let workspaceID = activeWorkspace?.workspaceID else { return [] }
        let aliases = workspaceAliases(for: workspaceID)
        return supervisedWorkflowRuns.filter {
            aliases.contains($0.workspaceID) && $0.phase.isTerminal
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
              lead.inputAvailable else { return false }
        return !recipeTargets.isEmpty
    }

    func pane(for participant: SupervisedWorkflowParticipant) -> WorkbenchPane? {
        panes.first {
            $0.id == participant.paneID
                && $0.workspaceID == participant.workspaceID
        }
    }

    func canRun(_ recipe: HandoffRecipe) -> Bool {
        guard let workspace = activeWorkspace,
              activeSupervisedWorkflow == nil,
              let lead = workspaceLead,
              lead.isStarted,
              !lead.isDead,
              lead.relayEnabled,
              lead.hasCurrentProtocol,
              lead.inputAvailable,
              recipe.kind.isAllowed(by: workspace.automationPolicy) else { return false }
        return HandoffRecipeTargeting.canSatisfy(recipe, with: recipeTargets)
    }

    var otherWorkspaceAskGroups: [WorkspaceAskGroup] {
        workspaces.compactMap { workspace in
            guard !workspace.isActive else { return nil }
            let targets = askTargets.filter { $0.workspaceID == workspace.workspaceID }
            return targets.isEmpty ? nil : WorkspaceAskGroup(workspace: workspace, panes: targets)
        }
    }

    var activePaneConsultations: [RelayConsultation] {
        guard let activePane else { return [] }
        return consultations.filter {
            $0.targetPaneID == activePane.id && $0.state == .awaitingAnswer
        }
    }

    var canReturn: Bool { !activePaneConsultations.isEmpty }

    private func workspaceAliases(for reference: String) -> Set<String> {
        let durableID = workspaces.first(where: {
            $0.id == reference || $0.workspaceID == reference
        })?.workspaceID ?? panes.first(where: {
            $0.workspaceID == reference
        })?.workspaceID
        guard let durableID else { return [reference] }
        return Set(panes.lazy.filter { $0.workspaceID == durableID }
            .map(\.workspaceID))
            .union([reference, durableID])
    }

    var workspaceHandoffs: [RelayHandoff] {
        guard let workspaceID = activeWorkspace?.workspaceID else { return handoffs }
        let aliases = workspaceAliases(for: workspaceID)
        return handoffs.filter {
            aliases.contains($0.sourceWorkspaceID) || aliases.contains($0.targetWorkspaceID)
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

    /// Owned-timestamp facts for one delegation: elapsed since delivery, the
    /// agent-declared note's age and the exact target pane's hook signal age.
    /// Nil for non-delegations and for records without a recorded delivered transition.
    func delegationVisibility(for handoff: RelayHandoff, at now: Date) -> DelegationVisibility? {
        guard handoff.kind == .delegate else { return nil }
        let target = panes.first { $0.id == handoff.targetPaneID }
        return DelegationVisibilityProjection.facts(for: handoff, target: target, now: now)
    }

    func awaitingAnswerCount(for paneID: String) -> Int {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return handoffs.count { $0.targetPaneID == paneID && activeStates.contains($0.state) }
    }

    func latestFailure(for paneID: String) -> RelayHandoff? {
        guard let latest = handoffs.first(where: { $0.targetPaneID == paneID }),
              latest.state == .failed || latest.state == .interrupted else {
            return nil
        }
        return latest
    }

    var paneAttentionItems: [PaneAttentionItem] {
        var byID: [String: RelayHandoff] = [:]
        for handoff in unreadHandoffs + statusHandoffs + handoffs {
            byID[handoff.id] = handoff
        }
        return PaneAttentionProjection.items(
            panes: panes,
            handoffs: Array(byID.values)
        )
    }

    func paneAttention(for paneID: String) -> PaneAttentionItem? {
        PaneAttentionProjection.primary(forPaneID: paneID, in: paneAttentionItems)
    }
    var handoffComposerSignalAdvisory: HandoffComposerSignalAdvisory? {
        guard let draft = handoffComposerDraft,
              let target = panes.first(where: {
                  $0.id == draft.targetPaneID && $0.kind == draft.targetKind
              }) else {
            return nil
        }
        return HandoffComposerSignalProjection.advisory(for: target)
    }


    /// Returns true when the Status Center should be presented for the item.
    @discardableResult
    func focusNextAttention() -> Bool {
        let items = paneAttentionItems
        guard !items.isEmpty else {
            attentionCycleCursorID = nil
            return false
        }
        let nextIndex: Int
        if let cursor = attentionCycleCursorID,
           let currentIndex = items.firstIndex(where: { $0.id == cursor }) {
            nextIndex = items.index(after: currentIndex) == items.endIndex
                ? items.startIndex
                : items.index(after: currentIndex)
        } else {
            nextIndex = items.startIndex
        }
        let item = items[nextIndex]
        attentionCycleCursorID = item.id

        if item.reason == .permissionRequest, canFocus(item.paneID) {
            _ = openExternalNavigation(.pane(item.paneID))
            return false
        }
        if let handoffID = item.handoffID {
            return openExternalNavigation(.handoff(handoffID))
        }
        if canFocus(item.paneID) {
            _ = openExternalNavigation(.pane(item.paneID))
        }
        return false
    }
    func unreadResultCount(forPane paneID: String) -> Int {
        unreadHandoffs.count { $0.sourcePaneID == paneID }
    }

    func unreadResultCount(forWorkspace workspaceID: String) -> Int {
        let aliases = workspaceAliases(for: workspaceID)
        return unreadHandoffs.count { aliases.contains($0.sourceWorkspaceID) }
    }

    func waitingCount(for workspaceID: String) -> Int {
        let aliases = workspaceAliases(for: workspaceID)
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        return handoffs.count {
            activeStates.contains($0.state)
                && (aliases.contains($0.sourceWorkspaceID)
                    || aliases.contains($0.targetWorkspaceID))
        }
    }

    func failureCount(for workspaceID: String) -> Int {
        let aliases = workspaceAliases(for: workspaceID)
        return handoffs.count {
            (aliases.contains($0.sourceWorkspaceID)
                || aliases.contains($0.targetWorkspaceID))
                && ($0.state == .failed || $0.state == .interrupted)
        }
    }

    func requiresHumanAttention(_ workspaceID: String) -> Bool {
        let aliases = workspaceAliases(for: workspaceID)
        return handoffs.contains {
            (aliases.contains($0.sourceWorkspaceID)
                || aliases.contains($0.targetWorkspaceID))
                && $0.state == .failed
                && $0.attention != nil
        }
    }

    func notificationsEnabled(for workspace: WorkbenchWorkspace) -> Bool {
        notificationWorkspaceNames.contains(workspace.name)
    }

    func setNotificationsEnabled(_ enabled: Bool, for workspace: WorkbenchWorkspace) {
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


    private func refreshCommandRuns() {
        guard let core = residentCore, let controller else { return }
        let coordinator = core.commandRuns
        coordinator.reconcile()
        coordinator.serviceWorkers(directory: core.commandRunDirectory)
        // Keep approved work queued while a preview covers the terminal.
        if !commandRunsPresented,
           let mainWindow = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Parley" }),
           mainWindow.attachedSheet == nil {
            coordinator.launchApproved { run in
                if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
                mainWindow.makeKeyAndOrderFront(nil)
                NSApp.activate()
                guard mainWindow.isVisible else { throw ReviewedCommandRunError.invalid("A visible Parley window is required before starting this command.") }
                guard let executable = Bundle.main.executableURL else { throw ReviewedCommandRunError.invalid("The Parley worker executable is unavailable.") }
                let created = try controller.createApprovedCommandPane(run: run, workerExecutable: executable)
                focusCanvasPaneID = nil
                recordNativeSplit(created: created, target: run.source, direction: .vertical)
                // Select and visibly mount the new retained surface before starting
                // the fixed worker. No input is sent to an existing Shell.
                panes = try controller.listPanes()
                workspaces = try controller.listWorkspaces()
                _ = try ghosttyRegistry.view(for: created.id)
                ghosttyRegistry.select(paneID: created.id)
            }
        }
        let runs = coordinator.runs()
        let grants = coordinator.grants()
        if runs != commandRuns { commandRuns = runs }
        if grants != commandRunGrants { commandRunGrants = grants }
        commandRunError = coordinator.lastError ?? (core.commandRunCleanupWarnings.isEmpty ? nil : core.commandRunCleanupWarnings.joined(separator: "\n"))
        refreshCommandRunAttention()
    }

    private func refreshCommandRunAttention() {
        let mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Parley" }
        // Include requested sheets that SwiftUI has not mounted yet. Keep
        // menus, native alerts, settings and other windows' edits undisturbed.
        let anotherPresentation = commandPalettePresented || setupPresented
            || panePermissionRequest != nil || paneChoiceRequest != nil
            || askManyComparisonPresented || contextPackPresented
            || workspaceBriefPresented || pinnedContextSnippetsPresented
            || supervisedWorkflowPresented || worktreeBrowserPresented
            || releaseLifecyclePresented || betaFeedbackPresented
            || handoffComposerDraft != nil || startupError != nil
        let canPresent = mainWindow?.isKeyWindow == true
            && mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
            && NSApp.modalWindow == nil && !anotherPresentation
            && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
            && RunLoop.main.currentMode != .eventTracking
        let decision = commandRunAttention.update(
            pendingIDs: pendingCommandRunIDs, reviewPresented: commandRunsPresented,
            canPresent: canPresent, applicationActive: NSApp.isActive
        )
        if decision.requestDockAttention {
            _ = NSApp.requestUserAttention(.informationalRequest)
        }
        if let id = decision.presentRunID {
            selectedCommandRunID = id
            commandRunsPresented = true
        }
    }

    func reviewCommandRuns() {
        if let run = commandRuns.first(where: { $0.state == .pending }) ?? commandRuns.first {
            selectCommandRun(run)
        }
        commandRunsPresented = true
    }

    func selectCommandRun(_ run: ReviewedCommandRun) {
        selectedCommandRunID = run.id
        if run.state == .pending { commandRunAttention.didPresent(runID: run.id) }
    }

    func dismissCommandRunReview() {
        // SwiftUI can report a dismissal after approve/reject already closed
        // the sheet. That acknowledgement must not suppress the next request.
        guard commandRunsPresented else { return }
        commandRunAttention.didDismiss(pendingIDs: pendingCommandRunIDs)
        commandRunsPresented = false
    }

    func approveCommandRun(_ run: ReviewedCommandRun, argv: [String], folder: String, autoApprove: Bool) throws {
        guard let core = residentCore else { throw ReviewedCommandRunError.invalid("The native command-run service is unavailable.") }
        try core.commandRuns.approve(id: run.id, revision: run.revision, argv: argv, folder: folder, autoApprove: autoApprove)
        commandRuns = core.commandRuns.runs()
        commandRunGrants = core.commandRuns.grants()
        commandRunsPresented = false
        // Dismiss the editable preview before the normal refresh starts work.
    }
    func rejectCommandRun(_ run: ReviewedCommandRun) {
        perform {
            guard let core = residentCore else { throw ReviewedCommandRunError.invalid("The native command-run service is unavailable.") }
            try core.commandRuns.reject(id: run.id, revision: run.revision)
            commandRuns = core.commandRuns.runs()
            commandRunsPresented = false
            try refresh()
        }
    }
    func cancelCommandRun(_ run: ReviewedCommandRun) {
        perform { try residentCore?.commandRuns.cancel(id: run.id); try refresh() }
    }
    func revokeCommandRunGrant(_ grant: ReviewedCommandGrant) {
        residentCore?.commandRuns.revoke(grantID: grant.id)
        try? refresh()
    }


    func refresh() throws {
        refreshCommandRuns()
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
                ghosttyRegistry.retainOnly(paneIDs: Set(refreshedPanes.map(\.id)))
                ghosttyRegistry.select(paneID: refreshedPanes.first(where: \.isActive)?.id)
                var selectedPaneIDs: [String: String] = [:]
                if let active = refreshedPanes.first(where: \.isActive) {
                    selectedPaneIDs[active.workspaceID] = active.id
                }
                // The registry keeps records for workspaces a stopped server
                // no longer lists; a write failure must not break refresh.
                _ = try? workspaceRegistry.synchronize(
                    workspaces: refreshedWorkspaces,
                    selectedPaneIDs: selectedPaneIDs
                )
                reconcileNativeLayouts(workspaces: refreshedWorkspaces, panes: refreshedPanes)
                reapIdleAgentsIfEnabled(controller: controller, panes: refreshedPanes)
                terminalAvailable = true
                terminalError = nil
            } catch {
                terminalAvailable = false
                terminalError = error.localizedDescription
                firstError = error
            }
        } else {
            terminalAvailable = false
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
                let refreshedBusyDrafts = try relayClient.reviewedBusyDrafts()
                if refreshedBusyDrafts != reviewedBusyDrafts {
                    reviewedBusyDrafts = refreshedBusyDrafts
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
        if terminalAvailable {
            scheduleProjectContextRefresh()
            schedulePaneListeningPortRefresh()
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
            throw RelayUIError.message("Parley could not initialise its Ghostty workbench. Quit and reopen the app after resolving the startup error.")
        }
        if !terminalAvailable {
            try controller.bootstrap(
                cwd: defaultFolder,
                createIfMissing: true
            )
        }
        if !coreAvailable {
            if let residentCore, residentCore.client.isHealthy() {
                relayClient = residentCore.client
            } else {
                let credentials = try RelayCredentials(
                    file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
                )
                let core = try AppResidentCoordinationCore(
                    controller: controller,
                    credentials: credentials,
                    applicationDirectory: controller.applicationDirectory,
                    transportDirectory: RelayFileTransport.runtimeDirectory(
                        applicationDirectory: controller.applicationDirectory
                    )
                )
                residentCore = core
                relayClient = core.client
            }
        }
        try refresh()
        startupError = nil
    }

    func refreshQuietly() {
        do { try refresh() } catch { /* a retained surface or broker may be between lifecycle events */ }
    }

    private func startPeriodicRefresh() {
        guard periodicRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.periodicRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshQuietly()
            }
        }
        RunLoop.main.add(timer, forMode: MenuTrackingRefreshPolicy.runLoopMode)
        periodicRefreshTimer = timer
    }

    private func externalAttentionSnapshot(generatedAt: Date) -> ExternalAttentionSnapshot {
        var byID: [String: RelayHandoff] = [:]
        for handoff in unreadHandoffs + statusHandoffs + handoffs {
            byID[handoff.id] = handoff
        }
        return ExternalAttentionProjection.snapshot(
            workspaces: workspaces,
            panes: panes,
            handoffs: Array(byID.values),
            generatedAt: generatedAt
        )
    }

    private func publishExternalAttentionSnapshot(force: Bool = false) {
        guard runtime.mode == .production else { return }
        let now = Date()
        publishExternalEditorCapabilities(generatedAt: now, force: force)
        let snapshot = externalAttentionSnapshot(generatedAt: now)
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

    private func publishExternalEditorCapabilities(generatedAt: Date, force: Bool) {
        let heartbeatDue = generatedAt.timeIntervalSince(lastExternalEditorCapabilitiesPublishedAt)
            >= Self.externalAttentionHeartbeatInterval
        guard force || heartbeatDue else { return }
        do {
            try ExternalEditorBridgeCapabilitiesFile.write(
                ExternalEditorBridgeCapabilities(generatedAt: generatedAt),
                applicationDirectory: applicationDirectory
            )
            try ExternalContextAcknowledgementFile.removeExpired(
                applicationDirectory: applicationDirectory,
                olderThan: ExternalContextImport.requestLifetime * 2,
                now: generatedAt
            )
            lastExternalEditorCapabilitiesPublishedAt = generatedAt
        } catch {
            // A missing or stale file makes the optional editor bridge fail
            // closed. It must never interrupt the native workbench refresh.
        }
    }

    private func removeExternalEditorCapabilities() {
        guard runtime.mode == .production else { return }
        ExternalEditorBridgeCapabilitiesFile.remove(applicationDirectory: applicationDirectory)
        lastExternalEditorCapabilitiesPublishedAt = .distantPast
    }

    func refreshStatusCenterQuietly() {
        historyPersistenceError = residentCore?.historyPersistenceError
        do {
            try refresh()
            guard let relayClient else { return }
            let history = try relayClient.handoffs(limit: 500)
            if history != statusHandoffs { statusHandoffs = history }
            let activity = try relayClient.activityEvents(limit: 500)
            if activity != statusActivityEvents { statusActivityEvents = activity }
            let retention = try relayClient.historyRetentionPolicy()
            if retention != historyRetentionPolicy { historyRetentionPolicy = retention }
            let busyDrafts = try relayClient.reviewedBusyDrafts()
            if busyDrafts != reviewedBusyDrafts { reviewedBusyDrafts = busyDrafts }
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

    private func schedulePaneListeningPortRefresh(force: Bool = false) {
        let descriptors = taskManagerPaneDescriptors()
        let signature = paneListeningPortSignature(descriptors)
        let now = Date()
        guard paneListeningPortRefreshState.shouldAttempt(
            now: now,
            inputSignature: signature,
            forced: force
        ) else { return }

        paneListeningPortRefreshState.beginAttempt(at: now, inputSignature: signature)
        guard descriptors.contains(where: \.isStarted) else {
            paneListeningPortRefreshState.publish(PaneListeningPortSnapshot(
                sampledAt: now,
                portsByPaneID: Dictionary(
                    uniqueKeysWithValues: descriptors.map { ($0.paneID, []) }
                )
            ))
            publishPaneListeningPortSnapshot()
            return
        }

        let resolver = paneListeningPortResolver
        let applicationPID = ProcessInfo.processInfo.processIdentifier
        Task.detached(priority: .utility) {
            // nil means lsof could not run or timed out; the previous snapshot
            // and its freshness are kept and the attempt still counts for the
            // throttle.
            let sampled = resolver.sample(
                applicationPID: applicationPID,
                paneDescriptors: descriptors,
                sampledAt: now
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                let currentSignature = self.paneListeningPortSignature(
                    self.taskManagerPaneDescriptors()
                )
                let inputsStillMatch = currentSignature == signature
                self.paneListeningPortRefreshState.finishAttempt(with: inputsStillMatch ? sampled : nil)
                guard inputsStillMatch else {
                    self.schedulePaneListeningPortRefresh(force: true)
                    return
                }
                self.publishPaneListeningPortSnapshot()
            }
        }
    }

    private func publishPaneListeningPortSnapshot() {
        let snapshot = paneListeningPortRefreshState.snapshot
        if snapshot != paneListeningPortSnapshot {
            paneListeningPortSnapshot = snapshot
        }
    }

    private func paneListeningPortSignature(
        _ descriptors: [TaskManagerPaneDescriptor]
    ) -> [String] {
        descriptors.map { descriptor in
            [
                descriptor.paneID,
                descriptor.isStarted ? "started" : "stopped",
                descriptor.foregroundPID.map(String.init) ?? "-",
                descriptor.ttyDevice.map(String.init) ?? "-",
            ].joined(separator: "\u{1f}")
        }.sorted()
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


    func statusReviewedBusyDrafts(workspaceID: String?) -> [ReviewedBusyDraft] {
        let aliases = workspaceID.map(workspaceAliases(for:)) ?? []
        return reviewedBusyDrafts.filter { draft in
            workspaceID == nil
                || aliases.contains(draft.sourceWorkspaceID)
                || aliases.contains(draft.targetWorkspaceID)
        }
    }

    func reviewedBusyDraftTargetIsBusy(_ draft: ReviewedBusyDraft) -> Bool {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        let knownHistory = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        return knownHistory.contains {
            $0.targetPaneID == draft.targetPaneID && activeStates.contains($0.state)
        }
    }

    func canFocusReviewedBusyDraftPane(_ paneID: String) -> Bool {
        panes.contains { $0.id == paneID }
    }

    func focusReviewedBusyDraft(_ draft: ReviewedBusyDraft, target: Bool) {
        guard let pane = panes.first(where: {
            $0.id == (target ? draft.targetPaneID : draft.sourcePaneID)
        }) else { return }
        select(pane)
    }

    func sendReviewedBusyDraft(_ draft: ReviewedBusyDraft) {
        guard draft.state == .queued,
              sendingReviewedBusyDraftID == nil,
              let relayClient else { return }
        if reviewedBusyDraftTargetIsBusy(draft) {
            let alert = NSAlert()
            alert.messageText = "\(draft.targetName) Is Still Busy"
            alert.informativeText = "The reviewed draft remains visible and unsent. Parley will not submit it automatically when the target becomes idle."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        guard let edited = editSupervisedWorkflowText(
            title: "Review and Send to \(draft.targetName)",
            message: "This is a fresh human authorization. The exact edited text will be submitted as a tracked Ask from \(draft.sourceName). Parley never sends this merely because the target became idle.",
            text: draft.text,
            action: "Send Reviewed Ask",
            insertVisible: { "" }
        ) else { return }

        sendingReviewedBusyDraftID = draft.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.sendReviewedBusyDraft(ReviewedBusyDraftSendRequest(
                        draftID: draft.id,
                        expectedUpdatedAt: draft.updatedAt,
                        text: edited,
                        preserveFormatting: draft.preserveFormatting
                    ))
                }.value
                self.sendingReviewedBusyDraftID = nil
                self.refreshStatusCenterQuietly()
                guard response.status == 200 else {
                    throw RelayUIError.message(response.text)
                }
            } catch {
                self.sendingReviewedBusyDraftID = nil
                self.refreshStatusCenterQuietly()
                NSAlert(error: error).runModal()
            }
        }
    }

    func discardReviewedBusyDraft(_ draft: ReviewedBusyDraft) -> Bool {
        let alert = NSAlert()
        alert.messageText = draft.state == .queued
            ? "Discard Reviewed Draft?"
            : "Dismiss Uncertain Send Record?"
        alert.informativeText = draft.state == .queued
            ? "This removes the local unsent draft for \(draft.targetName). No terminal input will be submitted. This cannot be undone."
            : "Parley cannot prove whether terminal submission occurred before the interruption. Dismissing this record does not cancel or reverse input that may already have reached \(draft.targetName), and Parley will not make it resendable."
        alert.alertStyle = .warning
        alert.addButton(withTitle: draft.state == .queued ? "Discard Draft" : "Dismiss Record")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            guard let relayClient else {
                throw RelayUIError.message("The app-resident coordination core is unavailable.")
            }
            let response = try relayClient.cancelReviewedBusyDraft(draft.id)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            refreshStatusCenterQuietly()
            return true
        } catch {
            NSAlert(error: error).runModal()
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

    func clearStatusHistory(workspaceID: String?, workspaceName: String?) -> String? {
        // Only an explicit nil scope means All Workspaces; never widen an
        // empty or stale workspace argument into a global deletion.
        if let workspaceID, workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSAlert(error: RelayUIError.message("Choose a workspace or All Workspaces before clearing history.")).runModal()
            return nil
        }
        let scopeName = workspaceID == nil ? "All Workspaces" : (workspaceName ?? workspaceID ?? "")
        let alert = NSAlert()
        alert.messageText = "Clear history for \(scopeName)?"
        alert.informativeText = "This permanently clears finished collaboration records and their returned or captured results, plus recorded pane and workspace activity in this scope. It includes records hidden by search filters or dismissal. Active work and running panes are preserved. This affects only this local \(runtime.mode.label) app and cannot be undone."
        alert.alertStyle = .warning
        let clear = alert.addButton(withTitle: "Clear History")
        let cancel = alert.addButton(withTitle: "Cancel")
        clear.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        do {
            guard let relayClient else {
                throw RelayUIError.message("The Parley coordination core is unavailable.")
            }
            let response: RelayTextResponse
            if let workspaceID {
                response = try relayClient.deleteWorkspaceHistory(workspaceID: workspaceID, workspaceName: workspaceName)
            } else {
                response = try relayClient.deleteAllHistory()
            }
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            refreshStatusCenterQuietly()
            return response.text
        } catch {
            // One journal may have cleared before another failed. Refresh the
            // actual retained records before showing the bounded error.
            refreshStatusCenterQuietly()
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func setHistoryRetention(maximumRecords: Int) {
        do {
            let requested = try CollaborationHistoryRetentionPolicy(maximumRecords: maximumRecords)
            guard requested != historyRetentionPolicy else { return }
            let lowering = requested.maximumRecords < historyRetentionPolicy.maximumRecords
            let alert = NSAlert()
            alert.messageText = "Keep up to \(requested.maximumRecords) local history records?"
            alert.informativeText = lowering
                ? "Parley will keep up to \(requested.maximumRecords) collaboration handoffs and \(requested.maximumRecords) lifecycle events. Lowering the current \(historyRetentionPolicy.maximumRecords)-record limit permanently removes the oldest eligible records immediately and cannot restore them later. Active handoffs are always preserved. This changes only this local \(runtime.mode.label) runtime; nothing is uploaded."
                : "Parley will keep up to \(requested.maximumRecords) collaboration handoffs and \(requested.maximumRecords) lifecycle events. Increasing the limit does not restore records previously removed. Active handoffs are preserved. This changes only this local \(runtime.mode.label) runtime; nothing is uploaded."
            alert.alertStyle = lowering ? .warning : .informational
            alert.addButton(withTitle: lowering ? "Apply and Prune" : "Change Retention")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard let relayClient else {
                throw RelayUIError.message("The Parley coordination core is unavailable.")
            }
            let change = try relayClient.updateHistoryRetention(
                maximumRecords: requested.maximumRecords
            )
            historyRetentionPolicy = change.policy
            refreshStatusCenterQuietly()
            guard change.removedHandoffs > 0 || change.removedActivityEvents > 0 else { return }
            let result = NSAlert()
            result.messageText = "Local History Retention Updated"
            result.informativeText = "Parley removed \(change.removedHandoffs) terminal handoff record\(change.removedHandoffs == 1 ? "" : "s") and \(change.removedActivityEvents) lifecycle event\(change.removedActivityEvents == 1 ? "" : "s"). Active work was preserved."
            result.addButton(withTitle: "OK")
            result.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportWorkspaceHistory(for workspace: WorkbenchWorkspace) {
        let source = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        let records = CollaborationHistoryProjection.records(
            source,
            involvingWorkspaceID: workspace.workspaceID
        )
        guard !records.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Collaboration History to Export"
            alert.informativeText = "Parley has no retained handoff records involving \(workspace.name). Lifecycle activity remains visible in Status Center but is not part of the collaboration-history Markdown export."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        exportCollaborationHistory(
            records,
            scopeName: workspace.name,
            selectionDescription: "All \(records.count) retained handoff record\(records.count == 1 ? "" : "s") involving this workspace"
        )
    }

    func exportCollaborationHistory(
        _ handoffs: [RelayHandoff],
        scopeName: String?,
        selectionDescription: String? = nil
    ) {
        guard !handoffs.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = selectionDescription == nil
            ? "Export Selected Collaboration History"
            : "Export Workspace Collaboration History"
        panel.message = selectionDescription == nil
            ? "This local Markdown file contains the complete questions, instructions, returned results, identities, and delivery receipts for exactly the selected records. Nothing is uploaded."
            : "This local Markdown file contains complete questions, instructions, returned results, identities, and delivery receipts for every retained handoff involving this workspace, including dismissed records. Lifecycle activity is not included. Nothing is uploaded."
        panel.prompt = selectionDescription == nil ? "Export Selected" : "Export Workspace"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = Self.collaborationHistoryFilename()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let markdown = CollaborationHistoryMarkdown.document(
                handoffs: handoffs,
                scopeName: scopeName,
                selectionDescription: selectionDescription
            )
            try CollaborationHistoryMarkdownWriter.write(markdown, to: destination)
            let alert = NSAlert()
            alert.messageText = "Collaboration History Exported"
            alert.informativeText = selectionDescription == nil
                ? "Parley saved \(handoffs.count) selected record\(handoffs.count == 1 ? "" : "s") to \(destination.lastPathComponent). Nothing was uploaded."
                : "Parley saved \(handoffs.count) retained workspace handoff record\(handoffs.count == 1 ? "" : "s") to \(destination.lastPathComponent). Nothing was uploaded."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func canAskAgain(_ handoff: RelayHandoff) -> Bool {
        repeatingAskHandoffID == nil
            && CollaborationHistoryRepeat.route(for: handoff, panes: panes) != nil
    }

    func askAgain(_ handoff: RelayHandoff) {
        guard repeatingAskHandoffID == nil,
              let route = CollaborationHistoryRepeat.route(for: handoff, panes: panes),
              let source = panes.first(where: { $0.id == route.sourcePaneID }),
              let target = panes.first(where: { $0.id == route.targetPaneID }),
              let relayClient else {
            NSAlert(error: RelayUIError.message(
                "This Ask cannot be repeated on its original route. Both original panes must still be running, relay-ready, and on Parley's current protocol."
            )).runModal()
            return
        }
        guard let edited = editRelay(
            title: "Ask \(target.displayName) Again",
            message: "Review the complete question before sending. This creates a new tracked Ask from \(source.displayName) to \(target.displayName); the historical record remains unchanged.",
            text: handoff.text,
            action: "Ask Again",
            insertVisible: { [weak self] in
                guard let self, let controller = self.controller else { return "" }
                return try controller.capturePane(source.id)
            }
        ) else { return }

        let freshIdentity = UUID().uuidString.lowercased()
        repeatingAskHandoffID = handoff.id
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.askFromUI(
                        sourcePaneID: route.sourcePaneID,
                        targetPaneID: route.targetPaneID,
                        text: edited,
                        idempotencyKey: freshIdentity
                    )
                }.value
                self.repeatingAskHandoffID = nil
                self.refreshStatusCenterQuietly()
                guard response.status == 200 else {
                    throw RelayUIError.message(response.text)
                }
            } catch {
                self.repeatingAskHandoffID = nil
                self.refreshStatusCenterQuietly()
                NSAlert(error: error).runModal()
            }
        }
    }

    func markRead(_ handoff: RelayHandoff) {
        guard handoff.hasUnreadResult, let relayClient else { return }
        do {
            let response = try relayClient.markHandoffRead(handoff.id)
            guard response.status == 200 else { return }
            refreshStatusCenterQuietly()
        } catch {
            // The regular refresh owns connection health. The app-resident core
            // from the previous UI build may not know this control route yet;
            // leave the result unread instead of misreporting the core as down.
            refreshQuietly()
        }
    }

    func create(_ kind: PaneKind, direction: SplitDirection) {
        if kind.isAgent,
           activeWorkspace?.isFolderless == true,
           activeWorkspace?.newPaneFolder == nil {
            createInChosenFolder(kind, direction: direction)
            return
        }
        preparePane(kind, direction: direction, folder: defaultFolder)
    }

    func createInActivePaneFolder(_ kind: PaneKind, direction: SplitDirection) {
        guard let activePane else { return }
        preparePane(kind, direction: direction, folder: activePane.cwd)
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
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        guard kind.isAgent else {
            createPane(kind, direction: direction, folder: standardized, permissionProfile: nil)
            return
        }
        panePermissionRequest = PanePermissionRequest(
            kind: kind,
            folder: standardized,
            workspaceName: activeWorkspace?.name ?? "Workspace",
            workspaceFolders: activeWorkspace?.attachedFolders ?? [],
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
            let standardized = WorkspaceFolderIdentity.normalized(folder)
            let splitTarget = activePane
            let created = try controller.createPane(
                kind: kind,
                cwd: standardized,
                permissionProfile: permissionProfile
            )
            recordNativeSplit(created: created, target: splitTarget, direction: direction)
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

    func permissionProfileName(for pane: WorkbenchPane) -> String? {
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
                let splitTarget = activePane
                let created = try controller.createPane(
                    kind: request.kind,
                    cwd: request.folder,
                    permissionProfile: effective
                )
                recordNativeSplit(created: created, target: splitTarget, direction: direction)
                rememberFolder(request.folder)
            case let .restart(paneID):
                try controller.restartPane(paneID, permissionProfile: effective)
                if let pane = panes.first(where: { $0.id == paneID }) {
                    try recordSuccessfulActivity(RelayActivityEventRequest(
                        kind: .paneRestarted,
                        workspaceID: pane.workspaceID,
                        workspaceName: pane.workspaceName ?? pane.workspaceID,
                        paneID: pane.id,
                        paneName: pane.displayName,
                        paneKind: pane.kind,
                        detail: "\(pane.kind.label) pane restarted with \(definition.name) permissions."
                    ))
                }
            case let .resume(paneID, replacingRunningProcess):
                guard let pane = panes.first(where: { $0.id == paneID }) else {
                    throw RelayUIError.message("That pane no longer exists.")
                }
                guard pane.isStarted == replacingRunningProcess else {
                    throw RelayUIError.message("That pane's running state changed. Reopen Resume and review it again.")
                }
                guard let plan = VendorResumeAdapter.plan(for: pane.kind) else {
                    throw RelayUIError.message("That pane does not support vendor session resume.")
                }
                if replacingRunningProcess {
                    try controller.restartPane(
                        paneID,
                        permissionProfile: effective,
                        launchMode: .resume
                    )
                } else {
                    try controller.startPane(
                        paneID,
                        permissionProfile: effective,
                        launchMode: .resume
                    )
                }
                try recordSuccessfulActivity(RelayActivityEventRequest(
                    kind: .paneResumeRequested,
                    workspaceID: pane.workspaceID,
                    workspaceName: pane.workspaceName ?? pane.workspaceID,
                    paneID: pane.id,
                    paneName: pane.displayName,
                    paneKind: pane.kind,
                    detail: "\(plan.detail) Launched with \(definition.name) permissions."
                ))
            case let .folderAccess(paneID):
                guard let pane = panes.first(where: { $0.id == paneID }) else {
                    throw RelayUIError.message("That pane no longer exists.")
                }
                guard effective.selection != pane.permissionSelection else {
                    throw RelayUIError.message("Folder access is unchanged; the pane was not restarted.")
                }
                let alert = NSAlert()
                alert.messageText = "Restart \(pane.displayName) with new folder access?"
                alert.informativeText = "The current vendor process will end. Its working folder remains \(request.folder). On restart, only the exact reviewed roots shown here are passed to the vendor CLI."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Restart with Access")
                alert.addButton(withTitle: "Keep Current Session")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try controller.restartPane(paneID, permissionProfile: effective)
                try recordSuccessfulActivity(RelayActivityEventRequest(
                    kind: .paneRestarted,
                    workspaceID: pane.workspaceID,
                    workspaceName: pane.workspaceName ?? pane.workspaceID,
                    paneID: pane.id,
                    paneName: pane.displayName,
                    paneKind: pane.kind,
                    detail: "\(pane.kind.label) pane restarted with \(definition.name) access to \(effective.approvedRoots.count) reviewed folder\(effective.approvedRoots.count == 1 ? "" : "s")."
                ))
            case let .start(paneID):
                try controller.startPane(paneID, permissionProfile: effective)
            }

            if definition.defaultLifetime == .remembered, !request.isFolderAccessReview {
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

    func select(_ pane: WorkbenchPane) {
        if focusCanvasPaneID != nil { focusCanvasPaneID = pane.id }
        perform {
            try controller?.selectPane(pane.id)
            _ = try? workspaceRegistry.updateSelectedPane(
                workspaceID: pane.workspaceID,
                paneID: pane.id
            )
            try refresh()
            terminalHandle.focus()
        }
    }

    /// Mouse focus in a native split also updates the authoritative base
    /// session selection. The clicked terminal already becomes first
    /// responder, so this path deliberately avoids refocusing a stale handle
    /// while SwiftUI publishes the newly active leaf.
    func selectNativePane(_ paneID: String) {
        guard activePane?.id != paneID,
              let pane = panes.first(where: { $0.id == paneID }) else { return }
        if focusCanvasPaneID != nil { focusCanvasPaneID = paneID }
        perform {
            try controller?.selectPane(pane.id)
            _ = try? workspaceRegistry.updateSelectedPane(
                workspaceID: pane.workspaceID,
                paneID: pane.id
            )
            try refresh()
        }
    }

    func select(_ workspace: WorkbenchWorkspace) {
        focusCanvasPaneID = nil
        perform {
            let recordedPaneID = try? workspaceRegistry.record(
                workspaceID: workspace.workspaceID
            )?.selectedPaneID
            if let recordedPaneID,
               panes.contains(where: {
                   $0.id == recordedPaneID && $0.workspaceID == workspace.workspaceID
               }) {
                try controller?.selectPane(recordedPaneID)
            } else {
                try controller?.selectWorkspace(workspace.id)
            }
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
        let orderedPanes = layoutOrderedVisiblePanes
        guard let targetID = NavigationOrder.adjacentID(
            currentID: activePane?.id,
            offset: offset,
            orderedIDs: orderedPanes.map(\.id)
        ), let target = orderedPanes.first(where: { $0.id == targetID }) else { return }
        select(target)
    }

    func selectPane(at index: Int) {
        let orderedPanes = layoutOrderedVisiblePanes
        guard orderedPanes.indices.contains(index) else { return }
        select(orderedPanes[index])
    }

    func toggleFocusCanvas(paneID: String? = nil) {
        let target = paneID ?? activePane?.id
        guard let target, visiblePanes.contains(where: { $0.id == target }) else {
            focusCanvasPaneID = nil
            return
        }
        focusCanvasPaneID = focusCanvasPaneID == target ? nil : target
        if activePane?.id != target, let pane = visiblePanes.first(where: { $0.id == target }) {
            select(pane)
        } else {
            terminalHandle.focus()
        }
    }

    func exitFocusCanvas() {
        focusCanvasPaneID = nil
        terminalHandle.focus()
    }

    func focusActiveTerminal() {
        terminalHandle.focus()
    }

    func toggleCollaborationDock() {
        collaborationDockVisible.toggle()
        preferences.set(collaborationDockVisible, forKey: Self.collaborationDockVisibleKey)
    }

    func ask(_ target: WorkbenchPane) {
        guard let source = activePane,
              askTargets.contains(where: { $0.id == target.id }) else { return }
        let selection = RelayDraft.initialText(selection: terminalHandle.selectedText)
        quickRelayTargetHistory.record(sourcePaneID: source.id, targetPaneID: target.id)
        handoffComposerDraft = HandoffComposerDraft(
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            text: selection,
            includesTerminalSelection: !selection.isEmpty
        )
    }

    var quickRelayTarget: WorkbenchPane? {
        guard let source = activePane else { return nil }
        let eligibleTargets = askTargets
        guard let targetPaneID = quickRelayTargetHistory.targetPaneID(
            for: source.id,
            eligibleTargetPaneIDs: Set(eligibleTargets.map(\.id))
        ) else { return nil }
        return eligibleTargets.first { $0.id == targetPaneID }
    }

    var canQuickRelaySelection: Bool {
        handoffComposerDraft == nil
            && !submittingHandoffComposer
            && quickRelayTarget != nil
    }

    func quickRelaySelection() {
        guard handoffComposerDraft == nil, !submittingHandoffComposer else { return }
        guard let source = activePane, let target = quickRelayTarget else {
            let alert = NSAlert()
            alert.messageText = "No Previous Ask Target"
            alert.informativeText = "Choose an explicit target from the Ask menu for this pane first. Nothing was sent."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let selection = RelayDraft.initialText(selection: terminalHandle.selectedText)
        guard !selection.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Select Terminal Text First"
            alert.informativeText = "Select the exact text in \(source.displayName), then press Command-Shift-A again. Parley never captures scrollback implicitly."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        handoffComposerDraft = HandoffComposerDraft(
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            text: selection,
            includesTerminalSelection: true
        )
    }

    func updateHandoffComposerText(_ text: String) {
        handoffComposerDraft?.text = text
    }

    func insertSelectionInHandoffComposer() {
        guard var draft = handoffComposerDraft else { return }
        perform {
            guard let controller else {
                throw RelayUIError.message("The embedded terminal workbench is unavailable.")
            }
            let selection = RelayText.clean(try controller.capturePane(draft.sourcePaneID))
            guard !selection.isEmpty else {
                throw RelayUIError.message("Select text in \(draft.sourceName) first; Parley never captures scrollback implicitly.")
            }
            if !draft.text.isEmpty { draft.text += "\n\n" }
            draft.text += selection
            draft.includesTerminalSelection = true
            handoffComposerDraft = draft
        }
    }

    func handoffReviewSource(for handoff: RelayHandoff) -> WorkbenchPane? {
        guard (handoff.kind == .ask || handoff.kind == .delegate), handoff.hasReturnedResult else { return nil }
        if let original = panes.first(where: {
            $0.id == handoff.sourcePaneID && isReviewReadyAgent($0)
        }) {
            return original
        }
        guard let activePane, isReviewReadyAgent(activePane) else { return nil }
        return activePane
    }

    func handoffReviewTargets(for handoff: RelayHandoff) -> [WorkbenchPane] {
        guard let source = handoffReviewSource(for: handoff) else { return [] }
        return panes
            .filter { $0.id != source.id && isReviewReadyAgent($0) }
            .sorted {
                let left = ($0.workspaceName ?? "", $0.displayName, $0.id)
                let right = ($1.workspaceName ?? "", $1.displayName, $1.id)
                return left < right
            }
    }

    func handoffReviewTargetIsBusy(_ pane: WorkbenchPane) -> Bool {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        let knownHistory = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        return knownHistory.contains {
            $0.targetPaneID == pane.id && activeStates.contains($0.state)
        }
    }

    func canOfferHandoffReview(_ handoff: RelayHandoff) -> Bool {
        relayClient != nil
            && handoffComposerDraft == nil
            && !submittingHandoffComposer
            && handoffReviewSource(for: handoff) != nil
            && !handoffReviewTargets(for: handoff).isEmpty
    }

    func beginHandoffReview(
        _ relationship: RelayHandoffRelationship,
        of handoff: RelayHandoff,
        with target: WorkbenchPane
    ) {
        guard let source = handoffReviewSource(for: handoff),
              handoffReviewTargets(for: handoff).contains(where: { $0.id == target.id }) else {
            NSAlert(error: RelayUIError.message(LinkedHandoffCopy.notRelayReady(relationship))).runModal()
            return
        }
        guard !handoffReviewTargetIsBusy(target) else {
            NSAlert(error: RelayUIError.message(
                LinkedHandoffCopy.targetBusy(relationship, targetName: target.displayName)
            )).runModal()
            return
        }
        let text = Self.linkedReviewDraftText(
            relationship: relationship,
            handoff: handoff
        )
        guard text.count <= RelayText.maximumCharacters else {
            NSAlert(error: RelayUIError.message(LinkedHandoffCopy.resultTooLarge(relationship))).runModal()
            return
        }
        handoffComposerDraft = HandoffComposerDraft(
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceKind: source.kind,
            targetPaneID: target.id,
            targetName: target.displayName,
            targetKind: target.kind,
            text: text,
            includesTerminalSelection: false,
            inReplyToHandoffID: handoff.id,
            relationship: relationship
        )
    }

    func saveHandoffReview(
        _ handoff: RelayHandoff,
        verdict: RelayHandoffVerdict?,
        note: String
    ) {
        perform {
            guard let relayClient else {
                throw RelayUIError.message("The app-resident coordination core is unavailable.")
            }
            let response = try relayClient.updateHandoffReview(RelayHandoffReviewUpdate(
                handoffID: handoff.id,
                expectedReviewRevision: handoff.reviewRevision ?? 0,
                verdict: verdict,
                note: note
            ))
            guard response.status == 200 else {
                refreshStatusCenterQuietly()
                throw RelayUIError.message(response.text)
            }
            refreshStatusCenterQuietly()
        }
    }

    func cancelHandoffComposer() {
        guard !submittingHandoffComposer else { return }
        handoffComposerDraft = nil
        terminalHandle.focus()
    }

    func submitHandoffComposer() {
        guard !submittingHandoffComposer, let draft = handoffComposerDraft else { return }
        let isLinkedReview = draft.inReplyToHandoffID != nil && draft.relationship != nil
        let edited = isLinkedReview
            ? ContextPackText.normalize(draft.text)
            : RelayText.clean(draft.text)
        guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if let parentID = draft.inReplyToHandoffID,
           let relationship = draft.relationship {
            if relationship == .requestChanges {
                submitRequestChangesDelegate(draft: draft, text: edited, parentID: parentID)
            } else {
                submitLinkedReviewAsk(
                    draft: draft,
                    text: edited,
                    parentID: parentID,
                    relationship: relationship
                )
            }
            return
        }
        guard draft.inReplyToHandoffID == nil, draft.relationship == nil else {
            NSAlert(error: RelayUIError.message(
                "The linked review draft is incomplete. Nothing was sent."
            )).runModal()
            return
        }

        perform {
            guard let source = panes.first(where: {
                $0.id == draft.sourcePaneID && $0.kind.isAgent && $0.isStarted && !$0.isDead
            }), let target = panes.first(where: {
                $0.id == draft.targetPaneID && $0.kind.isAgent && $0.isStarted && !$0.isDead
            }) else {
                throw RelayUIError.message("The reviewed source or target pane is no longer available. Nothing was sent.")
            }
            try submitOrOfferBusyQueue(
                edited,
                from: source,
                to: target,
                preserveFormatting: false
            )
            handoffComposerDraft = nil
            try refresh()
            terminalHandle.clearSelection()
            terminalHandle.focus()
        }
    }

    private func submitLinkedReviewAsk(
        draft: HandoffComposerDraft,
        text: String,
        parentID: String,
        relationship: RelayHandoffRelationship
    ) {
        guard let relayClient,
              let source = panes.first(where: {
                  $0.id == draft.sourcePaneID && isReviewReadyAgent($0)
              }),
              let target = panes.first(where: {
                  $0.id == draft.targetPaneID && isReviewReadyAgent($0)
              }),
              source.id != target.id else {
            NSAlert(error: RelayUIError.message(
                "The reviewed source or target pane is no longer relay-ready. Nothing was sent."
            )).runModal()
            return
        }
        guard !handoffReviewTargetIsBusy(target) else {
            NSAlert(error: RelayUIError.message(
                "\(target.displayName) already has tracked work. Linked reviews are never placed in the ordinary busy queue because that would lose their parent relationship."
            )).runModal()
            return
        }

        let draftID = draft.id
        let idempotencyKey = UUID().uuidString.lowercased()
        submittingHandoffComposer = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.reviewAskFromUI(
                        sourcePaneID: source.id,
                        targetPaneID: target.id,
                        text: text,
                        idempotencyKey: idempotencyKey,
                        inReplyToHandoffID: parentID,
                        relationship: relationship
                    )
                }.value
                self.submittingHandoffComposer = false
                self.refreshStatusCenterQuietly()
                guard response.status == 200 else {
                    throw RelayUIError.message(response.text)
                }
                if self.handoffComposerDraft?.id == draftID {
                    self.handoffComposerDraft = nil
                    self.terminalHandle.clearSelection()
                    self.terminalHandle.focus()
                }
            } catch {
                self.submittingHandoffComposer = false
                self.refreshStatusCenterQuietly()
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Request Changes is a linked Delegate child, never a verdict. It goes
    /// through the native-control route directly: a busy target is refused,
    /// and the draft never enters the reviewed busy queue.
    private func submitRequestChangesDelegate(
        draft: HandoffComposerDraft,
        text: String,
        parentID: String
    ) {
        guard let relayClient,
              let source = panes.first(where: {
                  $0.id == draft.sourcePaneID && isReviewReadyAgent($0)
              }),
              let target = panes.first(where: {
                  $0.id == draft.targetPaneID && isReviewReadyAgent($0)
              }),
              source.id != target.id else {
            NSAlert(error: RelayUIError.message(
                "The reviewed source or target pane is no longer relay-ready. Nothing was sent."
            )).runModal()
            return
        }
        guard !handoffReviewTargetIsBusy(target) else {
            NSAlert(error: RelayUIError.message(
                "\(target.displayName) already has tracked work. A linked request for changes is never queued; finish or cancel that work first."
            )).runModal()
            return
        }

        let draftID = draft.id
        let idempotencyKey = UUID().uuidString.lowercased()
        submittingHandoffComposer = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.requestChangesFromUI(
                        sourcePaneID: source.id,
                        targetPaneID: target.id,
                        text: text,
                        idempotencyKey: idempotencyKey,
                        inReplyToHandoffID: parentID
                    )
                }.value
                self.submittingHandoffComposer = false
                self.refreshStatusCenterQuietly()
                guard response.status == 200 else {
                    throw RelayUIError.message(response.text)
                }
                if self.handoffComposerDraft?.id == draftID {
                    self.handoffComposerDraft = nil
                    self.terminalHandle.clearSelection()
                    self.terminalHandle.focus()
                }
            } catch {
                self.submittingHandoffComposer = false
                self.refreshStatusCenterQuietly()
                NSAlert(error: error).runModal()
            }
        }
    }

    private func isReviewReadyAgent(_ pane: WorkbenchPane) -> Bool {
        pane.kind.isAgent
            && pane.isStarted
            && !pane.isDead
            && pane.relayEnabled
            && pane.hasCurrentProtocol
            && pane.inputAvailable
    }

    private static func linkedReviewDraftText(
        relationship: RelayHandoffRelationship,
        handoff: RelayHandoff
    ) -> String {
        let request: String
        switch relationship {
        case .challenge:
            request = "Challenge this returned result. Identify unsupported assumptions, concrete failures, and the corrections required before it should be accepted."
        case .verify:
            request = "Verify this returned result against the stated task. Identify the evidence that supports or contradicts it, then give a clear conclusion."
        case .requestChanges:
            request = "Revise this returned result. Address the requested changes below, keep what is already correct, and return the revised result with `parley done current` or `parley done current --file <path>`.\n\nRequested changes:\n(describe the changes required before this result can be accepted)"
        }
        let originalLabel = handoff.kind == .commandRun ? "Original command request" : (handoff.kind == .delegate ? "Original instruction" : "Original question or message")
        return """
        \(request)

        Linked Parley handoff: \(handoff.id)
        Original route: \(handoff.sourceName) to \(handoff.targetName)

        \(originalLabel):
        \(handoff.text)

        Returned result:
        \(handoff.resultText ?? "")
        """
    }

    func editWorkspaceBrief() {
        guard let workspace = activeWorkspace else { return }
        let aliases = workspaceAliases(for: workspace.workspaceID)
        let existing = workspaceBriefs.first(where: { aliases.contains($0.workspaceID) })
        workspaceBriefDraft = ActiveWorkspaceBriefDraft(
            workspaceID: workspace.workspaceID,
            workspaceName: workspace.name,
            existingBriefID: existing?.id,
            goal: existing?.goal ?? "",
            constraints: existing?.constraints ?? "",
            decisions: existing?.decisions ?? "",
            conclusions: existing?.conclusions ?? "",
            rationale: existing?.rationale ?? "",
            confidence: existing?.confidence ?? "",
            openQuestions: existing?.openQuestions ?? ""
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

    func saveWorkspaceBrief(
        goal: String,
        constraints: String,
        decisions: String,
        conclusions: String,
        rationale: String,
        confidence: String,
        openQuestions: String
    ) {
        do {
            guard let draft = workspaceBriefDraft else { return }
            _ = try workspaceBriefStore.save(
                workspaceID: draft.workspaceID,
                workspaceName: draft.workspaceName,
                goal: goal,
                constraints: constraints,
                decisions: decisions,
                conclusions: conclusions,
                rationale: rationale,
                confidence: confidence,
                openQuestions: openQuestions
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
    func canPromoteHandoffResultsToContextPack(_ handoffs: [RelayHandoff]) -> Bool {
        canCreateContextPack
            && !handoffs.isEmpty
            && handoffs.count <= ContextPackBuilder.maximumParts
            && Set(handoffs.map(\.id)).count == handoffs.count
            && handoffs.allSatisfy(\.hasReturnedResult)
            && handoffs.allSatisfy { $0.resultContextReviewID == nil }
    }

    func promoteHandoffResultsToContextPack(_ handoffs: [RelayHandoff]) {
        perform {
            guard canPromoteHandoffResultsToContextPack(handoffs),
                  let source = activePane,
                  let contextPackBuilder else {
                throw RelayUIError.message(
                    "Select a running relay-ready agent pane, then choose between 1 and \(ContextPackBuilder.maximumParts) returned Ask or Delegate results."
                )
            }
            let parts = try handoffs.map(contextPackBuilder.handoffResult)
            let pack = ContextPack(
                name: handoffs.count == 1 ? "Selected handoff result" : "Selected handoff results",
                note: "Review these person-selected cross-vendor results. Edit or remove any part before choosing a receiving pane.",
                parts: parts
            )
            _ = try contextPackBuilder.render(pack)

            if let existing = contextPackDraft, !existing.pack.parts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Replace the current context pack?"
                alert.informativeText = "The current pack has \(existing.pack.parts.count) explicit source\(existing.pack.parts.count == 1 ? "" : "s"). Replace it with \(handoffs.count) selected handoff result\(handoffs.count == 1 ? "" : "s")? Nothing will be submitted."
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
                pack: pack,
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

    func presentContextPack() {
        guard contextPackDraft != nil else { return }
        contextPackPresented = true
    }

    func returnedFileReview(for handoff: RelayHandoff) -> AgentContextReview? {
        guard let reviewID = handoff.resultContextReviewID else { return nil }
        return contextReviews.first(where: { $0.id == reviewID })
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
        guard contextPackDraft != nil else { return }
        let candidates = panes.filter { $0.isStarted && !$0.isDead }
        guard !candidates.isEmpty else {
            NSAlert(error: RelayUIError.message("There is no running pane from which selected text can be added.")).runModal()
            return
        }
        requestPaneChoice(
            title: "Use selection from which pane?",
            message: "Select terminal text first. Parley reads only that pane's current selection; it never captures scrollback or a whole conversation implicitly.",
            actionLabel: "Add Selection",
            candidates: candidates,
            selection: .single(preferredPaneID: activePane?.id)
        ) { [weak self] selected in
            guard let pane = selected.first else { return }
            self?.addVisibleTerminalContext(from: pane)
        }
    }

    private func addVisibleTerminalContext(from pane: WorkbenchPane) {
        guard let draft = contextPackDraft else { return }
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
                let part = try contextPackBuilder.terminalSelection(
                    paneID: pane.id,
                    paneName: pane.displayName,
                    text: visible
                )
                try appendContextPackParts([part], draftID: draft.id)
            }
            terminalHandle.clearSelection()
        }
    }

    func addVendorToolEvidence(
        kind: VendorToolEvidenceKind,
        paneID: String,
        sourceURL: String,
        selectedText: String,
        artifactPath: String
    ) throws {
        guard let draft = contextPackDraft else {
            throw RelayUIError.message("Open a context pack before adding browser or tool evidence.")
        }
        guard let pane = vendorToolEvidencePanes.first(where: { $0.id == paneID }) else {
            throw RelayUIError.message("That vendor pane is no longer running, so Parley cannot preserve truthful attribution.")
        }
        let url = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = artifactPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reviewID = draft.reviewID {
            let captureKind: AgentContextTrustedCaptureKind = switch kind {
            case .browserURL: .browserURL
            case .browserSelection: .browserSelection
            case .browserScreenshot: .browserScreenshot
            case .savedArtifact: .toolArtifact
            }
            try captureTrustedContext(
                AgentContextTrustedCaptureRequest(
                    reviewID: reviewID,
                    kind: captureKind,
                    paths: path.isEmpty ? [] : [path],
                    evidencePaneID: pane.id,
                    sourceURL: url.isEmpty ? nil : url,
                    selectedText: kind == .browserSelection ? selectedText : nil
                ),
                draftID: draft.id
            )
            return
        }

        guard let contextPackBuilder else {
            throw RelayUIError.message("Context capture is unavailable.")
        }
        let part: ContextPackPart = switch kind {
        case .browserURL:
            try contextPackBuilder.browserURLEvidence(from: pane, url: url)
        case .browserSelection:
            try contextPackBuilder.browserSelectionEvidence(from: pane, url: url, text: selectedText)
        case .browserScreenshot, .savedArtifact:
            try contextPackBuilder.vendorArtifactEvidence(
                kind: kind,
                from: pane,
                file: URL(fileURLWithPath: path),
                sourceURL: url.isEmpty ? nil : url
            )
        }
        try appendContextPackParts([part], draftID: draft.id)
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
                conclusions: savedBrief.conclusions,
                rationale: savedBrief.rationale,
                confidence: savedBrief.confidence,
                openQuestions: savedBrief.openQuestions,
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
                throw RelayUIError.message("The app-resident core is unavailable, so Parley cannot establish trusted capture provenance.")
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
        guard let draft = contextPackDraft else { return }
        guard !contextPackAskTargets.isEmpty else {
            NSAlert(error: RelayUIError.message("Open a ready pane from another vendor before sending this context pack.")).runModal()
            return
        }
        requestPaneChoice(
            title: "Ask which vendor with this context?",
            message: "The exact pack visible behind this sheet will be submitted through Parley's attributed Ask path after one more confirmation.",
            actionLabel: "Continue",
            candidates: contextPackAskTargets,
            selection: .single(preferredPaneID: draft.requestedTargetPaneID)
        ) { [weak self] selected in
            guard let target = selected.first else { return }
            self?.askWithContextPack(target: target)
        }
    }

    private func askWithContextPack(target: WorkbenchPane) {
        perform {
            guard let draft = contextPackDraft,
                  let source = contextPackSourcePane,
                  let contextPackBuilder else {
                throw RelayUIError.message("The context pack's source pane is no longer ready.")
            }
            let rendered = try contextPackBuilder.render(draft.pack)
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
                    throw RelayUIError.message("The app-resident core is unavailable, so this agent request cannot be approved.")
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
                    throw RelayUIError.message("The app-resident core is unavailable, so this agent draft cannot be sent safely.")
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
                try submitOrOfferBusyQueue(
                    rendered,
                    from: source,
                    to: target,
                    preserveFormatting: true
                )
            }
            contextPackPresented = false
            contextPackDraft = nil
            try refresh()
            terminalHandle.focus()
        }
    }

    func compareWithContextPack() {
        guard canCompareContextPack, contextPackDraft != nil else {
            NSAlert(error: RelayUIError.message("This context pack needs a ready source pane and at least two other target panes.")).runModal()
            return
        }
        requestPaneChoice(
            title: "Compare with which panes?",
            message: "Choose at least two distinct panes. Every selected pane receives the same attributed pack independently.",
            actionLabel: "Continue",
            candidates: contextPackAskTargets,
            selection: .multiple(minimum: 2)
        ) { [weak self] targets in
            guard targets.count >= 2 else { return }
            self?.compareWithContextPack(targets: targets)
        }
    }

    private func compareWithContextPack(targets: [WorkbenchPane]) {
        perform {
            guard canCompareContextPack,
                  let draft = contextPackDraft,
                  let source = contextPackSourcePane,
                  let contextPackBuilder else {
                throw RelayUIError.message("This context pack needs a ready source pane and at least two other target panes.")
            }
            let rendered = try contextPackBuilder.render(draft.pack)
            guard confirmContextSend(
                title: "Compare this context across \(targets.count) panes?",
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
        requestPaneChoice(
            title: "Compare with which panes?",
            message: "Choose at least two distinct panes. Every selected pane receives the same question independently.",
            actionLabel: "Continue",
            candidates: askTargets,
            selection: .multiple(minimum: 2)
        ) { [weak self] targets in
            guard let self, targets.count >= 2 else { return }
            self.compareAskMany(source: source, targets: targets)
        }
    }

    private func compareAskMany(source: WorkbenchPane, targets: [WorkbenchPane]) {
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
        source: WorkbenchPane,
        targets: [WorkbenchPane],
        question: String,
        preserveFormatting: Bool = false
    ) {
        guard let relayClient else { return }
        let run = AskManyComparisonRun(
            id: UUID().uuidString.lowercased(),
            sourcePaneID: source.id,
            sourceName: source.displayName,
            sourceWorkspaceID: source.workspaceID,
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
        terminalHandle.clearSelection()

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

    func reviewChanges(with target: WorkbenchPane) {
        perform {
            guard let source = activePane, let reviewDraftBuilder else { return }
            let draft = try reviewDraftBuilder.changes(in: source.cwd)
            try sendReview(draft, from: source, to: target)
        }
    }

    func reviewFile(with target: WorkbenchPane) {
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
            let initial = selectedContext ?? "Describe the exact task or decision this workflow should plan, review, implement and verify."
            guard let objective = editSupervisedWorkflowText(
                title: "Start Smart Orchestration",
                message: participants.mode == .automatic
                    ? "Auto will run correlated Plan, Review, Implement and Verify handoffs, preserve every result, and stop for your final decision. Vendor permission prompts remain authoritative."
                    : "Supervised mode pauses at every handoff so you can inspect and edit the exact payload.",
                text: initial,
                action: participants.mode == .automatic ? "Start Auto" : "Start Supervised",
                insertVisible: { try controller.capturePane(lead.id) }
            ) else { return }

            let planningPrompt = try SmartOrchestrationPromptBuilder(task: objective).planning()

            let leadStamp = workflowParticipant(lead)
            let reviewerStamp = workflowParticipant(participants.reviewer)
            let verifierStamp = workflowParticipant(participants.verifier)
            let run = try supervisedWorkflowStore.start(
                workspaceID: workspace.workspaceID,
                workspaceName: workspace.name,
                lead: leadStamp,
                reviewer: reviewerStamp,
                verifier: verifierStamp,
                planningPrompt: objective,
                mode: participants.mode
            )
            if participants.mode == .supervised {
                do {
                    try controller.pasteExplicitContext(planningPrompt, into: lead.id, submit: true)
                } catch {
                    _ = try? supervisedWorkflowStore.interrupt(
                        id: run.id,
                        detail: "Planning dispatch failed before the workflow could continue: \(error.localizedDescription)"
                    )
                    try reloadSupervisedWorkflows()
                    throw error
                }
            }
            try reloadSupervisedWorkflows()
            selectedSupervisedWorkflowID = run.id
            supervisedWorkflowPresented = true
            if participants.mode == .automatic {
                launchAutomaticOrchestration(run.id)
            } else {
                try controller.selectPane(lead.id)
                try refresh()
            }
            terminalHandle.clearSelection()
            terminalHandle.focus()
        }
    }

    private func launchAutomaticOrchestration(_ workflowID: String) {
        automaticOrchestrationTasks[workflowID]?.cancel()
        automaticOrchestrationTasks[workflowID] = Task { [weak self] in
            await self?.runAutomaticOrchestration(workflowID)
        }
    }

    private func runAutomaticOrchestration(_ workflowID: String) async {
        defer { automaticOrchestrationTasks[workflowID] = nil }
        do {
            var run = try requireAutomaticWorkflow(id: workflowID, phase: .planning)
            let prompts = SmartOrchestrationPromptBuilder(task: run.planningPrompt)

            let plan = try await automaticWorkflowAsk(
                workflowID: workflowID,
                stage: .planning,
                source: run.reviewer,
                target: run.lead,
                text: try prompts.planning()
            )
            try Task.checkCancellation()
            run = try requireAutomaticWorkflow(id: workflowID, phase: .planning)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .reviewingPlan,
                artifact: SupervisedWorkflowArtifact(kind: .plan, text: plan),
                detail: "Auto captured the lead's correlated plan and dispatched its exact text for independent review.",
                origin: .automation
            )
            try reloadSupervisedWorkflows()

            run = try requireAutomaticWorkflow(id: workflowID, phase: .reviewingPlan)
            let review = try await automaticWorkflowAsk(
                workflowID: workflowID,
                stage: .reviewingPlan,
                source: run.lead,
                target: run.reviewer,
                text: try prompts.planReview(plan: plan)
            )
            try Task.checkCancellation()
            run = try requireAutomaticWorkflow(id: workflowID, phase: .reviewingPlan)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .awaitingImplementationApproval,
                artifact: SupervisedWorkflowArtifact(kind: .planReview, text: review),
                detail: "Auto captured the review through its correlated answer. The person's initial Auto authorization permits the implementation stage.",
                origin: .automation
            )
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .implementing,
                artifact: nil,
                detail: "Auto submitted the preserved plan and independent review to the lead. Vendor permissions remain authoritative.",
                origin: .automation
            )
            try reloadSupervisedWorkflows()

            run = try requireAutomaticWorkflow(id: workflowID, phase: .implementing)
            let implementationReport = try await automaticWorkflowAsk(
                workflowID: workflowID,
                stage: .implementing,
                source: run.reviewer,
                target: run.lead,
                text: try prompts.implementation(plan: plan, review: review)
            )
            try Task.checkCancellation()
            run = try requireAutomaticWorkflow(id: workflowID, phase: .implementing)
            let implementationEvidence = """
            Attributed implementation report returned by \(run.lead.name). This remains an agent claim until the verifier checks it:

            \(implementationReport)
            """
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .verifying,
                artifact: SupervisedWorkflowArtifact(kind: .implementation, text: implementationEvidence),
                detail: "Auto preserved the lead's implementation report and dispatched it for independent verification.",
                origin: .automation
            )
            try reloadSupervisedWorkflows()

            run = try requireAutomaticWorkflow(id: workflowID, phase: .verifying)
            let verification = try await automaticWorkflowAsk(
                workflowID: workflowID,
                stage: .verifying,
                source: run.lead,
                target: run.verifier,
                text: try prompts.verification(implementationEvidence: implementationEvidence)
            )
            try Task.checkCancellation()
            run = try requireAutomaticWorkflow(id: workflowID, phase: .verifying)
            _ = try supervisedWorkflowStore.advance(
                id: run.id,
                to: .awaitingCompletionApproval,
                artifact: SupervisedWorkflowArtifact(kind: .verification, text: verification),
                detail: "Auto captured the verifier's correlated report and stopped for the person's final decision.",
                origin: .automation
            )
            try reloadSupervisedWorkflows()
            selectedSupervisedWorkflowID = workflowID
            supervisedWorkflowPresented = true
            refreshStatusCenterQuietly()
        } catch is CancellationError {
            return
        } catch {
            let detail = "Auto orchestration stopped without declaring success: \(error.localizedDescription)"
            if let run = (try? supervisedWorkflowStore.runs().first { $0.id == workflowID }),
               !run.phase.isTerminal {
                _ = try? supervisedWorkflowStore.interrupt(id: workflowID, detail: detail)
            }
            try? reloadSupervisedWorkflows()
            selectedSupervisedWorkflowID = workflowID
            supervisedWorkflowPresented = true
            refreshStatusCenterQuietly()
        }
    }

    private func automaticWorkflowAsk(
        workflowID: String,
        stage: SupervisedWorkflowPhase,
        source: SupervisedWorkflowParticipant,
        target: SupervisedWorkflowParticipant,
        text: String
    ) async throws -> String {
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so Auto sent nothing.")
        }
        _ = try requireWorkflowPane(source, role: "source")
        _ = try requireWorkflowPane(target, role: "target")
        let response = try await Task.detached(priority: .userInitiated) {
            try relayClient.askFromUI(
                sourcePaneID: source.paneID,
                targetPaneID: target.paneID,
                text: text,
                idempotencyKey: "smart:\(workflowID):\(stage.rawValue)",
                preserveFormatting: true,
                origin: .automation
            )
        }.value
        try Task.checkCancellation()
        refreshStatusCenterQuietly()
        guard response.status == 200 else {
            throw RelayUIError.message(response.text)
        }
        let answer = ContextPackText.normalize(response.text)
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RelayUIError.message("\(target.name) returned an empty correlated answer.")
        }
        return answer
    }

    private func requireAutomaticWorkflow(
        id: String,
        phase: SupervisedWorkflowPhase
    ) throws -> SupervisedWorkflowRun {
        guard let run = try supervisedWorkflowStore.runs().first(where: { $0.id == id }) else {
            throw RelayUIError.message("The Auto workflow no longer exists.")
        }
        guard run.mode == .automatic else {
            throw RelayUIError.message("This workflow is not running in Auto mode.")
        }
        guard let workspace = workspaces.first(where: {
            workspaceAliases(for: $0.workspaceID).contains(run.workspaceID)
        }), workspace.automationPolicy != .off else {
            throw RelayUIError.message("Workspace automation is Off, so Auto stopped before sending another handoff.")
        }
        guard run.phase == phase else {
            throw RelayUIError.message(
                "Auto stopped because the workflow moved from \(phase.label) to \(run.phase.label)."
            )
        }
        return run
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
            terminalHandle.clearSelection()
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
            terminalHandle.clearSelection()
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
            terminalHandle.clearSelection()
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
            terminalHandle.clearSelection()
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
        alert.messageText = "End this smart orchestration run?"
        alert.informativeText = run.mode == .automatic
            ? "This stops automatic advancement. It does not send Control-C; work already running in the current agent pane remains visible and can be interrupted separately."
            : "This stops Parley's sequence tracking. It does not send Control-C or cancel work already running in any agent pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Workflow")
        alert.addButton(withTitle: "Keep Running")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            automaticOrchestrationTasks[run.id]?.cancel()
            automaticOrchestrationTasks[run.id] = nil
            _ = try supervisedWorkflowStore.interrupt(
                id: run.id,
                detail: run.mode == .automatic
                    ? "The person stopped Auto orchestration. No agent process was interrupted automatically."
                    : "The person ended workflow tracking. No agent process was interrupted automatically."
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
                workspaceID: workspace.workspaceID,
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
        alert.informativeText = "This replaces edits to all five local handoff recipes. Running panes and collaboration history are unchanged."
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
              let workspace = workspaces.first(where: { $0.workspaceID == panes.first(where: { $0.id == run.leadPaneID })?.workspaceID }) else {
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
                workspaceID: workspace.workspaceID,
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
        candidates: [WorkbenchPane]
    ) throws -> [WorkbenchPane] {
        guard HandoffRecipeTargeting.canSatisfy(recipe, with: candidates) else {
            throw RelayUIError.message(HandoffRecipeTargeting.unavailableMessage(for: recipe))
        }

        let alert = NSAlert()
        alert.messageText = "Targets for \(recipe.name)"
        alert.informativeText = HandoffRecipeTargeting.pickerMessage(for: recipe)
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        if recipe.targetRequirements.allowsMultiple {
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
            if let rejection = HandoffRecipeTargeting.rejection(for: recipe, selected: selected) {
                throw RelayUIError.message(rejection)
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
        candidates: [WorkbenchPane]
    ) -> (reviewer: WorkbenchPane, verifier: WorkbenchPane, mode: SmartOrchestrationMode)? {
        guard !candidates.isEmpty else { return nil }
        let titles = candidates.map { "\($0.displayName) · \($0.kind.label) (\($0.id))" }
        let reviewerPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        reviewerPicker.addItems(withTitles: titles)
        let verifierPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        verifierPicker.addItems(withTitles: titles)
        if candidates.count > 1 { verifierPicker.selectItem(at: 1) }
        let modePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        modePicker.addItems(withTitles: SmartOrchestrationMode.allCases.map(\.label))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(NSTextField(labelWithString: "Run mode"))
        stack.addArrangedSubview(modePicker)
        stack.addArrangedSubview(NSTextField(labelWithString: "Independent plan reviewer"))
        stack.addArrangedSubview(reviewerPicker)
        stack.addArrangedSubview(NSTextField(labelWithString: "Independent implementation verifier"))
        stack.addArrangedSubview(verifierPicker)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 142)

        let alert = NSAlert()
        alert.messageText = "Configure Smart Orchestration"
        alert.informativeText = "Auto advances only from correlated Parley answers and always stops for your final decision. Both roles must use a pane different from the workspace lead."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (
            candidates[max(0, reviewerPicker.indexOfSelectedItem)],
            candidates[max(0, verifierPicker.indexOfSelectedItem)],
            SmartOrchestrationMode.allCases[max(0, modePicker.indexOfSelectedItem)]
        )
    }

    private func workflowParticipant(_ pane: WorkbenchPane) -> SupervisedWorkflowParticipant {
        SupervisedWorkflowParticipant(
            paneID: pane.id,
            name: pane.displayName,
            kind: pane.kind,
            workspaceID: pane.workspaceID
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
    ) throws -> WorkbenchPane {
        guard let pane = pane(for: participant),
              pane.kind == participant.kind,
              pane.kind.isAgent,
              pane.isStarted,
              !pane.isDead,
              pane.relayEnabled,
              pane.hasCurrentProtocol,
              pane.inputAvailable else {
            throw RelayUIError.message(
                "The workflow \(role) \(participant.name) is not currently ready. Restart or replace that pane, or end the workflow explicitly."
            )
        }
        return pane
    }

    private func reloadSupervisedWorkflows() throws {
        supervisedWorkflowRuns = try supervisedWorkflowStore.runs()
    }


    private func reloadWorkspaceBriefs() throws {
        workspaceBriefs = try workspaceBriefStore.briefs()
    }

    private func reloadPinnedContextSnippets() throws {
        pinnedContextSnippets = try pinnedContextSnippetStore.snippets()
    }

    private func requestPaneChoice(
        title: String,
        message: String,
        actionLabel: String,
        candidates: [WorkbenchPane],
        selection: PaneChoiceRequest.Selection,
        completion: @escaping ([WorkbenchPane]) -> Void
    ) {
        paneChoiceRequest = PaneChoiceRequest(
            title: title,
            message: message,
            actionLabel: actionLabel,
            candidates: candidates,
            selection: selection,
            completion: completion
        )
    }

    /// Continues the flow that asked for a choice once the sheet has closed,
    /// so any follow-up confirmation presents against a settled window.
    func resolvePaneChoice(_ selected: [WorkbenchPane]) {
        guard let request = paneChoiceRequest else { return }
        paneChoiceRequest = nil
        DispatchQueue.main.async { request.completion(selected) }
    }

    func cancelPaneChoice() {
        paneChoiceRequest = nil
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
                "The app-resident core is unavailable, so Parley cannot establish trusted capture provenance."
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
            throw RelayUIError.message("The app-resident core captured no context sources.")
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
        guard let consultation = activePaneConsultations.first else { return }
        returnConsultation(consultation)
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
            terminalHandle.clearSelection()
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
            kind: handoff.kind == .commandRun ? "command run" : (handoff.kind == .delegate ? "delegation" : "Ask"),
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
            if activeWorkspace?.workspaceID != pane.workspaceID {
                try controller.selectWorkspace(pane.workspaceID)
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

    func rename(_ pane: WorkbenchPane) {
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

    func setRole(_ pane: WorkbenchPane) {
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
            try controller.setPaneRole(role, paneID: pane.id, workspaceID: pane.workspaceID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func clearRole(_ pane: WorkbenchPane) {
        perform {
            guard let controller else { return }
            try controller.setPaneRole(nil, paneID: pane.id, workspaceID: pane.workspaceID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func mobilityDestinations(for pane: WorkbenchPane) -> [WorkbenchWorkspace] {
        workspaces.filter { $0.workspaceID != pane.workspaceID }
    }

    func movePane(_ pane: WorkbenchPane, to targetWorkspace: WorkbenchWorkspace) {
        perform {
            guard let controller else { return }
            try refresh()
            guard let currentPane = panes.first(where: { $0.id == pane.id }) else {
                throw ParleyWorkbenchError.paneNotFound(pane.id)
            }
            guard let currentTarget = workspaces.first(where: { $0.id == targetWorkspace.id }) else {
                throw ParleyWorkbenchError.workspaceNotFound(targetWorkspace.id)
            }
            let activeCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            let assessment = PaneMobilityPolicy.assess(
                action: .move,
                pane: currentPane,
                targetWorkspaceID: currentTarget.workspaceID,
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
            alert.informativeText = "Parley will transfer the exact live Ghostty pane. \(preservedState) Its pane id, terminal state and folder (\(currentPane.cwd)) are unchanged. The target workspace’s \(currentTarget.automationPolicy.label) automation policy applies after the move. The source workspace remains open."
            alert.alertStyle = .warning
            let affectedWorkspaces = [
                workspaces.first(where: { $0.workspaceID == currentPane.workspaceID }),
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
            // core again and let WorkbenchController repeat every structural check
            // against a fresh pane list immediately before join-pane.
            let finalActiveCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            _ = try controller.movePane(
                currentPane.id,
                toWorkspaceID: currentTarget.id,
                activeHandoffCount: finalActiveCount
            )
            try refresh()
            terminalHandle.focus()
        }
    }

    func clonePaneConfiguration(_ pane: WorkbenchPane, to targetWorkspace: WorkbenchWorkspace) {
        perform {
            guard let controller else { return }
            try refresh()
            guard let currentPane = panes.first(where: { $0.id == pane.id }) else {
                throw ParleyWorkbenchError.paneNotFound(pane.id)
            }
            guard let currentTarget = workspaces.first(where: { $0.id == targetWorkspace.id }) else {
                throw ParleyWorkbenchError.workspaceNotFound(targetWorkspace.id)
            }
            let activeCount = try verifiedActiveHandoffCount(for: currentPane, required: true)
            let assessment = PaneMobilityPolicy.assess(
                action: .clone,
                pane: currentPane,
                targetWorkspaceID: currentTarget.workspaceID,
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
                activeHandoffCount: finalActiveCount
            )
            try refresh()
            terminalHandle.focus()
        }
    }

    private func verifiedActiveHandoffCount(for pane: WorkbenchPane, required: Bool) throws -> Int {
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
        pane: WorkbenchPane,
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

    func confirmCopilotFolderTrust(_ pane: WorkbenchPane) {
        let alert = NSAlert()
        alert.messageText = "Has Copilot finished folder trust?"
        alert.informativeText = "First resolve the folder-trust prompt in \(pane.displayName). Confirm only when Copilot is showing its normal input prompt for \(pane.cwd). This enables Parley handoffs for this session; Copilot still owns its permissions."
        alert.addButton(withTitle: "Enable Handoffs")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try controller?.confirmCopilotFolderTrust(paneID: pane.id, expectedGeneration: pane.launchGeneration, expectedFolder: pane.cwd)
            try refresh()
        } catch { NSAlert(error: error).runModal() }
    }

    func restart(_ pane: WorkbenchPane) {
        let alert = NSAlert()
        alert.messageText = "Restart \(pane.displayName)?"
        alert.informativeText = pane.kind.isAgent
            ? "The current process will stop and a fresh \(pane.kind.label) session will start. Restart never restores vendor conversation history; choose Resume instead if you want the vendor to offer its saved sessions."
            : "The current process in this pane will be stopped and relaunched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if pane.kind.isAgent {
            let workspace = workspaces.first { $0.workspaceID == pane.workspaceID }
            panePermissionRequest = PanePermissionRequest(
                kind: pane.kind,
                folder: pane.cwd,
                workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
                workspaceFolders: workspace?.attachedFolders ?? [],
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
                workspaceID: pane.workspaceID,
                workspaceName: pane.workspaceName ?? pane.workspaceID,
                paneID: pane.id,
                paneName: pane.displayName,
                paneKind: pane.kind,
                detail: "\(pane.kind.label) pane restarted."
            ))
            try refresh()
        }
    }

    func resume(_ pane: WorkbenchPane) {
        guard let plan = VendorResumeAdapter.plan(for: pane.kind) else { return }

        let alert = NSAlert()
        alert.messageText = pane.isStarted
            ? "Replace \(pane.displayName) with \(plan.menuLabel.dropLast())?"
            : "\(plan.menuLabel.dropLast()) in \(pane.displayName)?"
        let explanation: [String?] = [
            pane.isStarted ? "The current process in this pane will stop." : nil,
            plan.detail,
            "Parley keeps this pane's working folder and reviews permissions before launch. If no saved conversation is suitable, cancel or exit the vendor UI and use Restart for a fresh session.",
        ]
        alert.informativeText = explanation.compactMap { $0 }.joined(separator: " ")
        alert.alertStyle = pane.isStarted ? .warning : .informational
        alert.addButton(withTitle: "Review Permissions")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let workspace = workspaces.first { $0.workspaceID == pane.workspaceID }
        if !pane.isStarted, workspace?.isFolderless == true, workspace?.newPaneFolder == nil {
            let panel = NSOpenPanel()
            panel.title = "Choose a working folder for \(pane.displayName)"
            panel.message = "Resume remains vendor-owned. This folder scopes the stopped pane and its permission review; it is not attached to the workspace."
            panel.prompt = "Continue"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: pane.cwd)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let folder = url.standardizedFileURL.path
            do {
                try controller?.setStoppedPaneFolder(pane.id, folder: folder)
                try refresh()
                rememberFolder(folder)
                panePermissionRequest = PanePermissionRequest(
                    kind: pane.kind,
                    folder: folder,
                    workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
                    workspaceFolders: workspace?.attachedFolders ?? [],
                    action: .resume(paneID: pane.id, replacingRunningProcess: false),
                    existingSelection: nil
                )
            } catch {
                NSAlert(error: error).runModal()
            }
            return
        }
        panePermissionRequest = PanePermissionRequest(
            kind: pane.kind,
            folder: pane.cwd,
            workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
            workspaceFolders: workspace?.attachedFolders ?? [],
            action: .resume(paneID: pane.id, replacingRunningProcess: pane.isStarted),
            existingSelection: pane.permissionSelection
        )
    }

    func start(_ pane: WorkbenchPane) {
        guard pane.kind.isAgent else { return }
        let workspace = workspaces.first { $0.workspaceID == pane.workspaceID }
        if workspace?.isFolderless == true, workspace?.newPaneFolder == nil {
            let panel = NSOpenPanel()
            panel.title = "Choose a working folder for \(pane.displayName)"
            panel.message = "This sets the stopped pane's working directory only. The permission review follows; the folder is not attached to the workspace."
            panel.prompt = "Continue"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: pane.cwd)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let folder = url.standardizedFileURL.path
            do {
                try controller?.setStoppedPaneFolder(pane.id, folder: folder)
                try refresh()
                rememberFolder(folder)
                panePermissionRequest = PanePermissionRequest(
                    kind: pane.kind,
                    folder: folder,
                    workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
                    workspaceFolders: workspace?.attachedFolders ?? [],
                    action: .start(pane.id),
                    existingSelection: nil
                )
            } catch {
                NSAlert(error: error).runModal()
            }
            return
        }
        panePermissionRequest = PanePermissionRequest(
            kind: pane.kind,
            folder: pane.cwd,
            workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
            workspaceFolders: workspace?.attachedFolders ?? [],
            action: .start(pane.id),
            existingSelection: pane.permissionSelection
        )
    }

    func showFolderAccess(_ pane: WorkbenchPane) {
        guard pane.kind.isAgent else { return }
        guard pane.isStarted else {
            start(pane)
            return
        }
        let workspace = workspaces.first { $0.workspaceID == pane.workspaceID }
        panePermissionRequest = PanePermissionRequest(
            kind: pane.kind,
            folder: pane.cwd,
            workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
            workspaceFolders: workspace?.attachedFolders ?? [],
            action: .folderAccess(pane.id),
            existingSelection: pane.permissionSelection
        )
    }

    func close(_ pane: WorkbenchPane) {
        let alert = NSAlert()
        alert.messageText = "Close \(pane.displayName)?"
        alert.informativeText = "This ends the app-resident pane process. It cannot be recovered from Parley."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let closesWorkspace = panes.filter { $0.workspaceID == pane.workspaceID }.count == 1
        perform {
            try controller?.closePane(pane.id)
            if focusCanvasPaneID == pane.id { focusCanvasPaneID = nil }
            if handoffComposerDraft?.sourcePaneID == pane.id || handoffComposerDraft?.targetPaneID == pane.id {
                handoffComposerDraft = nil
            }
            if closesWorkspace {
                try? workspaceRegistry.remove(workspaceID: pane.workspaceID)
                nativeLayouts.removeValue(forKey: pane.workspaceID)
                nativeSplitFractions.removeValue(forKey: pane.workspaceID)
            }
            try refresh()
        }
    }

    func balance() {
        guard let workspace = activeWorkspace else { return }
        let leaves = representativeLeaves(workspaceID: workspace.workspaceID, in: panes)
        guard let tiled = NativeLayoutNode.tiled(leaves) else { return }
        nativeLayouts[workspace.workspaceID] = tiled
        try? workspaceRegistry.updateLayout(workspaceID: workspace.workspaceID, layout: tiled)
        resetNativeSplitFractions(workspaceID: workspace.workspaceID)
        terminalHandle.focus()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the New Pane Folder for \(activeWorkspace?.name ?? "this workspace")"
        panel.message = "Choose where newly created panes in this workspace should start. Running panes will not move or restart."
        panel.prompt = "Choose"
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
            let standardized = WorkspaceFolderIdentity.normalized(folder)
            try controller.setWorkspaceNewPaneFolder(workspace.id, folder: standardized)
            workspaceContinuity.updateWorkspace(
                from: workspace,
                to: WorkbenchWorkspace(
                    id: workspace.id,
                    name: workspace.name,
                    attachedFolders: workspace.attachedFolders,
                    newPaneFolder: standardized,
                    isActive: workspace.isActive,
                    automationPolicy: workspace.automationPolicy,
                    workspaceID: workspace.workspaceID
                )
            )
            saveWorkspaceContinuity()
            rememberFolder(standardized)
            try refresh()
        }
    }

    func clearWorkspaceNewPaneFolder() {
        perform {
            guard let controller, let workspace = activeWorkspace else { return }
            try controller.setWorkspaceNewPaneFolder(workspace.id, folder: nil)
            try refresh()
        }
    }

    func attachFolder(to workspace: WorkbenchWorkspace) {
        let panel = NSOpenPanel()
        panel.title = "Attach a folder to \(workspace.name)"
        panel.message = "Attached folders make this workspace discoverable from folder-opening routes. Existing panes and permissions are unchanged."
        panel.prompt = "Attach"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: workspace.newPaneFolder ?? activePane?.cwd ?? fallbackFolder)
        guard panel.runModal() == .OK else { return }
        perform {
            guard let controller else { return }
            for url in panel.urls {
                let folder = url.standardizedFileURL.path
                try controller.attachFolder(folder, toWorkspace: workspace.id)
                rememberFolder(folder)
            }
            try refresh()
        }
    }

    func detachFolder(_ folder: String, from workspace: WorkbenchWorkspace) {
        perform {
            try controller?.detachFolder(folder, fromWorkspace: workspace.id)
            try refresh()
        }
    }

    func moveAttachedFolder(_ folder: String, in workspace: WorkbenchWorkspace, by offset: Int) {
        perform {
            try controller?.moveAttachedFolder(folder, inWorkspace: workspace.id, by: offset)
            try refresh()
        }
    }

    func isFavouriteFolder(_ folder: String) -> Bool {
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        return favouriteFolders.contains {
            WorkspaceFolderIdentity.matches($0, standardized)
        }
    }

    func toggleFavouriteFolder(_ folder: String) {
        _ = workspaceContinuity.toggleFavourite(folder: folder)
        favouriteFolders = workspaceContinuity.favouriteFolders
        saveWorkspaceContinuity()
    }

    func addFavouriteFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a favourite folder"
        panel.message = "Bookmark a folder for quick workspace access without changing the active workspace."
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFavouriteFolder(url.standardizedFileURL.path)
    }

    func addFavouriteFolder(_ folder: String) {
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        _ = workspaceContinuity.addFavourite(folder: standardized)
        favouriteFolders = workspaceContinuity.favouriteFolders
        saveWorkspaceContinuity()
        rememberFolder(standardized)
    }

    func canMove(_ workspace: WorkbenchWorkspace, by offset: Int) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return false }
        return workspaces.indices.contains(index + offset)
    }

    func move(_ workspace: WorkbenchWorkspace, by offset: Int) {
        let moved = workspaceContinuity.moveWorkspace(id: workspace.id, by: offset, in: workspaces)
        guard moved != workspaces else { return }
        workspaces = moved
        saveWorkspaceContinuity()
    }

    func moveWorkspaces(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard offsets.count == 1, let source = offsets.first,
              workspaces.indices.contains(source) else { return }
        let adjustedDestination = source < destination ? destination - 1 : destination
        guard workspaces.indices.contains(adjustedDestination), source != adjustedDestination else { return }
        move(workspaces[source], by: adjustedDestination - source)
    }

    func createWorkspace() {
        perform {
            guard let controller else { return }
            let launchFolder = activePane?.cwd ?? fallbackFolder
            let created = try controller.createFolderlessWorkspace(launchFolder: launchFolder)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceCreated,
                workspaceID: created.workspaceID,
                workspaceName: created.name,
                detail: "Created without folder attachments."
            ))
            try refresh()
            terminalHandle.focus()
        }
    }

    func openWorkspacePicker() {
        let panel = NSOpenPanel()
        panel.title = "Open a folder as a workspace"
        panel.message = "Choose a folder to focus its workspace, choose among matching workspaces, or open a new shell workspace."
        panel.prompt = "Open"
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

    func createNewWorkspace(folder: String) {
        perform {
            _ = try openWorkspace(folder: folder, forceNew: true)
        }
    }

    func openExternalWorkspace(_ request: ExternalWorkspaceOpenRequest) {
        // External authority ends at one validated local folder. The ordinary
        // workspace path may focus an existing workspace or create its shell;
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
                if activeWorkspace?.workspaceID != pane.workspaceID {
                    try controller.selectWorkspace(pane.workspaceID)
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
        let requestID = ExternalContextImport.requestIdentifier(
            file: file,
            applicationDirectory: applicationDirectory
        )
        do {
            guard let contextPackBuilder else { throw ExternalContextPresentationError.contextUnavailable }
            let imported = try ExternalContextImport.consume(
                file: file,
                applicationDirectory: applicationDirectory,
                builder: contextPackBuilder
            )
            let workspace = try openWorkspace(folder: imported.folder)
            let candidates = panes.filter {
                $0.workspaceID == workspace.workspaceID
                    && $0.kind.isAgent
                    && $0.isStarted
                    && !$0.isDead
                    && $0.relayEnabled
                    && $0.hasCurrentProtocol
            }
            guard let source = candidates.first(where: \.isActive) ?? candidates.first else {
                throw ExternalContextPresentationError.noReadyAgent
            }
            if let existing = contextPackDraft, !existing.pack.parts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Replace the current context pack?"
                alert.informativeText = "VS Code staged \(imported.parts.count) explicit source\(imported.parts.count == 1 ? "" : "s"). Replacing the current local draft cannot be undone; nothing has been sent."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open VS Code Context")
                alert.addButton(withTitle: "Keep Current Draft")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    publishExternalContextAcknowledgement(.rejected(
                        requestID: imported.requestID,
                        code: .declinedReplacement,
                        message: "Parley kept the existing context pack. Nothing was submitted."
                    ))
                    return
                }
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
            publishExternalContextAcknowledgement(.accepted(
                requestID: imported.requestID,
                workspaceID: workspace.workspaceID,
                sourceCount: imported.parts.count
            ))
        } catch {
            if let requestID {
                publishExternalContextAcknowledgement(
                    externalContextFailureAcknowledgement(requestID: requestID, error: error)
                )
            }
            NSAlert(error: error).runModal()
        }
    }

    private func externalContextFailureAcknowledgement(
        requestID: String,
        error: Error
    ) -> ExternalContextAcknowledgement {
        if let importError = error as? ExternalContextImportError {
            switch importError {
            case .expiredManifest:
                return .expired(requestID: requestID)
            case .unsupportedVersion:
                return .rejected(
                    requestID: requestID,
                    code: .unsupportedVersion,
                    message: "Update Parley and its VS Code companion together, then build the context pack again."
                )
            case .invalidItem:
                return .rejected(
                    requestID: requestID,
                    code: .invalidSource,
                    message: "One selected editor source could not be recaptured safely. Nothing was submitted."
                )
            case .unsafeManifest, .invalidManifest:
                return .rejected(
                    requestID: requestID,
                    code: .invalidRequest,
                    message: "Parley refused that editor context request. Nothing was submitted."
                )
            }
        }
        if let presentationError = error as? ExternalContextPresentationError {
            return .rejected(
                requestID: requestID,
                code: presentationError.code,
                message: presentationError.safeMessage
            )
        }
        if error is ContextPackError {
            return .rejected(
                requestID: requestID,
                code: .invalidSource,
                message: "One selected source could not be captured within Parley's context limits. Nothing was submitted."
            )
        }
        return .rejected(
            requestID: requestID,
            code: .internalError,
            message: "Parley could not open the editable context preview. Nothing was submitted."
        )
    }

    private func publishExternalContextAcknowledgement(
        _ acknowledgement: ExternalContextAcknowledgement
    ) {
        guard runtime.mode == .production else { return }
        do {
            try ExternalContextAcknowledgementFile.write(
                acknowledgement,
                applicationDirectory: applicationDirectory
            )
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "VS Code confirmation unavailable"
            alert.informativeText = "Parley could not publish the local one-shot confirmation. The context preview state shown in Parley is authoritative.\n\n\(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @discardableResult
    private func openWorkspace(folder: String, forceNew: Bool = false) throws -> WorkbenchWorkspace {
        guard let controller else {
            throw RelayUIError.message("Parley cannot open a workspace while its embedded terminal workbench is unavailable.")
        }
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        let choice: WorkspaceOpenChoice
        if forceNew {
            choice = .create
        } else {
            choice = switch WorkspaceFolderRouting.resolve(folder: standardized, in: workspaces) {
            case .create:
                .create
            case let .focus(workspaceID):
                .existing(workspaceID)
            case let .choose(workspaceIDs):
                try chooseWorkspace(for: standardized, workspaceIDs: workspaceIDs)
            }
        }
        let selectedID: String
        switch choice {
        case let .existing(workspaceID):
            try controller.selectWorkspace(workspaceID)
            selectedID = workspaceID
        case .create:
            let created = try controller.createWorkspace(folder: standardized)
            selectedID = created.id
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceCreated,
                workspaceID: created.workspaceID,
                workspaceName: created.name,
                detail: "Opened \(standardized)"
            ))
        }
        rememberFolder(standardized)
        try refresh()
        terminalHandle.focus()
        guard let selected = workspaces.first(where: { $0.id == selectedID }) else {
            throw RelayUIError.message("Parley opened the workspace but could not reconcile its live pane layout.")
        }
        return selected
    }

    private func chooseWorkspace(for folder: String, workspaceIDs: [String]) throws -> WorkspaceOpenChoice {
        let candidates = workspaceIDs.compactMap { id in
            workspaces.first(where: { $0.id == id })
        }
        guard candidates.count == workspaceIDs.count, candidates.count > 1 else {
            throw RelayUIError.message("The matching workspace list changed. Nothing was opened; try again.")
        }

        let alert = NSAlert()
        alert.messageText = "Several workspaces use this folder"
        alert.informativeText = "Choose the task workspace to open, or create another one at \(folder)."
        alert.addButton(withTitle: "Open Selected")
        alert.addButton(withTitle: "Open New Workspace")
        alert.addButton(withTitle: "Cancel")

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for workspace in candidates {
            picker.addItem(withTitle: workspace.name)
            picker.lastItem?.representedObject = workspace.id
        }
        if let activeIndex = candidates.firstIndex(where: \.isActive) {
            picker.selectItem(at: activeIndex)
        }
        alert.accessoryView = picker

        return switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let workspaceID = picker.selectedItem?.representedObject as? String {
                .existing(workspaceID)
            } else {
                throw RelayUIError.message("Parley could not identify the selected workspace. Nothing was opened.")
            }
        case .alertSecondButtonReturn:
            .create
        default:
            throw CancellationError()
        }
    }

    func rename(_ workspace: WorkbenchWorkspace) {
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
                to: WorkbenchWorkspace(
                    id: workspace.id,
                    name: renamed,
                    attachedFolders: workspace.attachedFolders,
                    newPaneFolder: workspace.newPaneFolder,
                    isActive: workspace.isActive,
                    automationPolicy: workspace.automationPolicy,
                    workspaceID: workspace.workspaceID
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

    func setAutomationPolicy(_ policy: WorkspaceAutomationPolicy, for workspace: WorkbenchWorkspace) {
        guard policy != workspace.automationPolicy else { return }
        perform {
            guard let controller else { return }
            try controller.setWorkspaceAutomationPolicy(workspace.id, policy: policy)
            try refresh()
            terminalHandle.focus()
        }
    }

    func setWorkspaceLead(_ pane: WorkbenchPane) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceLead(pane.id, workspaceID: pane.workspaceID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func clearWorkspaceLead(_ workspace: WorkbenchWorkspace) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceLead(nil, workspaceID: workspace.workspaceID)
            try refresh()
            terminalHandle.focus()
        }
    }

    func close(_ workspace: WorkbenchWorkspace) {
        let paneCount = panes.filter { $0.workspaceID == workspace.workspaceID }.count
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
            try? workspaceRegistry.remove(workspaceID: workspace.workspaceID)
            nativeLayouts.removeValue(forKey: workspace.workspaceID)
            nativeSplitFractions.removeValue(forKey: workspace.workspaceID)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceClosed,
                workspaceID: workspace.workspaceID,
                workspaceName: workspace.name,
                detail: "Closed \(paneCount) pane\(paneCount == 1 ? "" : "s")."
            ))
            try refresh()
            terminalHandle.focus()
        }
    }

    private func recordRestoredNativeLayout(
        _ saved: SavedLayoutNode,
        workspace: WorkbenchWorkspace
    ) {
        guard let controller else { return }
        guard let restoredPanes = try? controller.listPanes().filter({
            $0.workspaceID == workspace.workspaceID
        }) else { return }
        let paneIDs = WorkbenchIdentifierOrder.sorted(restoredPanes.map(\.id))
        guard let native = NativeLayoutNode.mirroring(saved, paneIDs: paneIDs) else { return }
        nativeLayouts[workspace.workspaceID] = native
        if let liveWorkspaces = try? controller.listWorkspaces() {
            _ = try? workspaceRegistry.synchronize(workspaces: liveWorkspaces)
        }
        try? workspaceRegistry.updateLayout(workspaceID: workspace.workspaceID, layout: native)
        resetNativeSplitFractions(workspaceID: workspace.workspaceID)
    }

    private func captureWorkspaceLayout(_ workspace: WorkbenchWorkspace) throws -> SavedWorkspaceLayout {
        guard controller != nil else {
            throw ParleyWorkbenchError.commandFailed("The embedded terminal workbench is unavailable.")
        }
        let workspacePanes = panes.filter { $0.workspaceID == workspace.workspaceID }
        let leaves = representativeLeaves(workspaceID: workspace.workspaceID, in: workspacePanes)
        guard let native = NativeLayoutNode.reconciled(
            nativeLayouts[workspace.workspaceID],
            with: leaves
        ) else {
            throw ParleyWorkbenchError.commandFailed("The workspace has no layout to save.")
        }
        let paneByID = Dictionary(uniqueKeysWithValues: workspacePanes.map { ($0.id, $0) })
        func saved(_ node: NativeLayoutNode) throws -> SavedLayoutNode {
            switch node {
            case let .leaf(paneID):
                guard let pane = paneByID[paneID] else {
                    throw ParleyWorkbenchError.paneNotFound(paneID)
                }
                return .leaf(SavedLayoutLeaf(
                    kind: pane.kind,
                    name: pane.displayName,
                    folder: pane.cwd,
                    role: pane.role,
                    isWorkspaceLead: pane.isWorkspaceLead,
                    permissionSelection: pane.permissionSelection
                ))
            case let .split(direction, first, second):
                return .split(
                    direction: direction,
                    ratio: 0.5,
                    first: try saved(first),
                    second: try saved(second)
                )
            }
        }
        return SavedWorkspaceLayout(
            name: workspace.name,
            defaultFolder: workspace.newPaneFolder
                ?? workspacePanes.first(where: \.isActive)?.cwd
                ?? workspacePanes.first?.cwd
                ?? fallbackFolder,
            root: try saved(native),
            automationPolicy: workspace.automationPolicy
        )
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
            let captured = try captureWorkspaceLayout(workspace)
            try teamTemplateStore.save(try TeamTemplate.capturing(captured, name: name))
            teamTemplates = try teamTemplateStore.templates()
            terminalHandle.focus()
        }
    }

    func createWorkspace(from layout: SavedWorkspaceLayout) {
        perform {
            guard let controller else { return }
            let restored = try controller.restoreWorkspaceLayout(layout)
            recordRestoredNativeLayout(layout.root, workspace: restored)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceRestored,
                workspaceID: restored.workspaceID,
                workspaceName: restored.name,
                detail: "Created from saved layout \(layout.name); shells started and agent panes left stopped."
            ))
            rememberFolder(layout.defaultFolder)
            try refresh()
            terminalHandle.focus()
        }
    }

    func apply(_ template: TeamTemplate) {
        let choice = NSAlert()
        choice.messageText = "Create \(template.name) workspace"
        choice.informativeText = "A folderless team keeps every agent stopped and unbound until you explicitly choose its working folder and permissions. Choosing a folder binds every template pane to that folder."
        choice.addButton(withTitle: "Create Folderless")
        choice.addButton(withTitle: "Choose Folder…")
        choice.addButton(withTitle: "Cancel")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let folderless = response == .alertFirstButtonReturn
        let launchFolder: String
        let workspaceName: String
        if folderless {
            launchFolder = activePane?.cwd ?? fallbackFolder
            workspaceName = availableWorkspaceName(template.name)
        } else {
            let panel = NSOpenPanel()
            panel.title = "Apply \(template.name) to a folder"
            panel.prompt = "Create Team Workspace"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: defaultFolder)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            launchFolder = url.standardizedFileURL.path
            let baseName = url.lastPathComponent.isEmpty ? template.name : url.lastPathComponent
            workspaceName = availableWorkspaceName(baseName)
        }

        perform {
            guard let controller else { return }
            let layout = try folderless
                ? template.folderlessWorkspaceLayout(
                    launchFolder: launchFolder,
                    workspaceName: workspaceName
                )
                : template.workspaceLayout(folder: launchFolder, workspaceName: workspaceName)
            let restored = try controller.restoreWorkspaceLayout(layout, folderless: folderless)
            recordRestoredNativeLayout(layout.root, workspace: restored)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceRestored,
                workspaceID: restored.workspaceID,
                workspaceName: restored.name,
                detail: folderless
                    ? "Applied team template \(template.name) without folder attachments; agent panes left stopped and unbound."
                    : "Applied team template \(template.name); agent panes left stopped."
            ))
            if !folderless { rememberFolder(launchFolder) }
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

    func saveLayout(of workspace: WorkbenchWorkspace) {
        let alert = NSAlert()
        alert.messageText = "Save workspace layout"
        alert.informativeText = "Saves pane kinds, names, folders and split structure. Native divider positions reopen balanced until divider persistence lands. Running processes, terminal contents and credentials are never stored."
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
            let captured = try captureWorkspaceLayout(workspace)
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

    func open(
        _ layout: SavedWorkspaceLayout,
        replacing requestedWorkspace: WorkbenchWorkspace? = nil
    ) {
        let workspace = requestedWorkspace ?? activeWorkspace
        let paneCount = workspace.map { selected in panes.count { $0.workspaceID == selected.workspaceID } } ?? 0
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
            let restored = try controller.restoreWorkspaceLayout(
                layout,
                replacing: workspace?.id
            )
            recordRestoredNativeLayout(layout.root, workspace: restored)
            try recordSuccessfulActivity(RelayActivityEventRequest(
                kind: .workspaceRestored,
                workspaceID: restored.workspaceID,
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
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        recentFolders.removeAll {
            WorkspaceFolderIdentity.matches($0, standardized)
        }
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

    private func sendReview(_ draft: ReviewDraft, from source: WorkbenchPane, to target: WorkbenchPane) throws {
        guard let controller else { return }
        guard let edited = editRelay(
            title: "\(draft.title) with \(target.displayName)",
            message: "Review exactly what will be submitted. This uses Parley's normal attributed Ask path; nothing else from the terminal or repository is copied automatically.",
            text: draft.text,
            action: "Ask for Review",
            insertVisible: { try controller.capturePane(source.id) }
        ) else { return }
        try submitOrOfferBusyQueue(
            edited,
            from: source,
            to: target,
            preserveFormatting: false
        )
        try refresh()
        terminalHandle.clearSelection()
        terminalHandle.focus()
    }

    private func submitOrOfferBusyQueue(
        _ text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool
    ) throws {
        let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
        let knownHistory = statusHandoffs.isEmpty ? handoffs : statusHandoffs
        let targetIsBusy = knownHistory.contains {
            $0.targetPaneID == target.id && activeStates.contains($0.state)
        }
        guard targetIsBusy else {
            try launchTrackedAsk(
                text,
                from: source,
                to: target,
                preserveFormatting: preserveFormatting
            )
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(target.displayName) Already Has Tracked Work"
        alert.informativeText = "Keep this exact reviewed Ask in Parley's local busy queue? It remains visible and unsent. When \(target.displayName) becomes idle, Parley will still wait for you to reopen, review and explicitly send it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Reviewed Draft")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so Parley cannot keep this draft safely.")
        }
        _ = try relayClient.enqueueReviewedBusyDraft(ReviewedBusyDraftCreateRequest(
            sourcePaneID: source.id,
            targetPaneID: target.id,
            text: text,
            preserveFormatting: preserveFormatting
        ))
    }

    private func launchTrackedAsk(
        _ text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool
    ) throws {
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so this reviewed Ask was not sent.")
        }
        let idempotencyKey = UUID().uuidString.lowercased()
        Task { [weak self] in
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.askFromUI(
                        sourcePaneID: source.id,
                        targetPaneID: target.id,
                        text: text,
                        idempotencyKey: idempotencyKey,
                        preserveFormatting: preserveFormatting
                    )
                }.value
                self?.refreshStatusCenterQuietly()
                guard response.status == 200 else {
                    throw RelayUIError.message(response.text)
                }
            } catch {
                self?.refreshStatusCenterQuietly()
                NSAlert(error: error).runModal()
            }
        }
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
        } catch is CancellationError {
            return
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

private enum ExternalContextPresentationError: LocalizedError {
    case contextUnavailable
    case noReadyAgent

    var code: ExternalContextAcknowledgementCode {
        switch self {
        case .contextUnavailable: .contextUnavailable
        case .noReadyAgent: .noReadyAgent
        }
    }

    var safeMessage: String {
        switch self {
        case .contextUnavailable:
            "Parley's context preview is unavailable while the workbench is starting. Nothing was submitted."
        case .noReadyAgent:
            "Start a ready agent pane in that workspace, then build the context pack again. Nothing was submitted."
        }
    }

    var errorDescription: String? {
        switch self {
        case .contextUnavailable:
            "Context capture is unavailable while Parley is starting."
        case .noReadyAgent:
            "Parley opened this workspace, but it has no ready agent pane. Start the pane you want to send from, then run the VS Code command again. Nothing was submitted."
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

        let insert = NSButton(title: "Insert Selection", target: self, action: #selector(insertVisiblePane))
        insert.bezelStyle = .rounded
        insert.controlSize = .small
        insert.frame = NSRect(x: 0, y: 0, width: 145, height: 28)
        insert.toolTip = "Insert the text currently selected in this Ghostty pane. Terminal scrollback is never captured implicitly."
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
