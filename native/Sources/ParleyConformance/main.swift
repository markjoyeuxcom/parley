import Darwin
import Foundation
import ParleyCore

private struct Options {
    var dryRun = false
    var timeout: TimeInterval = 90
    var vendors: [PaneKind] = []
    var applicationDirectory: URL?
    var runtimeMode: ParleyRuntimeMode?

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dry-run":
                options.dryRun = true
            case "--timeout":
                index += 1
                guard arguments.indices.contains(index),
                      let seconds = Double(arguments[index]),
                      (5...600).contains(seconds) else {
                    throw ConformanceCLIError.usage("--timeout needs a value from 5 to 600 seconds")
                }
                options.timeout = seconds
            case "--vendor":
                index += 1
                guard arguments.indices.contains(index),
                      let vendor = PaneKind(rawValue: arguments[index].lowercased()),
                      vendor.isAgent else {
                    throw ConformanceCLIError.usage("--vendor needs claude, codex, agy, or copilot")
                }
                if !options.vendors.contains(vendor) { options.vendors.append(vendor) }
            case "--application-directory":
                index += 1
                guard arguments.indices.contains(index), !arguments[index].isEmpty else {
                    throw ConformanceCLIError.usage("--application-directory needs an absolute path")
                }
                let url = URL(fileURLWithPath: arguments[index], isDirectory: true).standardizedFileURL
                guard url.path.hasPrefix("/") else {
                    throw ConformanceCLIError.usage("--application-directory needs an absolute path")
                }
                options.applicationDirectory = url
            case "--runtime":
                index += 1
                guard arguments.indices.contains(index),
                      let mode = ParleyRuntimeMode(rawValue: arguments[index]),
                      mode == .production || mode == .development else {
                    throw ConformanceCLIError.usage("--runtime needs production or development")
                }
                options.runtimeMode = mode
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw ConformanceCLIError.usage("unknown argument: \(arguments[index])")
            }
            index += 1
        }
        if options.vendors.isEmpty {
            options.vendors = PaneKind.allCases.filter(\.isAgent)
        }
        guard options.runtimeMode != nil || options.applicationDirectory != nil else {
            throw ConformanceCLIError.usage("name the runtime explicitly with --runtime production or --runtime development")
        }
        return options
    }
}

private enum ConformanceCLIError: LocalizedError {
    case usage(String)
    case runtime(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message), let .runtime(message): message
        }
    }
}

private func printUsage() {
    print("""
    usage: parley-conformance --runtime <production|development> [--dry-run] [--vendor <name>] [--timeout <seconds>]

      --runtime <name>     target exactly one isolated Parley runtime
      --dry-run            inspect open panes and print the plan; spend no quota
      --vendor <name>      probe only claude, codex, agy, or copilot; repeatable
      --timeout <seconds>  bound each live Ask (default 90; range 5...600)

    A live run requires PARLEY_LIVE=1. It uses existing ready panes, records
    ordinary Ask handoffs, and never creates, restarts, or closes a pane.
    """)
}

private func applicationDirectory(for options: Options) -> URL {
    if let applicationDirectory = options.applicationDirectory { return applicationDirectory }
    return ParleyRuntime.make(
        mode: options.runtimeMode ?? .development,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    ).applicationDirectory
}

private func renderPlan(_ plan: [VendorConformancePlanItem]) -> String {
    plan.map { item in
        switch item {
        case let .probe(probe):
            let coverage = [
                probe.testsInactiveTarget ? "inactive target" : "active target only",
                probe.testsCrossWorkspace ? "cross-workspace" : "same workspace only",
            ].joined(separator: ", ")
            return "READY \(probe.vendor.label) — \(probe.source.displayName) \(probe.source.id) → \(probe.target.displayName) \(probe.target.id) (\(coverage))"
        case let .skipped(vendor, reason):
            return "SKIP \(vendor.label) — \(reason)"
        }
    }.joined(separator: "\n")
}

private let operationalChecks = [
    "protocol injection",
    "multiline bracketed paste",
    "automatic submission",
    "answer current routing",
    "inactive target",
    "cross-workspace target",
]

