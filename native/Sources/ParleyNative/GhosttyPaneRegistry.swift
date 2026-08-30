import AppKit
import GhosttyTerminal
import ParleyCore

@MainActor
final class GhosttyPaneRegistry {
    private final class Delegate: NSObject,
        TerminalSurfaceTitleDelegate,
        TerminalSurfaceFocusDelegate,
        TerminalSurfaceCloseDelegate,
        TerminalSurfacePwdDelegate,
        TerminalSurfaceLifecycleDelegate
    {
        let paneID: String
        var onTitle: (String, String) -> Void
        var onFocus: (String) -> Void
        var onClose: (String, Bool) -> Void
        var onWorkingDirectory: (String, String) -> Void
        var onAttach: (String) -> Void
        var onDetach: (String) -> Void

        init(
            paneID: String,
            onTitle: @escaping (String, String) -> Void,
            onFocus: @escaping (String) -> Void,
            onClose: @escaping (String, Bool) -> Void,
            onWorkingDirectory: @escaping (String, String) -> Void,
            onAttach: @escaping (String) -> Void,
            onDetach: @escaping (String) -> Void
        ) {
            self.paneID = paneID
            self.onTitle = onTitle
            self.onFocus = onFocus
            self.onClose = onClose
            self.onWorkingDirectory = onWorkingDirectory
            self.onAttach = onAttach
            self.onDetach = onDetach
        }

        func terminalDidChangeTitle(_ title: String) { onTitle(paneID, title) }
        func terminalDidChangeFocus(_ focused: Bool) { if focused { onFocus(paneID) } }
        func terminalDidClose(processAlive: Bool) { onClose(paneID, processAlive) }
        func terminalDidChangeWorkingDirectory(_ path: String) { onWorkingDirectory(paneID, path) }
        func terminalDidAttachSurface(_ surface: TerminalSurface) { onAttach(paneID) }
        func terminalDidDetachSurface() { onDetach(paneID) }
    }

    private struct Entry {
        let generation: Int
        let view: AppTerminalView
        let delegate: Delegate
    }

    private let terminalController = TerminalController { builder in
        builder.withBackground("#161616")
        builder.withForeground("#d6d6d6")
        builder.withBackgroundOpacity(1)
        builder.withSelectionBackground("#315c91")
        builder.withSelectionForeground("#ffffff")
        builder.withWindowPaddingX(8)
        builder.withWindowPaddingY(7)
        builder.withCustom("copy-on-select", "false")
    }
    private weak var workbench: WorkbenchController?
    private var entries: [String: Entry] = [:]
    private var selectedPaneID: String?
    var onPaneFocused: ((String) -> Void)?
    var onPaneStateChanged: (() -> Void)?

    func bind(_ workbench: WorkbenchController) {
        self.workbench = workbench
    }

    func applyTerminalFont(_ preference: TerminalFontPreference) throws {
        var configuration = TerminalConfiguration()
        if let family = preference.family {
            configuration = configuration.fontFamily(family)
        }
        if let size = preference.size {
            configuration = configuration.fontSize(Float(size))
        }
        guard terminalController.terminalConfiguration != configuration else { return }
        guard terminalController.setTerminalConfiguration(configuration) else {
            throw ParleyWorkbenchError.commandFailed(
                terminalController.lastConfigurationIssue
                    ?? "Ghostty could not apply the terminal font configuration."
            )
        }
    }

