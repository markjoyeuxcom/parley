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

enum PanePermissionAction: Equatable {
    case create(SplitDirection)
    case restart(String)
    case resume(paneID: String, replacingRunningProcess: Bool)
    case start(String)
    case folderAccess(String)
}

struct PanePermissionRequest: Identifiable, Equatable {
    let id = UUID()
    /// Mutable because a creation review lets the person change the vendor;
    /// the id stays, so the review still matches the request it was opened for.
    var kind: PaneKind
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
    var voiceSource: VoiceDestination?
    var voiceTarget: VoiceDestination?
    var voiceKind: VoiceHandoffRequest.Kind?
    var actionLabel: String { voiceKind?.rawValue.capitalized ?? relationship?.label ?? "Ask" }

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
    @Published private(set) var panes: [WorkbenchPane] = [] {
        didSet { attentionInputGeneration &+= 1; statusInputGeneration &+= 1; voiceController?.reconcile(panes: panes) }
    }
    @Published private(set) var workspaces: [WorkbenchWorkspace] = [] {
        // The workspace activity index maps each workspace's ids.
        didSet { attentionInputGeneration &+= 1 }
    }
    /// The person's workspace groups, in order (All Workspaces).
    @Published private(set) var workspaceGroups: [WorkspaceGroup] = []
    @Published private(set) var commandRuns: [ReviewedCommandRun] = []
    @Published private(set) var commandRunGrants: [ReviewedCommandGrant] = []
    @Published private(set) var commandRunError: String?
    @Published private(set) var commandRunsPresented = false
    @Published private(set) var selectedCommandRunID: String?
    private var commandRunAttention = ReviewedCommandRunAttention()
    private var pendingCommandRunIDs: [String] {
        commandRuns.filter { $0.state == .pending }.map(\.id)
    }
    @Published private(set) var teamSessions: [TeamSession] = []
    @Published private(set) var teamSessionError: String?
    @Published private(set) var teamSessionsPresented = false
    @Published private(set) var selectedTeamSessionID: String?
    private var teamSessionAttention = ReviewedCommandRunAttention()
    private var pendingTeamSessionIDs: [String] {
        teamSessions.filter { $0.state == .pending }.map(\.id)
    }
    @Published private(set) var consultations: [RelayConsultation] = []
    @Published private(set) var handoffs: [RelayHandoff] = [] {
        didSet { attentionInputGeneration &+= 1; statusInputGeneration &+= 1 }
    }
    @Published private(set) var unreadHandoffs: [RelayHandoff] = [] {
        didSet { attentionInputGeneration &+= 1 }
    }
    /// Status Center's history and the tick's short list, newest record per
    /// handoff. Status Center's list stops refreshing when its window closes,
    /// so reading either one alone could show stale busy state or miss a
    /// handoff that just finished (review of 22 Sep 2026, M9).
    var latestKnownHandoffs: [RelayHandoff] { ReviewedAskHistory.newestPerHandoff(statusHandoffs, handoffs) }

    @Published private(set) var statusHandoffs: [RelayHandoff] = [] {
        didSet { attentionInputGeneration &+= 1; statusInputGeneration &+= 1 }
    }
    @Published private(set) var statusActivityEvents: [RelayActivityEvent] = [] {
        didSet { statusInputGeneration &+= 1 }
    }
    @Published private(set) var reviewedBusyDrafts: [ReviewedBusyDraft] = []
    @Published private(set) var controller: WorkbenchController?
    @Published private(set) var recentFolders: [String] = []
    @Published private(set) var favouriteFolders: [String] = []
    @Published private(set) var projectContexts: [String: GitProjectContext] = [:]
    @Published private(set) var worktreeScan: GitWorktreeScan = .empty
    @Published private(set) var savedLayouts: [SavedWorkspaceLayout] = []
    @Published private(set) var recipes: [HandoffRecipe] = []
    @Published private(set) var permissionProfiles: [PermissionProfileDefinition] = []
    @Published private(set) var activeRecipeRun: ActiveRecipeRun?
    @Published private(set) var askManyComparisonRun: AskManyComparisonRun?
    @Published private(set) var contextPackDraft: ActiveContextPack? {
        didSet { syncPersonImageHolds() }
    }
    @Published private(set) var contextReviews: [AgentContextReview] = []
    @Published private(set) var contextCommandCapturing = false
    /// One capture into the open context pack at a time: trusted capture into
    /// an agent draft (the core records the part as soon as it runs, so a
    /// second click would add a duplicate) or the person's own Git Diff.
    @Published private(set) var contextCaptureInFlight = false
    /// Review Changes is reading the repository; a second click waits.
    private var reviewDraftInFlight = false
    /// Folder comparisons and existence checks for views, remembered for a
    /// few seconds so the sidebar does not realpath and stat while it draws.
    let folderIdentity = FolderIdentityMemo()
    /// Retry Delivery requests still waiting on the core; a second retry of
    /// the same handoff would only be refused.
    private var retryingHandoffIDs: Set<String> = []

    /// Any capture into the open pack is still running. Sending, comparing,
    /// declining or adding another source waits for it: an agent draft's
    /// revision changes when the capture lands, and a pack sent now would
    /// miss the source being added.
    var contextPackCaptureRunning: Bool { contextCaptureInFlight || contextCommandCapturing }
    @Published private(set) var coreAvailable = false {
        didSet { statusInputGeneration &+= 1 }
    }
    /// Whether the peer-verified ticket socket is listening; the launch
    /// review's attestation line reads this at review time.
    var ticketSocketListening: Bool { residentCore?.ticketServer.isListening ?? false }
    @Published private(set) var terminalAvailable = false
    @Published private(set) var coreError: String?
    @Published private(set) var historyPersistenceError: String?
    @Published private(set) var terminalError: String?
    @Published private(set) var notificationWorkspaceNames: Set<String> = []
    @Published private(set) var dismissedHandoffIDs: Set<String> = [] {
        didSet { statusInputGeneration &+= 1 }
    }
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
    /// The terminal type panes advertise from their next start or restart.
    @Published private(set) var terminalTypePreference = TerminalTypePreference.default
    /// The person's choice to approve agent command runs without a preview.
    /// Native memory only, reset when the app quits; never restored from disk.
    var automaticCommandRunApprovalEnabled: Bool { commandRunAuthorization.automaticApproval }
    /// The person's choice to end a clean run's pane instead of handing it to a shell.
    var automaticCommandRunPaneCloseEnabled: Bool { commandRunAuthorization.closeCleanPanes }
    /// Automatic pane closes that failed or closed without restoring focus,
    /// per run, so one run's success never erases another run's explanation.
    @Published private(set) var commandRunPaneCloseErrors: [String: String] = [:]
    var commandRunPaneCloseError: String? {
        commandRunPaneCloseErrors.isEmpty ? nil : commandRunPaneCloseErrors.keys.sorted().compactMap { commandRunPaneCloseErrors[$0] }.joined(separator: "\n")
    }
    @Published private var commandRunAuthorization = CommandRunAuthorizationSession()
    private var commandRunPaneCleanup = CommandRunPaneCleanup()
    /// Closing a pane makes Ghostty report the close synchronously, which
    /// refreshes the model from inside the close; the cleanup pass must not
    /// run again inside itself.
    private var closingCommandRunPanes = false
    @Published private(set) var automaticUpdatesAvailable = false
    @Published private(set) var automaticUpdateChecksEnabled = false
    @Published private(set) var automaticUpdateCanCheck = false
    @Published private(set) var automaticUpdateDetail = "Automatic updates require an installed, notarized Production build."
    @Published private(set) var selectedSettingsSection = ApplicationSettingsSection.general
    @Published private(set) var settingsOpenRequestID: UUID?
    /// One-shot request for the root view to open Status Center, set together
    /// with `requestedStatusHandoffID` so the window opens on that handoff.
    /// Model code cannot call `openWindow`; the view observes this instead.
    @Published private(set) var statusCenterOpenRequestID: UUID?
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
    /// Everything, or only workspaces (Go to Workspace).
    @Published private(set) var commandPaletteScope: CommandPaletteScope = .everything
    @Published var setupPresented = false
    @Published var panePermissionRequest: PanePermissionRequest?
    @Published var askManyComparisonPresented = false
    @Published var contextPackPresented = false
    @Published var folderManagerPresented = false
    @Published var releaseLifecyclePresented = false
    @Published var betaFeedbackPresented = false
    @Published var focusCanvasPaneID: String?
    @Published var collaborationDockVisible = true
    @Published var handoffComposerDraft: HandoffComposerDraft?
    @Published private(set) var requestedHelpTopicID: String?
    @Published private(set) var requestedStatusHandoffID: String?
    /// A one-shot request for Status Center to show a segment when it opens or
    /// is already open elsewhere; consumed by the view once applied.
    @Published private(set) var requestedStatusCenterSegment: StatusCenterSegment?
    @Published var startupError: String?
    @Published private(set) var startupRequiresQuit = false

