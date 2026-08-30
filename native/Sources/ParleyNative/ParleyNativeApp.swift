import AppKit
import ParleyCore
import SwiftUI

fileprivate enum ExternalApplicationRequest: Equatable {
    case workspace(ExternalWorkspaceOpenRequest)
    case contextManifest(URL)
    case navigation(ExternalNavigationRequest)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var externalRequestHandler: ((ExternalApplicationRequest) -> Void)?
    private var pendingExternalRequests: [ExternalApplicationRequest] = []
    private var titlebarZoomRecognizer: NSClickGestureRecognizer?
    private var keyDownMonitor: Any?
    var terminationHandler: (() -> Bool)?
    var terminalFocusRepairHandler: ((NSEvent) -> Void)?
    var applicationShortcutHandler: ((WorkbenchKeyboardShortcut) -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (terminationHandler?() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no app bundle to declare a foreground
        // activation policy. Promote it explicitly during development so its
        // WindowGroup is visible and behaves like a normal macOS application.
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
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
        sender.orderOut(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
    }

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
            receive(Result {
                if url.host?.caseInsensitiveCompare(ExternalWorkspaceOpen.action) == .orderedSame {
                    return .workspace(try ExternalWorkspaceOpen.request(url: url))
                }
                return .navigation(try ExternalNavigation.request(url: url))
            })
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
        } else if url.pathExtension.caseInsensitiveCompare("parleycontext") == .orderedSame {
            return .contextManifest(url)
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
        installTitlebarZoomRecognizer(on: window)
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

    private func installTitlebarZoomRecognizer(on window: NSWindow) {
        if let titlebarZoomRecognizer {
            titlebarZoomRecognizer.view?.removeGestureRecognizer(titlebarZoomRecognizer)
        }
        guard let titlebar = titlebarInteractionView(for: window) else { return }
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(zoomFromTitlebar(_:)))
        recognizer.numberOfClicksRequired = 2
        recognizer.buttonMask = 0x1
        recognizer.delaysPrimaryMouseButtonEvents = false
        titlebar.addGestureRecognizer(recognizer)
        titlebarZoomRecognizer = recognizer
    }

    private func titlebarInteractionView(for window: NSWindow) -> NSView? {
        guard let closeButton = window.standardWindowButton(.closeButton) else { return nil }
        var candidate = closeButton.superview
        while let view = candidate {
            if view.bounds.width >= window.frame.width * 0.7,
               view.bounds.height >= 24,
               view.bounds.height <= 120 {
                return view
            }
            candidate = view.superview
        }
        return nil
    }

    @objc
    private func zoomFromTitlebar(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        recognizer.view?.window?.performZoom(recognizer)
    }
}

@main
struct ParleyNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Parley", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.terminationHandler = { model.resolveTermination() }
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
                        case .focusActiveTerminal: model.focusActiveTerminal()
                        case .toggleCollaborationDock: model.toggleCollaborationDock()
                        }
                    }
                    appDelegate.bindExternalRequestHandler { request in
                        switch request {
                        case let .workspace(workspace): model.openExternalWorkspace(workspace)
                        case let .contextManifest(file): model.importExternalContext(file: file)
                        case let .navigation(navigation):
                            if model.openExternalNavigation(navigation) {
                                openWindow(id: "status-center")
                            }
                        }
                    }
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
            CommandGroup(after: .appSettings) {
                Button("Prepare to Uninstall…") { model.prepareToUninstall() }
                    .disabled(!model.canPrepareToUninstall)
            }
            CommandMenu("Navigate") {
                Button("Command Palette…") { model.showCommandPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
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
                Button(model.focusCanvasPaneID == nil ? "Enter Focus Canvas" : "Return to Pane Grid") {
                    model.toggleFocusCanvas()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.activePane == nil)
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
                Button("Open Worktree…") { model.showWorktreeBrowser() }
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
                Button("Save Current as Team Template…") { model.saveActiveWorkspaceAsTeamTemplate() }
                    .disabled(model.activeWorkspace == nil)
            }
            CommandMenu("Tools") {
                Button("Environment Check…") { model.showEnvironmentCheck() }
                Button("Compatibility & Releases…") { model.showReleaseLifecycle() }
                Toggle(
                    "Reap Idle Agents After 30 Minutes",
                    isOn: Binding(
                        get: { model.idleAgentReaperEnabled },
                        set: { model.idleAgentReaperEnabled = $0 }
                    )
                )
                Divider()
                Button("Export Diagnostics…") { model.exportDiagnostics() }
                    .disabled(model.diagnosticsExporting)
            }
            CommandMenu("Pane") {
                Button("New Claude Pane") { model.create(.claude, direction: .horizontal) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("New Codex Pane") { model.create(.codex, direction: .horizontal) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("New Agy Pane") { model.create(.agy, direction: .horizontal) }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Button("New Shell Pane") { model.create(.shell, direction: .horizontal) }
                    .keyboardShortcut("4", modifiers: [.command, .shift])
                Button("New Copilot Pane") { model.create(.copilot, direction: .horizontal) }
                    .keyboardShortcut("5", modifiers: [.command, .shift])
                Divider()
                Button("Return Answer") { model.returnAnswer() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.canReturn)
                Button("Balance Panes") { model.balance() }
                Divider()
                Button("Terminal Font…") { model.showTerminalFontSettings() }
            }
        }

        MenuBarExtra {
            AttentionInboxMenu(model: model)
        } label: {
            AttentionInboxMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("Status Center", id: "status-center") {
            StatusCenterView(model: model)
        }
        .defaultSize(width: 1_120, height: 780)
        .windowResizability(.contentMinSize)

        Window("Parley Help", id: "help") {
            HelpView(model: model)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)

        Window("About Parley", id: "about") {
            AboutView(runtime: model.runtime, updateChannel: model.releaseChannel)
        }
        .windowResizability(.contentSize)
    }
}
