import AppKit
import ParleyCore
import ParleyUI
import SwiftUI

fileprivate enum ExternalApplicationRequest: Equatable {
    case workspace(ExternalWorkspaceOpenRequest)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var externalRequestHandler: ((ExternalApplicationRequest) -> Void)?
    private var pendingExternalRequests: [ExternalApplicationRequest] = []
    private var titlebarDoubleClickMonitor: Any?
    private var keyDownMonitor: Any?
    var terminationHandler: (() async -> Bool)?
    private var terminationPending = false
    var terminalFocusRepairHandler: ((NSEvent) -> Void)?
    var applicationShortcutHandler: ((WorkbenchKeyboardShortcut) -> Void)?
    var voiceKeyHandler: ((NSEvent) -> Bool)?
    var voiceStopHandler: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        guard let terminationHandler else { return .terminateNow }
        terminationPending = true
        Task {
            let approved = await terminationHandler()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no app bundle to declare a foreground
        // activation policy. Promote it explicitly during development so its
        // WindowGroup is visible and behaves like a normal macOS application.
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) {
            [weak self] event in
            if self?.voiceKeyHandler?(event) == true { return nil }
            guard event.type == .keyDown else { return event }
            if let shortcut = self?.workbenchShortcut(for: event),
               let handler = self?.applicationShortcutHandler {
                handler(shortcut)
                return nil
            }
            self?.terminalFocusRepairHandler?(event)
            return event
        }
        DispatchQueue.main.async {
            self.applyDevelopmentIcon()
            if let window = NSApp.windows.first(where: { $0.title == "Parley" && $0.canBecomeKey })
                ?? NSApp.windows.first(where: { $0.canBecomeKey }) {
                self.configureMainWindow(window)
            }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            let mainWindow = sender.windows.first(where: { $0.identifier?.rawValue == "main" })
                ?? sender.windows.first(where: { $0.title == "Parley" })
            if let mainWindow { recoverMainWindowFrame(mainWindow) }
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.title == "Parley" || sender.identifier?.rawValue == "main" else { return true }
        voiceStopHandler?()
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let titlebarDoubleClickMonitor {
            NSEvent.removeMonitor(titlebarDoubleClickMonitor)
            self.titlebarDoubleClickMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

    func applicationDidResignActive(_ notification: Notification) { voiceStopHandler?() }
    func windowDidResignKey(_ notification: Notification) { voiceStopHandler?() }

    fileprivate func bindExternalRequestHandler(
        _ handler: @escaping (ExternalApplicationRequest) -> Void
    ) {
        externalRequestHandler = handler
        let pending = pendingExternalRequests
        pendingExternalRequests.removeAll()
        for request in pending { handler(request) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first else {
            presentExternalOpenError(ExternalWorkspaceOpenError.oneFolderRequired)
            return
        }
        if url.isFileURL {
            receive(Result { try request(forFileURL: url) })
        } else {
            receive(Result { .workspace(try ExternalWorkspaceOpen.request(url: url)) })
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        do {
            guard filenames.count == 1, let filename = filenames.first else {
                throw ExternalWorkspaceOpenError.oneFolderRequired
            }
            enqueue(try request(forFileURL: URL(fileURLWithPath: filename)))
            sender.reply(toOpenOrPrint: .success)
        } catch {
            presentExternalOpenError(error)
            sender.reply(toOpenOrPrint: .failure)
        }
    }

    @objc(openInParley:userData:error:)
    func openInParley(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        guard let filenames = pasteboard.propertyList(forType: filenamesType) as? [String] else {
            errorPointer.pointee = "Choose one folder in Finder, then run Open in Parley."
            return
        }
        do {
            enqueue(.workspace(try ExternalWorkspaceOpen.request(folderPaths: filenames)))
        } catch {
            errorPointer.pointee = error.localizedDescription as NSString
            presentExternalOpenError(error)
        }
    }

    private func request(forFileURL url: URL) throws -> ExternalApplicationRequest {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .workspace(try ExternalWorkspaceOpen.request(folderPaths: [url.path]))
        }
        throw ExternalWorkspaceOpenError.notDirectory(url.path)
    }

    private func receive(_ result: Result<ExternalApplicationRequest, Error>) {
        switch result {
        case let .success(request): enqueue(request)
        case let .failure(error): presentExternalOpenError(error)
        }
    }

    private func enqueue(_ request: ExternalApplicationRequest) {
        foregroundApplication()
        if let externalRequestHandler {
            externalRequestHandler(request)
        } else if !pendingExternalRequests.contains(request) {
            pendingExternalRequests.append(request)
        }
    }

    private func foregroundApplication() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            let mainWindow = NSApp.windows.first(where: { $0.title == "Parley" && $0.canBecomeKey })
                ?? NSApp.windows.first(where: { $0.canBecomeKey })
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    private func presentExternalOpenError(_ error: Error) {
        foregroundApplication()
        DispatchQueue.main.async {
            NSAlert(error: error).runModal()
        }
    }

    private func applyDevelopmentIcon() {
        guard Bundle.main.bundleIdentifier != ParleyRuntime.productionBundleIdentifier else { return }
        let icon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("resources/icon.icns")
        if let image = NSImage(contentsOf: icon) {
            NSApp.applicationIconImage = image
        }
    }

    private func configureMainWindow(_ window: NSWindow) {
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unifiedCompact
        window.isMovable = true
        recoverMainWindowFrame(window)

        guard let frameView = window.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = 16
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
        installTitlebarDoubleClickMonitor(on: window)
        window.invalidateShadow()
    }

    private func recoverMainWindowFrame(_ window: NSWindow) {
        let recovered = WindowFrameRecovery.recoveredFrame(
            window.frame,
            visibleFrames: NSScreen.screens.map(\.visibleFrame)
        )
        guard recovered != window.frame else { return }
        window.setFrame(recovered, display: true, animate: false)
    }

    private func workbenchShortcut(for event: NSEvent) -> WorkbenchKeyboardShortcut? {
        let key: String
        switch event.keyCode {
        case 48: key = "tab"
        case 123: key = "left"
        case 124: key = "right"
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
                return nil
            }
            key = characters
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return WorkbenchKeyboardShortcut.resolve(
            key: key,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
    }

    // Keep the custom workbench toolbar inside the content safe area below
    // contentLayoutRect.maxY. SwiftUI buttons are not reliably NSControls, so
    // they must never overlap the native title-bar band handled here.
    private func installTitlebarDoubleClickMonitor(on window: NSWindow) {
        if let titlebarDoubleClickMonitor { NSEvent.removeMonitor(titlebarDoubleClickMonitor) }
        titlebarDoubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak window] event in
            guard let window else { return event }
            return WindowTitlebarDoubleClick.handle(event, in: window) ? nil : event
        }
    }
}

@main
enum ParleyNativeEntry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count > 1 && arguments[1] == ApprovedCommandWorker.argument {
            guard arguments.count == 4 else { Foundation.exit(2) }
            ApprovedCommandWorker.execute(ticketPath: arguments[2], expectedDigest: arguments[3])
        }
        ParleyNativeApp.main()
    }
}

