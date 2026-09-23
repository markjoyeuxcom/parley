import AppKit
import GhosttyTerminal
import GhosttyTheme
import ParleyCore
import ParleyUI

struct GhosttyPaneProcessAnchor {
    let foregroundPID: Int32?
    let ttyName: String?
}

@MainActor
final class GhosttyPaneRegistry {
    private final class Delegate: NSObject,
        TerminalSurfaceTitleDelegate,
        TerminalSurfaceFocusDelegate,
        TerminalSurfaceCloseDelegate,
        TerminalSurfacePwdDelegate,
        TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceLifecycleDelegate
    {
        let paneID: String
        var onTitle: (String, String) -> Void
        var onFocus: (String) -> Void
        var onClose: (String, Bool) -> Void
        var onWorkingDirectory: (String, String) -> Void
        var onAttach: (String) -> Void
        var onDetach: (String) -> Void
        var onOpenURL: (String) -> Void

        init(
            paneID: String,
            onTitle: @escaping (String, String) -> Void,
            onFocus: @escaping (String) -> Void,
            onClose: @escaping (String, Bool) -> Void,
            onWorkingDirectory: @escaping (String, String) -> Void,
            onAttach: @escaping (String) -> Void,
            onDetach: @escaping (String) -> Void,
            onOpenURL: @escaping (String) -> Void
        ) {
            self.paneID = paneID
            self.onTitle = onTitle
            self.onFocus = onFocus
            self.onClose = onClose
            self.onWorkingDirectory = onWorkingDirectory
            self.onAttach = onAttach
            self.onDetach = onDetach
            self.onOpenURL = onOpenURL
        }

        func terminalDidChangeTitle(_ title: String) { onTitle(paneID, title) }
        func terminalDidChangeFocus(_ focused: Bool) { if focused { onFocus(paneID) } }
        func terminalDidClose(processAlive: Bool) { onClose(paneID, processAlive) }
        func terminalDidChangeWorkingDirectory(_ path: String) { onWorkingDirectory(paneID, path) }
        func terminalDidAttachSurface(_ surface: TerminalSurface) { onAttach(paneID) }
        func terminalDidDetachSurface() { onDetach(paneID) }
        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) { onOpenURL(url) }
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
    /// Lends a pane focus for a delivery that needs it. Its focus callbacks
    /// meanwhile are not the person choosing that pane: they change no
    /// selection, and focus repair leaves the lent focus alone.
    private let deliveryFocus = DeliveryFocus()
    var onPaneFocused: ((String) -> Void)?
    var onPaneStateChanged: (() -> Void)?
    /// A title actually changed. Titles are display metadata only, so the
    /// model publishes pane state without relay fetching or layout work.
    var onPaneTitleChanged: (() -> Void)?

    func bind(_ workbench: WorkbenchController) {
        self.workbench = workbench
    }

    func loadGhosttyAppearanceImport() throws -> GhosttyAppearanceImport {
        try GhosttyAppearanceImporter.load(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            builtInTheme: { name in
                guard let theme = GhosttyThemeCatalog.theme(named: name) else { return nil }
                return GhosttyAppearanceColors(
                    background: theme.background,
                    foreground: theme.foreground,
                    cursorColor: theme.cursorColor,
                    cursorText: theme.cursorText,
                    selectionBackground: theme.selectionBackground,
                    selectionForeground: theme.selectionForeground,
                    palette: theme.palette
                )
            }
        )
    }

    func applyTerminalAppearance(
        font preference: TerminalFontPreference,
        imported appearance: GhosttyAppearanceImport?
    ) throws {
        let resolvedFont = try preference.resolving(imported: appearance)
        var configuration = TerminalConfiguration()
        if let family = resolvedFont.family {
            configuration = configuration.fontFamily(family)
        }
        if let size = resolvedFont.size {
            configuration = configuration.fontSize(Float(size))
        }

        let theme: TerminalTheme
        if let appearance {
            theme = TerminalTheme(
                light: Self.configuration(for: appearance.light),
                dark: Self.configuration(for: appearance.dark)
            )
        } else {
            theme = .default
        }

        let previousConfiguration = terminalController.terminalConfiguration
        let previousTheme = terminalController.theme
        if configuration != previousConfiguration,
           !terminalController.setTerminalConfiguration(configuration)
        {
            throw ParleyWorkbenchError.commandFailed(
                terminalController.lastConfigurationIssue
                    ?? "Ghostty could not apply the terminal font configuration."
            )
        }
        if theme != previousTheme, !terminalController.setTheme(theme) {
            if configuration != previousConfiguration {
                _ = terminalController.setTerminalConfiguration(previousConfiguration)
            }
            throw ParleyWorkbenchError.commandFailed(
                terminalController.lastConfigurationIssue
                    ?? "Ghostty could not apply the imported terminal colours."
            )
        }
    }

