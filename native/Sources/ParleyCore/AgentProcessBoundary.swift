import Foundation

public enum AgentProcessBoundaryError: LocalizedError, Equatable {
    case sandboxUnavailable
    case invalidPaneCapability

    public var errorDescription: String? {
        switch self {
        case .sandboxUnavailable:
            "Parley cannot start an agent safely because macOS sandbox-exec is unavailable. Shell panes remain available."
        case .invalidPaneCapability:
            "Parley refused an invalid pane relay capability."
        }
    }
}

/// A mandatory outer Seatbelt profile around every vendor CLI and all of its
/// descendants. Vendor-owned sandboxes still run inside this boundary; this
/// layer protects only Parley's own control plane and does not restrict the
/// repository, vendor authentication, ordinary tools, or network access.
public struct AgentProcessBoundary: Sendable {
    public let arguments: [String]
    public let endpointDirectory: URL

    public init(
        applicationDirectory: URL,
        protocolDirectory: URL,
        shimDirectory: URL,
        protectedControlEndpoint: URL? = nil,
        transportDirectory: URL,
        paneToken: String,
        fileManager: FileManager = .default
    ) throws {
        let executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw AgentProcessBoundaryError.sandboxUnavailable
        }
        guard Self.isPaneCapability(paneToken) else {
            throw AgentProcessBoundaryError.invalidPaneCapability
        }

        endpointDirectory = try RelayFileTransport.prepareEndpoint(
            runtimeDirectory: transportDirectory,
            paneToken: paneToken,
            fileManager: fileManager
        )

        let applications = Set(([applicationDirectory] + ParleyRuntime.controlDirectories()).map { Self.canonical($0) })
        let transports = Set(([transportDirectory] + applications.map {
            RelayFileTransport.runtimeDirectory(applicationDirectory: URL(fileURLWithPath: $0))
        }).map { Self.canonical($0) })
        let controls = Set(applications.map { URL(fileURLWithPath: $0).appendingPathComponent("relay.sock").path }
            + (protectedControlEndpoint.map { [Self.canonical($0)] } ?? []))
        let fileDenials = applications.union(transports).sorted().map {
            "(deny file-read* file-write* (subpath \(Self.schemeLiteral($0))))"
        }.joined(separator: "\n")
        let controlDenials = controls.sorted().map {
            "(deny network-outbound (literal \(Self.schemeLiteral($0))))"
        }.joined(separator: "\n")
        let profile = """
        (version 1)
        (allow default)
        \(fileDenials)
        \(controlDenials)
        (allow file-read* (subpath \(Self.schemeLiteral(Self.canonical(protocolDirectory)))))
        (allow file-read* (subpath \(Self.schemeLiteral(Self.canonical(shimDirectory)))))
        (allow file-read* file-write* (subpath \(Self.schemeLiteral(Self.canonical(endpointDirectory)))))
        """
        arguments = [executable.path, "-p", profile]
    }

    private static func isPaneCapability(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 48 && bytes.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.path
    }

    private static func schemeLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // JSON and Seatbelt string literals share the escaping needed here,
        // but JSONEncoder may unnecessarily escape path separators. Seatbelt
        // accepts ordinary `/` and keeping it literal makes the exact protected
        // path independently inspectable in diagnostics and tests.
        return encoded.replacingOccurrences(of: "\\/", with: "/")
    }
}