struct ParleyNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Parley", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.terminationHandler = { await model.resolveTermination() }
                    appDelegate.voiceKeyHandler = { model.handleVoiceKey($0) }
                    appDelegate.voiceStopHandler = { model.endVoiceHold() }
                    appDelegate.terminalFocusRepairHandler = { event in
                        model.repairNativeTerminalFocus(for: event)
                    }
                    appDelegate.applicationShortcutHandler = { shortcut in
                        switch shortcut {
                        case .nextWorkspace: model.selectAdjacentWorkspace(by: 1)
                        case .previousWorkspace: model.selectAdjacentWorkspace(by: -1)
                        case .nextPane: model.selectAdjacentPane(by: 1)
                        case .previousPane: model.selectAdjacentPane(by: -1)
                        case let .selectPane(index): model.selectPane(at: index)
                        case .toggleFocusCanvas: model.toggleFocusCanvas()
                        case .togglePanePresentation: model.togglePanePresentation()
                        case .focusActiveTerminal: model.focusActiveTerminal()
                        case .toggleCollaborationDock: model.toggleCollaborationDock()
                        case .quickRelaySelection: model.quickRelaySelection()
                        case .nextAttention:
                            if model.focusNextAttention() {
                                openWindow(id: "status-center")
                            }
                        case .workspaceSwitcher: model.showWorkspaceSwitcher()
                        }
                    }
                    appDelegate.bindExternalRequestHandler { request in
                        switch request {
                        case let .workspace(workspace): model.openExternalWorkspace(workspace)
                        }
                    }
                    model.startAutomaticUpdater()
                }
        }
        .defaultSize(width: 1_300, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Parley") { openWindow(id: "about") }
            }
            CommandGroup(replacing: .help) {
                Button("Parley Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: [.command])
            }
            CommandMenu("Voice") {
                Button("Start / Stop Dictation") { model.toggleVoiceRecording() }
                Button("Discard Voice Draft") { model.voice.discard() }
                Divider()
                Button("Read Selection") { model.readVoiceSelection() }
                Button("Stop Read-aloud and Clear Queue") { model.voice.stopSpeaking() }
                Divider()
                Button("Voice Settings…") { model.showSettings(.voice) }
            }
            CommandGroup(after: .appSettings) {
                Button("Prepare to Uninstall…") { model.prepareToUninstall() }
                    .disabled(!model.canPrepareToUninstall)
            }
            CommandMenu("Navigate") {
                Button("Command Palette…") { model.showCommandPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
                // Not disabled with one workspace: the key monitor takes the
                // chord before the menu, so the item would only disagree with it.
                Button("Go to Workspace…") { model.showWorkspaceSwitcher() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Next Workspace") { model.selectAdjacentWorkspace(by: 1) }
                    .keyboardShortcut(.tab, modifiers: [.control])
                    .disabled(!model.canNavigateWorkspaces)
                Button("Previous Workspace") { model.selectAdjacentWorkspace(by: -1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(!model.canNavigateWorkspaces)
                Divider()
                Button("Next Pane") { model.selectAdjacentPane(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .option])
                    .disabled(!model.canNavigatePanes)
                Button("Previous Pane") { model.selectAdjacentPane(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .option])
                    .disabled(!model.canNavigatePanes)
                Button("Next Attention Item") {
                    if model.focusNextAttention() { openWindow(id: "status-center") }
                }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(model.paneAttentionItems.isEmpty)
                Divider()
                Button("Focus Pane 1") { model.selectPane(at: 0) }
                    .keyboardShortcut("1", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 1)
                Button("Focus Pane 2") { model.selectPane(at: 1) }
                    .keyboardShortcut("2", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 2)
                Button("Focus Pane 3") { model.selectPane(at: 2) }
                    .keyboardShortcut("3", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 3)
                Button("Focus Pane 4") { model.selectPane(at: 3) }
                    .keyboardShortcut("4", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 4)
                Button("Focus Pane 5") { model.selectPane(at: 4) }
                    .keyboardShortcut("5", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 5)
                Button("Focus Pane 6") { model.selectPane(at: 5) }
                    .keyboardShortcut("6", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 6)
                Button("Focus Pane 7") { model.selectPane(at: 6) }
                    .keyboardShortcut("7", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 7)
                Button("Focus Pane 8") { model.selectPane(at: 7) }
                    .keyboardShortcut("8", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 8)
                Button("Focus Pane 9") { model.selectPane(at: 8) }
                    .keyboardShortcut("9", modifiers: [.command])
                    .disabled(model.visiblePanes.count < 9)
                Divider()
                Button(model.focusCanvasPaneID == nil ? "Zoom Pane" : "Unzoom Pane") {
                    model.toggleFocusCanvas()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.activePane == nil || model.activePresentation == .tabs)
                Button(model.activePresentation.toggleTitle) { model.togglePanePresentation() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.activeWorkspace == nil)
                Button("Focus Active Terminal") { model.focusActiveTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button(model.collaborationDockVisible ? "Hide Collaboration Dock" : "Show Collaboration Dock") {
                    model.toggleCollaborationDock()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("Workspace") {
                Button("New Workspace") { model.createWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Folder…") { model.openWorkspacePicker() }
                Button("Open Worktree…") {
                    openWindow(id: "worktrees")
                    model.selectWorktreeRepository(containing: model.activePane?.cwd ?? model.defaultFolder)
                }
                Divider()
                Button("Attach Folder…") {
                    if let workspace = model.activeWorkspace { model.attachFolder(to: workspace) }
                }
                    .disabled(model.activeWorkspace == nil)
                Button("Choose New Pane Folder…") { model.chooseFolder() }
                    .disabled(model.activeWorkspace == nil)
                Button("Clear New Pane Folder") { model.clearWorkspaceNewPaneFolder() }
                    .disabled(model.activeWorkspace?.newPaneFolder == nil)
                Divider()
                Button("Save Current Layout…") { model.saveActiveWorkspaceLayout() }
                    .disabled(model.activeWorkspace == nil)
            }
            CommandMenu("Tools") {
                Button("Worktrees…") { openWindow(id: "worktrees") }
                Button("Team Sessions…") { openWindow(id: "main"); model.reviewTeamSessions() }
                Divider()
                Button("Environment Check…") { model.showEnvironmentCheck() }
                Button("Compatibility & Releases…") { model.showReleaseLifecycle() }
                Button("Check for Stable Updates…") { model.checkForStableAutomaticUpdate() }
                    .disabled(!model.automaticUpdateCanCheck)
                Divider()
                Button("Export Diagnostics…") { model.exportDiagnostics() }
                    .disabled(model.diagnosticsExporting)
            }
            CommandMenu("Pane") {
                Button("New Agent Pane…") { model.createAgent(direction: .horizontal) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Claude Pane") { model.create(.claude, direction: .horizontal) }
                    .keyboardShortcut(KeyEquivalent(PaneCreationShortcut.key(for: .claude)!), modifiers: [.command, .option])
                Button("New Codex Pane") { model.create(.codex, direction: .horizontal) }
                    .keyboardShortcut(KeyEquivalent(PaneCreationShortcut.key(for: .codex)!), modifiers: [.command, .option])
                Button("New Agy Pane") { model.create(.agy, direction: .horizontal) }
                    .keyboardShortcut(KeyEquivalent(PaneCreationShortcut.key(for: .agy)!), modifiers: [.command, .option])
                Button("New Shell Pane") { model.create(.shell, direction: .horizontal) }
                    .keyboardShortcut(KeyEquivalent(PaneCreationShortcut.key(for: .shell)!), modifiers: [.command, .option])
                Button("New Copilot Pane") { model.create(.copilot, direction: .horizontal) }
                    .keyboardShortcut(KeyEquivalent(PaneCreationShortcut.key(for: .copilot)!), modifiers: [.command, .option])
                // The items above split beside; the toolbar's Pane menu also
                // offered below and another folder, and this menu did not.
                Menu("Split Below") {
                    Button("New Agent Pane Below…") { model.createAgent(direction: .vertical) }
                    Button("New Shell Pane Below") { model.create(.shell, direction: .vertical) }
                }
                Menu("In Another Folder") {
                    Button("New Agent Pane Beside…") { model.createInChosenFolder(model.lastAgentVendor, direction: .horizontal) }
                    Button("New Agent Pane Below…") { model.createInChosenFolder(model.lastAgentVendor, direction: .vertical) }
                    Divider()
                    Button("New Shell Pane Beside…") { model.createInChosenFolder(.shell, direction: .horizontal) }
                    Button("New Shell Pane Below…") { model.createInChosenFolder(.shell, direction: .vertical) }
                }
                Divider()
                Button(model.quickRelayTarget.map { "Ask \($0.displayName) with Selection…" } ?? "Ask Last Target with Selection…") {
                    model.quickRelaySelection()
                }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!model.canQuickRelaySelection)
                    .help("Open the active pane's exact terminal selection in the reviewed Ask composer")
                Divider()
                Button("Answer Waiting Ask…") { model.returnAnswer() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.canReturn)
                Button("Balance Panes") { model.balance() }
                    .disabled(model.activePresentation == .tabs)
                Divider()
                Button("Terminal Appearance…") { model.showTerminalFontSettings() }
            }
        }

        Settings {
            AuxiliaryWindowRoot(minimumSize: CGSize(width: 680, height: 590)) { ParleySettingsView(model: model) }
        }

        MenuBarExtra {
            AttentionInboxMenu(model: model)
        } label: {
            AttentionInboxMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Status Center", id: "status-center") {
            AuxiliaryWindowRoot(minimumSize: CGSize(width: 980, height: 640)) { StatusCenterView(model: model) }
        }
        .defaultSize(width: 1_120, height: 780)
        .windowResizability(.contentMinSize)


        Window("Worktrees", id: "worktrees") {
            AuxiliaryWindowRoot(minimumSize: CGSize(width: 900, height: 560)) { WorktreeManagerView(model: model) }
        }
        .defaultSize(width: 1_060, height: 700)
        .windowResizability(.contentMinSize)

        Window("Parley Help", id: "help") {
            AuxiliaryWindowRoot(minimumSize: CGSize(width: 820, height: 590)) { HelpView(model: model) }
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)

        Window("About Parley", id: "about") {
            AuxiliaryWindowRoot(minimumSize: CGSize(width: 650, height: 1)) { AboutView(runtime: model.runtime, updateChannel: model.releaseChannel) }
        }
        .windowResizability(.contentSize)
    }
}
