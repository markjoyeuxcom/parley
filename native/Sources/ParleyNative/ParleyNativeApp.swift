import AppKit
import ParleyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var externalWorkspaceHandler: ((ExternalWorkspaceOpenRequest) -> Void)?
    private var pendingExternalWorkspaces: [ExternalWorkspaceOpenRequest] = []

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

    func bindExternalWorkspaceHandler(
        _ handler: @escaping (ExternalWorkspaceOpenRequest) -> Void
    ) {
        externalWorkspaceHandler = handler
        let pending = pendingExternalWorkspaces
        pendingExternalWorkspaces.removeAll()
        for request in pending { handler(request) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, let url = urls.first else {
            presentExternalOpenError(ExternalWorkspaceOpenError.oneFolderRequired)
            return
        }
        receive(url.isFileURL
            ? Result { try ExternalWorkspaceOpen.request(folderPaths: [url.path]) }
            : Result { try ExternalWorkspaceOpen.request(url: url) })
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        do {
            enqueue(try ExternalWorkspaceOpen.request(folderPaths: filenames))
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
            enqueue(try ExternalWorkspaceOpen.request(folderPaths: filenames))
        } catch {
            errorPointer.pointee = error.localizedDescription as NSString
            presentExternalOpenError(error)
        }
    }

    private func receive(_ result: Result<ExternalWorkspaceOpenRequest, Error>) {
        switch result {
        case let .success(request): enqueue(request)
        case let .failure(error): presentExternalOpenError(error)
        }
    }

    private func enqueue(_ request: ExternalWorkspaceOpenRequest) {
        foregroundApplication()
        if let externalWorkspaceHandler {
            externalWorkspaceHandler(request)
        } else if !pendingExternalWorkspaces.contains(request) {
            pendingExternalWorkspaces.append(request)
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
        WindowGroup("Parley") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.bindExternalWorkspaceHandler { request in
                        model.openExternalWorkspace(request)
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
                Button("Choose Workspace Folder…") { model.chooseFolder() }
                    .disabled(model.activeWorkspace == nil)
            }
            CommandMenu("Tools") {
                Button("Environment Check…") { model.showEnvironmentCheck() }
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
            AboutView(runtime: model.runtime)
        }
        .windowResizability(.contentSize)
    }
}