    func view(for paneID: String) throws -> AppTerminalView {
        guard let workbench else {
            throw ParleyWorkbenchError.commandFailed("Parley's Ghostty workbench is unavailable.")
        }
        let launch = try workbench.launchConfiguration(for: paneID)
        if let existing = entries[paneID], existing.generation == launch.generation {
            existing.view.setSurfaceVisible(true)
            return existing.view
        }
        stop(paneID: paneID)

        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment,
            command: launch.command,
            waitAfterCommand: true,
            context: .window,
            resizeThrottleMilliseconds: 64
        )
        let delegate = Delegate(
            paneID: paneID,
            onTitle: { [weak self] paneID, title in
                try? self?.workbench?.terminalDidChangeTitle(paneID: paneID, title: title)
                self?.onPaneStateChanged?()
            },
            onFocus: { [weak self] paneID in
                guard let self else { return }
                selectedPaneID = paneID
                onPaneFocused?(paneID)
            },
            onClose: { [weak self] paneID, processAlive in
                try? self?.workbench?.terminalDidClose(paneID: paneID, processAlive: processAlive)
                self?.onPaneStateChanged?()
            },
            onWorkingDirectory: { [weak self] paneID, path in
                try? self?.workbench?.terminalDidChangeWorkingDirectory(paneID: paneID, path: path)
                self?.onPaneStateChanged?()
            },
            onAttach: { [weak self] paneID in
                try? self?.workbench?.terminalDidAttach(paneID: paneID)
                self?.onPaneStateChanged?()
            },
            onDetach: { [weak self] paneID in
                try? self?.workbench?.terminalDidDetach(paneID: paneID)
                self?.onPaneStateChanged?()
            }
        )
        view.delegate = delegate
        view.controller = terminalController
        entries[paneID] = Entry(generation: launch.generation, view: view, delegate: delegate)
        return view
    }

    func setVisible(_ visible: Bool, paneID: String) {
        entries[paneID]?.view.setSurfaceVisible(visible)
    }

    func select(paneID: String?) {
        selectedPaneID = paneID
    }

    var selectedView: AppTerminalView? {
        selectedPaneID.flatMap { entries[$0]?.view }
    }

    func focusSelected(in window: NSWindow? = nil) -> Bool {
        guard let view = selectedView else { return false }
        if let window, view.window !== window { return false }
        return view.acquireProgrammaticFocus()
    }

    func repairFocusIfNeeded(in window: NSWindow, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let commandChord = modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        guard !commandChord,
              let selectedView,
              selectedView.window === window,
              window.firstResponder !== selectedView else { return false }
        return selectedView.acquireProgrammaticFocus()
    }

    func selectedText() -> String? {
        guard let view = selectedView else { return nil }
        return selectionText(from: view)
    }

    func paste(_ text: String, into paneID: String, submit: Bool) throws {
        guard let entry = entries[paneID], entry.view.controller != nil,
              let pane = try workbench?.listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
        }
        let previousWindow = NSApp.keyWindow
        let previousResponder = previousWindow?.firstResponder
        let timing = PaneSubmissionTiming.forKind(pane.kind, submit: submit)
        _ = entry.view.acquireProgrammaticFocus()
        settleTerminalInput(for: timing.afterFocus)
        guard entry.view.paste(text: text) else {
            throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
        }
        if submit {
            settleTerminalInput(for: timing.afterPaste)
            guard entry.view.sendKey(.enter) else {
                throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
            }
        }
        if let previousWindow, let previousResponder, previousResponder !== entry.view {
            settleTerminalInput(for: timing.beforeRestoringFocus)
            previousWindow.makeFirstResponder(previousResponder)
        }
    }

    func interrupt(paneID: String) throws {
        guard let view = entries[paneID]?.view,
              view.sendKey(.c, modifiers: .ctrl) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
    }

    func captureSelectedText(paneID: String) throws -> String {
        guard let view = entries[paneID]?.view,
              let text = selectionText(from: view),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParleyWorkbenchError.noRelayText
        }
        return text
    }

    func stop(paneID: String) {
        guard let entry = entries.removeValue(forKey: paneID) else { return }
        entry.view.setSurfaceVisible(false)
        // Changing controllers is the public GhosttyTerminal teardown path:
        // the coordinator frees the surface and its owned child PTY.
        entry.view.controller = nil
        if selectedPaneID == paneID { selectedPaneID = nil }
    }

    func retainOnly(paneIDs: Set<String>) {
        for paneID in entries.keys where !paneIDs.contains(paneID) { stop(paneID: paneID) }
    }

    func stopAll() {
        for paneID in Array(entries.keys) { stop(paneID: paneID) }
    }

    private func settleTerminalInput(for interval: TimeInterval) {
        guard interval > 0 else { return }
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            _ = RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.01))
            )
        }
    }

    private func selectionText(from view: AppTerminalView) -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                if let data = item.data(forType: type) { values[type] = data }
            }
        } ?? []
        guard view.copySelectedTextToPasteboard() else { return nil }
        let selected = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !snapshot.isEmpty {
            let restored = snapshot.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        return selected
    }
}
