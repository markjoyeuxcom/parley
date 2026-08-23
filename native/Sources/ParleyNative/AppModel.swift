import AppKit
import Foundation
import ParleyCore
import SwiftTerm
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
    @Published private(set) var coreAvailable = false
    @Published private(set) var tmuxAvailable = false
    @Published private(set) var notificationWorkspaceNames: Set<String> = []
    @Published private(set) var dismissedHandoffIDs: Set<String> = []
    @Published var startupError: String?

    let terminalHandle = TerminalHandle()
    private let fallbackFolder: String
    private let layoutStore: SavedWorkspaceLayoutStore
    private var workspaceContinuity = WorkspaceContinuityState()
    private let projectContextResolver = GitProjectContextResolver()
    private var projectContextRefreshTask: Task<Void, Never>?
    private var projectContextFolders: Set<String> = []
    private var lastProjectContextRefresh = Date.distantPast
    private var relayClient: RelayCoreClient?
    private var reviewDraftBuilder: ReviewDraftBuilder?
    private let notificationEpoch = Date()
    private var observedNotificationEventIDs: Set<String> = []
    private static let recentFoldersKey = "parley.recentWorkspaceFolders"
    private static let workspaceContinuityKey = "parley.workspaceContinuity"
    private static let notificationWorkspacesKey = "parley.notificationWorkspaces"
    private static let dismissedHandoffsKey = "parley.dismissedStatusHandoffs"
    private static let projectContextRefreshInterval: TimeInterval = 5

    init() {
        let requestedFolder = Self.argument(named: "--cwd")
        let initialFolder = requestedFolder ?? FileManager.default.currentDirectoryPath
        fallbackFolder = URL(fileURLWithPath: initialFolder).standardizedFileURL.path
        let applicationDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Parley Native", isDirectory: true)
        layoutStore = SavedWorkspaceLayoutStore(
            file: applicationDirectory.appendingPathComponent("workspace-layouts.json")
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
            let relayClient = try RelayCoreLauncher.ensureRunning(
                applicationDirectory: controller.applicationDirectory,
                cwd: defaultFolder,
                environment: controller.environment
            )
            controller.configureRelay(RelayRuntime(
                infoFile: infoFile,
                shimDirectory: shimDirectory,
                credentials: credentials
            ))
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
            coreAvailable = true
            tmuxAvailable = true
            reviewDraftBuilder = ReviewDraftBuilder(environment: controller.environment)
            panes = livePanes
            workspaces = liveWorkspaces
            savedLayouts = try layoutStore.layouts()
            rememberFolder(defaultFolder)
            scheduleProjectContextRefresh(force: true)
        } catch {
            coreAvailable = false
            tmuxAvailable = false
            startupError = error.localizedDescription
        }
    }

    var activeWorkspace: TmuxWorkspace? { workspaces.first(where: \.isActive) }

    var defaultFolder: String { activeWorkspace?.defaultFolder ?? fallbackFolder }

    var visiblePanes: [TmuxPane] {
        guard let workspaceID = activeWorkspace?.id else { return panes }
        return panes.filter { $0.windowID == workspaceID }
    }

    var activePane: TmuxPane? { visiblePanes.first(where: \.isActive) }

    func projectContext(for pane: TmuxPane) -> GitProjectContext? {
        let folder = URL(fileURLWithPath: pane.cwd).standardizedFileURL.path
        return projectContexts[folder]
    }

    var askTargets: [TmuxPane] {
        guard let source = activePane,
              source.kind.isAgent,
              source.isStarted,
              source.relayEnabled,
              source.hasCurrentProtocol else { return [] }
        return panes.filter {
            $0.kind.isAgent
                && $0.kind != source.kind
                && $0.isStarted
                && $0.relayEnabled
                && $0.hasCurrentProtocol
        }
    }

    var localAskTargets: [TmuxPane] {
        guard let workspaceID = activeWorkspace?.id else { return [] }
        return askTargets.filter { $0.windowID == workspaceID }
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
            } catch {
                tmuxAvailable = false
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
            } catch {
                coreAvailable = false
                if firstError == nil { firstError = error }
            }
        } else {
            coreAvailable = false
        }
        if tmuxAvailable { scheduleProjectContextRefresh() }
        if let firstError { throw firstError }
    }

    func refreshQuietly() {
        do { try refresh() } catch { /* the attached client may be between tmux redraws */ }
    }

    func refreshStatusCenterQuietly() {
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
        perform {
            guard let controller else { return }
            _ = try controller.createPane(kind: kind, cwd: defaultFolder, direction: direction)
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
        let alert = NSAlert()
        alert.messageText = "Cancel this Ask?"
        alert.informativeText = "This releases the waiting \(consultation.sourceName) command and records the Ask as cancelled. It does not interrupt \(consultation.targetName) or send anything to either pane."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Ask")
        alert.addButton(withTitle: "Keep Waiting")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform {
            guard let relayClient else { return }
            let response = try relayClient.cancelHandoff(consultation.id)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
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
                    isActive: workspace.isActive
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
                root: captured.root
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
