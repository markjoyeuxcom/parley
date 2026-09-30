import Foundation
import ParleyCore

// A pane's own Stop item (Mark's container test of 25 September 2026: the only
// way to stop a container pane was Status Center > Health > Containers).

private func stopExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "PaneStop", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func stopSource(_ folder: String, _ file: String) throws -> SwiftSourceReader {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(folder).appendingPathComponent(file)
    return SwiftSourceReader(try String(contentsOf: url, encoding: .utf8))
}

private func stopBody(_ reader: SwiftSourceReader, _ signature: String) throws -> Substring {
    guard let found = reader.text.range(of: signature),
          let open = reader.text[found.upperBound...].firstIndex(of: "{"),
          let body = reader.balanced(at: open) else {
        throw NSError(domain: "PaneStop", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(signature) was not found"])
    }
    return body
}

@MainActor let paneStopChecks: [(String, () throws -> Void)] = [
    ("a started agent pane's own menu offers Stop", {
        let menu = try stopBody(try stopSource("ParleyNative", "ContentView.swift"), "private func paneMenuItems(")
        guard let stop = menu.range(of: "\"Stop…\"") else { throw NSError(domain: "PaneStop", code: 3, userInfo: [NSLocalizedDescriptionKey: "the pane menu has no Stop… item"]) }
        try stopExpect(menu[stop.upperBound...].prefix(80).contains("model.stop(pane)"), "the pane menu's Stop… does not call model.stop(pane)")
        // Only a started agent pane has a process to stop: the item sits in
        // the agent branch, inside its isStarted block.
        let before = menu[..<stop.lowerBound]
        guard let agent = before.range(of: "if pane.kind.isAgent", options: .backwards),
              let started = before.range(of: "if pane.isStarted {", options: .backwards) else {
            throw NSError(domain: "PaneStop", code: 4, userInfo: [NSLocalizedDescriptionKey: "Stop… is not inside the agent pane's started block"])
        }
        try stopExpect(agent.lowerBound < started.lowerBound, "Stop… is not inside the agent pane's started block")
        try stopExpect(!menu[started.upperBound..<stop.lowerBound].contains("} else"), "Stop… fell outside the started block")
    }),
    ("Stop confirms, stops a container before the pane and names the generation it reviewed", {
        let stop = try stopBody(try stopSource("ParleyNative", "AppModel.swift"), "func stop(_ pane: WorkbenchPane)")
        guard let confirm = stop.range(of: "runModal()"),
              let containers = stop.range(of: "performAfterContainerStops([pane])"),
              let process = stop.range(of: "stopPaneProcess(pane.id, expectedGeneration: pane.launchGeneration)"),
              let refresh = stop.range(of: "refresh()") else {
            throw NSError(domain: "PaneStop", code: 5, userInfo: [NSLocalizedDescriptionKey: "stop(_:) must confirm, run performAfterContainerStops([pane]), call stopPaneProcess with the reviewed generation and refresh"])
        }
        try stopExpect(confirm.lowerBound < containers.lowerBound, "stop(_:) acts before the person confirms")
        try stopExpect(containers.lowerBound < process.lowerBound && process.lowerBound < refresh.lowerBound,
                       "stop(_:) must stop the process inside performAfterContainerStops, after any container, then refresh")
        try stopExpect(!stop.contains("expectedGeneration: nil"), "stop(_:) must never stop whatever generation runs now")
    }),
]