    let runtime: ParleyRuntime
    let ghosttyRegistry = GhosttyPaneRegistry()
    private var voiceController: VoiceController?
    var voice: VoiceController {
        if let voiceController { return voiceController }
        let value = VoiceController(preferences: preferences); voiceController = value; return value
    }
    private var voiceShortcutHeld = false
    lazy var terminalHandle = TerminalHandle(
        selectedText: { [weak self] in self?.ghosttyRegistry.selectedText() },
        focus: { [weak self] in _ = self?.ghosttyRegistry.focusSelected() },
        clearSelection: { [weak self] in
            _ = self?.ghosttyRegistry.selectedView?.performBindingAction("clear_selection")
        }
    )
    private let fallbackFolder: String
    private let applicationDirectory: URL
    /// The core's image copies, read here only to preview a staged image.
    /// Parley's copies of staged images, read by previews off the main actor.
    var contextImageStore: ContextImageStore { ContextImageStore(directory: ContextImageStore.directory(applicationDirectory: applicationDirectory)) }
    private let preferences: UserDefaults
    private let runtimeLease: RuntimeUILease?
    private let layoutStore: SavedWorkspaceLayoutStore
    private let workspaceRegistry: WorkspaceRegistry
    private let recipeStore: HandoffRecipeStore
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
    /// Worktrees Parley created or bound to a team: ownership and base
    /// metadata only, never execution authority. Facts come from bounded
    /// background Git reads and are applied only when nothing moved meanwhile.
    @Published private(set) var managedWorktrees: [ManagedWorktreeRecord] = [] {
        didSet { managedWorktreesByPath = Dictionary(managedWorktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Exact canonical worktree root → record, for render-time lookups that
    /// must not touch the filesystem.
    private(set) var managedWorktreesByPath: [String: ManagedWorktreeRecord] = [:]
    @Published private(set) var managedWorktreeFacts: [String: ManagedWorktreeFacts] = [:]
    private var managedWorktreeStore: ManagedWorktreeStore?
    private var managedWorktreeService: ManagedWorktreeService?
    private var managedWorktreeFactsTask: Task<Void, Never>?
    private var managedWorktreeFactsGeneration = 0
    /// One native worktree mutation at a time. While a removal is in flight
    /// its path is published so pane starts and team provisioning inside that
    /// tree are refused instead of racing the delete.
    @Published private(set) var managedWorktreeMutation: ManagedWorktreeMutation?
    /// Replacing or dropping the control client invalidates every in-flight
    /// background result that was fetched through the old one.
    private var relayClient: RelayCoreClient? {
        didSet {
            refreshGate.invalidate()
            // A rebuilt core was built holding the person's pack's images
            // (`retainingPersonImages`); hold them again through it all the
            // same, so the app's record matches the core it now talks to.
            heldPersonImages = []
            syncPersonImageHolds()
        }
    }
    /// The periodic tick and the Status Center timer fetch off the main actor.
    /// One gate orders both channels against explicit refreshes and direct
    /// mutations, so a slower fetch that started earlier never overwrites
    /// state a human action just produced.
    private var refreshGate = RefreshSequenceGate()
    /// The broker revision the last applied relay snapshot was fetched at,
    /// and how many ticks skipped fetching since; see `RelayPollPolicy`.
    private var lastAppliedRelayRevision: UInt64?
    private var relayTicksSinceFetch = 0
    private var relayRefreshInFlight = false
    private var statusHistoryRefreshInFlight = false
    /// The same gate for Status Center's two-second history fetch (500
    /// handoffs and 500 activity records): unchanged broker state skips it.
    private var lastAppliedStatusRevision: UInt64?
    private var statusTicksSinceFetch = 0
    /// Bumped only when fetched history actually changed the model, so views
    /// can reconcile selection against the fetched state without idle publishes.
    @Published private(set) var statusHistoryRevision = 0
    private var residentCore: AppResidentCoordinationCore?
    private var reviewDraftBuilder: ReviewDraftBuilder?
    private var contextPackBuilder: ContextPackBuilder?
    private let notificationEpoch = Date()
    private var observedNotificationEventIDs: Set<String> = []
    private var runtimeReadinessTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var automaticUpdater: ParleyAutomaticUpdater?
    private var preparedForUninstall = false
    private var periodicRefreshTimer: Timer?
    /// One serial owner samples processes off the main actor; requests are
    /// numbered so a result is published only when it is the newest and the
    /// pane set it sampled is unchanged.
    private let taskManagerOwner = TaskManagerSamplingOwner()
    private var taskManagerSampling = TaskManagerSamplingCoordinator()
    /// Bumped whenever panes or any handoff collection change; the attention
    /// cache below is keyed on it so one sidebar pass shares one projection.
    private var attentionInputGeneration = 0
    private var attentionCache = PaneAttentionCache()
    private var workspaceActivityCache = WorkspaceActivityCache()
    /// Bumped whenever any input of Status Center's snapshot changes; the
    /// snapshot cache below is keyed on it, so a render projects each scope
    /// once however many times the view reads it.
    private var statusInputGeneration = 0
    private var statusSnapshotCache = StatusSnapshotCache()
    private var paneStatePublishScheduled = false
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
    private static let terminalTypePreferenceKey = "parley.terminalTypePreference"
    private static let terminalFontPreferenceKey = "parley.terminalFontPreference"
    private static let terminalAppearanceImportKey = "parley.terminalAppearanceImport"
    private static let projectContextRefreshInterval: TimeInterval = 5
    private static let worktreeRefreshInterval: TimeInterval = 15
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
        if let stored = preferences.string(forKey: Self.lastAgentVendorKey), let kind = PaneKind(rawValue: stored), kind.isAgent {
            lastAgentVendor = kind
        }
        if preferences.object(forKey: Self.collaborationDockVisibleKey) != nil {
            collaborationDockVisible = preferences.bool(forKey: Self.collaborationDockVisibleKey)
        }
        swiftPMCompatibilityEnabled = preferences.bool(forKey: Self.swiftPMCompatibilityKey)
        if let stored = preferences.string(forKey: Self.terminalTypePreferenceKey),
           let preference = TerminalTypePreference(rawValue: stored) {
            terminalTypePreference = preference
        }
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
        recipeStore = HandoffRecipeStore(
            file: applicationDirectory.appendingPathComponent("handoff-recipes.json")
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
        pruneMissingRecentFolders()
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
                swiftPMCompatibilityEnabled: swiftPMCompatibilityEnabled,
                terminalTypePreference: terminalTypePreference
            )
            try controller.bootstrap(
                cwd: defaultFolder,
                createIfMissing: true
            )
            let livePanes = try controller.listPanes()
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
                    transportDirectory: agentTransportDirectory,
                    permissionProfiles: { [permissionProfileStore] in try permissionProfileStore.profiles() }
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
            let worktreeStore = ManagedWorktreeStore(file: controller.applicationDirectory.appendingPathComponent("managed-worktrees.json"))
            managedWorktreeStore = worktreeStore
            managedWorktreeService = ManagedWorktreeService(store: worktreeStore, environment: controller.environment)
            reloadManagedWorktrees()
            reviewDraftBuilder = ReviewDraftBuilder(environment: controller.environment)
            contextPackBuilder = ContextPackBuilder(environment: controller.environment)
            workspaces = liveWorkspaces
            workspaceGroups = try controller.listWorkspaceGroups()
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
            ghosttyRegistry.onPaneTitleChanged = { [weak self] in
                self?.schedulePaneStatePublish()
            }
            controller.configureTerminalTransport(makeGhosttyTerminalTransport())
            reconcileNativeLayouts(workspaces: liveWorkspaces, panes: livePanes)
            savedLayouts = try layoutStore.layouts()
            rememberFolder(defaultFolder)
            scheduleProjectContextRefresh(force: true)
            schedulePaneListeningPortRefresh(force: true)
            scheduleWorktreeRefresh(force: true)
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
        // This repair runs on every non-Command keystroke, and it exists so a
        // terminal that lost first responder to a stray click gets it back. It
        // must never take keystrokes away from text the person is deliberately
        // editing: with the handoff composer open, or with any editable text
        // view as first responder (a SwiftUI TextEditor or a TextField's field
        // editor), the box looked dead because each key handed focus straight
        // back to the pane behind it.
        // A focused native control (including Dictate) owns its keyboard
        // activation too, even before a transcript has opened.
        guard handoffComposerDraft == nil, !voice.session.isPresented,
              !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl) else { return }
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
            voicePaste: { [weak self] paneID, text, submit, reviewed in
                try Self.onMainActorSync {
                    guard let self, let controller = self.controller else {
                        throw ParleyWorkbenchError.commandFailed("Parley is shutting down.")
                    }
                    try self.ghosttyRegistry.paste(text, into: paneID, submit: submit) {
                        let live = try controller.listPanes()
                        for snapshot in reviewed { _ = try snapshot.resolve(in: live) }
                    }
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

    // MARK: Settings and appearance

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


    // MARK: Quit-time choice

    /// Returns true when quitting may proceed. An owned runtime always offers
    /// an explicit choice to detach or stop, even when every agent is dead.
    /// Closing the main window is handled by AppDelegate and only hides it.
    /// Full application termination is the deliberate lifetime boundary for
    /// every retained Ghostty exec surface.
    func resolveTermination() async -> Bool {
        // End capture before the quit dialog; cancelling quit keeps the draft.
        voice.stopRecording(); voice.stopSpeaking()
        guard !applyingPanePermissions else {
            NSAlert(error: RelayUIError.message("Wait for the reviewed pane launch to finish before quitting.")).runModal()
            return false
        }
        if preparedForUninstall { return true }
        guard RuntimeTerminationPolicy.shouldOfferChoice(
            runtime: runtime,
            controllerAvailable: controller != nil
        ), let controller else {
            residentCore?.stop()
            ghosttyRegistry.stopAll()
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
                try await Task.detached(priority: .userInitiated) { try controller.prepareAllContainerStops() }.value
                try controller.shutdown()
                residentCore?.stop()
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

    /// True only while the Processes group is mounted in an active auxiliary
    /// window. No sample starts, restarts or stays queued while it is false.
    private var paneProcessSamplingActive = false

    func setPaneProcessSamplingActive(_ active: Bool) {
        guard paneProcessSamplingActive != active else { return }
        paneProcessSamplingActive = active
        if active { refreshTaskManager() }
    }

    func refreshTaskManager() {
        guard paneProcessSamplingActive, let generation = taskManagerSampling.request() else { return }
        startTaskManagerSample(generation: generation)
    }

    private func startTaskManagerSample(generation: Int) {
        let descriptors = taskManagerPaneDescriptors()
        let identity = TaskManagerSamplingPolicy.identity(of: panes)
        let applicationPID = ProcessInfo.processInfo.processIdentifier
        let owner = taskManagerOwner
        Task { @MainActor [weak self] in
            let snapshot = await owner.sample(applicationPID: applicationPID, paneDescriptors: descriptors)
            guard let self else { return }
            let outcome = self.taskManagerSampling.complete(generation: generation, sampledIdentity: identity,
                currentIdentity: TaskManagerSamplingPolicy.identity(of: self.panes))
            if outcome.publish, snapshot != self.taskManagerSnapshot { self.taskManagerSnapshot = snapshot }
            // A refresh requested while sampling ran, or a pane change that made
            // this result stale, gets one fresh sample instead of a dropped
            // request, but only while the Processes group is still active.
            if let next = outcome.restart {
                if self.paneProcessSamplingActive {
                    self.startTaskManagerSample(generation: next)
                } else {
                    self.taskManagerSampling.declineRestart()
                }
            }
        }
    }

    /// The Processes group's Refresh button: resample processes now and force
    /// one listener inspection past the sidebar throttle. The automatic timer
    /// uses `refreshTaskManager()` alone.
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
                    let handoffs = try relayClient.activeHandoffs()
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
                try await Task.detached(priority: .userInitiated) { try controller.prepareAllContainerStops() }.value
                try controller.shutdown()
                self.residentCore?.stop()
                self.relayClient = nil
                self.coreAvailable = false
                self.coreError = nil
                self.preparedForUninstall = true

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
        // A check still running was for the previous channel: its result
        // must not appear under this one.
        releaseTask?.cancel()
        releaseChecking = false
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
                guard !Task.isCancelled, let self, self.releaseChannel == channel else { return }
                self.releaseCheck = result
                self.releaseChecking = false
            } catch {
                guard !Task.isCancelled, let self, self.releaseChannel == channel else { return }
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

    /// Reaches a pane at its next start or restart; running panes keep the
    /// value they launched with, and Parley never restarts one for this.
    func setTerminalTypePreference(_ preference: TerminalTypePreference) {
        if preference == .default {
            preferences.removeObject(forKey: Self.terminalTypePreferenceKey)
        } else {
            preferences.set(preference.rawValue, forKey: Self.terminalTypePreferenceKey)
        }
        terminalTypePreference = preference
        controller?.setTerminalTypePreference(preference)
    }

    /// Native choices last for this app session only; disk state cannot grant them.
    func setAutomaticCommandRunApprovalEnabled(_ enabled: Bool) {
        commandRunAuthorization.automaticApproval = enabled
        residentCore?.commandRuns.setAutomaticApproval(enabled)
        try? refresh()
    }

    /// Applies only to runs staged after the choice changes.
    func setAutomaticCommandRunPaneCloseEnabled(_ enabled: Bool) {
        commandRunAuthorization.closeCleanPanes = enabled
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
        var history = latestKnownHandoffs
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

        var history = latestKnownHandoffs
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
            snapshot: attentionSnapshot(generatedAt: Date()),
            coreAvailable: coreAvailable
        )
    }

    var canNavigateWorkspaces: Bool { workspaces.count > 1 }

    var canNavigatePanes: Bool { visiblePanes.count > 1 }

    func projectContext(for pane: WorkbenchPane) -> GitProjectContext? {
        let folder = URL(fileURLWithPath: pane.launchWorkingDirectory).standardizedFileURL.path
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
            launchProfiles: controller?.runningPermissionDefinitions() ?? [:],
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

    func hasWorktreeWriterCollision(workspaceID: String) -> Bool {
        let aliases = workspaceAliases(for: workspaceID)
        return worktreeWriterCollisions.contains { collision in
            collision.writers.contains(where: { aliases.contains($0.workspaceID) })
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
        }
    }

    func canOpenDiscoveredWorktree(_ worktree: GitWorktreeRecord) -> Bool {
        var isDirectory: ObjCBool = false
        return worktree.pruneReason == nil
            && FileManager.default.fileExists(atPath: worktree.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: Managed worktrees

    struct ManagedWorktreeMutation: Equatable {
        enum Kind: String { case create, attach, remove, prune, deleteBranch }
        let kind: Kind
        /// The tree being removed; nil while creating, whose path is not yet a tree.
        let path: String?
    }

    private func beginManagedWorktreeMutation(_ kind: ManagedWorktreeMutation.Kind, path: String?) throws {
        if let current = managedWorktreeMutation {
            throw RelayUIError.message("Another worktree operation (\(current.kind.rawValue)\(current.path.map { " of \($0)" } ?? "")) is still in progress. Wait for it to finish; Parley runs one worktree mutation at a time.")
        }
        managedWorktreeMutation = ManagedWorktreeMutation(kind: kind, path: path)
    }

    private func endManagedWorktreeMutation() {
        managedWorktreeMutation = nil
    }

    /// How a team session approval binds its folder to a Git worktree.
    enum TeamWorktreeChoice: Equatable {
        /// Named to avoid `.none` reading as `Optional.none` at call sites.
        case ordinaryFolder
        case existing(path: String)
        /// The exact create preview the person approved.
        case create(preview: ManagedWorktreeService.CreatePreview)
    }

    /// The board row for one managed tree: the record, the last background
    /// Git read, the panes the scan mapped into the tree, the requesting pane
    /// if it still exists and the bound team if any. Pure derivation; SwiftUI
    /// calls this per row and nothing here touches the filesystem.
    func worktreeBoardRow(_ record: ManagedWorktreeRecord) -> WorktreeBoardRow {
        let inside = panes.filter { worktreeScan.paneWorktreePaths[$0.id] == record.path }
        let requester = record.requestedByPaneID.flatMap { id in panes.first { $0.id == id } }
        let session = record.teamSessionID.flatMap { id in teamSessions.first { $0.id == id } }
        return WorktreeBoardRow.derive(record: record, facts: managedWorktreeFacts[record.id], panesInside: inside,
            requester: requester, teamObjective: session?.objective, teamState: session?.state)
    }

    /// Integrate…: propose merging the tree's branch into the repository's
    /// primary checkout as a reviewed command run the person approves in the
    /// same editable preview an agent's request-run gets. Parley runs no
    /// merge itself; the approved worker does, in a new Shell pane, and the
    /// captured exit status and output are recorded. The browser sheet is
    /// dismissed first because one sheet is presented at a time.
    func proposeWorktreeIntegration(_ record: ManagedWorktreeRecord) {
        let repository = worktreeScan.repositories.first { $0.worktrees.contains(where: { $0.path == record.path }) }
            ?? worktreeRepositories.first { $0.worktrees.contains(where: { $0.path == record.path }) }
                .map { GitWorktreeRepository(primaryPath: $0.primaryPath, worktrees: $0.worktrees) }
        guard let repository, repository.worktrees.contains(where: \.isPrimary) else {
            NSAlert(error: ReviewedCommandRunError.invalid("Parley could not find the repository's primary checkout for this worktree. Open the Worktrees window on that repository, then try again.")).runModal()
            return
        }
        let live = managedWorktreeFacts[record.id]?.currentBranch
        let branch = (live.map { $0.isEmpty || $0 == "HEAD" ? nil : $0 } ?? nil) ?? record.branch
        proposeWorktreeIntegration(branch: branch, treePath: record.path, primaryPath: repository.primaryPath)
    }

    /// Integrate… for any linked tree: propose merging its branch into the
    /// repository's primary checkout as a reviewed command run the person
    /// approves in the same editable preview an agent's request-run gets.
    /// Parley runs no merge itself; the approved worker does, in a new Shell
    /// pane, and the captured exit status and output are recorded. The main
    /// window's sheets are dismissed first because one is presented at a time,
    /// and that window is brought forward since the review lives there.
    func proposeWorktreeIntegration(branch: String, treePath: String, primaryPath: String) {
        perform {
            guard let core = residentCore else { throw ReviewedCommandRunError.invalid("The native command-run service is unavailable.") }
            guard primaryPath != treePath else {
                throw ReviewedCommandRunError.invalid("This is the primary checkout itself; there is nothing to merge into it.")
            }
            guard !branch.isEmpty, branch != "HEAD", branch != "(detached)" else {
                throw ReviewedCommandRunError.invalid("This worktree is on a detached HEAD, so there is no branch to merge. Check out or create a branch in it first.")
            }
            let argv = try WorktreeIntegration.mergeArgv(branch: branch)
            guard let workspace = activeWorkspace ?? workspaces.first else {
                throw ReviewedCommandRunError.invalid("Open a workspace first; the run's Shell pane needs one.")
            }
            let run = try core.commandRuns.propose(argv: argv, folder: primaryPath, workspaceID: workspace.workspaceID, workspaceName: workspace.name)
            commandRuns = core.commandRuns.runs()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "Parley" }) { main.makeKeyAndOrderFront(nil) }
                self.selectCommandRun(run)
                self.commandRunsPresented = true
            }
        }
    }

    func integrateWorktreeFromManager(_ tree: GitWorktreeRecord, in entry: WorktreeRepositoryEntry) {
        guard entry.worktrees.contains(where: \.isPrimary) else {
            NSAlert(error: ReviewedCommandRunError.invalid("This bare repository has no primary checkout to merge into. Integrate from an explicitly chosen checkout in your terminal.")).runModal()
            return
        }
        proposeWorktreeIntegration(branch: tree.branch ?? "", treePath: tree.path, primaryPath: entry.primaryPath)
    }

    /// Predict… on a row: the same merge-tree prediction Finish… offers,
    /// against the primary checkout's HEAD, shown with its limitation and
    /// offering Integrate… from the result. A prediction, never a verdict,
    /// and no checkout, index, branch or object changes.
    func predictWorktreeMerge(_ tree: GitWorktreeRecord, in entry: WorktreeRepositoryEntry) {
        guard let primary = entry.worktrees.first(where: \.isPrimary), let branch = tree.branch else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let service = self.managedWorktreeService else { throw RelayUIError.message("The workbench is unavailable.") }
                let preview = try await Task.detached(priority: .userInitiated) {
                    try service.mergePreview(path: tree.path, repositoryFolder: entry.primaryPath, targetRef: primary.head)
                }.value
                let row = self.worktreeManagerRow(for: tree)
                let alert = NSAlert()
                alert.messageText = preview.headline(branch: branch, into: primary.shortIdentity)
                alert.informativeText = preview.detail(limit: 40)
                alert.alertStyle = .informational
                if row.canIntegrate { alert.addButton(withTitle: "Integrate…") }
                alert.addButton(withTitle: "Close")
                if alert.runModal() == .alertFirstButtonReturn, row.canIntegrate {
                    self.proposeWorktreeIntegration(branch: branch, treePath: tree.path, primaryPath: entry.primaryPath)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: Worktree manager

    @Published private(set) var worktreeRepositories: [WorktreeRepositoryEntry] = []
    @Published private(set) var worktreeManagerSelection: String?
    /// Facts for the selected repository's linked trees, keyed by tree path.
    @Published private(set) var worktreeManagerFacts: [String: ManagedWorktreeFacts] = [:]
    @Published private(set) var worktreeManagerReading = false
    private var worktreeRepositoriesTask: Task<Void, Never>?
    private var worktreeRepositoriesGeneration = 0
    private var worktreeManagerFactsTask: Task<Void, Never>?
    private var worktreeManagerFactsGeneration = 0
    private(set) var worktreeManagerMounted = false
    private var worktreeRepositoryStore: WorktreeRepositoryStore? {
        controller.map { WorktreeRepositoryStore(file: $0.applicationDirectory.appendingPathComponent("worktree-repositories.json")) }
    }

    var selectedWorktreeRepository: WorktreeRepositoryEntry? { worktreeRepositories.first { $0.id == worktreeManagerSelection } }

    /// The window's content tells the model when it is on screen; reads
    /// run only then, and closing the window cancels what is in flight.
    func setWorktreeManagerMounted(_ mounted: Bool) {
        worktreeManagerMounted = mounted
        if mounted {
            refreshWorktreeRepositories()
        } else {
            worktreeRepositoriesTask?.cancel()
            worktreeRepositoriesTask = nil
            worktreeManagerFactsTask?.cancel()
            worktreeManagerFactsTask = nil
            worktreeManagerReading = false
        }
    }

    /// Everything Parley knows a repository from: pane folders, attached,
    /// favourite and recent folders, managed records, and folders added by
    /// hand. Resolution to a repository happens off the main actor.
    private func worktreeRepositoryCandidates() -> [WorktreeRepositoryCandidate] {
        var candidates: [WorktreeRepositoryCandidate] = []
        for pane in panes { candidates.append(WorktreeRepositoryCandidate(folder: pane.launchWorkingDirectory, source: .pane)) }
        for workspace in workspaces {
            for folder in workspace.attachedFolders { candidates.append(WorktreeRepositoryCandidate(folder: folder, source: .attachment)) }
        }
        for folder in favouriteFolders { candidates.append(WorktreeRepositoryCandidate(folder: folder, source: .favourite)) }
        for folder in recentFolders { candidates.append(WorktreeRepositoryCandidate(folder: folder, source: .recent)) }
        for record in managedWorktrees { candidates.append(WorktreeRepositoryCandidate(folder: record.path, source: .record)) }
        for folder in (try? worktreeRepositoryStore?.folders()) ?? [] { candidates.append(WorktreeRepositoryCandidate(folder: folder, source: .added)) }
        return Array(Set(candidates)).sorted { $0.folder == $1.folder ? $0.source.rawValue < $1.source.rawValue : $0.folder < $1.folder }
    }

    func refreshWorktreeRepositories() {
        let candidates = worktreeRepositoryCandidates()
        worktreeRepositoriesTask?.cancel()
        worktreeRepositoriesGeneration += 1
        let generation = worktreeRepositoriesGeneration
        let resolver = worktreeResolver
        worktreeRepositoriesTask = Task.detached(priority: .utility) { [candidates, resolver] in
            var cache: [String: GitWorktreeRepository?] = [:]
            var resolved: [(candidate: WorktreeRepositoryCandidate, repository: GitWorktreeRepository?)] = []
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                let key = GitWorktreeResolver.canonicalPath(candidate.folder)
                let repository: GitWorktreeRepository?
                if let cached = cache[key] {
                    repository = cached
                } else {
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: key, isDirectory: &isDirectory) && isDirectory.boolValue
                    repository = exists ? resolver.repository(in: key)?.repository : nil
                    cache[key] = repository
                }
                resolved.append((candidate, repository))
            }
            let entries = WorktreeRepositoryCatalog.merge(resolved: resolved)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.worktreeRepositoriesGeneration == generation else { return }
                self.worktreeRepositoriesTask = nil
                if entries != self.worktreeRepositories { self.worktreeRepositories = entries }
                if self.worktreeManagerSelection.map({ id in entries.contains { $0.id == id } }) != true {
                    self.worktreeManagerSelection = entries.first?.id
                }
                self.refreshWorktreeManagerFacts()
            }
        }
    }

    func selectWorktreeRepository(_ primaryPath: String?) {
        worktreeManagerSelection = primaryPath
        refreshWorktreeManagerFacts()
    }

    /// Workspace › Open Worktree…: select the repository containing a
    /// folder, resolving it off the main actor first.
    func selectWorktreeRepository(containing folder: String) {
        let resolver = worktreeResolver
        Task.detached(priority: .userInitiated) { [resolver, folder] in
            let primary = resolver.repository(in: folder)?.repository.primaryPath
            await MainActor.run { [weak self] in
                guard let self, let primary else { return }
                if !self.worktreeRepositories.contains(where: { $0.id == primary }) { self.refreshWorktreeRepositories() }
                self.selectWorktreeRepository(primary)
            }
        }
    }

    /// Bounded background reads for the selected repository's linked trees,
    /// applied only by the newest request; a stale entry has no folder to
    /// read and is skipped.
    func refreshWorktreeManagerFacts() {
        worktreeManagerFactsTask?.cancel()
        worktreeManagerFactsGeneration += 1
        let generation = worktreeManagerFactsGeneration
        guard worktreeManagerMounted, let service = managedWorktreeService, let entry = selectedWorktreeRepository else {
            worktreeManagerReading = false
            return
        }
        let trees = entry.linked.filter { $0.pruneReason == nil }
        guard !trees.isEmpty else {
            worktreeManagerReading = false
            return
        }
        worktreeManagerReading = true
        let records = managedWorktreesByPath
        worktreeManagerFactsTask = Task.detached(priority: .utility) { [trees, service, records] in
            var facts: [String: ManagedWorktreeFacts] = [:]
            for tree in trees {
                guard !Task.isCancelled else { return }
                facts[tree.path] = service.facts(forTreeAt: tree.path, id: tree.path, expectedCommonDirectory: records[tree.path]?.commonDirectory)
            }
            let result = facts
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.worktreeManagerFactsGeneration == generation else { return }
                self.worktreeManagerFactsTask = nil
                self.worktreeManagerReading = false
                var merged = self.worktreeManagerFacts
                for (path, value) in result { merged[path] = value }
                if merged != self.worktreeManagerFacts { self.worktreeManagerFacts = merged }
            }
        }
    }

    /// A board row for a registry entry: the record, if any, annotates it.
    func worktreeManagerRow(for tree: GitWorktreeRecord) -> WorktreeBoardRow {
        // A gone folder cannot be realpath-resolved, so Git's spelling of a
        // stale entry may carry /private where the record does not.
        let record = managedWorktreesByPath[tree.path] ?? managedWorktrees.first { Self.samePathSpelling($0.path, tree.path) }
        let inside = panes.filter { worktreeScan.paneWorktreePaths[$0.id] == tree.path }
        let requester = record?.requestedByPaneID.flatMap { id in panes.first { $0.id == id } }
        let session = record?.teamSessionID.flatMap { id in teamSessions.first { $0.id == id } }
        let facts = worktreeManagerFacts[tree.path] ?? record.flatMap { managedWorktreeFacts[$0.id] }
        return WorktreeBoardRow.derive(tree: tree, record: record, facts: facts, panesInside: inside,
            requester: requester, teamObjective: session?.objective, teamState: session?.state)
    }

    /// Equal paths once the /private prefix macOS adds to /tmp, /var and
    /// /etc is ignored; the only comparison that works for a folder that no
    /// longer exists, where neither side can be resolved.
    static func samePathSpelling(_ a: String, _ b: String) -> Bool {
        func strip(_ path: String) -> String { path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path }
        return strip(a) == strip(b)
    }

    func addWorktreeRepository() {
        let panel = NSOpenPanel()
        panel.title = "Add a repository to the worktree manager"
        panel.message = "Choose a folder inside a Git repository. Parley lists its worktrees; nothing is created or changed."
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.standardizedFileURL.path
        let resolver = worktreeResolver
        Task.detached(priority: .userInitiated) { [resolver, folder] in
            let repository = resolver.repository(in: folder)?.repository
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.perform {
                    guard let repository else {
                        throw RelayUIError.message("\(folder) is not inside a Git repository, so there are no worktrees to list.")
                    }
                    try self.worktreeRepositoryStore?.add(repository.primaryPath)
                    self.worktreeManagerSelection = repository.primaryPath
                    self.refreshWorktreeRepositories()
                }
            }
        }
    }

    func forgetWorktreeRepository(_ entry: WorktreeRepositoryEntry) {
        perform {
            try worktreeRepositoryStore?.forget(entry.primaryPath)
            if worktreeManagerSelection == entry.id { worktreeManagerSelection = nil }
            refreshWorktreeRepositories()
        }
    }

    func openWorktreeFromManager(_ tree: GitWorktreeRecord) {
        openDiscoveredWorktree(tree)
    }

    /// An unrecorded tree gets a record on the way into an action that keeps
    /// evidence (Finish, Remove): what Track Existing wrote, written silently.
    func ensureWorktreeRecord(for tree: GitWorktreeRecord, in entry: WorktreeRepositoryEntry) async throws -> ManagedWorktreeRecord {
        if let record = managedWorktreesByPath[tree.path] { return record }
        return try await attachManagedWorktree(existingPath: tree.path, repositoryFolder: entry.primaryPath, teamSessionID: nil, requestedByPaneID: nil)
    }

    func removeWorktreeFromManager(_ tree: GitWorktreeRecord, in entry: WorktreeRepositoryEntry) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let record = try await self.ensureWorktreeRecord(for: tree, in: entry)
                self.removeManagedWorktree(record)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Prune…: Git forgets every registration its own dry run
    /// (`worktree prune -n -v`) names. Git has no per-entry prune, so the
    /// preview lists them all with Git's reasons and the person acknowledges
    /// that list; nothing on disk and no branch changes. Parley refuses when
    /// any entry's folder still exists or cannot be known, because pruning
    /// would leave that folder's files outside the repository. Parley records
    /// for forgotten entries are cleared.
    func pruneWorktrees(in entry: WorktreeRepositoryEntry) {
        guard let service = managedWorktreeService, let store = managedWorktreeStore else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try self.beginManagedWorktreeMutation(.prune, path: nil) } catch { NSAlert(error: error).runModal(); return }
            defer {
                self.endManagedWorktreeMutation()
                self.reloadManagedWorktrees()
                self.scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
                if self.worktreeManagerMounted { self.refreshWorktreeRepositories() }
            }
            let folder = entry.primaryPath
            let previewResult = await Task.detached(priority: .userInitiated) { [service, folder] in Result { try service.prunePreview(in: folder) } }.value
            let preview: ManagedWorktreeService.PrunePreview
            switch previewResult {
            case let .failure(error): NSAlert(error: error).runModal(); return
            case let .success(value): preview = value
            }
            guard !preview.entries.isEmpty else {
                let none = NSAlert()
                none.messageText = "Nothing to prune"
                none.informativeText = "Git would prune no worktree entry of \(entry.name). Nothing was changed."
                none.runModal()
                return
            }
            let listed = preview.entries.map { item in
                "• \(item.adminName): \(item.reason)"
                    + (item.folder.map { " — \(DelegationGitFacts.displayPath($0))" } ?? "")
                    + (item.branch.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
            guard preview.refusals.isEmpty else {
                let refused = NSAlert()
                refused.messageText = "Parley will not prune \(entry.name)"
                refused.informativeText = "Git has no per-entry prune, and it would also remove entries a worktree may still use:\n\n"
                    + preview.refusals.map { "• " + $0 }.joined(separator: "\n") + "\n\nEverything Git would prune:\n" + listed + "\n\nNothing was changed."
                refused.alertStyle = .warning
                refused.runModal()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Forget \(preview.entries.count) stale worktree entr\(preview.entries.count == 1 ? "y" : "ies") of \(entry.name)?"
            alert.informativeText = "Git will forget these registrations, whose folders are gone, as its own dry run lists them. Git has no per-entry prune, so every entry it would prune is included. No folder is touched and no branch is deleted; Parley clears its own records for them.\n\n"
                + listed
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Prune")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let acknowledged = preview.adminNames
            let outcome = await Task.detached(priority: .userInitiated) { [service, folder, acknowledged] in Result { try service.prune(in: folder, acknowledgedNames: acknowledged) } }.value
            let result = NSAlert()
            switch outcome {
            case let .success(pruned):
                for path in pruned.forgottenFolders {
                    for record in self.managedWorktrees where Self.samePathSpelling(record.path, path) { try? store.remove(id: record.id) }
                }
                result.messageText = pruned.remaining.isEmpty ? "Stale entries forgotten" : "Some entries remain"
                result.informativeText = pruned.detail
                result.alertStyle = pruned.remaining.isEmpty ? .informational : .warning
                // The branches those entries held are now deletable; offer that step separately, one confirmation each.
                let releasedBranches = pruned.forgottenBranches
                if !releasedBranches.isEmpty {
                    result.informativeText += "\n\nThe branch\(releasedBranches.count == 1 ? "" : "es") \(releasedBranches.joined(separator: ", ")) \(releasedBranches.count == 1 ? "is" : "are") kept. Delete Branch\(releasedBranches.count == 1 ? "" : "es")… runs git branch -d for each, one confirmation at a time; Git refuses any that is unmerged."
                    result.addButton(withTitle: "OK")
                    result.addButton(withTitle: releasedBranches.count == 1 ? "Delete Branch…" : "Delete Branches…")
                }
                if result.runModal() == .alertSecondButtonReturn {
                    // The prune is over; each branch step takes its own turn as a mutation.
                    self.endManagedWorktreeMutation()
                    for branch in releasedBranches { await self.deleteWorktreeBranchAwaiting(branch, in: folder) }
                }
                return
            case let .failure(error):
                result.messageText = "Nothing pruned"
                result.informativeText = error.localizedDescription
                result.alertStyle = .warning
            }
            result.runModal()
        }
    }

    /// Delete branch…: one git branch -d from the primary checkout. Git
    /// refuses an unmerged or checked-out branch in its own words and Parley
    /// shows them; the upper-case form is never used and nothing is retried.
    func deleteWorktreeBranch(_ branch: String, in primaryPath: String) {
        Task { @MainActor [weak self] in await self?.deleteWorktreeBranchAwaiting(branch, in: primaryPath) }
    }

    /// The same step, awaited, so a prune's follow-up can offer several
    /// branches one confirmation at a time.
    func deleteWorktreeBranchAwaiting(_ branch: String, in primaryPath: String) async {
        guard let service = managedWorktreeService else { return }
        do {
            do { try self.beginManagedWorktreeMutation(.deleteBranch, path: nil) } catch { NSAlert(error: error).runModal(); return }
            defer {
                self.endManagedWorktreeMutation()
                if self.worktreeManagerMounted { self.refreshWorktreeRepositories() }
            }
            let previewResult = await Task.detached(priority: .userInitiated) { [service, branch, primaryPath] in Result { try service.branchDeletionPreview(branch, in: primaryPath) } }.value
            let preview: ManagedWorktreeService.BranchDeletionPreview
            switch previewResult {
            case let .failure(error): NSAlert(error: error).runModal(); return
            case let .success(value): preview = value
            }
            let alert = NSAlert()
            alert.messageText = "Delete branch \(branch)?"
            var lines = ["Branch \(branch) is at \(preview.commit.prefix(12))."]
            if let checkedOut = preview.checkedOutAt, preview.heldByStaleEntry {
                lines.append("A stale worktree entry at \(DelegationGitFacts.displayPath(checkedOut)) still holds it, so Git will refuse. Prune that entry first; the branch step is offered again afterwards.")
            } else if let checkedOut = preview.checkedOutAt {
                lines.append("It is checked out at \(DelegationGitFacts.displayPath(checkedOut)); Git will refuse to delete it. Remove or switch that worktree first.")
            } else if let upstream = preview.upstream {
                // Git's rule: with an upstream, -d checks the upstream, not HEAD.
                let name = upstream.hasPrefix("refs/remotes/") ? String(upstream.dropFirst("refs/remotes/".count)) : upstream
                if preview.mergedIntoUpstream == true {
                    lines.append("Its commit is on its upstream \(name), by this repository's last fetch, so Git will delete the name"
                        + (preview.mergedIntoPrimaryHead ? " and the primary checkout's HEAD contains it too." : ". The primary checkout's HEAD does NOT contain it: afterwards it is kept only by \(name) and the remote it tracks."))
                } else {
                    lines.append("Its commit is NOT on its upstream \(name), so Git will refuse with -d, and Parley never uses -D; push or merge it first if you want to keep it.")
                }
            } else if preview.mergedIntoPrimaryHead {
                lines.append("It has no upstream, and its commit is contained in the primary checkout's HEAD, so nothing is lost by deleting the name.")
            } else {
                lines.append("It has no upstream, and its commit is NOT contained in the primary checkout's HEAD. Git will refuse with -d, and Parley never uses -D; merge or push it first if you want to keep it.")
            }
            lines.append("Parley runs one git branch -d. No folder, object or other ref changes.")
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete Branch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let expected = preview.commit
            let outcome = await Task.detached(priority: .userInitiated) { [service, branch, primaryPath, expected] in Result { try service.deleteBranch(branch, expectedCommit: expected, in: primaryPath) } }.value
            let result = NSAlert()
            switch outcome {
            case let .success(.deleted(commit)):
                result.messageText = "Branch deleted"
                result.informativeText = "Deleted \(branch) (was \(commit.prefix(12))). The commit is still in the repository until Git's own housekeeping runs."
            case let .success(.refused(reason)):
                result.messageText = "Branch not deleted"
                result.informativeText = reason + "\n\nParley does not retry with -D."
                result.alertStyle = .warning
            case let .failure(error):
                result.messageText = "Branch not deleted"
                result.informativeText = error.localizedDescription
                result.alertStyle = .warning
            }
            result.runModal()
        }
    }

    /// Remove integrated…: one preview over every INTEGRATED linked tree of
    /// the selected repository, built from fresh cleanup previews. Trees
    /// with a refusal are shown and skipped. Confirmation removes the
    /// passing trees one at a time, one git worktree remove each without
    /// --force, and stops at the first outcome that is not a confirmed
    /// removal. A second, separate confirmation offers the branches of the
    /// removed trees, one confirmation each, with -d only.
    func removeIntegratedWorktrees(in entry: WorktreeRepositoryEntry) {
        guard let service = managedWorktreeService, let controller else { return }
        let stateFiles = otherRuntimeStateFiles
        Task { @MainActor [weak self] in
            guard let self else { return }
            let candidates = entry.linked.filter { tree in
                tree.pruneReason == nil && [.integrated, .unused].contains(self.worktreeManagerRow(for: tree).state)
            }
            guard !candidates.isEmpty else {
                let none = NSAlert()
                none.messageText = "Nothing to remove"
                none.informativeText = "No linked worktree of \(entry.name) reads Integrated or Unused right now. Refresh, or remove trees one at a time."
                none.runModal()
                return
            }
            // Records first (silently, as Finish and Remove do), then one
            // mutation for the whole run so nothing else starts inside it.
            var records: [ManagedWorktreeRecord] = []
            for tree in candidates {
                do { records.append(try await self.ensureWorktreeRecord(for: tree, in: entry)) } catch { NSAlert(error: error).runModal(); return }
            }
            do { try self.beginManagedWorktreeMutation(.remove, path: entry.primaryPath) } catch { NSAlert(error: error).runModal(); return }
            var reserved: [String] = []
            defer {
                for path in reserved { controller.releaseFolderReservation(path) }
                self.endManagedWorktreeMutation()
                self.reloadManagedWorktrees()
                self.scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
                self.scheduleWorktreeRefresh(force: true)
                if self.worktreeManagerMounted { self.refreshWorktreeRepositories() }
            }
            let folders: [String]
            do { folders = try self.livePaneFoldersForCleanup() } catch { NSAlert(error: error).runModal(); return }
            // Labels come from facts read now, beside each preview, not from
            // the board's cached reading: a tree that gained work since the
            // board last read it is skipped rather than called Unused.
            let previews = await Task.detached(priority: .userInitiated) { [service, records, folders, stateFiles] in
                records.map { record in
                    Result { try service.cleanupPreview(record, livePaneFolders: folders, otherRuntimeStateFiles: stateFiles) }
                        .map { (preview: $0, state: WorktreeBulkRemovalPlan.freshState(record: record, facts: service.facts(for: record))) }
                }
            }.value
            var items: [WorktreeBulkRemovalPlan.Item] = []
            var unreadable: [String] = []
            for (record, result) in zip(records, previews) {
                switch result {
                case let .success(read):
                    guard let state = read.state else {
                        unreadable.append("\(record.branch): no longer reads Integrated or Unused")
                        continue
                    }
                    items.append(WorktreeBulkRemovalPlan.Item(record: record, preview: read.preview, state: state))
                case let .failure(error): unreadable.append("\(record.branch): \(error.localizedDescription)")
                }
            }
            let plan = WorktreeBulkRemovalPlan.plan(items: items)
            let alert = NSAlert()
            alert.messageText = plan.passing.isEmpty ? "No integrated or unused worktree of \(entry.name) can be removed" : "Remove \(plan.passing.count) integrated or unused worktree\(plan.passing.count == 1 ? "" : "s") of \(entry.name)?"
            var lines: [String] = []
            for item in plan.passing {
                lines.append("• \(item.record.branch) (\(item.state == .unused ? "unused: no commits since its base" : "integrated")) at \(DelegationGitFacts.displayPath(item.record.path))\n  \(item.preview.preservationSummary)."
                    + (item.preview.ignoredPaths.isEmpty ? "" : " \(item.preview.ignoredPaths.count) ignored entr\(item.preview.ignoredPaths.count == 1 ? "y" : "ies") will be deleted with it (listed below)."))
            }
            for item in plan.skipped {
                lines.append("• \(item.record.branch): skipped because " + item.refusals.map(DelegationGitFacts.displayPath).joined(separator: "; "))
            }
            for line in unreadable { lines.append("• \(line): skipped") }
            lines.append(plan.passing.isEmpty ? "Nothing will be changed."
                : "Parley runs one git worktree remove per tree, without --force, re-checking each first, and stops at the first outcome that is not a confirmed removal. Branches are kept; the next step offers them separately.")
            alert.informativeText = lines.joined(separator: "\n\n")
            alert.alertStyle = .warning
            let ignored = plan.passing.flatMap { item in item.preview.ignoredPaths.map { "\(item.record.branch): \($0)" } }
            if !ignored.isEmpty { alert.accessoryView = Self.reviewedPathList(ignored) }
            if plan.passing.isEmpty {
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            alert.addButton(withTitle: plan.totalIgnored == 0 ? "Remove \(plan.passing.count) Worktree\(plan.passing.count == 1 ? "" : "s")"
                : "Remove \(plan.passing.count) Worktree\(plan.passing.count == 1 ? "" : "s") and \(plan.totalIgnored) Ignored Entr\(plan.totalIgnored == 1 ? "y" : "ies")")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for item in plan.passing {
                do { try self.requireNoWorktreeTeamBinding(item.record.path); try controller.reserveFolderForRemoval(item.record.path); reserved.append(item.record.path) }
                catch { NSAlert(error: error).runModal(); return }
            }
            var removed: [ManagedWorktreeRecord] = []
            var report: [String] = []
            var stopped = false
            for item in plan.passing {
                let currentFolders: [String]
                do { currentFolders = try self.livePaneFoldersForCleanup() } catch { report.append("\(item.record.branch): \(error.localizedDescription)"); stopped = true; break }
                let record = item.record
                let acknowledged = item.preview.ignoredPaths
                let outcome = await Task.detached(priority: .userInitiated) { [service, record, acknowledged, currentFolders, stateFiles] in
                    Result { try service.remove(record, confirmed: .removeTree, acknowledgedIgnoredPaths: acknowledged, livePaneFolders: currentFolders, otherRuntimeStateFiles: stateFiles) }
                }.value
                switch outcome {
                case let .success(removal):
                    report.append("\(record.branch): \(removal.detail)")
                    if WorktreeBulkRemovalPlan.shouldContinue(after: removal.state) { removed.append(record) } else { stopped = true }
                case let .failure(error):
                    report.append("\(record.branch): \(error.localizedDescription)")
                    stopped = true
                }
                if stopped { break }
            }
            let result = NSAlert()
            result.messageText = stopped ? "Stopped after \(removed.count) of \(plan.passing.count)" : "\(removed.count) worktree\(removed.count == 1 ? "" : "s") removed"
            result.alertStyle = stopped ? .warning : .informational
            result.informativeText = report.joined(separator: "\n\n") + (stopped ? "\n\nThe remaining trees were not touched. Nothing is retried on its own." : "")
            let branches = removed.map(\.branch).filter { !$0.hasPrefix("(") }
            if !branches.isEmpty {
                result.informativeText += "\n\nThe branch\(branches.count == 1 ? "" : "es") \(branches.joined(separator: ", ")) \(branches.count == 1 ? "is" : "are") kept. Delete Branch\(branches.count == 1 ? "" : "es")… runs git branch -d for each, one confirmation at a time; Git refuses any that is unmerged."
                result.addButton(withTitle: "OK")
                result.addButton(withTitle: branches.count == 1 ? "Delete Branch…" : "Delete Branches…")
            }
            let response = result.runModal()
            if response == .alertSecondButtonReturn {
                for path in reserved { controller.releaseFolderReservation(path) }
                reserved = []
                self.endManagedWorktreeMutation()
                for branch in branches { await self.deleteWorktreeBranchAwaiting(branch, in: entry.primaryPath) }
            }
        }
    }

    func openManagedWorktree(_ record: ManagedWorktreeRecord) {
        perform {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw RelayUIError.message("That worktree folder no longer exists. Parley did not change Git state.")
            }
            _ = try openWorkspace(folder: record.path)
        }
    }

    func reloadManagedWorktrees() {
        guard let store = managedWorktreeStore else { return }
        let records = ((try? store.records()) ?? []).sorted { $0.createdAt > $1.createdAt }
        if records != managedWorktrees { managedWorktrees = records }
    }

    /// The managed record for the exact Git worktree root the background scan
    /// mapped this pane to. No filesystem work: SwiftUI bodies call this per
    /// row, and a pane the scan has not mapped yet simply shows nothing.
    func managedWorktree(forPane paneID: String) -> ManagedWorktreeRecord? {
        guard let root = worktreeScan.paneWorktreePaths[paneID] else { return nil }
        return managedWorktreesByPath[root]
    }

    func managedWorktree(atPath path: String) -> ManagedWorktreeRecord? {
        let canonical = GitWorktreeResolver.canonicalPath(path)
        return managedWorktrees.first { $0.path == canonical }
    }

    /// Display line for one managed worktree: recorded base from the record,
    /// live branch, HEAD, dirty count and upstream from the last background
    /// read. Anything Git did not answer is shown as unknown.
    func managedWorktreeSummary(_ record: ManagedWorktreeRecord) -> String {
        var parts = ["\(record.branch)", "recorded base \(record.baseCommit.map { String($0.prefix(12)) } ?? "not recorded")\(record.baseRef.map { " (\($0))" } ?? "")"]
        if let facts = managedWorktreeFacts[record.id] {
            switch facts.registered {
            case false?: parts.append("folder gone or no longer listed by Git"); return parts.joined(separator: " · ")
            case nil: parts.append("Git could not be read; registration unknown"); return parts.joined(separator: " · ")
            case true?: break
            }
            if let branch = facts.currentBranch, branch != record.branch { parts.append("now on \(branch)") }
            if let head = facts.head {
                parts.append("HEAD \(head.prefix(12))" + (record.baseCommit == head ? " (at base)" : ""))
            } else { parts.append("HEAD unknown") }
            switch facts.changedPathCount {
            case let count?: parts.append(count == 0 ? "clean" : "\(count) changed path\(count == 1 ? "" : "s")")
            case nil: parts.append("status unknown")
            }
            switch (facts.hasUpstream, facts.upstreamAheadCount) {
            case (true?, let ahead?): parts.append("\(ahead) ahead of upstream (local tracking state)")
            case (true?, nil) where facts.upstreamGone == true: parts.append("upstream gone (missing here)")
            case (true?, nil): parts.append("ahead-of-upstream count unknown")
            case (false?, _): parts.append("no upstream")
            case (nil, _): parts.append("upstream unknown")
            }
        } else {
            parts.append("live state not read yet")
        }
        parts.append(record.parleyCreated ? "created by Parley" : "existing tree, person-owned")
        return parts.joined(separator: " · ")
    }

    /// Bounded background Git reads for every managed record. Results apply
    /// only when the record set is unchanged, so a create or remove that
    /// happened meanwhile is never overwritten by stale facts.
    enum ManagedWorktreeFactsScope { case live, all }

    /// Records worth reading periodically: trees a pane sits in and trees
    /// bound to a session that is not over. Everything else is read on
    /// demand (browser open), so an archive of old records costs nothing.
    private func liveManagedWorktrees() -> [ManagedWorktreeRecord] {
        let paneRoots = Set(worktreeScan.paneWorktreePaths.values)
        let sessionRoots = Set(teamSessions.filter { !$0.state.isTerminal }.compactMap { $0.worktree?.path })
        return managedWorktrees.filter { paneRoots.contains($0.path) || sessionRoots.contains($0.path) }
    }

    func scheduleManagedWorktreeFactsRefresh(force: Bool = false, scope: ManagedWorktreeFactsScope = .live) {
        guard let service = managedWorktreeService, managedWorktreeFactsTask == nil || force else { return }
        managedWorktreeFactsTask?.cancel()
        managedWorktreeFactsGeneration += 1
        let generation = managedWorktreeFactsGeneration
        let records = scope == .all ? managedWorktrees : liveManagedWorktrees()
        guard !records.isEmpty else {
            managedWorktreeFactsTask = nil
            return
        }
        managedWorktreeFactsTask = Task.detached(priority: .utility) { [records, service] in
            var facts: [String: ManagedWorktreeFacts] = [:]
            for record in records {
                guard !Task.isCancelled else { return }
                facts[record.id] = service.facts(for: record)
            }
            let result = facts
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only the newest scheduled read may publish, and only over the
                // exact record set it read; a superseded task neither applies nor
                // clears anything.
                guard self.managedWorktreeFactsGeneration == generation else { return }
                self.managedWorktreeFactsTask = nil
                // Apply only over records that still exist unchanged; facts for
                // records not in this scope are left as they were.
                let current = Dictionary(self.managedWorktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var merged = self.managedWorktreeFacts
                for record in records {
                    guard current[record.id] == record, let facts = result[record.id] else { continue }
                    merged[record.id] = facts
                }
                merged = merged.filter { current[$0.key] != nil }
                if merged != self.managedWorktreeFacts { self.managedWorktreeFacts = merged }
            }
        }
    }

    /// Reads what a creation would do, off the main thread. The returned
    /// base commit is what the person approves; creation refuses a ref that
    /// moved afterwards.
    func previewManagedWorktree(repositoryFolder: String, branch: String, baseRef: String) async -> Result<ManagedWorktreeService.CreatePreview, Error> {
        guard let service = managedWorktreeService else { return .failure(RelayUIError.message("The workbench is not available.")) }
        return await Task.detached(priority: .userInitiated) { [service] in
            Result { try service.createPreview(repositoryFolder: repositoryFolder, branch: branch, baseRef: baseRef) }
        }.value
    }

    /// One fixed-argv `git worktree add` bound to the exact preview the person
    /// approved: repository, path and base commit are re-resolved and compared
    /// before anything is written.
    func createManagedWorktree(preview: ManagedWorktreeService.CreatePreview, repositoryFolder: String,
                               teamSessionID: String? = nil, requestedByPaneID: String? = nil) async throws -> ManagedWorktreeRecord {
        guard let service = managedWorktreeService else { throw RelayUIError.message("The workbench is not available.") }
        let request = ManagedWorktreeService.CreateRequest(preview: preview, repositoryFolder: repositoryFolder,
            teamSessionID: teamSessionID, requestedByPaneID: requestedByPaneID)
        try beginManagedWorktreeMutation(.create, path: nil)
        defer {
            endManagedWorktreeMutation()
            reloadManagedWorktrees()
            scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
            if worktreeManagerMounted { refreshWorktreeRepositories() }
            scheduleWorktreeRefresh(force: true)
        }
        return try await Task.detached(priority: .userInitiated) { [service, request] in try service.create(request) }.value
    }

    /// Records an existing registered worktree for a team without taking ownership.
    func attachManagedWorktree(existingPath: String, repositoryFolder: String, teamSessionID: String?, requestedByPaneID: String?) async throws -> ManagedWorktreeRecord {
        guard let service = managedWorktreeService else { throw RelayUIError.message("The workbench is not available.") }
        try beginManagedWorktreeMutation(.attach, path: existingPath)
        defer {
            endManagedWorktreeMutation()
            reloadManagedWorktrees()
            scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
            if worktreeManagerMounted { refreshWorktreeRepositories() }
        }
        return try await Task.detached(priority: .userInitiated) { [service] in
            try service.attach(existingPath: existingPath, in: repositoryFolder, baseRef: nil, teamSessionID: teamSessionID, requestedByPaneID: requestedByPaneID)
        }.value
    }

    private var otherRuntimeStateFiles: [URL] {
        ParleyRuntimeMode.allCases.filter { $0 != runtime.mode }.map {
            ParleyRuntime.make(mode: $0, homeDirectory: FileManager.default.homeDirectoryForCurrentUser).applicationDirectory
                .appendingPathComponent("workbench-state.json")
        }
    }

    /// Every pane folder this runtime knows, read fresh: started or stopped,
    /// any workspace. A stopped placeholder inside the tree would restart into
    /// a deleted folder, so it blocks removal too.
    private func livePaneFoldersForCleanup() throws -> [String] {
        guard let controller else { throw RelayUIError.message("The workbench is not available.") }
        return try controller.listPanes().flatMap(\.worktreeSafetyFolders)
    }

    /// Browser-only, on-demand read. No inspection runs from the refresh tick.
    func inspectWorktreeLifecycle(_ record: ManagedWorktreeRecord) async throws -> WorktreeLifecycleInspection {
        guard let service = managedWorktreeService, let controller else { throw RelayUIError.message("The workbench is unavailable.") }
        let currentPanes = try controller.listPanes()
        let currentWorkspaces = try controller.listWorkspaces()
        let history = statusHandoffs
        let teams = (residentCore?.teamSessions.sessions() ?? teamSessions).filter { !$0.state.isTerminal }.compactMap { $0.worktree?.path }
        let files = otherRuntimeStateFiles
        let task = Task.detached(priority: .utility) {
            try service.inspectLifecycle(record, panes: currentPanes, workspaces: currentWorkspaces, handoffs: history,
                activeTeamPaths: teams, otherRuntimeStateFiles: files)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func previewWorktreeMerge(_ record: ManagedWorktreeRecord, target: String) async throws -> WorktreeMergePreview {
        guard let service = managedWorktreeService else { throw RelayUIError.message("The workbench is unavailable.") }
        let task = Task.detached(priority: .userInitiated) { try service.mergePreview(record, targetRef: target) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func recoverWorktreeRecord(_ record: ManagedWorktreeRecord, to path: String) async throws {
        guard let service = managedWorktreeService else { throw RelayUIError.message("The workbench is unavailable.") }
        let alert = NSAlert()
        alert.messageText = "Update recorded worktree path?"
        alert.informativeText = "From: \(DelegationGitFacts.displayPath(record.path))\n\nTo: \(DelegationGitFacts.displayPath(path))\n\nParley rechecks the original creation marker and unchanged record. Only Parley's path record changes. Pane folders, workspaces, Git and files are untouched."
        alert.addButton(withTitle: "Update Recorded Path")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try beginManagedWorktreeMutation(.attach, path: path)
        defer { endManagedWorktreeMutation(); reloadManagedWorktrees(); scheduleManagedWorktreeFactsRefresh(force: true, scope: .all) }
        _ = try await Task.detached(priority: .userInitiated) { try service.relocateRecord(record, to: path) }.value
    }

    private func requireNoWorktreeTeamBinding(_ path: String) throws {
        let sessions = residentCore?.teamSessions.sessions() ?? teamSessions
        guard !sessions.contains(where: {
            !$0.state.isTerminal && $0.worktree.map { WorktreeCleanupPolicy.isNested($0.path, in: path) } == true
        }) else { throw RelayUIError.message("An active team is bound to this worktree. Choose Stop session in Team Sessions before removing its folder.") }
    }

    /// Reuses the existing fresh preview, folder reservation and removal checks.
    func removeManagedWorktree(_ record: ManagedWorktreeRecord) {
        guard let service = managedWorktreeService, let controller else { return }
        let stateFiles = otherRuntimeStateFiles
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.requireNoWorktreeTeamBinding(record.path)
                try self.beginManagedWorktreeMutation(.remove, path: record.path)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            // The controller's launch gate refuses every creation, start and
            // restart inside the tree from here until the defer below runs.
            do { try controller.reserveFolderForRemoval(record.path) } catch {
                self.endManagedWorktreeMutation()
                NSAlert(error: error).runModal()
                return
            }
            defer {
                controller.releaseFolderReservation(record.path)
                self.endManagedWorktreeMutation()
                self.reloadManagedWorktrees()
                self.scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
                self.scheduleWorktreeRefresh(force: true)
                if self.worktreeManagerMounted { self.refreshWorktreeRepositories() }
            }
            let folders: [String]
            do { folders = try self.livePaneFoldersForCleanup() } catch {
                NSAlert(error: error).runModal()
                return
            }
            let previewResult = await Task.detached(priority: .userInitiated) { [service, record, folders, stateFiles] in
                Result { try service.cleanupPreview(record, livePaneFolders: folders, otherRuntimeStateFiles: stateFiles) }
            }.value
            let preview: WorktreeCleanupPreview
            switch previewResult {
            case let .failure(error):
                NSAlert(error: error).runModal()
                return
            case let .success(value):
                preview = value
            }
            let alert = NSAlert()
            switch preview.decision {
            case let .refuse(reasons):
                alert.messageText = "This worktree cannot be removed"
                alert.informativeText = "\(DelegationGitFacts.displayPath(record.path))\n\nParley refused because:\n• " + reasons.map(DelegationGitFacts.displayPath).joined(separator: "\n• ")
                    + "\n\nNothing was changed. Resolve these in a terminal or close the panes, then try again."
                alert.alertStyle = .informational
                alert.runModal()
                return
            case .clearRecordOnly:
                alert.messageText = "Clear Parley's record of \(record.branch)?"
                alert.informativeText = "The folder \(DelegationGitFacts.displayPath(record.path)) no longer exists"
                    + (preview.facts.registered ? " and Git lists it as prunable." : " and Git no longer lists it.")
                    + " Parley will clear only its own record; no Git command runs, and the branch \(record.branch) is not touched."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Clear Record")
                alert.addButton(withTitle: "Cancel")
            case .removeTree:
                let ignored = preview.ignoredPaths
                alert.messageText = "Remove worktree \(record.branch)?"
                var lines = [
                    "Folder to delete: \(DelegationGitFacts.displayPath(record.path))",
                    "Branch \(record.branch) is kept; only the checkout is removed. Recorded base \(record.baseCommit.map { String($0.prefix(12)) } ?? "not recorded").",
                    "Checked just now: " + preview.preservationSummary + ".",
                ]
                if !record.parleyCreated {
                    lines.append("Parley did not create this tree, so there is no creation marker to compare. Its identity for this removal is Git's registry entry at the recorded path, checked just now.")
                }
                if ignored.isEmpty {
                    lines.append("No ignored files were found; Git removes only tracked content.")
                } else {
                    lines.append("\(ignored.count) ignored entr\(ignored.count == 1 ? "y is" : "ies are") not in Git and will be deleted with the folder. The complete list is below; an entry ending in / is a directory and means everything inside it.")
                }
                lines.append("Parley runs one git worktree remove without --force, re-checking everything first. Objects, refs, stashes and the branch stay in the repository.")
                alert.informativeText = lines.joined(separator: "\n\n")
                alert.alertStyle = .warning
                if !ignored.isEmpty {
                    alert.accessoryView = Self.reviewedPathList(ignored)
                }
                alert.addButton(withTitle: ignored.isEmpty ? "Remove Worktree" : "Remove Worktree and \(ignored.count) Ignored Entr\(ignored.count == 1 ? "y" : "ies")")
                alert.addButton(withTitle: "Cancel")
            }
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // The person may have opened or started a pane while the sheet was
            // up: the pane list is read again now, and the service re-reads
            // every Git fact inside remove before touching anything.
            let currentFolders: [String]
            do {
                try self.requireNoWorktreeTeamBinding(record.path)
                currentFolders = try self.livePaneFoldersForCleanup()
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            let acknowledged = preview.ignoredPaths
            let confirmed: WorktreeCleanupAction = preview.decision == .clearRecordOnly ? .clearRecordOnly : .removeTree
            let outcome = await Task.detached(priority: .userInitiated) { [service, record, confirmed, acknowledged, currentFolders, stateFiles] in
                Result { try service.remove(record, confirmed: confirmed, acknowledgedIgnoredPaths: acknowledged, livePaneFolders: currentFolders, otherRuntimeStateFiles: stateFiles) }
            }.value
            let result = NSAlert()
            switch outcome {
            case let .success(removal):
                switch removal.state {
                case .removed:
                    result.messageText = removal.recordRemoved ? "Worktree removed" : "Worktree removed; record not cleared"
                    result.alertStyle = removal.recordRemoved ? .informational : .warning
                    result.informativeText = removal.detail + (removal.recordRemoved ? "" : " Choose Remove… again to clear the record; Git will not run for an absent tree.")
                    if removal.recordRemoved, !record.branch.hasPrefix("(") {
                        result.informativeText += "\n\nThe branch \(record.branch) is kept. Delete Branch… runs one git branch -d, which Git refuses for an unmerged branch."
                        result.addButton(withTitle: "OK")
                        result.addButton(withTitle: "Delete Branch…")
                    }
                case .retained:
                    result.messageText = "Worktree not removed"
                    result.alertStyle = .warning
                    result.informativeText = removal.detail
                case .uncertain:
                    result.messageText = "Worktree state uncertain"
                    result.alertStyle = .critical
                    result.informativeText = removal.detail + " Parley kept its record and will not retry on its own."
                }
            case let .failure(error):
                result.messageText = "Worktree not removed"
                result.informativeText = error.localizedDescription + "\n\nNothing is deleted without Git's consent and Parley never adds --force."
                result.alertStyle = .warning
            }
            let response = result.runModal()
            if response == .alertSecondButtonReturn, case .success(let removal) = outcome, removal.state == .removed {
                // The primary checkout of an ordinary repository is the parent of its common directory.
                let common = URL(fileURLWithPath: record.commonDirectory)
                let primary = worktreeRepositories.first { $0.worktrees.contains(where: { $0.path == record.path }) }?.primaryPath
                    ?? (common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : nil)
                if let primary { self.deleteWorktreeBranch(record.branch, in: primary) }
            }
        }
    }

    /// The complete reviewed list of paths in a scrollable, read-only view.
    /// Paths are escaped so control or invisible characters cannot hide or
    /// spoof an entry.
    private static func reviewedPathList(_ paths: [String]) -> NSView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = paths.map(DelegationGitFacts.displayPath).joined(separator: "\n")
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: min(180, CGFloat(paths.count) * 16 + 14)))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    var paletteCommands: [PaletteCommand] {
        if commandPaletteScope == .workspaces { return workspaceSwitcherCommands }
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

        let activity = latestKnownHandoffs
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
        commandPaletteScope = .everything
        commandPalettePresented = true
    }

    /// The palette with workspaces only, in `WorkspaceSwitcherOrder`.
    func showWorkspaceSwitcher() {
        commandPaletteScope = .workspaces
        commandPalettePresented = true
    }

    private var workspaceSwitcherCommands: [PaletteCommand] {
        let index = workspaceActivityIndex
        let byID = Dictionary(workspaces.map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        let groupNames = Dictionary(workspaceGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        return WorkspaceSwitcherOrder.ordered(workspaces: workspaces, needsPerson: { index.activity(for: $0).needsPerson })
            .compactMap { id -> PaletteCommand? in
                guard let workspace = byID[id] else { return nil }
                let group = workspace.groupID.flatMap { groupNames[$0] }
                let needs = index.activity(for: id).needsPerson
                var detail = [group].compactMap { $0 }
                if workspace.isActive {
                    detail.append("Current")
                } else if needs > 0 {
                    detail.append("\(needs) waiting on you")
                } else if let used = workspace.lastSelectedAt {
                    detail.append("Last used \(WorkspaceRecency.label(for: used, now: now))")
                }
                detail.append(workspace.newPaneFolder ?? workspace.primaryAttachedFolder ?? "No folders attached")
                return PaletteCommand(
                    item: CommandPaletteItem(
                        id: "workspace:\(workspace.id)",
                        category: .workspace,
                        title: workspace.name,
                        detail: detail.joined(separator: " · "),
                        keywords: [group ?? "", workspace.isActive ? "current selected" : "open"] + workspace.attachedFolders
                    ),
                    action: .selectWorkspace(workspace)
                )
            }
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

    /// The person's own pack, or an agent's draft awaiting review, takes a
    /// window capture.
    var canCaptureWindowIntoContextPack: Bool {
        guard let draft = contextPackDraft, !contextPackCaptureRunning else { return false }
        return draft.reviewID == nil || draft.reviewState?.needsHumanReview == true
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
        guard !contextPackCaptureRunning,
              let draft = contextPackDraft,
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

    func canRun(_ recipe: HandoffRecipe) -> Bool {
        guard let workspace = activeWorkspace,
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
    /// Delivered a minute ago or more and the target, which reports turns,
    /// has not started one (advisory).
    func handoffNotStarted(_ handoff: RelayHandoff, at now: Date) -> Bool {
        HandoffStartProjection.notStarted(handoff, target: panes.first { $0.id == handoff.targetPaneID }, now: now)
    }

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
        let generation = attentionInputGeneration
        var byID: [String: RelayHandoff] = [:]
        // Inputs are only merged when the cache misses; a hit returns at once.
        if attentionCache.hasItems(for: generation) {
            return attentionCache.items(generation: generation, panes: panes, handoffs: [])
        }
        for handoff in unreadHandoffs + statusHandoffs + handoffs {
            byID[handoff.id] = handoff
        }
        return attentionCache.items(generation: generation, panes: panes, handoffs: Array(byID.values))
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
            _ = openAttentionNavigation(.pane(item.paneID))
            return false
        }
        if let handoffID = item.handoffID {
            return openAttentionNavigation(.handoff(handoffID))
        }
        if canFocus(item.paneID) {
            _ = openAttentionNavigation(.pane(item.paneID))
        }
        return false
    }
    /// Focus one live pane or open one Status Center handoff from an attention
    /// item. Returns true when Status Center should be presented.
    func openAttentionNavigation(_ request: AttentionNavigationRequest) -> Bool {
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
            let history = latestKnownHandoffs
            guard history.contains(where: { $0.id == handoffID }) else {
                NSAlert(error: RelayUIError.message("That Parley handoff is no longer in the local Status Center record.")).runModal()
                return false
            }
            requestedStatusHandoffID = handoffID
            return true
        }
    }

    func unreadResultCount(forPane paneID: String) -> Int {
        unreadHandoffs.count { $0.sourcePaneID == paneID }
    }

    /// Every workspace's badges and needs-you count from one pass over the
    /// handoffs, once per input generation. Each helper below used to scan
    /// every handoff for its workspace, several times per sidebar row and on
    /// every render, which grew with both at many workspaces.
    private var workspaceActivityIndex: WorkspaceActivityIndex {
        let now = Date()
        return workspaceActivityCache.index(generation: attentionInputGeneration, now: now) {
            var byID: [String: RelayHandoff] = [:]
            for handoff in unreadHandoffs + statusHandoffs + handoffs {
                byID[handoff.id] = handoff
            }
            return WorkspaceActivityProjection.index(workspaces: workspaces, panes: panes, handoffs: handoffs,
                                                     unreadHandoffs: unreadHandoffs, attentionHandoffs: Array(byID.values), now: now)
        }
    }

    func workspaceActivity(for workspaceID: String) -> WorkspaceActivity {
        workspaceActivityIndex.activity(for: workspaceID)
    }

    /// The sidebar's sections, in the workspace order.
    var workspaceSidebarSections: WorkspaceSidebarSections {
        let index = workspaceActivityIndex
        return WorkspaceSidebarSections.derive(workspaces: workspaces, groups: workspaceGroups, needsPerson: { index.activity(for: $0).needsPerson })
    }

    func unreadResultCount(forWorkspace workspaceID: String) -> Int {
        workspaceActivity(for: workspaceID).unreadResults
    }

    func waitingCount(for workspaceID: String) -> Int {
        workspaceActivity(for: workspaceID).waiting
    }

    func failureCount(for workspaceID: String) -> Int {
        workspaceActivity(for: workspaceID).failures
    }

    func requiresHumanAttention(_ workspaceID: String) -> Bool {
        workspaceActivity(for: workspaceID).requiresHumanAttention
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
        if coordinator.automaticApprovalEnabled != automaticCommandRunApprovalEnabled {
            coordinator.setAutomaticApproval(automaticCommandRunApprovalEnabled)
        }
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
                let previouslyActive = (try? controller.listPanes())?.first(where: \.isActive)?.id
                let exitWhenClean = automaticCommandRunPaneCloseEnabled
                let created = try controller.createApprovedCommandPane(run: run, workerExecutable: executable, exitWhenClean: exitWhenClean)
                commandRunPaneCleanup.recordLaunch(runID: run.id, paneID: created.id, paneGeneration: created.launchGeneration,
                    exitsWhenClean: exitWhenClean, previousActivePaneID: previouslyActive)
                focusCanvasPaneID = nil
                // An agent run's Shell splits beside the requesting pane; a run the
                // person proposed splits beside whatever is active in its workspace.
                let splitTarget = run.source
                    ?? panes.first(where: { $0.workspaceID == run.workspaceID && $0.isActive })
                    ?? panes.first(where: { $0.workspaceID == run.workspaceID })
                recordNativeSplit(created: created, target: splitTarget, direction: .vertical)
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
        closeFinishedCommandRunPanes(runs, coordinator: coordinator, directory: core.commandRunDirectory)
        if runs != commandRuns {
            // A run the person proposed from the worktree board (Integrate…)
            // changes what the board should say once it ends, and a tree with
            // no pane inside is outside the periodic facts scope.
            let finishedBefore = Set(commandRuns.filter { $0.origin == .person && $0.state.isTerminal }.map(\.id))
            let finishedNow = runs.filter { $0.origin == .person && $0.state.isTerminal }.map(\.id)
            commandRuns = runs
            if finishedNow.contains(where: { !finishedBefore.contains($0) }) {
                scheduleManagedWorktreeFactsRefresh(force: true, scope: .all)
                refreshWorktreeManagerFacts()
            }
        }
        if grants != commandRunGrants { commandRunGrants = grants }
        let commandRunMessage = coordinator.lastError ?? (core.commandRunCleanupWarnings.isEmpty ? nil : core.commandRunCleanupWarnings.joined(separator: "\n"))
            ?? commandRunPaneCloseError
        if commandRunError != commandRunMessage { commandRunError = commandRunMessage }
        refreshCommandRunAttention()
    }

    /// Runs inside the ordinary refresh, before panes are re-listed, so a
    /// removed pane disappears in the same pass. Every fact comes from a fresh
    /// controller read and the decision from `CommandRunPaneCleanup`: only a
    /// pane whose worker exited without handing over a shell is ever closed,
    /// even though Ghostty keeps showing the surface until a key is pressed.
    /// Never calls refresh() itself.
    private func closeFinishedCommandRunPanes(_ runs: [ReviewedCommandRun], coordinator: ReviewedCommandRunCoordinator, directory: URL) {
        // A refresh raised by a synchronous close report arrives while the
        // controller is still inside a lifecycle mutation; leave it for the
        // next tick rather than counting it as a failed close.
        guard !closingCommandRunPanes, let controller, !controller.isTerminatingSurface,
              let current = try? controller.listPanes() else { return }
        closingCommandRunPanes = true
        defer { closingCommandRunPanes = false }
        let facts = current.map { CommandRunPaneCleanup.PaneFacts(id: $0.id, launchGeneration: $0.launchGeneration, isStarted: $0.isStarted, isDead: $0.isDead) }
        // Newest first from the tracker, so a chain of run panes unwinds back
        // to the pane the person started from.
        for decision in commandRunPaneCleanup.decisions(runs: runs, panes: facts) {
            guard case let .close(runID, paneID, recordedRestore) = decision else { continue }
            do {
                // Re-read right before acting: the person may have moved, and an
                // earlier close in this pass may have removed the recorded target.
                let fresh = try controller.listPanes()
                guard let pane = fresh.first(where: { $0.id == paneID && $0.kind == .shell }) else {
                    commandRunPaneCleanup.didFailToClose(runID: runID)
                    continue
                }
                // The decision used the cached lease flag; take the kernel fact
                // now. A worker still in its exit delay keeps the pane one more
                // tick (not counted as a failed attempt).
                guard coordinator.workerLeaseReleased(id: runID, directory: directory) else { continue }
                let wasActive = pane.isActive
                try controller.closePane(paneID)
                commandRunPaneCleanup.didClose(runID: runID)
                // Only this run's own explanation is repaired by its success.
                commandRunPaneCloseErrors.removeValue(forKey: runID)
                if focusCanvasPaneID == paneID { focusCanvasPaneID = nil }
                if handoffComposerDraft?.sourcePaneID == paneID || handoffComposerDraft?.targetPaneID == paneID {
                    handoffComposerDraft = nil
                }
                // Give focus back only if the person was still on the run's
                // pane; a focus choice they made in the meantime is theirs.
                guard wasActive else { continue }
                let remaining = try controller.listPanes()
                let remainingFacts = remaining.map { CommandRunPaneCleanup.PaneFacts(id: $0.id, launchGeneration: $0.launchGeneration, isStarted: $0.isStarted, isDead: $0.isDead) }
                guard let restoreTo = commandRunPaneCleanup.restoreTarget(from: recordedRestore, panes: remainingFacts),
                      let target = remaining.first(where: { $0.id == restoreTo }) else { continue }
                do {
                    try controller.selectPane(target.id)
                    _ = try? workspaceRegistry.updateSelectedPane(workspaceID: target.workspaceID, paneID: target.id)
                } catch {
                    commandRunPaneCloseErrors[runID] = "The finished run's pane was closed, but focus could not return to \(target.displayName): \(error.localizedDescription)"
                }
            } catch {
                let gaveUp = commandRunPaneCleanup.didFailToClose(runID: runID)
                commandRunPaneCloseErrors[runID] = "The finished run's pane could not be closed automatically\(gaveUp ? " and stays open" : "; Parley will retry"): \(error.localizedDescription)"
            }
        }
        // Explanations for runs no longer listed at all can go.
        let listed = Set(runs.map(\.id))
        let pruned = commandRunPaneCloseErrors.filter { listed.contains($0.key) }
        if pruned != commandRunPaneCloseErrors { commandRunPaneCloseErrors = pruned }
    }

    private func refreshCommandRunAttention() {
        let mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Parley" }
        // Include requested sheets that SwiftUI has not mounted yet. Keep
        // menus, native alerts, settings and other windows' edits undisturbed.
        let anotherPresentation = commandPalettePresented || setupPresented || teamSessionsPresented
            || panePermissionRequest != nil || paneChoiceRequest != nil
            || askManyComparisonPresented || contextPackPresented
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


    private func refreshTeamSessions() {
        guard let core = residentCore, let controller else { return }
        let coordinator = core.teamSessions
        coordinator.reconcile()
        let mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Parley" }
        // The Team Sessions sheet is the monitoring surface and never blocks
        // creation. Any other sheet, a modal or a hidden window does, and a
        // visible window is never activated or reordered for a creation.
        let allowed = TeamProvisioningPresentation.allowsCreation(
            teamSheetPresented: teamSessionsPresented,
            commandRunsPresented: commandRunsPresented,
            otherSheetAttached: mainWindow?.attachedSheet != nil,
            modalWindowPresent: NSApp.modalWindow != nil,
            mainWindowVisible: mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
        )
        if allowed, !coordinator.pendingProvisions().isEmpty {
            coordinator.fulfilProvisions(create: { session, grant, provision in
                // Resolve from the approved snapshot, never from a newer store.
                let profile = try PermissionProfileResolver.resolve(
                    definition: grant.approvedProfile,
                    paneFolder: grant.folder,
                    approvedRoots: grant.approvedRoots,
                    approvals: grant.approvals(for: provision.kind)
                )
                return try controller.createTeamPane(session: session, grant: grant, provision: provision, permissionProfile: profile)
            }, mount: { session, created in
                // Ownership precedes both asynchronous Docker preparation and mounting.
                if created.containerConfiguration != nil {
                    try prepareTeamContainer(session: session, pane: created)
                } else {
                    try presentTeamPane(session: session, pane: created)
                }
            })
        }
        let sessions = coordinator.sessions()
        if sessions != teamSessions { teamSessions = sessions }
        if teamSessionError != coordinator.lastError { teamSessionError = coordinator.lastError }
        refreshTeamSessionAttention()
    }

    private func presentTeamPane(session: TeamSession, pane: WorkbenchPane) throws {
        guard let controller else { throw TeamSessionError.invalid("The workbench is unavailable.") }
        focusCanvasPaneID = nil
        recordNativeSplit(created: pane, target: panes.first { $0.id == session.source.id }, direction: .vertical)
        panes = try controller.listPanes()
        workspaces = try controller.listWorkspaces()
        _ = try ghosttyRegistry.view(for: pane.id)
        if NSApp.isActive { ghosttyRegistry.select(paneID: pane.id) }
        rememberFolder(pane.cwd)
    }

    private func prepareTeamContainer(session: TeamSession, pane: WorkbenchPane) throws {
        guard let controller, let coordinator = residentCore?.teamSessions,
              let grant = coordinator.grant(for: session.id),
              let configuration = grant.containerConfigurations?[pane.kind.rawValue],
              let provision = coordinator.pendingProvisions().first(where: { $0.paneID == pane.id }) else {
            throw TeamSessionError.invalid("The container preparation no longer has its approved grant.")
        }
        let profile = try PermissionProfileResolver.resolve(definition: grant.approvedProfile, paneFolder: grant.folder, approvedRoots: grant.approvedRoots,
            approvals: grant.approvals(for: pane.kind))
        Task {
            do {
                let approved = try coordinator.containerPreparation(id: provision.id)
                guard approved.grant == grant, approved.pane.launchGeneration == pane.launchGeneration,
                      approved.pane.cwd == pane.cwd, approved.pane.workspaceID == pane.workspaceID,
                      approved.pane.permissionSelection == pane.permissionSelection else {
                    throw TeamSessionError.invalid("The team pane changed before container preparation.")
                }
                try await Task.detached(priority: .userInitiated) {
                    try controller.prepareContainerStart(pane.id, configuration: configuration, permissionProfile: profile)
                }.value
                try coordinator.finishContainerProvision(id: provision.id, activate: { approved, current in
                    guard approved == grant else { throw TeamSessionError.invalid("The approved container grant changed.") }
                    try controller.startPane(current.id, permissionProfile: profile, containerConfiguration: configuration)
                    return try controller.listPanes().first { $0.id == current.id }!
                }, mount: { session, started in try presentTeamPane(session: session, pane: started) })
            } catch {
                var reason = "The team pane was created but its container did not start: \(error.localizedDescription)"
                do {
                    guard let current = try controller.listPanes().first(where: { $0.id == pane.id }),
                          coordinator.sessions().first(where: { $0.id == session.id })?.members.contains(where: { $0.owns(current) }) == true else {
                        throw TeamSessionError.invalid("The pane changed generation; its replacement was left alone.")
                    }
                    try await Task.detached(priority: .userInitiated) { try controller.prepareContainerStop(current, requiringWorkspace: false) }.value
                    // Cleanup is confirmed. A pane started again meanwhile is a
                    // new session, left alone; that is not a cleanup failure.
                    if let now = try? controller.listPanes().first(where: { $0.id == pane.id }), now.launchGeneration != current.launchGeneration {
                        reason += " Its container was removed. The pane was started again meanwhile; that session was left alone."
                    } else {
                        do { try controller.stopPaneProcess(current.id, expectedGeneration: current.launchGeneration) }
                        catch { reason += " Its container was removed, but the pane could not be marked stopped: \(error.localizedDescription)" }
                    }
                } catch { reason += " Cleanup was not confirmed: \(error.localizedDescription) Use Status Center to remove its recorded container." }
                coordinator.failContainerProvision(id: provision.id, reason: reason)
            }
            try? refresh()
        }
    }

    private func refreshTeamSessionAttention() {
        let mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Parley" }
        let anotherPresentation = commandPalettePresented || setupPresented || commandRunsPresented
            || panePermissionRequest != nil || paneChoiceRequest != nil
            || askManyComparisonPresented || contextPackPresented
            || releaseLifecyclePresented || betaFeedbackPresented
            || handoffComposerDraft != nil || startupError != nil
        let canPresent = mainWindow?.isKeyWindow == true
            && mainWindow?.isVisible == true && mainWindow?.isMiniaturized == false
            && NSApp.modalWindow == nil && !anotherPresentation
            && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
            && RunLoop.main.currentMode != .eventTracking
        let decision = teamSessionAttention.update(
            pendingIDs: pendingTeamSessionIDs, reviewPresented: teamSessionsPresented,
            canPresent: canPresent, applicationActive: NSApp.isActive
        )
        if decision.requestDockAttention {
            _ = NSApp.requestUserAttention(.informationalRequest)
        }
        if let id = decision.presentRunID {
            selectedTeamSessionID = id
            teamSessionsPresented = true
        }
    }

    func reviewTeamSessions() {
        if let session = teamSessions.first(where: { $0.state == .pending })
            ?? teamSessions.first(where: { $0.state == .active }) ?? teamSessions.first {
            selectTeamSession(session)
        }
        teamSessionsPresented = true
    }

    func selectTeamSession(_ session: TeamSession) {
        selectedTeamSessionID = session.id
        if session.state == .pending { teamSessionAttention.didPresent(runID: session.id) }
    }

    func dismissTeamSessionReview() {
        guard teamSessionsPresented else { return }
        teamSessionAttention.didDismiss(pendingIDs: pendingTeamSessionIDs)
        teamSessionsPresented = false
    }

    func approveTeamSession(_ session: TeamSession, objective: String, folder: String, allowedVendors: [PaneKind],
                            permissionProfileID: String, paneLimit: Int, hours: Int, containerConfigurations: [String: ContainerConfiguration]? = nil,
                            hostApprovals: [String: PermissionApprovalHandling]? = nil) async throws {
        guard let core = residentCore else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
        try core.teamSessions.preflightApproval(id: session.id, revision: session.revision, objective: objective, folder: folder,
            allowedVendors: allowedVendors, permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours, folderExists: true)
        try await preflightHostTeam(folder: folder, allowedVendors: allowedVendors, profileID: permissionProfileID, containers: containerConfigurations)
        try core.teamSessions.approve(id: session.id, revision: session.revision, objective: objective, folder: folder,
            allowedVendors: allowedVendors, permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours, containerConfigurations: containerConfigurations,
            hostApprovals: hostApprovals)
        teamSessions = core.teamSessions.sessions()
        selectedTeamSessionID = session.id
    }

    private func preflightHostTeam(folder: String, allowedVendors: [PaneKind], profileID: String,
                                   containers: [String: ContainerConfiguration]?) async throws {
        guard allowedVendors.contains(.codex), containers?[PaneKind.codex.rawValue] == nil else { return }
        guard let controller, let definition = permissionProfiles.first(where: { $0.id == profileID }) else {
            throw TeamSessionError.invalid("The reviewed host permission profile is unavailable.")
        }
        let profile = try PermissionProfileResolver.resolve(definition: definition, paneFolder: folder,
            approvedRoots: definition.rootMode == .exactApprovedRoots ? [folder] : [])
        try await Task.detached(priority: .userInitiated) {
            try controller.preflightHostLaunch(folder: folder, profile: profile)
        }.value
        guard try permissionProfileStore.profiles().contains(definition) else {
            throw TeamSessionError.invalid("The profile changed during the host tool check. Review the team again.")
        }
    }

    /// Approval bound to a worktree. Git work runs off the main thread first;
    /// the grant is then bound to exactly the resulting folder. A tree that
    /// was created but whose approval then failed is reported as such and
    /// stays as a Parley-created worktree the person can select or remove.
    func approveTeamSession(_ session: TeamSession, objective: String, folder: String, allowedVendors: [PaneKind],
                            permissionProfileID: String, paneLimit: Int, hours: Int, worktree: TeamWorktreeChoice, containerConfigurations: [String: ContainerConfiguration]? = nil,
                            hostApprovals: [String: PermissionApprovalHandling]? = nil) async throws {
        guard let core = residentCore else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
        let record: ManagedWorktreeRecord
        switch worktree {
        case .ordinaryFolder:
            try await approveTeamSession(session, objective: objective, folder: folder, allowedVendors: allowedVendors,
                permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours, containerConfigurations: containerConfigurations,
                hostApprovals: hostApprovals)
            return
        case let .existing(path):
            // Authority and containment first; Git only after the approval would pass.
            try core.teamSessions.preflightApproval(id: session.id, revision: session.revision, objective: objective, folder: path,
                allowedVendors: allowedVendors, permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours, folderExists: true)
            record = try await attachManagedWorktree(existingPath: path, repositoryFolder: folder, teamSessionID: session.id, requestedByPaneID: session.source.id)
        case let .create(preview):
            try core.teamSessions.preflightApproval(id: session.id, revision: session.revision, objective: objective, folder: preview.path,
                allowedVendors: allowedVendors, permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours, folderExists: false)
            record = try await createManagedWorktree(preview: preview, repositoryFolder: folder, teamSessionID: session.id, requestedByPaneID: session.source.id)
        }
        do {
            try await preflightHostTeam(folder: record.path, allowedVendors: allowedVendors, profileID: permissionProfileID, containers: containerConfigurations)
            try core.teamSessions.approve(id: session.id, revision: session.revision, objective: objective, folder: record.path,
                allowedVendors: allowedVendors, permissionProfileID: permissionProfileID, paneLimit: paneLimit, hours: hours,
                worktree: TeamWorktreeBinding(record: record), containerConfigurations: containerConfigurations, hostApprovals: hostApprovals)
        } catch {
            teamSessions = core.teamSessions.sessions()
            if case .create = worktree {
                throw RelayUIError.message("The worktree \(record.branch) was created at \(record.path), but the team session was not approved: \(error.localizedDescription) The tree stays as a Parley-created worktree; approve again by selecting it as an existing worktree, or remove it from the worktree browser. Do not create it a second time.")
            }
            throw error
        }
        teamSessions = core.teamSessions.sessions()
        selectedTeamSessionID = session.id
    }

    func rejectTeamSession(_ session: TeamSession) {
        perform {
            guard let core = residentCore else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
            try core.teamSessions.reject(id: session.id, revision: session.revision)
            teamSessions = core.teamSessions.sessions()
            try refresh()
        }
    }

    /// Stops only the panes this session created and still owns (same pane id
    /// and created generation); the lead and unrelated panes keep running.
    /// The disclosure names exactly that before the click.
    func stopTeamSession(_ session: TeamSession) {
        let alert = NSAlert()
        alert.messageText = "Stop team session?"
        alert.informativeText = TeamSessionDisclosure.stop
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let core = residentCore else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
            let members = try core.teamSessions.stop(id: session.id, reason: "Stopped by the person")
            Task {
                do { try await finishStoppingTeamPanes(sessionID: session.id, members: members) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    /// After provisioning authority ended (expiry, interruption or an earlier
    /// Stop with failures), the person can still stop surviving owned panes.
    /// Provisioning stays revoked; this never re-creates authority.
    func stopTeamPanes(_ session: TeamSession) {
        let alert = NSAlert()
        alert.messageText = "Stop team panes?"
        alert.informativeText = TeamSessionDisclosure.stop
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Team Panes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let core = residentCore else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
            let members = try core.teamSessions.ownedMembers(id: session.id)
            Task {
                do { try await finishStoppingTeamPanes(sessionID: session.id, members: members) }
                catch { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Closes the stopped placeholders this session created, each named in one
    /// confirmation. Ownership is re-read from the live workbench after the
    /// confirmation, so a pane the person restarted meanwhile is skipped and
    /// reported rather than closed. A workspace left with no panes stays.
    func closeStoppedTeamPanes(_ session: TeamSession) {
        let candidates = session.stoppedPlaceholders(in: panes)
        guard !candidates.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Close \(candidates.count) stopped team pane\(candidates.count == 1 ? "" : "s")?"
        alert.informativeText = candidates.map { "• \($0.displayName)" }.joined(separator: "\n")
            + "\n\nThese are stopped placeholders this session created. Closing removes them from the workspace. Nothing running is touched, and a pane you restarted since is skipped."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Stopped Panes")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performAfterContainerStops(candidates) { [self] in
            guard let controller else { return }
            let outcome = TeamPlaceholderClosing.close(candidates,
                stillStopped: { id in session.stoppedPlaceholders(in: try controller.listPanes()).contains { $0.id == id } },
                close: { id in
                    try controller.closePane(id)
                    if focusCanvasPaneID == id { focusCanvasPaneID = nil }
                })
            // Refresh whatever happened: some panes may have closed.
            var refreshFailure: String?
            do { try refresh() } catch { refreshFailure = error.localizedDescription }
            let name = { (id: String) in candidates.first { $0.id == id }?.displayName ?? id }
            let lines = outcome.skipped.map { "\(name($0)) (no longer a stopped placeholder of this session)" }
                + outcome.failed.map { "\(name($0.paneID)) (could not be closed: \($0.reason))" }
                + (refreshFailure.map { ["The window could not be refreshed afterwards: \($0)"] } ?? [])
            if !lines.isEmpty {
                let note = NSAlert()
                note.messageText = "Some panes were not closed"
                note.informativeText = lines.joined(separator: "\n")
                note.alertStyle = outcome.failed.isEmpty ? .informational : .warning
                note.runModal()
            }
        }
    }

    /// Executes the pure stop plan against the workbench and records exactly
    /// what happened per owned generation. Process state and recording
    /// failure are kept distinct: a pane that stopped but could not be
    /// recorded is reported as stopped-but-unrecorded, never as still running.
    private func finishStoppingTeamPanes(sessionID: String, members: [TeamSessionMember]) async throws {
        guard let core = residentCore, let controller else { throw TeamSessionError.invalid("The native team session service is unavailable.") }
        // Planning needs fresh workbench state; a cached list could stop the wrong generation.
        let live: [WorkbenchPane]
        do { live = try controller.listPanes() } catch {
            throw RelayUIError.message("The workbench state could not be read, so no team pane was stopped: \(error.localizedDescription)")
        }
        let containers = TeamStopPlanner.containerCleanup(members: members, live: live)
        let cleanupFailures = await Task.detached(priority: .userInitiated) {
            var failures: [String: String] = [:]
            for pane in containers {
                do { try controller.prepareContainerStop(pane, requiringWorkspace: false) }
                catch { failures[pane.id] = error.localizedDescription }
            }
            return failures
        }.value
        let current = try controller.listPanes()
        // A preparation may have ended during the cleanup above; plan from the
        // members as they are now, not as `stop` returned them.
        let planned = (try? core.teamSessions.ownedMembers(id: sessionID)) ?? members
        let outcomes = TeamStopExecution.execute(
            plan: TeamStopPlanner.plan(members: planned, live: current),
            stop: { id in
                if let failure = cleanupFailures[id] { throw ContainerPaneError.refused(failure) }
                try controller.stopPaneProcess(id, expectedGeneration: planned.first { $0.paneID == id }?.launchGeneration)
            },
            currentPane: { id in (try? controller.listPanes())?.first { $0.id == id } }
        )
        let recordedOutcomes = outcomes.map { outcome in
            if let failure = cleanupFailures[outcome.paneID], let member = planned.first(where: { $0.paneID == outcome.paneID }),
               current.contains(where: { member.owns($0) }) {
                return TeamMemberStopOutcome(paneID: outcome.paneID, launchGeneration: outcome.launchGeneration, name: outcome.name, result: .failed, message: failure)
            }
            return outcome
        }
        let attempt = TeamStopAttempt(reason: "Stopped by the person", outcomes: recordedOutcomes)
        core.teamSessions.recordStopAttempt(id: sessionID, attempt: attempt)
        teamSessions = core.teamSessions.sessions()
        try refresh()
        let failed = recordedOutcomes.filter { [.failed, .stoppedUnrecorded, .unknown].contains($0.result) }
        if !failed.isEmpty {
            throw RelayUIError.message("Some team panes did not stop cleanly:\n" + failed.map { "\($0.name): \($0.result.label). \($0.message ?? "")" }.joined(separator: "\n")
                + "\n\nThe session shows the recorded outcome; Stop team panes retries any owned generation still running.")
        }
    }

    func refresh(includingRelay: Bool = true) throws {
        if includingRelay {
            refreshGate.invalidate()
            // A direct mutation or explicit refresh: the next tick must fetch.
            // So must the status history fetch; a new broker (core recovery)
            // also counts its revision from zero again.
            lastAppliedRelayRevision = nil
            lastAppliedStatusRevision = nil
            // Parley's own action may have created or removed a folder.
            folderIdentity.invalidate()
        }
        refreshCommandRuns()
        refreshTeamSessions()
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
                let refreshedGroups = try controller.listWorkspaceGroups()
                if refreshedGroups != workspaceGroups { workspaceGroups = refreshedGroups }
                let refreshedPanes = try controller.listPanes()
                if refreshedPanes != panes { panes = refreshedPanes }
                ghosttyRegistry.retainOnly(paneIDs: Set(refreshedPanes.map(\.id)))
                ghosttyRegistry.select(paneID: refreshedPanes.first(where: \.isActive)?.id)
                var selectedPaneIDs: [String: String] = [:]
                if let active = refreshedPanes.first(where: \.isActive) {
                    selectedPaneIDs[active.workspaceID] = active.id
                }
                // Every live workspace, never a subset: the registry makes room
                // for a new workspace by dropping records whose workspace is
                // absent from this list. A write failure must not break refresh.
                _ = try? workspaceRegistry.synchronize(
                    workspaces: refreshedWorkspaces,
                    selectedPaneIDs: selectedPaneIDs
                )
                reconcileNativeLayouts(workspaces: refreshedWorkspaces, panes: refreshedPanes)
                if !terminalAvailable { terminalAvailable = true }
                if terminalError != nil { terminalError = nil }
            } catch {
                if terminalAvailable { terminalAvailable = false }
                let message = error.localizedDescription
                if terminalError != message { terminalError = message }
                firstError = error
            }
        } else if terminalAvailable {
            terminalAvailable = false
        }
        if includingRelay {
            if let relayClient {
                let result = Result { try Self.fetchRelaySnapshot(relayClient) }
                applyRelaySnapshot(result)
                if case let .failure(error) = result, firstError == nil { firstError = error }
            } else if coreAvailable {
                coreAvailable = false
            }
        }
        if terminalAvailable {
            scheduleProjectContextRefresh()
            schedulePaneListeningPortRefresh()
            scheduleWorktreeRefresh()
        }
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
                    ),
                    permissionProfiles: { [permissionProfileStore] in try permissionProfileStore.profiles() },
                    retainingPersonImages: wantedPersonImages
                )
                residentCore = core
                relayClient = core.client
            }
        }
        try refresh()
        startupError = nil
    }

    /// Title-only changes: publish the controller's pane list once per
    /// run-loop turn, equality-guarded, with no relay sockets, layout
    /// reconciliation or background scheduling. Titles are not rendered by
    /// any view today, so this only keeps `panes` consistent.
    private func schedulePaneStatePublish() {
        guard !paneStatePublishScheduled else { return }
        paneStatePublishScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.paneStatePublishScheduled = false
            guard let controller = self.controller, let refreshed = try? controller.listPanes(), refreshed != self.panes else { return }
            self.panes = refreshed
        }
    }

    func refreshQuietly() {
        do { try refresh(includingRelay: false) } catch { /* a retained surface or broker may be between lifecycle events */ }
        refreshRelayStateInBackground()
    }

    /// What one relay refresh reads. Fetched and decoded off the main actor
    /// for the periodic tick; applied on it with the usual equality guards.
    private struct RelayRefreshSnapshot: Sendable {
        let consultations: [RelayConsultation]
        let handoffs: [RelayHandoff]
        let unread: [RelayHandoff]
        let contextReviews: [AgentContextReview]
        let busyDrafts: [ReviewedBusyDraft]
    }

    private nonisolated static func fetchRelaySnapshot(_ client: RelayCoreClient) throws -> RelayRefreshSnapshot {
        RelayRefreshSnapshot(
            consultations: try client.consultations(),
            handoffs: try client.handoffs(limit: 24),
            unread: try client.unreadHandoffs(),
            contextReviews: try client.contextReviews(),
            busyDrafts: try client.reviewedBusyDrafts()
        )
    }

    private func refreshRelayStateInBackground() {
        guard let relayClient else {
            if coreAvailable { coreAvailable = false }
            return
        }
        guard !relayRefreshInFlight else { return }
        // The broker is in this process: if nothing it holds changed since the
        // snapshot we applied, the five round trips would return the same data.
        let revision = residentCore?.broker.stateRevision()
        if let revision, !RelayPollPolicy.shouldFetch(revision: revision, lastApplied: lastAppliedRelayRevision, ticksSinceFetch: relayTicksSinceFetch) {
            relayTicksSinceFetch += 1
            return
        }
        relayRefreshInFlight = true
        let token = refreshGate.token()
        let client = relayClient
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try Self.fetchRelaySnapshot(client) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.relayRefreshInFlight = false
                // A synchronous refresh or direct mutation ran meanwhile and holds newer state.
                guard self.refreshGate.accepts(token) else { return }
                self.applyRelaySnapshot(result)
                if case .success = result {
                    // The revision read before the fetch: a change during the
                    // fetch advances it and the next tick fetches again.
                    self.lastAppliedRelayRevision = revision
                    self.relayTicksSinceFetch = 0
                }
            }
        }
    }

    /// Applies fetched relay state with equality guards so an unchanged tick
    /// publishes nothing. Used by both the synchronous and background paths.
    private func applyRelaySnapshot(_ result: Result<RelayRefreshSnapshot, Error>) {
        switch result {
        case let .success(snapshot):
            if snapshot.consultations != consultations { consultations = snapshot.consultations }
            if snapshot.handoffs != handoffs { handoffs = snapshot.handoffs }
            if snapshot.unread != unreadHandoffs { unreadHandoffs = snapshot.unread }
            if snapshot.contextReviews != contextReviews {
                contextReviews = snapshot.contextReviews
                if let id = contextPackDraft?.reviewID,
                   !snapshot.contextReviews.contains(where: { $0.id == id }) {
                    contextPackDraft = nil
                    contextPackPresented = false
                }
                if var draft = contextPackDraft,
                   let reviewID = draft.reviewID,
                   let review = snapshot.contextReviews.first(where: { $0.id == reviewID }) {
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
            if snapshot.busyDrafts != reviewedBusyDrafts { reviewedBusyDrafts = snapshot.busyDrafts }
            processNotifications(from: snapshot.handoffs + snapshot.unread)
            if !coreAvailable { coreAvailable = true }
            if coreError != nil { coreError = nil }
        case let .failure(error):
            if coreAvailable { coreAvailable = false }
            let message = error.localizedDescription
            if coreError != message { coreError = message }
        }
    }

    /// The Status Center timer's refresh: history and activity are fetched
    /// and decoded off the main actor, and no second full tick runs. Explicit
    /// actions keep using the synchronous `refreshStatusCenterQuietly()`.
    func refreshStatusCenterPeriodically() {
        let persistence = residentCore?.historyPersistenceError
        if historyPersistenceError != persistence { historyPersistenceError = persistence }
        guard let relayClient, !statusHistoryRefreshInFlight else { return }
        // Handoffs, activity and retention all advance the broker's revision;
        // `RelayPollPolicy` still fetches every fifteenth tick as a safety net.
        let revision = residentCore?.broker.stateRevision()
        if let revision, !RelayPollPolicy.shouldFetch(revision: revision, lastApplied: lastAppliedStatusRevision, ticksSinceFetch: statusTicksSinceFetch) {
            statusTicksSinceFetch += 1
            return
        }
        statusHistoryRefreshInFlight = true
        let token = refreshGate.token()
        let client = relayClient
        // Busy drafts have one asynchronous owner, the relay tick; this channel
        // never writes them, so the two channels cannot race on that list.
        Task.detached(priority: .utility) { [weak self] in
            let result = Result {
                StatusHistoryRefresh.Fetched(handoffs: try client.handoffs(limit: 500), activity: try client.activityEvents(limit: 500),
                    retention: try client.historyRetentionPolicy())
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.statusHistoryRefreshInFlight = false
                guard case let .success(fetched) = result else { return }
                // Only history that was applied counts: a stale token was
                // discarded, so the next tick must fetch again.
                if self.applyFetchedStatusHistory(fetched, token: token) {
                    self.lastAppliedStatusRevision = revision
                    self.statusTicksSinceFetch = 0
                }
            }
        }
    }

    private var statusHistoryState: StatusHistoryRefresh.State {
        StatusHistoryRefresh.State(handoffs: statusHandoffs, activity: statusActivityEvents, retention: historyRetentionPolicy,
            dismissedHandoffIDs: dismissedHandoffIDs)
    }

    /// Applies fetched history through the gated pure step. A stale token
    /// changes nothing, prunes nothing and raises no notification.
    @discardableResult
    private func applyFetchedStatusHistory(_ fetched: StatusHistoryRefresh.Fetched, token: Int) -> Bool {
        guard let outcome = StatusHistoryRefresh.apply(fetched, token: token, gate: refreshGate, to: statusHistoryState) else { return false }
        if outcome.state.handoffs != statusHandoffs { statusHandoffs = outcome.state.handoffs }
        if outcome.state.activity != statusActivityEvents { statusActivityEvents = outcome.state.activity }
        if outcome.state.retention != historyRetentionPolicy { historyRetentionPolicy = outcome.state.retention }
        if outcome.dismissalsChanged {
            dismissedHandoffIDs = outcome.state.dismissedHandoffIDs
            saveDismissedHandoffs()
        }
        if outcome.changed || outcome.dismissalsChanged { statusHistoryRevision &+= 1 }
        processNotifications(from: outcome.notificationInput)
        return true
    }

    private func startPeriodicRefresh() {
        guard periodicRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.periodicRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ghosttyRegistry.recordExitedProcesses()
                self?.refreshQuietly()
            }
        }
        RunLoop.main.add(timer, forMode: MenuTrackingRefreshPolicy.runLoopMode)
        periodicRefreshTimer = timer
    }

    private func attentionSnapshot(generatedAt: Date) -> ExternalAttentionSnapshot {
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

    func refreshStatusCenterQuietly() {
        let persistence = residentCore?.historyPersistenceError
        if historyPersistenceError != persistence { historyPersistenceError = persistence }
        do {
            try refresh() // invalidates the gate: older background results are discarded
            guard let relayClient else { return }
            let fetched = StatusHistoryRefresh.Fetched(handoffs: try relayClient.handoffs(limit: 500),
                activity: try relayClient.activityEvents(limit: 500), retention: try relayClient.historyRetentionPolicy())
            let busyDrafts = try relayClient.reviewedBusyDrafts()
            if busyDrafts != reviewedBusyDrafts { reviewedBusyDrafts = busyDrafts }
            applyFetchedStatusHistory(fetched, token: refreshGate.token())
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
            URL(fileURLWithPath: $0.launchWorkingDirectory).standardizedFileURL.path
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
                    URL(fileURLWithPath: $0.launchWorkingDirectory).standardizedFileURL.path
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
            (pane.id, URL(fileURLWithPath: pane.launchWorkingDirectory).standardizedFileURL.path)
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

        scheduleManagedWorktreeFactsRefresh()
        let resolver = worktreeResolver
        worktreeRefreshTask = Task.detached(priority: .utility) { [paneFolders, resolver] in
            let scan = resolver.scan(paneFolders: paneFolders)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.worktreeRefreshTask = nil
                let currentPaneFolders = Dictionary(uniqueKeysWithValues: self.panes.map { pane in
                    (pane.id, URL(fileURLWithPath: pane.launchWorkingDirectory).standardizedFileURL.path)
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
        statusSnapshotCache.snapshot(
            generation: statusInputGeneration,
            scope: .init(workspaceID: workspaceID, includeDismissed: includeDismissed)
        ) {
            StatusCenterProjection.snapshot(
                panes: panes,
                handoffs: latestKnownHandoffs,
                activityEvents: statusActivityEvents,
                workspaceID: workspaceID,
                coreAvailable: coreAvailable,
                dismissedHandoffIDs: dismissedHandoffIDs,
                includeDismissed: includeDismissed
            )
        }
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
        ReviewedAskHistory.targetHasTrackedWork(draft.targetPaneID, in: latestKnownHandoffs)
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
        guard let edited = editBoundedText(
            title: "Review and Send to \(draft.targetName)",
            message: "This is a fresh human authorization. The exact edited text will be submitted as a tracked Ask from \(draft.sourceName). Parley never sends this merely because the target became idle."
                + (draft.images.map { $0.isEmpty ? "" : " The \($0.count) image\($0.count == 1 ? "" : "s") queued with it go too, and only \(draft.targetName) may fetch \($0.count == 1 ? "it" : "them")." } ?? ""),
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
        refreshGate.invalidate() // an older fetch must not prune this dismissal
        dismissedHandoffIDs.insert(handoff.id)
        saveDismissedHandoffs()
    }

    func restoreToStatusCenter(_ handoff: RelayHandoff) {
        refreshGate.invalidate()
        dismissedHandoffIDs.remove(handoff.id)
        saveDismissedHandoffs()
    }

    func restoreAllStatusCenterDismissals() {
        refreshGate.invalidate()
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
        alert.informativeText = "This deletes finished collaboration records, their returned or captured results, saved context and recorded activity in this scope from Parley’s local storage. It includes records hidden by search filters or dismissal. Waiting approvals, deliveries in progress and running panes are preserved. Older context without a recorded workspace can be deleted using All Workspaces or Delete Saved Context. Project files, exports and messages already received by vendor CLIs are unchanged. This affects only this local \(runtime.mode.label) app and cannot be undone."
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
            let previousHandoffIDs = Set(statusHandoffs.map(\.id))
            defer {
                refreshStatusCenterQuietly()
                if let core = residentCore { commandRuns = core.commandRuns.runs() }
                let removed = previousHandoffIDs.subtracting(statusHandoffs.map(\.id))
                if let pack = contextPackDraft?.pack,
                   pack.parts.contains(where: { $0.source.kind == .handoffResult && removed.contains($0.source.referenceID ?? "") }) {
                    contextPackDraft = nil
                    contextPackPresented = false
                }
            }
            let response: RelayTextResponse
            if let workspaceID {
                response = try relayClient.deleteWorkspaceHistory(workspaceID: workspaceID, workspaceName: workspaceName)
            } else {
                response = try relayClient.deleteAllHistory()
            }
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
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
            // Reapplying the saved limit retries partial journal maintenance.
            let lowering = requested.maximumRecords < historyRetentionPolicy.maximumRecords
            let retrying = requested == historyRetentionPolicy
            let alert = NSAlert()
            alert.messageText = "Keep up to \(requested.maximumRecords) local history records?"
            alert.informativeText = lowering
                ? "Parley will keep up to \(requested.maximumRecords) collaboration handoffs and \(requested.maximumRecords) lifecycle events. Lowering the current \(historyRetentionPolicy.maximumRecords)-record limit permanently removes the oldest eligible records immediately and cannot restore them later. Active handoffs are always preserved. This changes only this local \(runtime.mode.label) runtime; nothing is uploaded."
                : retrying
                    ? "Parley will retry journal maintenance for the saved \(requested.maximumRecords)-record limit and remove any remaining eligible excess records. Records already removed cannot be restored. Active handoffs are preserved. This changes only this local \(runtime.mode.label) runtime; nothing is uploaded."
                    : "Parley will keep up to \(requested.maximumRecords) collaboration handoffs and \(requested.maximumRecords) lifecycle events. Increasing the limit does not restore records previously removed. Active handoffs are preserved. This changes only this local \(runtime.mode.label) runtime; nothing is uploaded."
            alert.alertStyle = lowering ? .warning : .informational
            alert.addButton(withTitle: lowering ? "Apply and Prune" : (retrying ? "Retry Maintenance" : "Change Retention"))
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
            refreshStatusCenterQuietly()
            NSAlert(error: error).runModal()
        }
    }

    func exportWorkspaceHistory(for workspace: WorkbenchWorkspace) {
        let source = latestKnownHandoffs
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

    /// Marks a result read, or a failure or request seen, so it stops
    /// counting as needing the person (`awaitsAcknowledgement`).
    func markRead(_ handoff: RelayHandoff) {
        guard handoff.awaitsAcknowledgement, let relayClient else { return }
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

    /// The vendor the Agent menu items and the review preselect: the last
    /// one a creation review started, Claude until then. A preference, not a
    /// launch fact; the review is where the vendor is actually chosen.
    static let lastAgentVendorKey = "lastAgentVendor"
    @Published private(set) var lastAgentVendor: PaneKind = .claude

    func createAgent(direction: SplitDirection) {
        create(lastAgentVendor, direction: direction)
    }

    private func rememberAgentVendor(_ kind: PaneKind) {
        guard kind.isAgent else { return }
        lastAgentVendor = kind
        preferences.set(kind.rawValue, forKey: Self.lastAgentVendorKey)
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
        if pane.containerConfiguration?.bypassVendorPermissions == true { return "Container bypass" }
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

    @Published var applyingPanePermissions = false

    /// `approvals` is required, not defaulted: the review re-resolves the
    /// profile from the current store here, and v0.1.44 resolved it without
    /// the person's approvals choice, so a Claude pane reviewed as "Vendor's
    /// automatic reviewer" launched in accept-edits mode while the review
    /// said auto mode.
    func applyPermissionProfile(
        to request: PanePermissionRequest,
        profileID: String,
        approvedRoots: [String],
        approvals: PermissionApprovalHandling,
        containerConfiguration: ContainerConfiguration? = nil
    ) async {
        guard !applyingPanePermissions else { return }
        applyingPanePermissions = true
        defer { applyingPanePermissions = false }
        var createdContainerPlaceholder = false
        do {
            guard panePermissionRequest?.id == request.id else { return }
            guard let definition = permissionProfiles.first(where: { $0.id == profileID }) else {
                throw RelayUIError.message("That permission profile is no longer available.")
            }
            let effective = try PermissionProfileResolver.resolve(
                definition: definition,
                paneFolder: request.folder,
                approvedRoots: definition.rootMode == .exactApprovedRoots ? approvedRoots : [],
                approvals: approvals
            )
            guard effective.approvedRoots.contains(canonicalFolder(request.folder)) else {
                throw RelayUIError.message("The pane folder must remain one of the approved roots.")
            }

            guard let controller else { return }
            if containerConfiguration == nil, request.kind == .codex {
                try await Task.detached(priority: .userInitiated) {
                    try controller.preflightHostLaunch(folder: request.folder, profile: effective)
                }.value
                guard panePermissionRequest?.id == request.id,
                      permissionProfiles.contains(definition) else {
                    throw RelayUIError.message("The permission review changed during the host tool check. Review Start again.")
                }
            }
            switch request.action {
            case let .create(direction):
                let splitTarget = activePane
                let created = try controller.createPane(
                    kind: request.kind,
                    cwd: request.folder,
                    permissionProfile: effective,
                    containerConfiguration: containerConfiguration
                )
                recordNativeSplit(created: created, target: splitTarget, direction: direction)
                rememberFolder(request.folder)
                rememberAgentVendor(request.kind)
                if let containerConfiguration {
                    // Retain one stopped placeholder if preparation fails; another
                    // click must not create duplicate panes or vendor-state volumes.
                    createdContainerPlaceholder = true
                    try refresh()
                    try await launchReviewedPane(created.id, profile: effective, mode: .fresh, configuration: containerConfiguration)
                }
            case let .restart(paneID):
                try await launchReviewedPane(paneID, profile: effective, mode: .fresh, configuration: containerConfiguration)
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
                try await launchReviewedPane(paneID, profile: effective, mode: .resume, configuration: containerConfiguration)
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
                guard effective.selection != pane.permissionSelection || containerConfiguration != pane.containerConfiguration else {
                    throw RelayUIError.message("Folder access is unchanged; the pane was not restarted.")
                }
                let alert = NSAlert()
                alert.messageText = "Restart \(pane.displayName) with new folder access?"
                alert.informativeText = "The current vendor process will end. Its working folder remains \(request.folder). On restart, only the exact reviewed roots shown here are passed to the vendor CLI."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Restart with Access")
                alert.addButton(withTitle: "Keep Current Session")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try await launchReviewedPane(paneID, profile: effective, mode: .fresh, configuration: containerConfiguration)
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
                try await launchReviewedPane(paneID, profile: effective, mode: .fresh, configuration: containerConfiguration)
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
            if createdContainerPlaceholder { panePermissionRequest = nil }
            try? refresh()
            NSAlert(error: error).runModal()
        }
    }

    private func launchReviewedPane(_ paneID: String, profile: EffectivePermissionProfile,
        mode: AgentLaunchMode, configuration: ContainerConfiguration?) async throws {
        guard let controller, let reviewed = try controller.listPanes().first(where: { $0.id == paneID }) else {
            throw RelayUIError.message("That pane no longer exists.")
        }
        if reviewed.containerConfiguration != nil {
            try await Task.detached(priority: .userInitiated) { try controller.prepareContainerStop(reviewed, requiringWorkspace: false) }.value
            try controller.stopPaneProcess(paneID, expectedGeneration: reviewed.launchGeneration)
        } else if configuration != nil, reviewed.isStarted {
            try controller.stopPaneProcess(paneID, expectedGeneration: reviewed.launchGeneration)
        }
        if let configuration {
            try await Task.detached(priority: .userInitiated) {
                try controller.prepareContainerStart(paneID, configuration: configuration, permissionProfile: profile, launchMode: mode)
            }.value
            guard permissionProfiles.contains(profile.definition) else {
                throw RelayUIError.message("The permission profile changed during preparation. Remove the prepared container in Status Center and review Start again.")
            }
            try controller.startPane(paneID, permissionProfile: profile, launchMode: mode, containerConfiguration: configuration)
        } else if try controller.listPanes().first(where: { $0.id == paneID })?.isStarted == true {
            try controller.restartPane(paneID, permissionProfile: profile, launchMode: mode)
        } else {
            try controller.startPane(paneID, permissionProfile: profile, launchMode: mode)
        }
    }

    /// Docker may be unavailable for seconds. Keep the main actor and the
    /// relay's workbench reads free, then revalidate before touching Ghostty.
    /// Stops the reviewed panes' containers, then runs `operation` if every
    /// pane is still as reviewed. The panes are held against a move for the
    /// whole of it, taken before the first cleanup and released after the
    /// last step on every path: the cleanup's own reservation ends when
    /// Docker returns, and in a batch one pane's cleanup ends while another's
    /// still runs, so a move could otherwise land between a removed container
    /// and the step that ends its pane.
    private func performAfterContainerStops(_ reviewed: [WorkbenchPane], operation: @escaping @MainActor () throws -> Void) {
        guard reviewed.contains(where: { $0.containerConfiguration != nil }), let controller else {
            perform(operation)
            return
        }
        // Holds every reviewed pane now, synchronously after the person's
        // confirmation; the sequence releases them when it ends.
        let sequence: ContainerStopSequence
        do { sequence = try ContainerStopSequence(reviewed: reviewed, environment: controller) } catch {
            NSAlert(error: error).runModal()
            return
        }
        Task {
            do { try await sequence.run(operation) } catch { NSAlert(error: error).runModal() }
        }
    }

    func cancelPermissionProfileSelection() {
        guard !applyingPanePermissions else { return }
        panePermissionRequest = nil
        terminalHandle.focus()
    }

    func consumeRequestedHelpTopicID() {
        requestedHelpTopicID = nil
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
        let next = WorkbenchZoomPolicy.next(
            current: focusCanvasPaneID,
            requested: paneID,
            active: activePane?.id,
            visible: visiblePanes.map(\.id)
        )
        focusCanvasPaneID = next
        if let next, activePane?.id != next, let pane = visiblePanes.first(where: { $0.id == next }) {
            select(pane)
        } else {
            terminalHandle.focus()
        }
    }

    func focusActiveTerminal() {
        terminalHandle.focus()
    }

    func toggleCollaborationDock() {
        collaborationDockVisible.toggle()
        preferences.set(collaborationDockVisible, forKey: Self.collaborationDockVisibleKey)
    }

    var voiceDestinationPane: WorkbenchPane? {
        if let destination = voice.session.destination { return try? destination.resolve(in: panes) }
        guard let activePane, isReviewReadyAgent(activePane) else { return nil }
        return activePane
    }

    func beginVoiceRecording() {
        guard let pane = voiceDestinationPane else {
            voice.error = "Choose a running agent pane, or select a new destination for this draft."; return
        }
        voice.begin(pane: pane)
    }

    func toggleVoiceRecording() {
        if voice.session.captureActive { voice.stopRecording() } else { beginVoiceRecording() }
    }

    func handleVoiceKey(_ event: NSEvent) -> Bool {
        if voiceShortcutHeld, event.type == .keyUp, event.keyCode == 49 {
            voiceShortcutHeld = false; voice.stopRecording(); return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if voiceShortcutHeld, event.type == .flagsChanged, !modifiers.contains([.control, .shift]) {
            voiceShortcutHeld = false; voice.stopRecording(); return false
        }
        guard event.type == .keyDown, event.keyCode == 49,
              modifiers.contains([.control, .shift]), !modifiers.contains(.command), !modifiers.contains(.option),
              let window = event.window, window.identifier?.rawValue == "main" || window.title == "Parley",
              window.attachedSheet == nil else { return false }
        if !event.isARepeat, !voiceShortcutHeld { voiceShortcutHeld = true; beginVoiceRecording() }
        return true
    }

    func endVoiceHold() { voiceShortcutHeld = false; voice.stopRecording() }

    func useActiveVoiceDestination() {
        do {
            guard let activePane, isReviewReadyAgent(activePane) else { throw VoiceError.unavailable("Select a running agent pane first.") }
            try voice.session.retarget(VoiceDestination(pane: activePane)); voice.error = nil
        } catch { voice.error = error.localizedDescription }
    }

    func deliverVoice(submit: Bool) {
        var attempted = false
        do {
            guard let controller else { throw VoiceError.unavailable("The workbench is unavailable.") }
            let reviewed = try voice.session.prepareDelivery(panes: controller.listPanes())
            attempted = true
            try controller.pasteVoice(reviewed.text, destination: reviewed.destination, submit: submit)
            voice.discard()
        } catch {
            // A refusal before any input (Copilot trust, a delivery in
            // progress) keeps the draft reviewable; anything else may have
            // left text in the pane.
            voice.session.deliveryFailed(error, afterAttempt: attempted)
        }
    }

    func composeVoiceHandoff(_ kind: VoiceHandoffRequest.Kind) {
        do {
            guard handoffComposerDraft == nil else { throw VoiceError.unavailable("Finish or cancel the open handoff draft first.") }
            let reviewed = try voice.session.reviewedText(panes: panes)
            let candidates = panes.filter { $0.id != reviewed.destination.paneID && isReviewReadyAgent($0) }
            guard !candidates.isEmpty else { throw VoiceError.unavailable("Open another agent pane to receive the \(kind.rawValue.capitalized).") }
            let voiceID = voice.session.id
            requestPaneChoice(title: "Choose \(kind.rawValue.capitalized) Destination",
                message: "From \(reviewed.destination.label). The transcript remains editable before you send.",
                actionLabel: "Create Draft", candidates: candidates, selection: .single(preferredPaneID: nil)) { [weak self] selection in
                guard let self, let selected = selection.first, self.voice.session.id == voiceID else { return }
                do {
                    let source = try reviewed.destination.resolve(in: self.panes)
                    let targetSnapshot = VoiceDestination(pane: selected)
                    let target = try targetSnapshot.resolve(in: self.panes)
                    guard self.handoffComposerDraft == nil else { throw VoiceError.unavailable("Another handoff draft is already open.") }
                    var draft = HandoffComposerDraft(sourcePaneID: source.id, sourceName: source.displayName, sourceKind: source.kind,
                        targetPaneID: target.id, targetName: target.displayName, targetKind: target.kind,
                        text: reviewed.text, includesTerminalSelection: false)
                    draft.voiceSource = reviewed.destination; draft.voiceTarget = targetSnapshot; draft.voiceKind = kind
                    self.handoffComposerDraft = draft; self.voice.discard()
                } catch { self.voice.error = error.localizedDescription }
            }
        } catch { voice.error = error.localizedDescription }
    }

    private func submitVoiceHandoff(_ draft: HandoffComposerDraft) {
        do {
            guard let source = draft.voiceSource, let target = draft.voiceTarget, let kind = draft.voiceKind,
                  let relayClient else { throw VoiceError.unavailable("The reviewed voice handoff is incomplete.") }
            _ = try source.resolve(in: panes); _ = try target.resolve(in: panes)
            let request = VoiceHandoffRequest(source: source, target: target, text: draft.text, kind: kind, idempotencyKey: draft.id.uuidString.lowercased())
            submittingHandoffComposer = true
            Task { [weak self] in
                defer { self?.submittingHandoffComposer = false }
                do {
                    let response = try await Task.detached(priority: .userInitiated) { try relayClient.voiceHandoffFromUI(request) }.value
                    guard response.status == 200 else { throw VoiceError.unavailable(response.text) }
                    guard let self else { return }
                    if self.handoffComposerDraft?.id == draft.id { self.handoffComposerDraft = nil }
                    try? self.refresh()
                    if kind == .ask { self.revealCompletedUIAsk(idempotencyKey: request.idempotencyKey) }
                    else { self.statusCenterOpenRequestID = UUID() }
                } catch {
                    self?.refreshStatusCenterQuietly()
                    NSAlert(error: error).runModal()
                }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    func readVoiceSelection() {
        guard let text = terminalHandle.selectedText else { voice.error = "Select terminal text before choosing Read Selection."; return }
        voice.read(text, label: "Selection from \(activePane?.displayName ?? "pane")")
    }

    func readVoiceResult(_ handoff: RelayHandoff) {
        guard (handoff.kind == .ask || handoff.kind == .delegate), handoff.hasReturnedResult,
              let current = (statusHandoffs + handoffs).first(where: { $0.id == handoff.id && $0.resultText == handoff.resultText }),
              let text = current.resultText else { voice.error = "The returned result is no longer available."; return }
        voice.read(text, label: "Returned \(handoff.kind.rawValue.capitalized) · \(handoff.targetName)")
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
            // Whole or not at all: inserting only part of a selection would
            // silently drop its beginning.
            guard selection.count <= RelayText.maximumCharacters else {
                throw RelayUIError.message("The selection in \(draft.sourceName) is \(selection.count.formatted()) characters, over the \(RelayText.maximumCharacters.formatted())-character limit. Select less; nothing was inserted.")
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
        ReviewedAskHistory.targetHasTrackedWork(pane.id, in: latestKnownHandoffs)
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
        if draft.voiceKind != nil { submitVoiceHandoff(draft); return }
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
            let submission = try submitOrOfferBusyQueue(
                edited,
                from: source,
                to: target,
                preserveFormatting: false,
                onUnanswered: { [weak self] failure in
                    self?.handleUnansweredAsk(
                        failure, text: edited, from: source, to: target, preserveFormatting: false,
                        restore: { [weak self] in
                            // An empty composer opened since then is not a draft to protect.
                            guard let self, self.handoffComposerDraft.map({ RelayText.clean($0.text).isEmpty }) ?? true else { return false }
                            self.handoffComposerDraft = draft
                            return true
                        }
                    )
                }
            )
            // Cancel on the busy-queue offer keeps the draft in the composer.
            guard submission != .cancelled else { return }
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
            request = "Revise this returned result. Address the requested changes below, keep what is already correct, and return the revised result with `parley done <id>` or `parley done <id> --file <path>`, using the id Parley names in this delegation.\n\nRequested changes:\n(describe the changes required before this result can be accepted)"
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
            sourceFolder: source.launchWorkingDirectory,
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
                sourceFolder: source.launchWorkingDirectory,
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

    func requestStatusCenterSegment(_ segment: StatusCenterSegment) {
        requestedStatusCenterSegment = segment
    }

    func consumeRequestedStatusCenterSegment() {
        requestedStatusCenterSegment = nil
    }

    func savedContextReviews(workspaceID: String?) -> [AgentContextReview] {
        guard let workspaceID else { return contextReviews }
        return contextReviews.filter { $0.belongs(to: workspaceID, handoffs: statusHandoffs) }
    }

    var deletableContextReviews: [AgentContextReview] {
        contextReviews.filter { $0.state.canDelete }
    }

    func deleteSavedContext(_ reviews: [AgentContextReview]) {
        let selected = reviews.filter { $0.state.canDelete }
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = selected.count == 1
            ? "Delete “\(AgentDraftMenuProjection.packLabel(for: selected[0]))”?"
            : "Delete \(selected.count) saved context records?"
        alert.informativeText = "This deletes the selected drafts, captured text, edits and returned-file copies from Parley's local storage. Waiting approvals and deliveries in progress are preserved. Messages already sent remain in History until you clear it. Original project files and exported copies are unchanged. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Saved Context").keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard let relayClient else { throw RelayUIError.message("The Parley coordination core is unavailable.") }
            let response = try relayClient.deleteContextReviews(AgentContextDeletion(reviews: selected.map {
                AgentContextDraftDiscard(reviewID: $0.id, expectedUpdatedAt: $0.updatedAt)
            }))
            refreshStatusCenterQuietly()
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
        } catch {
            refreshStatusCenterQuietly()
            NSAlert(error: error).runModal()
        }
    }

    /// Closed workspaces remain addressable for history cleanup. Old records
    /// without a stable workspace identity remain accessible in All Workspaces.
    var closedHistoryWorkspaces: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for handoff in statusHandoffs {
            names[handoff.sourceWorkspaceID] = handoff.sourceWorkspaceName ?? handoff.sourceWorkspaceID
            names[handoff.targetWorkspaceID] = handoff.targetWorkspaceName ?? handoff.targetWorkspaceID
        }
        for event in statusActivityEvents { names[event.workspaceID] = event.workspaceName }
        for review in contextReviews {
            if let id = review.sourceWorkspaceID { names[id] = review.sourceWorkspaceName ?? id }
        }
        let live = Set(workspaces.map(\.workspaceID))
        return names.filter { !$0.key.isEmpty && !live.contains($0.key) }
            .map { (id: $0.key, name: $0.value) }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Discards one editable agent draft from Status Center. The core checks
    /// the draft state and the listed revision under its own lock, so a draft
    /// that became a waiting Ask while the confirmation was open is refused;
    /// waiting approvals are declined only from their own review sheet.
    func discardAgentDraft(_ review: AgentContextReview) {
        perform {
            guard review.state == .draft, let relayClient else { return }
            let alert = NSAlert()
            alert.messageText = "Discard this agent draft?"
            alert.informativeText = "Nothing will be submitted. The source pane can stage a new draft later. A file returned by a delegation stays readable, unedited, from its completed handoff in Status Center while the core keeps the resolved review."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard Draft")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let response = try relayClient.discardContextDraft(reviewID: review.id, expectedUpdatedAt: review.updatedAt)
            if contextPackDraft?.reviewID == review.id, (200..<300).contains(response.status) {
                contextPackPresented = false
                contextPackDraft = nil
            }
            try refresh()
            guard (200..<300).contains(response.status) else { throw RelayUIError.message(response.text) }
        }
    }

    /// Ends every editable agent draft in one confirmed action. Drafts waiting
    /// for approval (a pane blocked in `ask --context`) are left untouched.
    func discardAllEditableDrafts(_ reviews: [AgentContextReview]? = nil) {
        perform {
            guard let relayClient else { return }
            let editable = pendingContextReviews.filter { $0.state == .draft }
            guard !editable.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Discard \(editable.count) editable agent \(editable.count == 1 ? "draft" : "drafts")?"
            alert.informativeText = "Nothing will be submitted. Drafts waiting for your approval are not affected, and a draft that becomes one before this runs is left alone. Each source pane can stage a new draft later. A file returned by a delegation stays readable, unedited, from its completed handoff in Status Center while the core keeps the resolved review."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard All Editable Drafts")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // Each discard names the revision that was listed; the core refuses
            // a draft that became a waiting Ask or changed meanwhile.
            var failures: [String] = []
            var discardedIDs: Set<String> = []
            for review in editable {
                let response = try relayClient.discardContextDraft(reviewID: review.id, expectedUpdatedAt: review.updatedAt)
                if (200..<300).contains(response.status) {
                    discardedIDs.insert(review.id)
                } else {
                    failures.append("\(AgentDraftMenuProjection.packLabel(for: review)): \(response.text)")
                }
            }
            if let presented = contextPackDraft?.reviewID, discardedIDs.contains(presented) {
                contextPackPresented = false
                contextPackDraft = nil
            }
            try refresh()
            if !failures.isEmpty {
                throw RelayUIError.message("\(discardedIDs.count) discarded; \(failures.count) left as \(failures.count == 1 ? "it is" : "they are") — \(failures.joined(separator: "; "))")
            }
        }
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
            guard let revision = draft.reviewUpdatedAt else { throw RelayUIError.message("Reload this context review before changing it.") }
            let response = try isWaitingAsk
                ? relayClient.rejectContextReview(reviewID, expectedUpdatedAt: revision)
                : relayClient.discardContextDraft(reviewID: reviewID, expectedUpdatedAt: revision)
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
                captureTrustedContext(
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
                captureTrustedContext(
                    AgentContextTrustedCaptureRequest(reviewID: reviewID, kind: .gitDiff),
                    draftID: draft.id
                )
            } else {
                guard let contextPackBuilder, !contextCaptureInFlight else { return }
                // Up to four Git commands with 5 s timeouts: never on the main thread.
                let folder = draft.sourceFolder
                let draftID = draft.id
                contextCaptureInFlight = true
                Task { @MainActor [weak self] in
                    defer { self?.contextCaptureInFlight = false }
                    do {
                        let part = try await Task.detached(priority: .userInitiated) {
                            try contextPackBuilder.gitDiff(in: folder)
                        }.value
                        try self?.appendContextPackParts([part], draftID: draftID)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    /// The person's own window capture: the system window picker, then one
    /// still image of the window picked. The core holds the image before
    /// Parley's copy is written, as staging pins an agent's, and the part
    /// joins the pack for review like any other source. Added to an agent's
    /// draft, the core saves it with the review.
    func captureWindowIntoContextPack() {
        guard let draft = contextPackDraft, canCaptureWindowIntoContextPack else { return }
        let draftID = draft.id
        let reviewID = draft.reviewID
        let store = contextImageStore
        contextCaptureInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.contextCaptureInFlight = false }
            do {
                guard let captured = try await WindowCapture.pickAndCapture() else { return }
                let image = try await Task.detached(priority: .userInitiated) { try ContextImageInspector.inspect(captured.data) }.value
                guard let self, self.contextPackDraft?.id == draftID else { return }
                self.capturingImageDigest = image.sha256
                defer {
                    self.capturingImageDigest = nil
                    self.syncPersonImageHolds()
                }
                try self.holdPersonImagesOrThrow()
                try await Task.detached(priority: .userInitiated) { _ = try store.store(captured.data) }.value
                if let reviewID {
                    // An agent's draft is saved by the core, which adds the
                    // capture only while the person still holds it.
                    guard let relayClient = self.relayClient else {
                        throw RelayUIError.message("The app-resident core is unavailable, so the capture could not join the agent's draft.")
                    }
                    let request = AgentContextTrustedCaptureRequest(reviewID: reviewID, kind: .windowCapture, image: image)
                    let response = try await Task.detached(priority: .userInitiated) { try relayClient.captureTrustedContext(request) }.value
                    try self.appendTrustedContextResponse(response, draftID: draftID)
                } else {
                    let time = Date().formatted(date: .omitted, time: .shortened)
                    try self.appendContextPackParts([.personWindowCapture(
                        image,
                        label: "Window captured at \(time)",
                        detail: "Captured by the person with the macOS window picker · \(image.width) × \(image.height) pixels"
                    )], draftID: draftID)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// What the core holds for the person's open pack, which it has no other
    /// record of: the pack's images, one being captured into it and any a
    /// send still carries. Releasing one lets the core delete Parley's copy
    /// unless a sent handoff keeps it.
    private var heldPersonImages: Set<String> = []
    private var capturingImageDigest: String?
    private var sendingImageDigests: [String: Int] = [:]

    private var wantedPersonImages: Set<String> {
        var wanted = Set(sendingImageDigests.keys)
        if let draft = contextPackDraft, draft.reviewID == nil {
            wanted.formUnion(draft.pack.parts.compactMap { $0.image?.sha256 })
        }
        if let capturingImageDigest { wanted.insert(capturingImageDigest) }
        return wanted
    }

    /// Best effort after any change to the pack; a capture and a send hold
    /// through `holdPersonImagesOrThrow` before they rely on it.
    private func syncPersonImageHolds() {
        _ = try? holdPersonImagesOrThrow()
    }

    private func holdPersonImagesOrThrow(force: Bool = false) throws {
        let wanted = wantedPersonImages
        guard force || wanted != heldPersonImages else { return }
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so Parley cannot keep a window capture.")
        }
        let response = try relayClient.holdPersonImages(wanted)
        guard response.status == 200 else { throw RelayUIError.message(response.text) }
        heldPersonImages = wanted
    }

    private func beginImageSend(_ images: [ContextPackImage]) {
        for image in images { sendingImageDigests[image.sha256, default: 0] += 1 }
    }

    private func endImageSend(_ images: [ContextPackImage]) {
        for image in images {
            let count = (sendingImageDigests[image.sha256] ?? 1) - 1
            sendingImageDigests[image.sha256] = count > 0 ? count : nil
        }
        syncPersonImageHolds()
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
                // The core reads the selection; clear it only once it has.
                captureTrustedContext(
                    AgentContextTrustedCaptureRequest(
                        reviewID: reviewID,
                        kind: .visibleTerminal,
                        paneID: pane.id
                    ),
                    draftID: draft.id,
                    then: { [weak self] in self?.terminalHandle.clearSelection() }
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
                terminalHandle.clearSelection()
            }
        }
    }

    func addVendorToolEvidence(
        kind: VendorToolEvidenceKind,
        paneID: String,
        sourceURL: String,
        selectedText: String,
        artifactPath: String
    ) async throws {
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
            try await captureTrustedContextOffMain(
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
            try await captureTrustedContextOffMain(
                AgentContextTrustedCaptureRequest(
                    reviewID: reviewID,
                    kind: .commandResult,
                    executablePath: path,
                    arguments: arguments
                ),
                draftID: draft.id
            )
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
            guard !contextPackCaptureRunning else {
                throw RelayUIError.message("A source is still being captured into this pack. Send it once the capture finishes.")
            }
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
            if let reviewID = draft.reviewID {
                guard let relayClient else {
                    throw RelayUIError.message(isAwaitingAgent
                        ? "The app-resident core is unavailable, so this agent request cannot be approved."
                        : "The app-resident core is unavailable, so this agent draft cannot be sent safely.")
                }
                guard let expectedUpdatedAt = draft.reviewUpdatedAt else {
                    throw RelayUIError.message(isAwaitingAgent
                        ? "Reopen this agent review before approving its latest sources."
                        : "Reopen this agent review before sending its latest sources.")
                }
                // The sheet closes now and the tracked request runs off the main
                // actor. Both routes return only once the core has delivered into
                // the target pane, and the core delivers through the main thread:
                // waiting here froze v0.1.40 until it was force-quit.
                contextPackPresented = false
                contextPackDraft = nil
                launchTrackedContextSend(
                    relayClient: relayClient,
                    approve: isAwaitingAgent,
                    reviewID: reviewID,
                    expectedUpdatedAt: expectedUpdatedAt,
                    draft: draft,
                    target: target
                )
                return
            }
            let images = draft.pack.parts.compactMap(\.image)
            let submission = try submitOrOfferBusyQueue(
                rendered,
                from: source,
                to: target,
                preserveFormatting: true,
                images: images,
                onUnanswered: { [weak self] failure in
                    self?.handleUnansweredAsk(
                        failure, text: rendered, from: source, to: target, preserveFormatting: true,
                        images: images,
                        restore: { [weak self] in
                            // An empty pack opened since then is not a draft to protect.
                            guard let self, self.contextPackDraft.map({ $0.pack.parts.isEmpty }) ?? true else { return false }
                            self.contextPackDraft = draft
                            self.contextPackPresented = true
                            return true
                        }
                    )
                }
            )
            // Cancel on the busy-queue offer keeps the pack open.
            guard submission != .cancelled else { return }
            contextPackPresented = false
            contextPackDraft = nil
            try refresh()
            terminalHandle.focus()
        }
    }

    /// Approves an agent's context Ask, or sends a person-reviewed draft as a
    /// correlated Ask, off the main actor. Either request returns only after
    /// the core has delivered into the target pane (and, for the person's own
    /// Ask, after the answer arrives), and that delivery hops to the main
    /// thread, so the caller must not be standing on it. The client refuses a
    /// tracked request from the main thread for the same reason. The person's
    /// Ask is revealed in Status Center by the key minted here, exactly like
    /// the toolbar Ask.
    private func launchTrackedContextSend(
        relayClient: RelayCoreClient,
        approve: Bool,
        reviewID: String,
        expectedUpdatedAt: Date,
        draft: ActiveContextPack,
        target: WorkbenchPane
    ) {
        let pack = draft.pack
        let idempotencyKey = UUID().uuidString.lowercased()
        Task { [weak self] in
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    if approve {
                        return try relayClient.approveContextReview(
                            reviewID: reviewID,
                            expectedUpdatedAt: expectedUpdatedAt,
                            pack: pack,
                            targetPaneID: target.id
                        )
                    }
                    return try relayClient.completeContextDraft(
                        reviewID: reviewID,
                        expectedUpdatedAt: expectedUpdatedAt,
                        pack: pack,
                        targetPaneID: target.id,
                        idempotencyKey: idempotencyKey
                    )
                }.value
                self?.refreshStatusCenterQuietly()
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
                try? self?.refresh()
                if approve {
                    self?.terminalHandle.focus()
                } else {
                    self?.revealCompletedUIAsk(idempotencyKey: idempotencyKey)
                }
            } catch {
                self?.refreshStatusCenterQuietly()
                // The sheet closed before the send; what becomes of the
                // person's edits is decided from the review read fresh now.
                let fresh = await Task.detached(priority: .userInitiated) { try? relayClient.contextReviews() }.value
                self?.recoverContextSend(draft: draft, target: target,
                                         decision: ContextSendRecovery.decide(reviewID: reviewID, sent: pack, sentRevision: expectedUpdatedAt, fresh: fresh),
                                         failure: error.localizedDescription, approve: approve, idempotencyKey: idempotencyKey)
            }
        }
    }

    /// After a failed send of an agent-staged draft: reopens the person's
    /// edits when nothing was delivered, and otherwise offers them as text to
    /// copy rather than as a draft that could be sent twice
    /// (`ContextSendRecovery`).
    private func recoverContextSend(draft: ActiveContextPack, target: WorkbenchPane, decision: ContextSendRecovery,
                                    failure: String, approve: Bool, idempotencyKey: String) {
        switch decision {
        case .delivered:
            let alert = NSAlert()
            alert.messageText = "Delivered to \(target.displayName), but the send did not finish"
            alert.informativeText = failure + "\n\nThe context reached \(target.displayName), so it was not reopened. Its handoff is in Status Center."
            alert.alertStyle = .informational
            alert.runModal()
            try? refresh()
            if approve { terminalHandle.focus() } else { revealCompletedUIAsk(idempotencyKey: idempotencyKey) }
        case let .reopen(review):
            // An empty pack opened since then is not a draft to protect.
            if contextPackDraft.map({ $0.pack.parts.isEmpty }) ?? true {
                var restored = draft
                restored.reviewState = review.state
                restored.reviewUpdatedAt = review.updatedAt
                restored.requestedTargetPaneID = review.requestedTargetPaneID
                updateContextPackMeasurement(&restored)
                contextPackDraft = restored
                contextPackPresented = true
                let alert = NSAlert()
                alert.messageText = "Nothing was sent to \(target.displayName)"
                alert.informativeText = failure + "\n\nYour edited pack is open again."
                alert.alertStyle = .warning
                alert.runModal()
            } else {
                offerContextSendCopy(draft: draft, title: "Nothing was sent to \(target.displayName)",
                    detail: failure + "\n\nAnother pack is open, so your edits were not reopened. The agent's draft is still in the Context menu; copy your edited text below if you want it.")
            }
        case let .changed(review):
            // The agent changed the draft while it was being edited. Show it as
            // it is now, unless another pack is open; the person's edits stay
            // available to copy either way.
            let title = "\(review.sourcePaneName) changed this draft while you edited it"
            if contextPackDraft.map({ $0.pack.parts.isEmpty }) ?? true {
                presentContextReview(review)
                offerContextSendCopy(draft: draft, title: title,
                    detail: failure + "\n\nNothing was sent. The draft is open as \(review.sourcePaneName) left it" + (review.state == .awaitingReview ? ", now asking for your review" : "") + ". Copy your edited text to bring your changes across.")
            } else {
                offerContextSendCopy(draft: draft, title: title,
                    detail: failure + "\n\nNothing was sent. Another pack is open, so \(review.sourcePaneName)'s draft was not opened; it is in the Context menu. Copy your edited text to keep your changes.")
            }
        case let .copyOnly(reason):
            offerContextSendCopy(draft: draft, title: "Parley could not confirm this context reached \(target.displayName)",
                detail: failure + "\n\n" + reason + " It was not reopened for sending, so it cannot go twice; check \(target.displayName) and Status Center first.")
        }
    }

    private func offerContextSendCopy(draft: ActiveContextPack, title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        // Copying is the default: Return, the reflex after an error, must not
        // be the key that discards the only remaining copy of the edits.
        alert.addButton(withTitle: "Copy Pack Text")
        alert.addButton(withTitle: "Don't Copy")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = (try? contextPackBuilder?.render(draft.pack)) ?? {
            let note = draft.pack.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = draft.pack.parts.map(\.text).joined(separator: "\n\n")
            return note.isEmpty ? parts : note + "\n\n" + parts
        }()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
                    preserveFormatting: true,
                    images: draft.pack.parts.compactMap(\.image)
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
        preserveFormatting: Bool = false,
        images: [ContextPackImage] = []
    ) {
        guard let relayClient else { return }
        // As for one Ask: the images stay held until the comparison ends.
        beginImageSend(images)
        if !images.isEmpty {
            do { try holdPersonImagesOrThrow(force: true) } catch {
                endImageSend(images)
                NSAlert(error: error).runModal()
                return
            }
        }
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
            defer { self?.endImageSend(images) }
            guard let self else { return }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.askManyFromUI(
                        sourcePaneID: source.id,
                        targetPaneIDs: targetPaneIDs,
                        text: question,
                        idempotencyKey: run.id,
                        preserveFormatting: preserveFormatting,
                        images: images
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
        guard let source = activePane, let reviewDraftBuilder, !reviewDraftInFlight else { return }
        // Up to five Git commands with 5 s timeouts: never on the main thread.
        let folder = source.launchWorkingDirectory
        reviewDraftInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.reviewDraftInFlight = false }
            do {
                let draft = try await Task.detached(priority: .userInitiated) {
                    try reviewDraftBuilder.changes(in: folder)
                }.value
                guard let self else { return }
                // The preview names both panes; they may have changed during the read.
                guard let current = self.panes.first(where: { $0.id == source.id }),
                      current.launchGeneration == source.launchGeneration,
                      let currentTarget = self.panes.first(where: { $0.id == target.id }),
                      currentTarget.launchGeneration == target.launchGeneration else {
                    throw RelayUIError.message("A pane changed while its repository was being read. Choose Review again.")
                }
                self.perform { try self.sendReview(draft, from: current, to: currentTarget) }
            } catch {
                NSAlert(error: error).runModal()
            }
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
        panel.directoryURL = URL(fileURLWithPath: source.launchWorkingDirectory)
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
            try controller.paste("The person using Parley requested this recipe:\n\n\(edited)", into: lead.id, submit: true)
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
            throw RelayUIError.message("That context pack was closed or replaced while its source was being captured, so the source was not added.")
        }
        draft.pack.parts.append(contentsOf: parts)
        let rendered = try contextPackBuilder.render(draft.pack)
        draft.renderedByteCount = rendered.utf8.count
        draft.isValid = true
        contextPackDraft = draft
    }

    /// Trusted capture into an agent draft runs off the main thread: the
    /// core reads a selection through `DispatchQueue.main.sync` and can run a
    /// command or several Git reads, so a main thread waiting on it froze and
    /// then reported a failure while the part had been recorded. `then` runs
    /// on the main actor after the part is in the draft.
    private func captureTrustedContext(
        _ request: AgentContextTrustedCaptureRequest,
        draftID: String,
        then: (() -> Void)? = nil
    ) {
        Task { @MainActor [weak self] in
            do {
                try await self?.captureTrustedContextOffMain(request, draftID: draftID)
                then?()
            } catch is CancellationError {
                return
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func captureTrustedContextOffMain(
        _ request: AgentContextTrustedCaptureRequest,
        draftID: String
    ) async throws {
        guard let relayClient else {
            throw RelayUIError.message(
                "The app-resident core is unavailable, so Parley cannot establish trusted capture provenance."
            )
        }
        guard !contextCaptureInFlight else {
            throw RelayUIError.message("A capture into this pack is still running. Wait for it to finish before adding another source.")
        }
        contextCaptureInFlight = true
        defer { contextCaptureInFlight = false }
        let response = try await Task.detached(priority: .userInitiated) {
            try relayClient.captureTrustedContext(request)
        }.value
        try appendTrustedContextResponse(response, draftID: draftID)
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
            throw RelayUIError.message("That context pack was closed or replaced while its source was being captured. The captured source is kept with the agent's draft; reopen the draft to see it.")
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
        guard let relayClient, !retryingHandoffIDs.contains(handoff.id) else { return }
        let handoffID = handoff.id
        retryingHandoffIDs.insert(handoffID)
        // Off the main thread: the core delivers into the target pane through
        // DispatchQueue.main.sync, so a main thread waiting here froze and
        // then reported "retry failed" while the delivery went through.
        Task { @MainActor [weak self] in
            defer { self?.retryingHandoffIDs.remove(handoffID) }
            do {
                let response = try await Task.detached(priority: .userInitiated) {
                    try relayClient.retryHandoff(handoffID)
                }.value
                guard response.status == 200 else { throw RelayUIError.message(response.text) }
                try self?.refresh()
                self?.terminalHandle.focus()
            } catch {
                NSAlert(error: error).runModal()
            }
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
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Set Role")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        field.validateEditing()
        var role = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if role.hasPrefix("@") { role.removeFirst() }
        // Every outcome is visible. An empty entry says so instead of doing
        // nothing, and the result is shown once this dialog has fully closed,
        // so a refusal is never presented while the menu that opened the
        // dialog is still winding down.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !role.isEmpty else {
                NSAlert(error: RelayUIError.message("Enter a role such as reviewer before choosing Set Role. Nothing was changed.")).runModal()
                return
            }
            perform {
                guard let controller else { return }
                try controller.setPaneRole(role, paneID: pane.id, workspaceID: pane.workspaceID)
                try refresh()
                terminalHandle.focus()
            }
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

    private func verifiedActiveHandoffCount(for pane: WorkbenchPane, required: Bool) throws -> Int {
        let history: [RelayHandoff]
        if let relayClient {
            history = try relayClient.activeHandoffs()
        } else if required && pane.kind.isAgent {
            throw RelayUIError.message(
                "Parley cannot verify this agent’s active handoffs while the core service is unavailable. Restore the core connection before moving it."
            )
        } else {
            history = handoffs
        }
        return history.filter {
            ($0.sourcePaneID == pane.id || $0.targetPaneID == pane.id) && $0.state.isActive
        }.count
    }

    private func showPaneMobilityRefusal(
        pane: WorkbenchPane,
        action: PaneMobilityAction,
        assessment: PaneMobilityAssessment
    ) {
        let alert = NSAlert()
        alert.messageText = "Move unavailable for \(pane.displayName)"
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
                folder: pane.launchWorkingDirectory,
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

    /// Ends a started agent pane's process and keeps the pane, stopped, to be
    /// started or resumed later. A container pane's container is stopped
    /// first, as Close stops it; its home volume, with the vendor's login and
    /// conversations, stays. Until 1 October 2026 the only way to stop a
    /// container pane without closing it was Status Center's Stop and Remove.
    func stop(_ pane: WorkbenchPane) {
        let alert = NSAlert()
        alert.messageText = "Stop \(pane.displayName)?"
        alert.informativeText = pane.containerConfiguration == nil
            ? "The \(pane.kind.label) process ends and the pane stays, stopped. Start it again from its menu later."
            : "The \(pane.kind.label) process ends, its container is stopped and removed, and the pane stays, stopped. The pane's saved vendor login and conversations are kept. Start it again from its menu later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performAfterContainerStops([pane]) { [self] in
            try controller?.stopPaneProcess(pane.id, expectedGeneration: pane.launchGeneration)
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
            panel.directoryURL = URL(fileURLWithPath: pane.launchWorkingDirectory)
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
            folder: pane.launchWorkingDirectory,
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
            panel.directoryURL = URL(fileURLWithPath: pane.launchWorkingDirectory)
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
            folder: pane.launchWorkingDirectory,
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
            folder: pane.launchWorkingDirectory,
            workspaceName: workspace?.name ?? pane.workspaceName ?? "Workspace",
            workspaceFolders: workspace?.attachedFolders ?? [],
            action: .folderAccess(pane.id),
            existingSelection: pane.permissionSelection
        )
    }

    func close(_ pane: WorkbenchPane, onlyInsideWorktree: String? = nil) {
        let alert = NSAlert()
        alert.messageText = "Close \(pane.displayName)?"
        alert.informativeText = "This ends the app-resident pane process. It cannot be recovered from Parley."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let path = onlyInsideWorktree {
            guard let fresh = try? controller?.listPanes().first(where: { $0.id == pane.id }),
                  fresh.launchGeneration == pane.launchGeneration, fresh.worktreeSafetyFolders == pane.worktreeSafetyFolders,
                  fresh.worktreeSafetyFolders.contains(where: { WorktreeCleanupPolicy.isNested($0, in: path) }) else {
                NSAlert(error: RelayUIError.message("This pane changed since the preview. Refresh before closing it.")).runModal()
                return
            }
        }
        let closesWorkspace = panes.filter { $0.workspaceID == pane.workspaceID }.count == 1
        performAfterContainerStops([pane]) { [self] in
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

    func setPinned(_ pinned: Bool, for workspace: WorkbenchWorkspace) {
        perform {
            guard let controller else { return }
            try controller.setWorkspacePinned(workspace.workspaceID, pinned: pinned)
            try refresh(includingRelay: false)
        }
    }

    /// A drag within a list that shows part of the workspace order (Pinned,
    /// a group or Ungrouped), carried out on the whole order.
    func moveWorkspaces(inSubset subset: [String], fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard offsets.count == 1, let source = offsets.first,
              let move = WorkspaceSidebarSections.subsetMove(source: source, destination: destination,
                                                             subset: subset, all: workspaces.map(\.workspaceID)) else { return }
        moveWorkspaces(fromOffsets: IndexSet(integer: move.source), toOffset: move.destination)
    }

    // Workspace groups. Each asks the controller, which saves or rolls back
    // whole, then refreshes without the relay, which a group never changes;
    // nothing here grants, starts or closes anything.

    /// Asks for a group name and checks it here, so a name that cannot be
    /// used asks again with the text kept and the reason shown.
    private func promptForGroupName(title: String, informative: String, initial: String, button: String,
                                    excluding groupID: String? = nil) -> String? {
        var text = initial
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = problem.map { "\($0)\n\n\(informative)" } ?? informative
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            text = field.stringValue
            switch WorkspaceGroup.validatedName(text, among: workspaceGroups, excluding: groupID) {
            case let .success(name): return name
            case let .failure(error): problem = error.localizedDescription
            }
        }
    }

    /// Creates a group last, moving `workspace` into it when given.
    func newWorkspaceGroup(moving workspace: WorkbenchWorkspace?) {
        guard let name = promptForGroupName(
            title: "New group",
            informative: workspace.map { "\($0.name) moves into the new group. Groups only arrange the sidebar." }
                ?? "Groups only arrange the sidebar; nothing is opened or closed.",
            initial: "", button: "Create") else { return }
        perform {
            guard let controller else { return }
            _ = try controller.createWorkspaceGroup(name: name, moving: workspace?.workspaceID)
            try refresh(includingRelay: false)
        }
    }

    func renameWorkspaceGroup(_ group: WorkspaceSidebarSections.Group) {
        guard let name = promptForGroupName(title: "Rename group", informative: "Its workspaces stay in it.",
                                            initial: group.name, button: "Rename", excluding: group.id) else { return }
        perform {
            guard let controller else { return }
            try controller.renameWorkspaceGroup(group.id, name: name)
            try refresh(includingRelay: false)
        }
    }

    func deleteWorkspaceGroup(_ group: WorkspaceSidebarSections.Group) {
        let alert = NSAlert()
        alert.messageText = "Delete the group “\(group.name)”?"
        alert.informativeText = group.workspaces.isEmpty
            ? "The group is empty."
            : "Its \(group.workspaces.count) workspace\(group.workspaces.count == 1 ? "" : "s") move\(group.workspaces.count == 1 ? "s" : "") to Ungrouped. No workspace or pane is closed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete Group")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let controller else { return }
            try controller.deleteWorkspaceGroup(group.id)
            try refresh(includingRelay: false)
        }
    }

    /// Moves a workspace into a group, or to Ungrouped with nil.
    func move(_ workspace: WorkbenchWorkspace, toGroup groupID: String?) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceGroup(workspace.workspaceID, groupID: groupID)
            try refresh(includingRelay: false)
        }
    }

    func canMoveWorkspaceGroup(_ group: WorkspaceSidebarSections.Group, by offset: Int) -> Bool {
        guard let index = workspaceGroups.firstIndex(where: { $0.id == group.id }) else { return false }
        return workspaceGroups.indices.contains(index + offset)
    }

    func moveWorkspaceGroup(_ group: WorkspaceSidebarSections.Group, by offset: Int) {
        perform {
            guard let controller else { return }
            try controller.moveWorkspaceGroup(group.id, by: offset)
            try refresh(includingRelay: false)
        }
    }

    func setCollapsed(_ collapsed: Bool, for group: WorkspaceSidebarSections.Group) {
        perform {
            guard let controller else { return }
            try controller.setWorkspaceGroupCollapsed(group.id, collapsed: collapsed)
            try refresh(includingRelay: false)
        }
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

    func consumeRequestedStatusHandoffID() {
        requestedStatusHandoffID = nil
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

    func close(_ workspace: WorkbenchWorkspace, onlyInsideWorktree: String? = nil) {
        let reviewedPanes = panes.filter { $0.workspaceID == workspace.workspaceID }
        let paneCount = panes.filter { $0.workspaceID == workspace.workspaceID }.count
        let alert = NSAlert()
        alert.messageText = "Close \(workspace.name)?"
        alert.informativeText = "This removes \(paneCount) pane\(paneCount == 1 ? "" : "s") and ends every process still running in them. The workspace cannot be recovered from Parley. Its history and saved context remain in Status Center under this closed workspace until you clear them. Project files are unchanged."
        alert.alertStyle = .warning
        attachWorkspaceSafetySummaries([workspaceSafetySummary(for: workspace)], to: alert)
        alert.addButton(withTitle: "Close Workspace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performAfterContainerStops(reviewedPanes) { [self] in
            guard let controller else { return }
            if let path = onlyInsideWorktree {
                let fresh = try controller.listPanes().filter { $0.workspaceID == workspace.workspaceID }
                guard !fresh.isEmpty, fresh.count == reviewedPanes.count,
                      fresh.allSatisfy({ pane in
                          pane.worktreeSafetyFolders.contains(where: { WorktreeCleanupPolicy.isNested($0, in: path) }) &&
                          reviewedPanes.contains(where: { $0.id == pane.id && $0.launchGeneration == pane.launchGeneration && $0.worktreeSafetyFolders == pane.worktreeSafetyFolders })
                      }) else { throw RelayUIError.message("Workspace panes changed or include another folder. Refresh before closing it.") }
            }
            let currentIDs = Set(try controller.listPanes().filter { $0.workspaceID == workspace.workspaceID }.map(\.id))
            guard currentIDs == Set(reviewedPanes.map(\.id)) else {
                throw RelayUIError.message("Workspace membership changed during cleanup; review Close again.")
            }
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
                    folder: pane.launchWorkingDirectory,
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
                ?? workspacePanes.first(where: \.isActive)?.launchWorkingDirectory
                ?? workspacePanes.first?.launchWorkingDirectory
                ?? fallbackFolder,
            root: try saved(native),
            automationPolicy: workspace.automationPolicy
        )
    }

    func saveActiveWorkspaceLayout() {
        guard let workspace = activeWorkspace else { return }
        saveLayout(of: workspace)
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

    func saveLayout(of workspace: WorkbenchWorkspace) {
        let alert = NSAlert()
        alert.messageText = "Save workspace layout"
        alert.informativeText = "Saves pane kinds, names, folders and split structure. Divider positions are not part of a saved layout: it reopens balanced, and the workspace then keeps any positions you set. Running processes, terminal contents and credentials are never stored."
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

        let reviewed = panes.filter { $0.workspaceID == workspace?.workspaceID }
        performAfterContainerStops(reviewed) { [self] in
            guard let controller else { return }
            let current = try controller.listPanes().filter { $0.workspaceID == workspace?.workspaceID }
            guard Set(current.map(\.id)) == Set(reviewed.map(\.id)) else {
                throw RelayUIError.message("Workspace membership changed during cleanup; review replacement again.")
            }
            let restored = try controller.restoreWorkspaceLayout(
                layout,
                replacing: workspace?.id
            )
            // The replaced workspace is gone, as after a close: its record
            // goes too, rather than staying until the registry fills.
            if let replaced = workspace {
                try? workspaceRegistry.remove(workspaceID: replaced.workspaceID)
                nativeLayouts.removeValue(forKey: replaced.workspaceID)
                nativeSplitFractions.removeValue(forKey: replaced.workspaceID)
            }
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

    /// What Codex's own configuration says about who answers its prompts, for
    /// the permission review to state before the person chooses. Read off the
    /// main actor; a failure is worded as one rather than hidden.
    func codexApprovalsReviewerFact(folder: String) async -> String {
        guard let controller else { return "Codex configuration could not be read: the workbench is unavailable." }
        do {
            let setting = try await Task.detached(priority: .userInitiated) { try controller.codexApprovalsReviewer(folder: folder) }.value
            switch setting {
            case nil:
                return "Codex's own configuration sets no approvals_reviewer for this folder, so the choice above decides who answers."
            case "auto_review"?:
                return "Codex's own configuration sets approvals_reviewer = auto_review for this folder: Codex sends sandbox escalations to its automatic reviewer and shows no prompt, whichever you choose above. Remove that line from ~/.codex/config.toml to see Codex's prompt."
            case let other?:
                return "Codex's own configuration sets approvals_reviewer = \(other) for this folder; that setting, not the choice above, decides who answers escalations."
            }
        } catch {
            return "Codex configuration could not be read: \(error.localizedDescription)"
        }
    }

    private func rememberFolder(_ folder: String) {
        let standardized = WorkspaceFolderIdentity.normalized(folder)
        recentFolders.removeAll {
            WorkspaceFolderIdentity.matches($0, standardized)
        }
        recentFolders.insert(standardized, at: 0)
        if recentFolders.count > 8 { recentFolders.removeLast(recentFolders.count - 8) }
        pruneMissingRecentFolders()
        preferences.set(recentFolders, forKey: Self.recentFoldersKey)
    }

    /// Recent history is automatic, so a folder that no longer exists leaves
    /// it on its own; it cannot be used for new panes and was being offered
    /// for weeks after deletion. Favourites are the person's bookmarks and are
    /// only reported as missing, never removed here.
    private func pruneMissingRecentFolders() {
        let kept = FolderListMaintenance.existing(recentFolders, exists: { FolderListMaintenance.directoryExists($0) })
        guard kept != recentFolders else { return }
        recentFolders = kept
        preferences.set(recentFolders, forKey: Self.recentFoldersKey)
    }

    func removeRecentFolder(_ folder: String) {
        recentFolders = FolderListMaintenance.removing(folder, from: recentFolders)
        preferences.set(recentFolders, forKey: Self.recentFoldersKey)
    }

    func clearRecentFolders() {
        recentFolders = []
        preferences.removeObject(forKey: Self.recentFoldersKey)
    }

    func removeFavouriteFolder(_ folder: String) {
        guard isFavouriteFolder(folder) else { return }
        toggleFavouriteFolder(folder)
    }

    /// Favourites that no longer exist on disk, for the folder manager to show
    /// as missing with a Remove button.
    var missingFavouriteFolders: [String] {
        FolderListMaintenance.missing(favouriteFolders, exists: { FolderListMaintenance.directoryExists($0) })
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
        // Several callers paste the result straight into a pane (Forward
        // comparison, Run recipe), so the limit is enforced here rather than
        // left to the broker. `RelayText.clean` no longer truncates; over the
        // limit the editor reopens with the person's edits.
        var current = text
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: action)
            alert.addButton(withTitle: "Cancel")

            let accessory = RelayEditorAccessory(text: current, insertVisible: insertVisible)
            alert.accessoryView = accessory

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            current = accessory.text
            let cleaned = RelayText.clean(current)
            if cleaned.count > RelayText.maximumCharacters {
                NSAlert(error: RelayUIError.message(
                    "The text is \(cleaned.count.formatted()) characters. Reduce it to \(RelayText.maximumCharacters.formatted()) before sending; nothing was sent."
                )).runModal()
                continue
            }
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private func editBoundedText(
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
                NSAlert(error: RelayUIError.message("The text cannot be empty.")).runModal()
                continue
            }
            if current.utf8.count > ContextPackBuilder.defaultMaximumRenderedBytes {
                NSAlert(error: RelayUIError.message(
                    "The text is \(current.utf8.count) bytes. Reduce it to \(ContextPackBuilder.defaultMaximumRenderedBytes) bytes before dispatch."
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
        let submission = try submitOrOfferBusyQueue(
            edited,
            from: source,
            to: target,
            preserveFormatting: false,
            onUnanswered: { [weak self] failure in
                // The review was edited in a dialog, so there is no draft to
                // reopen; its text can be copied.
                self?.handleUnansweredAsk(
                    failure, text: edited, from: source, to: target, preserveFormatting: false,
                    restore: { false },
                    notRestoredNote: "The review text was edited in a dialog that has closed; copy it to keep it, or start the review again."
                )
            }
        )
        guard submission != .cancelled else { return }
        try refresh()
        terminalHandle.clearSelection()
        terminalHandle.focus()
    }

    /// What became of a reviewed Ask the person sent: only `launched` and
    /// `queued` may clear the draft it came from.
    private enum ReviewedAskSubmission { case launched, queued, cancelled }

    private func submitOrOfferBusyQueue(
        _ text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool,
        images: [ContextPackImage] = [],
        onUnanswered: @escaping @MainActor (ReviewedAskFailure) -> Void
    ) throws -> ReviewedAskSubmission {
        guard ReviewedAskHistory.targetHasTrackedWork(target.id, in: latestKnownHandoffs) else {
            try launchTrackedAsk(
                text,
                from: source,
                to: target,
                preserveFormatting: preserveFormatting,
                images: images,
                onUnanswered: onUnanswered
            )
            return .launched
        }
        return try offerBusyQueue(text, from: source, to: target, preserveFormatting: preserveFormatting, images: images) ? .queued : .cancelled
    }

    /// Offers the local busy queue for a reviewed Ask to a target that
    /// already has tracked work. Returns whether the draft was queued.
    private func offerBusyQueue(
        _ text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool,
        images: [ContextPackImage] = []
    ) throws -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(target.displayName) Already Has Tracked Work"
        alert.informativeText = "Keep this exact reviewed Ask in Parley's local busy queue? It remains visible and unsent. When \(target.displayName) becomes idle, Parley will still wait for you to reopen, review and explicitly send it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Reviewed Draft")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so Parley cannot keep this draft safely.")
        }
        // The core takes the images over from the person's hold; it keeps
        // them with the queued draft and sends them with it.
        if !images.isEmpty { try holdPersonImagesOrThrow(force: true) }
        _ = try relayClient.enqueueReviewedBusyDraft(ReviewedBusyDraftCreateRequest(
            sourcePaneID: source.id,
            targetPaneID: target.id,
            text: text,
            preserveFormatting: preserveFormatting,
            images: images
        ))
        return true
    }

    /// Why a person's reviewed Ask ended without an answer, as far as the app
    /// can tell. Only `refused` gives the draft back; every other case keeps
    /// it sent (or possibly sent) and offers its text for copying, so the
    /// same question is never offered for sending twice.
    enum ReviewedAskFailure {
        case refused(reason: String, targetBusy: Bool)
        case deliveryMayHaveStarted(reason: String)
        case deliveredThenFailed(reason: String)
        case unknown(reason: String)
    }

    /// Launches the person's reviewed Ask off the main actor. On any outcome
    /// other than an answer, including a transport error, it reads fresh
    /// history and reports what became of the Ask through `onUnanswered` on
    /// the main actor.
    private func launchTrackedAsk(
        _ text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool,
        images: [ContextPackImage] = [],
        onUnanswered: @escaping @MainActor (ReviewedAskFailure) -> Void
    ) throws {
        guard let relayClient else {
            throw RelayUIError.message("The app-resident core is unavailable, so this reviewed Ask was not sent.")
        }
        let idempotencyKey = UUID().uuidString.lowercased()
        let sourceID = source.id
        let targetID = target.id
        // The images stay held until this send ends, whatever becomes of the
        // pack meanwhile; the handoff keeps them once the core records it.
        beginImageSend(images)
        if !images.isEmpty {
            do { try holdPersonImagesOrThrow(force: true) } catch {
                endImageSend(images)
                throw error
            }
        }
        Task { [weak self] in
            defer { self?.endImageSend(images) }
            let (result, history) = await Task.detached(priority: .userInitiated) { () -> (Result<RelayTextResponse, Error>, [RelayHandoff]?) in
                let result = Result {
                    try relayClient.askFromUI(
                        sourcePaneID: sourceID,
                        targetPaneID: targetID,
                        text: text,
                        idempotencyKey: idempotencyKey,
                        preserveFormatting: preserveFormatting,
                        images: images
                    )
                }
                if case let .success(response) = result, response.status == 200 { return (result, nil) }
                // Unanswered: what became of it? Nil when history cannot be read.
                return (result, try? relayClient.handoffs(limit: 500))
            }.value
            self?.refreshStatusCenterQuietly()
            if case let .success(response) = result, response.status == 200 {
                // The answer is durable by now, but a person who asked from this
                // pane saw nothing: it was only a Result badge and an unread
                // count. Reveal the exact completed handoff, found by the key
                // this app minted, so the answer is on screen when it arrives.
                self?.revealCompletedUIAsk(idempotencyKey: idempotencyKey)
                return
            }
            let reason = switch result {
            case let .success(response): response.text
            case let .failure(error): error.localizedDescription
            }
            guard let history else {
                onUnanswered(.unknown(reason: reason))
                return
            }
            switch ReviewedAskHistory.outcome(idempotencyKey: idempotencyKey, in: history) {
            case .refusedBeforeDelivery:
                onUnanswered(.refused(reason: reason, targetBusy: ReviewedAskHistory.targetHasTrackedWork(targetID, in: history)))
            case .deliveryMayHaveStarted:
                onUnanswered(.deliveryMayHaveStarted(reason: reason))
            case .delivered:
                onUnanswered(.deliveredThenFailed(reason: reason))
            }
        }
    }

    /// Tells the person what became of an unanswered reviewed Ask. A refused
    /// one gives its draft back (`restore` reopens it where nothing else took
    /// its place) and offers the busy queue for a busy target; every other
    /// outcome says what may have happened and offers the text for copying.
    private func handleUnansweredAsk(
        _ failure: ReviewedAskFailure,
        text: String,
        from source: WorkbenchPane,
        to target: WorkbenchPane,
        preserveFormatting: Bool,
        images: [ContextPackImage] = [],
        restore: () -> Bool,
        notRestoredNote: String = "Another draft is open in its place, so this one was not reopened; copy its text to keep it."
    ) {
        let title: String
        let detail: String
        switch failure {
        case let .refused(reason, targetBusy):
            // A busy target is offered the queue first, so a queued draft never
            // needs reopening; declined, the draft comes back quietly because
            // the offer already said why it was not sent.
            var offeredQueue = false
            if targetBusy {
                do {
                    if try offerBusyQueue(text, from: source, to: target, preserveFormatting: preserveFormatting, images: images) { return }
                    offeredQueue = true
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
            let restored = restore()
            if restored && offeredQueue { return }
            title = "Nothing was sent to \(target.displayName)"
            detail = reason + "\n\n" + (restored ? "Your reviewed draft is back where you wrote it." : notRestoredNote)
            if restored {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = detail
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
        case let .deliveryMayHaveStarted(reason):
            title = "Parley could not finish sending this Ask to \(target.displayName)"
            detail = reason + "\n\nIts text may already be in \(target.displayName)'s input line. Check that pane before sending it again."
        case let .deliveredThenFailed(reason):
            title = "\(target.displayName) received this Ask but did not answer"
            detail = reason + "\n\nThe question was delivered, so it was not reopened; copy its text if you want to ask again."
        case let .unknown(reason):
            title = "Parley could not confirm whether this Ask reached \(target.displayName)"
            detail = reason + "\n\nCheck Status Center before sending it again."
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        // Copying is the default, as for a context pack: Return must not be
        // the key that discards the only remaining copy of the draft.
        alert.addButton(withTitle: "Copy Draft Text")
        alert.addButton(withTitle: "Don't Copy")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Opens Status Center on the Ask this app just launched, identified by the
    /// idempotency key it minted rather than by guessing at the newest record.
    /// Nothing is delivered into the source pane: an agent's prompt is never
    /// written to unrequested. Delivering the answer onward stays an explicit
    /// person action with its own editable preview.
    private func revealCompletedUIAsk(idempotencyKey: String) {
        let history = latestKnownHandoffs
        guard let handoff = history.first(where: { $0.idempotencyKey == idempotencyKey && $0.kind == .ask }) else { return }
        guard openAttentionNavigation(.handoff(handoff.id)) else { return }
        statusCenterOpenRequestID = UUID()
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
            // Whole or not at all, as in the composer's Insert Selection.
            guard visible.count <= RelayText.maximumCharacters else {
                throw RelayUIError.message("The selection is \(visible.count.formatted()) characters, over the \(RelayText.maximumCharacters.formatted())-character limit. Select less; nothing was inserted.")
            }
            editor.insertText(visible, replacementRange: editor.selectedRange())
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// What the command palette lists: everything, or only workspaces for Go to
/// Workspace (Shift-Command-O).
enum CommandPaletteScope: Equatable {
    case everything
    case workspaces
}