private func results(
    vendor: PaneKind,
    outcome: VendorConformanceOutcome,
    detail: String
) -> [VendorConformanceResult] {
    operationalChecks.map {
        VendorConformanceResult(vendor: vendor, check: $0, outcome: outcome, detail: detail)
    }
}

private func probeQuestion(marker: String) -> String {
    """
    This is an opt-in Parley live conformance probe, not a project task.
    Read the version number from the Parley cross-vendor protocol already loaded in your instructions.
    Return exactly four plain-text lines through `parley answer current`, with no Markdown fence or explanation:
    PARLEY_CONFORMANCE \(marker)
    protocol=<the loaded protocol version number>
    alpha=first line
    beta=second line with spaces
    """
}

private func expectedAnswer(marker: String) -> String {
    """
    PARLEY_CONFORMANCE \(marker)
    protocol=\(AgentProtocol.version)
    alpha=first line
    beta=second line with spaces
    """
}

private func combinedOutput(_ output: CommandOutput) -> String {
    [output.stdoutText, output.stderrText]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func cancelTimedOutHandoff(
    idempotencyKey: String,
    client: RelayCoreClient
) {
    guard let handoff = try? client.handoffs(limit: 100).first(where: { $0.idempotencyKey == idempotencyKey }) else {
        return
    }
    _ = try? client.cancelHandoff(handoff.id)
}

private func runProbe(
    _ probe: VendorConformanceProbe,
    controller: TmuxController,
    credentials: RelayCredentials,
    shim: URL,
    infoFile: URL,
    client: RelayCoreClient,
    environment: [String: String],
    timeout: TimeInterval
) throws -> [VendorConformanceResult] {
    let visible = try controller.capturePane(probe.target.id)
    if let attention = VendorConformanceAttention.blockedReason(
        kind: probe.target.kind,
        visibleText: visible
    ) {
        return results(vendor: probe.vendor, outcome: .blocked, detail: attention.detail) + [
            VendorConformanceResult(
                vendor: probe.vendor,
                check: "trust and permission gate",
                outcome: .passed,
                detail: attention.detail
            ),
        ]
    }

    let marker = UUID().uuidString.lowercased()
    let idempotencyKey = "conformance-\(marker)"
    let expected = expectedAnswer(marker: marker)
    let sourceToken = try credentials.token(for: probe.source.id)
    var commandEnvironment = environment
    commandEnvironment["PARLEY_RELAY_INFO"] = infoFile.path
    commandEnvironment["PARLEY_RELAY_TOKEN"] = sourceToken
    commandEnvironment["PARLEY_IDEMPOTENCY_KEY"] = idempotencyKey

    let output = try ProcessCommandRunner(timeout: timeout).run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [shim.path, "ask", probe.target.id, probeQuestion(marker: marker)],
        environment: commandEnvironment,
        input: nil
    )
    if output.status == 124 {
        cancelTimedOutHandoff(idempotencyKey: idempotencyKey, client: client)
    }

    let answer = RelayText.clean(output.stdoutText)
    let handoff = try? client.handoffs(limit: 100).first(where: { $0.idempotencyKey == idempotencyKey })
    let completed = handoff?.state == .completed
    let submitted = handoff?.transitions.contains(where: { $0.state == .delivered }) == true
        && handoff?.transitions.contains(where: { $0.state == .waiting }) == true
    let protocolReturned = answer.split(separator: "\n").contains("protocol=\(AgentProtocol.version)")
    let exactMultiline = answer == expected
    let detail = combinedOutput(output)
    let failureDetail = detail.isEmpty ? "the live Ask returned no output" : detail

    var results: [VendorConformanceResult] = [
        VendorConformanceResult(
            vendor: probe.vendor,
            check: "protocol injection",
            outcome: protocolReturned ? .passed : .failed,
            detail: protocolReturned ? "the target returned protocol v\(AgentProtocol.version) from its loaded instructions" : failureDetail
        ),
        VendorConformanceResult(
            vendor: probe.vendor,
            check: "multiline bracketed paste",
            outcome: exactMultiline ? .passed : .failed,
            detail: exactMultiline ? "the exact four-line sentinel returned intact" : failureDetail
        ),
        VendorConformanceResult(
            vendor: probe.vendor,
            check: "automatic submission",
            outcome: submitted ? .passed : .failed,
            detail: submitted ? "the handoff reached delivered and waiting without manual Enter" : failureDetail
        ),
        VendorConformanceResult(
            vendor: probe.vendor,
            check: "answer current routing",
            outcome: completed && output.status == 0 ? .passed : .failed,
            detail: completed && output.status == 0 ? "the correlated answer completed the originating Ask" : failureDetail
        ),
    ]
    let routeCompleted = completed && output.status == 0
    results.append(VendorConformanceResult(
        vendor: probe.vendor,
        check: "inactive target",
        outcome: probe.testsInactiveTarget ? (routeCompleted ? .passed : .failed) : .notExercised,
        detail: probe.testsInactiveTarget
            ? (routeCompleted ? "the target completed while initially inactive" : failureDetail)
            : "only the active \(probe.vendor.label) pane was available"
    ))
    results.append(VendorConformanceResult(
        vendor: probe.vendor,
        check: "cross-workspace target",
        outcome: probe.testsCrossWorkspace ? (routeCompleted ? .passed : .failed) : .notExercised,
        detail: probe.testsCrossWorkspace
            ? (routeCompleted ? "the answer crossed workspace boundaries and returned correctly" : failureDetail)
            : "the selected source and target share one workspace"
    ))
    results.append(VendorConformanceResult(
        vendor: probe.vendor,
        check: "trust and permission gate",
        outcome: .notExercised,
        detail: "the pane was at a normal prompt; deterministic checks cover prompt refusal"
    ))
    return results
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    let live = ProcessInfo.processInfo.environment["PARLEY_LIVE"] == "1"
    if !options.dryRun && !live {
        throw ConformanceCLIError.runtime(
            "Live conformance spends subscription quota and types into existing panes. Run `npm run test:conformance:plan` first, then set PARLEY_LIVE=1 explicitly."
        )
    }

    let directory = applicationDirectory(for: options)
    let environment = EnvironmentResolver.resolved()
    let controller = try TmuxController(applicationDirectory: directory, environment: environment)
    let panes = try controller.listPanes()
    let plan = VendorConformancePlanner.plan(panes: panes, vendors: options.vendors)

    if options.dryRun {
        print("Parley vendor conformance plan — no prompts sent, no quota spent\n")
        print(renderPlan(plan))
        exit(0)
    }

    let controlToken = try RelayCoreControlToken.loadOrCreate(
        at: directory.appendingPathComponent("core-control-token")
    )
    let client = RelayCoreClient(
        infoFile: directory.appendingPathComponent("relay-url"),
        controlToken: controlToken
    )
    guard client.isHealthy() else {
        throw ConformanceCLIError.runtime("Parley's coordination core is not healthy. Open Parley and retry.")
    }
    guard try client.consultations().isEmpty else {
        throw ConformanceCLIError.runtime("An Ask is already waiting. Complete or cancel it before running live conformance.")
    }

    let credentials = try RelayCredentials(file: directory.appendingPathComponent("relay-tokens.json"))
    let shim = try RelayShim.install(in: directory).appendingPathComponent("parley")
    let infoFile = directory.appendingPathComponent("relay-url")
    var allResults: [VendorConformanceResult] = []

    print("Parley live vendor conformance — existing panes will receive explicit probe messages\n")
    for item in plan {
        switch item {
        case let .skipped(vendor, reason):
            allResults += results(vendor: vendor, outcome: .notExercised, detail: reason)
            allResults.append(VendorConformanceResult(
                vendor: vendor,
                check: "trust and permission gate",
                outcome: .notExercised,
                detail: reason
            ))
        case let .probe(probe):
            print("Probing \(probe.vendor.label) in pane \(probe.target.id)…")
            allResults += try runProbe(
                probe,
                controller: controller,
                credentials: credentials,
                shim: shim,
                infoFile: infoFile,
                client: client,
                environment: environment,
                timeout: options.timeout
            )
        }
    }

    let report = VendorConformanceReport(results: allResults)
    print("\n\(report.rendered())")
    exit(report.hasFailures || report.hasBlockedChecks ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("Parley conformance: \(error.localizedDescription)\n".utf8))
    exit(2)
}
