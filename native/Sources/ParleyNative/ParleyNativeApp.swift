import AppKit
import ParleyCore
import SwiftUI

fileprivate enum ExternalApplicationRequest: Equatable {
    case workspace(ExternalWorkspaceOpenRequest)
    case contextManifest(URL)
    case navigation(ExternalNavigationRequest)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var externalRequestHandler: ((ExternalApplicationRequest) -> Void)?
    private var pendingExternalRequests: [ExternalApplicationRequest] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A SwiftPM executable has no app bundle to declare a foreground
        // activation policy. Promote it explicitly during development so its
        // WindowGroup is visible and behaves like a normal macOS application.
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = self
        DispatchQueue.main.async {
            self.applyDevelopmentIcon()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
            }
            CommandMenu("Workspace") {
                Button("Open Workspace…") { model.createWorkspace() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open New Workspace…") { model.createAdditionalWorkspace() }
                Button("Choose New Pane Folder…") { model.chooseFolder() }
                    .disabled(model.activeWorkspace == nil)
            }
            CommandMenu("Tools") {
                Button("Environment Check…") { model.showEnvironmentCheck() }
                Button("Compatibility & Releases…") { model.showReleaseLifecycle() }
                Divider()
                Toggle(
                    "Keep Coordination Core Available at Login",
                    isOn: Binding(
                        get: { model.coreLoginItemRequested },
                        set: { requested in model.setCoreLoginItemRequested(requested) }
                    )
                )
                .disabled(!model.canChangeCoreLoginItem)
                if model.coreLoginItemState == .requiresApproval {
                    Button("Open Login Items Settings…") {
                        model.openCoreLoginItemSettings()
                    }
                }
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
                Button("Zoom Active Pane") { model.zoom() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("Balance Panes") { model.balance() }
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
