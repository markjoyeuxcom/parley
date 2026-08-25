import Foundation
import Darwin

public enum RelayCoreShutdownReason: String, Equatable, Sendable {
    case upgrade
    case uninstall

    public var preservesExchangeFiles: Bool { self == .upgrade }
}

public struct RelayCoreUninstallTransaction: Equatable, Sendable {
    public let loginItemWasRegistered: Bool
    public private(set) var loginItemWasDisabled = false
    public private(set) var coreStopWasAccepted = false
    public private(set) var preparationWasCompleted = false

    public init(loginItemWasRegistered: Bool) {
        self.loginItemWasRegistered = loginItemWasRegistered
    }

    public mutating func recordLoginItemDisabled() {
        loginItemWasDisabled = true
    }

    public mutating func recordCoreStopAccepted() {
        coreStopWasAccepted = true
    }

    public mutating func recordPreparationCompleted() {
        preparationWasCompleted = true
    }

    public var requiresLoginItemRollback: Bool {
        loginItemWasRegistered && loginItemWasDisabled && !preparationWasCompleted
    }
}

public struct CoreServiceIdentity: Codable, Equatable, Sendable {
    public static let currentContractVersion = 3

    public let contractVersion: Int
    public let applicationVersion: String
    public let build: String

    public init(contractVersion: Int, applicationVersion: String, build: String) {
        self.contractVersion = contractVersion
        self.applicationVersion = applicationVersion
        self.build = build
    }

    public static func resolve(infoDictionary: [String: Any]?) -> CoreServiceIdentity {
        func normalized(_ key: String) -> String {
            guard let value = infoDictionary?[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "development"
            }
            return value
        }
        return CoreServiceIdentity(
            contractVersion: currentContractVersion,
            applicationVersion: normalized("CFBundleShortVersionString"),
            build: normalized("CFBundleVersion")
        )
    }

    public static func current(
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        fileManager: FileManager = .default
    ) -> CoreServiceIdentity {
        let macOSDirectory = executableURL.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let appBundle = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              appBundle.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let data = fileManager.contents(atPath: contentsDirectory.appendingPathComponent("Info.plist").path),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return resolve(infoDictionary: nil)
        }
        return resolve(infoDictionary: dictionary)
    }

    public func requiresHandover(from running: CoreServiceIdentity?) -> Bool {
        running != self
    }
}

public struct RelayUpgradeReadiness: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let activeConsultations: Int
    public let activeDelegations: Int
    public let activeDispatches: Int

    public init(
        accepted: Bool,
        activeConsultations: Int,
        activeDelegations: Int,
        activeDispatches: Int
    ) {
        self.accepted = accepted
        self.activeConsultations = activeConsultations
        self.activeDelegations = activeDelegations
        self.activeDispatches = activeDispatches
    }

    public var activeWorkCount: Int {
        activeConsultations + activeDelegations + activeDispatches
    }
}

public enum RelayCoreHandoverOutcome: Equatable, Sendable {
    case current
    case deferred(RelayUpgradeReadiness)
    case replaced
}

public struct RelayCoreHandoverResult: Sendable {
    public let client: RelayCoreClient
    public let outcome: RelayCoreHandoverOutcome

    public init(client: RelayCoreClient, outcome: RelayCoreHandoverOutcome) {
        self.client = client
        self.outcome = outcome
    }
}

public enum RelayCoreHandover {
    /// Reconciles the long-lived coordination core with the UI bundle that is
    /// currently open. tmux is deliberately outside this lifecycle: replacing
    /// the core never terminates a pane or its vendor CLI process.
    public static func reconcile(
        client: RelayCoreClient,
        expectedIdentity: CoreServiceIdentity,
        applicationDirectory: URL,
        cwd: String,
        environment: [String: String],
        tmuxSessionName: String = "parley",
        runtimeMarker: String? = nil,
        executable: URL? = nil,
        timeout: TimeInterval = 10
    ) throws -> RelayCoreHandoverResult {
        let runningIdentity = try client.coreIdentity()
        guard expectedIdentity.requiresHandover(from: runningIdentity) else {
            return RelayCoreHandoverResult(client: client, outcome: .current)
        }

        if runningIdentity != nil {
            let response = try client.shutdownIfIdle()
            guard response.status == 202 else {
                return RelayCoreHandoverResult(client: client, outcome: .deferred(response.readiness))
            }
        } else {
            let consultations = try client.consultations()
            let handoffs = try client.handoffs(limit: 500)
            guard CoreLoginItemChangePolicy.canDisable(
                activeConsultationCount: consultations.count,
                handoffs: handoffs
            ) else {
                let activeStates: Set<RelayHandoffState> = [.created, .delivered, .waiting, .answered]
                let delegations = handoffs.filter {
                    $0.kind == .delegate && activeStates.contains($0.state)
                }.count
                return RelayCoreHandoverResult(
                    client: client,
                    outcome: .deferred(RelayUpgradeReadiness(
                        accepted: false,
                        activeConsultations: consultations.count,
                        activeDelegations: delegations,
                        activeDispatches: 0
                    ))
                )
            }
            try terminateLegacyCore(applicationDirectory: applicationDirectory)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, client.isHealthy() {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !client.isHealthy() else {
            throw RelayCoreError.serviceFailed("the previous core did not stop after accepting the upgrade")
        }

        let replacement = try RelayCoreLauncher.ensureRunning(
            applicationDirectory: applicationDirectory,
            cwd: cwd,
            environment: environment,
            tmuxSessionName: tmuxSessionName,
            runtimeMarker: runtimeMarker,
            executable: executable,
            timeout: timeout
        )
        guard try replacement.coreIdentity() == expectedIdentity else {
            throw RelayCoreError.serviceFailed("the replacement core does not match this Parley build")
        }
        return RelayCoreHandoverResult(client: replacement, outcome: .replaced)
    }

    public static func validatedLegacyPID(
        pidFileContents: String,
        executablePath: String,
        currentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Int32? {
        guard let pid = Int32(pidFileContents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              pid != currentPID,
              URL(fileURLWithPath: executablePath).lastPathComponent == "parley-core-service" else {
            return nil
        }
        return pid
    }

    private static func terminateLegacyCore(applicationDirectory: URL) throws {
        let pidFile = applicationDirectory.appendingPathComponent("core.pid")
        let contents = try String(contentsOf: pidFile, encoding: .utf8)
        guard let candidate = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              candidate > 1,
              candidate != ProcessInfo.processInfo.processIdentifier else {
            throw RelayCoreError.serviceFailed("the legacy core PID is invalid")
        }

        // proc_pidpath documents a maximum path buffer of 4 KiB. Its C macro
        // is not imported by Swift because it expands through an unsupported
        // structure expression.
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(candidate, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else {
            throw RelayCoreError.serviceFailed("the legacy core process no longer exists")
        }
        let bytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executablePath = String(decoding: bytes, as: UTF8.self)
        guard validatedLegacyPID(
            pidFileContents: contents,
            executablePath: executablePath
        ) == candidate else {
            throw RelayCoreError.serviceFailed("refusing to stop a process that is not parley-core-service")
        }
        guard Darwin.kill(candidate, SIGTERM) == 0 || errno == ESRCH else {
            throw RelayCoreError.serviceFailed("could not stop the legacy core: \(String(cString: strerror(errno)))")
        }
    }
}
