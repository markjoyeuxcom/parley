import Foundation
import ParleyCore

// A pane's own Stop item (Mark's container test of 25 September 2026: the only
// way to stop a container pane was Status Center > Health > Containers).
// These read the source structurally: each requirement names the block that
// must contain it, found by balanced braces, because a check on the order of
// strings alone passed wiring that had regressed (the team review of the
// first version, 1 October 2026).

private func stopFailure(_ message: String) -> NSError {
    NSError(domain: "PaneStop", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func stopExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw stopFailure(message) }
}

private func stopSource(_ folder: String, _ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

/// The body of every block opened by `opener` (which ends with its delimiter)
/// inside `region`, in source order.
private func stopBlocks(_ reader: SwiftSourceReader, _ opener: String, in region: Substring) -> [Substring] {
    var bodies: [Substring] = []
    var search = region.startIndex..<region.endIndex
    while let found = reader.text.range(of: opener, range: search) {
        search = found.upperBound..<region.endIndex
        if let body = reader.balanced(at: reader.text.index(before: found.upperBound)) { bodies.append(body) }
    }
    return bodies
}

private func stopBody(_ reader: SwiftSourceReader, _ signature: String) throws -> Substring {
    guard let found = reader.text.range(of: signature),
          let open = reader.text[found.upperBound...].firstIndex(of: "{"),
          let body = reader.balanced(at: open) else { throw stopFailure("\(signature) was not found") }
    return body
}

@MainActor let paneStopChecks: [(String, () throws -> Void)] = [
    ("a started agent pane's own menus offer Stop", {
        let view = try stopSource("ParleyNative", "ContentView.swift")
        let menu = try stopBody(view, "private func paneMenuItems(")
        try stopExpect(menu.components(separatedBy: "\"Stop…\"").count == 2, "the pane menu must offer Stop… exactly once")
        // The agent block that holds the lifecycle items, then its started block.
        guard let lifecycle = stopBlocks(view, "if pane.kind.isAgent {", in: menu).first(where: { $0.contains("Restart Fresh Session…") }),
              let started = stopBlocks(view, "if pane.isStarted {", in: lifecycle).first(where: { $0.contains("\"Stop…\"") }) else {
            throw stopFailure("Stop… is not inside the agent pane's isStarted block")
        }
        guard let item = started.range(of: "\"Stop…\""),
              let action = view.balanced(at: started[item.upperBound...].firstIndex(of: "{") ?? started.endIndex) else {
            throw stopFailure("Stop… has no action")
        }
        try stopExpect(action.trimmingCharacters(in: .whitespacesAndNewlines) == "model.stop(pane)", "the pane menu's Stop… does not call model.stop(pane)")
        // The header's ellipsis and the sidebar's right-click menu both show this list.
        try stopExpect(view.text.contains("PaneContextMenu(items: paneMenuItems(pane))"), "the sidebar context menu no longer uses paneMenuItems")
        try stopExpect(stopBlocks(view, "PaneActionsMenu(", in: view.text[...]).contains { $0.contains("paneMenuItems(pane)") },
                       "the pane header menu no longer uses paneMenuItems")
    }),
    ("Stop confirms, stops a container before the pane and names the generation it reviewed", {
        let model = try stopSource("ParleyNative", "AppModel.swift")
        let stop = try stopBody(model, "func stop(_ pane: WorkbenchPane)")
        guard let cancel = stop.range(of: "guard alert.runModal() == .alertFirstButtonReturn else { return }") else {
            throw stopFailure("stop(_:) must return when the person cancels")
        }
        let helpers = stopBlocks(model, "performAfterContainerStops([pane]) {", in: stop)
        try stopExpect(helpers.count == 1, "stop(_:) must run its work in one performAfterContainerStops([pane]) closure")
        let work = helpers[0]
        try stopExpect(cancel.upperBound <= work.startIndex, "stop(_:) acts before the person confirms")
        guard let process = work.range(of: "stopPaneProcess(pane.id, expectedGeneration: pane.launchGeneration)"),
              let refresh = work.range(of: "refresh()") else {
            throw stopFailure("the container-stop closure must stop the reviewed generation and refresh")
        }
        try stopExpect(process.upperBound <= refresh.lowerBound, "stop(_:) refreshes before stopping")
        // Nothing outside the closure stops a process: that would not wait for the container.
        let outside = String(stop[..<work.startIndex]) + String(stop[work.endIndex...])
        try stopExpect(!outside.contains("stopPaneProcess"), "stop(_:) stops a process outside the container-stop closure")
        try stopExpect(!stop.contains("expectedGeneration: nil"), "stop(_:) must never stop whatever generation runs now")
    }),
]
