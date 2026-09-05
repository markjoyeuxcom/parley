import Foundation
import Darwin

/// Fail before constructing GUI surfaces when the login backend is denied.
public enum GhosttyLaunchPreflight {
    public static func check() throws {
    do {
        let result = try ProcessCommandRunner(timeout: 3).run(
            executable: URL(fileURLWithPath: "/usr/bin/login"),
            arguments: ["-flp", NSUserName(), "/usr/bin/true"],
            environment: ["PATH": "/usr/bin:/bin"])
        guard result.status == 0 else {
            throw NSError(domain: "GhosttyLaunchCheck", code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "Ghostty's /usr/bin/login launch probe failed: \(result.stderrText)"])
        }
    } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) {
        throw NSError(domain: "GhosttyLaunchCheck", code: Int(EPERM),
            userInfo: [NSLocalizedDescriptionKey: "requires human Shell pane: EPERM spawning /usr/bin/login under AgentProcessBoundary"])
    }
}
}