    func applyTerminalFont(_ preference: TerminalFontPreference) throws {
        try applyTerminalAppearance(font: preference, imported: nil)
    }

    private static func configuration(for colors: GhosttyAppearanceColors) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            if let value = colors.background { builder.withBackground(value) }
            if let value = colors.foreground { builder.withForeground(value) }
            if let value = colors.cursorColor { builder.withCursorColor(value) }
            if let value = colors.cursorText { builder.withCursorText(value) }
            if let value = colors.selectionBackground { builder.withSelectionBackground(value) }
            if let value = colors.selectionForeground { builder.withSelectionForeground(value) }
            if let value = colors.boldColor { builder.withBoldColor(value) }
            for index in colors.palette.keys.sorted() {
                guard let color = colors.palette[index] else { continue }
                builder.withPalette(index, color: color)
            }
        }
    }

    func view(for paneID: String) throws -> AppTerminalView {
        guard let workbench else {
            throw ParleyWorkbenchError.commandFailed("Parley's Ghostty workbench is unavailable.")
        }
        guard let pane = try workbench.listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.paneNotFound(paneID)
        }
        if let existing = entries[paneID], existing.generation == pane.launchGeneration {
            existing.view.setSurfaceVisible(true)
            return existing.view
        }
        let launch = try workbench.launchConfiguration(for: paneID)
        stop(paneID: paneID)

        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 420))
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            workingDirectory: launch.workingDirectory,
            envVars: launch.environment,
            command: launch.command,
            // Ghostty forces this on for any surface created with a command;
            // stated here so the behaviour is explicit, not chosen per pane.
            waitAfterCommand: true,
            context: .window,
            resizeThrottleMilliseconds: 64
        )
        let delegate = Delegate(
            paneID: paneID,
            onTitle: { [weak self] paneID, title in
                guard let self, let workbench = self.workbench else { return }
                if (try? workbench.terminalDidChangeTitle(paneID: paneID, title: title)) == true {
                    self.onPaneTitleChanged?()
                }
            },
            onFocus: { [weak self] paneID in
                guard let self, paneID != deliveryFocus.paneID else { return }
                selectedPaneID = paneID
                onPaneFocused?(paneID)
            },
            onClose: { [weak self] paneID, processAlive in
                guard let self, let workbench = self.workbench else { return }
                guard let closed = try? workbench.listPanes().first(where: { $0.id == paneID }),
                      closed.launchGeneration == launch.generation else { return }
                try? workbench.terminalDidClose(paneID: paneID, generation: launch.generation, processAlive: processAlive)
                self.onPaneStateChanged?()
                // A lost docker client does not prove its daemon-owned process
                // ended. Reconcile its exact receipt in the background. Ordinary
                // deliberate termination has already completed this cleanup.
                if !processAlive, !workbench.isTerminatingSurface,
                   closed.containerConfiguration != nil {
                    Task { [weak self] in
                        do {
                            try await Task.detached(priority: .utility) { try workbench.prepareContainerStop(closed) }.value
                            try workbench.stopPaneProcess(paneID)
                            self?.onPaneStateChanged?()
                        } catch {
                            NSAlert(error: ContainerPaneError.refused("The container client ended, but cleanup was not confirmed. Its receipt remains in Status Center. \(error.localizedDescription)")).runModal()
                        }
                    }
                }
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
            },
            // The pane's own process wrote this link. Only an ordinary web URL
            // is handed to the system; anything that could launch something
            // local is ignored rather than reported, because a refused click is
            // not an error the person asked for.
            onOpenURL: { url in
                guard let opened = TerminalLinkPolicy.openableURL(url) else { return }
                NSWorkspace.shared.open(opened)
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

    func processAnchor(for paneID: String) -> GhosttyPaneProcessAnchor {
        guard let view = entries[paneID]?.view else {
            return GhosttyPaneProcessAnchor(foregroundPID: nil, ttyName: nil)
        }
        return GhosttyPaneProcessAnchor(
            foregroundPID: view.foregroundPid,
            ttyName: view.ttyName
        )
    }

    func focusSelected(in window: NSWindow? = nil) -> Bool {
        guard deliveryFocus.paneID == nil, let view = selectedView else { return false }
        if let window, view.window !== window { return false }
        return view.acquireProgrammaticFocus()
    }

    func repairFocusIfNeeded(in window: NSWindow, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let commandChord = modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        guard !commandChord, deliveryFocus.paneID == nil,
              let selectedView,
              selectedView.window === window,
              window.firstResponder !== selectedView else { return false }
        return selectedView.acquireProgrammaticFocus()
    }

    func selectedText() -> String? {
        guard let view = selectedView else { return nil }
        return selectionText(from: view)
    }

    func paste(_ text: String, into paneID: String, submit: Bool, validate: () throws -> Void = {}) throws {
        try validate()
        guard let entry = entries[paneID], entry.view.controller != nil,
              let pane = try workbench?.listPanes().first(where: { $0.id == paneID }) else {
            throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
        }
        let timing = PaneSubmissionTiming.forKind(pane.kind, submit: submit)
        // Ghostty takes paste and Enter on a surface without focus, so only a
        // delivery that needs its pane focused (Copilot's submission) moves
        // the person's focus, and `DeliveryFocus` gives it back.
        guard timing.focusesTarget else {
            try deliver(text, to: entry, paneID: paneID, submit: submit, timing: timing, validate: validate)
            return
        }
        try deliveryFocus.deliver(focusing: entry.view, paneID: paneID, beforeRestoring: timing.beforeRestoringFocus,
                                  settle: { settleTerminalInput(for: $0) }) {
            try deliver(text, to: entry, paneID: paneID, submit: submit, timing: timing, validate: validate)
        }
    }

    private func deliver(_ text: String, to entry: Entry, paneID: String, submit: Bool,
                         timing: PaneSubmissionTiming, validate: () throws -> Void) throws {
        settleTerminalInput(for: timing.afterFocus)
        try requireLiveTarget(paneID, entry)
        try validate()
        guard entry.view.paste(text: text) else {
            throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
        }
        if submit {
            settleTerminalInput(for: timing.afterPaste)
            try requireLiveTarget(paneID, entry)
            try validate()
            guard entry.view.sendKey(.enter) else {
                throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
            }
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

    /// Lets the terminal consume what was just delivered before the next step.
    ///
    /// The deadline is monotonic on purpose. `Date()` is the wall clock, and a
    /// backward step from an NTP correction would keep the comparison true for
    /// the length of the step, spinning the main thread and freezing the window
    /// until the clock caught up. Only the run loop's own `before:` argument
    /// stays a `Date`, because that is the API's shape, and it is recomputed
    /// from the current clock on every turn rather than held across the wait.
    private func settleTerminalInput(for interval: TimeInterval) {
        guard interval > 0 else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(interval * 1_000_000_000)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return }
            let remaining = min(0.01, Double(deadline &- now) / 1_000_000_000)
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(remaining))
        }
    }

    /// Confirms the pane is still the one this delivery started against.
    ///
    /// `settleTerminalInput` pumps the main run loop, so a close, stop, restart
    /// or workspace change can run between one input step and the next. The
    /// `Entry` captured before that is then stale: its view may already have had
    /// its controller cleared by `stop(paneID:)`. Sending the rest of a delivery
    /// into a torn-down surface would report a submission that never landed.
    private func requireLiveTarget(_ paneID: String, _ started: Entry) throws {
        guard let current = entries[paneID],
              current.generation == started.generation,
              current.view === started.view,
              current.view.controller != nil else {
            throw ParleyWorkbenchError.unsafeRelayTarget(paneID)
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
