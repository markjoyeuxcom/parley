import Darwin
import Foundation

public enum ParleyRuntimeMode: String, Codable, CaseIterable, Sendable {
    case production
    case development

    public var label: String {
        switch self {
        case .production: "Production"
        case .development: "Development"
        }
    }
}

public enum ParleyRuntimeResolutionError: LocalizedError, Equatable {
    case missingValue
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingValue:
            "--runtime requires development."
        case let .invalidValue(value):
            "Unknown Parley runtime '\(value)'. Use development."
        }
    }
}

/// Every path and lifecycle permission used by a Parley UI is derived from
/// this one value. A development process therefore cannot accidentally mix a
/// production and development Application Support or preferences.
public struct ParleyRuntime: Equatable, Sendable {
    public static let productionBundleIdentifier = "com.markjoyeux.parley"

    public let mode: ParleyRuntimeMode
    public let applicationDirectory: URL
    public let preferenceSuiteName: String

    public var visibleMarker: String? {
        switch mode {
        case .production: nil
        case .development: "DEV"
        }
    }

    public var installsStableCommand: Bool { mode == .production }
    public var uiLeaseFile: URL { applicationDirectory.appendingPathComponent("ui.lock") }

    public static func resolve(
        arguments: [String],
        homeDirectory: URL,
        isBundledApplication: Bool
    ) throws -> ParleyRuntime {
        // A packaged Parley.app is production by construction. Command-line
        // arguments cannot turn an installed build into a development owner.
        if isBundledApplication {
            return make(mode: .production, homeDirectory: homeDirectory)
        }

        guard let runtimeIndex = arguments.firstIndex(of: "--runtime") else {
            // Direct SwiftPM binaries fail safely into Development. The npm
            // entry points still pass the mode explicitly and are tested.
            return make(mode: .development, homeDirectory: homeDirectory)
        }
        guard arguments.indices.contains(runtimeIndex + 1) else {
            throw ParleyRuntimeResolutionError.missingValue
        }
        let value = arguments[runtimeIndex + 1]
        guard let mode = ParleyRuntimeMode(rawValue: value), mode == .development else {
            throw ParleyRuntimeResolutionError.invalidValue(value)
        }
        return make(mode: mode, homeDirectory: homeDirectory)
    }

    public static func make(mode: ParleyRuntimeMode, homeDirectory: URL) -> ParleyRuntime {
        let support = homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        switch mode {
        case .production:
            return ParleyRuntime(
                mode: mode,
                applicationDirectory: support.appendingPathComponent("Parley Native", isDirectory: true),
                preferenceSuiteName: productionBundleIdentifier
            )
        case .development:
            return ParleyRuntime(
                mode: mode,
                applicationDirectory: support.appendingPathComponent("Parley Native Development", isDirectory: true),
                preferenceSuiteName: "\(productionBundleIdentifier).development"
            )
        }
    }
}

public enum RuntimeTerminationPolicy {
    public static func shouldOfferChoice(
        runtime: ParleyRuntime,
        controllerAvailable: Bool
    ) -> Bool {
        controllerAvailable
    }
}

public enum RuntimeUILeaseError: LocalizedError, Equatable {
    case alreadyRunning(ParleyRuntimeMode)
    case io(ParleyRuntimeMode, String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyRunning(mode):
            return "A \(mode.label) Parley UI is already open. Use that window instead."
        case let .io(mode, detail):
            return "Parley could not acquire the \(mode.label) UI lease: \(detail)"
        }
    }
}

/// An advisory filesystem lock held for the life of a UI process. macOS
/// `O_EXLOCK` belongs to the open descriptor, so a crash or force-quit releases
/// it automatically and cannot strand a stale PID lock.
public final class RuntimeUILease: @unchecked Sendable {
    public let runtimeMode: ParleyRuntimeMode
    public let file: URL
    private let descriptor: Int32

    private init(runtimeMode: ParleyRuntimeMode, file: URL, descriptor: Int32) {
        self.runtimeMode = runtimeMode
        self.file = file
        self.descriptor = descriptor
    }

    deinit {
        _ = Darwin.close(descriptor)
    }

    public static func acquire(
        runtime: ParleyRuntime,
        fileManager: FileManager = .default
    ) throws -> RuntimeUILease {
        let directory = runtime.applicationDirectory
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw RuntimeUILeaseError.io(runtime.mode, error.localizedDescription)
        }

        let descriptor = Darwin.open(
            runtime.uiLeaseFile.path,
            O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw RuntimeUILeaseError.alreadyRunning(runtime.mode)
            }
            throw RuntimeUILeaseError.io(runtime.mode, String(cString: strerror(errno)))
        }

        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
            let detail = String(cString: strerror(errno))
            _ = Darwin.close(descriptor)
            throw RuntimeUILeaseError.io(runtime.mode, detail)
        }

        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        let record = "pid=\(ProcessInfo.processInfo.processIdentifier) runtime=\(runtime.mode.rawValue)\n"
        _ = Darwin.ftruncate(descriptor, 0)
        _ = Darwin.lseek(descriptor, 0, SEEK_SET)
        record.withCString { pointer in
            _ = Darwin.write(descriptor, pointer, record.utf8.count)
        }
        return RuntimeUILease(runtimeMode: runtime.mode, file: runtime.uiLeaseFile, descriptor: descriptor)
    }
}
