import AppKit
import Foundation
import ParleyCore
import SwiftTerm

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
    @Published private(set) var controller: TmuxController?
    @Published private(set) var recentFolders: [String] = []
    @Published var startupError: String?

    let terminalHandle = TerminalHandle()
    private let fallbackFolder: String
    private var relayServer: RelayHTTPServer?
    private var relayBroker: RelayBroker?
    private static let recentFoldersKey = "parley.recentWorkspaceFolders"

    init() {
        let requestedFolder = Self.argument(named: "--cwd")
        let initialFolder = requestedFolder ?? FileManager.default.currentDirectoryPath
        fallbackFolder = URL(fileURLWithPath: initialFolder).standardizedFileURL.path
        recentFolders = UserDefaults.standard.stringArray(forKey: Self.recentFoldersKey) ?? []

        do {
            let controller = try TmuxController()
            try controller.bootstrap(cwd: defaultFolder)
            var livePanes = try controller.listPanes()
            let liveWorkspaces = try controller.listWorkspaces()
            let credentials = try RelayCredentials(
                file: controller.applicationDirectory.appendingPathComponent("relay-tokens.json")
            )
            try credentials.retain(paneIDs: Set(livePanes.map(\.id)))
            let shimDirectory = try RelayShim.install(in: controller.applicationDirectory)
            // Persistent tmux panes retain the PATH they were born with. Put a
            // managed copy in the user's existing stable command directory so
            // reattaching the UI upgrades relay access without killing those
            // agent conversations. A foreign `parley` command is never replaced.
            _ = try RelayShim.installCommand(
                in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
            )
            let infoFile = controller.applicationDirectory.appendingPathComponent("relay-url")
            let broker = RelayBroker(
                credentials: credentials,
                panes: { try controller.listPanes() },
                paste: { paneID, text in try controller.paste(text, into: paneID, submit: false) },
                // Relay and Ask may submit; explicit `parley paste` continues
                // to use only the unsent closure above. Ask additionally owns
                // a correlated answer route back to its waiting command.
                submit: { paneID, text in try controller.paste(text, into: paneID, submit: true) }
            )
            let relayServer = RelayHTTPServer(broker: broker, infoFile: infoFile)
            try relayServer.start()
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
            self.controller = controller
            self.relayBroker = broker
            self.relayServer = relayServer
            panes = livePanes
            workspaces = liveWorkspaces
            rememberFolder(defaultFolder)
        } catch {
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

    var askTargets: [TmuxPane] {
        guard let source = activePane, source.kind.isAgent else { return [] }
        return panes.filter { $0.kind.isAgent && $0.kind != source.kind }
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

    func awaitingAnswerCount(for paneID: String) -> Int {
        consultations.count { $0.targetPaneID == paneID && $0.state == .awaitingAnswer }
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
        if let controller {
            workspaces = try controller.listWorkspaces()
            panes = try controller.listPanes()
        }
        consultations = relayBroker?.consultations() ?? []
    }

    func refreshQuietly() {
        do { try refresh() } catch { /* the attached client may be between tmux redraws */ }
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
            guard let controller, let relayBroker else { return }
            guard let edited = editRelay(
                title: "Answer \(consultation.sourceName)",
                message: "Use this only if \(consultation.targetName) printed its answer without running `parley answer`. This completes the waiting command directly; it does not paste or press Enter in \(consultation.sourceName).",
                text: RelayDraft.initialText(selection: terminalHandle.selectedText),
                action: "Return",
                insertVisible: { try controller.capturePane(consultation.targetPaneID) }
            ) else { return }
            let response = relayBroker.answerFromUI(consultationID: consultation.id, text: edited)
            guard response.status == 200 else { throw RelayUIError.message(response.text) }
            try controller.selectPane(consultation.sourcePaneID)
            try refresh()
            terminalHandle.terminal?.selectNone()
            terminalHandle.focus()
        }
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
            try controller?.restartPane(pane.id)
            try refresh()
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
            guard let workspace = activeWorkspace else { return }
            try controller?.setWorkspaceFolder(workspace.id, folder: folder)
            rememberFolder(folder)
            try refresh()
        }
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
                _ = try controller.createWorkspace(folder: standardized)
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
        perform {
            try controller?.renameWorkspace(workspace.id, name: field.stringValue)
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
            try controller?.closeWorkspace(workspace.id)
            try refresh()
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
